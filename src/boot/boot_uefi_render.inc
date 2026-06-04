; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI rectangle and text rendering
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

; fn_fill_rect(x, y, w, h, color) - fills rectangle via GOP Blt VideoFill
; edi=x, esi=y, edx=w, ecx=h, r8d=color(BGRX)
fn_fill_rect:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96          ; stack space for Blt args + shadow

    mov r12d, edi         ; x
    mov r13d, esi         ; y
    mov r14d, edx         ; w
    mov r15d, ecx         ; h
    mov [v_bltpx], r8d    ; store color in blt pixel buffer

    ; GOP->Blt(this, &pixel, EfiBltVideoFill, srcX, srcY, destX, destY, w, h, delta)
    ; Stack params at: [rsp+32]=srcY [rsp+40]=destX [rsp+48]=destY [rsp+56]=w [rsp+64]=h [rsp+72]=delta
    mov qword [rsp+32], 0   ; SourceY = 0
    mov eax, r12d
    mov [rsp+40], rax        ; DestinationX
    mov eax, r13d
    mov [rsp+48], rax        ; DestinationY
    mov eax, r14d
    mov [rsp+56], rax        ; Width
    mov eax, r15d
    mov [rsp+64], rax        ; Height
    mov qword [rsp+72], 0   ; Delta = 0

    mov rcx, [v_gop]        ; this
    lea rdx, [v_bltpx]      ; BltBuffer = &pixel
    xor r8d, r8d            ; BltOperation = EfiBltVideoFill (0)
    xor r9d, r9d            ; SourceX = 0
    mov rax, [rcx + GOP_BLT]
    call rax

    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fn_draw_char(x, y, char, color, bg_color) - draws 8x8 char via GOP Blt
; edi=x, esi=y, dl=char, ecx=fg_color, r8d=bg_color
fn_draw_char:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 96

    mov r12d, edi       ; x
    mov r13d, esi       ; y
    movzx r14d, dl      ; char
    mov r15d, ecx       ; fg color
    mov ebp, r8d        ; bg color

    ; Get font data pointer: font_8x8 + (char - 32) * 8
    sub r14d, 32
    cmp r14d, 95
    jae .dc_done        ; out of range
    lea rbx, [font_8x8]
    shl r14d, 3         ; * 8
    add rbx, r14

    ; Build 8x8 pixel buffer (64 dwords = 256 bytes) in char_buf
    lea rdi, [char_buf]
    mov ecx, 8          ; 8 rows
.dc_build_row:
    movzx eax, byte [rbx]
    mov edx, 8          ; 8 columns
.dc_build_col:
    test al, 0x80
    jz .dc_build_bg
    mov [rdi], r15d     ; fg color
    jmp .dc_build_next
.dc_build_bg:
    mov [rdi], ebp      ; bg color
.dc_build_next:
    shl al, 1
    add rdi, 4
    dec edx
    jnz .dc_build_col
    inc rbx
    dec ecx
    jnz .dc_build_row

    ; Blt the 8x8 buffer to screen
    ; GOP->Blt(this, buf, EfiBltBufferToVideo, 0, 0, destX, destY, 8, 8, 8*4)
    mov rcx, [v_gop]
    lea rdx, [char_buf]
    mov r8d, 2              ; EfiBltBufferToVideo
    xor r9d, r9d            ; SourceX = 0
    mov qword [rsp+32], 0   ; SourceY = 0
    mov eax, r12d
    mov [rsp+40], rax        ; DestinationX
    mov eax, r13d
    mov [rsp+48], rax        ; DestinationY
    mov qword [rsp+56], 8   ; Width = 8
    mov qword [rsp+64], 8   ; Height = 8
    mov qword [rsp+72], 32  ; Delta = 8 pixels * 4 bytes = 32
    mov rax, [rcx + GOP_BLT]
    call rax

.dc_done:
    add rsp, 96
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fn_draw_str(x, y, str_ptr, fg, bg)
; edi=x, esi=y, rdx=str_ptr (ASCII null-term), ecx=fg, r8d=bg
fn_draw_str:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi       ; x
    mov r13d, esi       ; y
    mov rbx, rdx        ; string ptr
    mov r14d, ecx       ; fg
    mov r15d, r8d       ; bg
.ds_loop:
    movzx eax, byte [rbx]
    test al, al
    jz .ds_done
    mov edi, r12d
    mov esi, r13d
    mov dl, al
    mov ecx, r14d
    mov r8d, r15d
    push rbx
    call fn_draw_char
    pop rbx
    add r12d, 8         ; advance x by 8 pixels (char width)
    inc rbx
    jmp .ds_loop
.ds_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

