; --- Fill rectangle (rep stosd per row) ---
; EDI = x, ESI = y, EDX = w, ECX = h, R8D = color
; auto-wrapped (FN_BEGIN emits global): global fill_rect
FN_BEGIN fill_rect, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r9
    push r10
    push r11
    push r12
    push r13

    ; Clip to screen bounds.  Keep all geometry and address math in 64-bit
    ; registers so hostile 32-bit inputs cannot wrap back into kernel memory.
    movsxd r9, edi           ; x
    movsxd r10, esi          ; y
    movsxd r11, edx          ; w
    movsxd r12, ecx          ; h
    mov r13d, r8d            ; color

    ; Clip left
    cmp r9, 0
    jge .clip_right
    add r11, r9              ; Reduce width
    xor r9d, r9d             ; x = 0
.clip_right:
    cmp r11, 0
    jle .rect_done
    mov eax, [scr_width]
    cmp r9, rax
    jae .rect_done
    mov rbx, rax
    mov rax, r9
    add rax, r11
    cmp rax, rbx
    jbe .clip_top
    mov r11, rbx
    sub r11, r9
.clip_top:
    cmp r10, 0
    jge .clip_bottom
    add r12, r10
    xor r10d, r10d
.clip_bottom:
    cmp r12, 0
    jle .rect_done
    mov eax, [scr_height]
    cmp r10, rax
    jae .rect_done
    mov rbx, rax
    mov rax, r10
    add rax, r12
    cmp rax, rbx
    jbe .clip_done
    mov r12, rbx
    sub r12, r10
.clip_done:
    ; Validate dimensions
    cmp r11, 0
    jle .rect_done
    cmp r12, 0
    jle .rect_done

    ; Calculate starting offset
    mov rax, r10
    imul rax, [scr_pitch_q]
    lea rax, [rax + r9 * 4]
    mov rbx, [bb_addr]
    add rbx, rax

    mov rsi, [scr_pitch_q]

    ; Simple robust fill using rep stosd
    mov rdi, rbx             ; RDI = starting address in back buffer
    mov rcx, r11             ; RCX = width in pixels
.row_loop:
    push rdi
    push rcx
    mov eax, r13d            ; Color
    rep stosd                ; Fill row
    pop rcx
    pop rdi

    add rdi, rsi             ; Next row (add pitch)
    dec r12
    jnz .row_loop

.rect_done:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Draw single character (optimized fast path) ---
; EDI = x, ESI = y, DL = character, ECX = fg_color, R8D = bg_color
; auto-wrapped (FN_BEGIN emits global): global draw_char
FN_BEGIN draw_char, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    movzx r9d, dl            ; Character
    mov r10d, edi             ; x
    mov r11d, esi             ; y
    mov r12d, ecx             ; fg color
    mov r13d, r8d             ; bg color

    ; Get font data pointer
    sub r9d, FONT_FIRST_CHAR
    cmp r9d, FONT_NUM_CHARS
    jge .char_done
    cmp r9d, 0
    jl .char_done

    extern font_data
    lea rbx, [font_data]
    shl r9d, 4               ; * 16 bytes per char
    add rbx, r9

    ; Quick reject: if entirely off-screen, skip
    cmp r10d, [scr_width]
    jge .char_done
    cmp r11d, [scr_height]
    jge .char_done
    mov eax, r10d
    add eax, FONT_WIDTH
    cmp eax, 0
    jle .char_done
    mov eax, r11d
    add eax, FONT_HEIGHT
    cmp eax, 0
    jle .char_done

    ; FAST PATH: if character is fully on-screen (x>=0 && x+8<=width && y>=0 && y+16<=height)
    ; we can skip all per-pixel clipping and use direct writes
    cmp r10d, 0
    jl .slow_path
    mov eax, r10d
    add eax, 8
    cmp eax, [scr_width]
    jg .slow_path
    cmp r11d, 0
    jl .slow_path
    mov eax, r11d
    add eax, 16
    cmp eax, [scr_height]
    jg .slow_path

    ; === FAST PATH: No clipping needed ===
    ; Pre-calculate row start in back buffer
    movsxd rax, r11d
    imul rax, [scr_pitch_q]
    lea rax, [rax + r10 * 4]
    mov r14, [bb_addr]
    add r14, rax              ; r14 = pointer to first pixel of char in BB

    mov r15, [scr_pitch_q]     ; pitch for row advance

    mov r9d, 16               ; 16 rows
.fast_row:
    movzx eax, byte [rbx]     ; Font row byte

    ; Check if transparent bg - if so, we must handle per-pixel
    cmp r13d, -1
    je .fast_row_transparent

    ; Opaque background: write all 8 pixels unconditionally (2 dwords at a time)
    ; Pixel 0 (MSB)
    test al, 0x80
    mov ecx, r13d             ; assume bg
    cmovnz ecx, r12d          ; if bit set, use fg
    mov [r14], ecx
    ; Pixel 1
    test al, 0x40
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 4], ecx
    ; Pixel 2
    test al, 0x20
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 8], ecx
    ; Pixel 3
    test al, 0x10
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 12], ecx
    ; Pixel 4
    test al, 0x08
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 16], ecx
    ; Pixel 5
    test al, 0x04
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 20], ecx
    ; Pixel 6
    test al, 0x02
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 24], ecx
    ; Pixel 7 (LSB)
    test al, 0x01
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 28], ecx

    jmp .fast_row_next

.fast_row_transparent:
    ; Transparent background: only write foreground pixels
    test al, 0x80
    jz .ft1
    mov [r14], r12d
.ft1:
    test al, 0x40
    jz .ft2
    mov [r14 + 4], r12d
.ft2:
    test al, 0x20
    jz .ft3
    mov [r14 + 8], r12d
.ft3:
    test al, 0x10
    jz .ft4
    mov [r14 + 12], r12d
.ft4:
    test al, 0x08
    jz .ft5
    mov [r14 + 16], r12d
.ft5:
    test al, 0x04
    jz .ft6
    mov [r14 + 20], r12d
.ft6:
    test al, 0x02
    jz .ft7
    mov [r14 + 24], r12d
.ft7:
    test al, 0x01
    jz .fast_row_next
    mov [r14 + 28], r12d

.fast_row_next:
    inc rbx                   ; Next font row
    add r14, r15              ; Next screen row
    dec r9d
    jnz .fast_row
    jmp .char_done

.slow_path:
    ; === SLOW PATH: Per-pixel clipping (edge cases) ===
    mov r14d, 16             ; Row counter
.char_row:
    ; Skip row if Y out of bounds
    cmp r11d, 0
    jl .skip_row
    cmp r11d, [scr_height]
    jge .char_done           ; All remaining rows are off-screen

    movzx eax, byte [rbx]    ; Font row byte
    mov ecx, 8               ; 8 pixels per row

    ; Calculate row start pointer
    push r9
    movsxd r9, r11d
    imul r9, [scr_pitch_q]
    movsxd rax, r10d
    lea r9, [r9 + rax * 4]
    mov rdi, [bb_addr]
    add rdi, r9
    pop r9

    ; Track current X for clipping
    push r9
    mov r9d, r10d            ; Current pixel X

.char_pixel:
    ; Clip X
    cmp r9d, 0
    jl .skip_pixel
    cmp r9d, [scr_width]
    jge .row_done_pop

    test al, 0x80            ; Test MSB
    jz .bg_pixel
    mov dword [rdi], r12d    ; Foreground
    jmp .next_pixel
.bg_pixel:
    cmp r13d, -1             ; -1 = transparent background
    je .next_pixel
    mov dword [rdi], r13d    ; Background
.next_pixel:
.skip_pixel:
    shl al, 1
    add rdi, 4
    inc r9d
    dec ecx
    jnz .char_pixel

.row_done_pop:
    pop r9

.skip_row:
    inc rbx                  ; Next font row
    inc r11d                 ; Next screen row
    dec r14d
    jnz .char_row

.char_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop rbx
    pop rax
    ret

; --- Draw null-terminated string ---
; EDI = x, ESI = y, RDX = pointer to string, ECX = fg_color, R8D = bg_color
; auto-wrapped (FN_BEGIN emits global): global draw_string
FN_BEGIN draw_string, 0, 0, FN_RET_SCALAR
    push rbx
    push r9
    push r10
    push r11

    mov r9d, edi             ; Current x
    mov r10d, esi            ; y
    mov rbx, rdx             ; String pointer
    mov r11d, ecx            ; fg color (preserve for all chars)

    ; Quick reject: if string Y is entirely off-screen, skip
    cmp r10d, [scr_height]
    jge .str_done
    mov eax, r10d
    add eax, FONT_HEIGHT
    cmp eax, 0
    jle .str_done

.str_loop:
    ; rbx points at the caller's string, which for syscall-driven text
    ; (.sc_gui_text -> render_text) lives in PTE.U app memory. With SMAP
    ; enforced this supervisor read #PFs unless AC is set, so bracket the
    ; user deref with stac/clac. Kernel-memory callers are unaffected (stac
    ; permits kernel reads too). Kept tight to one byte so SMAP re-arms across
    ; draw_char.
    USER_ACCESS_BEGIN
    movzx eax, byte [rbx]
    USER_ACCESS_END
    test al, al
    jz .str_done

    ; Skip chars that are entirely past right edge
    cmp r9d, [scr_width]
    jge .str_done

    ; Draw character (draw_char handles left-edge clipping)
    mov edi, r9d
    mov esi, r10d
    mov dl, al
    mov ecx, r11d
    ; R8D already has bg_color
    call draw_char

    add r9d, FONT_WIDTH      ; Advance x by character width
    inc rbx
    jmp .str_loop

.str_done:
    pop r11
    pop r10
    pop r9
    pop rbx
    ret

; --- Draw horizontal line ---
; EDI = x, ESI = y, EDX = width, ECX = color
; auto-wrapped (FN_BEGIN emits global): global draw_hline
FN_BEGIN draw_hline, 0, 0, FN_RET_SCALAR
    push r8
    mov r8d, ecx             ; color
    mov ecx, 1               ; height = 1
    call fill_rect
    pop r8
    ret

; Target-aware scanline used by SVG raster primitives only. Normal GUI chrome
; uses draw_hline/fill_rect above, which always write to the real backbuffer.
draw_hline_raster:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    push r9
    push r10
    movsxd r9, edi            ; x
    movsxd r10, esi           ; y
    movsxd rbx, edx           ; width
    test rbx, rbx
    jle .done
    cmp r10, 0
    jl .done
    mov eax, [raster_target_height]
    cmp r10, rax
    jge .done
    cmp r9, 0
    jge .clip_right
    add rbx, r9
    jle .done
    xor r9d, r9d
.clip_right:
    mov eax, [raster_target_width]
    cmp r9, rax
    jge .done
    mov rdi, rax
    sub rdi, r9
    cmp rbx, rdi
    jle .addr
    mov rbx, rdi
.addr:
    mov rax, r10
    imul rax, [raster_target_pitch_q]
    lea rax, [rax + r9 * 4]
    mov rdi, [raster_target_addr]
    add rdi, rax
    mov eax, ecx
    mov rcx, rbx
    rep stosd
.done:
    pop r10
    pop r9
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; --- Draw vertical line ---
; EDI = x, ESI = y, EDX = height, ECX = color
; auto-wrapped (FN_BEGIN emits global): global draw_vline
FN_BEGIN draw_vline, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push r8

    ; Clip
    cmp edi, 0
    jl .vl_done
    cmp edi, [scr_width]
    jge .vl_done

    mov r8d, ecx             ; color
    mov eax, esi             ; y
    mov ebx, edx             ; height

.vl_loop:
    cmp ebx, 0
    jle .vl_done
    cmp eax, 0
    jl .vl_next
    cmp eax, [scr_height]
    jge .vl_done

    ; Write pixel
    push rax
    imul rax, [scr_pitch_q]
    movsxd rcx, edi
    lea rax, [rax + rcx * 4]
    mov rcx, [bb_addr]
    mov [rcx + rax], r8d
    pop rax

.vl_next:
    inc eax
    dec ebx
    jmp .vl_loop

.vl_done:
    pop r8
    pop rbx
    pop rax
    ret

; --- Draw rectangle outline ---
; EDI = x, ESI = y, EDX = w, ECX = h, R8D = color
; auto-wrapped (FN_BEGIN emits global): global draw_rect_outline
FN_BEGIN draw_rect_outline, 0, 0, FN_RET_SCALAR
    push rdi
    push rsi
    push rdx
    push rcx
    push r8

    ; Save params
    push rdi                 ; x
    push rsi                 ; y
    push rdx                 ; w
    push rcx                 ; h

    ; Top line
    mov ecx, r8d
    mov edx, [rsp + 8]      ; w
    call draw_hline

    ; Bottom line
    mov edi, [rsp + 24]     ; x
    mov esi, [rsp + 16]     ; y
    add esi, [rsp]           ; + h - 1
    dec esi
    mov edx, [rsp + 8]      ; w
    mov ecx, r8d
    call draw_hline

    ; Left line
    mov edi, [rsp + 24]
    mov esi, [rsp + 16]
    mov edx, [rsp]           ; h
    mov ecx, r8d
    call draw_vline

    ; Right line
    mov edi, [rsp + 24]
    add edi, [rsp + 8]      ; x + w - 1
    dec edi
    mov esi, [rsp + 16]
    mov edx, [rsp]
    mov ecx, r8d
    call draw_vline

    add rsp, 32
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret
