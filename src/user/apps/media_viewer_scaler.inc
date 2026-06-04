; §3  Generic helpers
; ---------------------------------------------------------------------------

; nx_media_fill_rect(edi=x, esi=y, edx=w, ecx=h, r8d=color)
;   Clipped solid fill. Used by the control bar and the letterbox pass.
nx_media_fill_rect:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    movsxd r12, edi                          ; x (SIGNED — a negative x must not
                                             ; zero-extend into a wild row ptr)
    mov r13d, esi                            ; y
    mov r14d, edx                            ; w
    mov r15d, ecx                            ; h
    mov ebp, r8d                             ; color
    test r14d, r14d
    jle .fill_done
    test r15d, r15d
    jle .fill_done

    ; Horizontal clip to [0, scr_width): drop off-left columns, cap width at the
    ; right edge. Y is clamped per-row below. Without this an off-screen rect
    ; walks the row pointer past the framebuffer -> #PF.
    test r12, r12
    jns .fill_x_right
    add r14d, r12d                           ; w -= (-x)
    xor r12d, r12d                           ; x = 0
    test r14d, r14d
    jle .fill_done
.fill_x_right:
    mov eax, [scr_width]
    cmp r12d, eax
    jge .fill_done                           ; entirely right of screen
    sub eax, r12d                            ; max width = scr_width - x
    cmp r14d, eax
    jbe .fill_x_ok
    mov r14d, eax
.fill_x_ok:

    xor ebx, ebx
.fill_row:
    cmp ebx, r15d
    jge .fill_done
    mov edx, r13d
    add edx, ebx
    test edx, edx
    js .fill_skip
    cmp edx, [scr_height]
    jge .fill_done
    mov eax, edx
    imul eax, [scr_pitch]
    mov r10, [bb_addr]
    add r10, rax
    lea r10, [r10 + r12 * 4]
    xor r11, r11
    cmp byte [rel media_direct_present], 0
    je .fill_no_fb_row
    mov r11, [fb_addr]
    add r11, rax
    lea r11, [r11 + r12 * 4]
.fill_no_fb_row:
    mov edi, r14d
.fill_px:
    test edi, edi
    jz .fill_skip
    mov [r10], ebp
    test r11, r11
    je .fill_no_fb
    mov [r11], ebp
    add r11, 4
.fill_no_fb:
    add r10, 4
    dec edi
    jmp .fill_px
.fill_skip:
    inc ebx
    jmp .fill_row
.fill_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ---------------------------------------------------------------------------
; nx_media_compute_fit
;   Aspect-preserving fit of (src_w, src_h) into (dst_w, dst_h).
;
;   Inputs : edi=src_w, esi=src_h, edx=dst_w, ecx=dst_h
;   Output : eax = fit_w, ebx = fit_h, r10d = off_x, r11d = off_y
;   Clobbers: rax, rdx, r8, r9, r10, r11
;
;   Picks the smaller of (dst_w/src_w) and (dst_h/src_h) in 16.16 fixed
;   point, then multiplies src by the chosen ratio. Inputs are spilled to
;   the stack on entry so we can still read dst_w/dst_h after the
;   intermediate divides clobber edx.
;
;   Stack frame (after `sub rsp, 32`):
;     [rsp +  0]  src_w
;     [rsp +  4]  src_h
;     [rsp +  8]  dst_w
;     [rsp + 12]  dst_h
; ---------------------------------------------------------------------------
nx_media_compute_fit:
    sub rsp, 32
    mov [rsp + 0], edi                       ; src_w
    mov [rsp + 4], esi                       ; src_h
    mov [rsp + 8], edx                       ; dst_w
    mov [rsp + 12], ecx                      ; dst_h

    test edi, edi
    jz .cf_zero
    test esi, esi
    jz .cf_zero
    test edx, edx
    jz .cf_zero
    test ecx, ecx
    jz .cf_zero

    ; ratio_w = (dst_w << 16) / src_w
    mov eax, edx
    shl rax, 16
    xor edx, edx
    div rdi
    mov r8, rax                              ; ratio_w in r8

    ; ratio_h = (dst_h << 16) / src_h
    mov eax, [rsp + 12]
    shl rax, 16
    xor edx, edx
    div rsi
    cmp rax, r8
    jb .cf_use_h
    mov rax, r8
.cf_use_h:
    mov r9, rax                              ; chosen ratio (16.16)

    ; fit_w = src_w * ratio >> 16
    mov eax, [rsp + 0]
    imul rax, r9
    shr rax, 16
    mov ebx, eax                             ; fit_w in ebx
    ; fit_h = src_h * ratio >> 16
    mov eax, [rsp + 4]
    imul rax, r9
    shr rax, 16                              ; fit_h in eax

    ; Clamp to dst (rounding can overshoot by 1).
    mov r10d, [rsp + 8]                      ; dst_w
    cmp ebx, r10d
    jbe .cf_w_ok
    mov ebx, r10d
.cf_w_ok:
    mov r11d, [rsp + 12]                     ; dst_h
    cmp eax, r11d
    jbe .cf_h_ok
    mov eax, r11d
.cf_h_ok:

    ; Centre offsets.
    mov r10d, [rsp + 8]
    sub r10d, ebx
    shr r10d, 1                              ; off_x
    mov r11d, [rsp + 12]
    sub r11d, eax
    shr r11d, 1                              ; off_y

    ; Pack outputs: caller expects eax=fit_w, ebx=fit_h.
    xchg eax, ebx
    add rsp, 32
    ret

.cf_zero:
    xor eax, eax
    xor ebx, ebx
    xor r10d, r10d
    xor r11d, r11d
    add rsp, 32
    ret


; ---------------------------------------------------------------------------
; nx_media_blit_scaled
;   Aspect-preserving nearest-neighbor blit of a top-down BGRA source
;   into a viewport inside the window's client area.
;
;   Inputs (caller-saved values stashed on a local frame):
;     r12 = source BGRA pixels  (top-down, row-major, stride = src_w*4)
;     r13 = window struct ptr
;     r14d = src_w
;     r15d = src_h
;     dl   = 1 if alpha-keyed (skip pixels with A==0); 0 = opaque
;     r9d  = reserve_bottom_px (e.g. MEDIA_BAR_H for video; 0 for stills)
;
;   The viewport = client area minus the reserved bottom strip. We
;   letterbox the viewport in black, fit the source with aspect kept,
;   then walk the destination once with a 16.16 fixed-point step.
;
;   Performance notes
;   -----------------
;   - One unsigned divide per axis to compute the step. No divide in the
;     inner loop.
;   - One add per pixel for the U/V accumulators. No multiplies in the
;     inner loop.
;   - Pure scalar — no SSE — for portability across every CPU we boot
;     on. The framebuffer is WC-mapped (see fbperf_wc_landed memory) so
;     a single 32-bit `mov [r10], eax` is already a fast write. A SIMD
;     gather/store rewrite is sketched in §8.
; ---------------------------------------------------------------------------
;
; Stack frame (offsets from RSP after the `sub rsp, 64` below):
;     [rsp +  0]  src_ptr                   (qword)
;     [rsp +  8]  step_x (16.16)            (dword)
;     [rsp + 12]  step_y (16.16)            (dword)
;     [rsp + 16]  dst_x                     (dword)
;     [rsp + 20]  dst_y                     (dword)
;     [rsp + 24]  fit_w                     (dword)
;     [rsp + 28]  fit_h                     (dword)
;     [rsp + 32]  alpha_key flag (0/1)      (dword)
;     [rsp + 36]  viewport_w                (dword)
;     [rsp + 40]  viewport_h                (dword)
;     [rsp + 48]  direct fb row ptr         (qword)
nx_media_blit_scaled:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64

    mov [rsp + 0], r12                       ; src
    movzx eax, dl
    mov [rsp + 32], eax                      ; alpha-key flag

    ; Compute viewport (client area minus reserved bottom strip).
    mov edx, [r13 + WIN_OFF_W]
    sub edx, BORDER_WIDTH * 2                ; viewport_w
    mov ecx, [r13 + WIN_OFF_H]
    sub ecx, TITLEBAR_HEIGHT
    sub ecx, BORDER_WIDTH
    sub ecx, r9d                             ; minus reserved bottom strip
    test edx, edx
    jle .sc_done
    test ecx, ecx
    jle .sc_done
    mov [rsp + 36], edx
    mov [rsp + 40], ecx

    ; Compute fit.
    mov edi, r14d
    mov esi, r15d
    call nx_media_compute_fit
    ; eax=fit_w, ebx=fit_h, r10d=off_x, r11d=off_y
    test eax, eax
    jz .sc_done
    test ebx, ebx
    jz .sc_done
    mov [rsp + 24], eax
    mov [rsp + 28], ebx

    ; Destination origin = (client_x + off_x, client_y + off_y).
    mov ecx, [r13 + WIN_OFF_X]
    add ecx, BORDER_WIDTH
    add ecx, r10d
    mov [rsp + 16], ecx
    mov edx, [r13 + WIN_OFF_Y]
    add edx, TITLEBAR_HEIGHT
    add edx, r11d
    mov [rsp + 20], edx

    ; step_x = (src_w << 16) / fit_w
    mov rax, r14
    shl rax, 16
    xor edx, edx
    div dword [rsp + 24]
    mov [rsp + 8], eax
    ; step_y = (src_h << 16) / fit_h
    mov rax, r15
    shl rax, 16
    xor edx, edx
    div dword [rsp + 28]
    mov [rsp + 12], eax

    ; Fast path for native-size opaque video: no letterbox, no scaling, just
    ; copy BGRA rows into the backbuffer. BOOTANIM.NBA opens at this size.
    cmp dword [rsp + 32], 0
    jne .sc_letterbox
    mov eax, [rsp + 24]
    cmp eax, r14d
    jne .sc_check_2x
    cmp eax, [rsp + 36]
    jne .sc_check_2x
    mov eax, [rsp + 28]
    cmp eax, r15d
    jne .sc_check_2x
    cmp eax, [rsp + 40]
    jne .sc_check_2x
    cmp dword [rsp + 8], MEDIA_FIXED_ONE
    jne .sc_check_2x
    cmp dword [rsp + 12], MEDIA_FIXED_ONE
    jne .sc_check_2x
    jmp .sc_copy_opaque_1x

    ; Fast path for exact 2x opaque video. This is the full-size BOOTANIM.NBA
    ; case: read one source pixel and emit a 2x2 block instead of doing four
    ; fixed-point source lookups.
.sc_check_2x:
    cmp dword [rsp + 8], 0x8000
    jne .sc_letterbox
    cmp dword [rsp + 12], 0x8000
    jne .sc_letterbox
    mov eax, r14d
    shl eax, 1
    cmp eax, [rsp + 24]
    jne .sc_letterbox
    cmp eax, [rsp + 36]
    jne .sc_letterbox
    mov eax, r15d
    shl eax, 1
    cmp eax, [rsp + 28]
    jne .sc_letterbox
    cmp eax, [rsp + 40]
    jne .sc_letterbox
    jmp .sc_copy_opaque_2x

.sc_letterbox:
    ; Letterbox the whole viewport black so off-aspect borders are clean.
    mov edi, [r13 + WIN_OFF_X]
    add edi, BORDER_WIDTH
    mov esi, [r13 + WIN_OFF_Y]
    add esi, TITLEBAR_HEIGHT
    mov edx, [r13 + WIN_OFF_W]
    sub edx, BORDER_WIDTH * 2
    mov ecx, [r13 + WIN_OFF_H]
    sub ecx, TITLEBAR_HEIGHT
    sub ecx, BORDER_WIDTH
    sub ecx, r9d
    mov r8d, MEDIA_COL_LETTERBOX
    call nx_media_fill_rect

    ; Inner loop — one pass over the fit rectangle.
    ;   edi = dy
    ;   r10d = v (16.16 src y)
    xor edi, edi
    xor r10d, r10d
.sc_row:
    cmp edi, [rsp + 28]                      ; fit_h
    jge .sc_done

    ; screen_y = dst_y + dy
    mov edx, [rsp + 20]
    add edx, edi
    test edx, edx
    js .sc_row_next
    cmp edx, [scr_height]
    jge .sc_done

    ; src_row_ptr = src + (v >> 16) * src_w * 4
    mov eax, r10d
    shr eax, 16
    cmp eax, r15d
    jae .sc_row_next
    mov ecx, r14d
    imul ecx, eax
    shl ecx, 2
    mov r8, [rsp + 0]
    add r8, rcx                              ; r8 = src row ptr

    ; dst_row_ptr = bb + screen_y * pitch + dst_x * 4
    mov eax, edx
    imul eax, [scr_pitch]
    mov r9, [bb_addr]
    add r9, rax
    mov eax, [rsp + 16]
    lea r9, [r9 + rax * 4]                   ; r9 = dst row ptr
    cmp byte [rel media_direct_present], 0
    je .sc_no_direct_row
    mov eax, edx
    imul eax, [scr_pitch]
    mov rbx, [fb_addr]
    add rbx, rax
    mov eax, [rsp + 16]
    lea rbx, [rbx + rax * 4]
    mov [rsp + 48], rbx
    mov byte [rel media_direct_presented], 1
.sc_no_direct_row:

    ; Per-pixel walk.
    xor r11d, r11d                            ; u (16.16 src x)
    mov ecx, [rsp + 24]                       ; remaining pixels (fit_w)
    mov edx, [rsp + 8]                        ; step_x (loop-constant)
    ; Defense-in-depth horizontal clamp to [0, scr_width). The WM keeps windows
    ; on-screen so this is normally a no-op; it guards against any caller that
    ; still hands us an off-screen rect (negative dst_x would otherwise build a
    ; wild row pointer via zero-extension).
    mov eax, [rsp + 16]                       ; dst_x
    test eax, eax
    js .sc_row_next                           ; left of screen -> skip row
    mov ebp, [scr_width]
    sub ebp, eax                              ; max run = scr_width - dst_x
    jle .sc_row_next                          ; at/over right edge -> skip row
    cmp ecx, ebp
    jbe .sc_px
    mov ecx, ebp
.sc_px:
    test ecx, ecx
    jz .sc_row_next
    mov eax, r11d
    shr eax, 16
    cmp eax, r14d
    jae .sc_px_skip
    mov eax, [r8 + rax * 4]
    cmp dword [rsp + 32], 0
    je .sc_px_write                          ; opaque source — always write
    test eax, MEDIA_ALPHA_MASK
    jz .sc_px_skip                           ; alpha-keyed and A==0 → skip
.sc_px_write:
    mov [r9], eax
    cmp byte [rel media_direct_present], 0
    je .sc_px_skip
    mov rbx, [rsp + 48]
    mov [rbx], eax
.sc_px_skip:
    add r9, 4
    cmp byte [rel media_direct_present], 0
    je .sc_px_no_fb_advance
    add qword [rsp + 48], 4
.sc_px_no_fb_advance:
    add r11d, edx
    dec ecx
    jmp .sc_px

.sc_row_next:
    add r10d, [rsp + 12]                     ; v += step_y (always)
    inc edi
    jmp .sc_row

.sc_copy_opaque_1x:
    xor ebp, ebp                                ; row index
    mov r8, [rsp + 0]                           ; src row
.sc_copy_row:
    cmp ebp, r15d
    jge .sc_done
    mov edx, [rsp + 20]
    add edx, ebp
    test edx, edx
    js .sc_copy_next
    cmp edx, [scr_height]
    jge .sc_done

    ; Horizontal clamp -> ebx = pixels to copy this row (no-op when on-screen;
    ; guards a negative/over-wide dst_x from running rep movsd past the row).
    mov ebx, r14d                            ; src_w
    mov eax, [rsp + 16]                      ; dst_x
    test eax, eax
    js .sc_copy_next
    mov ecx, [scr_width]
    sub ecx, eax
    jle .sc_copy_next
    cmp ebx, ecx
    jbe .sc1_ccap
    mov ebx, ecx
.sc1_ccap:

    mov eax, edx
    imul eax, [scr_pitch]
    mov r9, [bb_addr]
    add r9, rax
    mov eax, [rsp + 16]
    lea r9, [r9 + rax * 4]

    mov rsi, r8
    mov rdi, r9
    mov ecx, ebx
    rep movsd
    cmp byte [rel media_direct_present], 0
    je .sc_copy_next
    mov rsi, r8
    mov eax, edx
    imul eax, [scr_pitch]
    mov rdi, [fb_addr]
    add rdi, rax
    mov eax, [rsp + 16]
    lea rdi, [rdi + rax * 4]
    mov ecx, ebx
    rep movsd
    mov byte [rel media_direct_presented], 1

.sc_copy_next:
    mov eax, r14d
    shl eax, 2
    add r8, rax
    inc ebp
    jmp .sc_copy_row

.sc_copy_opaque_2x:
    xor ebp, ebp                                ; source row index
    mov r8, [rsp + 0]                           ; src row
.sc2_row:
    cmp ebp, r15d
    jge .sc_done

    mov edx, [rsp + 20]
    mov eax, ebp
    shl eax, 1
    add edx, eax                                ; dest y = dst_y + sy*2
    test edx, edx
    js .sc2_next_src
    cmp edx, [scr_height]
    jge .sc_done

    mov eax, edx
    imul eax, [scr_pitch]
    mov r9, [bb_addr]
    add r9, rax
    mov eax, [rsp + 16]
    lea r9, [r9 + rax * 4]                      ; bb row 0
    mov r10, r9
    movsxd rax, dword [scr_pitch]
    add r10, rax                                ; bb row 1

    xor rbx, rbx                                ; fb row 0, optional
    xor r11, r11                                ; fb row 1, optional
    cmp byte [rel media_direct_present], 0
    je .sc2_no_fb_row
    mov eax, edx
    imul eax, [scr_pitch]
    mov rbx, [fb_addr]
    add rbx, rax
    mov eax, [rsp + 16]
    lea rbx, [rbx + rax * 4]
    mov r11, rbx
    movsxd rax, dword [scr_pitch]
    add r11, rax
    mov byte [rel media_direct_presented], 1
.sc2_no_fb_row:

    ; If the doubled second row would fall off the bottom, alias it onto row 0
    ; so the 2x2 block writes stay in-bounds (harmless double-write) instead of
    ; running one row past the backbuffer/framebuffer.
    mov eax, edx
    inc eax
    cmp eax, [scr_height]
    jl .sc2_row1_ok
    mov r10, r9
    mov r11, rbx
.sc2_row1_ok:
    ; Horizontal clamp: each src pixel emits two dst columns starting at dst_x,
    ; so the source-pixel budget is (scr_width - dst_x) / 2. No-op on-screen.
    mov ecx, r14d
    mov eax, [rsp + 16]                       ; dst_x
    test eax, eax
    js .sc2_next_src
    mov edx, [scr_width]
    sub edx, eax
    jle .sc2_next_src
    shr edx, 1
    jz .sc2_next_src
    cmp ecx, edx
    jbe .sc2_ccap
    mov ecx, edx
.sc2_ccap:

    mov rsi, r8
.sc2_px:
    test ecx, ecx
    jz .sc2_next_src
    mov eax, [rsi]
    add rsi, 4
    mov [r9], eax
    mov [r9 + 4], eax
    mov [r10], eax
    mov [r10 + 4], eax
    test rbx, rbx
    jz .sc2_advance
    mov [rbx], eax
    mov [rbx + 4], eax
    mov [r11], eax
    mov [r11 + 4], eax
    add rbx, 8
    add r11, 8
.sc2_advance:
    add r9, 8
    add r10, 8
    dec ecx
    jmp .sc2_px

.sc2_next_src:
    mov eax, r14d
    shl eax, 2
    add r8, rax
    inc ebp
    jmp .sc2_row

.sc_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret


; ---------------------------------------------------------------------------
