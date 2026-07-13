; Draw a specific window: RDI = window ID
FN_BEGIN wm_draw_window, 1, 0, FN_RET_VOID
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Calculate struct pointer
    mov rax, rdi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov rbx, rax

    ; Launch-ordering race gate. A window is drawable only once WF_READY is set
    ; (wm_window_finalize, after the manifest is applied, the L3 slot is seeded,
    ; and the signed handlers are installed). During the launch gap rendering
    ; would either present uninitialized slot state (blank/garbage client) or
    ; dispatch the app draw callback whose syscalls the capability gate then
    ; rejects (dropped draw -> white window). Skip the whole window until ready;
    ; wm_window_finalize marks the scene dirty so the first frame it appears in is
    ; the fully-formed one. See WF_READY in constants.inc.
    test qword [rbx + WIN_OFF_FLAGS], WF_READY
    jz .content_done

    ; Load dimensions
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    ; --- Raised bevel border (VGA98 style) ---
    ; Outer black frame
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8d, COLOR_BEVEL_XDK
    call render_rect

    ; Top highlight
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, COLOR_BEVEL_LT
    call draw_hline

    ; Left highlight
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    mov rcx, COLOR_BEVEL_LT
    call draw_vline

    ; Bottom shadow (1px up from outer)
    mov rdi, r12
    mov rsi, r13
    add rsi, r15
    sub rsi, 1
    mov rdx, r14
    mov rcx, COLOR_BEVEL_DK
    call draw_hline

    ; Right shadow (1px left from outer)
    mov rdi, r12
    add rdi, r14
    sub rdi, 1
    mov rsi, r13
    mov rdx, r15
    mov rcx, COLOR_BEVEL_DK
    call draw_vline

    ; --- Client area ---
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov rcx, r15
    sub rcx, TITLEBAR_HEIGHT
    sub rcx, BORDER_WIDTH
    ; Clamp to at least 0
    cmp rcx, 0
    jle .skip_client
    cmp rdx, 0
    jle .skip_client
    mov r8d, COLOR_WINDOW_BG
    call render_rect
.skip_client:

    ; --- Title bar ---
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, BORDER_WIDTH
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, TITLEBAR_HEIGHT - BORDER_WIDTH
    mov rax, [rbx + WIN_OFF_FLAGS]
    test rax, WF_FOCUSED
    jnz .tb_focused
    mov r8d, COLOR_TITLEBAR_UNF
    jmp .tb_draw
.tb_focused:
    mov r8d, COLOR_TITLEBAR
.tb_draw:
    call render_rect

    ; --- Title text ---
    mov rdi, r12
    add rdi, 8
    mov rsi, r13
    add rsi, 5
    lea rdx, [rbx + WIN_OFF_TITLE]
    ; Active/inactive titlebars have separate foreground tokens so both remain
    ; readable in light and dark themes.
    mov rax, [rbx + WIN_OFF_FLAGS]
    test rax, WF_FOCUSED
    jnz .tt_focused
    mov ecx, COLOR_TITLE_TEXT_UNF
    mov r8d, COLOR_TITLEBAR_UNF
    jmp .tt_draw
.tt_focused:
    mov ecx, COLOR_TITLE_TEXT
    mov r8d, COLOR_TITLEBAR
.tt_draw:
    call render_text

    ; --- Close button [X] ---
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE + 4
    mov rsi, r13
    add rsi, 4
    mov edx, CLOSE_BTN_SIZE
    mov ecx, CLOSE_BTN_SIZE
    mov r8d, COLOR_CLOSE_BTN
    call render_rect

    ; Close icon
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE + 3
    mov rsi, r13
    add rsi, 5
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, nx_icon_close_16
    call nx_icon_blit

    ; --- Minimize button [-] ---
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE * 2 + 8
    mov rsi, r13
    add rsi, 4
    mov edx, MIN_BTN_SIZE
    mov ecx, MIN_BTN_SIZE
    mov r8d, COLOR_MIN_BTN
    call render_rect

    ; Min label
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE * 2 + 5
    mov rsi, r13
    add rsi, 5
    mov rdx, szMinDash
    mov ecx, COLOR_TEXT_BLACK
    mov r8d, COLOR_MIN_BTN
    call render_text

    ; --- App content ---
    ; Call draw_fn if set, else default content
    mov rax, [rbx + WIN_OFF_DRAWFN]
    test rax, rax
    jz .default_content
    cmp rax, app_media_draw
    jne .dispatch_user_draw
    mov rdi, rbx
    call app_media_draw
    jmp .draw_done
.dispatch_user_draw:
    mov rdi, rax
    mov rsi, rbx         ; arg0: window_ptr
    xor edx, edx         ; arg1
    xor ecx, ecx         ; arg2
    call dispatch_app_callback
.draw_done:
    jmp .content_done

.default_content:
    ; Default: show "Empty Window"
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 8
    mov rdx, szEmptyWin
    mov ecx, COLOR_TEXT_GRAY
    mov r8d, COLOR_WINDOW_BG
    call render_text

.content_done:
    FN_END wm_draw_window
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wm_handle_mouse_event migrated to src/kernel/grithlk/wm_helpers.ghl.
; Keep click/drag callback routing in GritHLK so the event path cannot dispatch
; a tagged/stale window-struct pointer directly into ring 3.
; Draw drag outline (called from main loop when dragging)
; Uses wm_drag_preview_x/y/w/h to draw a 2px rectangle outline
global wm_draw_drag_outline
FN_BEGIN wm_draw_drag_outline, 0, 0, FN_RET_VOID
    cmp qword [wm_drag_window_id], -1
    je .outline_ret

    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, [wm_drag_preview_x]    ; x
    mov r13, [wm_drag_preview_y]    ; y
    mov r14, [wm_drag_preview_w]    ; w
    mov r15, [wm_drag_preview_h]    ; h

    ; Top edge: full width, 2px tall
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, 2
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    ; Bottom edge
    mov edi, r12d
    mov esi, r13d
    add esi, r15d
    sub esi, 2
    mov edx, r14d
    mov ecx, 2
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    ; Left edge
    mov edi, r12d
    mov esi, r13d
    mov edx, 2
    mov ecx, r15d
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    ; Right edge
    mov edi, r12d
    add edi, r14d
    sub edi, 2
    mov esi, r13d
    mov edx, 2
    mov ecx, r15d
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.outline_ret:
    FN_END wm_draw_drag_outline
    ret

; wm_mark_outline_dirty migrated to src/kernel/grithlk/wm_helpers.ghl
; (R8=x R9=y R10=w R11=h; four render_mark_dirty edge calls).

; wm_get_window_at migrated to src/kernel/grithlk/wm_helpers.ghl
; (RDI=x RSI=y -> RAX=window ID or -1; pure geometry hit-test).

; ============================================================================
; §6 - Kernel-owned per-slot callback trampoline
;
; Threat: today the WM invokes app callbacks by reading a RAW function pointer
; straight out of the window struct (WIN_OFF_CLICKFN/KEYFN/DRAGFN/RCLICKFN) and
; jumping to it, so the invocation target is a ring-3-influenced qword.
;
; This adds a kernel-owned indirection so the WM's invocation no longer trusts
; the window-struct qword as the call target. Each (slot, field) callback is
; INTERNED - the pointer is copied into a per-slot callback table that lives in
; KERNEL BSS, OUTSIDE the ring-3 app arena (so an app's own slot-memory write
; bug can't forge an entry) - and the WM then dispatches by ID through
; wm_cb_resolve/wm_cb_trampoline, which read the target from the kernel table.
; The window struct's qword is reduced to "intern input", not "the address we
; jump to". Same per-slot-array + index discipline as the handle table
; (src/kernel/proc/handle_table.inc): one fixed-size row per slot, kernel BSS.
;
; SCOPE (strict file ownership; other agents edit syscall.asm / main.asm /
; launch.inc concurrently):
;   - INVOCATION sites this file owns are routed through the table:
;     CLICKFN (.client_click), RCLICKFN (.right_click), DRAGFN
;     (.app_drag_active). The call target is taken from wm_cb_table, not the
;     window struct.
;   - REGISTRATION (apps installing a callback) lives in syscall.asm
;     (.sc_wm_handlers, CLICKFN/KEYFN) and src/user/apps/launch.inc (KEYFN
;     direct write) - NOT owned here. The full ABI cutover (app registers a
;     slot-local ID instead of a raw pointer; the kernel interns at
;     registration time via wm_cb_intern) requires those owners to call
;     wm_cb_intern at the store site and have apps pass an ID. Until then we
;     intern lazily at dispatch, which still removes the raw pointer from the
;     WM's call target and gives the table a single trusted fill point.
;   - KEYFN INVOCATION lives in main.asm (the two WIN_OFF_KEYFN dispatch
;     sites) - NOT owned here. That owner should swap
;     `mov rdi,[win+KEYFN]; call dispatch_app_callback` for the same
;     intern+`call wm_cb_trampoline` shape used below (field id
;     WM_CB_FIELD_KEY reserved for it).
;   - If CPI-lite callback signing (cpi_sign/verify_callback) lands/relands in
;     this dispatch path, intern the CPI-VERIFIED pointer (defense in depth):
;     verify first, then pass the cleaned pointer to wm_cb_intern.
; ============================================================================

; Per-(slot,field) callback target table - kernel BSS, indexed
; [slot * WM_CB_FIELDS + field]. Holds the trusted kernel-image VA the WM will
; actually jump to. A zero entry means "no callback interned".
WM_CB_FIELD_CLICK   equ 0
WM_CB_FIELD_KEY     equ 1            ; reserved for the main.asm KEYFN site
WM_CB_FIELD_DRAG    equ 2
WM_CB_FIELD_RCLICK  equ 3
WM_CB_FIELDS        equ 4

; wm_cb_intern and wm_cb_resolve migrated to src/kernel/grithlk/wm_helpers.ghl
; (bounded callback-table fill/lookup with #UD-on-OOB indexing). WM_CB_FIELDS /
; WM_CB_FIELD_* equs above stay here (used by the mouse handler + trampoline);
; the wm_cb_table BSS array is defined below. wm_cb_trampoline (CPI-adjacent
; dispatch) stays in asm and calls wm_cb_resolve cross-module within this unit.

; wm_cb_trampoline - the kernel-owned invoker. Resolve a slot-local callback id
; against the table and dispatch the stored TRUSTED target.
;   EDI = slot-local callback id (0 = none)
;   RSI = window ptr (arg0); RDX = arg1; RCX = arg2
; Returns dispatch_app_callback's rax, or 0 (no call) if the id resolves empty.
; Clobbers per dispatch_app_callback. Exposed (FN_BEGIN -> global) so the
; main.asm KEYFN dispatch site can route through it in a later cutover.
FN_BEGIN wm_cb_trampoline, 4, 0, FN_RET_SCALAR
    push rsi
    push rdx
    push rcx
    call wm_cb_resolve                ; rax = trusted target from kernel BSS
    pop rcx
    pop rdx
    pop rsi
    test rax, rax
    jz .ct_none
    mov rdi, rax                      ; target from KERNEL table, not the window
    call dispatch_app_callback
    FN_END wm_cb_trampoline
    ret
.ct_none:
    xor eax, eax
    FN_END wm_cb_trampoline
    ret

