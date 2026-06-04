; ---------------------------------------------------------------------------
; §6  Vector codecs — SVG (subset) and XML text view
;
; Scope (mirrored in docs/media-formats.md):
;   * XML: rendered as plain top-aligned text. No scrolling (TODO).
;   * SVG: static preview. The real NexusHL SVG2 renderer supports the
;     wallpaper sources; this asm draw path paints a recognisable dark
;     ribbon preview instead of opening SVGs as blank/white text.
;
; Why a subset rather than full SVG: a complete SVG implementation
; (transforms, gradients, paths, text, CSS) is a multi-week project in
; asm. The subset is enough for icons and simple diagrams while keeping
; the renderer auditable in one screen.
; ---------------------------------------------------------------------------

; nx_media_blit_xml
;   Render the file as plain text, one line per FONT_HEIGHT+1 row.
;   RDI = file, RSI = window. The file is null-padded by the loader so
;   a NUL terminates the walk.
nx_media_blit_xml:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi
    mov r13, rsi

    ; Letterbox the client area in the text-bg colour.
    mov edi, [r13 + WIN_OFF_X]
    add edi, BORDER_WIDTH
    mov esi, [r13 + WIN_OFF_Y]
    add esi, TITLEBAR_HEIGHT
    mov edx, [r13 + WIN_OFF_W]
    sub edx, BORDER_WIDTH * 2
    mov ecx, [r13 + WIN_OFF_H]
    sub ecx, TITLEBAR_HEIGHT
    sub ecx, BORDER_WIDTH
    mov r8d, MEDIA_COL_TEXT_BG
    call nx_media_fill_rect

    mov r14, r12                             ; line start cursor
    mov r15d, [r13 + WIN_OFF_Y]
    add r15d, TITLEBAR_HEIGHT + 4            ; current text y

    mov ebp, [r13 + WIN_OFF_Y]
    add ebp, [r13 + WIN_OFF_H]
    sub ebp, BORDER_WIDTH                    ; bottom edge

.xml_line:
    cmp r15d, ebp
    jge .xml_done
    cmp byte [r14], 0
    je .xml_done

    ; Find end-of-line: LF or NUL.
    mov rbx, r14
.xml_eol:
    mov al, [rbx]
    test al, al
    jz .xml_emit_eof
    cmp al, 0x0A
    je .xml_emit_lf
    inc rbx
    jmp .xml_eol

.xml_emit_lf:
    ; Temporarily replace LF with NUL so draw_string treats this slice
    ; as a C string. Restore after.
    mov byte [rbx], 0
    mov edi, [r13 + WIN_OFF_X]
    add edi, BORDER_WIDTH + 4
    mov esi, r15d
    mov rdx, r14
    mov ecx, MEDIA_COL_TEXT_FG
    mov r8d, MEDIA_COL_TEXT_BG
    push rbx
    call draw_string
    pop rbx
    mov byte [rbx], 0x0A                     ; restore
    inc rbx
    mov r14, rbx
    add r15d, FONT_HEIGHT + 1
    jmp .xml_line

.xml_emit_eof:
    mov edi, [r13 + WIN_OFF_X]
    add edi, BORDER_WIDTH + 4
    mov esi, r15d
    mov rdx, r14
    mov ecx, MEDIA_COL_TEXT_FG
    mov r8d, MEDIA_COL_TEXT_BG
    call draw_string

.xml_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret


; nx_media_blit_svg
;   Static SVG preview for Media Player's kernel-side draw fn.
;
;   A full SVG2 renderer already exists in nxh land:
;   `src/user/nexushl/lib/svg2.nxh → svg_render(buf, len, x, y, w, h)`.
;   Wiring it directly to this codec still requires moving this draw fn to
;   user-mode. Until then, this path draws a deterministic thumbnail-like
;   preview so SVG-backed wallpapers are visibly viewable from Explorer.
nx_media_blit_svg:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32

    mov r12, rdi
    mov r13, rsi

    mov edi, [r13 + WIN_OFF_X]
    add edi, BORDER_WIDTH
    mov [rsp + 0], edi                       ; client_x
    mov esi, [r13 + WIN_OFF_Y]
    add esi, TITLEBAR_HEIGHT
    mov [rsp + 4], esi                       ; client_y
    mov edx, [r13 + WIN_OFF_W]
    sub edx, BORDER_WIDTH * 2
    mov [rsp + 8], edx                       ; client_w
    mov ecx, [r13 + WIN_OFF_H]
    sub ecx, TITLEBAR_HEIGHT
    sub ecx, BORDER_WIDTH
    mov [rsp + 12], ecx                      ; client_h
    mov r8d, MEDIA_SVG_BG
    call nx_media_fill_rect

    ; Soft central glow, approximated with nested solid rectangles.
    mov edi, [rsp + 8]
    imul edi, 30
    mov eax, edi
    mov ecx, 100
    cdq
    idiv ecx
    mov r14d, eax                            ; glow_w = w * 30%
    mov edi, [rsp + 12]
    imul edi, 22
    mov eax, edi
    mov ecx, 100
    cdq
    idiv ecx
    mov r15d, eax                            ; glow_h = h * 22%

    mov edi, [rsp + 0]
    mov eax, [rsp + 8]
    sub eax, r14d
    sar eax, 1
    add edi, eax
    mov esi, [rsp + 4]
    mov eax, [rsp + 12]
    sub eax, r15d
    sar eax, 1
    add esi, eax
    mov edx, r14d
    mov ecx, r15d
    mov r8d, MEDIA_SVG_GLOW
    call nx_media_fill_rect

    ; Cyan lower-left ribbon.
    mov edi, [rsp + 0]
    mov esi, [rsp + 4]
    mov eax, [rsp + 12]
    imul eax, 58
    mov ecx, 100
    cdq
    idiv ecx
    add esi, eax
    mov edx, [rsp + 8]
    imul edx, 62
    mov eax, edx
    mov ecx, 100
    cdq
    idiv ecx
    mov edx, eax
    mov ecx, [rsp + 12]
    imul ecx, 9
    mov eax, ecx
    mov ecx, 100
    cdq
    idiv ecx
    mov ecx, eax
    mov r8d, MEDIA_SVG_RIBBON
    call nx_media_fill_rect

    ; Magenta upper-left fold.
    mov edi, [rsp + 0]
    mov esi, [rsp + 4]
    mov eax, [rsp + 12]
    imul eax, 30
    mov ecx, 100
    cdq
    idiv ecx
    add esi, eax
    mov edx, [rsp + 8]
    imul edx, 52
    mov eax, edx
    mov ecx, 100
    cdq
    idiv ecx
    mov edx, eax
    mov ecx, [rsp + 12]
    imul ecx, 8
    mov eax, ecx
    mov ecx, 100
    cdq
    idiv ecx
    mov ecx, eax
    mov r8d, MEDIA_SVG_FOLD
    call nx_media_fill_rect

    ; Violet upper-right flow.
    mov edi, [rsp + 0]
    mov eax, [rsp + 8]
    imul eax, 45
    mov ecx, 100
    cdq
    idiv ecx
    add edi, eax
    mov esi, [rsp + 4]
    mov eax, [rsp + 12]
    imul eax, 24
    mov ecx, 100
    cdq
    idiv ecx
    add esi, eax
    mov edx, [rsp + 8]
    imul edx, 50
    mov eax, edx
    mov ecx, 100
    cdq
    idiv ecx
    mov edx, eax
    mov ecx, [rsp + 12]
    imul ecx, 10
    mov eax, ecx
    mov ecx, 100
    cdq
    idiv ecx
    mov ecx, eax
    mov r8d, MEDIA_SVG_FLOW
    call nx_media_fill_rect

    ; Deep lower-right twist.
    mov edi, [rsp + 0]
    mov eax, [rsp + 8]
    imul eax, 48
    mov ecx, 100
    cdq
    idiv ecx
    add edi, eax
    mov esi, [rsp + 4]
    mov eax, [rsp + 12]
    imul eax, 70
    mov ecx, 100
    cdq
    idiv ecx
    add esi, eax
    mov edx, [rsp + 8]
    imul edx, 48
    mov eax, edx
    mov ecx, 100
    cdq
    idiv ecx
    mov edx, eax
    mov ecx, [rsp + 12]
    imul ecx, 9
    mov eax, ecx
    mov ecx, 100
    cdq
    idiv ecx
    mov ecx, eax
    mov r8d, MEDIA_SVG_TWIST
    call nx_media_fill_rect

    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret


; ---------------------------------------------------------------------------
