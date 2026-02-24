; ============================================================================
; NexusOS v3.0 - Render Engine (SSE2 Optimized)
; Dirty rectangle tracking and wrappers for display driver
; ============================================================================
bits 64

%include "constants.inc"

MAX_DIRTY_RECTS equ 32

section .text

; Import from display driver
extern display_flip_rect
extern display_flip
extern fill_rect
extern draw_string
extern draw_hline
extern draw_vline
extern display_clear
extern bb_addr

; Export to GUI
global render_init
global render_rect
global render_text
global render_line
global render_get_backbuffer
global render_mark_dirty
global render_mark_full
global render_flush

; --- Initialize render system ---
render_init:
    mov dword [dirty_count], 0
    mov byte [full_redraw], 1    ; First frame: full redraw
    ret

; --- Wrappers ---
render_rect:
    jmp fill_rect

render_text:
    jmp draw_string

render_line:
    ret

render_get_backbuffer:
    mov rax, [bb_addr]
    ret

; --- Mark a rectangle as dirty ---
; EDI = x, ESI = y, EDX = w, ECX = h
render_mark_dirty:
    push rax

    ; If too many dirty rects, just do full redraw
    mov eax, [dirty_count]
    cmp eax, MAX_DIRTY_RECTS
    jge .mark_full

    ; Store dirty rect
    shl eax, 4              ; * 16 bytes per rect
    lea rax, [dirty_rects + rax]
    mov [rax], edi           ; x
    mov [rax + 4], esi       ; y
    mov [rax + 8], edx       ; w
    mov [rax + 12], ecx      ; h
    inc dword [dirty_count]
    pop rax
    ret

.mark_full:
    mov byte [full_redraw], 1
    pop rax
    ret

; --- Mark entire screen as dirty ---
render_mark_full:
    mov byte [full_redraw], 1
    ret

; --- Flush dirty rectangles to framebuffer ---
render_flush:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Check if full redraw needed
    cmp byte [full_redraw], 0
    jne .do_full

    ; Flip each dirty rectangle
    mov ebx, [dirty_count]
    test ebx, ebx
    jz .flush_done

    xor eax, eax            ; Index
.flush_loop:
    cmp eax, ebx
    jge .flush_done

    push rax
    shl eax, 4
    lea r8, [dirty_rects + rax]
    mov edi, [r8]
    mov esi, [r8 + 4]
    mov edx, [r8 + 8]
    mov ecx, [r8 + 12]
    call display_flip_rect
    pop rax

    inc eax
    jmp .flush_loop

.do_full:
    call display_flip
    mov byte [full_redraw], 0

.flush_done:
    ; Reset dirty count
    mov dword [dirty_count], 0

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Save back buffer (RAM -> RAM) SSE2 optimized, 128 bytes/iteration ---
global render_save_backbuffer
render_save_backbuffer:
    push rdi
    push rsi
    push rcx
    push rax

    mov rdi, BACK_BUFFER_SAVE_ADDR
    mov rsi, [bb_addr]
    mov ecx, FRAMEBUFFER_SIZE  ; 3MB in bytes

    ; SSE2 copy: 128 bytes per iteration (8x movdqa load, 8x movdqa store)
    shr ecx, 7                ; / 128
.save_loop:
    movdqa xmm0, [rsi]
    movdqa xmm1, [rsi + 16]
    movdqa xmm2, [rsi + 32]
    movdqa xmm3, [rsi + 48]
    movdqa xmm4, [rsi + 64]
    movdqa xmm5, [rsi + 80]
    movdqa xmm6, [rsi + 96]
    movdqa xmm7, [rsi + 112]
    movdqa [rdi], xmm0
    movdqa [rdi + 16], xmm1
    movdqa [rdi + 32], xmm2
    movdqa [rdi + 48], xmm3
    movdqa [rdi + 64], xmm4
    movdqa [rdi + 80], xmm5
    movdqa [rdi + 96], xmm6
    movdqa [rdi + 112], xmm7
    add rsi, 128
    add rdi, 128
    dec ecx
    jnz .save_loop

    ; Handle remainder (FRAMEBUFFER_SIZE % 128)
    mov ecx, FRAMEBUFFER_SIZE
    and ecx, 127
    shr ecx, 3
    rep movsq

    pop rax
    pop rcx
    pop rsi
    pop rdi
    ret

; --- Restore back buffer (RAM -> RAM) SSE2 optimized, 128 bytes/iteration ---
global render_restore_backbuffer
render_restore_backbuffer:
    push rdi
    push rsi
    push rcx
    push rax

    mov rdi, [bb_addr]
    mov rsi, BACK_BUFFER_SAVE_ADDR
    mov ecx, FRAMEBUFFER_SIZE

    ; SSE2 copy: 128 bytes per iteration
    shr ecx, 7                ; / 128
.restore_loop:
    movdqa xmm0, [rsi]
    movdqa xmm1, [rsi + 16]
    movdqa xmm2, [rsi + 32]
    movdqa xmm3, [rsi + 48]
    movdqa xmm4, [rsi + 64]
    movdqa xmm5, [rsi + 80]
    movdqa xmm6, [rsi + 96]
    movdqa xmm7, [rsi + 112]
    movdqa [rdi], xmm0
    movdqa [rdi + 16], xmm1
    movdqa [rdi + 32], xmm2
    movdqa [rdi + 48], xmm3
    movdqa [rdi + 64], xmm4
    movdqa [rdi + 80], xmm5
    movdqa [rdi + 96], xmm6
    movdqa [rdi + 112], xmm7
    add rsi, 128
    add rdi, 128
    dec ecx
    jnz .restore_loop

    ; Remainder
    mov ecx, FRAMEBUFFER_SIZE
    and ecx, 127
    shr ecx, 3
    rep movsq

    pop rax
    pop rcx
    pop rsi
    pop rdi
    ret

section .data
dirty_count:    dd 0
full_redraw:    db 1

section .bss
dirty_rects:    resb (MAX_DIRTY_RECTS * 16)
