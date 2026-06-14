; L3 self-test window handlers. Debug-only: their strings (szL3*) carry markers
; the release-artifact scan forbids in a public image, and no kernel code
; references these handlers, so the whole self-test is gated out of -Release.
%ifndef RELEASE_BUILD
app_l3_test_draw:
    push rdi
    push r14
    ;SYS_PRINT szL3DrawOk
    mov rdi, [rsp + 8]
    mov r14, [rdi + WIN_OFF_APPDATA]
    cmp byte [r14], 1
    je .skip_selftest
    mov byte [r14], 1
    ;SYS_PRINT szL3T0
    SYS_FS_COUNT
    mov [r14 + 8], eax
    ;SYS_PRINT szL3T4
    xor edi, edi
    SYS_FS_ENTRY rdi
    mov [r14 + 16], rax
    test rax, rax
    jz .skip_selftest
    ;SYS_PRINT szL3T5
    xor edi, edi
    SYS_FS_CHDIR rdi
    ;SYS_PRINT szL3T6
    mov rdi, [r14 + 16]
    lea rsi, [r14 + 256]
    mov rdx, 64
    SYS_FS_READ rdi, rsi, rdx
    mov [r14 + 24], eax
    ;SYS_PRINT szL3T8
    mov rdi, [r14 + 16]
    lea rsi, [r14 + 128]
    SYS_FS_FORMAT_NAME rdi, rsi
    ;SYS_PRINT szL3T11
    lea rdi, [rel szL3Tmp83]
    lea rsi, [rel szL3TmpData]
    mov rdx, 4
    SYS_FS_WRITE rdi, rsi, rdx
    ;SYS_PRINT szL3T13
    SYS_FS_SYNC_ROOT
    ;SYS_PRINT szL3T14
    SYS_CURSOR_INIT
    ;SYS_PRINT szL3T17
.skip_selftest:
    pop r14
    pop rdi
    mov rax, [rdi + WIN_OFF_X]
    add rax, BORDER_WIDTH + 8
    mov rsi, [rdi + WIN_OFF_Y]
    add rsi, TITLEBAR_HEIGHT + 8
    mov rdi, rax
    mov edx, 80
    mov ecx, 24
    mov r8d, LAUNCH_COL_L3_PANEL
    SYS_GUI_RECT rdi, rsi, rdx, rcx, r8
    lea rdx, [szL3DrawOk]
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, LAUNCH_COL_L3_PANEL
    SYS_GUI_TEXT rdi, rsi, rdx, rcx, r8
    ret

app_l3_test_click:
    push rdi
    lea rdi, [szL3ClickOk]
    SYS_PRINT rdi
    pop rdi
    ret

app_l3_test_key:
    push rdi
    lea rdi, [szL3KeyOk]
    SYS_PRINT rdi
    pop rdi
    ret
%endif

extern cpi_sign_callback

; RAX = window ID, R10 = click handler, R11 = key handler.
; Drag handler (optional): install separately via app_set_window_drag below
; (kept as a separate helper so existing callers stay unchanged and we never
; clobber a stale value).
;
; Both handlers are run through cpi_sign_callback before being committed to
; the window struct, so a later attacker who overwrites these slots without
; knowing kernel_canary AND &window produces a value the dispatcher will
; reject (kernel_panic_canary). See cpi_sign_callback in syscall.asm.
app_set_window_handlers:
    push rcx
    push rdx
    push rdi
    push rsi
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    push rax
    mov rdi, r10
    mov rsi, rax
    mov rdx, WIN_OFF_CLICKFN
    call cpi_sign_callback
    mov rcx, rax                      ; signed click_fn
    mov rax, [rsp]                    ; &window
    mov rdi, r11
    mov rsi, rax
    mov rdx, WIN_OFF_KEYFN
    call cpi_sign_callback
    pop rdi                           ; &window
    mov [rdi + WIN_OFF_CLICKFN], rcx
    mov [rdi + WIN_OFF_KEYFN], rax
    pop rax
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; RAX = window ID, R10 = drag handler. Same calling convention as click:
;   drag_fn(rsi=win_ptr, rdx=client_x, rcx=client_y).
; The WM fires drag_fn for every mouse-poll tick where the cursor has moved
; AND the left button is still held AND the initial press landed on this
; window's client area. The cursor may leave the window's bounds - drag
; events keep flowing until the button is released. Pass 0 to detach.
app_set_window_drag:
    push rcx
    push rdx
    push rdi
    push rsi
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov rdi, r10
    mov rsi, rax
    mov rdx, WIN_OFF_DRAGFN
    push rax
    call cpi_sign_callback
    pop rdi
    mov [rdi + WIN_OFF_DRAGFN], rax
    pop rax
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; RAX = window ID, R10 = right-click handler. Same calling convention as click:
;   rclick_fn(rsi=win_ptr, rdx=client_x, rcx=client_y).
; Fired once on right-button-down inside a window's client area. Pass 0 to
; detach. Apps use this for context menus or custom secondary actions.
app_set_window_rclick:
    push rcx
    push rdx
    push rdi
    push rsi
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov rdi, r10
    mov rsi, rax
    mov rdx, WIN_OFF_RCLICKFN
    push rax
    call cpi_sign_callback
    pop rdi
    mov [rdi + WIN_OFF_RCLICKFN], rax
    pop rax
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; RAX = window ID. Preserve RAX.
; The GritHL notepad callbacks read state from the window's L3 slot copy of
; the app blob. ALL per-instance notepad state must be written through this
; helper (slot-relative) - never to the kernel image's master copy, which is
; shared across all instances and is only a linker placeholder.
app_seed_notepad_slot:
    push rax
    push rbx
    push rcx
    push rdi

    mov edi, eax
    call l3_copy_app_blob_to_slot
    mov rbx, rax

    ; SMAP: the slot is a user (PTE.U=1) page; bracket the kernel-side seed
    ; writes with stac/clac. l3_copy_app_blob_to_slot above already re-armed
    ; SMAP on return, so AC is clear here.
    USER_ACCESS_BEGIN
    ; Starter text "Hello"
    mov byte [rbx + notepad_buf - app_blob_start + 0], 'H'
    mov byte [rbx + notepad_buf - app_blob_start + 1], 'e'
    mov byte [rbx + notepad_buf - app_blob_start + 2], 'l'
    mov byte [rbx + notepad_buf - app_blob_start + 3], 'l'
    mov byte [rbx + notepad_buf - app_blob_start + 4], 'o'
    mov byte [rbx + notepad_buf - app_blob_start + 5], 0
    mov dword [rbx + np_line_len - app_blob_start], 5
    mov dword [rbx + np_cursor_row - app_blob_start], 0
    mov dword [rbx + np_cursor_col - app_blob_start], 5
    mov dword [rbx + np_num_lines - app_blob_start], 1
    mov dword [rbx + np_scroll_top - app_blob_start], 0

    ; Reset transient UI / dialog state in the slot
    mov byte  [rbx + np_menu_open - app_blob_start], 0
    mov byte  [rbx + np_save_dialog - app_blob_start], 0
    mov byte  [rbx + np_save_done_msg - app_blob_start], 0
    mov byte  [rbx + np_has_saved - app_blob_start], 0
    mov dword [rbx + np_save_field - app_blob_start], 0
    mov dword [rbx + np_saveas_cursor - app_blob_start], 0
    mov byte  [rbx + np_saveas_buf - app_blob_start], 0
    mov dword [rbx + np_saveloc_cursor - app_blob_start], 1
    mov byte  [rbx + np_saveloc_buf - app_blob_start], 47       ; '/'
    mov byte  [rbx + np_saveloc_buf - app_blob_start + 1], 0
    mov qword [rbx + np_open_entry - app_blob_start], 0
    USER_ACCESS_END

    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; RAX = window ID. Preserve RAX.
; GritHL app state is read from the per-window L3 slot. When a window slot is
; reused, call_app_l3 sees the existing magic and does not recopy the blob, so
; launch-time state resets done above would otherwise stay invisible.
app_refresh_window_slot:
    push rax
    push rdi

    mov edi, eax
    call l3_copy_app_blob_to_slot

    pop rdi
    pop rax
    ret

; RAX = Explorer window ID. Preserve RAX.
app_reset_explorer_slot:
    push rax
    push rbx
    push rdi

    mov edi, eax
    call l3_slot_base
    mov rbx, rax
    ; SMAP: slot base (rax) is a user (PTE.U=1) page. Bracket these resets.
    USER_ACCESS_BEGIN
    mov dword [rbx + explorer_sel - app_blob_start], 0
    mov dword [rbx + explorer_dir - app_blob_start], 0
    mov byte [rbx + ctx_menu_visible - app_blob_start], 0
    mov byte [rbx + exp_ctx_visible - app_blob_start], 0
    mov byte [rbx + exp_rename_active - app_blob_start], 0
    mov byte [rbx + exp_newfolder_active - app_blob_start], 0
    mov byte [rbx + exp_newfolder_done_msg - app_blob_start], 0
    mov byte [rbx + exp_prop_visible - app_blob_start], 0
    mov dword [rbx + exp_rename_cursor - app_blob_start], 0
    mov dword [rbx + exp_newfolder_cursor - app_blob_start], 0
    mov byte [rbx + exp_rename_buf - app_blob_start], 0
    mov byte [rbx + exp_newfolder_buf - app_blob_start], 0
    USER_ACCESS_END

    pop rdi
    pop rbx
    pop rax
    ret


; APPLY_MANIFEST app_id
;
; After wm_create_window_ex returns rax = slot id, narrow that slot's
; syscall capability mask to the app's declared manifest. Required for every
; launch path - without this the slot keeps the CAP_ALL default and the
; sandbox is effectively off. Preserves rax / rdi / rsi so the launcher can
; keep treating rax as the slot id and continue its post-create work.
extern kernel_apply_app_manifest
extern app_segment_verify
%macro APPLY_MANIFEST 1
    push rax
    push rdi
    push rsi
    mov rdi, %1
    call app_segment_verify
    mov rdi, [rsp + 16]
    mov rsi, %1
    call kernel_apply_app_manifest
    pop rsi
    pop rdi
    pop rax
%endmacro

; ============================================================================
; app_launch - Launch an app by ID  (kfault-guarded fail-soft wrapper)
; RDI = app ID (2..6)
; Returns: RAX = window ID or -1
;
; The launch path runs entirely in ring 0 and touches per-slot user pages,
; the window pool, fat16 globals, and the integrity verifier. A ring-0 fault
; anywhere in there used to be unrecoverable: the ISR fell through to the
; verbose register dump, blew the (small) faulting stack, took a #DF, and the
; nested-exception guard halted the whole OS (observed as "clicking Notepad
; freezes everything", esp. under KASLR when a stale absolute pointer derefs a
; user page -> SMAP #PF). We now bracket the real launch body with a kfault
; guard: on a ring-0 fault the ISR logs a compact KREC line (incl. the
; slide-relative RIP) and longjmps to .al_land, which aborts the launch and
; returns -1. The bad app simply fails to open; the desktop keeps running.
; ============================================================================
extern kfault_arm
extern kfault_disarm
global app_launch