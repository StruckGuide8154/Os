; ============================================================================
; Grit v3.0 - Function signature and trace macros
; ============================================================================

%ifndef TRACE_INC
%define TRACE_INC

FN_KIND_SCALAR  equ 0
FN_KIND_PTR     equ 1
FN_KIND_CSTRING equ 2
FN_KIND_HANDLE  equ 3

FN_RET_VOID     equ 0
FN_RET_SCALAR   equ 1
FN_RET_PTR      equ 2
FN_RET_HANDLE   equ 3

TRACE_FLAG_ENTER         equ 1
TRACE_FLAG_EXIT          equ 2
TRACE_FLAG_SYSCALL_ENTER equ 4
TRACE_FLAG_SYSCALL_EXIT  equ 8
TRACE_FLAG_VALIDATE_FAIL equ 16

; FN_BEGIN emits a normal function label plus machine-readable metadata.
; Slot is read from the global trace_active_slot (set by syscall entry).
; All caller-saved registers are preserved so this is safe to drop into
; ISR/IRQ landing pads as well as ordinary kernel functions.
%macro FN_BEGIN 4
%define __fn_prev_section __?SECT?__
    global %1
%1:
%assign %{1}__argc %2
%assign %{1}__kindmask %3
%assign %{1}__retkind %4
%ifdef ENABLE_SIG_SECTION
    [section .signature]
%{1}__sigmeta:
%ifdef %{1}__hash
    dq %{1}__hash
%else
    dq 0
%endif
    db %2
    dd %3
    db %4
    dd __LINE__
    dq %{1}__name
%{1}__name:
    db %str(%1), 0
    __fn_prev_section
%endif
%ifdef ENABLE_TRACE
%ifndef DISABLE_FN_RUNTIME_TRACE
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
%ifdef %{1}__hash32
    mov edi, %{1}__hash32
%else
    mov edi, %1
%endif
    movzx esi, byte [rel trace_active_slot]
    call trace_fn_enter
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endif
%endif
%endmacro

; FN_ARG is intentionally doc-only for now. The registry builder reads source
; FN_ARG lines and attaches arg names/kinds to the JSON sidecar.
%macro FN_ARG 3
%endmacro

%macro FN_END 1
%ifdef ENABLE_TRACE
%ifndef DISABLE_FN_RUNTIME_TRACE
    push rax                        ; preserve retval at top of save area
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
%ifdef %{1}__hash32
    mov edi, %{1}__hash32
%else
    mov edi, %1
%endif
    movzx esi, byte [rel trace_active_slot]
    mov rdx, [rsp + 8*8]            ; saved RAX (retval) sits 8 qwords below top
    call trace_fn_exit
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endif
%endif
%endmacro

%macro FN_CALL 2
%ifdef %{1}__argc
    %if %{1}__argc != %2
        %error "FN_CALL argc mismatch"
    %endif
%endif
    call %1
%endmacro

%macro FN_BEGIN_FULL 4
    FN_BEGIN %1, %2, %3, %4
%endmacro

; Lightweight: declares signature only, no runtime trace (use in ISR/IRQ
; landing pads where calling helpers before the iretq frame is unsafe).
%macro FN_DECL 4
    global %1
%1:
%assign %{1}__argc %2
%assign %{1}__kindmask %3
%assign %{1}__retkind %4
%ifdef ENABLE_SIG_SECTION
    [section .signature]
%{1}__sigmeta_decl:
%ifdef %{1}__hash
    dq %{1}__hash
%else
    dq 0
%endif
    db %2
    dd %3
    db %4
    dd __LINE__
    dq %{1}__name_decl
%{1}__name_decl:
    db %str(%1), 0
    __SECT__
%endif
%endmacro

%endif
