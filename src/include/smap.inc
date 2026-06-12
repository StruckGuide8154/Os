%ifndef SMAP_INC
%define SMAP_INC
; ============================================================================
; SMAP / SMEP enforcement for the kernel/user boundary.
;
; THREAT MODEL
;   SMEP (CR4.SMEP, bit 20) faults if the CPU tries to *execute* a user-mode
;   (PTE.U=1) page while in ring 0 - kills ret2usr / supervisor-mode code
;   exec out of an attacker-mapped slot page.
;   SMAP (CR4.SMAP, bit 21) faults if ring 0 *reads or writes* a user-mode
;   page while EFLAGS.AC is clear. The only places the kernel legitimately
;   touches user memory are the syscall arg validators / loaders and the
;   handful of copy sites; everywhere else an accidental user deref now
;   faults instead of silently succeeding (the "confused deputy" class).
;
; CONTRACT
;   Bracket EVERY intentional kernel access to a user pointer with
;   USER_ACCESS_BEGIN ... USER_ACCESS_END. BEGIN sets EFLAGS.AC (stac) so the
;   enclosed load/store is permitted; END clears it (clac) so any *later*
;   stray deref faults. Keep the bracket as tight as possible - ideally one
;   instruction - and never call out to a helper that itself does user access
;   while AC is set unless that helper expects it.
;
;   AC propagates through CALL/RET and is part of EFLAGS, but it is cleared by
;   the CPU on interrupt/exception entry, so the window is not exploitable via
;   a nested IRQ landing in unrelated kernel code.
;
; BUILD GATE
;   Everything here is gated on -dENABLE_SMAP (same convention as
;   ENABLE_TRACE / ENABLE_SHADOW_STACK_POC). Without the flag the macros are
;   no-ops and CR4 is left exactly as the boot loaders configured it, so the
;   default build is byte-for-byte unchanged. With the flag, smap_smep_init
;   probes CPUID(7).EBX for SMEP (bit 7) / SMAP (bit 20) and only sets the CR4
;   bits the part actually supports - older QEMU / CPUs without SMAP boot fine
;   (the stac/clac then #UD, which is why the macros are also gated: a build
;   with ENABLE_SMAP is expected to run on SMAP-capable silicon or KVM).
;
; INTERACTION WITH THE SHADOW STACK
;   These macros only touch EFLAGS.AC via stac/clac, which preserve all GPRs
;   and the rest of FLAGS. They are independent of KPROLOGUE/KEPILOGUE and may
;   appear inside a shadow-protected function without affecting the mirror.
; ============================================================================

; ============================================================================
; FS/GS sanitization on the kernel<->ring-3 boundary (security_todo.md §3,
; "Sanitize FS/GS on user entry/exit").
;
; THREAT MODEL / WHY THIS LIVES HERE
;   GritOS runs a FLAT segment model: there is no swapgs anywhere, and the
;   FS_BASE (MSR 0xC0000100), GS_BASE (0xC0000101) and KERNEL_GS_BASE
;   (0xC0000102) MSRs are never written by the kernel - FS/GS are only ever
;   selectors into the flat GDT data segments. CR4.FSGSBASE is left disabled,
;   so ring 3 cannot wrfsbase/wrgsbase a base of its own either. That means the
;   classic "kernel GS base leaks to ring 3 via a missing swapgs" bug is
;   structurally absent today. BUT two real gaps existed:
;
;     1. ENTRY (SYSCALL): the entry stub loads kernel data selectors into
;        ds/es/fs/gs, which is correct - kept here as the canonical entry
;        sanitizer so every future kernel-entry path uses one definition.
;     2. EXIT (SYSRET / iretq): NEITHER SYSRETQ NOR IRETQ reloads DS/ES/FS/GS.
;        The kernel GDT64_DATA_SEG (a DPL-0 selector) left in fs/gs at entry
;        therefore stayed visible to ring 3 across the return - a stale kernel
;        selector leak, and the wrong direction for a future swapgs/FSGSBASE
;        world. SANITIZE_SEG_USER_EXIT closes it by loading the ring-3
;        GDT64_USER_DATA selector into ds/es/fs/gs before the SYSRETQ/IRETQ.
;
;   The base-MSR zeroing below is defense-in-depth: it is a no-op against
;   today's flat model (the bases are already 0) but makes the boundary
;   DETERMINISTIC - if anyone later turns on FSGSBASE or swapgs, a stale base
;   can never survive a transition in either direction. It is gated on
;   -dENABLE_FSGS_MSR_SCRUB (OFF by default) so the default build pays nothing
;   and keeps byte-for-byte behaviour; the selector reloads are always on
;   because they are the load-bearing fix and cost three moves.
;
;   REGISTER CONTRACT: the selector macros clobber ONLY ax (a scratch GPR the
;   exit paths have already finished with - verified at each call site). The
;   MSR scrub additionally clobbers rcx/rdx/rax for wrmsr and is bracketed so
;   it only runs where those are dead. NEITHER touches the SYSRET/return
;   contract registers (rax=return value, rdx/edx=slot id, rcx=user RIP,
;   r11=user RFLAGS) - the macros are invoked BEFORE those are loaded on the
;   exit paths.
; ============================================================================

IA32_FS_BASE        equ 0xC0000100
IA32_GS_BASE        equ 0xC0000101
IA32_KERNEL_GS_BASE equ 0xC0000102

; SANITIZE_SEG_KERNEL_ENTRY - load kernel data selectors into ds/es/fs/gs.
;   The canonical kernel-entry segment sanitizer. Clobbers ax only.
%macro SANITIZE_SEG_KERNEL_ENTRY 0
    mov ax, GDT64_DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
%ifdef ENABLE_FSGS_MSR_SCRUB
    SANITIZE_FSGS_BASE_MSRS
%endif
%endmacro

; SANITIZE_SEG_USER_EXIT - load ring-3 data selectors into ds/es/fs/gs so the
;   kernel GDT64_DATA_SEG selector never stays visible to ring 3 after
;   SYSRETQ/IRETQ. Clobbers ax only. MUST run before the exit path loads the
;   SYSRET/return contract registers (rax/rcx/rdx/r11).
%macro SANITIZE_SEG_USER_EXIT 0
%ifdef ENABLE_FSGS_MSR_SCRUB
    SANITIZE_FSGS_BASE_MSRS
%endif
    mov ax, GDT64_USER_DATA
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
%endmacro

; SANITIZE_FSGS_BASE_MSRS - zero FS_BASE/GS_BASE/KERNEL_GS_BASE.
;   Defense-in-depth only (no-op against the flat model). Clobbers rax/rcx/rdx.
%macro SANITIZE_FSGS_BASE_MSRS 0
    xor eax, eax
    xor edx, edx
    mov ecx, IA32_FS_BASE
    wrmsr
    mov ecx, IA32_GS_BASE
    wrmsr
    mov ecx, IA32_KERNEL_GS_BASE
    wrmsr
%endmacro

; USER_ACCESS_BEGIN - permit ring-0 access to user (PTE.U) pages.
%macro USER_ACCESS_BEGIN 0
%ifdef ENABLE_SMAP
    stac
%endif
%endmacro

; USER_ACCESS_END - re-arm SMAP so subsequent stray user derefs fault.
%macro USER_ACCESS_END 0
%ifdef ENABLE_SMAP
    clac
%endif
%endmacro

%ifdef ENABLE_SMAP
; smap_smep_init - enable CR4.SMEP/SMAP for the BSP, contingent on CPUID.
;   Call once after the kernel page tables are live (PTE.U bits are correct)
;   and before the first ring-3 entry. APs mirror CR4 from the BSP in
;   apic.asm, so enabling here propagates to them via that sanitize step.
;   Clobbers rax/rbx/rcx/rdx (caller-saved at the init call site in kmain).
global smap_smep_init
smap_smep_init:
    push rbx
    ; CPUID leaf 7, subleaf 0 -> EBX feature bits.
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov rax, cr4
    ; SMEP = CPUID.(7,0).EBX bit 7  -> CR4 bit 20
    bt  ebx, 7
    jnc .no_smep
    bts rax, 20
.no_smep:
    ; SMAP = CPUID.(7,0).EBX bit 20 -> CR4 bit 21
    bt  ebx, 20
    jnc .no_smap
    bts rax, 21
.no_smap:
    mov cr4, rax
    ; Start with AC clear so the very first stray kernel deref faults.
    clac
    pop rbx
    ret
%endif

%endif ; SMAP_INC
