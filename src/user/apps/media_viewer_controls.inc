; §7  Control bar UI
;
; Layout (mirrored in media.nxh):
;
;   +-------+-------+-------+--------------------------------+--------+
;   | PLAY  | -10s  | +10s  |  scrub track                   |  MM:SS |
;   +-------+-------+-------+--------------------------------+--------+
;     28px    28px    28px        flex                          56px
;
; All drawing is clipped by nx_media_fill_rect, so an undersized window
; just clips the rightmost elements instead of crashing.
; ---------------------------------------------------------------------------

; Glyph: ▶ play triangle. 12 px tall, widens by 1 px per row up to the
; midpoint, then narrows. edi=x, esi=y, edx=color.
nx_media_draw_glyph_play:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    xor ebx, ebx
.gp_row:
    cmp ebx, 12
    jge .gp_done
    mov edi, r12d
    mov esi, r13d
    add esi, ebx
    mov edx, ebx
    cmp edx, 6
    jb .gp_grow
    mov edx, 11
    sub edx, ebx
.gp_grow:
    add edx, 1
    mov ecx, 1
    mov r8d, r14d
    call nx_media_fill_rect
    inc ebx
    jmp .gp_row
.gp_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Glyph: ⏸ pause. Two 3×10 bars 4 px apart. edi=x, esi=y, edx=color.
nx_media_draw_glyph_pause:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx

    mov edi, r12d
    mov esi, r13d
    mov edx, 3
    mov ecx, 10
    mov r8d, r14d
    call nx_media_fill_rect

    mov edi, r12d
    add edi, 7
    mov esi, r13d
    mov edx, 3
    mov ecx, 10
    mov r8d, r14d
    call nx_media_fill_rect

    pop r14
    pop r13
    pop r12
    ret

; Glyph: ⏪ skip back. Two ◀ triangles, 12 px wide total, 10 px tall.
;   edi=x, esi=y, edx=color
nx_media_draw_glyph_skip_back:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov r12d, edi                            ; x
    mov r13d, esi                            ; y
    mov r14d, edx                            ; color
    xor ebx, ebx
.gsb_row:
    cmp ebx, 10
    jge .gsb_done
    ; width grows then shrinks across 10 rows (peak at row 5).
    mov ebp, ebx
    cmp ebp, 5
    jb .gsb_grow
    mov ebp, 9
    sub ebp, ebx
.gsb_grow:
    add ebp, 1                               ; ebp = current row width
    ; First triangle: apex left at x+5-w, base flush at x+5.
    mov edi, r12d
    add edi, 5
    sub edi, ebp
    mov esi, r13d
    add esi, ebx
    mov edx, ebp
    mov ecx, 1
    mov r8d, r14d
    call nx_media_fill_rect
    ; Second triangle: apex at x+11-w, base flush at x+11.
    mov edi, r12d
    add edi, 11
    sub edi, ebp
    mov esi, r13d
    add esi, ebx
    mov edx, ebp
    mov ecx, 1
    mov r8d, r14d
    call nx_media_fill_rect
    inc ebx
    jmp .gsb_row
.gsb_done:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Glyph: ⏩ skip forward.
nx_media_draw_glyph_skip_fwd:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    xor ebx, ebx
.gsf_row:
    cmp ebx, 10
    jge .gsf_done
    mov ebp, ebx
    cmp ebp, 5
    jb .gsf_grow
    mov ebp, 9
    sub ebp, ebx
.gsf_grow:
    add ebp, 1
    ; First triangle: apex right at x+ebp, base flush at x.
    mov edi, r12d
    mov esi, r13d
    add esi, ebx
    mov edx, ebp
    mov ecx, 1
    mov r8d, r14d
    call nx_media_fill_rect
    ; Second triangle: apex at x+6+ebp, base flush at x+6.
    mov edi, r12d
    add edi, 6
    mov esi, r13d
    add esi, ebx
    mov edx, ebp
    mov ecx, 1
    mov r8d, r14d
    call nx_media_fill_rect
    inc ebx
    jmp .gsf_row
.gsf_done:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; nx_media_format_mmss(rdi=buf, eax=seconds)
;   Writes "MM:SS" + NUL into the 6-byte buffer at RDI. Caps minutes at
;   99 (display rolls over at 99:59).
nx_media_format_mmss:
    push rbx
    push rcx
    push rdx
    push rdi
    xor edx, edx
    mov ecx, 60
    div ecx                                  ; eax = minutes, edx = secs
    mov ebx, edx                             ; secs
    cmp eax, 99
    jbe .mmss_ok
    mov eax, 99
    mov ebx, 59
.mmss_ok:
    mov edi, [rsp]
    ; minutes (two digits).
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi + 0], al
    add dl, '0'
    mov [rdi + 1], dl
    mov byte [rdi + 2], ':'
    ; seconds.
    mov eax, ebx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi + 3], al
    add dl, '0'
    mov [rdi + 4], dl
    mov byte [rdi + 5], 0
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; Scratch text buffers for the time label. Single-tenant — the WM draws
; windows sequentially so two players don't overlap their formatting.
nx_media_time_cur: times 8 db 0
nx_media_time_dur: times 8 db 0
sz_media_time_sep: db " / ", 0

; nx_media_draw_nba_controls
;   Inputs:
;     rdi = file ptr (NBA header)
;     rsi = window struct ptr
;     edx = current frame
;     ecx = frame count
;     r8d = fps
;
;   Local stack frame (after `sub rsp, 32`):
;     [rsp +  0]  bar_x  (dword)
;     [rsp +  4]  bar_y  (dword)
;     [rsp +  8]  bar_w  (dword)
;     [rsp + 12]  fps    (dword)
;     [rsp + 16]  cur_frame
;     [rsp + 20]  frame_count
;     [rsp + 24]  track_w
;     [rsp + 28]  filled_px
nx_media_draw_nba_controls:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32

    mov r12, rdi
    mov r13, rsi
    mov [rsp + 16], edx                      ; cur frame
    mov [rsp + 20], ecx                      ; frame count
    mov [rsp + 12], r8d                      ; fps

    ; Bar geometry.
    mov eax, [r13 + WIN_OFF_X]
    add eax, BORDER_WIDTH
    mov [rsp + 0], eax                       ; bar_x
    mov eax, [r13 + WIN_OFF_Y]
    add eax, [r13 + WIN_OFF_H]
    sub eax, BORDER_WIDTH
    sub eax, MEDIA_BAR_H
    mov [rsp + 4], eax                       ; bar_y
    mov eax, [r13 + WIN_OFF_W]
    sub eax, BORDER_WIDTH * 2
    mov [rsp + 8], eax                       ; bar_w

    ; Bar background.
    mov edi, [rsp + 0]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, MEDIA_BAR_H
    mov r8d, MEDIA_COL_BAR_BG
    call nx_media_fill_rect

    ; Three button backgrounds (PLAY / -10s / +10s).
    ; PLAY
    mov edi, [rsp + 0]
    add edi, MEDIA_BTN_PLAY_X + 2
    mov esi, [rsp + 4]
    add esi, 5
    mov edx, MEDIA_BTN_W - 4
    mov ecx, 16
    mov r8d, MEDIA_COL_BTN_BG
    call nx_media_fill_rect
    ; -10s
    mov edi, [rsp + 0]
    add edi, MEDIA_BTN_BACK_X + 2
    mov esi, [rsp + 4]
    add esi, 5
    mov edx, MEDIA_BTN_W - 4
    mov ecx, 16
    mov r8d, MEDIA_COL_BTN_BG
    call nx_media_fill_rect
    ; +10s
    mov edi, [rsp + 0]
    add edi, MEDIA_BTN_FWD_X + 2
    mov esi, [rsp + 4]
    add esi, 5
    mov edx, MEDIA_BTN_W - 4
    mov ecx, 16
    mov r8d, MEDIA_COL_BTN_BG
    call nx_media_fill_rect

    ; Play / pause glyph.
    mov rax, [r13 + WIN_OFF_APPDATA]
    cmp dword [rax + app_hl_media_mp_paused - app_blob_start], 0
    je .ctl_glyph_pause
    mov edi, [rsp + 0]
    add edi, MEDIA_BTN_PLAY_X + 7
    mov esi, [rsp + 4]
    add esi, 7
    mov edx, MEDIA_COL_GLYPH
    call nx_media_draw_glyph_play
    jmp .ctl_skip_glyphs
.ctl_glyph_pause:
    mov edi, [rsp + 0]
    add edi, MEDIA_BTN_PLAY_X + 9
    mov esi, [rsp + 4]
    add esi, 8
    mov edx, MEDIA_COL_GLYPH
    call nx_media_draw_glyph_pause
.ctl_skip_glyphs:

    ; -10s glyph
    mov edi, [rsp + 0]
    add edi, MEDIA_BTN_BACK_X + 8
    mov esi, [rsp + 4]
    add esi, 8
    mov edx, MEDIA_COL_GLYPH
    call nx_media_draw_glyph_skip_back

    ; +10s glyph
    mov edi, [rsp + 0]
    add edi, MEDIA_BTN_FWD_X + 8
    mov esi, [rsp + 4]
    add esi, 8
    mov edx, MEDIA_COL_GLYPH
    call nx_media_draw_glyph_skip_fwd

    ; Scrub track.
    mov eax, [rsp + 8]                       ; bar_w
    sub eax, MEDIA_SCRUB_X
    sub eax, MEDIA_TIME_W
    cmp eax, 4
    jle .ctl_no_scrub
    mov [rsp + 24], eax                      ; track_w
    mov edi, [rsp + 0]
    add edi, MEDIA_SCRUB_X
    mov esi, [rsp + 4]
    add esi, 12
    mov edx, eax
    mov ecx, 3
    mov r8d, MEDIA_COL_TRACK_BG
    call nx_media_fill_rect

    ; Progress fill: (cur+1) * track_w / frame_count.
    mov eax, [rsp + 16]
    inc eax
    mul dword [rsp + 24]                     ; rdx:rax = (cur+1)*track_w
    mov ecx, [rsp + 20]
    test ecx, ecx
    jz .ctl_no_progress
    div ecx                                   ; eax = filled px
    mov [rsp + 28], eax
    mov edi, [rsp + 0]
    add edi, MEDIA_SCRUB_X
    mov esi, [rsp + 4]
    add esi, 12
    mov edx, eax
    mov ecx, 3
    mov r8d, MEDIA_COL_TRACK_FG
    call nx_media_fill_rect

    ; Knob: 5×9 centred at the fill end.
    mov edi, [rsp + 0]
    add edi, MEDIA_SCRUB_X
    add edi, [rsp + 28]
    sub edi, 2
    mov esi, [rsp + 4]
    add esi, 9
    mov edx, 5
    mov ecx, 9
    mov r8d, MEDIA_COL_KNOB
    call nx_media_fill_rect
.ctl_no_progress:
.ctl_no_scrub:

    ; "MM:SS" current — drawn in the right-edge time area. We only show
    ; current (duration would overflow MEDIA_TIME_W with default font).
    mov ecx, [rsp + 12]                      ; fps
    test ecx, ecx
    jz .ctl_done
    mov eax, [rsp + 16]
    xor edx, edx
    div ecx                                   ; eax = current seconds
    lea rdi, [rel nx_media_time_cur]
    call nx_media_format_mmss

    mov eax, [rsp + 0]
    add eax, [rsp + 8]
    sub eax, MEDIA_TIME_W
    add eax, 4
    mov edi, eax
    mov esi, [rsp + 4]
    add esi, 8
    lea rdx, [rel nx_media_time_cur]
    mov ecx, MEDIA_COL_TEXT_FG
    mov r8d, MEDIA_COL_BAR_BG
    call draw_string

.ctl_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret


; ---------------------------------------------------------------------------
; §8  Future-work notes (kept here so the work surface stays discoverable)
;
;   STATUS: SYS_MEDIA_BLIT_SCALED (syscall #66) is live. The scaler in
;   §3 is now reachable from user-mode NexusHL via the helper
;   `media_blit_scaled(...)` in `src/user/nexushl/lib/media.nxh`. The
;   kernel-side validation lives in `syscall.asm → .sc_media_blit_scaled`
;   and covers: buffer range, dim bounds, byte-count cap, window id,
;   reserve-bottom clamp, alpha-key normalisation. Future apps should
;   call the syscall rather than carry their own scaler.
;
;   * SIMD scaler. The §3 inner loop is scalar. An SSE2 form that
;     advances `u` by 4*step per iteration and writes a 16-byte chunk
;     would roughly double throughput on real HW. Blocked on the WM
;     adding xmm save/restore around draw callbacks — none of the other
;     codecs need xmm today and the WM doesn't preserve it.
;
;   * Dirty-rect awareness. We redraw the whole client area each tick.
;     Frame index changes only every (100/fps) ticks; on no-change
;     ticks we could skip the blit and just redraw the scrub knob.
;     This would slash idle CPU during paused / single-frame playback.
;
;   * BMP through the shared scaler. Landed for uncompressed 24/32bpp
;     BI_RGB BMP in the Media Player path. The standalone legacy BMP
;     viewer still routes to app_bmp_draw.
;
;   * SVG subset rasteriser. Walk the file once; for each <rect>,
;     <circle>, <line> with a recognised fill/stroke attribute, draw
;     scaled by the same fit transform we use for bitmaps. Strict
;     subset only — no transforms, no gradients, no text, no CSS.
;
;   * Audio. Out of scope until the kernel has an audio mixer.
; ---------------------------------------------------------------------------
