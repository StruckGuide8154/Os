; ============================================================================
; debug_events.asm - structured forensic event ring and panic dumper
; ============================================================================

%include "debug_events.inc"

section .text

global dbg_event_emit6
dbg_event_emit6:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov eax, 1
    lock xadd qword [rel dbg_evt_head], rax
    mov rbx, rax
    mov r10, rax
    and r10, DBG_EVT_MASK
    imul r10, DBG_EVT_RECORD_SIZE
    lea r11, [rel dbg_evt_ring]
    add r10, r11
    mov [r10 + DBG_EVT_SEQ], rbx
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [r10 + DBG_EVT_TSC], rax
    mov r11, [rsp + 32]                 ; original rdi = event id
    mov [r10 + DBG_EVT_ID], r11
    mov r11, [rsp + 40]                 ; original rsi = slot/context
    mov [r10 + DBG_EVT_SLOT], r11
    mov r11, [rsp + 48]                 ; original rdx = a0
    mov [r10 + DBG_EVT_A0], r11
    mov r11, [rsp + 56]                 ; original rcx = a1
    mov [r10 + DBG_EVT_A1], r11
    mov r11, [rsp + 16]                 ; original r8 = a2
    mov [r10 + DBG_EVT_A2], r11
    mov r11, [rsp + 8]                  ; original r9 = a3
    mov [r10 + DBG_EVT_A3], r11
    mov qword [r10 + DBG_EVT_A4], 0
    mov qword [r10 + DBG_EVT_A5], 0
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

global dbg_event_dump_serial
dbg_event_dump_serial:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    call .crlf
    mov al, 'D'
    call .putc
    mov al, 'E'
    call .putc
    mov al, 'V'
    call .putc
    mov al, 'T'
    call .putc
    mov al, ' '
    call .putc
    mov rdi, [rel dbg_evt_head]
    call .hex64
    call .crlf

    mov rax, [rel dbg_evt_head]
    cmp rax, DBG_EVT_RECORDS
    jae .have_start
    xor r8, r8
    jmp .start_ready
.have_start:
    mov r8, rax
    sub r8, DBG_EVT_RECORDS
.start_ready:
    mov r9, [rel dbg_evt_head]
.dump_loop:
    cmp r8, r9
    jae .done
    mov r10, r8
    and r10, DBG_EVT_MASK
    imul r10, DBG_EVT_RECORD_SIZE
    lea r10, [abs dbg_evt_ring + r10]
    cmp qword [r10 + DBG_EVT_ID], 0
    je .next

    mov al, 'E'
    call .putc
    mov al, ' '
    call .putc
    mov rdi, [r10 + DBG_EVT_SEQ]
    call .hex64
    mov al, ' '
    call .putc
    mov rdi, [r10 + DBG_EVT_ID]
    call .hex64
    mov al, ' '
    call .putc
    mov rdi, [r10 + DBG_EVT_SLOT]
    call .hex64
    mov al, ' '
    call .putc
    mov rdi, [r10 + DBG_EVT_A0]
    call .hex64
    mov al, '/'
    call .putc
    mov rdi, [r10 + DBG_EVT_A1]
    call .hex64
    mov al, '/'
    call .putc
    mov rdi, [r10 + DBG_EVT_A2]
    call .hex64
    mov al, '/'
    call .putc
    mov rdi, [r10 + DBG_EVT_A3]
    call .hex64
    mov al, '/'
    call .putc
    mov rdi, [r10 + DBG_EVT_A4]
    call .hex64
    mov al, '/'
    call .putc
    mov rdi, [r10 + DBG_EVT_A5]
    call .hex64
    call .crlf
.next:
    inc r8
    jmp .dump_loop

.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.putc:
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    ret

.crlf:
    mov al, 13
    call .putc
    mov al, 10
    call .putc
    ret

.hex64:
    push rax
    push rcx
    push rdx
    mov rcx, 16
.hex_loop:
    rol rdi, 4
    mov al, dil
    and al, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - '0' - 10
.digit:
    add al, '0'
    mov dx, 0x3F8
    out dx, al
    loop .hex_loop
    pop rdx
    pop rcx
    pop rax
    ret

section .bss
alignb 16
global dbg_evt_head
global dbg_evt_ring
dbg_evt_head: resq 1
dbg_evt_ring: resb DBG_EVT_RECORD_SIZE * DBG_EVT_RECORDS
