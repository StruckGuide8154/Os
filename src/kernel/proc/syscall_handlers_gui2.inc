; ============================================================================
; syscall_handlers_gui2.inc
; syscall_entry handlers for the gui2 retained-mode library:
;   .sc_gui_batch        (SYS_GUI_BATCH      = 77)
;   .sc_gui_present      (SYS_GUI_PRESENT    = 78)
;   .sc_gui_glyph_bake   (SYS_GUI_GLYPH_BAKE = 79)
;
; %included into syscall.asm inside syscall_entry's local-label scope (right
; after syscall_handlers_gui_wm.inc), so .done, ALL_*, sc_validate_user_io_range
; and sc_validate_user_cstring are all in scope here. render_rect/render_text/
; render_mark_dirty/render_mark_full/render_flush and scr_width/scr_height are
; extern (declared in syscall.asm).
;
; SECURITY MODEL: the dispatcher's table-driven PTR check (SC_DESC_LEN(0,2) +
; SC_FLAG_STRICT) only proves the *count*-byte prefix is mapped; the real
; record_count*64 / rect_count*32 byte ranges are re-validated here BEFORE any
; record is walked. Every per-record user pointer (OP_TEXT str_ptr) is
; re-validated against the calling slot's user range before it reaches a
; renderer. The walk runs off a kernel-local copy of the count, never a
; re-read of user memory. Widths/coords are consumed as 32-bit halves (edi/esi/
; edx/ecx) exactly like .sc_gui_rect so a stale high half can't corrupt the
; renderer's clipping arithmetic.
; ============================================================================

; ----------------------------------------------------------------------------
; .sc_gui_batch - SYS_GUI_BATCH(rdi=buf_ptr, rsi=record_count)
;   Returns the number of primitives actually drawn in rax, or -1 on reject.
; ----------------------------------------------------------------------------
.sc_gui_batch:
    ; rdi = user command buffer, rsi = record count.
    ; Reject empty or oversize batches up front (rsi is a full 64-bit count).
    test rsi, rsi
    jz .sc_gui_batch_reject
    cmp rsi, GUI_MAX_RECORDS
    ja .sc_gui_batch_reject
    ; byte length = count * 64. count <= 4096 so this cannot overflow 64-bit.
    mov rax, rsi
    shl rax, 6                          ; * GUI_REC_SIZE (64)
    ; Range-check the whole buffer against the calling slot's user mapping.
    ; (rdi = ptr, rsi = byte len) -> eax nonzero ok.
    push rdi                            ; keep base ptr
    push rsi                            ; keep raw record count (kernel copy)
    mov rsi, rax                        ; byte length
    call sc_validate_user_io_range
    test eax, eax
    pop rsi                             ; rsi = record count (kernel-local copy)
    pop rdi                             ; rdi = base ptr
    jz .sc_gui_batch_reject

    ; Walk: r12 = current record ptr, r13 = records remaining (kernel copy),
    ; r14 = primitives-drawn accumulator. These are callee-saved across the
    ; kernel syscall path, so we save/restore them.
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
.sc_gui_batch_loop:
    test r13, r13
    jz .sc_gui_batch_done
    mov rax, [r12 + GUI_REC_OP]
    cmp rax, GUI_OP_NOP
    je .sc_gui_batch_next
    cmp rax, GUI_OP_RECT
    je .sc_gui_batch_rect
    cmp rax, GUI_OP_TEXT
    je .sc_gui_batch_text
    ; OP_GLYPH(3) / OP_CLIP(4) / OP_BLIT(5): no-op for this first landing.
    ; TODO(gui2): OP_GLYPH = blit from the (not-yet-implemented) glyph atlas;
    ; TODO(gui2): OP_CLIP = push/pop a clip rect (C<0 = pop) and honour it in
    ;             RECT/TEXT clamping; OP_BLIT = validated slot-local surface
    ;             blit. Until then they advance without drawing and are NOT
    ;             counted as primitives. Any pointer/size carried in these
    ;             records is therefore never dereferenced (no unchecked trust).
    jmp .sc_gui_batch_next

.sc_gui_batch_rect:
    ; A=x B=y C=w D=h E=color. Consume 32-bit halves and clamp like .sc_gui_rect
    ; so an out-of-range value can't feed the renderer's clipping arithmetic.
    mov edi, [r12 + GUI_REC_A]          ; x
    cmp edi, [scr_width]
    ja .sc_gui_batch_next
    mov esi, [r12 + GUI_REC_B]          ; y
    cmp esi, [scr_height]
    ja .sc_gui_batch_next
    mov edx, [r12 + GUI_REC_C]          ; w
    cmp edx, [scr_width]
    ja .sc_gui_batch_next
    mov ecx, [r12 + GUI_REC_D]          ; h
    cmp ecx, [scr_height]
    ja .sc_gui_batch_next
    mov r8d, [r12 + GUI_REC_E]          ; color
    ; render_rect(rdi=x, rsi=y, rdx=w, rcx=h, r8=color)
    call render_rect
    inc r14
    jmp .sc_gui_batch_next

.sc_gui_batch_text:
    ; A=x B=y C=str_ptr D=fg E=bg F=len. Re-validate the embedded user string
    ; pointer against the calling slot before draw_string walks it.
    mov edi, [r12 + GUI_REC_A]          ; x
    cmp edi, [scr_width]
    ja .sc_gui_batch_next
    mov esi, [r12 + GUI_REC_B]          ; y
    cmp esi, [scr_height]
    ja .sc_gui_batch_next
    mov rdi, [r12 + GUI_REC_C]          ; str_ptr (full 64-bit user pointer)
    mov rsi, SYSCALL_MAX_STR_LEN
    call sc_validate_user_cstring
    test eax, eax
    jz .sc_gui_batch_next               ; bad string ptr -> skip, not fatal
    ; render_text(rdi=x, rsi=y, rdx=cstring, rcx=fg, r8=bg)
    mov edi, [r12 + GUI_REC_A]          ; x
    mov esi, [r12 + GUI_REC_B]          ; y
    mov rdx, [r12 + GUI_REC_C]          ; cstring ptr (validated)
    mov ecx, [r12 + GUI_REC_D]          ; fg
    mov r8d, [r12 + GUI_REC_E]          ; bg
    call render_text
    inc r14
    jmp .sc_gui_batch_next

.sc_gui_batch_next:
    add r12, GUI_REC_SIZE
    dec r13
    jmp .sc_gui_batch_loop
.sc_gui_batch_done:
    mov rax, r14
    pop r14
    pop r13
    pop r12
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_gui_batch_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; ----------------------------------------------------------------------------
; .sc_gui_present - SYS_GUI_PRESENT(rdi=damage_ptr, rsi=rect_count)
;   Marks damage and flushes; returns rect_count, or -1 on reject.
; ----------------------------------------------------------------------------
.sc_gui_present:
    ; rect_count == 0 is legal: present nothing-changed -> full repaint + flush.
    test rsi, rsi
    jz .sc_gui_present_full
    cmp rsi, GUI_MAX_RECORDS
    ja .sc_gui_present_reject
    ; byte length = rect_count * 32 (4 quads). count <= 4096 -> no overflow.
    mov rax, rsi
    shl rax, 5                          ; * GUI_DAMAGE_RECT_SIZE (32)
    push rdi
    push rsi
    mov rsi, rax
    call sc_validate_user_io_range
    test eax, eax
    pop rsi
    pop rdi
    jz .sc_gui_present_reject
    ; Walk the damage rects, marking each dirty. r12=ptr, r13=remaining.
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
.sc_gui_present_loop:
    test r13, r13
    jz .sc_gui_present_flush
    ; Each rect = 4 quads x,y,w,h. render_mark_dirty(edi=x,esi=y,edx=w,ecx=h)
    ; clamps internally; we still consume 32-bit halves only.
    mov edi, [r12 + 0]                  ; x
    mov esi, [r12 + 8]                  ; y
    mov edx, [r12 + 16]                 ; w
    mov ecx, [r12 + 24]                 ; h
    call render_mark_dirty
    add r12, GUI_DAMAGE_RECT_SIZE
    dec r13
    jmp .sc_gui_present_loop
.sc_gui_present_flush:
    pop r13
    pop r12
    call render_flush
    ; TODO(gui2): true async / vblank-paced present (queue + return immediately,
    ; coalesce damage, signal completion). For now this is a synchronous flush.
    mov rax, [rsp + ALL_RSI]            ; return the (original) rect_count
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_gui_present_full:
    ; rect_count == 0: repaint everything.
    call render_mark_full
    call render_flush
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_gui_present_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; ----------------------------------------------------------------------------
; .sc_gui_glyph_bake - SYS_GUI_GLYPH_BAKE(rdi=codepoint, rsi=fg, rdx=bg)
;   Returns the atlas cell index, or -1 (GUI_GLYPH_NONE).
; ----------------------------------------------------------------------------
.sc_gui_glyph_bake:
    ; TODO(gui2): implement a real glyph atlas surface (rasterize codepoint at
    ; fg/bg into a cached cell, return its index). Until then return -1
    ; unconditionally so the userspace atlas falls back to immediate OP_TEXT,
    ; which SYS_GUI_BATCH already renders correctly. All three args are scalars,
    ; so there is nothing to validate.
    mov qword [rsp + ALL_RAX], GUI_GLYPH_NONE
    jmp .done
