; ============================================================================
; syscall_handlers_xml_draw.inc
; syscall_entry handlers: XML DOM, draw line/circle/triangle, blend pixel/span, media blit
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
.sc_xml_parse:
    ; rdi=buf, rsi=len. sc_validate_user_io_range takes (rdi=ptr, rsi=len).
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
    call xml_parse
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_xml_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_xml_root:
    call xml_root
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_tag:
    call xml_tag
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_tag_name:
    ; rdi=node, rsi=out, rdx=max
    push rdi
    push rdx
    mov rdi, rsi
    mov rsi, rdx
    call sc_validate_user_io_range
    pop rdx
    pop rdi
    test eax, eax
    jz .sc_xml_reject
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    call xml_tag_name
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_first_child:
    call xml_first_child
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_next_sibling:
    call xml_next_sibling
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_parent:
    call xml_parent
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_attr:
    ; rdi=node, rsi=name, rdx=nlen, r10=out, r8=omax
    ; validate name range
    mov rdi, rsi
    mov rsi, rdx
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    ; validate out range
    mov rdi, [rsp + ALL_R10]
    mov rsi, [rsp + ALL_R8]
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    ; reload original args and call xml_attr(node, name, nlen, out, omax)
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    mov rcx, [rsp + ALL_R10]
    mov r8,  [rsp + ALL_R8]
    call xml_attr
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_text:
    ; rdi=node, rsi=out, rdx=max
    push rdi
    push rdx
    mov rdi, rsi
    mov rsi, rdx
    call sc_validate_user_io_range
    pop rdx
    pop rdi
    test eax, eax
    jz .sc_xml_reject
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    call xml_text
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_free:
    call xml_free
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_last_error:
    ; Return packed diagnostic: bits[31:0] = error code,
    ; bits[63:32] = byte offset truncated to 32 bits.
    call xml_last_error
    shl rdx, 32
    mov eax, eax
    or rax, rdx
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_node_count:
    call xml_node_count
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_text_runs:
    ; rdi = node
    mov rdi, [rsp + ALL_RDI]
    call xml_text_runs
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_text_run:
    ; rdi = node, rsi = run index, rdx = out, r10 = max
    mov rdi, [rsp + ALL_RDX]
    mov rsi, [rsp + ALL_R10]
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    mov rdi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov rcx, [rsp + ALL_RDX]
    mov r8,  [rsp + ALL_R10]
    call xml_text_run
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_namespace:
    ; rdi = node, rsi = prefix, rdx = prefix len, r10 = out, r8 = max
    cmp qword [rsp + ALL_RDX], 0
    je .sc_xml_namespace_out
    mov rdi, [rsp + ALL_RSI]
    mov rsi, [rsp + ALL_RDX]
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
.sc_xml_namespace_out:
    mov rdi, [rsp + ALL_R10]
    mov rsi, [rsp + ALL_R8]
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    mov rcx, [rsp + ALL_R10]
    mov r8,  [rsp + ALL_R8]
    call xml_namespace
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_node_namespace:
    ; rdi = node, rsi = out, rdx = max
    mov rdi, [rsp + ALL_RSI]
    mov rsi, [rsp + ALL_RDX]
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    mov rdi, [rsp + ALL_RDI]
    mov rcx, [rsp + ALL_RSI]
    mov r8,  [rsp + ALL_RDX]
    call xml_node_namespace
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_xml_entity_value:
    ; rdi = name, rsi = name len, rdx = out, r10 = max
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    mov rdi, [rsp + ALL_RDX]
    mov rsi, [rsp + ALL_R10]
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_xml_reject
    mov rsi, [rsp + ALL_RDI]
    mov rdx, [rsp + ALL_RSI]
    mov rcx, [rsp + ALL_RDX]
    mov r8,  [rsp + ALL_R10]
    call xml_entity_value
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_draw_line:
    ; rdi=x0, rsi=y0, rdx=x1, r10=y1, r8=color
    mov edi, r15d
    call raster_select_syscall_target
    mov edi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov edx, [rsp + ALL_RDX]
    mov ecx, [rsp + ALL_R10]
    mov r8d, [rsp + ALL_R8]
    call draw_line
    call raster_sc_release_target
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_fill_circle:
    ; rdi=cx, rsi=cy, rdx=r, r10=color
    mov edi, r15d
    call raster_select_syscall_target
    mov edi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov edx, [rsp + ALL_RDX]
    mov ecx, [rsp + ALL_R10]
    call fill_circle
    call raster_sc_release_target
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_fill_triangle:
    ; rdi = coords ptr (24 bytes: 6 int32), rsi = color
    mov rdi, [rsp + ALL_RDI]
    mov rsi, 24
    call sc_validate_user_io_range
    test eax, eax
    jz .sc_fill_triangle_reject
    mov edi, r15d
    call raster_select_syscall_target
    mov rdi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    call fill_triangle
    call raster_sc_release_target
    mov qword [rsp + ALL_RAX], 0
    jmp .done
.sc_fill_triangle_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_blend_pixel:
    ; rdi = x, rsi = y, rdx = color
    mov edi, r15d
    call raster_select_syscall_target
    mov edi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov edx, [rsp + ALL_RDX]
    call blend_pixel
    call raster_sc_release_target
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_blend_span:
    ; rdi = x, rsi = y, rdx = len, r10 = color
    mov edi, r15d
    call raster_select_syscall_target
    mov edi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov edx, [rsp + ALL_RDX]
    mov ecx, [rsp + ALL_R10]
    call blend_span
    call raster_sc_release_target
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_blend_span_argb:
    ; rdi = x, rsi = y, rdx = len (pixels), r10 = ARGB src buffer.
    ; Batches one scanline run: replaces `len` per-pixel blend syscalls.
    ; 64-bit + unsigned length math so len*4 cannot wrap a 32-bit register
    ; and slip a huge range through with byte-len=0.
    mov edx, [rsp + ALL_RDX]          ; zero-extends into rdx
    test rdx, rdx
    jz .sc_blend_span_argb_done
    cmp rdx, 0x100000                 ; cap at 1M pixels — far above any real scanline
    ja .sc_blend_span_argb_done
    mov rdi, [rsp + ALL_R10]          ; src buffer ptr
    mov rsi, rdx
    shl rsi, 2                        ; byte length = len * 4 (64-bit, safe)
    call sc_validate_user_range
    test eax, eax
    jz .sc_blend_span_argb_done
    mov edi, r15d
    call raster_select_syscall_target
    mov edi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov edx, [rsp + ALL_RDX]
    mov rcx, [rsp + ALL_R10]
    call blend_span_argb
    call raster_sc_release_target
.sc_blend_span_argb_done:
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_blend_span_argb_screen:
    ; rdi = x, rsi = y, rdx = len (pixels), r10 = ARGB src buffer.
    ; mix-blend-mode: screen variant of sc_blend_span_argb. See _argb above
    ; for why the length math is 64-bit unsigned with an explicit cap.
    mov edx, [rsp + ALL_RDX]
    test rdx, rdx
    jz .sc_blend_span_argb_screen_done
    cmp rdx, 0x100000
    ja .sc_blend_span_argb_screen_done
    mov rdi, [rsp + ALL_R10]
    mov rsi, rdx
    shl rsi, 2
    call sc_validate_user_range
    test eax, eax
    jz .sc_blend_span_argb_screen_done
    mov edi, r15d
    call raster_select_syscall_target
    mov edi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov edx, [rsp + ALL_RDX]
    mov rcx, [rsp + ALL_R10]
    call blend_span_argb_screen
    call raster_sc_release_target
.sc_blend_span_argb_screen_done:
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_blend_span_argb_multiply:
    ; rdi = x, rsi = y, rdx = len (pixels), r10 = ARGB src buffer.
    ; mix-blend-mode: multiply variant of sc_blend_span_argb. See _argb above
    ; for why the length math is 64-bit unsigned with an explicit cap.
    mov edx, [rsp + ALL_RDX]
    test rdx, rdx
    jz .sc_blend_span_argb_multiply_done
    cmp rdx, 0x100000
    ja .sc_blend_span_argb_multiply_done
    mov rdi, [rsp + ALL_R10]
    mov rsi, rdx
    shl rsi, 2
    call sc_validate_user_range
    test eax, eax
    jz .sc_blend_span_argb_multiply_done
    mov edi, r15d
    call raster_select_syscall_target
    mov edi, [rsp + ALL_RDI]
    mov esi, [rsp + ALL_RSI]
    mov edx, [rsp + ALL_RDX]
    mov rcx, [rsp + ALL_R10]
    call blend_span_argb_multiply
    call raster_sc_release_target
.sc_blend_span_argb_multiply_done:
    mov qword [rsp + ALL_RAX], 0
    jmp .done

; ---------------------------------------------------------------------------
; sc_media_blit_scaled — aspect-preserving BGRA blit into a window's client
; area. Used by the Media Player (and any future timeline-bearing app) so
; the codec dispatch and control-bar drawing can live in user-mode NexusHL
; instead of being trapped in kernel asm.
;
; Args (already loaded from caller registers):
;   rdi = window_id (low 32 bits)
;   rsi = src_ptr (BGRA buffer in caller's slot)
;   rdx = packed dims: (src_w << 16) | src_h, each in [1, 4096]
;   r10 = reserve_bottom_px (0..scr_height, clamped)
;   r8  = alpha_key (any nonzero treated as 1)
; Returns: 0 on success, -1 if any input is rejected.
;
; Dims are packed so the syscall fits in NexusHL's 6-argument syscall()
; arity. Both halves are validated as if they had been separate args —
; bounding happens before any arithmetic on them.
;
; Security invariants
; -------------------
;  * src_w / src_h bounded to [1, MEDIA_MAX_DIM] (4096). Caps the divide
;    inputs in nx_media_blit_scaled and the byte-range computed below.
;  * src_w * src_h * 4 computed in 64-bit and bounded to MEDIA_MAX_BYTES
;    (64 MB) before being handed to sc_validate_user_range, so a hostile
;    caller cannot induce arithmetic overflow that would wrap the range
;    check.
;  * src_ptr range must lie entirely within the caller's app slot or the
;    built-in user blob (sc_validate_user_range — same predicate used by
;    sc_blend_span_argb).
;  * window_id < MAX_WINDOWS. The window struct address is computed from
;    a bounded index so a forged id cannot redirect the scaler's writes
;    elsewhere.
;  * reserve_bottom_px is clamped to scr_height, so an absurd value
;    cannot make the scaler's internal client_h go negative and walk
;    backwards through memory.
;  * alpha_key is reduced to {0,1} by `cmp/setnz` — any caller-supplied
;    bit pattern lands on one of the two intended paths.
; ---------------------------------------------------------------------------
.sc_media_blit_scaled:
    ; Unpack dims: rdx = (src_w << 16) | src_h.
    mov eax, edx
    shr eax, 16                              ; src_w
    mov ecx, edx
    and ecx, 0xFFFF                          ; src_h

    ; Bound each half.
    test eax, eax
    jz .sc_media_blit_reject
    cmp eax, MEDIA_MAX_DIM
    ja .sc_media_blit_reject
    test ecx, ecx
    jz .sc_media_blit_reject
    cmp ecx, MEDIA_MAX_DIM
    ja .sc_media_blit_reject

    ; byte_len = src_w * src_h * 4 in 64-bit; reject overflow or > cap.
    mov ebx, eax                             ; stash src_w
    mov r11d, ecx                            ; stash src_h
    imul rax, rcx                            ; rax = w*h (fits in 64 bits)
    shl rax, 2                               ; * 4 bpp
    cmp rax, MEDIA_MAX_BYTES
    ja .sc_media_blit_reject
    mov r14, rax                             ; stash byte_len

    ; Validate src range — sc_validate_user_range takes (rdi=ptr, rsi=len).
    mov rdi, rsi
    mov rsi, r14
    call sc_validate_user_range
    test eax, eax
    jz .sc_media_blit_reject

    ; Validate window id (rdi at entry, reloaded fresh).
    mov rdi, [rsp + ALL_RDI]
    mov rax, rdi
    shr rax, 32
    test rax, rax
    jnz .sc_media_blit_reject                ; high half must be zero
    mov eax, edi
    cmp eax, MAX_WINDOWS
    jae .sc_media_blit_reject

    ; Resolve window struct address.
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov r13, rax

    ; Clamp reserve_bottom to scr_height.
    mov r8, [rsp + ALL_R10]                  ; reserve_bottom_px
    mov ecx, [scr_height]
    cmp r8d, ecx
    jbe .sc_media_blit_reserve_ok
    mov r8d, ecx
.sc_media_blit_reserve_ok:

    ; Reduce alpha_key to {0,1}.
    mov r9, [rsp + ALL_R8]                   ; alpha_key
    xor eax, eax
    test r9, r9
    setnz al

    ; Load scaler register contract:
    ;   r12 = src, r13 = window, r14d = src_w, r15d = src_h,
    ;   dl = alpha_key, r9d = reserve_bottom
    mov r12, [rsp + ALL_RSI]
    mov r14d, ebx
    mov r15d, r11d
    mov edx, eax                             ; alpha_key in dl
    mov r9d, r8d                             ; reserve_bottom
    call nx_media_blit_scaled

    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_media_blit_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

