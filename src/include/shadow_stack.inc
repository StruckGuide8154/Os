%ifndef SHADOW_STACK_INC
%define SHADOW_STACK_INC
; ============================================================================
; Kernel shadow stack - parallel return-address store for the syscall path.
;
; THREAT MODEL
;   A stack overflow (or any stray write) inside a kernel helper that runs on
;   the L3 syscall stack can corrupt a saved return address. On the next RET
;   the CPU jumps to whatever the attacker placed at [rsp]. The user-mode
;   stack guard at slot+0x1FA000 catches user-side overflows; this is the
;   kernel-side analogue for the syscall dispatch path.
;
; DESIGN - positional mirror, no global state
;   Commit 1 widened each per-slot syscall-stack stride to 16 KiB:
;     +0x0000 guard | +0x1000 shadow (4 KiB) | +0x2000 guard | +0x3000 stack
;   Because the stride is 16 KiB-aligned, the shadow address of any live
;   syscall-stack frame is simply (its address ^ 0x2000): the stack lives in
;   the +0x3000 page, the shadow in the +0x1000 page, and bit 13 is the only
;   difference. So there is no per-slot shadow SP, no global array, and no
;   dependency on r15 holding the slot id.
;
;   A protected function mirrors its own return address on entry (KPROLOGUE)
;   and re-checks it against the mirror on exit (KEPILOGUE). The check is
;   purely local: "does the address I'm about to return to still match the
;   copy I stashed in the parallel page?" A mismatch jumps to
;   kernel_panic_shadow (fail-closed).
;
; PROPERTIES
;   * Self-contained per function. You only edit the protected function, never
;     its callers - KPROLOGUE writes the mirror, KEPILOGUE reads it. A
;     protected function called from uninstrumented code still works.
;   * Stateless. No init at syscall_entry, no empty-check at .done.
;   * Frame layouts unchanged. The macros push/pop a balanced 16 bytes and
;     restore rsp before doing anything else, so SC_VALIDATE_FRAME_OFF-style
;     readers in syscall.asm see the same offsets they always did.
;   * CET-SS migration path. When hardware CET shadow stacks are enabled the
;     macros are deleted and the CPU performs the same check in microcode; the
;     +0x1000 shadow page is exactly the SSP region CET would use.
;
; CONSTRAINTS - read before instrumenting a function
;   * ONLY apply to functions that always run on the syscall stack (rsp inside
;     a 16 KiB slot stride). On any other stack, (rsp ^ 0x2000) is NOT the
;     shadow page, so KPROLOGUE would scribble 8 bytes into unrelated memory.
;     In particular cpi_sign_callback / cpi_verify_callback are called from the
;     render loop (main.asm) and window.asm on the KERNEL stack - they must
;     keep plain ret.
;   * The protected function must be stack-balanced at every KEPILOGUE (rsp
;     equal to entry rsp), which a normal "push regs ... pop regs ... ret"
;     prologue/epilogue already guarantees.
;
; CLOBBERS
;   None. Both macros save and restore rax and r11 via push/pop, so the
;   return value (rax) and FLAGS-carrier (r11) survive untouched. The only
;   side effect of KPROLOGUE is the mirror write; the only side effect of
;   KEPILOGUE on the good path is reading it.
; ============================================================================

; KPROLOGUE - first instruction of a shadow-protected function.
;   Mirrors the freshly-pushed return address into the parallel shadow page.
%macro KPROLOGUE 0
    push rax
    push r11
    mov  rax, [rsp + 16]              ; return address on the real stack
    lea  r11, [rsp + 16]             ; address of that return-address slot
    xor  r11, 0x2000                 ; -> corresponding shadow slot
    mov  [r11], rax                  ; stash the mirror
    pop  r11
    pop  rax
%endmacro

; KEPILOGUE - replaces every RET in a shadow-protected function.
;   Re-derives the same shadow slot and verifies the return address is intact.
%macro KEPILOGUE 0
    push rax
    push r11
    mov  rax, [rsp + 16]             ; return address about to be used
    lea  r11, [rsp + 16]
    xor  r11, 0x2000
    cmp  rax, [r11]                  ; still matches the mirror?
    jne  %%bad
    pop  r11
    pop  rax
    ret
%%bad:
    mov  rdi, rax                    ; observed (corrupted) return address
    mov  rsi, [r11]                  ; expected (shadow) return address
    jmp  kernel_panic_shadow
%endmacro

%endif ; SHADOW_STACK_INC
