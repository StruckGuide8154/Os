%ifndef KPTI_INC
%define KPTI_INC
; ============================================================================
; KPTI — Kernel Page-Table Isolation on bare-metal x86-64.
;
; security_todo.md §3 — "KPTI even on bare-metal x86-64. Extend the per-slot
; PT model so the kernel address space isn't fully mapped while user code runs.
; Defeats Meltdown-class leaks and speculative side channels into kernel data."
;
; ---------------------------------------------------------------------------
; THREAT MODEL (docs/STATUS.md §9 — software root of trust)
;   The §9 boundary puts *Meltdown-class speculative leaks of kernel data into
;   ring 3* squarely in scope: a malicious ring-3 app that speculatively reads
;   kernel memory (canary, l3_slot_key[], cap-mask HMAC keys, other slots'
;   blobs) through a transient out-of-order load, even though the architectural
;   access faults. SMEP/SMAP and the USER-bit toggling already landed
;   (l3_apply_slot_isolation, smap.inc) stop *architectural* ring-0 data
;   exposure and ret2usr, but they do NOT stop speculation: with the full
;   kernel still PRESENT in the active CR3 while ring 3 runs, the supervisor
;   PTEs are walkable by the speculative pipeline and the data is a Meltdown
;   gadget away. KPTI removes the kernel mapping from the address space that is
;   live while ring 3 executes, so there is simply no PTE to speculate through.
;
; ---------------------------------------------------------------------------
; THE EXISTING (NON-KPTI) ADDRESS-SPACE MODEL  (what this extends)
;   NexusOS runs on ONE shared PML4 at PAGE_TABLE_ADDR (0x70000), built by the
;   loader (uefi_loader.asm setup_paging / stage2.asm):
;       PML4[0] -> PDPT0 (0x71000)  — covers 0..512 GiB, USER branch (the app
;                                     arena PDEs live under here)
;       PML4[1] -> PDPT1 (0x72000)  — 512..1024 GiB, supervisor identity
;       PML4[2..511]                — absent
;   Everything the kernel owns — .text/.rodata/.data/.bss, the page tables
;   themselves, GDT/IDT, the framebuffer, the syscall/shadow stacks — is mapped
;   SUPERVISOR (PTE.U=0) somewhere under PML4[0]. l3_apply_slot_isolation flips
;   only the USER bit on the active slot's arena pages; the kernel mapping is
;   PRESENT the entire time ring 3 runs. That presence is the Meltdown surface.
;
; ---------------------------------------------------------------------------
; THE KPTI MODEL  (what this file adds)
;   A SECOND, kernel-owned "user-view" PML4 (kpti_user_pml4, kernel BSS,
;   OUTSIDE the ring-3 arena) that maps ONLY:
;     (a) the ring-3 app arena (PML4[0] -> the same PDPT0 the kernel PML4 uses,
;         so per-slot USER/W^X toggling via l3_apply_slot_isolation keeps
;         working unchanged — the arena PDEs are shared, only the top-level
;         PML4 differs), AND
;     (b) a tiny KERNEL TRAMPOLINE region — the minimal supervisor mapping the
;         CPU needs to take a SYSCALL / IRQ / exception and reach the code that
;         swaps CR3 back to the full kernel PML4. That region is the low 2 MiB
;         (PT0, 0x74000) which already holds the entry trampolines, the syscall
;         dispatcher's first instructions, the IDT, the GDT, and the page
;         tables the CPU must walk on entry. It stays SUPERVISOR (PTE.U=0) so
;         ring 3 still cannot read it architecturally; KPTI's job is only to
;         keep the rest of the kernel UNMAPPED here so it is not even a
;         speculative target.
;   The full kernel PML4 (kpti_kernel_pml4 == the loader's PAGE_TABLE_ADDR) is
;   installed on kernel ENTRY and the user-view PML4 on EXIT to ring 3, via
;   CR3 reloads — exactly the TLB-flush idiom the existing code already uses
;   (`mov rax,cr3 / mov cr3,rax`), just swapping the PML4 physical base.
;
;   FAIL-CLOSED / KERNEL-PT-PAGES-OUTSIDE-THE-ARENA: kpti_user_pml4 lives in
;   kernel BSS like l3_slot_key[] / l3_code_hash[] — an app's slot-memory write
;   bug cannot reach it. If KPTI init has not run (user-view base still 0) the
;   entry/exit macros are NO-OPs (they check kpti_active first), so a half-init
;   can never load a zero CR3 and triple-fault.
;
; ---------------------------------------------------------------------------
; BUILD GATE  (mirrors smap.inc -dENABLE_SMAP / cet.inc -dENABLE_CET)
;   -dENABLE_KPTI : compile the user-view-PML4 builder (kpti_init) and the
;                   CR3-swap entry/exit macros' bodies. Without it the macros
;                   are no-ops, kpti_init is not compiled, kpti_active stays 0,
;                   and the default image is BYTE-FOR-BYTE UNCHANGED — there is
;                   no new code, data, or CR3 traffic on the default boot.
;   OFF BY DEFAULT. KPTI is a measurable per-syscall cost (two CR3 reloads =
;   two full TLB flushes without PCID) and a security/perf tradeoff the lead
;   should opt into deliberately, like -Cet / -NoSmap.
;
; ---------------------------------------------------------------------------
; WHAT LANDS HERE (assembles clean in default and -dENABLE_KPTI)
;   * kpti_build_user_pml4 / kpti_init — construct the user-view PML4 at runtime
;     from the live loader PML4 (cloning the shared arena branch, mapping only
;     the low-2 MiB trampoline PDE supervisor, leaving everything else absent),
;     and record kpti_kernel_cr3 / kpti_user_cr3 / kpti_active. Runtime
;     construction (not a loader change) keeps the whole feature self-contained
;     in the gated path and touches no boot file.
;   * KPTI_SWITCH_TO_KERNEL_CR3 / KPTI_SWITCH_TO_USER_CR3 — the entry/exit
;     CR3-swap macros (one scratch GPR, documented), no-ops unless KPTI is
;     built AND active.
;
; ---------------------------------------------------------------------------
; DELIBERATELY SCOPED OUT  (documented remaining wiring — same convention as
; the CET / SMAP / per-slot-key landings in §3/§10)
;   The SWITCH POINTS themselves must be inserted into files owned by other
;   concurrent changes, so per repo convention the primitive + macros land here
;   and the call-site wiring is enumerated, not forced into a contended file:
;
;   (1) SYSCALL entry/exit — src/kernel/proc/syscall.asm (held by the
;       heterogeneous-syscall-numbering change). On ENTRY: invoke
;       KPTI_SWITCH_TO_KERNEL_CR3 at the very top of `syscall_entry`, BEFORE the
;       first instruction that touches a kernel address that is unmapped in the
;       user view — i.e. immediately after the CPU lands, before the
;       `mov rdx,[rel l3_app_arena_base_v]` rel read (that .data symbol is
;       outside the trampoline region). The syscall entry stub itself (its first
;       bytes) MUST sit in the low-2 MiB trampoline window that the user view
;       keeps mapped; today syscall_entry is in the monolithic .text which
;       spans well past 2 MiB, so a full cutover also needs the entry stub (just
;       the CR3 swap + a jmp to the body) relocated into the trampoline PDE — a
;       linker/section change. On EXIT: invoke KPTI_SWITCH_TO_USER_CR3 at
;       `.slot_ok_return`, AFTER the last kernel-data access and right before
;       `SANITIZE_SEG_USER_EXIT` / the SYSRET-frame load (it clobbers one
;       scratch GPR — bracket it like the rax/rdx save already there).
;
;   (2) IRQ / exception entry/exit — src/kernel/core/isr.asm (isr_common_stub
;       and the exception stubs). Same shape: swap to the kernel CR3 in the
;       common stub prologue (after the trampoline saves regs) and back to the
;       user view in the epilogue ONLY on the ring-3 return path (iretq to CS
;       with RPL=3). Returns to ring 0 (nested kernel IRQ) must NOT swap. The
;       exception/IRQ entry vectors are reached via the IDT, whose pointer and
;       first stub bytes also live in the low-2 MiB trampoline window.
;
;   (3) The enter_usermode / call_app_l3 iretq paths (usermode.asm, owned here)
;       — these are the OTHER ring-3 entry exits. They are wired in THIS change
;       (see KPTI_SWITCH_TO_USER_CR3 right before the iretq frames) because
;       usermode.asm is owned by this task; they are inert until kpti_init runs.
;
;   (4) ENTRY-STUB RELOCATION + PCID. A production KPTI keeps the per-CR3 TLB
;       cost down with PCID (CR4.PCIDE + non-flushing CR3 writes) and places the
;       trampoline in a dedicated tiny section. Both are follow-ups; the macros
;       use plain CR3 reloads (correct, just slower) and the trampoline window
;       is the existing low-2 MiB supervisor PDE.
;
;   Until (1) and (2) are wired, kpti_init is still NOT called from kmain
;   (kpti_active stays 0) so even a -dENABLE_KPTI build is a runtime no-op: the
;   user-view PML4 is built-able and verified to assemble, but is not made live
;   because making it live without the syscall/IRQ swap points would unmap the
;   kernel from under a returning ring-3 syscall and triple-fault. The kmain
;   call to kpti_init is the final flip, gated behind the same -dENABLE_KPTI,
;   to be added in lockstep with the two contended switch points.
; ============================================================================

; Paging bit constants (local — paging.asm's are file-local; usermode.asm/this
; redeclare the ones they need, same as PAGE_NX in boot_memory.inc).
KPTI_P_PRESENT  equ 0x01
KPTI_P_WRITABLE equ 0x02
KPTI_P_USER     equ 0x04
KPTI_NX         equ (1 << 63)

; The low-2 MiB trampoline PDE index in PD0 (0..2 MiB → PD0[0]). This PDE
; already points at the fine-grained PT0 (4 KiB pages) in the loader build, and
; holds the entry trampolines, the early dispatcher bytes, GDT, IDT, and the
; page tables themselves — the minimum the CPU must walk/execute to take an
; entry and swap CR3 back. KPTI keeps exactly this PDE (supervisor) in the user
; view and nothing else of the kernel.
KPTI_TRAMPOLINE_PDE_IDX equ 0

%ifdef ENABLE_KPTI
; ---------------------------------------------------------------------------
; kpti_build_user_pml4 — construct the user-view PML4 in kpti_user_pml4 (kernel
;   BSS). Clones the loader PML4's ARENA branch (PML4[0] -> the SAME PDPT0, so
;   the per-slot USER/W^X toggling on the shared arena PTs keeps working) and
;   maps ONLY the low-2 MiB trampoline PDE supervisor; every other PML4 entry
;   (PML4[1] = the supervisor identity, PML4[2..511]) is left ABSENT so no
;   kernel data is reachable from the user view.
;
;   IMPORTANT: cloning PML4[0] wholesale would re-expose all of the low 1 GiB
;   (kernel .text/.data live in PD0[1..]). So instead the user view gets its
;   OWN PDPT0 + PD0 (kpti_user_pdpt0 / kpti_user_pd0, kernel BSS) that map only
;   (a) PD0[0] = the trampoline PT0 (shared, supervisor) and (b) the arena PDEs
;   pointing at the SAME app-arena PTs the kernel PD0 uses. PDPT0[1..511] and
;   PD0[non-arena, non-tramp] stay absent.
;
;   Walks the live loader tables to find the arena PDE range and PT0, so it is
;   independent of KASLR / boot path. Clobbers rax/rbx/rcx/rdx/rsi/rdi/r8/r9.
;   Returns nothing; sets kpti_user_cr3 / kpti_kernel_cr3. Does NOT set
;   kpti_active (kpti_init does, last, after the build succeeds).
; ---------------------------------------------------------------------------
global kpti_build_user_pml4
kpti_build_user_pml4:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    ; Record the kernel CR3 (the loader PML4, == PAGE_TABLE_ADDR; reading CR3
    ; rather than the constant honors any future relocation of the root).
    mov rax, cr3
    and rax, ~0xFFF
    mov [rel kpti_kernel_cr3], rax
    mov r8, rax                          ; r8 = kernel PML4 base

    ; Zero the user-view PML4 / PDPT0 / PD0 (all absent to start).
    lea rdi, [rel kpti_user_pml4]
    xor eax, eax
    mov ecx, (4096 * 3) / 8              ; three 4 KiB tables
    cld
    rep stosq

    ; kpti_user_pml4[0] -> kpti_user_pdpt0 (USER branch: the arena needs U=1 on
    ; the PML4/PDPT/PD path so the leaf PTE.U toggling is effective). The kernel
    ; is identity-mapped at its load base, so the label VA == physical address;
    ; the low 12 bits are zero (alignb 4096) so OR-ing flags is safe.
    lea rax, [rel kpti_user_pdpt0]
    or  rax, KPTI_P_PRESENT | KPTI_P_WRITABLE | KPTI_P_USER
    lea rdi, [rel kpti_user_pml4]
    mov [rdi], rax

    ; kpti_user_pdpt0[0] -> kpti_user_pd0 (USER branch).
    lea rax, [rel kpti_user_pd0]
    or  rax, KPTI_P_PRESENT | KPTI_P_WRITABLE | KPTI_P_USER
    lea rdi, [rel kpti_user_pdpt0]
    mov [rdi], rax

    ; Walk the kernel tables: kernel PML4[0] -> PDPT0 -> PD0.
    mov rbx, [r8]                        ; kernel PML4[0]
    and rbx, ~0xFFF                      ; rbx = kernel PDPT0 phys
    mov rdx, [rbx]                       ; kernel PDPT0[0]
    and rdx, ~0xFFF                      ; rdx = kernel PD0 phys
    mov r9, rdx                          ; r9 = kernel PD0 base

    ; kpti_user_pd0[0] = kernel PD0[0] (the trampoline PDE -> PT0), supervisor,
    ; copied VERBATIM so the low-2 MiB fine-grained mapping (entry stubs, IDT,
    ; GDT, page tables) is identical and walkable on entry. Clearing USER is
    ; harmless (kernel PD0[0] has U=1 because the arena lives elsewhere under
    ; PD0; but the trampoline pages themselves are PTE.U=0 in PT0, so ring 3
    ; still cannot read them).
    mov rax, [r9 + KPTI_TRAMPOLINE_PDE_IDX*8]
    lea rdi, [rel kpti_user_pd0]
    mov [rdi + KPTI_TRAMPOLINE_PDE_IDX*8], rax

    ; Copy the ARENA PDEs (the per-slot 4 KiB-PT-backed PDEs) verbatim from the
    ; kernel PD0 into the user PD0, so the user view shares the SAME app-arena
    ; PTs — l3_apply_slot_isolation / l3_apply_wx_policy continue to operate on
    ; one set of leaf PTEs that BOTH PML4s observe. Arena PDE range:
    ;   first = l3_app_arena_base_v >> 21   (PD0 index, since arena < 1 GiB)
    ;   count = ceil(l3_app_arena_size_v / 2 MiB)
    mov rax, [rel l3_app_arena_base_v]
    shr rax, 21                          ; rax = first arena PDE index
    mov rcx, [rel l3_app_arena_size_v]
    add rcx, 0x1FFFFF
    shr rcx, 21                          ; rcx = arena PDE count
    lea rsi, [r9 + rax*8]                ; src = &kernel_PD0[first]
    lea rdi, [rel kpti_user_pd0]
    lea rdi, [rdi + rax*8]               ; dst = &user_PD0[first]
.copy_arena_pde:
    test rcx, rcx
    jz .arena_done
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec rcx
    jmp .copy_arena_pde
.arena_done:

    ; Keep the supervisor kernel-stack PDE mapped so IRET can read ring-3 entry
    ; frames built on the kernel stack after KPTI_SWITCH_TO_USER_CR3. The leaf
    ; mappings remain supervisor-only; ring 3 cannot architecturally read them.
    mov rax, KERNEL_STACK_TOP - 1
    shr rax, 21
    mov rdx, [r9 + rax*8]
    lea rdi, [rel kpti_user_pd0]
    mov [rdi + rax*8], rdx

    ; Keep the syscall-stack PT PDE mapped supervisor-only for SYSRET/IRET
    ; transitions whose final frame still lives on a kernel syscall stack.
    mov rax, L3_SYSCALL_STACK_ADDR
    shr rax, 21
    mov rdx, [r9 + rax*8]
    mov [rdi + rax*8], rdx

    ; Publish the user CR3 (physical base of kpti_user_pml4). VA==PA for the
    ; identity-mapped kernel BSS, so the label address is the physical base.
    lea rax, [rel kpti_user_pml4]
    and rax, ~0xFFF
    mov [rel kpti_user_cr3], rax

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---------------------------------------------------------------------------
; kpti_init — build the user-view PML4 and arm KPTI. Call from kmain (gated)
;   AFTER l3_install_syscall_stack_pt (so the final low-2 MiB mapping is in
;   place) and AFTER app_blob_init (so l3_app_arena_base_v/size_v are valid),
;   but ONLY once the syscall.asm + isr.asm CR3-swap points are wired — see the
;   scoped-out note in the header. Sets kpti_active=1 as the final step.
;   Clobbers the same set as kpti_build_user_pml4.
; ---------------------------------------------------------------------------
global kpti_init
kpti_init:
    call kpti_build_user_pml4
    mov byte [rel kpti_active], 1
    ret

global kpti_log_state
kpti_log_state:
    push rax
    push rdi
    SER 'K'
    SER 'P'
    SER 'T'
    SER 'I'
    SER ' '
    SER 'a'
    movzx edi, byte [rel kpti_active]
    call ser_print_hex64
    SER ' '
    SER 'k'
    mov rdi, [rel kpti_kernel_cr3]
    call ser_print_hex64
    SER ' '
    SER 'u'
    mov rdi, [rel kpti_user_cr3]
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    pop rax
    ret
%endif ; ENABLE_KPTI

; ---------------------------------------------------------------------------
; KPTI_SWITCH_TO_KERNEL_CR3 — install the full kernel PML4 (the loader's). Used
;   on EVERY kernel entry from ring 3 (SYSCALL stub, IRQ/exception common stub)
;   before touching any kernel address outside the trampoline window. No-op
;   unless KPTI is built AND kpti_active. Clobbers ONE scratch GPR (the macro
;   arg); the caller must pass a register that is dead at the entry point (on
;   the SYSCALL path r11/r10 are live with user RFLAGS/arg — pass rax only after
;   the user rax syscall-number has been saved, or an explicitly-saved scratch).
; ---------------------------------------------------------------------------
%macro KPTI_SWITCH_TO_KERNEL_CR3 1
%ifdef ENABLE_KPTI
    ; Entry may be running under the user-view CR3, where kpti_active and other
    ; kernel data are intentionally unmapped. Use the loader PML4 constant.
    mov %1, PAGE_TABLE_ADDR
    mov cr3, %1
%endif
%endmacro

; ---------------------------------------------------------------------------
; KPTI_SWITCH_TO_USER_CR3 — install the user-view PML4. Used on EVERY return to
;   ring 3 (SYSRET path, the iretq paths in usermode.asm, the IRQ/exception
;   ring-3 return). MUST run AFTER the last kernel-data access on the exit path
;   and BEFORE the SYSRET/IRETQ — once it executes, only the trampoline + arena
;   are mapped, so the few remaining exit instructions (selector loads, the
;   iret frame already pushed on the syscall stack) must reference only
;   trampoline-window or already-loaded state. No-op unless built AND active.
;   Clobbers ONE scratch GPR (the macro arg); pass a register dead on the exit
;   path (bracket with push/pop like the existing rax/rdx save at .slot_ok_return
;   if none is free).
; ---------------------------------------------------------------------------
%macro KPTI_SWITCH_TO_USER_CR3 1
%ifdef ENABLE_KPTI
    cmp byte [rel kpti_active], 0
    je %%kpti_skip_u
    mov %1, [rel kpti_user_cr3]
    mov cr3, %1
%%kpti_skip_u:
%endif
%endmacro

%ifdef ENABLE_KPTI
section .bss
; 4 KiB-aligned kernel-owned page-table pages for the user view. OUTSIDE the
; ring-3 arena (kernel BSS) so an app's slot-memory write cannot forge them.
; alignb 4096 guarantees each is a valid CR3/PML4/PDPT/PD base.
alignb 4096
global kpti_user_pml4
global kpti_user_pdpt0
global kpti_user_pd0
kpti_user_pml4:  resb 4096
kpti_user_pdpt0: resb 4096
kpti_user_pd0:   resb 4096

section .data
align 8
; Cached CR3 values (physical PML4 bases). kpti_kernel_cr3 = the loader PML4
; (full kernel mapping); kpti_user_cr3 = the trampoline+arena-only view.
global kpti_kernel_cr3
global kpti_user_cr3
kpti_kernel_cr3: dq 0
kpti_user_cr3:   dq 0

align 1
; kpti_active gates the entry/exit macros at RUNTIME. Default 0 so a
; -dENABLE_KPTI build that has not yet called kpti_init (e.g. before the
; contended syscall/IRQ switch points are wired) is a pure no-op and cannot
; load a half-built / zero CR3. Defined ONLY under the gate so the default
; image is byte-for-byte unchanged: without ENABLE_KPTI no macro body is
; emitted, nothing references kpti_active, and no byte is added to any section.
global kpti_active
kpti_active: db 0
%endif ; ENABLE_KPTI

%endif ; KPTI_INC
