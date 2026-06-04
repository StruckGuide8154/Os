; ============================================================================
; syscall_epilogue.inc
; syscall_entry epilogue: app-done, postcondition check, canary verify, sysret
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
.sc_app_done:
%ifdef ENABLE_TRACE
    mov rdi, [rsp + ALL_RAX]
    mov esi, r15d
    xor edx, edx
    mov ecx, TRACE_FLAG_SYSCALL_EXIT
    call trace_syscall
%endif
    POP_ALL
    ; Canary check before handing back to the L3 return path. Layout
    ; after POP_ALL: [rsp]=slot, [rsp+8]=canary. call_app_l3_return
    ; reads slot from [rsp].
    mov rax, [rsp + 8]
    cmp rax, [rel kernel_canary]
    jne .app_done_canary_bad
    jmp call_app_l3_return
.app_done_canary_bad:
    mov rdi, rax
    lea rsi, [rel .app_done_canary_bad]
    jmp kernel_panic_canary

.done:
%ifdef ENABLE_TRACE
    mov eax, r15d
    cmp eax, MAX_WINDOWS
    jb .trace_slot_ok_done
    xor eax, eax
.trace_slot_ok_done:
    imul rax, L3_RT_SIZE
    lea rdi, [rel l3_runtime]
    add rdi, rax
    mov rdi, [rdi + L3_RT_SYSCALL_NUM]
    mov esi, r15d
    mov rdx, [rsp + ALL_RAX]
    mov ecx, TRACE_FLAG_SYSCALL_EXIT
    call trace_syscall
%endif
%ifdef ENABLE_DEBUG_SERIAL
    ; Validator post-condition recheck (§2, debug build only). If this slot was
    ; armed at dispatch (a fully validated syscall ran), re-read the 6 saved arg
    ; qwords from the still-present PUSH_ALL frame and compare them against the
    ; snapshot taken at validation entry. A handler that mutated its own saved
    ; arg frame mid-syscall (TOCTOU against a value the validator approved) is a
    ; kernel-integrity violation, so route it to the CANARY panic path. Runs
    ; before POP_ALL so [rsp + ALL_*] is the saved frame. rax/rcx/rdx are dead
    ; here (POP_ALL reloads them from the frame), so clobbering them is safe.
    lea rcx, [rel sc_postcond_valid]
    movzx eax, r15b
    cmp byte [rcx + rax], 0
    je .sc_postcond_skip
    mov byte [rcx + rax], 0             ; consume the snapshot
    movzx eax, r15b
    imul eax, eax, 48
    lea rcx, [rel sc_postcond_args]
    add rcx, rax
    mov rax, [rsp + ALL_RDI]
    cmp rax, [rcx + 0]
    jne .sc_postcond_fail
    mov rax, [rsp + ALL_RSI]
    cmp rax, [rcx + 8]
    jne .sc_postcond_fail
    mov rax, [rsp + ALL_RDX]
    cmp rax, [rcx + 16]
    jne .sc_postcond_fail
    mov rax, [rsp + ALL_R10]
    cmp rax, [rcx + 24]
    jne .sc_postcond_fail
    mov rax, [rsp + ALL_R8]
    cmp rax, [rcx + 32]
    jne .sc_postcond_fail
    mov rax, [rsp + ALL_R9]
    cmp rax, [rcx + 40]
    jne .sc_postcond_fail
    jmp .sc_postcond_skip
.sc_postcond_fail:
    mov rdi, rax                        ; observed (mutated) saved arg value
    lea rsi, [rel .sc_postcond_fail]
    jmp kernel_panic_canary
.sc_postcond_skip:
%endif
    POP_ALL
    ; Stack canary check before SYSRET. Layout after POP_ALL:
    ;   [rsp+0]  = slot id, [rsp+8] = canary, [rsp+16] = alignment pad.
    mov r10, [rsp + 8]
    cmp r10, [rel kernel_canary]
    jne .done_canary_bad
    mov edx, [rsp]
    cmp edx, MAX_WINDOWS
    jb .slot_ok_return
    xor edx, edx
    jmp .slot_ok_return
.done_canary_bad:
    mov rdi, r10
    lea rsi, [rel .done_canary_bad]
    jmp kernel_panic_canary
.slot_ok_return:
    ; Per-syscall code-segment scrub. Walk the active slot's 512-entry PT and
    ; re-assert manifest-driven W^X on every page: X+!W inside
    ; [code_start, code_end), W+NX everywhere else. Catches any X-bit drift
    ; introduced mid-syscall (JIT alias misuse, transient mappings,
    ; speculative re-mark). l3_apply_wx_policy preserves rax (syscall return)
    ; and rdx (slot id), and flushes the TLB via a CR3 reload before
    ; returning, so the new permissions are in effect on the very first
    ; instruction after SYSRETQ.
    mov edi, edx
    call l3_apply_wx_policy
    ; FS/GS sanitization on the SYSRET exit (security_todo.md §3). SYSRETQ does
    ; NOT reload DS/ES/FS/GS, so the kernel GDT64_DATA_SEG selector loaded at
    ; entry would otherwise stay visible to ring 3. Load the ring-3
    ; GDT64_USER_DATA selector into all four before returning. The macro
    ; clobbers ax, which here is the low half of the rax syscall-return value,
    ; so bracket it with a save/restore — rax (return) and rdx (slot id, still
    ; needed for the runtime-ptr math below) are the only contract regs live,
    ; and rdx is untouched by the selector loads. (Under the optional MSR-scrub
    ; the macro also clobbers rcx/rdx, so save rdx too — rdx is reloaded into
    ; the runtime-ptr math right after.) Done before rcx/r11/rsp are loaded.
    push rax
    push rdx
    SANITIZE_SEG_USER_EXIT
    pop rdx
    pop rax
    imul rdx, L3_RT_SIZE
    lea rcx, [rel l3_runtime]
    add rdx, rcx
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (click-freeze diagnosis): if the user RIP we are about to SYSRET into
    ; is non-canonical, the iretq/sysret would deliver a corrupt ring-3 RIP and
    ; #GP (exactly the observed 0x1F4E...13682C). Flag it HERE — before the bad
    ; sysret — with the slot, the corrupt RIP, the user RSP, and the syscall's
    ; return value (rax) so we know which call's exit path stored garbage. This
    ; only fires on actual corruption (canonical RIPs are silent -> no flood).
    ; rsp is still the kernel syscall stack here, so pushes are safe.
    push rax                              ; preserve syscall return value
    push rcx
    push rdi
    mov rcx, [rdx + L3_RT_USER_RIP]
    mov rax, rcx
    shl rax, 16
    sar rax, 16                           ; sign-extend bit 47 (canonical form)
    cmp rax, rcx
    je .sysret_rip_ok
    SER 'S'
    SER 'R'
    SER 'B'
    SER 'A'
    SER 'D'
    SER ' '
    SER 's'
    mov edi, [rsp + 24]                   ; slot id ([rsp] after 3 pushes = original [rsp])
    call ser_print_hex64
    SER ' '
    SER 'p'
    mov rdi, [rdx + L3_RT_USER_RIP]
    call ser_print_hex64
    SER ' '
    SER 'u'
    mov rdi, [rdx + L3_RT_USER_RSP]
    call ser_print_hex64
    SER ' '
    SER 'a'
    mov rdi, [rsp + 16]                   ; preserved rax (syscall return value)
    call ser_print_hex64
    SER 13
    SER 10
.sysret_rip_ok:
    pop rdi
    pop rcx
    pop rax
%endif
    mov r10, [rdx + L3_RT_USER_RSP]
    mov rcx, [rdx + L3_RT_USER_RIP]
    mov r11, [rdx + L3_RT_USER_RFLAGS]
    KPTI_SWITCH_TO_USER_CR3 rdx
    mov rsp, r10
    ; Encode SYSRETQ directly to avoid NASM's spurious label-orphan warning.
    db 0x48, 0x0F, 0x07

; Diagnostic: log every SYS_WM_CREATE with calling slot (r15) and drawfn (r9).
; Self-contained, preserves all registers. Prints "[WCREATE] slot=.. dfn=..".
