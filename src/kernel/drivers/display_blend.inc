; --- Blend horizontal span (source-over) ---
; EDI = x, ESI = y, EDX = len, ECX = color (0xAARRGGBB)
FN_BEGIN blend_span, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push r12
    push r13
    push r14
    push rdi
    push rsi
    push rdx
    push rcx

    movsxd r12, edi
    movsxd r13, esi
    movsxd r14, edx           ; len
    test r14, r14
    jle .bs_done

    ; Clip y
    cmp r13, 0
    jl .bs_done
    mov eax, [scr_height]
    cmp r13, rax
    jge .bs_done

    ; Clip left
    cmp r12, 0
    jge .bs_cl_right
    add r14, r12              ; len += x (x is negative)
    xor r12d, r12d
.bs_cl_right:
    cmp r14, 0
    jle .bs_done
    mov eax, [scr_width]
    cmp r12, rax
    jge .bs_done
    mov rbx, rax
    sub rbx, r12              ; max width from x
    cmp r14, rbx
    jle .bs_loop
    mov r14, rbx
.bs_loop:
    test r14, r14
    jle .bs_done
    mov edi, r12d
    mov esi, r13d
    mov edx, ecx
    push rcx
    call blend_pixel
    pop rcx
    inc r12
    dec r14
    jmp .bs_loop
.bs_done:
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rax
    ret

; --- Blend horizontal span from a per-pixel ARGB buffer (source-over) ---
; EDI = x, ESI = y, EDX = len, RCX = src buffer (len * 4 bytes, ARGB each)
; One syscall replaces `len` calls to blend_pixel - used by the SVG raster
; scanline filler to avoid the kernel round-trip per pixel.
FN_BEGIN blend_span_argb, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    movsxd r12, edi               ; r12 = x
    movsxd r13, esi               ; r13 = y
    movsxd r14, edx               ; r14 = len
    mov    r15, rcx               ; r15 = src buffer pointer

    test r14, r14
    jle .bsa_done

    ; Clip y
    cmp r13, 0
    jl .bsa_done
    mov eax, [scr_height]
    cmp r13, rax
    jge .bsa_done

    ; Clip left: if x < 0, skip (-x) pixels at the start of the source buffer.
    cmp r12, 0
    jge .bsa_cl_right
    mov rax, r12
    neg rax                       ; rax = -x = pixels to skip
    add r14, r12                  ; len += x (x is negative)
    jle .bsa_done
    lea r15, [r15 + rax * 4]      ; advance src past skipped pixels
    xor r12d, r12d
.bsa_cl_right:
    mov eax, [raster_target_tbl + RTGT_WIDTH]
    cmp r12, rax
    jge .bsa_done
    mov rbx, rax
    sub rbx, r12
    cmp r14, rbx
    jle .bsa_setup
    mov r14, rbx                  ; clip len to remaining row width
.bsa_setup:
    ; dst row addr = bb_addr + y * pitch + x * 4
    mov rax, r13
    imul rax, [scr_pitch_q]
    mov rdi, [raster_target_tbl + RTGT_ADDR]
    add rdi, rax
    lea rdi, [rdi + r12 * 4]         ; rdi = dst pixel pointer
    mov rsi, r15                     ; rsi = src pixel pointer
    mov ecx, r14d                    ; ecx = pixel count

.bsa_loop:
    mov eax, [rsi]                ; eax = src ARGB
    add rsi, 4
    mov edx, eax
    shr edx, 24
    and edx, 0xFF                 ; edx = sa
    jz .bsa_next                  ; fully transparent
    cmp edx, 0xFF
    jne .bsa_blend
    mov [rdi], eax                ; opaque
    jmp .bsa_next

.bsa_blend:
    ; r9d = 255 - sa
    mov r9d, 255
    sub r9d, edx
    mov r8d, [rdi]                ; dst ARGB

    ; R channel:  (sr*sa + dr*(255-sa) + 128) >> 8
    mov r10d, eax
    shr r10d, 16
    and r10d, 0xFF
    imul r10d, edx                ; sr*sa
    mov r11d, r8d
    shr r11d, 16
    and r11d, 0xFF
    imul r11d, r9d                ; dr*(255-sa)
    add r10d, r11d
    add r10d, 128
    shr r10d, 8
    and r10d, 0xFF
    shl r10d, 16
    mov ebx, r10d                 ; ebx accumulates output

    ; G channel
    mov r10d, eax
    shr r10d, 8
    and r10d, 0xFF
    imul r10d, edx
    mov r11d, r8d
    shr r11d, 8
    and r11d, 0xFF
    imul r11d, r9d
    add r10d, r11d
    add r10d, 128
    shr r10d, 8
    and r10d, 0xFF
    shl r10d, 8
    or ebx, r10d

    ; B channel
    mov r10d, eax
    and r10d, 0xFF
    imul r10d, edx
    mov r11d, r8d
    and r11d, 0xFF
    imul r11d, r9d
    add r10d, r11d
    add r10d, 128
    shr r10d, 8
    and r10d, 0xFF
    or ebx, r10d

    mov [rdi], ebx

.bsa_next:
    add rdi, 4
    dec ecx
    jnz .bsa_loop

.bsa_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Blend horizontal span from ARGB buffer (screen blend mode) ---
; EDI = x, ESI = y, EDX = len, RCX = src buffer (len * 4 bytes, ARGB each)
; Implements CSS mix-blend-mode: screen. The back buffer is opaque, so the
; per-channel result is:  out = sa*screen(d,s) + (255-sa)*d, where
; screen(d,s) = s + d - s*d/255. Unlike source-over there is no opaque
; shortcut: an opaque source still mixes with the backdrop via screen().
FN_BEGIN blend_span_argb_screen, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    movsxd r12, edi               ; r12 = x
    movsxd r13, esi               ; r13 = y
    movsxd r14, edx               ; r14 = len
    mov    r15, rcx               ; r15 = src buffer pointer

    test r14, r14
    jle .bss_done

    cmp r13, 0
    jl .bss_done
    mov eax, [scr_height]
    cmp r13, rax
    jge .bss_done

    cmp r12, 0
    jge .bss_cl_right
    mov rax, r12
    neg rax
    add r14, r12
    jle .bss_done
    lea r15, [r15 + rax * 4]
    xor r12d, r12d
.bss_cl_right:
    mov eax, [raster_target_tbl + RTGT_WIDTH]
    cmp r12, rax
    jge .bss_done
    mov rbx, rax
    sub rbx, r12
    cmp r14, rbx
    jle .bss_setup
    mov r14, rbx
.bss_setup:
    mov rax, r13
    imul rax, [scr_pitch_q]
    mov rdi, [raster_target_tbl + RTGT_ADDR]
    add rdi, rax
    lea rdi, [rdi + r12 * 4]         ; rdi = dst pixel pointer
    mov rsi, r15                     ; rsi = src pixel pointer

.bss_loop:
    mov eax, [rsi]                ; eax = src ARGB
    add rsi, 4
    mov edx, eax
    shr edx, 24
    and edx, 0xFF                 ; edx = sa
    jz .bss_next                  ; fully transparent
    mov r9d, 255
    sub r9d, edx                  ; r9d = 255 - sa
    mov r8d, [rdi]                ; r8d = dst ARGB
    xor ebx, ebx                  ; ebx accumulates output

    ; R channel
    mov r10d, eax
    shr r10d, 16
    and r10d, 0xFF                ; r10d = s
    mov r11d, r8d
    shr r11d, 16
    and r11d, 0xFF                ; r11d = d
    mov ecx, r10d
    imul ecx, r11d
    add ecx, 128
    shr ecx, 8                    ; ecx = s*d/255
    add r10d, r11d
    sub r10d, ecx                 ; r10d = screen(d,s)
    imul r10d, edx                ; screen*sa
    mov ecx, r11d
    imul ecx, r9d                 ; d*(255-sa)
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 16
    or ebx, ecx

    ; G channel
    mov r10d, eax
    shr r10d, 8
    and r10d, 0xFF
    mov r11d, r8d
    shr r11d, 8
    and r11d, 0xFF
    mov ecx, r10d
    imul ecx, r11d
    add ecx, 128
    shr ecx, 8
    add r10d, r11d
    sub r10d, ecx
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 8
    or ebx, ecx

    ; B channel
    mov r10d, eax
    and r10d, 0xFF
    mov r11d, r8d
    and r11d, 0xFF
    mov ecx, r10d
    imul ecx, r11d
    add ecx, 128
    shr ecx, 8
    add r10d, r11d
    sub r10d, ecx
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    or ebx, ecx

    mov [rdi], ebx

.bss_next:
    add rdi, 4
    dec r14d
    jnz .bss_loop

.bss_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Blend horizontal span from ARGB buffer (multiply blend mode) ---
; EDI = x, ESI = y, EDX = len, RCX = src buffer (len * 4 bytes, ARGB each)
; CSS mix-blend-mode: multiply over an opaque back buffer:
; out = sa*multiply(d,s) + (255-sa)*d, multiply(d,s)=d*s/255.
FN_BEGIN blend_span_argb_multiply, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    movsxd r12, edi
    movsxd r13, esi
    movsxd r14, edx
    mov    r15, rcx

    test r14, r14
    jle .bsm_done
    cmp r13, 0
    jl .bsm_done
    mov eax, [raster_target_tbl + RTGT_HEIGHT]
    cmp r13, rax
    jge .bsm_done
    cmp r12, 0
    jge .bsm_cl_right
    mov rax, r12
    neg rax
    add r14, r12
    jle .bsm_done
    lea r15, [r15 + rax * 4]
    xor r12d, r12d
.bsm_cl_right:
    mov eax, [raster_target_tbl + RTGT_WIDTH]
    cmp r12, rax
    jge .bsm_done
    mov rbx, rax
    sub rbx, r12
    cmp r14, rbx
    jle .bsm_setup
    mov r14, rbx
.bsm_setup:
    mov rax, r13
    imul rax, [raster_target_tbl + RTGT_PITCH]
    mov rdi, [raster_target_tbl + RTGT_ADDR]
    add rdi, rax
    lea rdi, [rdi + r12 * 4]
    mov rsi, r15

.bsm_loop:
    mov eax, [rsi]
    add rsi, 4
    mov edx, eax
    shr edx, 24
    and edx, 0xFF
    jz .bsm_next
    mov r9d, 255
    sub r9d, edx
    mov r8d, [rdi]
    xor ebx, ebx

    ; R channel
    mov r10d, eax
    shr r10d, 16
    and r10d, 0xFF
    mov r11d, r8d
    shr r11d, 16
    and r11d, 0xFF
    imul r10d, r11d
    add r10d, 128
    shr r10d, 8                    ; multiply(d,s)
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 16
    or ebx, ecx

    ; G channel
    mov r10d, eax
    shr r10d, 8
    and r10d, 0xFF
    mov r11d, r8d
    shr r11d, 8
    and r11d, 0xFF
    imul r10d, r11d
    add r10d, 128
    shr r10d, 8
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 8
    or ebx, ecx

    ; B channel
    mov r10d, eax
    and r10d, 0xFF
    mov r11d, r8d
    and r11d, 0xFF
    imul r10d, r11d
    add r10d, 128
    shr r10d, 8
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    or ebx, ecx

    mov [rdi], ebx

.bsm_next:
    add rdi, 4
    dec r14d
    jnz .bsm_loop

.bsm_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
