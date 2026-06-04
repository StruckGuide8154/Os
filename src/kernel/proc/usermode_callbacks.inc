FN_BEGIN call_app_l3_packed, 1, 0, FN_RET_SCALAR
    mov rsi, [rdi + 8]
    mov rdx, [rdi + 16]
    mov rcx, [rdi + 24]
    mov rdi, [rdi + 0]
    call call_app_l3
    FN_END call_app_l3_packed
    ret

; call_app_l3
; RDI = target function
; RSI = arg0 (window ptr)
; RDX = arg1
; RCX = arg2
;
; Note: Stage 2c added the dispatch_app_callback scaffold in process.asm as
; the future chokepoint for ring-3-on-AP routing. Existing call sites still
; invoke call_app_l3 directly (inline path); Stage 2d will replace them with
; dispatch_app_callback once the slot-isolation refactor lands.
FN_DECL call_app_l3, 0, 0, FN_RET_SCALAR
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r13, rdi            ; preserve target
    mov r14, rsi            ; preserve arg0
    mov r15, rdx            ; preserve arg1
    mov rbx, rcx            ; preserve arg2
    xor r11d, r11d

.pick_slot:
    ; Pick slot from per-window app_data arena, not window ID.
    xor eax, eax
    test r14, r14
    jz .slot_ready
    mov rax, [r14 + WIN_OFF_APPDATA]
    sub rax, [rel l3_app_arena_base_v]
    js .slot_zero
    shr rax, 21
    cmp eax, MAX_WINDOWS
    jb .slot_ready
.slot_zero:
    xor eax, eax
.slot_ready:
    mov r11d, eax
    mov edi, r11d
    call l3_runtime_ptr
    mov r12, rax

    mov [r12 + L3_RT_ENTRY], r13
    mov [r12 + L3_RT_ARG0], r14
    mov [r12 + L3_RT_ARG1], r15
    mov [r12 + L3_RT_ARG2], rbx
    mov [r12 + L3_RT_SLOT], r11
    mov [r12 + L3_RT_KERNEL_RSP], rsp
    pushfq
    pop qword [r12 + L3_RT_KERNEL_RFLAGS]
    mov edi, [r12 + L3_RT_SLOT]
    call l3_slot_base
    mov [r12 + L3_RT_APP_BASE], rax
    mov rdx, L3_SLOT_MAGIC
    mov ecx, [r12 + L3_RT_SLOT]
    cmp [l3_slot_live + rcx*8], rdx
    je .translate_generic
    mov edi, [r12 + L3_RT_SLOT]
    call l3_copy_app_blob_to_slot
.translate_generic:
    mov rdi, r13
    mov rsi, rax
    call l3_translate_target
    mov r13, rax
.target_ready:
    mov [r12 + L3_RT_ENTRY], r13

    ; Ring-3 code cannot dereference the kernel window struct directly.
    ; Build the slot-local shadow once; later callbacks reuse it.
    test r14, r14
    jz .args_ready
    mov rax, [r12 + L3_RT_APP_BASE]
    ; Re-sync the shadow window from the live kernel struct on every call.
    ; Caching it on first use leaves the app reading stale x/y/w/h after the
    ; WM moves or resizes the window (e.g. during drag).
    mov rsi, r14
    mov rdi, rax
    add rdi, L3_SHADOW_WIN_OFF
    mov rcx, WINDOW_STRUCT_SIZE / 8
    cld
    USER_ACCESS_BEGIN
    rep movsq
    mov rax, [r12 + L3_RT_APP_BASE]
    mov [rdi - WINDOW_STRUCT_SIZE + WIN_OFF_APPDATA], rax
    USER_ACCESS_END
.shadow_ready:
    mov rax, [r12 + L3_RT_APP_BASE]
    lea r14, [rax + L3_SHADOW_WIN_OFF]
    mov [r12 + L3_RT_ARG0], r14
.args_ready:
%ifdef ENABLE_L3_CALL_TRACE
    ; Per-call entry trace. Off by default: at one call per window message it
    ; floods COM1 and the busy-wait OUT-0x3F8 stalls the render loop enough to
    ; freeze the cursor. Re-enable with -dENABLE_L3_CALL_TRACE when needed.
    SER 'U'
    mov rdi, r13
    call ser_print_hex64
    SER '@'
    mov rdi, r14
    call ser_print_hex64
    SER ':'
    mov rdi, r15
    call ser_print_hex64
    SER ':'
    mov rdi, rbx
    call ser_print_hex64
    SER 13
    SER 10
%endif

    ; Restrict the arena so only this slot's pages are ring-3 accessible.
    mov edi, [r12 + L3_RT_SLOT]
    call l3_apply_slot_isolation
    mov edi, [r12 + L3_RT_SLOT]
    call l3_apply_wx_policy

    mov edi, [r12 + L3_RT_SLOT]
    call l3_user_stack_top
    sub rax, 8
    push rax
    mov edi, [r12 + L3_RT_SLOT]
    call l3_install_app_done_trampoline
    mov rdx, rax
    pop rax
    USER_ACCESS_BEGIN
    mov [rax], rdx                ; IRET trampoline onto the slot's user stack (PTE.U=1)
    USER_ACCESS_END
    mov [r12 + L3_RT_USER_RSP], rax

    ; FS/GS sanitization (security_todo.md ??3). As in enter_usermode: IRETQ
    ; does not reload DS/ES/FS/GS, so install ring-3 selectors before the iret
    ; frame is built and the callback arg registers (rdi/rsi/rdx) are loaded.
    ; Clobbers ax (and, under the optional MSR scrub, rcx/rdx) ??? done BEFORE the
    ; rdi/rsi/rdx arg loads below so none of them are corrupted. r12/r13/r14/r15
    ; and rbx (callback ptr/args) survive.
    SANITIZE_SEG_USER_EXIT
    push qword GDT64_USER_DATA
    push qword [r12 + L3_RT_USER_RSP]
    pushfq
    pop rax
    and rax, ~0x300
    push rax
    push qword GDT64_USER_CODE
    push r13
    mov rdi, r14
    mov rsi, r15
    mov rdx, rbx
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (click-freeze diagnosis): a ring-3 #GP with a corrupt RIP fired
    ; *inside* a callback (dispatch_app_callback never returned). It is either a
    ; bad iretq target or a clobbered return trampoline the handler `ret`s into.
    ; Dump, for EVERY callback right before iretq: the slot, the iretq target RIP
    ; (r13), the user RSP iretq will load, and the return-trampoline qword sitting
    ; at [user RSP]. Floods on draw, but the LAST line before the X-dump is the
    ; offending callback. Reads the user stack under kernel CR3 (KPTI not yet
    ; switched) via USER_ACCESS. Preserves the callback arg regs (rdi/rsi/rdx),
    ; rax (dead here but cheap), and the 5-qword iret frame already on the stack.
    push rax
    push rdi
    push rsi
    push rdx
    SER 'L'
    SER '3'
    SER 'I'
    SER ' '
    SER 's'
    mov edi, [r12 + L3_RT_SLOT]     ; slot
    call ser_print_hex64
    SER ' '
    SER 't'
    mov rdi, r13                    ; iretq target (translated callback entry)
    call ser_print_hex64
    SER ' '
    SER 'u'
    mov rdi, [r12 + L3_RT_USER_RSP] ; user RSP iretq will load
    call ser_print_hex64
    SER ' '
    SER 'r'
    mov rsi, [r12 + L3_RT_USER_RSP]
    USER_ACCESS_BEGIN
    mov rdi, [rsi]                  ; return trampoline addr the handler will ret to
    USER_ACCESS_END
    call ser_print_hex64
    SER 13
    SER 10
    pop rdx
    pop rsi
    pop rdi
    pop rax
%endif
    ; KPTI (security_todo.md ??3): swap to the user-view PML4 before the iretq
    ; into the ring-3 callback. No-op unless -dENABLE_KPTI AND armed. rax is
    ; dead (its RFLAGS value was pushed above); rdi/rsi/rdx (the callback args)
    ; and r12..r15/rbx survive. Same LIVE-path caveat as enter_usermode: the
    ; iret frame's stack must be in the trampoline window once KPTI is armed.
    KPTI_SWITCH_TO_USER_CR3 rax
    iretq

call_app_l3_app_done:
    mov ax, GDT64_USER_DATA
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    ; RAW syscall number (NOT APP_SYSNO): this trampoline is kernel-resident
    ; code that runs in ring 3 at a kernel VA, outside the per-slot copied app
    ; blob, so its immediate is never rewritten by the loader. The dispatcher
    ; attributes a syscall from outside the arena to slot 0, whose permutation
    ; is the identity (sc_slot_perm_generate), so raw 10 == real SYS_APP_DONE.
    mov eax, 10                          ; SYS_APP_DONE
    syscall
    ud2

FN_DECL call_app_l3_return, 0, 0, FN_RET_SCALAR
    mov eax, [rsp]
    cmp eax, MAX_WINDOWS
    jb .ret_slot_ready
    xor eax, eax
.ret_slot_ready:
    mov edi, eax
    call l3_runtime_ptr
    mov r12, rax
    mov r10, [r12 + L3_RT_KERNEL_RSP]
%ifdef ENABLE_L3_CALL_TRACE
    ; Paired with the entry trace above; same rationale for being opt-in.
    SER 'R'
    mov rdi, [r12 + L3_RT_KERNEL_RSP]
    call ser_print_hex64
    SER ':'
    mov rdi, rbp
    call ser_print_hex64
    SER ':'
    mov rdi, rbx
    call ser_print_hex64
    SER ':'
    mov rdi, r14
    call ser_print_hex64
    SER ':'
    mov rdi, r15
    call ser_print_hex64
    SER 13
    SER 10
%endif
    mov rsp, [r12 + L3_RT_KERNEL_RSP]
    push qword [r12 + L3_RT_KERNEL_RFLAGS]
    popfq

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; --- Dummy usermode code for testing ---
; auto-wrapped (FN_BEGIN emits global): global test_usermode_proc
FN_BEGIN test_usermode_proc, 0, 0, FN_RET_SCALAR
    jmp $

l3_test_blob:
    lea rdi, [rel .msg]
    ; RAW syscall number (NOT APP_SYSNO): dummy kernel-resident test blob, not
    ; part of the per-slot copied app blob, so its immediate must stay raw
    ; (slot-0 identity path). See call_app_l3_app_done above.
    mov eax, 0                           ; SYS_PRINT
    syscall
    ret
.msg:
    db "L3 test callback ok", 0
l3_test_blob_end:
