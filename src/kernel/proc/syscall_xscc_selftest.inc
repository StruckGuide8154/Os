; ============================================================================
; syscall_xscc_selftest.inc
; Cross-Syscall Callee-saved Contract (XSCC) boot-time self-test.
;
; PURPOSE (compiler/regalloc gate prerequisite, see MEMORY
; compiler_optimizer_baseline_and_gap): the GritHL register allocator wants to
; keep app values live in r12-r14 (and rbx/rbp) ACROSS a syscall, which is only
; sound if the kernel's syscall round-trip preserves those callee-saved
; registers as the SysV ABI promises. Two facts about the path are provable by
; inspection:
;
;   * The PUSH_ALL/POP_ALL frame (macros.inc) saves and restores user
;     rbx/rbp/r12/r13/r14 on every exit; only r15 is clobbered (it carries the
;     slot id). The earlier MEMORY note syscall_entry_kernel_stack_first claimed
;     rbx/rbp were clobbered, but the current dispatch core re-saves the user
;     values into the PUSH_ALL frame, so that note is stale.
;   * The callback round-trip (call_app_l3 / call_app_l3_return in
;     usermode_callbacks.ghl) explicitly pushes rbp,rbx,r12,r13,r14,r15 and pops
;     them in reverse, so a kernel caller's callee-saved set survives a ring-3
;     callback by construction.
;
; The ONE residual that inspection cannot settle is the normal SYSRET exit TAIL:
; after POP_ALL restores the callee-saved set, the epilogue still runs
;
;       call l3_apply_wx_policy        ; documented: preserves rax + rdx
;       SANITIZE_SEG_USER_EXIT         ; segment loads (rax, +rcx/rdx under scrub)
;
; BEFORE the SYSRETQ. l3_apply_wx_policy only pushes rax,rbx,rcx,rdx,rsi,
; r8,r9,r10,r11,r12 - it does NOT save rbp,r13,r14,r15. Its header claims "preserves
; all caller registers", but that only holds if neither its body nor its callees
; (nk_pt_window_begin/end) ever touch rbp/r13/r14/r15. If any of them does, the
; value POP_ALL restored is re-clobbered before the SYSRETQ and the app does NOT
; get callee-saved preservation -> the regalloc gate must stay closed.
;
; This self-test loads sentinels into rbx/rbp/r12/r13/r14/r15, runs the exact
; exit-tail callees, and checks survival. It is the genuine prerequisite the
; gap note calls for: an empirical verdict, not more allocator code. It is a
; fault/regression harness in the same spirit as security_probe (raw asm by
; design); no app or ring-3 plumbing is needed because the residual lives
; entirely in the ring-0 tail.
;
; Reports on COM1 (debug builds):
;   XSCC A=<maskA> B=<maskB> -> PASS | FAIL
; where each mask bit set means that register did NOT survive:
;   bit0 rbx  bit1 rbp  bit2 r12  bit3 r13  bit4 r14  bit5 r15
; A = l3_apply_wx_policy phase, B = SANITIZE_SEG_USER_EXIT phase.
; ============================================================================

XSCC_SENT_RBX equ 0xB1B2B3B4B5B6B7B8
XSCC_SENT_RBP equ 0xBADCAFE0FEEDFAC1
XSCC_SENT_R12 equ 0x1212121212121212
XSCC_SENT_R13 equ 0x1313131313131313
XSCC_SENT_R14 equ 0x1414141414141414
XSCC_SENT_R15 equ 0x1515151515151515

; Load all six sentinels (used twice; macro keeps the two phases byte-identical).
%macro XSCC_LOAD_SENTINELS 0
    mov rbx, XSCC_SENT_RBX
    mov rbp, XSCC_SENT_RBP
    mov r12, XSCC_SENT_R12
    mov r13, XSCC_SENT_R13
    mov r14, XSCC_SENT_R14
    mov r15, XSCC_SENT_R15
%endmacro

; Snapshot the six registers into the scratch buffer WITHOUT disturbing them,
; then fold a 6-bit "did-not-survive" mask into edi (caller compares).
;   Clobbers: rax (scratch), edi (result).
%macro XSCC_SNAPSHOT_AND_MASK 0
    mov [rel xscc_obs + 0], rbx
    mov [rel xscc_obs + 8], rbp
    mov [rel xscc_obs + 16], r12
    mov [rel xscc_obs + 24], r13
    mov [rel xscc_obs + 32], r14
    mov [rel xscc_obs + 40], r15
    xor edi, edi
    mov rax, XSCC_SENT_RBX
    cmp [rel xscc_obs + 0], rax
    je %%ok0
    or edi, 1
%%ok0:
    mov rax, XSCC_SENT_RBP
    cmp [rel xscc_obs + 8], rax
    je %%ok1
    or edi, 2
%%ok1:
    mov rax, XSCC_SENT_R12
    cmp [rel xscc_obs + 16], rax
    je %%ok2
    or edi, 4
%%ok2:
    mov rax, XSCC_SENT_R13
    cmp [rel xscc_obs + 24], rax
    je %%ok3
    or edi, 8
%%ok3:
    mov rax, XSCC_SENT_R14
    cmp [rel xscc_obs + 32], rax
    je %%ok4
    or edi, 16
%%ok4:
    mov rax, XSCC_SENT_R15
    cmp [rel xscc_obs + 40], rax
    je %%ok5
    or edi, 32
%%ok5:
%endmacro

; ----------------------------------------------------------------------------
; cross_syscall_contract_selftest - run from kmain (debug builds only), after
; syscall_init and after the boot page tables (incl. the APP_ARENA_PT_BASE arena
; PTs built in boot/paging.asm) are live. EDI/slot 0 is used for the wx-policy
; walk; slot 0's manifest version defaults to 0 (permissive), so the walk leaves
; present blob pages untouched and only exercises the WP window + CR3 reload.
; Preserves every callee-saved register it tests; SysV-clean to its caller.
; ----------------------------------------------------------------------------
global cross_syscall_contract_selftest
FN_DECL cross_syscall_contract_selftest, 0, 0, FN_RET_VOID
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    ; --- Phase A: the load-bearing residual. l3_apply_wx_policy(slot 0). ---
    XSCC_LOAD_SENTINELS
    xor edi, edi                        ; slot 0
    call l3_apply_wx_policy
    XSCC_SNAPSHOT_AND_MASK
    mov [rel xscc_mask_a], edi

    ; --- Phase B: the segment-sanitize tail. SANITIZE_SEG_USER_EXIT loads the
    ; ring-3 data selector into ds/es/fs/gs (and, under ENABLE_FSGS_MSR_SCRUB,
    ; clobbers rax/rcx/rdx via wrmsr). Restore the kernel data selector right
    ; after so the rest of boot runs with kernel segments. ---
    XSCC_LOAD_SENTINELS
    SANITIZE_SEG_USER_EXIT
    SANITIZE_SEG_KERNEL_ENTRY           ; re-arm kernel ds/es/fs/gs for ring-0 boot
    XSCC_SNAPSHOT_AND_MASK
    mov [rel xscc_mask_b], edi

%ifdef ENABLE_DEBUG_SERIAL
    SER 'X'
    SER 'S'
    SER 'C'
    SER 'C'
    SER ' '
    SER 'A'
    SER '='
    mov edi, [rel xscc_mask_a]
    call ser_print_hex64
    SER ' '
    SER 'B'
    SER '='
    mov edi, [rel xscc_mask_b]
    call ser_print_hex64
    SER ' '
    mov eax, [rel xscc_mask_a]
    or  eax, [rel xscc_mask_b]
    test eax, eax
    jnz .xscc_fail
    SER 'P'
    SER 'A'
    SER 'S'
    SER 'S'
    jmp .xscc_emit_done
.xscc_fail:
    SER 'F'
    SER 'A'
    SER 'I'
    SER 'L'
.xscc_emit_done:
    SER 13
    SER 10
%endif

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

section .data
xscc_obs:    times 6 dq 0
xscc_mask_a: dd 0
xscc_mask_b: dd 0
section .text
