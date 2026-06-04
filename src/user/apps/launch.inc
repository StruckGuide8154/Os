MEDIA_PLAYER_BAR_H equ 26

; ----------------------------------------------------------------------------
; Named constants for the launcher / L3 selftest. Values copied verbatim from
; the original inline literals.
; ----------------------------------------------------------------------------
LAUNCH_COL_L3_PANEL equ 0x0000AA44   ; L3 selftest result panel rect/text color (green, ARGB)
LAUNCH_NBA1_MAGIC   equ 0x3141424E   ; 'NBA1' little-endian file magic (NexusOS video clip)

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
; window's client area. The cursor may leave the window's bounds — drag
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
; The NexusHL notepad callbacks read state from the window's L3 slot copy of
; the app blob. ALL per-instance notepad state must be written through this
; helper (slot-relative) — never to the kernel image's master copy, which is
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
; NexusHL app state is read from the per-window L3 slot. When a window slot is
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
; launch path — without this the slot keeps the CAP_ALL default and the
; sandbox is effectively off. Preserves rax / rdi / rsi so the launcher can
; keep treating rax as the slot id and continue its post-create work.
extern kernel_apply_app_manifest
%macro APPLY_MANIFEST 1
    push rax
    push rdi
    push rsi
    mov rdi, rax
    mov rsi, %1
    call kernel_apply_app_manifest
    pop rsi
    pop rdi
    pop rax
%endmacro

; ============================================================================
; app_launch - Launch an app by ID
; RDI = app ID (2..6)
; Returns: RAX = window ID or -1
; ============================================================================
global app_launch
app_launch:
    SER 'L'
    SER '['
    push rdi
    call ser_print_hex64
    pop rdi
    SER ']'
    cmp rdi, APP_EXPLORER
    je .launch_explorer
    cmp rdi, APP_TERMINAL
    je .launch_terminal
    cmp rdi, APP_NOTEPAD
    je .launch_notepad
    cmp rdi, APP_SETTINGS
    je .launch_settings
    cmp rdi, APP_PAINT
    je .launch_paint
    cmp rdi, APP_ABOUT
    je .launch_about
    cmp rdi, APP_SECURITY_PROBE
    je .launch_security_probe
    cmp rdi, APP_TASKMGR
    je .launch_taskmgr
    cmp rdi, APP_PING
    je .launch_ping
    cmp rdi, APP_MEDIA
    je .launch_media
    mov rax, -1
    ret

.launch_explorer:
    SER 'E'
    SER 'e'
    ; Reset explorer state to root
    mov dword [explorer_sel], 0
    mov dword [explorer_dir], 0
    mov byte [ctx_menu_visible], 0
    mov byte [exp_ctx_visible], 0
    mov byte [exp_rename_active], 0
    mov byte [exp_newfolder_active], 0
    mov byte [exp_newfolder_done_msg], 0
    mov byte [exp_prop_visible], 0
    lea rdi, [rel szExplorerTitle]
    mov rsi, 120
    mov rdx, 80
    mov rcx, 420
    mov r8, 340
    mov r9, app_hl_explorer_draw
    SER '{'
    sub rsp, 8               ; Align stack
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_EXPLORER
    call app_refresh_window_slot
    call app_reset_explorer_slot
    mov r10, app_hl_explorer_click
    mov r11, app_hl_explorer_key
    call app_set_window_handlers
    mov r10, app_hl_explorer_rclick
    call app_set_window_rclick
    SER 'e'
    jmp .done

.launch_terminal:
    ; Terminal is now a pure-NexusHL app (src/user/nexushl/apps/terminal.nxh).
    ; Per-slot state lives in its state{} block (zero-initialised on copy) and
    ; the welcome banner is seeded lazily on first draw, so no launch-time
    ; state/history/fat16 seeding is required — same shape as .launch_ping.
    lea rdi, [rel szTermTitle]
    mov rsi, 200
    mov rdx, 150
    mov rcx, 450
    mov r8, 300
    mov r9, app_hl_terminal_draw
    sub rsp, 8               ; Align stack
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_TERMINAL
    mov r10, app_hl_terminal_click
    mov r11, app_hl_terminal_key
    call app_set_window_handlers
    jmp .done

.launch_notepad:
    SER 'N'
    SER 'n'
    ; Per-instance state is owned by the L3 slot; app_seed_notepad_slot below
    ; populates it. Do NOT touch the kernel image's np_* master copies here —
    ; they are linker placeholders, not shared state, and were a source of
    ; cross-instance corruption when used as scratch.
    lea rdi, [rel szNotepadTitle]
    mov rsi, 250
    mov rdx, 120
    mov rcx, 400
    mov r8, 300
    mov r9, app_hl_notepad_draw
    SER '{'
    sub rsp, 8               ; Align stack
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_NOTEPAD
    call app_seed_notepad_slot
    mov r10, app_hl_notepad_click
    mov r11, app_hl_notepad_key
    call app_set_window_handlers
    SER 'n'
    jmp .done

.launch_settings:
    SER 'S'
    SER 's'
    lea rdi, [rel szSettingsTitle]
    mov rsi, 300
    mov rdx, 180
    mov rcx, 380
    mov r8, 340
    mov r9, app_hl_settings_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_SETTINGS
    mov r10, app_hl_settings_click
    mov r11, app_hl_settings_key
    call app_set_window_handlers
    SER 's'
    jmp .done

.launch_paint:
    SER 'P'
    SER 'p'
    ; Per-instance paint state is owned by the L3 slot via the NexusHL
    ; `state {}` block; the kernel-image paint_* placeholders are unused.
    lea rdi, [rel szPaintTitle]
    mov rsi, 150
    mov rdx, 100
    mov rcx, 340   ; width (toolbar + canvas)
    mov r8, 240    ; height (toolbar + canvas)
    mov r9, app_hl_paint_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_PAINT
    mov r10, app_hl_paint_click
    mov r11, app_hl_paint_key
    call app_set_window_handlers
    mov r10, app_hl_paint_drag
    call app_set_window_drag
    SER 'p'
    jmp .done

.launch_about:
    SER 'B'
    SER 'b'
    lea rdi, [rel szAboutTitle]
    mov rsi, 280
    mov rdx, 200
    mov rcx, 380
    mov r8, 300
    mov r9, app_hl_about_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_ABOUT
    mov r10, app_hl_about_click
    mov r11, app_hl_about_key
    call app_set_window_handlers
    SER 'b'
    jmp .done

.launch_security_probe:
    lea rdi, [rel szSecurityProbeTitle]
    mov rsi, 80
    mov rdx, 70
    mov rcx, 520
    mov r8, 260
    mov r9, app_security_probe_draw
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_SECURITY_PROBE
    xor r10d, r10d
    xor r11d, r11d
    call app_set_window_handlers
    jmp .done

.launch_taskmgr:
    SER 'M'
    SER 'm'
    lea rdi, [rel szTaskMgrTitle]
    mov rsi, 200
    mov rdx, 120
    mov rcx, 360
    mov r8, 300
    mov r9, app_hl_taskmgr_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_TASKMGR
    mov r10, app_hl_taskmgr_click
    mov r11, app_hl_taskmgr_key
    call app_set_window_handlers
    SER 'm'
    jmp .done

.launch_media:
    ; The Media Player's draw fn is the kernel asm renderer (codec dispatch
    ; in media_viewer.asm), not the auto-generated app_hl_media_draw stub.
    ; Click/key still route through the nxh handlers so future UI work can
    ; live in media.nxh without touching this glue.
    lea rdi, [rel szMediaTitle]
    mov rsi, 180
    mov rdx, 120
    mov rcx, 480
    mov r8, 340
    lea r9, [rel app_media_draw]
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_MEDIA
    call app_refresh_window_slot
    mov r10, app_hl_media_click
    mov r11, app_hl_media_key
    call app_set_window_handlers
    jmp .done

.launch_ping:
    lea rdi, [rel szPingTitle]
    mov rsi, 220
    mov rdx, 90
    mov rcx, 480
    mov r8, 360
    mov r9, app_hl_ping_draw
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_PING
    mov r10, app_hl_ping_click
    mov r11, app_hl_ping_key
    call app_set_window_handlers
    jmp .done

.done:
    ret


; ============================================================================
; app_open_file - Open a file, routing by extension
; RDI = pointer to FAT16 dir entry (32 bytes)
; ============================================================================
global app_open_file
app_open_file:
    ; Extension routing. The 3-byte field at entry+8 holds the 8.3 extension,
    ; already upper-cased and space-padded by FAT16. Match against the known
    ; media extensions first; everything else opens in Notepad.
    ;
    ;   "BMP" → legacy BMP viewer (kept for back-compat)
    ;   "NIC" → Media Player (native still image)
    ;   "NBA" → Media Player (native animation)
    ;   "SVG" → Media Player (subset rasteriser; see media_viewer.inc §6)
    ;   "XML" → Media Player (renders as plain text view)
    ;
    ; Adding a new media format = one new compare block here that jumps to
    ; app_open_file_in_media, plus a codec row in media_viewer.inc §2.
    cmp byte [rdi + 8], 'B'
    jne .not_bmp
    cmp byte [rdi + 9], 'M'
    jne .not_bmp
    cmp byte [rdi + 10], 'P'
    jne .not_bmp
    jmp app_open_file_in_bmpview
.not_bmp:
    cmp byte [rdi + 8], 'N'
    jne .check_svg
    cmp byte [rdi + 9], 'I'
    jne .check_nba
    cmp byte [rdi + 10], 'C'
    jne .not_native_media
    jmp app_open_file_in_media
.check_nba:
    cmp byte [rdi + 9], 'B'
    jne .not_native_media
    cmp byte [rdi + 10], 'A'
    jne .not_native_media
    jmp app_open_file_in_media
.check_svg:
    cmp byte [rdi + 8], 'S'
    jne .check_xml
    cmp byte [rdi + 9], 'V'
    jne .not_native_media
    cmp byte [rdi + 10], 'G'
    jne .not_native_media
    jmp app_open_file_in_media
.check_xml:
    cmp byte [rdi + 8], 'X'
    jne .not_native_media
    cmp byte [rdi + 9], 'M'
    jne .not_native_media
    cmp byte [rdi + 10], 'L'
    jne .not_native_media
    jmp app_open_file_in_media
.not_native_media:
    jmp app_open_file_in_notepad

; ============================================================================
; app_open_file_in_media - thin user-mode wrapper. Routes to a kernel helper
; via SYS_OPEN_FILE_NP semantics — see kernel_open_file_in_media below for
; why the heavy lifting must run in kernel context (real fat16 globals).
; RDI = dir entry pointer
; ============================================================================
global app_open_file_in_media
app_open_file_in_media:
    SYS_OPEN_FILE_MEDIA rdi
    ret

; ============================================================================
; app_open_file_in_notepad - thin user-mode wrapper.
;   Routes everything through SYS_OPEN_FILE_NP so the heavy lifting (launch
;   notepad, read FAT16, parse lines, push into the notepad slot) runs in
;   kernel mode where the globals it touches actually live. When this code
;   ran in Ring 3 it modified the *caller's* (explorer's) slot copy of
;   notepad_buf, which is why every notepad stayed seeded with "Hello".
; RDI = slot-cached dir entry pointer
; ============================================================================
global app_open_file_in_notepad
app_open_file_in_notepad:
    SYS_OPEN_FILE_NP rdi
    ret

; ============================================================================
; kernel_open_file_in_notepad - runs in kernel context. Same semantics as the
; old user-mode helper, but uses direct kernel calls instead of syscall
; macros and finishes by re-copying the blob into the new notepad's slot so
; the slot reflects the freshly-loaded file contents.
;
; Note: common.inc %xdefine'd FAT16 helpers to user-mode syscall wrappers.
; Locally restore the real kernel symbols for launch helpers that run in ring 0;
; restore the aliases afterwards so the rest of the user blob is unaffected.
; RDI = slot-cached dir entry pointer
; Returns RAX = window id, or -1 on launch failure
; ============================================================================
%undef fat16_file_count
%undef fat16_get_entry
%undef fat16_change_dir
%undef fat16_read_file
extern fat16_file_count
extern fat16_get_entry
extern fat16_change_dir
extern fat16_read_file

; kernel_open_app_command - secure command-line app launcher.
; RDI = validated user cstring: "app" or "app params"
; Returns RAX = window id, or -1.
global kernel_open_app_command
kernel_open_app_command:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi

    ; Copy the caller string into a bounded kernel-owned buffer before parsing.
    lea rdi, [app_open_cmd_buf]
    mov rsi, r12
    mov ecx, APP_SLOT_PARAM_SZ - 1
.koac_copy_cmd:
    lodsb
    stosb
    test al, al
    jz .koac_cmd_copied
    dec ecx
    jnz .koac_copy_cmd
    mov byte [rdi], 0
.koac_cmd_copied:

    lea rbx, [app_open_cmd_buf]
.koac_skip_lead:
    mov al, [rbx]
    cmp al, ' '
    je .koac_skip_lead_1
    cmp al, 9
    jne .koac_have_name
.koac_skip_lead_1:
    inc rbx
    jmp .koac_skip_lead
.koac_have_name:
    cmp byte [rbx], 0
    je .koac_fail
    mov r12, rbx

.koac_find_name_end:
    mov al, [rbx]
    test al, al
    jz .koac_name_ended
    cmp al, ' '
    je .koac_name_delim
    cmp al, 9
    je .koac_name_delim
    cmp al, ','
    je .koac_name_delim
    inc rbx
    jmp .koac_find_name_end
.koac_name_delim:
    mov byte [rbx], 0
    inc rbx
.koac_name_ended:
    mov rdi, r12
    call app_command_name_to_id
    test eax, eax
    jz .koac_fail
    mov r13d, eax

    ; Copy raw params, trimming leading whitespace/commas only.
.koac_skip_param_lead:
    mov al, [rbx]
    cmp al, ' '
    je .koac_skip_param_1
    cmp al, 9
    je .koac_skip_param_1
    cmp al, ','
    jne .koac_copy_params_start
.koac_skip_param_1:
    inc rbx
    jmp .koac_skip_param_lead
.koac_copy_params_start:
    lea rdi, [app_open_param_buf]
    xor eax, eax
    mov ecx, APP_SLOT_PARAM_SZ
    cld
    rep stosb
    lea rdi, [app_open_param_buf]
    mov rsi, rbx
    mov ecx, APP_SLOT_PARAM_SZ - 1
.koac_copy_param:
    lodsb
    stosb
    test al, al
    jz .koac_param_copied
    dec ecx
    jnz .koac_copy_param
    mov byte [rdi], 0
.koac_param_copied:

    cmp r13d, APP_NOTEPAD
    jne .koac_launch_generic
    cmp byte [app_open_param_buf], 0
    je .koac_launch_generic
    lea rdi, [app_open_param_buf]
    call app_find_entry_by_path
    test rax, rax
    jz .koac_fail
    mov rdi, rax
    call kernel_open_file_in_notepad
    cmp rax, -1
    je .koac_done
    mov edi, eax
    lea rsi, [app_open_param_buf]
    call app_store_launch_params
    jmp .koac_done

.koac_launch_generic:
    mov edi, r13d
    sub rsp, 8
    call app_launch
    add rsp, 8
    cmp rax, -1
    je .koac_done
    mov edi, eax
    lea rsi, [app_open_param_buf]
    call app_store_launch_params
    jmp .koac_done

.koac_fail:
    mov rax, -1
.koac_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; RDI = app name token, returns EAX = APP_* id or 0.
app_command_name_to_id:
    lea rsi, [szAppNameExplorer]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_explorer
    lea rsi, [szAppNameTerminal]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_terminal
    lea rsi, [szAppNameNotepad]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_notepad
    lea rsi, [szAppNameSettings]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_settings
    lea rsi, [szAppNamePaint]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_paint
    lea rsi, [szAppNameAbout]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_about
    lea rsi, [szAppNameSecurity]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_security
    lea rsi, [szAppNameSecurityProbe]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_security
    lea rsi, [szAppNamePing]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_ping
    lea rsi, [szAppNameMedia]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_media
    xor eax, eax
    ret
.acnti_explorer:
    mov eax, APP_EXPLORER
    ret
.acnti_terminal:
    mov eax, APP_TERMINAL
    ret
.acnti_notepad:
    mov eax, APP_NOTEPAD
    ret
.acnti_settings:
    mov eax, APP_SETTINGS
    ret
.acnti_paint:
    mov eax, APP_PAINT
    ret
.acnti_about:
    mov eax, APP_ABOUT
    ret
.acnti_security:
    mov eax, APP_SECURITY_PROBE
    ret
.acnti_ping:
    mov eax, APP_PING
    ret
.acnti_media:
    mov eax, APP_MEDIA
    ret

; Case-insensitive ASCII strcmp. RDI=a, RSI=b, EAX=1 on match.
app_str_eq_ci:
    push rdi
    push rsi
.ase_loop:
    mov al, [rdi]
    mov ah, [rsi]
    cmp al, 'A'
    jb .ase_a_ready
    cmp al, 'Z'
    ja .ase_a_ready
    add al, 32
.ase_a_ready:
    cmp ah, 'A'
    jb .ase_b_ready
    cmp ah, 'Z'
    ja .ase_b_ready
    add ah, 32
.ase_b_ready:
    cmp al, ah
    jne .ase_no
    test al, al
    jz .ase_yes
    inc rdi
    inc rsi
    jmp .ase_loop
.ase_yes:
    mov eax, 1
    jmp .ase_done
.ase_no:
    xor eax, eax
.ase_done:
    pop rsi
    pop rdi
    ret

; EDI=window id, RSI=params. Copies params into the target app slot.
app_store_launch_params:
    push rax
    push rcx
    push rdi
    push rsi
    cmp edi, MAX_WINDOWS
    jae .aslp_done
    mov eax, edi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov rdi, [rax + WIN_OFF_APPDATA]
    test rdi, rdi
    jz .aslp_done
    add rdi, APP_SLOT_PARAM_OFF
    mov ecx, APP_SLOT_PARAM_SZ
    cld
    rep movsb
.aslp_done:
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; RDI=path. Resolves root/current FAT16 path to a live dir-entry pointer.
app_find_entry_by_path:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov r12, rdi
    ; A root-qualified path starts at /, \, C:/, C:\, or root/.
    cmp byte [r12], '/'
    je .afebp_root_slash
    cmp byte [r12], '\'
    je .afebp_root_slash
    mov al, [r12]
    cmp al, 'C'
    je .afebp_drive_maybe
    cmp al, 'c'
    jne .afebp_root_name_maybe
.afebp_drive_maybe:
    cmp byte [r12 + 1], ':'
    jne .afebp_root_name_maybe
    mov ax, 0
    call fat16_change_dir
    add r12, 2
    jmp .afebp_skip_slashes
.afebp_root_name_maybe:
    mov rdi, r12
    lea rsi, [szAppNameRoot]
    call app_path_has_prefix
    test eax, eax
    jz .afebp_component_loop
    mov ax, 0
    call fat16_change_dir
    add r12, 4
    jmp .afebp_skip_slashes
.afebp_root_slash:
    mov ax, 0
    call fat16_change_dir
.afebp_skip_slashes:
    cmp byte [r12], '/'
    je .afebp_skip_one
    cmp byte [r12], '\'
    jne .afebp_component_loop
.afebp_skip_one:
    inc r12
    jmp .afebp_skip_slashes

.afebp_component_loop:
    cmp byte [r12], 0
    je .afebp_fail
    lea rdi, [app_open_comp_buf]
    xor ecx, ecx
.afebp_copy_comp:
    mov al, [r12]
    test al, al
    jz .afebp_comp_done
    cmp al, '/'
    je .afebp_comp_done
    cmp al, '\'
    je .afebp_comp_done
    cmp ecx, 63
    jae .afebp_fail
    mov [rdi], al
    inc rdi
    inc r12
    inc ecx
    jmp .afebp_copy_comp
.afebp_comp_done:
    mov byte [rdi], 0
    lea rdi, [app_open_comp_buf]
    lea rsi, [app_open_83_buf]
    call filename_to_83
    lea rdi, [app_open_83_buf]
    call app_find_entry_83
    test rax, rax
    jz .afebp_fail
    mov r14, rax
    ; Skip separators and decide if this is the final component.
.afebp_after_comp_slashes:
    cmp byte [r12], '/'
    je .afebp_after_comp_skip
    cmp byte [r12], '\'
    jne .afebp_after_comp_ready
.afebp_after_comp_skip:
    inc r12
    jmp .afebp_after_comp_slashes
.afebp_after_comp_ready:
    cmp byte [r12], 0
    je .afebp_success
    mov al, [r14 + 11]
    test al, 0x10
    jz .afebp_fail
    mov ax, [r14 + 26]
    call fat16_change_dir
    test eax, eax
    jnz .afebp_fail
    jmp .afebp_component_loop

.afebp_success:
    mov rax, r14
    jmp .afebp_done
.afebp_fail:
    xor eax, eax
.afebp_done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI=path, RSI=literal prefix. EAX=1 if followed by /, \, or NUL.
app_path_has_prefix:
    push rdi
    push rsi
.aphp_loop:
    mov al, [rsi]
    test al, al
    jz .aphp_prefix_done
    mov ah, [rdi]
    cmp ah, 'A'
    jb .aphp_cmp
    cmp ah, 'Z'
    ja .aphp_cmp
    add ah, 32
.aphp_cmp:
    cmp ah, al
    jne .aphp_no
    inc rdi
    inc rsi
    jmp .aphp_loop
.aphp_prefix_done:
    mov al, [rdi]
    test al, al
    jz .aphp_yes
    cmp al, '/'
    je .aphp_yes
    cmp al, '\'
    je .aphp_yes
.aphp_no:
    xor eax, eax
    jmp .aphp_done
.aphp_yes:
    mov eax, 1
.aphp_done:
    pop rsi
    pop rdi
    ret

; RDI=11-byte 8.3 name. Returns matching current-directory entry or 0.
app_find_entry_83:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rdi
    call fat16_file_count
    mov ebx, eax
    xor ecx, ecx
.afe83_loop:
    cmp ecx, ebx
    jge .afe83_fail
    mov edi, ecx
    push rcx
    call fat16_get_entry
    pop rcx
    test rax, rax
    jz .afe83_fail
    mov rsi, r12
    mov rdi, rax
    mov edx, 11
.afe83_cmp:
    mov al, [rdi]
    cmp al, [rsi]
    jne .afe83_next
    inc rdi
    inc rsi
    dec edx
    jnz .afe83_cmp
    sub rdi, 11
    mov rax, rdi
    jmp .afe83_done
.afe83_next:
    inc ecx
    jmp .afe83_loop
.afe83_fail:
    xor eax, eax
.afe83_done:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

global kernel_open_file_in_notepad
; Open a FAT16 file (RDI = dir-entry ptr) in a fresh Notepad window. All per-
; instance state is written directly into the new window's L3 slot — never
; into the kernel image's np_* master copies. The kernel-side notepad_buf is
; used as a transient raw-bytes scratch, scoped strictly to this call.
kernel_open_file_in_notepad:
    SER 'O'
    SER 'F'
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                      ; dir entry ptr
    ; Notepad is a text editor. Keep known binary media formats out of its
    ; parser even if a caller bypasses Explorer's type-aware Open With list.
    cmp byte [r12 + 8], 'B'
    jne .kop_not_bmp
    cmp byte [r12 + 9], 'M'
    jne .kop_not_bmp
    cmp byte [r12 + 10], 'P'
    je .kop_fail
.kop_not_bmp:
    cmp byte [r12 + 8], 'N'
    jne .kop_not_media
    cmp byte [r12 + 9], 'I'
    jne .kop_check_nba
    cmp byte [r12 + 10], 'C'
    je .kop_fail
    jmp .kop_not_media
.kop_check_nba:
    cmp byte [r12 + 9], 'B'
    jne .kop_not_media
    cmp byte [r12 + 10], 'A'
    je .kop_fail
.kop_not_media:

    ; Launch a fresh Notepad. app_seed_notepad_slot resets the slot to a
    ; pristine "Hello" baseline; we then overwrite slot state with file data.
    mov rdi, APP_NOTEPAD
    sub rsp, 8
    call app_launch
    add rsp, 8
    cmp rax, -1
    je .kop_fail
    mov r13, rax                      ; new window id (== slot index)

    ; Cascade window position so file viewers don't cover Explorer.
    mov rax, r13
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_X], 560
    mov rbx, r13
    imul rbx, 24
    add rbx, 80
    mov [rax + WIN_OFF_Y], rbx
    lea rdi, [rax + 48]
    mov rsi, r12
    call fat16_format_name_to

    ; Resolve the slot base. All subsequent writes are slot-relative.
    mov edi, r13d
    call l3_slot_base
    mov r14, rax                      ; r14 = slot base

    ; SMAP: r14 is a user (PTE.U=1) slot page. Bracket the slot writes; the
    ; fat16 read below targets the kernel scratch buffer so it stays outside.
    USER_ACCESS_BEGIN
    ; Save dir entry into slot so Save can find the file later.
    mov [r14 + np_open_entry - app_blob_start], r12

    ; Pre-zero slot's notepad_buf + np_line_len so untouched cells stay clean.
    push rdi
    push rax
    push rcx
    lea rdi, [r14 + notepad_buf - app_blob_start]
    xor eax, eax
    mov ecx, NP_BUF_SIZE
    rep stosb
    lea rdi, [r14 + np_line_len - app_blob_start]
    xor eax, eax
    mov ecx, NP_MAX_LINES
    rep stosd
    pop rcx
    pop rax
    pop rdi
    USER_ACCESS_END

    ; Read raw file bytes into kernel-side notepad_buf (scratch only).
    mov rdi, r12
    lea rsi, [notepad_buf]
    mov edx, NP_BUF_SIZE - 1
    call fat16_read_file
    ; SMAP: the parse path below writes the slot (user page) on every branch,
    ; including .kop_empty. Arm AC now, after the kernel-scratch read returns,
    ; so all paths into the slot-write region run with AC set. Kernel-scratch
    ; reads ([rbx+rsi], [notepad_buf]) inside the region are fine with AC set.
    USER_ACCESS_BEGIN
    cmp eax, -1
    je .kop_empty
    test eax, eax
    jz .kop_empty
    ; Clamp the byte count to the scratch capacity; fat16_read_file is
    ; expected to honour edx, but defence-in-depth — this is the only
    ; bound between an attacker-controlled file size and the parse loop.
    cmp eax, NP_BUF_SIZE - 1
    jbe .kop_size_ok
    mov eax, NP_BUF_SIZE - 1
.kop_size_ok:
    lea rbx, [notepad_buf]
    mov byte [rbx + rax], 0

    ; Parse scratch -> slot's per-line layout.
    ;   r14 = slot base, rbx = scratch base, r12d = raw byte count
    mov r12d, eax
    xor ecx, ecx                      ; line index
    xor edx, edx                      ; column
    xor esi, esi                      ; raw offset

.kop_parse_loop:
    cmp esi, r12d
    jge .kop_parse_done
    cmp ecx, NP_MAX_LINES - 1
    jge .kop_parse_done

    movzx eax, byte [rbx + rsi]
    inc esi

    cmp al, 13
    je .kop_parse_cr
    cmp al, 10
    je .kop_parse_lf

    cmp edx, NP_MAX_COLS - 1
    jge .kop_parse_loop               ; clip overlong lines

    push rcx
    imul ecx, NP_MAX_COLS
    add rcx, rdx
    mov [r14 + rcx + notepad_buf - app_blob_start], al
    pop rcx
    inc edx
    jmp .kop_parse_loop

.kop_parse_cr:
    cmp esi, r12d
    jge .kop_parse_newline
    cmp byte [rbx + rsi], 10
    jne .kop_parse_newline
    inc esi
.kop_parse_lf:
.kop_parse_newline:
    push rcx
    imul ecx, NP_MAX_COLS
    add rcx, rdx
    mov byte [r14 + rcx + notepad_buf - app_blob_start], 0
    pop rcx
    mov [r14 + np_line_len - app_blob_start + rcx * 4], edx
    inc ecx
    xor edx, edx
    jmp .kop_parse_loop

.kop_parse_done:
    push rcx
    push rcx
    imul ecx, NP_MAX_COLS
    add rcx, rdx
    mov byte [r14 + rcx + notepad_buf - app_blob_start], 0
    pop rcx
    mov [r14 + np_line_len - app_blob_start + rcx * 4], edx
    pop rcx
    inc ecx
    mov [r14 + np_num_lines - app_blob_start], ecx
    mov dword [r14 + np_cursor_row - app_blob_start], 0
    mov dword [r14 + np_cursor_col - app_blob_start], 0
    mov dword [r14 + np_scroll_top - app_blob_start], 0
    jmp .kop_seed_visible

.kop_empty:
    mov dword [r14 + np_num_lines - app_blob_start], 1
    mov dword [r14 + np_cursor_row - app_blob_start], 0
    mov dword [r14 + np_cursor_col - app_blob_start], 0
    mov dword [r14 + np_scroll_top - app_blob_start], 0
    mov byte  [r14 + notepad_buf - app_blob_start], 0
    mov dword [r14 + np_line_len - app_blob_start], 0

.kop_seed_visible:
    ; Seed slot's szOpenTextScratch with the first visible line so the very
    ; first draw frame (which may fire before copy_line_to_scratch runs)
    ; renders real bytes instead of whatever was there before.
    lea rdi, [r14 + app_hl_notepad_szOpenTextScratch - app_blob_start]
    lea rsi, [r14 + notepad_buf - app_blob_start]
    mov ecx, NP_MAX_COLS - 1
.kop_copy_visible:
    lodsb
    test al, al
    jz .kop_copy_visible_done
    stosb
    dec ecx
    jnz .kop_copy_visible
.kop_copy_visible_done:
    mov byte [rdi], 0
    USER_ACCESS_END

    ; Clear scratch so we don't leave file bytes in the kernel image's master
    ; copy (defence-in-depth — nothing should read them, but stale file
    ; content lingering in kernel .data is a needless info-leak surface).
    push rdi
    push rax
    push rcx
    lea rdi, [notepad_buf]
    xor eax, eax
    mov ecx, NP_BUF_SIZE
    rep stosb
    pop rcx
    pop rax
    pop rdi

    mov rax, r13
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.kop_fail:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; kernel_open_file_in_media - runs in kernel context. Launches Media Player
; for an arbitrary FAT16 entry (NIC, NBA, or any future codec) and reads the
; file bytes into the new window's slot at APP_SLOT_BMP_FILE_OFF — the same
; offset `app_media_draw` probes for the magic on every frame.
;
; Mirrors kernel_open_file_in_notepad: the heavy lifting must run in kernel
; mode so the real fat16_* helpers (not user-mode syscall macros) can be
; called, and so the slot we write into is the *new* Media Player window's
; slot, not the caller's (a long-standing bug in the legacy BMP opener).
;
; RDI = slot-cached dir entry pointer
; Returns RAX = window id, or -1 on launch failure / read failure.
; ============================================================================
global kernel_open_file_in_media
extern page_alloc_contig
extern fat16_get_file_size
extern media_full_buf
extern media_full_buf_pages
extern media_release_window_buf
kernel_open_file_in_media:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                      ; dir entry ptr

    ; Launch a fresh Media Player window via the normal dispatch.
    mov rdi, APP_MEDIA
    sub rsp, 8
    call app_launch
    add rsp, 8
    cmp rax, -1
    je .kom_fail
    mov r13, rax                      ; new window id

    ; Cascade window position so the viewer doesn't cover the explorer.
    mov rax, r13
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_X], 200
    mov rbx, r13
    imul rbx, 24
    add rbx, 100
    mov [rax + WIN_OFF_Y], rbx

    ; Resolve the new window's slot base.
    mov edi, r13d
    call l3_slot_base
    mov r14, rax                      ; slot base

    ; SMAP: from here the function freely mixes slot (user, PTE.U=1) reads and
    ; writes with kernel-scratch and window-pool accesses across many branches,
    ; and fat16_read_file below writes its bytes straight into the slot. Arm AC
    ; once for the whole body and clac at every ret. fat16_read_file does not
    ; touch AC, so it propagates correctly; an IRQ clears AC on entry and iret
    ; restores it, so the window is not nested-IRQ exploitable.
    USER_ACCESS_BEGIN

    ; Zero the slot's media buffer header so a failed read doesn't leave
    ; an old codec magic lingering from a previous tenant of this slot.
    lea rdi, [r14 + APP_SLOT_BMP_FILE_OFF]
    xor eax, eax
    mov ecx, 64                       ; just the header region is enough
    rep stosd

    ; Read file bytes into the slot's media buffer.
    lea rdi, [r14 + APP_SLOT_BMP_FILE_OFF]
    mov rsi, rdi
    mov rdi, r12
    mov edx, APP_SLOT_BMP_FILE_SZ
    call fat16_read_file
    cmp eax, -1
    je .kom_fail
    mov ebx, eax
    mov r15d, ebx

    ; APP_SLOT_BMP_FILE_SZ intentionally caps the generic synchronous load.
    ; NBA files can be much larger than a slot-local media buffer, so each media
    ; window allocates its OWN physically-contiguous full-clip buffer sized to
    ; the file and the real header stays in the slot for controls/hit-testing.
    ; Per-window ownership (vs. the old single shared buffer) means opening a
    ; second video no longer truncates the first one's playback.
    cmp dword [r14 + APP_SLOT_BMP_FILE_OFF], LAUNCH_NBA1_MAGIC ; 'NBA1'
    jne .kom_loaded

    ; Drop any buffer left over from a previous tenant of this reused window id.
    mov edi, r13d
    call media_release_window_buf

    mov rdi, r12
    call fat16_get_file_size                 ; eax = file size in bytes
    cmp eax, APP_SLOT_BMP_FILE_SZ
    jbe .kom_nba_clamp_slot                  ; fits the slot: no full buffer
    cmp eax, MEDIA_FULL_BUF_MAX_SZ
    jbe .kom_nba_sz_ok
    mov eax, MEDIA_FULL_BUF_MAX_SZ           ; cap absurdly large clips
.kom_nba_sz_ok:
    mov ebx, eax                             ; ebx = bytes to read
    add eax, 0xFFF
    shr eax, 12                              ; pages needed
    mov rdi, rax
    call page_alloc_contig                   ; rax = buffer base (0 = OOM)
    test rax, rax
    jz .kom_nba_clamp_slot                   ; OOM: fall back to slot
    ; Record ownership so the renderer can find it and close can free it.
    lea rdx, [rel media_full_buf]
    mov [rdx + r13*8], rax
    mov ecx, ebx
    add ecx, 0xFFF
    shr ecx, 12
    lea rdx, [rel media_full_buf_pages]
    mov [rdx + r13*8], rcx
    ; Load the clip into the freshly allocated buffer.
    mov rsi, rax                             ; dest
    mov rdi, r12                             ; entry
    mov edx, ebx                             ; max bytes
    call fat16_read_file
    cmp eax, 20
    jbe .kom_nba_free_fallback
    lea rcx, [rel media_full_buf]
    mov r11, [rcx + r13*8]                   ; buffer base
    cmp dword [r11], LAUNCH_NBA1_MAGIC
    jne .kom_nba_free_fallback
    mov ebx, eax                             ; bytes loaded into full buffer
    ; Refresh the slot header from the full buffer so controls/sizing match.
    mov eax, [r11 + 0]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 0], eax
    mov eax, [r11 + 4]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 4], eax
    mov eax, [r11 + 8]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 8], eax
    mov eax, [r11 + 12]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 12], eax
    mov eax, [r11 + 16]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 16], eax
    jmp .kom_nba_validate_loaded

.kom_nba_free_fallback:
    ; The full-buffer read failed validation. Release it and fall back to the
    ; slot-local bytes already loaded above.
    mov edi, r13d
    call media_release_window_buf
.kom_nba_clamp_slot:
    ; No full buffer in play. Fall back to the slot-local bytes and clamp
    ; frame_count so the renderer never walks past the 256 KiB slot buffer.
    mov ebx, r15d
.kom_nba_validate_loaded:
    cmp ebx, 20
    jbe .kom_nba_no_frames
    mov eax, [r14 + APP_SLOT_BMP_FILE_OFF + 4]
    test eax, eax
    jz .kom_nba_no_frames
    mov ecx, [r14 + APP_SLOT_BMP_FILE_OFF + 8]
    test ecx, ecx
    jz .kom_nba_no_frames
    imul eax, ecx
    shl eax, 2
    test eax, eax
    jz .kom_nba_no_frames
    mov ecx, eax                      ; frame bytes
    mov eax, ebx
    sub eax, 20
    xor edx, edx
    div ecx                           ; eax = complete loaded frames
    test eax, eax
    jz .kom_nba_no_frames
    cmp eax, [r14 + APP_SLOT_BMP_FILE_OFF + 12]
    jae .kom_loaded
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 12], eax
    jmp .kom_loaded
.kom_nba_no_frames:
    mov dword [r14 + APP_SLOT_BMP_FILE_OFF + 12], 0
.kom_loaded:
    ; Native-size NBA playback avoids the expensive scaler hot path for the
    ; common BOOTANIM.NBA case while still using normal controls/chrome.
    cmp dword [r14 + APP_SLOT_BMP_FILE_OFF], LAUNCH_NBA1_MAGIC ; 'NBA1'
    jne .kom_return
    mov rax, r13
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov ebx, [r14 + APP_SLOT_BMP_FILE_OFF + 4]          ; source w
    test ebx, ebx
    jz .kom_return
    add ebx, BORDER_WIDTH * 2
    cmp ebx, MIN_WINDOW_W
    jae .kom_w_ok
    mov ebx, MIN_WINDOW_W
.kom_w_ok:
    mov [rax + WIN_OFF_W], rbx
    mov ebx, [r14 + APP_SLOT_BMP_FILE_OFF + 8]          ; source h
    test ebx, ebx
    jz .kom_return
    add ebx, TITLEBAR_HEIGHT + BORDER_WIDTH + MEDIA_PLAYER_BAR_H
    cmp ebx, MIN_WINDOW_H
    jae .kom_h_ok
    mov ebx, MIN_WINDOW_H
.kom_h_ok:
    mov [rax + WIN_OFF_H], rbx

.kom_return:
    USER_ACCESS_END

    mov rax, r13
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.kom_fail:
    ; Reached both before the USER_ACCESS_BEGIN above (early app_launch fail,
    ; AC already clear) and after it; clac is a harmless no-op in the former.
    USER_ACCESS_END
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Restore the user-mode alias for the remainder of the blob.
%xdefine fat16_file_count app_sys_fs_count
%xdefine fat16_get_entry app_sys_fs_get_entry
%xdefine fat16_change_dir app_sys_fs_change_dir
%xdefine fat16_read_file app_sys_fs_read

; ============================================================================
; FILE EXPLORER APP
; Virtual filesystem with navigable directories
; ============================================================================

; Draw callback: RDI = window struct ptr
