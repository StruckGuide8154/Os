; §4  Image codecs
; ---------------------------------------------------------------------------

; nx_media_blit_nic
;   NIC1: magic +0, u16 w +4, u16 h +6, u8 bpp +8, BGRA pixels +16.
;   Alpha-keyed: A==0 transparent.
nx_media_blit_nic:
    push rbx
    push r14
    push r15
    cmp byte [rdi + 8], 32
    jne .nic_done
    movzx r14d, word [rdi + 4]
    movzx r15d, word [rdi + 6]
    test r14d, r14d
    jz .nic_done
    test r15d, r15d
    jz .nic_done
    lea r12, [rdi + 16]                      ; source
    mov r13, rsi                             ; window
    mov dl, 1                                ; alpha-keyed
    xor r9d, r9d                             ; no reserved bottom strip
    call nx_media_blit_scaled
.nic_done:
    pop r15
    pop r14
    pop rbx
    ret

; nx_media_blit_bmp
;   Decode uncompressed 24/32bpp BMP into slot-local top-down BGRA scratch,
;   then route through the shared scaler so BMP stills are fitted and
;   letterboxed like NIC images. The legacy standalone BMP viewer keeps
;   using app_bmp_draw; this path is media-player-only.
nx_media_blit_bmp:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    ; [rsp +  0] row_stride
    ; [rsp +  4] bpp
    ; [rsp +  8] top_down flag
    ; [rsp + 16] pixel_data ptr
    ; [rsp + 24] scratch ptr

    mov r12, rdi                             ; BMP file
    mov r13, rsi                             ; window

    cmp word [r12], BMP_MAGIC16
    jne .bmp_done
    cmp dword [r12 + 14], 40                 ; BITMAPINFOHEADER minimum
    jb .bmp_done
    cmp word [r12 + 26], 1                   ; planes
    jne .bmp_done
    cmp dword [r12 + 30], 0                  ; BI_RGB only
    jne .bmp_done

    mov r14d, [r12 + 18]                     ; width
    test r14d, r14d
    jle .bmp_done
    mov r15d, [r12 + 22]                     ; signed height
    test r15d, r15d
    jz .bmp_done
    xor eax, eax
    test r15d, r15d
    jns .bmp_height_ok
    neg r15d
    mov eax, 1
.bmp_height_ok:
    mov [rsp + 8], eax                       ; top-down if original < 0

    movzx eax, word [r12 + 28]
    cmp eax, 24
    je .bmp_bpp_ok
    cmp eax, 32
    jne .bmp_done
.bmp_bpp_ok:
    mov [rsp + 4], eax

    ; Scratch guard: w * h * 4 must fit in MEDIA_BMP_SCRATCH_SZ.
    mov eax, r14d
    mul r15d
    jo .bmp_done
    shl rax, 2
    cmp rax, MEDIA_BMP_SCRATCH_SZ
    ja .bmp_done

    ; Row stride = ((w * bytes_per_pixel) + 3) & ~3.
    mov eax, r14d
    cmp dword [rsp + 4], 32
    je .bmp_stride_32
    imul eax, 3
    jmp .bmp_stride_pad
.bmp_stride_32:
    shl eax, 2
.bmp_stride_pad:
    add eax, 3
    and eax, ~3
    mov [rsp + 0], eax

    mov eax, [r12 + 10]
    lea rax, [r12 + rax]
    mov [rsp + 16], rax

    mov rax, [r13 + WIN_OFF_APPDATA]
    add rax, MEDIA_BMP_SCRATCH_OFF
    mov [rsp + 24], rax

    xor ebp, ebp                             ; dest y
.bmp_row_loop:
    cmp ebp, r15d
    jge .bmp_scale

    ; Source row index: top-down keeps y, bottom-up flips y.
    mov eax, ebp
    cmp dword [rsp + 8], 0
    jne .bmp_src_row_ready
    mov eax, r15d
    dec eax
    sub eax, ebp
.bmp_src_row_ready:
    imul eax, [rsp + 0]
    mov rsi, [rsp + 16]
    add rsi, rax

    mov eax, ebp
    imul eax, r14d
    shl eax, 2
    mov rdi, [rsp + 24]
    add rdi, rax

    xor ebx, ebx                             ; x
.bmp_px_loop:
    cmp ebx, r14d
    jge .bmp_next_row

    cmp dword [rsp + 4], 32
    je .bmp_copy_32
    ; 24bpp source is BGR. Store opaque BGRA.
    movzx eax, byte [rsi]                    ; B
    movzx ecx, byte [rsi + 1]                ; G
    shl ecx, 8
    or eax, ecx
    movzx ecx, byte [rsi + 2]                ; R
    shl ecx, 16
    or eax, ecx
    or eax, MEDIA_ALPHA_MASK
    mov [rdi], eax
    add rsi, 3
    jmp .bmp_px_done
.bmp_copy_32:
    mov eax, [rsi]                           ; already BGRA for BI_RGB
    mov [rdi], eax
    add rsi, 4
.bmp_px_done:
    add rdi, 4
    inc ebx
    jmp .bmp_px_loop

.bmp_next_row:
    inc ebp
    jmp .bmp_row_loop

.bmp_scale:
    mov r12, [rsp + 24]                      ; source BGRA scratch
    mov dl, 0                                ; opaque
    xor r9d, r9d                             ; no reserved bottom strip
    call nx_media_blit_scaled

.bmp_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret


; ---------------------------------------------------------------------------
