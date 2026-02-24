; ============================================================================
; NexusOS v3.0 - Mouse Cursor Rendering
; Draws cursor to front buffer, saves/restores background
; ============================================================================
bits 64

%include "constants.inc"

section .text

extern fb_addr, bb_addr, scr_width, scr_height, scr_pitch

; --- Initialize cursor ---
global cursor_init
cursor_init:
    mov dword [cursor_old_x], -1
    mov dword [cursor_old_y], -1
    mov byte [cursor_visible], 0
    ret

; --- Restore background under cursor from saved data (optimized) ---
; Uses precomputed row pointer instead of per-pixel imul
global cursor_hide
cursor_hide:
    cmp byte [cursor_visible], 0
    je .hide_done

    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12

    mov r8d, [cursor_old_x]   ; base x
    mov r9d, [cursor_old_y]   ; base y (current row y)
    mov r10, [fb_addr]
    lea r11, [cursor_bg_save]  ; save buffer pointer
    mov r12d, [cursor_save_h]  ; rows remaining
    movsxd rbx, dword [scr_pitch]

    ; Compute initial row pointer: r10 = fb_addr + y * pitch
    mov eax, r9d
    cmp eax, 0
    jge .rh_y_ok
    ; y < 0: skip negative rows
    neg eax
    cmp eax, r12d
    jge .restore_done
    sub r12d, eax
    mov ecx, [cursor_save_w]
    imul ecx, eax
    lea r11, [r11 + rcx*4]    ; advance save ptr
    xor r9d, r9d              ; y = 0
    xor eax, eax
.rh_y_ok:
    imul rax, rbx              ; y * pitch
    add r10, rax               ; r10 = row base in framebuffer

.restore_row:
    cmp r12d, 0
    jle .restore_done
    cmp r9d, [scr_height]
    jge .restore_done

    mov ecx, [cursor_save_w]  ; columns this row
    mov edx, r8d               ; current x = base x

.restore_col:
    test ecx, ecx
    jz .restore_next_row
    cmp edx, 0
    jl .rh_skip_pix
    cmp edx, [scr_width]
    jge .rh_skip_rest

    ; Write saved pixel: fb[row_base + x*4] = saved
    mov eax, [r11]
    mov [r10 + rdx*4], eax

.rh_skip_pix:
    add r11, 4
    inc edx
    dec ecx
    jmp .restore_col

.rh_skip_rest:
    ; Skip remaining save buffer entries for this row
    lea r11, [r11 + rcx*4]

.restore_next_row:
    add r10, rbx              ; next row (add pitch)
    inc r9d
    dec r12d
    jmp .restore_row

.restore_done:
    mov byte [cursor_visible], 0
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax

.hide_done:
    ret

; --- Update cursor position ---
; EDI = new x, ESI = new y
global cursor_update
cursor_update:
    call cursor_hide
    call cursor_draw
    ret

; --- Simpler cursor draw: directly plot pixels ---
; EDI = x, ESI = y - draws a standard arrow cursor (or move cursor if cursor_mode=1)
global cursor_draw
cursor_draw:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    cmp byte [cursor_mode], 1
    je .draw_move_cursor

    mov [cursor_old_x], edi
    mov [cursor_old_y], esi
    mov byte [cursor_visible], 1
    mov dword [cursor_save_w], CURSOR_WIDTH
    mov dword [cursor_save_h], CURSOR_HEIGHT

    mov r12d, edi            ; base x
    mov r13d, esi            ; base y

    ; --- Save background from back buffer using row pointers ---
    mov r8, [bb_addr]
    lea r9, [cursor_bg_save]
    movsxd rbx, dword [scr_pitch]

    ; Compute initial row pointer for save
    mov eax, r13d
    cmp eax, 0
    jge .s_y_ok
    xor eax, eax             ; clamp to 0 for pointer calc
.s_y_ok:
    imul rax, rbx
    lea r8, [r8 + rax]       ; r8 = bb_addr + y*pitch (row pointer)

    xor r10d, r10d           ; row
.s_row:
    cmp r10d, CURSOR_HEIGHT
    jge .s_done
    mov eax, r13d
    add eax, r10d            ; screen y for this row
    cmp eax, 0
    jl .s_skip_row
    cmp eax, [scr_height]
    jge .s_skip_row

    xor r11d, r11d           ; col
.s_col:
    cmp r11d, CURSOR_WIDTH
    jge .s_nrow
    mov ecx, r12d
    add ecx, r11d            ; screen x
    cmp ecx, 0
    jl .s_skip_pix
    cmp ecx, [scr_width]
    jge .s_skip_pix
    ; Read pixel using row pointer + x*4
    mov eax, [r8 + rcx*4]
    mov [r9], eax
    jmp .s_next
.s_skip_pix:
    mov dword [r9], 0
.s_next:
    add r9, 4
    inc r11d
    jmp .s_col

.s_skip_row:
    ; Fill entire row in save buffer with 0
    mov ecx, CURSOR_WIDTH
.s_skip_fill:
    mov dword [r9], 0
    add r9, 4
    dec ecx
    jnz .s_skip_fill
    jmp .s_advance

.s_nrow:
.s_advance:
    add r8, rbx              ; next row pointer (rbx = pitch, must not be clobbered)
    inc r10d
    jmp .s_row
.s_done:

    ; --- Draw cursor using shape table with row pointers ---
    mov r8, [fb_addr]
    movsxd rbx, dword [scr_pitch]

    ; Compute initial row pointer for draw
    mov eax, r13d
    cmp eax, 0
    jge .d_y_ok
    xor eax, eax
.d_y_ok:
    imul rax, rbx
    lea r8, [r8 + rax]       ; r8 = fb_addr + y*pitch

    lea r9, [cursor_shape]
    xor r10d, r10d           ; row index
.d_row:
    cmp r10d, CURSOR_HEIGHT
    jge .d_done
    mov eax, r13d
    add eax, r10d            ; screen y
    cmp eax, 0
    jl .d_nrow
    cmp eax, [scr_height]
    jge .d_done

    movzx eax, byte [r9 + r10]   ; Width of this row
    xor r11d, r11d           ; col
.d_col:
    cmp r11d, eax
    jge .d_nrow

    mov edx, r12d
    add edx, r11d            ; screen x
    cmp edx, 0
    jl .d_ncol
    cmp edx, [scr_width]
    jge .d_ncol

    ; Determine color: edge pixels = black, inner = white
    mov ecx, 0x00FFFFFF      ; Default white
    cmp r11d, 0
    je .d_black
    push rax
    dec eax
    cmp r11d, eax
    pop rax
    je .d_black
    cmp r10d, 0
    je .d_black
    cmp r10d, CURSOR_HEIGHT - 1
    je .d_black
    jmp .d_write
.d_black:
    xor ecx, ecx
.d_write:
    ; Write pixel using row pointer + x*4
    mov [r8 + rdx*4], ecx

.d_ncol:
    inc r11d
    jmp .d_col
.d_nrow:
    add r8, rbx              ; next row pointer
    inc r10d
    jmp .d_row
.d_done:
    jmp .cursor_ret

; --- Move cursor (cross) drawing ---
.draw_move_cursor:
    ; Center the cross at mouse position: draw origin = (x-5, y-5)
    sub edi, 5
    sub esi, 5
    mov [cursor_old_x], edi
    mov [cursor_old_y], esi
    mov byte [cursor_visible], 1
    mov dword [cursor_save_w], MOVE_CURSOR_W
    mov dword [cursor_save_h], MOVE_CURSOR_H

    mov r12d, edi            ; base x
    mov r13d, esi            ; base y

    ; --- Save background ---
    mov r8, [bb_addr]
    lea r9, [cursor_bg_save]
    
    xor r10d, r10d           ; row index
.ms_row:
    cmp r10d, MOVE_CURSOR_H
    jge .ms_done

    ; Calculate screen Y
    mov eax, r13d
    add eax, r10d
    ; Check Y bounds
    cmp eax, 0
    jl .ms_skip_entire_row
    cmp eax, [scr_height]
    jge .ms_skip_entire_row

    ; Calculate Row Pointer: bb_addr + screen_y * pitch
    imul eax, dword [scr_pitch]
    lea r14, [r8 + rax]      ; Row pointer

    xor r11d, r11d           ; col index
.ms_col:
    cmp r11d, MOVE_CURSOR_W
    jge .ms_next_row

    ; Calculate screen X
    mov ecx, r12d
    add ecx, r11d
    ; Check X bounds
    cmp ecx, 0
    jl .ms_skip_pix
    cmp ecx, [scr_width]
    jge .ms_skip_pix

    ; Read pixel: [row_ptr + x * 4]
    mov eax, [r14 + rcx*4]
    mov [r9], eax
    jmp .ms_advance_pix

.ms_skip_pix:
    mov dword [r9], 0

.ms_advance_pix:
    add r9, 4
    inc r11d
    jmp .ms_col

.ms_skip_entire_row:
    ; Fill row in save buffer with 0
    mov ecx, MOVE_CURSOR_W
.ms_fill_zeros:
    mov dword [r9], 0
    add r9, 4
    dec ecx
    jnz .ms_fill_zeros

.ms_next_row:
    inc r10d
    jmp .ms_row
.ms_done:

    ; --- Draw cursor ---
    mov r8, [fb_addr]        ; Switch to FB for drawing
    lea r9, [cursor_move_shape]
    xor r10d, r10d           ; row
.md_row:
    cmp r10d, MOVE_CURSOR_H
    jge .md_done

    mov eax, r13d
    add eax, r10d
    cmp eax, 0
    jl .md_skip_row_logic
    cmp eax, [scr_height]
    jge .md_done

    ; Row good - compute pointer
    imul eax, dword [scr_pitch]
    lea r14, [r8 + rax]

    xor r11d, r11d           ; col
.md_col:
    cmp r11d, MOVE_CURSOR_W
    jge .md_next_row

    ; Get shape byte
    movzx eax, byte [r9]
    inc r9
    test eax, eax
    jz .md_advance_col_loop

    ; Screen X check
    mov ecx, r12d
    add ecx, r11d
    cmp ecx, 0
    jl .md_advance_col_loop
    cmp ecx, [scr_width]
    jge .md_advance_col_loop

    ; Draw pixel
    cmp eax, 1
    je .md_black
    mov dword [r14 + rcx*4], 0x00FFFFFF
    jmp .md_advance_col_loop
.md_black:
    mov dword [r14 + rcx*4], 0

.md_advance_col_loop:
    inc r11d
    jmp .md_col

.md_next_row:
    inc r10d
    jmp .md_row

.md_skip_row_logic:
    add r9, MOVE_CURSOR_W     ; Skip shape bytes for this row
    inc r10d
    jmp .md_row
.md_done:

.cursor_ret:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .data
cursor_old_x:       dd -1
cursor_old_y:       dd -1
cursor_visible:     db 0
cursor_save_w:      dd CURSOR_WIDTH     ; width of last saved bg
cursor_save_h:      dd CURSOR_HEIGHT    ; height of last saved bg
global cursor_mode
cursor_mode:        db 0            ; 0=normal arrow, 1=move cross

section .rodata
; Cursor shape: width of each row (forms a triangular arrow)
cursor_shape:
    db 1    ; row 0
    db 2    ; row 1
    db 3    ; row 2
    db 4    ; row 3
    db 5    ; row 4
    db 6    ; row 5
    db 7    ; row 6
    db 8    ; row 7
    db 9    ; row 8
    db 10   ; row 9
    db 11   ; row 10
    db 6    ; row 11 (narrowing)
    db 5    ; row 12
    db 4    ; row 13
    db 4    ; row 14
    db 3    ; row 15
    db 3    ; row 16
    db 2    ; row 17
    db 1    ; row 18

; Move cursor shape: 11x11 cross/arrow centered at (5,5)
; Stored as 11 rows x 11 cols, 1=black, 2=white, 0=transparent
cursor_move_shape:
    ;        col: 0  1  2  3  4  5  6  7  8  9 10
    db  0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0   ; row 0: top arrow
    db  0, 0, 0, 0, 1, 2, 1, 0, 0, 0, 0   ; row 1
    db  0, 0, 0, 1, 1, 2, 1, 1, 0, 0, 0   ; row 2
    db  0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0   ; row 3
    db  0, 1, 1, 0, 0, 2, 0, 0, 1, 1, 0   ; row 4
    db  1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1   ; row 5: center horizontal
    db  0, 1, 1, 0, 0, 2, 0, 0, 1, 1, 0   ; row 6
    db  0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0   ; row 7
    db  0, 0, 0, 1, 1, 2, 1, 1, 0, 0, 0   ; row 8
    db  0, 0, 0, 0, 1, 2, 1, 0, 0, 0, 0   ; row 9
    db  0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0   ; row 10: bottom arrow

MOVE_CURSOR_W equ 11
MOVE_CURSOR_H equ 11

section .bss
cursor_bg_save: resb (CURSOR_WIDTH * CURSOR_HEIGHT * 4)  ; Saved background pixels
