; ============================================================================
; GritOS v3.0 - Append-only trace ring with parent-hash causal chain
; ============================================================================
bits 64

%include "macros.inc"
%include "trace.inc"

TRACE_RECORD_SIZE     equ 32
TRACE_RING_RECORDS    equ 2048
TRACE_RING_MASK       equ TRACE_RING_RECORDS - 1
TRACE_DUMP_RECORDS    equ 64
TRACE_MAX_SLOTS       equ 256
TRACE_STACK_DEPTH     equ 16

section .text

extern ser_print_hex64
extern debug_print

; ----------------------------------------------------------------------------
; trace_fn_enter - called from FN_BEGIN
;   EDI = fn_id (32-bit), ESI = slot
; Pushes parent on per-slot stack, sets current_fn[slot] = fn_id, emits ENTER.
; ----------------------------------------------------------------------------
global trace_fn_enter
trace_fn_enter:
%ifndef ENABLE_TRACE
    ret
%else
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    movzx r10d, sil
    and r10d, TRACE_MAX_SLOTS - 1
    lea rbx, [rel trace_current_fn]
    mov r8, [rbx + r10 * 8]                 ; r8 = old parent
    mov eax, edi
    mov [rbx + r10 * 8], rax                ; current_fn[slot] = new fn_id
    lea rbx, [rel trace_current_depth]
    movzx ecx, byte [rbx + r10]
    cmp ecx, TRACE_STACK_DEPTH
    jae .depth_saturated
    lea rdx, [rel trace_parent_stack]
    mov eax, r10d
    shl rax, 7                              ; slot * 16 entries * 8 = 128
    add rdx, rax
    mov [rdx + rcx * 8], r8                 ; parent_stack[slot][depth] = old parent
    inc byte [rbx + r10]
.depth_saturated:
    mov ecx, edi                            ; arg0 = fn_id (placeholder for first param)
    mov edx, TRACE_FLAG_ENTER
    mov r9, r8                              ; parent_hash
    call trace_emit
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
%endif

; ----------------------------------------------------------------------------
; trace_fn_exit - called from FN_END
;   EDI = fn_id, ESI = slot, RDX = retval
; Pops parent stack into current_fn[slot]; emits EXIT with retval.
; ----------------------------------------------------------------------------
global trace_fn_exit
trace_fn_exit:
%ifndef ENABLE_TRACE
    ret
%else
    push rax
    push rbx
    push rcx
    push r8
    push r9
    push r10
    push r11
    movzx r10d, sil
    and r10d, TRACE_MAX_SLOTS - 1
    mov r11, rdx                            ; r11 = retval
    lea rbx, [rel trace_current_depth]
    movzx ecx, byte [rbx + r10]
    test ecx, ecx
    jz .no_parent
    dec ecx
    mov [rbx + r10], cl
    lea rax, [rel trace_parent_stack]
    mov r8d, r10d
    shl r8, 7
    add rax, r8
    mov r9, [rax + rcx * 8]                 ; r9 = restored parent
    lea rbx, [rel trace_current_fn]
    mov [rbx + r10 * 8], r9
    jmp .have_parent
.no_parent:
    xor r9, r9
    lea rbx, [rel trace_current_fn]
    mov qword [rbx + r10 * 8], 0
.have_parent:
    mov rcx, r11                            ; arg0 slot holds retval
    mov edx, TRACE_FLAG_EXIT
    call trace_emit
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    pop rax
    ret
%endif

; ----------------------------------------------------------------------------
; trace_syscall - emit a syscall enter/exit record explicitly.
;   EDI = syscall number, ESI = slot, EDX = flags, RCX = arg0/return
; ----------------------------------------------------------------------------
global trace_syscall
trace_syscall:
%ifndef ENABLE_TRACE
    ret
%else
    push rax
    push rbx
    push r8
    push r9
    movzx ebx, sil
    and ebx, TRACE_MAX_SLOTS - 1
    lea r8, [rel trace_current_fn]
    mov r9, [r8 + rbx * 8]                  ; parent = current fn for this slot
    call trace_emit
    pop r9
    pop r8
    pop rbx
    pop rax
    ret
%endif

; ----------------------------------------------------------------------------
; trace_emit
;   EDI = fn_id, ESI = slot, EDX = flags, RCX = arg0/result, R9 = parent_hash
; Reserves a sequence number with `lock xadd` and writes the record at
; ring[seq mod RECORDS]. Lock-free for concurrent writers.
; ----------------------------------------------------------------------------
global trace_emit
trace_emit:
%ifndef ENABLE_TRACE
    ret
%else
    push rax
    push rbx
    mov eax, 1
    lock xadd qword [rel trace_seq], rax    ; rax = pre-increment seq
    mov rbx, rax
    and ebx, TRACE_RING_MASK
    shl rbx, 5                              ; record size = 32
    lea r8, [rel trace_ring]
    add rbx, r8
    mov [rbx + 0], edi                      ; fn_id
    mov [rbx + 4], si                       ; slot
    mov [rbx + 6], dx                       ; flags
    mov [rbx + 8], rcx                      ; arg0 / retval
    mov [rbx + 16], r9                      ; parent_hash
    mov [rbx + 24], rax                     ; seq
    pop rbx
    pop rax
    ret
%endif

; ----------------------------------------------------------------------------
; trace_dump_serial - dump last TRACE_DUMP_RECORDS records to COM1.
; Format per line: "#<seq> F<fn_id>:<flags>:<arg>:<parent>"
; ----------------------------------------------------------------------------
global trace_dump_serial
trace_dump_serial:
%ifndef ENABLE_TRACE
    ret
%else
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    SER 'T'
    SER 'R'
    SER 13
    SER 10
    mov rax, [rel trace_seq]
    cmp rax, TRACE_DUMP_RECORDS
    jae .have_start
    xor rax, rax
    jmp .start_ok
.have_start:
    sub rax, TRACE_DUMP_RECORDS
.start_ok:
    mov rcx, TRACE_DUMP_RECORDS
.dump_loop:
    push rax
    push rcx
    mov rbx, rax
    and ebx, TRACE_RING_MASK
    shl rbx, 5
    lea rdx, [rel trace_ring]
    add rbx, rdx
    SER '#'
    mov rdi, [rbx + 24]
    call ser_print_hex64
    SER ' '
    SER 'F'
    mov edi, [rbx + 0]
    call ser_print_hex64
    SER ':'
    movzx edi, word [rbx + 6]
    call ser_print_hex64
    SER ':'
    mov rdi, [rbx + 8]
    call ser_print_hex64
    SER ':'
    mov rdi, [rbx + 16]
    call ser_print_hex64
    SER 13
    SER 10
    pop rcx
    pop rax
    inc rax
    dec rcx
    jnz .dump_loop
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
%endif

global trace_dump_screen
trace_dump_screen:
%ifndef ENABLE_TRACE
    ret
%else
    push rsi
    lea rsi, [rel trace_screen_msg]
    call debug_print
    pop rsi
    ret
%endif

; ----------------------------------------------------------------------------
; trace_set_slot - set the global active slot used by FN_BEGIN/FN_END.
; Called by syscall entry / scheduler when switching contexts.
;   EDI = slot
; ----------------------------------------------------------------------------
global trace_set_slot
trace_set_slot:
    mov [rel trace_active_slot], dil
    ret

section .data
trace_screen_msg: db "TRACE: last records sent to serial", 0

section .bss
alignb 8
global trace_seq
trace_seq:           resq 1
global trace_active_slot
trace_active_slot:   resb 1
alignb 8
trace_current_fn:    resq TRACE_MAX_SLOTS
trace_parent_stack:  resq TRACE_MAX_SLOTS * TRACE_STACK_DEPTH
trace_current_depth: resb TRACE_MAX_SLOTS
alignb 16
trace_ring:          resb TRACE_RECORD_SIZE * TRACE_RING_RECORDS
