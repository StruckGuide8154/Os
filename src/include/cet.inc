%ifndef CET_INC
%define CET_INC
; ============================================================================
; x86 CET (Control-flow Enforcement Technology): shadow stack (SHSTK) and
; indirect branch tracking (IBT) detection + future enable plumbing.
;
; security_todo.md §3 - "CET shadow stack + IBT on supported CPUs."
;
; RELATIONSHIP TO THE EXISTING SOFTWARE SHADOW STACK
;   Grit already ships a *software* kernel shadow stack on the syscall path
;   (shadow_stack.inc: the KPROLOGUE/KEPILOGUE macros mirror each return
;   address into the per-slot +0x1000 shadow page and trap a mismatch in
;   kernel_panic_shadow). That mitigation is portable - it works on every CPU
;   and under QEMU TCG. This file COMPLEMENTS it: where the silicon supports
;   hardware CET shadow stacks, the +0x1000 shadow page is exactly the SSP
;   region the CPU would use, and a future migration deletes the macros and
;   lets microcode do the same check (see the "CET-SS migration path" note in
;   shadow_stack.inc). Until that migration lands the software mirror stays the
;   load-bearing kernel-ROP defense; this file adds detection + the enable
;   scaffold so the hardware feature can be turned on incrementally.
;
; WHAT THIS FILE DOES TODAY (and why it is scoped this way)
;   * DETECTION (always compiled, cheap, no side effects beyond a few data
;     bytes): cet_detect probes CPUID(7,0).ECX bit 7 (SHSTK) and
;     CPUID(7,0).EDX bit 20 (IBT) and records them in cet_have_shstk /
;     cet_have_ibt, plus a combined cet_supported. Called from kmain. This is
;     the inventory the rest of the kernel (and a future attestation syscall)
;     reads to know whether the part can do hardware CET at all.
;
;   * ENABLE SCAFFOLD (gated on -dENABLE_CET): cet_enable records that the
;     always-on software kernel shadow stack remains the active protection.
;     It deliberately does not touch CR4.CET, IA32_S_CET, or IA32_PL0_SSP yet,
;     even when CPUID reports hardware support. This keeps real hardware with
;     CET-capable AMD/Intel CPUs on the same safe path as QEMU.
;
; DELIBERATELY SCOPED OUT (documented follow-up work)
;   * Activating the supervisor shadow stack itself. Turning on CR4.CET +
;     S_CET.SH_STK_EN is NOT sufficient to safely RET-check in ring 0: the CPU
;     also needs a valid supervisor SSP (IA32_PL0_SSP, MSR 0x6A4) pointing at a
;     shadow-stack-typed page seeded with a supervisor-shadow-stack token, the
;     PTEs for that page marked shadow-stack (Dirty=1, R/W=0) in the paging
;     structures, and CR0.WP=1 - all of which must be wired through the per-slot
;     syscall-stack PT setup in usermode.asm/l3_install_syscall_stack_pt. That
;     is the invasive part and is left for a follow-up; the +0x1000 shadow page
;     reserved by the software design is the natural home for it. Until then
;     cet_enable leaves hardware supervisor CET completely inert, so it cannot
;     trap a kernel RET against an unseeded/incompletely wired SSP and brick the
;     boot.
;
;   * Full IBT (an endbr64 at every indirect-branch target). Grit has many
;     indirect jumps/calls (the syscall dispatcher's jmp [r12+HANDLER], the
;     app-callback trampolines, etc.); landing endbr64 on every one is a broad,
;     cross-file change that would touch files owned by other concurrent
;     work. Per the task scope this is reduced to DETECTION + plumbing: we
;     record cet_have_ibt and expose -dENABLE_CET_IBT, but do NOT flip
;     S_CET.ENDBR_EN by default (doing so without endbr64 markers would #CP on
;     the first indirect branch). The marker rollout + ENDBR_EN flip is the
;     documented follow-up.
;
; USER-MODE CET (U_CET, MSR 0x6A0) is also out of scope here: ring-3 apps are
;   loaded from a single signed blob and run under W^X + the per-slot software
;   protections already landed; wiring U_CET would require shadow-stack PTEs in
;   every app slot. Detection covers it implicitly (same CPUID bits); the U_CET
;   MSR address is defined below for the follow-up.
;
; BUILD GATE  (mirrors smap.inc's -dENABLE_SMAP / -NoSmap convention)
;   -dENABLE_CET      : compile cet_enable's software-fallback status path.
;                       Hardware CR4/S_CET/SSP programming is intentionally
;                       scoped out until the full SSP wiring lands.
;   -dENABLE_CET_IBT  : reserved for the later IBT arm path. Requires
;                       -dENABLE_CET, but is inert today because endbr64 markers
;                       and CR4.CET arming are not yet emitted.
; ============================================================================

; CET-related MSRs.
IA32_U_CET    equ 0x6A0     ; user-mode CET config (scoped out - see header)
IA32_S_CET    equ 0x6A2     ; supervisor-mode CET config
IA32_PL0_SSP  equ 0x6A4     ; ring-0 shadow stack pointer (follow-up)
IA32_PL3_SSP  equ 0x6A7     ; ring-3 shadow stack pointer (follow-up)

; IA32_S_CET bit layout (subset we care about).
S_CET_SH_STK_EN equ (1 << 0)   ; enable supervisor shadow stack (NOT set yet - see header)
S_CET_WR_SHSTK_EN equ (1 << 1) ; allow WRSS
S_CET_ENDBR_EN  equ (1 << 2)   ; enable IBT (NOT set yet - needs endbr64 markers)
S_CET_NO_TRACK_EN equ (1 << 4) ; honor no-track prefix

; CR4.CET is bit 23.
CR4_CET_BIT   equ 23

; Dedicated supervisor CET shadow stack. This is intentionally separate from
; the software per-slot shadow pages that KPROLOGUE writes to.
CET_PL0_SHSTK_ADDR equ (L3_SYSCALL_STACK_ADDR + 0x1FF000)
CET_PL0_SHSTK_TOP  equ (CET_PL0_SHSTK_ADDR + 0x1000)
CET_PL0_SHSTK_PTE  equ (SYSCALL_STACK_PT_BASE + 0x1FF*8)
CET_P_PRESENT      equ 0x001
CET_P_DIRTY        equ 0x040

; ---------------------------------------------------------------------------
; cet_detect - probe CPUID(7,0) for SHSTK/IBT and record the result.
;   Always safe to call on any long-mode CPU. Clobbers rax/rbx/rcx/rdx
;   (caller-saved at the kmain init site). No CR4/MSR writes here.
;
;   CPUID(7,0).ECX bit 7  = SHSTK (shadow stack)
;   CPUID(7,0).EDX bit 20 = IBT   (indirect branch tracking)
; ---------------------------------------------------------------------------
global cet_detect
cet_detect:
    push rbx
    ; Make sure CPUID leaf 7 exists (max basic leaf >= 7).
    xor eax, eax
    cpuid
    cmp eax, 7
    jb .none
    mov eax, 7
    xor ecx, ecx
    cpuid
    ; SHSTK = ECX bit 7
    xor eax, eax
    bt  ecx, 7
    setc al
    mov byte [rel cet_have_shstk], al
    mov bl, al                       ; remember for the combined flag
    ; IBT = EDX bit 20
    xor eax, eax
    bt  edx, 20
    setc al
    mov byte [rel cet_have_ibt], al
    or  bl, al
    mov byte [rel cet_supported], bl
    call cet_log_detect
    pop rbx
    ret
.none:
    mov byte [rel cet_have_shstk], 0
    mov byte [rel cet_have_ibt], 0
    mov byte [rel cet_supported], 0
    call cet_log_detect
    pop rbx
    ret

cet_log_detect:
    push rax
    push rdi
    SER 'C'
    SER 'E'
    SER 'T'
    SER 'D'
    SER ' '
    SER 's'
    movzx edi, byte [rel cet_have_shstk]
    call ser_print_hex64
    SER ' '
    SER 'i'
    movzx edi, byte [rel cet_have_ibt]
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    pop rax
    ret

%ifdef ENABLE_CET
; ---------------------------------------------------------------------------
; cet_enable - publish the current CET protection mode.
;   PRECONDITION: cet_detect has run (kmain calls it first). If hardware SHSTK
;   is unavailable, the existing software kernel shadow stack remains the active
;   fallback and the serial state reports that explicitly.
;
;   Scoped (see header): hardware supervisor CET is NOT armed yet. Real CPUs can
;   expose SHSTK before this kernel has the required per-core SSPs, interrupt/IST
;   SSP handling, syscall-entry SSPs, and properly sized shadow stacks. Until
;   that invasive work lands, do not write IA32_PL0_SSP, IA32_S_CET, or CR4.CET.
;
;   Clobbers nothing. Caller-saved at the kmain init site.
; ---------------------------------------------------------------------------
global cet_enable
cet_enable:
    mov byte [rel cet_sw_shstk_armed], 1
    mov byte [rel cet_enable_state], 3
    ret
%endif ; ENABLE_CET

global cet_log_state
cet_log_state:
    push rax
    push rdi
    SER 'C'
    SER 'E'
    SER 'T'
    SER ' '
    SER 'e'
    movzx edi, byte [rel cet_enable_state]
    call ser_print_hex64
    SER ' '
    SER 's'
    movzx edi, byte [rel cet_shstk_armed]
    call ser_print_hex64
    SER ' '
    SER 'w'
    movzx edi, byte [rel cet_sw_shstk_armed]
    call ser_print_hex64
    SER ' '
    SER 'i'
    movzx edi, byte [rel cet_ibt_armed]
    call ser_print_hex64
    SER ' '
    SER 'p'
    mov rdi, [rel cet_pl0_ssp]
    call ser_print_hex64
    SER ' '
    SER 'm'
    mov rdi, [rel cet_s_cet_low]
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    pop rax
    ret

section .data
align 1
; Detection results (bytes; 1 = present). Read by a future attestation syscall
; and by cet_enable. Default 0 so a kmain that somehow skips cet_detect is safe.
global cet_have_shstk
global cet_have_ibt
global cet_supported
global cet_enable_state
global cet_shstk_armed
global cet_sw_shstk_armed
global cet_ibt_armed
global cet_s_cet_low
global cet_pl0_ssp
cet_have_shstk: db 0
cet_have_ibt:   db 0
cet_supported:  db 0
cet_enable_state: db 0     ; 0=not called, 2=hardware SHSTK, 3=software fallback
cet_shstk_armed:  db 0
cet_sw_shstk_armed: db 0
cet_ibt_armed:    db 0
align 8
cet_s_cet_low:    dq 0
cet_pl0_ssp:      dq 0

%endif ; CET_INC
