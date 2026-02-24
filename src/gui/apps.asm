; ============================================================================
; NexusOS v3.0 - Application Framework + Built-in Apps
; Each app provides: draw_fn(rdi=window_ptr), click_fn(rdi=window_ptr,
;   rsi=client_x, rdx=client_y), key_fn(rdi=window_ptr, esi=key_event)
; Window struct offsets (from window.asm):
;   8:X 16:Y 24:W 32:H 40:Flags 48:Title 112:draw_fn 120:key_fn 128:click_fn 136:app_data
; ============================================================================
bits 64

%include "constants.inc"

WIN_OFF_X       equ 8
WIN_OFF_Y       equ 16
WIN_OFF_W       equ 24
WIN_OFF_H       equ 32
WIN_OFF_FLAGS   equ 40
WIN_OFF_DRAWFN  equ 112
WIN_OFF_KEYFN   equ 120
WIN_OFF_CLICKFN equ 128
WIN_OFF_APPDATA equ 136

; App IDs (matches menu item return codes from taskbar: 2..6)
APP_EXPLORER    equ 2
APP_TERMINAL    equ 3
APP_NOTEPAD     equ 4
APP_SETTINGS    equ 5
APP_PAINT       equ 6
APP_ABOUT       equ 7

; Virtual filesystem entry size
VFS_ENTRY_SIZE  equ 32     ; 24 bytes name + 1 byte type + 7 bytes size

; Notepad constants
NP_MAX_LINES    equ 32
NP_MAX_COLS     equ 80
NP_BUF_SIZE     equ (NP_MAX_LINES * NP_MAX_COLS)
NP_MENU_H       equ 18
NP_EDIT_TOP     equ 20     ; offset from client top to editing area

; Terminal constants
TERM_MAX_HIST   equ 16     ; max history output lines

; Context menu
CTX_ITEM_H      equ 20
CTX_WIDTH       equ 140

section .text

extern render_rect
extern render_text
extern wm_create_window_ex
extern fat16_file_count
extern fat16_get_entry
extern fat16_read_file
extern fat16_write_file
extern fat16_sync_root
extern fat16_change_dir
extern bb_addr
extern scr_pitch
extern mouse_debug_dump
extern xhci_debug_dump
extern i2c_hid_debug_dump
extern mouse_wait_input
extern fat16_debug_dump_root

; ============================================================================
; app_launch - Launch an app by ID
; RDI = app ID (2..6)
; Returns: RAX = window ID or -1
; ============================================================================
global app_launch
app_launch:
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
    mov rax, -1
    ret

.launch_explorer:
    ; Reset explorer state to root
    mov dword [explorer_sel], 0
    mov dword [explorer_dir], 0
    mov byte [ctx_menu_visible], 0
    mov byte [exp_rename_active], 0
    mov byte [exp_newfolder_active], 0
    mov byte [exp_newfolder_done_msg], 0
    mov rdi, szExplorerTitle
    mov rsi, 120
    mov rdx, 80
    mov rcx, 420
    mov r8, 340
    mov r9, app_explorer_draw
    call wm_create_window_ex
    cmp rax, -1
    je .done
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_CLICKFN], app_explorer_click
    mov qword [rax + WIN_OFF_KEYFN], app_explorer_key
    pop rax
    jmp .done

.launch_terminal:
    ; Reset terminal state
    mov dword [term_cursor], 0
    mov byte [term_input], 0
    mov dword [term_hist_count], 0
    ; Clear history pointers
    lea rcx, [term_hist_ptrs]
    xor eax, eax
.clr_hist:
    cmp eax, TERM_MAX_HIST
    jge .hist_cleared
    mov qword [rcx + rax * 8], 0
    inc eax
    jmp .clr_hist
.hist_cleared:
    ; Add welcome lines
    lea rcx, [term_hist_ptrs]
    mov qword [rcx + 0], szTermWelcome
    mov qword [rcx + 8], szTermVer
    mov qword [rcx + 16], szTermHelpHint
    mov dword [term_hist_count], 3
    mov rdi, szTermTitle
    mov rsi, 200
    mov rdx, 150
    mov rcx, 450
    mov r8, 300
    mov r9, app_terminal_draw
    call wm_create_window_ex
    cmp rax, -1
    je .done
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_CLICKFN], app_terminal_click
    mov qword [rax + WIN_OFF_KEYFN], app_terminal_key
    pop rax
    jmp .done

.launch_notepad:
    ; Reset notepad state
    lea rdi, [notepad_buf]
    xor eax, eax
    mov ecx, NP_BUF_SIZE
    rep stosb
    mov dword [np_cursor_row], 0
    mov dword [np_cursor_col], 0
    mov dword [np_num_lines], 1
    mov dword [np_scroll_top], 0
    mov byte [np_menu_open], 0
    mov byte [np_save_dialog], 0
    mov qword [np_open_entry], 0
    ; Initialize line lengths array - line 0 starts with length 0
    lea rdi, [np_line_len]
    xor eax, eax
    mov ecx, NP_MAX_LINES
    rep stosd
    mov rdi, szNotepadTitle
    mov rsi, 250
    mov rdx, 120
    mov rcx, 400
    mov r8, 300
    mov r9, app_notepad_draw
    call wm_create_window_ex
    cmp rax, -1
    je .done
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_KEYFN], app_notepad_key
    mov qword [rax + WIN_OFF_CLICKFN], app_notepad_click
    pop rax
    jmp .done

.launch_settings:
    mov rdi, szSettingsTitle
    mov rsi, 300
    mov rdx, 180
    mov rcx, 380
    mov r8, 280
    mov r9, app_settings_draw
    call wm_create_window_ex
    cmp rax, -1
    je .done
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_CLICKFN], app_settings_click
    pop rax
    jmp .done

.launch_paint:
    ; Reset paint state - use static buffers at known addresses
    mov dword [paint_color], 0xFF000000 ; Black
    mov dword [paint_brush_size], 2
    
    ; Clear canvas (white) - 200x150 pixels * 4 bytes = 120000 bytes
    mov edi, PAINT_CANVAS_BUF
    mov ecx, 30000          ; 30000 dwords
    mov eax, 0xFFFFFFFF
    rep stosd

    mov rdi, szPaintTitle
    mov rsi, 150
    mov rdx, 100
    mov rcx, 340   ; width (canvas 200 + border/tools + buttons)
    mov r8, 240    ; height (canvas 150 + toolbar)
    mov r9, app_paint_draw
    call wm_create_window_ex
    cmp rax, -1
    je .done
    
    ; Setup callback
    push rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_CLICKFN], app_paint_click
    mov qword [rax + WIN_OFF_KEYFN], app_paint_key
    pop rax
    jmp .done

.launch_about:
    mov rdi, szAboutTitle
    mov rsi, 280
    mov rdx, 200
    mov rcx, 340
    mov r8, 220
    mov r9, app_about_draw
    call wm_create_window_ex
    jmp .done

.done:
    ret

; ============================================================================
; app_open_file - Open a file, routing by extension
; RDI = pointer to FAT16 dir entry (32 bytes)
; ============================================================================
global app_open_file
app_open_file:
    ; Check extension at entry+8 (3 bytes)
    ; BMP files: extension = "BMP"
    cmp byte [rdi + 8], 'B'
    jne .open_not_bmp
    cmp byte [rdi + 9], 'M'
    jne .open_not_bmp
    cmp byte [rdi + 10], 'P'
    jne .open_not_bmp
    jmp app_open_file_in_bmpview
.open_not_bmp:
    jmp app_open_file_in_notepad

; ============================================================================
; Helper: open file in notepad
; RDI = pointer to FAT16 dir entry
; ============================================================================
global app_open_file_in_notepad
app_open_file_in_notepad:
    push rbx
    push r12
    push r13
    push rdi
    push rsi
    push rcx

    mov r12, rdi             ; save dir entry ptr

    ; Launch notepad (resets buffer)
    mov rdi, APP_NOTEPAD
    call app_launch
    cmp rax, -1
    je .open_done
    mov r13, rax             ; window ID

    ; Set window title from 8.3 name
    imul rax, r13, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    lea rdi, [rax + 48]      ; WIN_OFF_TITLE
    mov rsi, r12
    call fat16_format_name_to  ; format 8.3 name into rdi

    ; Save dir entry for notepad (so Save knows the filename)
    mov [np_open_entry], r12

    ; Read file content from FAT16
    mov rdi, r12             ; dir entry ptr
    lea rsi, [notepad_buf]   ; dest = notepad buffer
    mov edx, NP_BUF_SIZE - 1 ; max bytes
    call fat16_read_file
    ; eax = bytes read
    cmp eax, -1
    je .open_load_empty
    test eax, eax
    jz .open_load_empty

    ; Null-terminate
    lea rbx, [notepad_buf]
    mov byte [rbx + rax], 0

    ; Parse content into lines: split on CR/LF
    mov r12d, eax            ; total bytes
    xor ecx, ecx             ; current line
    xor edx, edx             ; current col
    xor esi, esi             ; source offset

.parse_loop:
    cmp esi, r12d
    jge .parse_done
    cmp ecx, NP_MAX_LINES - 1
    jge .parse_done

    movzx eax, byte [rbx + rsi]
    inc esi

    cmp al, 13               ; CR
    je .parse_cr
    cmp al, 10               ; LF
    je .parse_lf

    ; Regular char - store in current line
    cmp edx, NP_MAX_COLS - 1
    jge .parse_loop           ; skip if line too long

    push rcx
    imul ecx, NP_MAX_COLS
    mov [notepad_buf + rcx + rdx], al
    pop rcx
    inc edx
    jmp .parse_loop

.parse_cr:
    ; Skip following LF if present
    cmp esi, r12d
    jge .parse_newline
    cmp byte [rbx + rsi], 10
    jne .parse_newline
    inc esi
.parse_lf:
.parse_newline:
    ; Null-terminate current line
    push rcx
    imul ecx, NP_MAX_COLS
    mov byte [notepad_buf + rcx + rdx], 0
    pop rcx
    ; Store line length
    mov [np_line_len + rcx * 4], edx
    inc ecx
    xor edx, edx
    jmp .parse_loop

.parse_done:
    ; Terminate last line
    push rcx
    push rcx
    imul ecx, NP_MAX_COLS
    mov byte [notepad_buf + rcx + rdx], 0
    pop rcx
    mov [np_line_len + rcx * 4], edx
    pop rcx
    inc ecx
    mov [np_num_lines], ecx
    mov dword [np_cursor_row], 0
    mov dword [np_cursor_col], 0
    jmp .open_done

.open_load_empty:
    mov dword [np_num_lines], 1
    mov dword [np_cursor_row], 0
    mov dword [np_cursor_col], 0

.open_done:
    pop rcx
    pop rsi
    pop rdi
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; FILE EXPLORER APP
; Virtual filesystem with navigable directories
; ============================================================================

; Draw callback: RDI = window struct ptr
app_explorer_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    ; --- Path bar ---
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, 20
    mov r8d, 0x00E0E0E0
    call render_rect

    ; Path text
    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 3
    mov rdx, szPathRoot
    mov ecx, 0x00333333
    mov r8d, 0x00E0E0E0
    call render_text

    ; --- Column headers ---
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 22
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, 18
    mov r8d, 0x00D0D0E0
    call render_rect

    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 23
    mov rdx, szColName
    mov ecx, 0x00333333
    mov r8d, 0x00D0D0E0
    call render_text

    mov rdi, r12
    add rdi, r14
    sub rdi, 100
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 23
    mov rdx, szColSize
    mov ecx, 0x00333333
    mov r8d, 0x00D0D0E0
    call render_text

    ; --- File list from FAT16 ---
    call fat16_file_count
    mov r8d, eax            ; total files
    xor edx, edx            ; current file index

.entry_loop:
    cmp edx, r8d
    jge .entries_done
    ; Max 20 entries visible
    cmp edx, 20
    jge .entries_done

    push rdx
    push r8

    ; Highlight selected row
    mov eax, [explorer_sel]
    cmp eax, edx
    jne .no_highlight

    push rdx
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 42
    movzx eax, dl
    imul eax, 18
    add rsi, rax
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, 18
    mov r8d, COLOR_HIGHLIGHT
    call render_rect
    pop rdx

.no_highlight:
    ; Get FAT16 directory entry
    push rdx
    mov edi, edx
    call fat16_get_entry
    mov r9, rax              ; r9 = dir entry pointer
    pop rdx
    test r9, r9
    jz .entry_size_done

    ; Convert 8.3 name to display name in fat16_name_buf
    push rdx
    mov rdi, fat16_name_buf
    mov rsi, r9
    call fat16_format_name
    pop rdx

    ; Entry name text - edx = file index here
    ; Save r9 (dir entry ptr) for later
    mov [explorer_cur_entry], r9
    mov [explorer_cur_idx], edx

    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 43
    imul eax, edx, 18
    add rsi, rax
    mov rdx, fat16_name_buf

    ; Color: directories=gold, files=black
    mov cl, [r9 + 11]
    test cl, 0x10
    jz .file_icon
    mov ecx, 0x00CC8800
    jmp .draw_entry_name
.file_icon:
    mov ecx, 0x00333333
.draw_entry_name:
    mov r8d, COLOR_WINDOW_BG
    mov eax, [explorer_cur_idx]
    cmp eax, [explorer_sel]
    jne .entry_no_hl_text
    mov r8d, COLOR_HIGHLIGHT
    mov ecx, COLOR_TEXT_WHITE
.entry_no_hl_text:
    call render_text
    mov edx, [explorer_cur_idx]
    mov r9, [explorer_cur_entry]

    ; Entry size text
    mov cl, [r9 + 11]
    test cl, 0x10
    jnz .dir_size

    ; Convert file size to string
    push rdx
    mov edi, [r9 + 28]      ; file size (32-bit)
    mov rsi, fat16_size_buf
    call app_format_bytes_size
    pop rdx

    mov rdi, r12
    add rdi, r14
    sub rdi, 80
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 43
    movzx eax, dl
    imul eax, 18
    add rsi, rax
    mov rdx, fat16_size_buf
    mov ecx, 0x00666666
    mov r8d, COLOR_WINDOW_BG
    call render_text
    jmp .entry_size_done

.dir_size:
    mov rdi, r12
    add rdi, r14
    sub rdi, 80
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 43
    movzx eax, dl
    imul eax, 18
    add rsi, rax
    mov rdx, szDirLabel
    mov ecx, 0x00999999
    mov r8d, COLOR_WINDOW_BG
    call render_text

.entry_size_done:
    pop r8
    pop rdx
    inc edx
    jmp .entry_loop

.entries_done:

    ; Status bar at bottom
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 18
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, 18
    mov r8d, 0x00E8E8E8
    call render_rect

    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 17
    mov rdx, szStatusReady
    mov ecx, 0x00666666
    mov r8d, 0x00E8E8E8
    call render_text

    ; --- Rename overlay (inline input at bottom) ---
    cmp byte [exp_rename_active], 0
    je .no_rename_overlay

    ; Dark overlay bar at bottom of file list
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 40
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, 22
    mov r8d, 0x00334455
    call render_rect

    ; "Rename:" label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 38
    mov rdx, szRenameLabel
    mov ecx, 0x00AACCFF
    mov r8d, 0x00334455
    call render_text

    ; Rename text input value
    mov rdi, r12
    add rdi, BORDER_WIDTH + 64
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 38
    lea rdx, [exp_rename_buf]
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, 0x00334455
    call render_text

    ; Blinking cursor after text
    mov eax, [exp_rename_cursor]
    imul eax, FONT_WIDTH
    add eax, BORDER_WIDTH + 64
    mov edi, eax
    add edi, r12d
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 38
    mov rdx, szCursor
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, 0x00334455
    call render_text

.no_rename_overlay:

    ; --- New Folder overlay (inline input at bottom) ---
    cmp byte [exp_newfolder_active], 0
    je .no_newfolder_overlay

    ; Dark overlay bar
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 40
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, 22
    mov r8d, 0x00443355
    call render_rect

    ; "New Folder:" label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 38
    mov rdx, szNewFolderLabel
    mov ecx, 0x00FFAACC
    mov r8d, 0x00443355
    call render_text

    ; Folder name input value
    mov rdi, r12
    add rdi, BORDER_WIDTH + 96
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 38
    lea rdx, [exp_newfolder_buf]
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, 0x00443355
    call render_text

    ; Cursor
    mov eax, [exp_newfolder_cursor]
    imul eax, FONT_WIDTH
    add eax, BORDER_WIDTH + 96
    mov edi, eax
    add edi, r12d
    mov rsi, r13
    add rsi, r15
    sub rsi, BORDER_WIDTH + 38
    mov rdx, szCursor
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, 0x00443355
    call render_text

.no_newfolder_overlay:

    ; --- "Folder Created!" message overlay ---
    cmp byte [exp_newfolder_done_msg], 0
    je .no_newfolder_msg

    mov rdi, r12
    mov eax, r14d
    sub eax, 140
    shr eax, 1
    add edi, eax
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 60
    mov edx, 140
    mov ecx, 30
    mov r8d, 0x00228B22
    call render_rect

    mov rdi, r12
    mov eax, r14d
    sub eax, 110
    shr eax, 1
    add edi, eax
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 68
    mov rdx, szNewFolderDone
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, 0x00228B22
    call render_text

.no_newfolder_msg:

    ; --- Context menu overlay ---
    cmp byte [ctx_menu_visible], 0
    je .no_ctx_menu

    ; Draw context menu background (4 items: Open, Rename, New Folder, Properties)
    mov edi, [ctx_menu_x]
    mov esi, [ctx_menu_y]
    mov edx, CTX_WIDTH
    mov ecx, CTX_ITEM_H * 4 + 4
    mov r8d, 0x00F0F0F0
    call render_rect

    ; Border
    mov edi, [ctx_menu_x]
    mov esi, [ctx_menu_y]
    mov edx, CTX_WIDTH
    mov ecx, 1
    mov r8d, 0x00999999
    call render_rect

    ; Item 0: Open
    mov edi, [ctx_menu_x]
    add edi, 8
    mov esi, [ctx_menu_y]
    add esi, 4
    mov rdx, szCtxOpen
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text

    ; Item 1: Rename
    mov edi, [ctx_menu_x]
    add edi, 8
    mov esi, [ctx_menu_y]
    add esi, 4 + CTX_ITEM_H
    mov rdx, szCtxRename
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text

    ; Item 2: New Folder
    mov edi, [ctx_menu_x]
    add edi, 8
    mov esi, [ctx_menu_y]
    add esi, 4 + CTX_ITEM_H * 2
    mov rdx, szCtxNewFolder
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text

    ; Item 3: Properties
    mov edi, [ctx_menu_x]
    add edi, 8
    mov esi, [ctx_menu_y]
    add esi, 4 + CTX_ITEM_H * 3
    mov rdx, szCtxProperties
    mov ecx, 0x00666666
    mov r8d, 0x00F0F0F0
    call render_text

.no_ctx_menu:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Click callback: RDI=window_ptr, RSI=client_x, RDX=client_y
app_explorer_click:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Dismiss "Folder Created!" message on click
    cmp byte [exp_newfolder_done_msg], 0
    je .exp_no_nf_dismiss
    mov byte [exp_newfolder_done_msg], 0
    jmp .exp_click_ret
.exp_no_nf_dismiss:

    ; Cancel rename/newfolder mode on click outside
    cmp byte [exp_rename_active], 0
    je .exp_no_rename_dismiss
    mov byte [exp_rename_active], 0
.exp_no_rename_dismiss:
    cmp byte [exp_newfolder_active], 0
    je .exp_no_nf_dismiss2
    mov byte [exp_newfolder_active], 0
.exp_no_nf_dismiss2:

    ; Check if context menu is open - handle menu click
    cmp byte [ctx_menu_visible], 0
    je .exp_no_ctx_click

    ; Check if click is inside context menu
    ; ctx_menu_x/y are screen coords; rsi/rdx are client coords
    ; Convert client to screen: add window X/Y + border + titlebar
    mov rax, [rdi + WIN_OFF_X]
    add rax, BORDER_WIDTH
    add rsi, rax
    mov rax, [rdi + WIN_OFF_Y]
    add rax, TITLEBAR_HEIGHT
    add rdx, rax

    mov eax, [ctx_menu_x]
    cmp esi, eax
    jl .ctx_dismiss
    add eax, CTX_WIDTH
    cmp esi, eax
    jge .ctx_dismiss
    mov eax, [ctx_menu_y]
    cmp edx, eax
    jl .ctx_dismiss
    mov ecx, eax
    add ecx, CTX_ITEM_H * 4 + 4
    cmp edx, ecx
    jge .ctx_dismiss

    ; Which item clicked?
    sub edx, [ctx_menu_y]
    sub edx, 4
    mov eax, edx
    xor edx, edx
    mov ecx, CTX_ITEM_H
    div ecx
    ; eax = item index (0=Open, 1=Rename, 2=New Folder, 3=Properties)
    cmp eax, 0
    je .ctx_open
    cmp eax, 1
    je .ctx_rename
    cmp eax, 2
    je .ctx_new_folder
    cmp eax, 3
    je .ctx_properties
    jmp .ctx_dismiss

.ctx_open:
    ; Open selected file in notepad
    mov byte [ctx_menu_visible], 0
    mov edi, [explorer_sel]
    call fat16_get_entry
    test rax, rax
    jz .ctx_dismiss
    ; Check it's a file (not dir)
    mov cl, [rax + 11]
    test cl, 0x10
    jnz .ctx_dismiss
    mov rdi, rax
    call app_open_file
    jmp .exp_click_ret

.ctx_rename:
    ; Enter rename mode - copy current name into rename buffer
    mov byte [ctx_menu_visible], 0
    mov byte [exp_rename_active], 1
    mov dword [exp_rename_cursor], 0
    ; Get current entry name
    mov edi, [explorer_sel]
    call fat16_get_entry
    test rax, rax
    jz .ctx_dismiss
    ; Copy name into rename buffer (up to 23 chars from VFS 24-byte name)
    push rsi
    push rdi
    push rcx
    mov rsi, rax
    lea rdi, [exp_rename_buf]
    xor ecx, ecx
.ctx_rename_copy:
    cmp ecx, 23
    jge .ctx_rename_copy_done
    mov al, [rsi + rcx]
    test al, al
    jz .ctx_rename_copy_done
    mov [rdi + rcx], al
    inc ecx
    jmp .ctx_rename_copy
.ctx_rename_copy_done:
    mov byte [rdi + rcx], 0
    mov [exp_rename_cursor], ecx
    pop rcx
    pop rdi
    pop rsi
    jmp .exp_click_ret

.ctx_new_folder:
    ; Enter new folder mode - show input for folder name
    mov byte [ctx_menu_visible], 0
    mov byte [exp_newfolder_active], 1
    mov dword [exp_newfolder_cursor], 0
    ; Clear the buffer
    lea rdi, [exp_newfolder_buf]
    mov byte [rdi], 0
    jmp .exp_click_ret

.ctx_properties:
    mov byte [ctx_menu_visible], 0
    mov edi, [explorer_sel]
    call fat16_get_entry
    test rax, rax
    jz .ctx_dismiss
    mov [prop_entry_ptr], rax
    ; Open a Properties window
    mov rdi, szPropTitle
    mov rsi, 250
    mov rdx, 200
    mov rcx, 240
    mov r8, 160
    mov r9, app_properties_draw
    call wm_create_window_ex
    jmp .exp_click_ret

.ctx_dismiss:
    mov byte [ctx_menu_visible], 0
    jmp .exp_click_ret

.exp_no_ctx_click:
    ; Restore original rsi/rdx (client coords)
    mov rsi, [rsp + 8]     ; original rsi
    mov rdx, [rsp + 16]    ; original rdx

    ; Check if right button - show context menu
    ; We don't have right-button info here directly...
    ; Context menu is triggered by explorer_key or by the main event loop

    ; client_y relative to client area top
    cmp rdx, 42
    jl .exp_click_ret

    ; Calculate entry index
    sub rdx, 42
    mov rax, rdx
    xor edx, edx
    mov rcx, 18
    div rcx

    ; Check against FAT16 file count
    push rax
    call fat16_file_count
    mov ecx, eax
    pop rax
    cmp eax, ecx
    jge .exp_click_ret

.exp_select:
    ; Check if same item (double-click = open)
    cmp eax, [explorer_sel]
    jne .exp_first_click

    ; Double-click: open file
    push rax
    mov edi, eax
    call fat16_get_entry
    test rax, rax
    jz .dblclick_done
    ; Check if directory
    mov cl, [rax + 11]
    test cl, 0x10
    jnz .dblclick_done
    ; Open file in notepad
    mov rdi, rax
    call app_open_file
.dblclick_done:
    pop rax
    jmp .exp_click_ret

.exp_first_click:
    mov [explorer_sel], eax

.exp_click_ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Key handler for explorer (arrow navigation + Enter to open + right-click menu key)
app_explorer_key:
    push rax
    push rbx
    push rcx
    push rdx

    ; Check if rename mode is active
    cmp byte [exp_rename_active], 1
    je .exp_rename_key
    ; Check if new folder mode is active
    cmp byte [exp_newfolder_active], 1
    je .exp_newfolder_key

    mov eax, esi
    ; Extract scancode (lowest byte)
    movzx ecx, al           ; scancode

    ; Check for extended arrow keys
    cmp cl, 0xC8            ; Up arrow (E0 48 -> stored as 0xC8)
    je .exp_key_up
    cmp cl, 0xD0            ; Down arrow
    je .exp_key_down
    cmp cl, 0x1C            ; Enter scancode
    je .exp_key_enter

    ; Check ASCII
    mov eax, esi
    shr eax, 8
    and eax, 0xFF
    cmp al, 13              ; Enter ASCII
    je .exp_key_enter

    jmp .exp_key_done

; --- Rename input key handler ---
.exp_rename_key:
    mov eax, esi
    movzx ecx, al           ; scancode
    shr eax, 8
    and eax, 0xFF            ; ASCII
    mov edx, eax

    ; Escape cancels
    cmp cl, 0x01
    je .exp_rename_cancel

    ; Enter confirms rename
    cmp dl, 13
    je .exp_rename_confirm

    ; Backspace
    cmp dl, 8
    je .exp_rename_bs

    ; Printable chars
    cmp dl, 32
    jl .exp_key_done
    cmp dl, 126
    jg .exp_key_done

    ; Add char if room
    mov ecx, [exp_rename_cursor]
    cmp ecx, 22
    jge .exp_key_done
    lea rax, [exp_rename_buf]
    mov [rax + rcx], dl
    inc ecx
    mov byte [rax + rcx], 0
    mov [exp_rename_cursor], ecx
    jmp .exp_key_done

.exp_rename_bs:
    mov ecx, [exp_rename_cursor]
    test ecx, ecx
    jz .exp_key_done
    dec ecx
    lea rax, [exp_rename_buf]
    mov byte [rax + rcx], 0
    mov [exp_rename_cursor], ecx
    jmp .exp_key_done

.exp_rename_cancel:
    mov byte [exp_rename_active], 0
    jmp .exp_key_done

.exp_rename_confirm:
    ; Apply rename: copy rename_buf into the VFS entry name (24 bytes)
    mov byte [exp_rename_active], 0
    mov edi, [explorer_sel]
    call fat16_get_entry
    test rax, rax
    jz .exp_key_done
    ; Copy new name into entry (up to 23 chars, pad with 0)
    push rsi
    push rdi
    push rcx
    lea rsi, [exp_rename_buf]
    mov rdi, rax              ; destination = entry start (name field)
    xor ecx, ecx
.rename_copy:
    cmp ecx, 23
    jge .rename_pad
    mov al, [rsi + rcx]
    test al, al
    jz .rename_pad
    mov [rdi + rcx], al
    inc ecx
    jmp .rename_copy
.rename_pad:
    ; Null-pad remaining bytes up to 24
    cmp ecx, 24
    jge .rename_done_copy
    mov byte [rdi + rcx], 0
    inc ecx
    jmp .rename_pad
.rename_done_copy:
    pop rcx
    pop rdi
    pop rsi
    jmp .exp_key_done

; --- New Folder input key handler ---
.exp_newfolder_key:
    mov eax, esi
    movzx ecx, al           ; scancode
    shr eax, 8
    and eax, 0xFF
    mov edx, eax

    ; Escape cancels
    cmp cl, 0x01
    je .exp_newfolder_cancel

    ; Enter confirms
    cmp dl, 13
    je .exp_newfolder_confirm

    ; Backspace
    cmp dl, 8
    je .exp_newfolder_bs

    ; Printable chars
    cmp dl, 32
    jl .exp_key_done
    cmp dl, 126
    jg .exp_key_done

    ; Add char
    mov ecx, [exp_newfolder_cursor]
    cmp ecx, 22
    jge .exp_key_done
    lea rax, [exp_newfolder_buf]
    mov [rax + rcx], dl
    inc ecx
    mov byte [rax + rcx], 0
    mov [exp_newfolder_cursor], ecx
    jmp .exp_key_done

.exp_newfolder_bs:
    mov ecx, [exp_newfolder_cursor]
    test ecx, ecx
    jz .exp_key_done
    dec ecx
    lea rax, [exp_newfolder_buf]
    mov byte [rax + rcx], 0
    mov [exp_newfolder_cursor], ecx
    jmp .exp_key_done

.exp_newfolder_cancel:
    mov byte [exp_newfolder_active], 0
    jmp .exp_key_done

.exp_newfolder_confirm:
    ; Create folder: add a VFS dir entry at end of current directory listing
    mov byte [exp_newfolder_active], 0
    ; Check name is not empty
    cmp byte [exp_newfolder_buf], 0
    je .exp_key_done
    ; For VFS: we add an entry after the current directory entries
    ; This is a cosmetic VFS, so we just show a "Created!" message
    ; (Real filesystem operations would need FAT16 write support)
    mov byte [exp_newfolder_done_msg], 1
    
    ; Create actual directory on disk/FAT16
    ; 1. Format name to 8.3
    lea rdi, [fat16_name_buf]
    lea rsi, [exp_newfolder_buf]
    ; Space pad
    push rdi
    mov ecx, 11
    mov al, ' '
    rep stosb
    pop rdi
    ; Copy name (up to 8 chars, simple)
    mov ecx, 0
.fmt_loop:
    cmp ecx, 8
    jge .fmt_fill
    mov al, [rsi + rcx]
    test al, al
    jz .fmt_fill
    ; Toupper
    cmp al, 'a'
    jl .fmt_cpy
    cmp al, 'z'
    jg .fmt_cpy
    sub al, 32
.fmt_cpy:
    mov [rdi + rcx], al
    inc ecx
    jmp .fmt_loop
.fmt_fill:
    
    ; 2. Create 0-byte file
    lea rdi, [fat16_name_buf]
    mov rsi, exp_newfolder_buf ; dummy src
    xor edx, edx ; size 0
    call fat16_write_file
    
    ; 3. Hack: Find the entry and flip Attribute to Directory (0x10)
    ; fat16_write_file updates FAT16_ROOT_CACHE. We can find it there.
    mov rbx, 0x920000 ; FAT16_ROOT_CACHE
    movzx r8d, word [fat16_root_entries] ; usually 512
    xor ecx, ecx
.find_new_loop:
    cmp ecx, r8d
    jge .find_done
    cmp byte [rbx], 0
    je .find_done
    
    ; Check name match (11 chars)
    push rcx
    push rdi
    push rsi
    mov rdi, rbx
    lea rsi, [fat16_name_buf]
    mov ecx, 11
    repe cmpsb
    pop rsi
    pop rdi
    pop rcx
    je .found_to_patch
    
    add rbx, 32
    inc ecx
    jmp .find_new_loop
    
.found_to_patch:
    mov byte [rbx + 11], 0x10 ; ATTR_DIRECTORY
    ; Sync root cache to disk
    call fat16_sync_root
    
.find_done:
    jmp .exp_key_done

.exp_key_up:
    mov eax, [explorer_sel]
    test eax, eax
    jz .exp_key_done
    dec eax
    mov [explorer_sel], eax
    jmp .exp_key_done

.exp_key_down:
    mov eax, [explorer_sel]
    inc eax
    ; Check against FAT16 file count
    push rax
    call fat16_file_count
    mov ecx, eax
    pop rax
    cmp eax, ecx
    jge .exp_key_done
    mov [explorer_sel], eax
    jmp .exp_key_done

.exp_key_enter:
    ; Open selected file
    mov eax, [explorer_sel]
    push rax
    mov edi, eax
    call fat16_get_entry
    test rax, rax
    jz .eke_done
    ; Check if directory
    mov cl, [rax + 11]
    test cl, 0x10
    jz .eke_file
    
    ; Enter directory
    ; Cluster is at +26 (low word)
    movzx eax, word [rax + 26]
    call fat16_change_dir
    ; Reset selection
    mov dword [explorer_sel], 0
    jmp .eke_done

.eke_file:
    mov rdi, rax
    call app_open_file
.eke_done:
    pop rax

.exp_key_done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; TERMINAL APP
; Command prompt with scrollable output history
; ============================================================================

app_terminal_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    ; Black terminal background
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov rcx, r15
    sub rcx, TITLEBAR_HEIGHT + BORDER_WIDTH
    cmp rcx, 0
    jle .term_draw_done
    mov r8d, 0x00111111
    call render_rect

    ; Draw history lines
    mov eax, [term_hist_count]
    test eax, eax
    jz .term_no_hist

    ; Calculate how many lines fit on screen (reserve 1 line for prompt)
    mov ecx, r15d
    sub ecx, TITLEBAR_HEIGHT + BORDER_WIDTH + 16
    xor edx, edx
    push rax
    mov eax, ecx
    mov ecx, 14                  ; line height
    xor edx, edx
    div ecx
    mov ecx, eax                 ; max visible lines
    pop rax
    dec ecx                      ; -1 for prompt line
    cmp ecx, 0
    jle .term_no_hist

    ; Show last N lines of history
    ; start_idx = max(0, hist_count - max_visible)
    mov edx, eax                 ; hist_count
    sub edx, ecx                 ; hist_count - max_visible
    cmp edx, 0
    jge .term_start_ok
    xor edx, edx
.term_start_ok:
    ; edx = start index, eax = hist_count
    push rbx
    lea rbx, [term_hist_ptrs]
    xor r8d, r8d                 ; display line counter
.term_hist_loop:
    cmp edx, eax
    jge .term_hist_end

    push rax
    push rdx
    push r8

    ; Get string pointer
    mov rcx, [rbx + rdx * 8]
    test rcx, rcx
    jz .term_hist_skip

    ; Draw line
    mov rdi, r12
    add rdi, BORDER_WIDTH + 6
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 4
    imul eax, r8d, 14
    add rsi, rax
    mov rdx, rcx
    mov ecx, 0x0000DD00          ; Green output text
    mov r8d, 0x00111111
    call render_text

.term_hist_skip:
    pop r8
    pop rdx
    pop rax
    inc edx
    inc r8d
    jmp .term_hist_loop

.term_hist_end:
    ; r8d = number of lines drawn
    mov [term_draw_lines], r8d
    pop rbx
    jmp .term_draw_prompt

.term_no_hist:
    mov dword [term_draw_lines], 0

.term_draw_prompt:
    ; Draw prompt
    mov rdi, r12
    add rdi, BORDER_WIDTH + 6
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 4
    mov eax, [term_draw_lines]
    imul eax, 14
    add rsi, rax
    mov rdx, szTermPrompt
    mov ecx, 0x0000FF00
    mov r8d, 0x00111111
    call render_text

    ; Draw input text after prompt "C:\> "
    mov rdi, r12
    add rdi, BORDER_WIDTH + 6 + 40
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 4
    mov eax, [term_draw_lines]
    imul eax, 14
    add rsi, rax
    lea rdx, [term_input]
    mov ecx, 0x00FFFFFF
    mov r8d, 0x00111111
    call render_text

    ; Draw cursor
    mov eax, [term_cursor]
    imul eax, FONT_WIDTH
    add eax, BORDER_WIDTH + 6 + 40
    mov rdi, r12
    add edi, eax
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 4
    mov eax, [term_draw_lines]
    imul eax, 14
    add rsi, rax
    mov rdx, szCursor
    mov ecx, 0x00FFFFFF
    mov r8d, 0x00111111
    call render_text

.term_draw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

app_terminal_click:
    ret

; Key handler: RDI=window_ptr, ESI=key_event [pressed:8|mods:8|ascii:8|scan:8]
app_terminal_key:
    push rax
    push rbx
    push rcx
    push rdx

    ; Extract ASCII
    mov eax, esi
    shr eax, 8
    and eax, 0xFF
    test eax, eax
    jz .term_key_done

    ; Enter
    cmp al, 13
    je .term_enter
    ; Backspace
    cmp al, 8
    je .term_backspace

    ; Normal printable char
    cmp al, 32
    jl .term_key_done
    cmp al, 126
    jg .term_key_done

    mov ecx, [term_cursor]
    cmp ecx, 62
    jge .term_key_done
    lea rbx, [term_input]
    mov [rbx + rcx], al
    inc ecx
    mov byte [rbx + rcx], 0
    mov [term_cursor], ecx
    jmp .term_key_done

.term_backspace:
    mov ecx, [term_cursor]
    test ecx, ecx
    jz .term_key_done
    dec ecx
    lea rbx, [term_input]
    mov byte [rbx + rcx], 0
    mov [term_cursor], ecx
    jmp .term_key_done

.term_enter:
    lea rbx, [term_input]
    cmp byte [rbx], 0
    je .term_key_done

    ; Add "C:\> <input>" echo to history
    ; Build echo string in term_echo_buf
    lea rdi, [term_echo_buf]
    lea rsi, [szTermPrompt]
.copy_prompt:
    lodsb
    test al, al
    jz .prompt_copied
    stosb
    jmp .copy_prompt
.prompt_copied:
    lea rsi, [term_input]
.copy_input:
    lodsb
    stosb
    test al, al
    jnz .copy_input

    ; Add echo string pointer to history
    call term_add_history_echo

    ; Match command
    lea rsi, [term_input]
    
    ; Check "help"
    lea rdi, [szCmdHelp]
    call term_strcmp
    test eax, eax
    jnz .cmd_help
    
    ; Check "ver"
    lea rdi, [szCmdVer]
    call term_strcmp
    test eax, eax
    jnz .cmd_ver
    
    ; Check "cls" or "clear"
    lea rdi, [szCmdCls]
    call term_strcmp
    test eax, eax
    jnz .cmd_cls
    lea rdi, [szCmdClear]
    call term_strcmp
    test eax, eax
    jnz .cmd_cls
    
    ; Check "dir" or "ls"
    lea rdi, [szCmdDir]
    call term_strcmp
    test eax, eax
    jnz .cmd_dir
    lea rdi, [szCmdLs]
    call term_strcmp
    test eax, eax
    jnz .cmd_dir
    
    ; Check "time" or "date"
    lea rdi, [szCmdTime]
    call term_strcmp
    test eax, eax
    jnz .cmd_time
    lea rdi, [szCmdDate]
    call term_strcmp
    test eax, eax
    jnz .cmd_time
    
    ; Check "exit"
    lea rdi, [szCmdExit]
    call term_strcmp
    test eax, eax
    jnz .cmd_exit
    
    ; Check "pwd"
    lea rdi, [szCmdPwd]
    call term_strcmp
    test eax, eax
    jnz .cmd_pwd
    
    ; Check "echo" (starts with echo)
    lea rdi, [szCmdEcho]
    call term_starts_with
    test eax, eax
    jnz .cmd_echo

    ; Check "debug"
    lea rdi, [szCmdDebug]
    call term_strcmp
    test eax, eax
    jnz .cmd_debug

    ; Check "xdebug"
    lea rdi, [szCmdXDebug]
    call term_strcmp
    test eax, eax
    jnz .cmd_xdebug

    ; Check "restart" or "reboot"
    lea rdi, [szCmdRestart]
    call term_strcmp
    test eax, eax
    jnz .cmd_restart
    lea rdi, [szCmdReboot]
    call term_strcmp
    test eax, eax
    jnz .cmd_restart

    ; Check "usb" (alias for debug)
    lea rdi, [szCmdUsb]
    call term_strcmp
    test eax, eax
    jnz .cmd_debug

    ; Check "mouse"
    lea rdi, [szCmdMouse]
    call term_strcmp
    test eax, eax
    jnz .cmd_mouse

    ; Check "touchpad" or "idebug"
    lea rdi, [szCmdTouchpad]
    call term_strcmp
    test eax, eax
    jnz .cmd_idebug
    lea rdi, [szCmdIdebug]
    call term_strcmp
    test eax, eax
    jnz .cmd_idebug

    ; Unknown command
    lea rdx, [szCmdUnknown]
    jmp .cmd_add_output
    
.cmd_exit:
    ; Close terminal window
    mov rdi, rbx ; window ptr
    call wm_close_window
    jmp .term_key_done
    
.cmd_pwd:
    lea rdx, [szTermPrompt] ; "C:\> "
    jmp .cmd_add_output

.cmd_help:
    lea rdx, [szCmdHelpOut]
    jmp .cmd_add_output
.cmd_ver:
    lea rdx, [szCmdVerOut]
    jmp .cmd_add_output
.cmd_dir:
    lea rdx, [szCmdDirOut] ; Static for now, could be dynamic
    jmp .cmd_add_output
.cmd_time:
    lea rdx, [szTime] ; Use taskbar time string
    jmp .cmd_add_output
    
.cmd_echo:
    ; Echo back the rest of the string
    lea rdx, [term_input + 5] ; skip "echo "
    jmp .cmd_add_output

.cmd_debug:
    ; Build XHCI debug dump into buffer
    lea rdi, [term_debug_buf]
    call xhci_debug_dump
    lea rdx, [term_debug_buf]
    jmp .cmd_add_output

.cmd_xdebug:
    ; Build XHCI debug dump into buffer
    lea rdi, [term_debug_buf]
    call xhci_debug_dump
    lea rdx, [term_debug_buf]
    jmp .cmd_add_output

.cmd_restart:
    ; Reboot via 8042 keyboard controller pulse reset line
    cli
    ; Try 8042 reset (pulse CPU reset line)
    call mouse_wait_input       ; wait for 8042 input buffer clear
    mov al, 0xFE                ; Reset command
    out 0x64, al
    ; If that didn't work, try triple fault
    lidt [.null_idt]
    int 0
.null_idt:
    dw 0
    dq 0


.cmd_cls:
    mov dword [term_hist_count], 0
    lea rcx, [term_hist_ptrs]
    xor eax, eax
.cls_loop:
    cmp eax, TERM_MAX_HIST
    jge .term_clear_input
    mov qword [rcx + rax * 8], 0
    inc eax
    jmp .cls_loop

.cmd_mouse:
    lea rdi, [term_debug_buf]
    call mouse_debug_dump
    lea rdx, [term_debug_buf]
    jmp .cmd_add_output

.cmd_idebug:
    lea rdi, [term_debug_buf]
    call i2c_hid_debug_dump
    lea rdx, [term_debug_buf]
    jmp .cmd_add_output



.cmd_add_output:
    ; rdx = static response string pointer
    ; Add to history
    mov eax, [term_hist_count]
    cmp eax, TERM_MAX_HIST
    jge .term_scroll_hist

    lea rcx, [term_hist_ptrs]
    mov [rcx + rax * 8], rdx
    inc dword [term_hist_count]
    jmp .term_clear_input

.term_scroll_hist:
    ; Shift history up by 1
    lea rcx, [term_hist_ptrs]
    mov eax, 0
.scroll_loop:
    cmp eax, TERM_MAX_HIST - 1
    jge .scroll_done
    mov rbx, [rcx + rax * 8 + 8]
    mov [rcx + rax * 8], rbx
    inc eax
    jmp .scroll_loop
.scroll_done:
    mov [rcx + (TERM_MAX_HIST - 1) * 8], rdx
    jmp .term_clear_input

.term_clear_input:
    mov byte [term_input], 0
    mov dword [term_cursor], 0

.term_key_done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Helper: add echo buffer pointer to history
term_add_history_echo:
    push rax
    push rcx
    push rdx
    mov eax, [term_hist_count]
    cmp eax, TERM_MAX_HIST
    jge .echo_scroll

    lea rcx, [term_hist_ptrs]
    lea rdx, [term_echo_buf]
    mov [rcx + rax * 8], rdx
    inc dword [term_hist_count]
    jmp .echo_done

.echo_scroll:
    lea rcx, [term_hist_ptrs]
    mov eax, 0
.echo_shift:
    cmp eax, TERM_MAX_HIST - 1
    jge .echo_shift_done
    mov rdx, [rcx + rax * 8 + 8]
    mov [rcx + rax * 8], rdx
    inc eax
    jmp .echo_shift
.echo_shift_done:
    lea rdx, [term_echo_buf]
    mov [rcx + (TERM_MAX_HIST - 1) * 8], rdx
.echo_done:
    pop rdx
    pop rcx
    pop rax
    ret

; Internal helper: string compare (case insensitive)
; RSI = input, RDI = cmd string
; Returns EAX=1 if match, 0 if not
term_strcmp:
    push rsi
    push rdi
.tcmp_loop:
    mov al, [rsi]
    mov bl, [rdi]
    
    ; Lowercase AL
    cmp al, 'A'
    jl .al_lower
    cmp al, 'Z'
    jg .al_lower
    add al, 32
.al_lower:

    ; Lowercase BL (should be already, but safe)
    cmp bl, 'A'
    jl .bl_lower
    cmp bl, 'Z'
    jg .bl_lower
    add bl, 32
.bl_lower:

    cmp al, bl
    jne .tcmp_fail
    test bl, bl
    jz .tcmp_match
    inc rsi
    inc rdi
    jmp .tcmp_loop
.tcmp_fail:
    pop rdi
    pop rsi
    xor eax, eax
    ret
.tcmp_match:
    pop rdi
    pop rsi
    mov eax, 1
    ret

; Helper: starts with
term_starts_with:
    push rsi
    push rdi
.tsw_loop:
    mov bl, [rdi]
    test bl, bl
    jz .tsw_match
    mov al, [rsi]
    or al, 0x20
    cmp al, bl
    jne .tsw_fail
    inc rsi
    inc rdi
    jmp .tsw_loop
.tsw_fail:
    pop rdi
    pop rsi
    xor eax, eax
    ret
.tsw_match:
    pop rdi
    pop rsi
    mov eax, 1
    ret

; ============================================================================
; NOTEPAD APP
; Multi-line text editor with arrow navigation, Enter, File/Edit menus
; Buffer layout: NP_MAX_LINES lines, each NP_MAX_COLS bytes
; np_line_len[i] = length of line i
; ============================================================================

app_notepad_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    ; Menu bar
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, NP_MENU_H
    mov r8d, 0x00E8E8E8
    call render_rect

    ; "File" menu label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 2
    mov rdx, szNoteMenuFile
    mov ecx, 0x00333333
    mov r8d, 0x00E8E8E8
    call render_text

    ; "Edit" menu label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 52
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 2
    mov rdx, szNoteMenuEdit
    mov ecx, 0x00333333
    mov r8d, 0x00E8E8E8
    call render_text

    ; White editing area
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_EDIT_TOP
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov rcx, r15
    sub rcx, TITLEBAR_HEIGHT + NP_EDIT_TOP + BORDER_WIDTH
    cmp rcx, 0
    jle .note_draw_done
    mov r8d, 0x00FFFFFF
    call render_rect

    ; Calculate visible lines
    mov eax, r15d
    sub eax, TITLEBAR_HEIGHT + NP_EDIT_TOP + BORDER_WIDTH
    xor edx, edx
    mov ecx, 14                  ; line height
    div ecx
    mov r8d, eax                 ; max visible lines
    test r8d, r8d
    jz .note_draw_done

    ; Draw text lines
    mov eax, [np_scroll_top]
    xor ecx, ecx                ; display line counter
.np_draw_lines:
    cmp ecx, r8d
    jge .np_lines_done
    cmp eax, [np_num_lines]
    jge .np_lines_done

    push rax
    push rcx
    push r8

    ; Get line pointer: notepad_buf + line_idx * NP_MAX_COLS
    mov edx, eax
    imul edx, NP_MAX_COLS
    lea rdx, [notepad_buf + rdx]

    ; Check if line is empty
    cmp byte [rdx], 0
    je .np_empty_line

    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_EDIT_TOP + 2
    imul r8d, ecx, 14
    add esi, r8d
    mov ecx, 0x00000000
    mov r8d, 0x00FFFFFF
    call render_text

.np_empty_line:
    pop r8
    pop rcx
    pop rax

    inc eax
    inc ecx
    jmp .np_draw_lines

.np_lines_done:
    ; Draw cursor
    mov eax, [np_cursor_row]
    sub eax, [np_scroll_top]
    cmp eax, 0
    jl .note_draw_done
    cmp eax, r8d
    jge .note_draw_done

    ; Cursor position
    mov edi, [np_cursor_col]
    imul edi, FONT_WIDTH
    add edi, BORDER_WIDTH + 4
    add edi, r12d
    mov esi, eax
    imul esi, 14
    add esi, TITLEBAR_HEIGHT + NP_EDIT_TOP + 2
    add esi, r13d
    mov rdx, szCursor
    mov ecx, 0x00000000
    mov r8d, 0x00FFFFFF
    call render_text

    ; --- Draw dropdown menu if open ---
    cmp byte [np_menu_open], 0
    je .note_draw_done

    cmp byte [np_menu_open], 1
    je .draw_file_menu
    cmp byte [np_menu_open], 2
    je .draw_edit_menu
    jmp .note_draw_done

.draw_file_menu:
    ; File dropdown (3 items: New, Save, Close)
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H
    mov edx, 100
    mov ecx, CTX_ITEM_H * 3 + 4
    mov r8d, 0x00F0F0F0
    call render_rect
    ; Border
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H
    mov edx, 100
    mov ecx, 1
    mov r8d, 0x00999999
    call render_rect
    ; Item 0: New
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H + 4
    mov rdx, szFileNew
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text
    ; Item 1: Save
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H + 4 + CTX_ITEM_H
    mov rdx, szFileSave
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text
    ; Item 2: Close
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H + 4 + CTX_ITEM_H * 2
    mov rdx, szFileClose
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text
    jmp .note_draw_done

.draw_edit_menu:
    ; Edit dropdown
    mov rdi, r12
    add rdi, BORDER_WIDTH + 48
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H
    mov edx, 110
    mov ecx, CTX_ITEM_H * 2 + 4
    mov r8d, 0x00F0F0F0
    call render_rect
    ; Border
    mov rdi, r12
    add rdi, BORDER_WIDTH + 48
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H
    mov edx, 110
    mov ecx, 1
    mov r8d, 0x00999999
    call render_rect
    ; Items
    mov rdi, r12
    add rdi, BORDER_WIDTH + 56
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H + 4
    mov rdx, szEditSelAll
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text
    mov rdi, r12
    add rdi, BORDER_WIDTH + 56
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + NP_MENU_H + 4 + CTX_ITEM_H
    mov rdx, szEditClear
    mov ecx, 0x00222222
    mov r8d, 0x00F0F0F0
    call render_text

.note_draw_done:
    ; Show save-as dialog overlay
    cmp byte [np_save_dialog], 1
    jne .np_no_save_dialog

    ; Semi-transparent dark overlay background
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 40
    mov edx, r14d
    sub edx, BORDER_WIDTH * 2 + 40
    mov ecx, 80
    mov r8d, 0x00223344
    call render_rect

    ; Border
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 40
    mov edx, r14d
    sub edx, BORDER_WIDTH * 2 + 40
    mov ecx, 1
    mov r8d, 0x004488AA
    call render_rect

    ; "Save As" title
    mov rdi, r12
    add rdi, BORDER_WIDTH + 30
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 46
    mov rdx, szSaveAsTitle
    mov ecx, 0x00AADDFF
    mov r8d, 0x00223344
    call render_text

    ; "Filename:" label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 30
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 66
    mov rdx, szSaveAsFilename
    mov ecx, 0x00CCCCCC
    mov r8d, 0x00223344
    call render_text

    ; Input field background (white box)
    mov rdi, r12
    add rdi, BORDER_WIDTH + 104
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 62
    mov edx, r14d
    sub edx, BORDER_WIDTH * 2 + 140
    mov ecx, 18
    mov r8d, 0x00FFFFFF
    call render_rect

    ; Input text
    mov rdi, r12
    add rdi, BORDER_WIDTH + 108
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 65
    lea rdx, [np_saveas_buf]
    mov ecx, 0x00000000
    mov r8d, 0x00FFFFFF
    call render_text

    ; Cursor in input field
    mov eax, [np_saveas_cursor]
    imul eax, FONT_WIDTH
    add eax, BORDER_WIDTH + 108
    mov edi, eax
    add edi, r12d
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 65
    mov rdx, szCursor
    mov ecx, 0x00000000
    mov r8d, 0x00FFFFFF
    call render_text

    ; "Enter=Save  Esc=Cancel" hint
    mov rdi, r12
    add rdi, BORDER_WIDTH + 30
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 86
    mov rdx, szSaveAsHint
    mov ecx, 0x00888888
    mov r8d, 0x00223344
    call render_text

.np_no_save_dialog:

    ; Show "Saved!" overlay if active
    cmp byte [np_save_done_msg], 1
    jne .note_draw_exit
    ; Dark overlay box centered in window
    mov rdi, r12
    mov eax, r14d
    sub eax, 120
    shr eax, 1
    add edi, eax          ; x = win_x + (win_w - 120)/2
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 60
    mov edx, 120
    mov ecx, 30
    mov r8d, 0x00228B22   ; dark green
    call render_rect
    ; "Saved!" text
    mov rdi, r12
    mov eax, r14d
    sub eax, 48           ; approx text width
    shr eax, 1
    add edi, eax
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 68
    mov rdx, szSavedMsg
    mov ecx, 0x00FFFFFF
    mov r8d, 0x00228B22
    call render_text

.note_draw_exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Click handler for notepad
app_notepad_click:
    push rax
    push rbx
    push rcx
    push rdx

    ; RSI=client_x, RDX=client_y

    ; Check if save-done message is showing - dismiss on any click
    cmp byte [np_save_done_msg], 1
    jne .np_no_dismiss_saved
    mov byte [np_save_done_msg], 0
    jmp .np_click_done
.np_no_dismiss_saved:

    ; Check if dropdown menu is open
    cmp byte [np_menu_open], 0
    jne .np_menu_click

    ; Check if clicking on menu bar (client_y < NP_EDIT_TOP)
    cmp rdx, NP_EDIT_TOP
    jge .np_text_click

    ; Menu bar click - check which menu
    cmp rsi, 48
    jl .np_click_file
    cmp rsi, 96
    jl .np_click_edit
    jmp .np_click_done

.np_click_file:
    mov byte [np_menu_open], 1
    jmp .np_click_done

.np_click_edit:
    mov byte [np_menu_open], 2
    jmp .np_click_done

.np_menu_click:
    ; Handle click on dropdown menu item
    cmp byte [np_menu_open], 1
    je .np_file_menu_click
    cmp byte [np_menu_open], 2
    je .np_edit_menu_click
    mov byte [np_menu_open], 0
    jmp .np_click_done

.np_file_menu_click:
    ; Check Y position
    mov eax, edx
    sub eax, NP_MENU_H
    cmp eax, 4
    jl .np_dismiss_menu
    sub eax, 4
    xor edx, edx
    mov ecx, CTX_ITEM_H
    div ecx
    cmp eax, 0
    je .np_file_new
    cmp eax, 1
    je .np_file_save
    cmp eax, 2
    je .np_file_close
    jmp .np_dismiss_menu

.np_file_new:
    ; Clear buffer
    mov byte [np_menu_open], 0
    lea rdi, [notepad_buf]
    xor eax, eax
    mov ecx, NP_BUF_SIZE
    rep stosb
    lea rdi, [np_line_len]
    xor eax, eax
    mov ecx, NP_MAX_LINES
    rep stosd
    mov dword [np_cursor_row], 0
    mov dword [np_cursor_col], 0
    mov dword [np_num_lines], 1
    mov dword [np_scroll_top], 0
    jmp .np_click_done

.np_file_save:
    mov byte [np_menu_open], 0
    ; If no file is open, show save dialog for filename input
    mov rax, [np_open_entry]
    test rax, rax
    jnz .np_do_save
    ; Show save-as dialog
    mov byte [np_save_dialog], 1
    mov dword [np_saveas_cursor], 0
    mov byte [np_saveas_buf], 0
    jmp .np_click_done

.np_do_save:
    push rsi
    push rdi
    push rcx
    push rdx
    push r8
    push r9

    ; Build flat file content from notepad lines into np_saved_content
    lea rdi, [np_saved_content]
    xor ecx, ecx             ; line index
    xor r8d, r8d             ; total bytes written
.save_build_loop:
    cmp ecx, [np_num_lines]
    jge .save_build_done

    ; Copy line content
    mov eax, ecx
    imul eax, NP_MAX_COLS
    lea rsi, [notepad_buf + rax]
    mov edx, [np_line_len + rcx * 4]
    test edx, edx
    jz .save_newline
    ; Copy edx bytes
    push rcx
    mov ecx, edx
    rep movsb
    pop rcx
    add r8d, edx

.save_newline:
    ; Add CR LF (unless last line)
    mov eax, ecx
    inc eax
    cmp eax, [np_num_lines]
    jge .save_next_line
    mov byte [rdi], 13
    inc rdi
    mov byte [rdi], 10
    inc rdi
    add r8d, 2

.save_next_line:
    inc ecx
    jmp .save_build_loop

.save_build_done:
    ; r8d = total bytes
    mov [np_save_total_bytes], r8d

    ; Write to FAT16 if we have an open file entry
    mov rax, [np_open_entry]
    test rax, rax
    jz .save_mem_only

    ; Get the 11-byte filename from the dir entry
    mov rdi, rax             ; 8.3 filename at entry+0
    lea rsi, [np_saved_content]
    mov edx, r8d
    call fat16_write_file

.save_mem_only:
    mov byte [np_has_saved], 1
    mov byte [np_save_done_msg], 1

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    jmp .np_click_done

.np_file_close:
    mov byte [np_menu_open], 0
    ; Close window - we'd need the window ID. For now just clear.
    jmp .np_click_done

.np_edit_menu_click:
    mov eax, edx
    sub eax, NP_MENU_H
    cmp eax, 4
    jl .np_dismiss_menu
    sub eax, 4
    xor edx, edx
    mov ecx, CTX_ITEM_H
    div ecx
    cmp eax, 0
    je .np_edit_sel_all
    cmp eax, 1
    je .np_edit_clear
    jmp .np_dismiss_menu

.np_edit_sel_all:
    ; Just dismiss for now (no selection support yet)
    mov byte [np_menu_open], 0
    jmp .np_click_done

.np_edit_clear:
    mov byte [np_menu_open], 0
    ; Same as File > New
    lea rdi, [notepad_buf]
    xor eax, eax
    mov ecx, NP_BUF_SIZE
    rep stosb
    lea rdi, [np_line_len]
    xor eax, eax
    mov ecx, NP_MAX_LINES
    rep stosd
    mov dword [np_cursor_row], 0
    mov dword [np_cursor_col], 0
    mov dword [np_num_lines], 1
    mov dword [np_scroll_top], 0
    jmp .np_click_done

.np_dismiss_menu:
    mov byte [np_menu_open], 0
    jmp .np_click_done

.np_text_click:
    ; Close any open menu
    mov byte [np_menu_open], 0

    ; Calculate which line/col was clicked
    mov eax, edx
    sub eax, NP_EDIT_TOP + 2
    cmp eax, 0
    jl .np_click_done
    xor edx, edx
    mov ecx, 14
    div ecx
    ; eax = display line
    add eax, [np_scroll_top]
    ; Clamp to valid range
    cmp eax, [np_num_lines]
    jl .np_row_ok
    mov eax, [np_num_lines]
    dec eax
.np_row_ok:
    mov [np_cursor_row], eax

    ; Column from X
    mov eax, esi
    sub eax, 4
    cmp eax, 0
    jge .np_col_ok
    xor eax, eax
.np_col_ok:
    xor edx, edx
    mov ecx, FONT_WIDTH
    div ecx
    ; Clamp to line length
    mov ecx, [np_cursor_row]
    mov edx, [np_line_len + rcx * 4]
    cmp eax, edx
    jle .np_col_set
    mov eax, edx
.np_col_set:
    mov [np_cursor_col], eax

.np_click_done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Key handler for notepad: supports arrows, Enter, Backspace, printable chars
app_notepad_key:
    push rax
    push rbx
    push rcx
    push rdx

    ; Check if save dialog is active - route keys there
    cmp byte [np_save_dialog], 1
    je .np_saveas_key

    ; Close menu on any key
    mov byte [np_menu_open], 0

    ; Extract scancode and ASCII
    mov eax, esi
    movzx ecx, al           ; scancode
    shr eax, 8
    and eax, 0xFF            ; ASCII
    mov edx, eax             ; edx = ASCII

    ; Check arrow keys (extended scancodes stored as 0x80|raw)
    cmp cl, 0xC8             ; Up
    je .np_arrow_up
    cmp cl, 0xD0             ; Down
    je .np_arrow_down
    cmp cl, 0xCB             ; Left
    je .np_arrow_left
    cmp cl, 0xCD             ; Right
    je .np_arrow_right

    ; ASCII-based checks
    test edx, edx
    jz .np_key_done

    cmp dl, 8                ; Backspace
    je .np_backspace
    cmp dl, 13               ; Enter
    je .np_enter
    cmp dl, 9                ; Tab -> insert spaces
    je .np_tab

    ; Printable character
    cmp dl, 32
    jl .np_key_done
    cmp dl, 126
    jg .np_key_done

    ; Insert char at cursor position
    mov eax, [np_cursor_row]
    mov ecx, [np_line_len + rax * 4]
    cmp ecx, NP_MAX_COLS - 1
    jge .np_key_done

    ; Shift chars right from cursor_col to end
    imul ebx, eax, NP_MAX_COLS
    lea rbx, [notepad_buf + rbx]
    mov eax, ecx              ; line length
    mov ecx, [np_cursor_col]
.np_shift_right:
    cmp eax, ecx
    jle .np_insert_char
    mov r8b, [rbx + rax - 1]
    mov [rbx + rax], r8b
    dec eax
    jmp .np_shift_right
.np_insert_char:
    mov [rbx + rcx], dl
    mov eax, [np_cursor_row]
    inc dword [np_line_len + rax * 4]
    ; Null terminate
    mov ecx, [np_line_len + rax * 4]
    mov byte [rbx + rcx], 0
    inc dword [np_cursor_col]
    jmp .np_key_done

.np_backspace:
    mov eax, [np_cursor_col]
    test eax, eax
    jnz .np_bs_inline

    ; At column 0: merge with previous line
    mov eax, [np_cursor_row]
    test eax, eax
    jz .np_key_done

    ; Merge current line onto end of previous line
    dec eax
    mov ecx, [np_line_len + rax * 4]  ; prev line len
    mov edx, ecx                       ; new cursor col
    push rdx

    ; Get pointers
    imul ebx, eax, NP_MAX_COLS
    lea rbx, [notepad_buf + rbx]       ; prev line
    mov r8d, eax
    inc r8d
    imul r8d, NP_MAX_COLS
    lea r8, [notepad_buf + r8]          ; current line

    ; Append current line content to prev line
    mov ecx, [np_cursor_row]
    mov r9d, [np_line_len + rcx * 4]   ; current line len
    ; Check if combined length fits
    mov r10d, [np_line_len + rax * 4]
    add r10d, r9d
    cmp r10d, NP_MAX_COLS - 1
    jge .np_bs_no_merge

    ; Copy current line to end of prev line
    xor ecx, ecx
.np_merge_copy:
    cmp ecx, r9d
    jge .np_merge_done
    mov dl, [r8 + rcx]
    mov [rbx + r10], dl
    inc r10d
    inc ecx
    jmp .np_merge_copy
    ; Actually let me redo this properly
.np_merge_done:
    ; prev line new length
    mov [np_line_len + rax * 4], r10d
    mov byte [rbx + r10], 0

    ; Shift all subsequent lines up by 1
    mov ecx, [np_cursor_row]
    mov edx, [np_num_lines]
.np_shift_lines_up:
    mov r8d, ecx
    inc r8d
    cmp r8d, edx
    jge .np_shift_up_done
    ; Copy line r8d to ecx
    push rcx
    push rdx
    imul r9d, r8d, NP_MAX_COLS
    lea r9, [notepad_buf + r9]
    imul ecx, ecx, NP_MAX_COLS
    lea rcx, [notepad_buf + rcx]
    xor eax, eax
.copy_line_up:
    mov dl, [r9 + rax]
    mov [rcx + rax], dl
    inc eax
    cmp eax, NP_MAX_COLS
    jl .copy_line_up
    pop rdx
    pop rcx
    ; Copy line length
    mov eax, [np_line_len + r8 * 4]
    mov [np_line_len + rcx * 4], eax
    inc ecx
    jmp .np_shift_lines_up
.np_shift_up_done:
    dec dword [np_num_lines]
    pop rdx
    dec dword [np_cursor_row]
    mov [np_cursor_col], edx
    jmp .np_ensure_visible

.np_bs_no_merge:
    pop rdx
    jmp .np_key_done

.np_bs_inline:
    ; Delete char before cursor
    mov eax, [np_cursor_row]
    imul ebx, eax, NP_MAX_COLS
    lea rbx, [notepad_buf + rbx]
    mov ecx, [np_cursor_col]
    ; Shift left from cursor_col to end
.np_shift_left:
    mov r8d, [np_line_len + rax * 4]
    cmp ecx, r8d
    jge .np_bs_done
    mov dl, [rbx + rcx]
    mov [rbx + rcx - 1], dl
    inc ecx
    jmp .np_shift_left
.np_bs_done:
    mov eax, [np_cursor_row]
    dec dword [np_line_len + rax * 4]
    mov ecx, [np_line_len + rax * 4]
    mov byte [rbx + rcx], 0
    dec dword [np_cursor_col]
    jmp .np_key_done

.np_enter:
    ; Insert new line at cursor position
    mov eax, [np_num_lines]
    cmp eax, NP_MAX_LINES - 1
    jge .np_key_done

    ; Shift all lines from cursor_row+1 down by 1
    mov ecx, [np_num_lines]
    dec ecx
.np_shift_down:
    mov edx, [np_cursor_row]
    cmp ecx, edx
    jle .np_shift_down_done
    ; Copy line ecx to ecx+1
    push rcx
    imul eax, ecx, NP_MAX_COLS
    lea rbx, [notepad_buf + rax]
    add eax, NP_MAX_COLS
    lea r8, [notepad_buf + rax]
    xor edx, edx
.copy_line_down:
    mov al, [rbx + rdx]
    mov [r8 + rdx], al
    inc edx
    cmp edx, NP_MAX_COLS
    jl .copy_line_down
    pop rcx
    ; Copy line length
    mov eax, [np_line_len + rcx * 4]
    mov [np_line_len + rcx * 4 + 4], eax
    dec ecx
    jmp .np_shift_down
.np_shift_down_done:

    ; Now split current line at cursor position
    mov eax, [np_cursor_row]
    imul ebx, eax, NP_MAX_COLS
    lea rbx, [notepad_buf + rbx]
    mov ecx, [np_cursor_col]
    mov edx, [np_line_len + rax * 4]

    ; New line gets chars from cursor_col to end
    mov r8d, eax
    inc r8d
    imul r9d, r8d, NP_MAX_COLS
    lea r9, [notepad_buf + r9]
    xor r10d, r10d
    mov eax, ecx
.np_split_copy:
    cmp eax, edx
    jge .np_split_done
    mov r11b, [rbx + rax]
    mov [r9 + r10], r11b
    inc eax
    inc r10d
    jmp .np_split_copy
.np_split_done:
    mov byte [r9 + r10], 0
    mov [np_line_len + r8 * 4], r10d

    ; Truncate current line at cursor
    mov byte [rbx + rcx], 0
    mov eax, [np_cursor_row]
    mov [np_line_len + rax * 4], ecx

    ; Move cursor to start of next line
    inc dword [np_num_lines]
    inc dword [np_cursor_row]
    mov dword [np_cursor_col], 0
    jmp .np_ensure_visible

.np_tab:
    ; Insert 4 spaces
    mov ecx, 4
.np_tab_loop:
    test ecx, ecx
    jz .np_key_done
    push rcx
    mov eax, [np_cursor_row]
    mov ecx, [np_line_len + rax * 4]
    cmp ecx, NP_MAX_COLS - 1
    jge .np_tab_skip
    imul ebx, eax, NP_MAX_COLS
    lea rbx, [notepad_buf + rbx]
    mov eax, ecx
    mov ecx, [np_cursor_col]
.np_tab_shift:
    cmp eax, ecx
    jle .np_tab_insert
    mov dl, [rbx + rax - 1]
    mov [rbx + rax], dl
    dec eax
    jmp .np_tab_shift
.np_tab_insert:
    mov byte [rbx + rcx], ' '
    mov eax, [np_cursor_row]
    inc dword [np_line_len + rax * 4]
    mov ecx, [np_line_len + rax * 4]
    mov byte [rbx + rcx], 0
    inc dword [np_cursor_col]
.np_tab_skip:
    pop rcx
    dec ecx
    jmp .np_tab_loop

.np_arrow_up:
    mov eax, [np_cursor_row]
    test eax, eax
    jz .np_key_done
    dec eax
    mov [np_cursor_row], eax
    ; Clamp col to new line length
    mov ecx, [np_line_len + rax * 4]
    cmp [np_cursor_col], ecx
    jle .np_ensure_visible
    mov [np_cursor_col], ecx
    jmp .np_ensure_visible

.np_arrow_down:
    mov eax, [np_cursor_row]
    inc eax
    cmp eax, [np_num_lines]
    jge .np_key_done
    mov [np_cursor_row], eax
    mov ecx, [np_line_len + rax * 4]
    cmp [np_cursor_col], ecx
    jle .np_ensure_visible
    mov [np_cursor_col], ecx
    jmp .np_ensure_visible

.np_arrow_left:
    mov eax, [np_cursor_col]
    test eax, eax
    jz .np_left_prev_line
    dec eax
    mov [np_cursor_col], eax
    jmp .np_key_done
.np_left_prev_line:
    mov eax, [np_cursor_row]
    test eax, eax
    jz .np_key_done
    dec eax
    mov [np_cursor_row], eax
    mov ecx, [np_line_len + rax * 4]
    mov [np_cursor_col], ecx
    jmp .np_ensure_visible

.np_arrow_right:
    mov eax, [np_cursor_row]
    mov ecx, [np_cursor_col]
    cmp ecx, [np_line_len + rax * 4]
    jl .np_right_same
    ; At end of line - move to next line
    inc eax
    cmp eax, [np_num_lines]
    jge .np_key_done
    mov [np_cursor_row], eax
    mov dword [np_cursor_col], 0
    jmp .np_ensure_visible
.np_right_same:
    inc dword [np_cursor_col]
    jmp .np_key_done

.np_ensure_visible:
    ; Auto-scroll to keep cursor visible
    mov eax, [np_cursor_row]
    cmp eax, [np_scroll_top]
    jge .np_scroll_check_bot
    mov [np_scroll_top], eax
    jmp .np_key_done
.np_scroll_check_bot:
    ; Rough: assume ~15 visible lines
    mov ecx, [np_scroll_top]
    add ecx, 15
    cmp eax, ecx
    jl .np_key_done
    sub eax, 14
    mov [np_scroll_top], eax

    jmp .np_key_done

; --- Save As dialog key handler ---
.np_saveas_key:
    mov eax, esi
    movzx ecx, al           ; scancode
    shr eax, 8
    and eax, 0xFF
    mov edx, eax             ; ASCII

    ; Escape cancels
    cmp cl, 0x01
    je .np_saveas_cancel

    ; Enter confirms save
    cmp dl, 13
    je .np_saveas_confirm

    ; Backspace
    cmp dl, 8
    je .np_saveas_bs

    ; Printable chars
    cmp dl, 32
    jl .np_key_done
    cmp dl, 126
    jg .np_key_done

    ; Add char if room (max 22 chars for filename)
    mov ecx, [np_saveas_cursor]
    cmp ecx, 22
    jge .np_key_done
    lea rax, [np_saveas_buf]
    mov [rax + rcx], dl
    inc ecx
    mov byte [rax + rcx], 0
    mov [np_saveas_cursor], ecx
    jmp .np_key_done

.np_saveas_bs:
    mov ecx, [np_saveas_cursor]
    test ecx, ecx
    jz .np_key_done
    dec ecx
    lea rax, [np_saveas_buf]
    mov byte [rax + rcx], 0
    mov [np_saveas_cursor], ecx
    jmp .np_key_done

.np_saveas_cancel:
    mov byte [np_save_dialog], 0
    jmp .np_key_done

.np_saveas_confirm:
    ; Confirm: save content with given filename
    mov byte [np_save_dialog], 0
    ; Check filename not empty
    cmp byte [np_saveas_buf], 0
    je .np_key_done

    ; Build content from notepad lines into np_saved_content
    push rsi
    push rdi
    push rcx
    push rdx
    push r8
    push r9

    lea rdi, [np_saved_content]
    xor ecx, ecx
    xor r8d, r8d
.saveas_build_loop:
    cmp ecx, [np_num_lines]
    jge .saveas_build_done
    mov eax, ecx
    imul eax, NP_MAX_COLS
    lea rsi, [notepad_buf + rax]
    mov edx, [np_line_len + rcx * 4]
    test edx, edx
    jz .saveas_newline
    push rcx
    mov ecx, edx
    rep movsb
    pop rcx
    add r8d, edx
.saveas_newline:
    mov eax, ecx
    inc eax
    cmp eax, [np_num_lines]
    jge .saveas_next_line
    mov byte [rdi], 13
    inc rdi
    mov byte [rdi], 10
    inc rdi
    add r8d, 2
.saveas_next_line:
    inc ecx
    jmp .saveas_build_loop
.saveas_build_done:
    mov [np_save_total_bytes], r8d

    ; Convert user filename to FAT16 8.3 format
    lea rdi, [np_saveas_buf]
    lea rsi, [np_saveas_83]
    call filename_to_83

    ; Write using 8.3 filename
    lea rdi, [np_saveas_83]
    lea rsi, [np_saved_content]
    mov edx, r8d
    call fat16_write_file

    mov byte [np_has_saved], 1
    mov byte [np_save_done_msg], 1

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    jmp .np_key_done

.np_key_done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; SETTINGS APP
; System information display
; ============================================================================

app_settings_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rdi

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    ; --- Display Section ---
    mov rdi, r12
    add rdi, BORDER_WIDTH + 10
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 10
    mov rdx, szSetDisplay
    mov ecx, 0x00000000
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; Resolution Label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 35
    mov rdx, szSetRes
    call render_text

    ; Resolution Buttons
    ; 800x600 Button
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 55
    mov rdx, 80
    mov rcx, 24
    mov r8d, 0x00D0D0D0
    call render_rect
    mov rdi, r12
    add rdi, BORDER_WIDTH + 26
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 60
    mov rdx, szRes800
    mov ecx, 0x00000000
    mov r8d, 0x00D0D0D0
    call render_text

    ; 1024x768 Button
    mov rdi, r12
    add rdi, BORDER_WIDTH + 110
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 55
    mov rdx, 80
    mov rcx, 24
    mov r8d, 0x00D0D0D0
    call render_rect
    mov rdi, r12
    add rdi, BORDER_WIDTH + 116
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 60
    mov rdx, szRes1024
    mov ecx, 0x00000000
    mov r8d, 0x00D0D0D0
    call render_text

    ; 1280x720 Button
    mov rdi, r12
    add rdi, BORDER_WIDTH + 200
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 55
    mov rdx, 80
    mov rcx, 24
    mov r8d, 0x00D0D0D0
    call render_rect
    mov rdi, r12
    add rdi, BORDER_WIDTH + 206
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 60
    mov rdx, szRes1280
    mov ecx, 0x00000000
    mov r8d, 0x00D0D0D0
    call render_text

    ; --- VSync Toggle ---
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    mov rdx, 16
    mov rcx, 16
    mov r8d, 0x00FFFFFF ; White box
    call render_rect

    ; Border
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    mov rdx, 16
    mov rcx, 1
    mov r8d, 0x00000000
    call render_rect ; Top
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90 + 15
    call render_rect ; Bottom
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    mov rdx, 1
    mov rcx, 16
    call render_rect ; Left
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20 + 15
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    call render_rect ; Right

    ; Checkmark if enabled
    cmp byte [vsync_enabled], 1
    jne .no_vsync_check
    mov rdi, r12
    add rdi, BORDER_WIDTH + 24
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 94
    mov rdx, 8
    mov rcx, 8
    mov r8d, 0x00000000
    call render_rect
.no_vsync_check:

    ; Label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 45
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    mov rdx, szSetVSync
    mov ecx, 0x00000000
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; --- FPS Toggle ---
    mov rdi, r12
    add rdi, BORDER_WIDTH + 150
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    mov rdx, 16
    mov rcx, 16
    mov r8d, 0x00FFFFFF
    call render_rect
    
    ; Border (lazy reuse of regs/logic)
    ; ... skipping explicit border drawing for brevity, assume render_rect handles it or it looks OK flat

    ; Checkmark
    cmp byte [fps_show], 1
    jne .no_fps_check
    mov rdi, r12
    add rdi, BORDER_WIDTH + 154
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 94
    mov rdx, 8
    mov rcx, 8
    mov r8d, 0x00000000
    call render_rect
.no_fps_check:

    ; Label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 175
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    mov rdx, szSetFPS
    mov ecx, 0x00000000
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; --- System Info ---
    mov rdi, r12
    add rdi, BORDER_WIDTH + 10
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 130
    mov rdx, szSetMemory
    call render_text
    
    mov rdi, r12
    add rdi, BORDER_WIDTH + 20
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 150
    mov rdx, szSetMem512
    call render_text
    
    pop rdi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Click Handler
app_settings_click:
    push rbx
    push r12
    push r13
    
    ; RSI = Client X
    ; RDX = Client Y
    
    ; Check Resolution Buttons (Y approx 55 to 79)
    cmp rdx, 55
    jl .chk_vsync
    cmp rdx, 79
    jg .chk_vsync
    
    ; 800x600: X 20-100
    cmp rsi, 20
    jl .chk_vsync
    cmp rsi, 100
    jle .set_res_800
    
    ; 1024x768: X 110-190
    cmp rsi, 110
    jl .chk_vsync
    cmp rsi, 190
    jle .set_res_1024
    
    ; 1280x720: X 200-280
    cmp rsi, 200
    jl .chk_vsync
    cmp rsi, 280
    jle .set_res_1280
    
    jmp .done_clk

.set_res_800:
    mov edi, 800
    mov esi, 600
    mov edx, 32
    call display_set_mode
    test eax, eax
    jnz .done_clk
    call cursor_init
    jmp .done_clk

.set_res_1024:
    mov edi, 1024
    mov esi, 768
    mov edx, 32
    call display_set_mode
    test eax, eax
    jnz .done_clk
    call cursor_init
    jmp .done_clk

.set_res_1280:
    mov edi, 1280
    mov esi, 720
    mov edx, 32
    call display_set_mode
    test eax, eax
    jnz .done_clk
    call cursor_init
    jmp .done_clk

.chk_vsync:
    ; VSync Toggle: Y 90-106, X 20-36
    cmp rdx, 90
    jl .chk_fps
    cmp rdx, 106
    jg .chk_fps
    
    cmp rsi, 20
    jl .chk_fps
    cmp rsi, 36
    jg .chk_fps
    
    xor byte [vsync_enabled], 1
    jmp .done_clk

.chk_fps:
    ; FPS Toggle: Y 90-106, X 150-166
    cmp rdx, 90
    jl .done_clk
    cmp rdx, 106
    jg .done_clk
    
    cmp rsi, 150
    jl .done_clk
    cmp rsi, 166
    jg .done_clk
    
    xor byte [fps_show], 1
    jmp .done_clk

.done_clk:
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================================
; ABOUT APP
; Version info and credits
; ============================================================================

app_about_draw:
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]

    ; OS Icon (blue square)
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 12
    mov edx, 48
    mov ecx, 48
    mov r8d, 0x002255AA
    call render_rect

    ; "N" in the icon
    mov rdi, r12
    add rdi, BORDER_WIDTH + 28
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 28
    mov rdx, szIconN
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, 0x002255AA
    call render_text

    ; Title
    mov rdi, r12
    add rdi, BORDER_WIDTH + 68
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 16
    mov rdx, szAboutName
    mov ecx, 0x00222222
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; Version
    mov rdi, r12
    add rdi, BORDER_WIDTH + 68
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 36
    mov rdx, szAboutVer
    mov ecx, 0x00666666
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; Separator
    mov rdi, r12
    add rdi, BORDER_WIDTH + 4
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 68
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2 + 8
    mov ecx, 1
    mov r8d, 0x00CCCCCC
    call render_rect

    ; Info lines
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 78
    mov rdx, szAboutArch
    mov ecx, 0x00444444
    mov r8d, COLOR_WINDOW_BG
    call render_text

    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 98
    mov rdx, szAboutDesc
    mov ecx, 0x00444444
    mov r8d, COLOR_WINDOW_BG
    call render_text

    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 118
    mov rdx, szAboutCopy
    mov ecx, 0x00888888
    mov r8d, COLOR_WINDOW_BG
    call render_text

    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; Right-click context menu for explorer (called from main event loop)
; RDI=mouseX, RSI=mouseY (screen coords)
; ============================================================================
global app_show_context_menu
app_show_context_menu:
    mov [ctx_menu_x], edi
    mov [ctx_menu_y], esi
    mov byte [ctx_menu_visible], 1
    ret

; ============================================================================
; PROPERTIES WINDOW
; Shows file name, type, and size
; ============================================================================
app_properties_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    mov rcx, [prop_entry_ptr]
    test rcx, rcx
    jz .prop_draw_done

    ; "Name:" label at y+4
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 8
    mov rdx, szPropName
    mov ecx, 0x00555555
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; File name value - format 8.3 name from FAT16 entry
    mov rcx, [prop_entry_ptr]
    push rcx
    mov rdi, fat16_name_buf
    mov rsi, rcx
    call fat16_format_name
    pop rcx

    mov rdi, r12
    add rdi, BORDER_WIDTH + 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 8
    mov rdx, fat16_name_buf
    mov ecx, 0x00000000
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; "Type:" label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 30
    mov rdx, szPropType
    mov ecx, 0x00555555
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; Type value - FAT16: byte 11 bit 0x10 = directory
    mov rcx, [prop_entry_ptr]
    mov al, [rcx + 11]
    test al, 0x10
    jz .prop_is_file
    mov rdx, szPropTypeDir
    jmp .prop_draw_type
.prop_is_file:
    mov rdx, szPropTypeFile
.prop_draw_type:
    mov rdi, r12
    add rdi, BORDER_WIDTH + 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 30
    mov ecx, 0x00000000
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; "Size:" label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 52
    mov rdx, szPropSize
    mov ecx, 0x00555555
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; Size value - FAT16: bytes 28-31 = uint32 file size
    mov rcx, [prop_entry_ptr]
    mov al, [rcx + 11]
    test al, 0x10
    jnz .prop_show_dir_size
    ; Convert size to string
    push rcx
    mov edi, [rcx + 28]
    mov rsi, fat16_size_buf
    call app_format_bytes_size
    pop rcx
    mov rdx, fat16_size_buf
    jmp .prop_show_size
.prop_show_dir_size:
    mov rdx, szPropSizeDir
.prop_show_size:
    mov rdi, r12
    add rdi, BORDER_WIDTH + 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 52
    mov ecx, 0x00000000
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; "Location:" label
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 74
    mov rdx, szPropLoc
    mov ecx, 0x00555555
    mov r8d, COLOR_WINDOW_BG
    call render_text

    ; Location value
    mov rdx, szPathRoot
    mov rdi, r12
    add rdi, BORDER_WIDTH + 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 74
    mov ecx, 0x00000000
    mov r8d, COLOR_WINDOW_BG
    call render_text

.prop_draw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

global ctx_menu_visible

; ============================================================================
; BMP VIEWER
; Opens a BMP file and displays it in a window
; ============================================================================

; BMP file buffer address
BMP_FILE_BUF    equ 0x950000     ; Up to 256KB for BMP files
PAINT_CANVAS_BUF equ 0x990000    ; 120KB for Paint canvas (200x150x4)
PAINT_CANVAS_SIZE equ 30000      ; pixels

app_open_file_in_bmpview:
    push rbx
    push r12
    push r13

    mov r12, rdi             ; dir entry ptr

    ; Read BMP file into memory
    mov rdi, r12
    mov rsi, BMP_FILE_BUF
    mov edx, 262144          ; max 256KB
    call fat16_read_file
    cmp eax, -1
    je .bmp_open_fail
    mov r13d, eax            ; bytes read

    ; Parse BMP header
    ; Check 'BM' signature
    cmp byte [BMP_FILE_BUF], 'B'
    jne .bmp_open_fail
    cmp byte [BMP_FILE_BUF + 1], 'M'
    jne .bmp_open_fail

    ; Get width/height from DIB header (offset 18/22)
    mov eax, [BMP_FILE_BUF + 18]
    mov [bmp_width], eax
    mov eax, [BMP_FILE_BUF + 22]
    mov [bmp_height], eax
    ; Get pixel data offset (offset 10)
    mov eax, [BMP_FILE_BUF + 10]
    mov [bmp_data_offset], eax
    ; Get bits per pixel (offset 28)
    movzx eax, word [BMP_FILE_BUF + 28]
    mov [bmp_bpp], eax

    ; Create viewer window
    mov rdi, fat16_name_buf
    mov rsi, r12
    call fat16_format_name

    mov rdi, fat16_name_buf
    mov rsi, 150
    mov rdx, 100
    ; Window size = image size + borders + titlebar
    mov ecx, [bmp_width]
    add ecx, BORDER_WIDTH * 2
    cmp ecx, 200
    jge .bmp_w_ok
    mov ecx, 200
.bmp_w_ok:
    mov r8d, [bmp_height]
    add r8d, TITLEBAR_HEIGHT + BORDER_WIDTH
    cmp r8d, 100
    jge .bmp_h_ok
    mov r8d, 100
.bmp_h_ok:
    mov r9, app_bmp_draw
    call wm_create_window_ex

.bmp_open_fail:
    pop r13
    pop r12
    pop rbx
    ret

; BMP viewer draw callback
app_bmp_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]    ; window X
    mov r13, [rbx + WIN_OFF_Y]    ; window Y

    ; Get BMP parameters
    mov ecx, [bmp_width]
    mov edx, [bmp_height]
    test ecx, ecx
    jz .bmp_draw_done
    test edx, edx
    jz .bmp_draw_done

    ; Calculate BMP row size (padded to 4 bytes)
    mov eax, [bmp_bpp]
    cmp eax, 24
    jne .bmp_draw_done        ; only support 24bpp for now

    mov eax, ecx
    imul eax, 3               ; bytes per row (24bpp)
    add eax, 3
    and eax, ~3               ; pad to 4 bytes
    mov r14d, eax             ; row stride

    ; BMP is bottom-up, so row 0 is at bottom
    mov r15d, edx             ; height
    dec r15d                  ; start from last row

    ; Source = BMP_FILE_BUF + data_offset
    mov eax, [bmp_data_offset]
    lea r8, [BMP_FILE_BUF + rax]

    ; Get framebuffer address
    mov rax, [bb_addr]         ; backbuffer logic

    ; Draw pixel by pixel
    xor edx, edx              ; dest Y counter (0 = top)
.bmp_row_loop:
    cmp edx, [bmp_height]
    jge .bmp_draw_done

    ; Source row = r15d (counts down from height-1)
    mov eax, r15d
    imul eax, r14d            ; row * stride
    lea rsi, [r8 + rax]      ; source pixel row

    ; Dest pixel Y = window_Y + titlebar + edx
    mov edi, r13d
    add edi, TITLEBAR_HEIGHT
    add edi, edx
    ; Check Y bounds
    cmp edi, SCREEN_HEIGHT
    jge .bmp_draw_done

    imul edi, [scr_pitch]    ; Y * pitch (use variable pitch)

    xor ecx, ecx              ; X counter
.bmp_col_loop:
    cmp ecx, [bmp_width]
    jge .bmp_row_done

    ; Dest pixel X = window_X + border + ecx
    mov ebx, r12d
    add ebx, BORDER_WIDTH
    add ebx, ecx
    cmp ebx, SCREEN_WIDTH
    jge .bmp_row_done

    ; Read BGR from source
    movzx r9d, byte [rsi]      ; B
    movzx r10d, byte [rsi + 1] ; G
    movzx r11d, byte [rsi + 2] ; R
    add rsi, 3

    ; Compose 32-bit pixel: 0x00RRGGBB
    shl r11d, 16
    shl r10d, 8
    or r11d, r10d
    or r11d, r9d

    ; Write to framebuffer
    push rdi
    mov rax, [bb_addr]        ; RELOAD bb_addr (eax clobbered by source calc)
    add rdi, rax
    mov [rdi + rbx * 4], r11d
    pop rdi

    inc ecx
    jmp .bmp_col_loop

.bmp_row_done:
    dec r15d
    inc edx
    jmp .bmp_row_loop

.bmp_draw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; HELPER FUNCTIONS
; ============================================================================

; fat16_format_name - Format FAT16 8.3 name to readable string
; rdi = output buffer (at least 13 bytes)
; rsi = pointer to FAT16 dir entry (32 bytes)
fat16_format_name:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi

    ; Copy filename part (8 bytes), strip trailing spaces
    mov ecx, 8
.fn_copy:
    lodsb
    cmp al, ' '
    je .fn_space
    stosb
    dec ecx
    jnz .fn_copy
    jmp .fn_dot
.fn_space:
    dec ecx
    ; Skip remaining filename chars
.fn_skip:
    test ecx, ecx
    jz .fn_dot
    lodsb
    dec ecx
    jmp .fn_skip

.fn_dot:
    ; Check if extension is blank
    mov al, [rsi]
    cmp al, ' '
    je .fn_noext
    ; Add dot
    mov byte [rdi], '.'
    inc rdi
    ; Copy extension (3 bytes), strip trailing spaces
    mov ecx, 3
.ext_copy:
    lodsb
    cmp al, ' '
    je .ext_done
    stosb
    dec ecx
    jnz .ext_copy
.ext_done:
.fn_noext:
    mov byte [rdi], 0     ; null terminate

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; fat16_format_name_to - Same as fat16_format_name but rdi = destination
; rdi = destination buffer
; rsi = FAT16 dir entry pointer
fat16_format_name_to:
    jmp fat16_format_name   ; same function

; filename_to_83 - Convert user filename ("hello.txt") to FAT16 8.3 format ("HELLO   TXT")
; rdi = input null-terminated string (user typed)
; rsi = output buffer (at least 11 bytes)
; Uppercases, pads with spaces, splits on dot
filename_to_83:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi

    mov rdx, rsi             ; rdx = output buffer

    ; Fill output with 11 spaces
    mov ecx, 11
    mov rsi, rdx
.fill_spaces:
    mov byte [rsi], ' '
    inc rsi
    dec ecx
    jnz .fill_spaces

    ; Copy name part (up to 8 chars before dot)
    mov rsi, rdi             ; rsi = input string
    xor ecx, ecx             ; char count
.name_copy:
    mov al, [rsi]
    test al, al
    jz .name_done
    cmp al, '.'
    je .found_dot
    cmp ecx, 8
    jge .name_skip
    ; Uppercase
    cmp al, 'a'
    jl .name_store
    cmp al, 'z'
    jg .name_store
    sub al, 32
.name_store:
    mov [rdx + rcx], al
    inc ecx
.name_skip:
    inc rsi
    jmp .name_copy

.found_dot:
    inc rsi                   ; skip the dot
    ; Copy extension (up to 3 chars)
    xor ecx, ecx
.ext_copy83:
    mov al, [rsi]
    test al, al
    jz .name_done
    cmp ecx, 3
    jge .name_done
    ; Uppercase
    cmp al, 'a'
    jl .ext_store
    cmp al, 'z'
    jg .ext_store
    sub al, 32
.ext_store:
    mov [rdx + 8 + rcx], al
    inc ecx
    inc rsi
    jmp .ext_copy83

.name_done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; app_format_bytes_size - Convert uint32 to decimal string with " B" suffix
; edi = value
; rsi = output buffer (at least 16 bytes)
app_format_bytes_size:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    mov eax, edi
    mov rdi, rsi          ; output buffer

    ; Handle zero
    test eax, eax
    jnz .u2s_nonzero
    mov byte [rdi], '0'
    mov byte [rdi + 1], ' '
    mov byte [rdi + 2], 'B'
    mov byte [rdi + 3], 0
    jmp .u2s_done

.u2s_nonzero:
    ; Convert to digits on stack (reverse order)
    xor ecx, ecx          ; digit count
    mov ebx, 10
.u2s_div:
    xor edx, edx
    div ebx
    add dl, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz .u2s_div

    ; Pop digits into buffer
.u2s_pop:
    pop rax
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .u2s_pop

    ; Add " B" suffix
    mov byte [rdi], ' '
    mov byte [rdi + 1], 'B'
    mov byte [rdi + 2], 0

.u2s_done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; PAINTER APP
; ============================================================================

global app_paint_draw
global app_paint_click

app_paint_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    ; 1. Draw Toolbar background (top 44px)
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov rcx, 44
    mov r8d, 0x00D0D0D0
    call render_rect

    ; --- Color Palette ---
    ; X: 10 to 202 (8 * 24 = 192px width)
    xor r10d, r10d  ; index
.palette_loop:
    cmp r10d, 8
    jge .palette_done
    
    mov rdi, r12
    add rdi, BORDER_WIDTH + 10
    imul eax, r10d, 24
    add edi, eax
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 10
    mov rdx, 20
    mov rcx, 20
    
    lea rax, [paint_palette_colors]
    mov r8d, [rax + r10*4]
    call render_rect
    
    ; Selection Indicator
    cmp r8d, [paint_color]
    jne .pal_next
    mov rdi, r12
    add rdi, BORDER_WIDTH + 10 + 8
    imul eax, r10d, 24
    add edi, eax
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 34
    mov rdx, 4
    mov rcx, 4
    mov r8d, 0x00000000
    call render_rect
    
.pal_next:
    inc r10d
    jmp .palette_loop
.palette_done:

    ; --- Buttons (Right aligned) ---
    ; Clear Button: X = Width - 110, Y = 10
    mov rdi, r12
    add rdi, r14
    sub rdi, 110
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 10
    mov rdx, 45
    mov rcx, 24
    mov r8d, 0x00A0A0A0
    call render_rect
    
    mov rdi, r12
    add rdi, r14
    sub rdi, 105
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 15
    mov rdx, szEditClear
    mov ecx, 0x00000000
    mov r8d, 0x00A0A0A0
    call render_text

    ; Save Button: X = Width - 60, Y = 10
    mov rdi, r12
    add rdi, r14
    sub rdi, 55
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 10
    mov rdx, 45
    mov rcx, 24
    mov r8d, 0x00A0A0A0
    call render_rect
    
    mov rdi, r12
    add rdi, r14
    sub rdi, 50
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 15
    mov rdx, szFileSave
    mov ecx, 0x00000000
    mov r8d, 0x00A0A0A0
    call render_text

    ; --- Canvas Border (Dark Gray) ---
    ; Canvas centered at X = (W - 200)/2 = (340-200)/2 = 70
    ; Y = 50
    mov rdi, r12
    add rdi, BORDER_WIDTH + 69
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 49
    mov rdx, 202
    mov rcx, 152
    mov r8d, 0x00555555
    call render_rect

    ; --- Draw Canvas from Buffer (Clipped) ---
    mov r10d, r12d
    add r10d, BORDER_WIDTH + 70  ; Canvas Screen X
    mov r11d, r13d
    add r11d, TITLEBAR_HEIGHT + 50 ; Canvas Screen Y
    
    xor ecx, ecx ; y line counter (0 to 149)
.canvas_loop_y:
    cmp ecx, 150
    jge .canvas_done
    
    push rcx
    
    ; Calculate Screen Y for this line
    mov eax, r11d
    add eax, ecx
    
    ; Clip Y
    cmp eax, 0
    jl .skip_row_pop
    cmp eax, SCREEN_HEIGHT
    jge .skip_row_pop
    
    ; Prepare X clipping
    mov r8d, r10d         ; Screen X
    mov r9d, 200          ; Width
    xor ebx, ebx          ; Source X offset (pixels)
    
    ; Clip Left
    cmp r8d, 0
    jge .chk_right
    ; X < 0
    mov ebx, r8d
    neg ebx               ; ebx = -X (positive) = pixels to skip
    sub r9d, ebx          ; Width -= skip
    mov r8d, 0            ; Clip Screen X to 0
.chk_right:
    ; Clip Right
    mov eax, r8d
    add eax, r9d
    sub eax, SCREEN_WIDTH
    jle .calc_ptrs
    ; Over > 0
    sub r9d, eax          ; Width -= Over
.calc_ptrs:
    cmp r9d, 0
    jle .skip_row_pop

    ; Valid row, copy r9d pixels
    
    ; Source: PAINT_CANVAS_BUF + (y * 200 + SrcOffset) * 4
    mov eax, [rsp]        ; y
    imul eax, 200
    add eax, ebx          ; + SrcOffset
    shl eax, 2            ; * 4
    add eax, PAINT_CANVAS_BUF
    mov rsi, rax
    
    ; Dest: bb_addr + (ScreenY * Pitch) + (ScreenX * 4)
    ; ScreenY is (r11d + [rsp])
    mov eax, r11d
    add eax, [rsp]
    imul eax, SCREEN_PITCH
    
    mov edx, r8d          ; Screen X
    shl edx, 2
    add eax, edx
    add rax, [bb_addr]
    mov rdi, rax
    
    ; Copy
    mov ecx, r9d
    rep movsd
    
.skip_row_pop:
    pop rcx
    inc ecx
    jmp .canvas_loop_y
.canvas_done:

    ; --- Save As Dialog Overlay ---
    cmp byte [paint_save_active], 1
    jne .paint_no_save
    
    ; Draw dialog background (centered)
    ; Window is 340x240. Dialog 220x80.
    ; X = 60, Y = 80
    mov rdi, r12
    add rdi, 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 80
    mov rdx, 220
    mov rcx, 80
    mov r8d, 0x00E0E0E0
    call render_rect
    
    call render_rect
    
    ; Border (using 4 rects)
    ; Top
    mov rdi, r12
    add rdi, 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 80
    mov rdx, 220
    mov rcx, 1
    mov r8d, 0x00404040
    call render_rect
    ; Bottom
    mov rdi, r12
    add rdi, 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 159
    mov rdx, 220
    mov rcx, 1
    mov r8d, 0x00404040
    call render_rect
    ; Left
    mov rdi, r12
    add rdi, 60
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 80
    mov rdx, 1
    mov rcx, 80
    mov r8d, 0x00404040
    call render_rect
    ; Right
    mov rdi, r12
    add rdi, 279
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 80
    mov rdx, 1
    mov rcx, 80
    mov r8d, 0x00404040
    call render_rect
    
    ; Text "Save As:"
    mov rdi, r12
    add rdi, 70
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 90
    mov rdx, szSaveAsTitle ; Reuse Notepad string "Save As"
    mov ecx, 0x00000000
    mov r8d, 0x00E0E0E0
    call render_text
    
    ; Filename input box
    mov rdi, r12
    add rdi, 70
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 110
    mov rdx, 140
    mov rcx, 18
    mov r8d, 0x00FFFFFF
    call render_rect
    
    ; Typed filename
    mov rdi, r12
    add rdi, 74
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 112
    lea rdx, [paint_save_buf]
    mov ecx, 0x00000000
    mov r8d, 0x00FFFFFF
    call render_text
    
    ; Cursor "_"
    mov eax, [paint_save_len]
    imul eax, 8 ; font width
    add edi, eax
    mov rdx, szCursor
    call render_text
    
    ; Ext ".BMP"
    mov rdi, r12
    add rdi, 215
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 112
    mov rdx, szExtBmp
    mov ecx, 0x00000000
    mov r8d, 0x00E0E0E0
    call render_text
    
    ; Hint "Enter=Save"
    mov rdi, r12
    add rdi, 70
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 135
    mov rdx, szSaveAsHint
    mov ecx, 0x00555555
    mov r8d, 0x00E0E0E0
    call render_text

.paint_no_save:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Click Handler
; RSI = Client X, RDX = Client Y
app_paint_click:
    push rbx
    push r12
    push r13
    
    mov rbx, rdi
    mov r12, [rbx + WIN_OFF_W] ; Window width
    
    ; Check Canvas Click
    ; Canvas is at X=70, Y=50, W=200, H=150
    ; Client Y coords (relative to titlebar bottom)
    
    cmp rdx, 50
    jl .check_toolbar
    
    ; Canvas Area
    sub rsi, 70
    sub rdx, 50
    
    cmp rsi, 0
    jl .done_click
    cmp rsi, 200
    jge .done_click
    cmp rdx, 0
    jl .done_click
    cmp rdx, 150
    jge .done_click
    
    ; Draw Point
    mov eax, edx
    imul eax, 200
    add eax, esi
    shl eax, 2
    add eax, PAINT_CANVAS_BUF
    
    mov ecx, [paint_color]
    mov [eax], ecx
    
    ; 2x2 Brush (simple bounds check)
    cmp rsi, 199
    jge .done_click
    cmp rdx, 149
    jge .done_click
    mov [eax + 4], ecx
    mov [eax + 800], ecx
    mov [eax + 804], ecx
    jmp .done_click

.check_toolbar:
    ; Palette: X=10..202, Y=10..30
    cmp rdx, 10
    jl .done_click
    cmp rdx, 30
    jg .done_click
    
    cmp rsi, 10
    jl .done_click
    cmp rsi, 202
    jg .check_tb_buttons
    
    ; Palette click
    sub rsi, 10
    mov rax, rsi
    xor rdx, rdx
    mov rcx, 24
    div rcx
    ; RAX = index (0..7)
    cmp rax, 8
    jge .done_click
    
    lea rcx, [paint_palette_colors]
    mov edx, [rcx + rax*4]
    mov [paint_color], edx
    jmp .done_click

.check_tb_buttons:
    ; Clear: Width-110 to Width-65
    ; Save: Width-55 to Width-10
    
    ; Calc offsets from right
    mov rax, r12
    sub rax, rsi   ; rax = distance from right edge
    
    ; Save button is 10..55 px from right (padding 10 + width 45)
    ; Clear button is 65..110 px from right
    
    cmp rax, 10
    jl .done_click
    
    cmp rax, 55
    jle .click_save
    
    cmp rax, 65
    jl .done_click
    
    cmp rax, 110
    jle .click_clear
    
    jmp .done_click

.click_save:
    ; Toggle save mode
    mov byte [paint_save_active], 1
    mov byte [paint_save_buf], 0
    mov dword [paint_save_len], 0
    jmp .done_click

.click_clear:
    mov edi, PAINT_CANVAS_BUF
    mov ecx, 30000
    mov eax, 0xFFFFFFFF
    rep stosd
    
.done_click:
    pop r13
    pop r12
    pop rbx
    ret

; Key handler for Paint (Save As)
app_paint_key:
    cmp byte [paint_save_active], 1
    jne .pk_ret
    
    push rbx
    push rcx
    push rdx
    
    ; Extract ASCII
    mov eax, esi
    shr eax, 8
    and eax, 0xFF
    test eax, eax
    jz .pk_done
    
    ; Esc = Cancel
    cmp al, 27
    je .pk_cancel
    
    ; Enter = Save
    cmp al, 13
    je .pk_save
    
    ; Backspace
    cmp al, 8
    je .pk_backspace
    
    ; Printable: A-Z, 0-9
    ; ToUpper
    cmp al, 'a'
    jl .pk_chk_num
    cmp al, 'z'
    jg .pk_chk_num
    sub al, 32
.pk_chk_num:
    ; Valid chars?
    cmp al, ' '
    jl .pk_done
    cmp al, '~'
    jg .pk_done
    
    ; Append to buffer (max 8 chars)
    mov ecx, [paint_save_len]
    cmp ecx, 8
    jge .pk_done
    lea rbx, [paint_save_buf]
    mov [rbx + rcx], al
    inc ecx
    mov byte [rbx + rcx], 0
    mov [paint_save_len], ecx
    jmp .pk_done

.pk_backspace:
    mov ecx, [paint_save_len]
    test ecx, ecx
    jz .pk_done
    dec ecx
    lea rbx, [paint_save_buf]
    mov byte [rbx + rcx], 0
    mov [paint_save_len], ecx
    jmp .pk_done

.pk_cancel:
    mov byte [paint_save_active], 0
    jmp .pk_done

.pk_save:
    ; Format 8.3 filename
    ; Filename is in paint_save_buf (up to 8 chars)
    ; Extension is BMP
    lea rdi, [paint_filename_83]
    lea rsi, [paint_save_buf]
    ; Fill with spaces first
    push rdi
    mov ecx, 11
    mov al, ' '
    rep stosb
    pop rdi
    
    ; Copy name
    mov ecx, [paint_save_len]
    rep movsb
    
    ; Set extension at offset 8
    lea rdi, [paint_filename_83 + 8]
    mov byte [rdi], 'B'
    mov byte [rdi+1], 'M'
    mov byte [rdi+2], 'P'
    
    call app_paint_save
    mov byte [paint_save_active], 0
    jmp .pk_done

.pk_done:
    pop rdx
    pop rcx
    pop rbx
.pk_ret:
    ret

app_paint_save:
    mov rdi, 0x930000
    mov byte [rdi], 'B'
    mov byte [rdi+1], 'M'
    mov dword [rdi+2], 90054
    mov dword [rdi+6], 0
    mov dword [rdi+10], 54
    mov dword [rdi+14], 40
    mov dword [rdi+18], 200
    mov dword [rdi+22], 150
    mov word [rdi+26], 1
    mov word [rdi+28], 24
    mov dword [rdi+30], 0
    mov dword [rdi+34], 90000
    mov dword [rdi+38], 0
    mov dword [rdi+42], 0
    mov dword [rdi+46], 0
    mov dword [rdi+50], 0
    
    mov rsi, PAINT_CANVAS_BUF
    mov rbx, 0x930000 + 54
    mov r8d, 149
.save_row_loop:
    cmp r8d, 0
    jl .save_done
    mov eax, r8d
    imul eax, 200 * 4
    add eax, PAINT_CANVAS_BUF
    mov r9, rax
    xor ecx, ecx
.save_col_loop:
    cmp ecx, 200
    jge .save_row_next
    mov eax, [r9 + rcx*4]
    mov byte [rbx], al
    shr eax, 8
    mov byte [rbx+1], al
    shr eax, 8
    mov byte [rbx+2], al
    add rbx, 3
    inc ecx
    jmp .save_col_loop
.save_row_next:
    dec r8d
    jmp .save_row_loop
.save_done:
    lea rdi, [paint_filename_83]
    mov rsi, 0x930000
    mov edx, 90054
    call fat16_write_file
    ret

; ============================================================================
; DATA SECTION
; ============================================================================
section .data

; --- Window titles ---
szExplorerTitle db "File Explorer", 0
szTermTitle     db "Terminal", 0
szNotepadTitle  db "Notepad", 0
szSettingsTitle db "Settings", 0
szAboutTitle    db "About NexusOS", 0

; --- Explorer strings ---
szPathRoot      db "C:\", 0
szPathDocs      db "C:\Documents", 0
szPathPics      db "C:\Pictures", 0
szPathSys       db "C:\System", 0
szColName       db "Name", 0
szColSize       db "Size", 0
szDirLabel      db "<DIR>", 0
szStatusReady   db "Ready", 0

; --- Context menu strings ---
szCtxOpen       db "Open", 0
szCtxRename     db "Rename", 0
szCtxNewFolder  db "New Folder", 0
szCtxProperties db "Properties", 0
szRenameLabel   db "Rename:", 0
szNewFolderLabel db "New Folder:", 0
szNewFolderDone db "Folder Created!", 0

; --- Properties window strings ---
szPropTitle     db "Properties", 0
szPropName      db "Name:", 0
szPropType      db "Type:", 0
szPropSize      db "Size:", 0
szPropLoc       db "Path:", 0
szPropTypeFile  db "File", 0
szPropTypeDir   db "Folder", 0
szPropSizeDir   db "--", 0

prop_entry_ptr  dq 0            ; pointer to VFS entry being viewed

; --- Virtual Filesystem ---
; Each entry: 24 bytes name (null-padded) + 1 byte type (0=dir,1=file) + 7 bytes size string
; VFS_ENTRY_SIZE = 32

; Root directory (6 entries)
vfs_root:
    db "Documents",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; 24 bytes name
    db 0                                              ; type=dir
    db 0,0,0,0,0,0,0                                 ; size (unused for dir)
    db "Pictures",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; 24 bytes
    db 0
    db 0,0,0,0,0,0,0
    db "System",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ; 24 bytes
    db 0
    db 0,0,0,0,0,0,0
    db "readme.txt",0,0,0,0,0,0,0,0,0,0,0,0,0,0     ; 24 bytes
    db 1                                              ; type=file
    db "1.2 KB",0                                     ; 7 bytes size
    db "config.sys",0,0,0,0,0,0,0,0,0,0,0,0,0,0     ; 24 bytes
    db 1
    db "256 B",0,0                                    ; 7 bytes
    db "nexus.log",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0    ; 24 bytes
    db 1
    db "4.8 KB",0                                     ; 7 bytes

; Documents subdirectory (4 entries)
vfs_docs:
    db "..",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0  ; 24 bytes - go up
    db 0
    db 0,0,0,0,0,0,0
    db "notes.txt",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0    ; 24 bytes
    db 1
    db "3.1 KB",0
    db "todo.txt",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; 24 bytes
    db 1
    db "512 B",0,0
    db "report.doc",0,0,0,0,0,0,0,0,0,0,0,0,0,0     ; 24 bytes
    db 1
    db "12 KB",0,0

; Pictures subdirectory (3 entries)
vfs_pics:
    db "..",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0
    db 0,0,0,0,0,0,0
    db "wallpaper.bmp",0,0,0,0,0,0,0,0,0,0,0         ; 24 bytes
    db 1
    db "2.3 MB",0
    db "photo.bmp",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0    ; 24 bytes
    db 1
    db "1.1 MB",0

; System subdirectory (4 entries)
vfs_sys:
    db "..",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0
    db 0,0,0,0,0,0,0
    db "kernel.bin",0,0,0,0,0,0,0,0,0,0,0,0,0,0     ; 24 bytes
    db 1
    db "64 KB",0,0
    db "boot.cfg",0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; 24 bytes
    db 1
    db "128 B",0,0
    db "drivers.sys",0,0,0,0,0,0,0,0,0,0,0,0,0      ; 24 bytes
    db 1
    db "32 KB",0,0

; --- Explorer state ---
explorer_sel    dd 0
explorer_dir    dd 0
explorer_cur_entry dq 0          ; temp: current dir entry pointer during draw
explorer_cur_idx   dd 0          ; temp: current draw index

; File open state
np_open_entry   dq 0             ; FAT16 dir entry of last opened file

; Context menu state
ctx_menu_visible db 0
ctx_menu_x      dd 0
ctx_menu_y      dd 0

; Rename mode state
exp_rename_active  db 0
exp_rename_cursor  dd 0

; New folder mode state
exp_newfolder_active  db 0
exp_newfolder_cursor  dd 0
exp_newfolder_done_msg db 0

; --- Terminal strings ---
szTermWelcome   db "NexusOS Terminal v3.0", 0
szTermVer       db "Type 'help' for commands", 0
szTermHelpHint  db "----------------------------", 0
szTermPrompt    db "C:\> ", 0
szCursor        db "_", 0
szCmdUnknown    db "  Unknown command. Type help.", 0
szCmdHelpOut    db "  help ver dir cls debug restart usb mouse touchpad", 0
szCmdVerOut     db "  NexusOS v3.0 (x86-64)", 0
szCmdDirOut     db "  Documents  Pictures  System", 0

; Terminal state
term_cursor     dd 0
term_hist_count dd 0
term_draw_lines dd 0
term_hist_ptrs: times TERM_MAX_HIST dq 0

; --- Notepad strings ---
szNoteMenuFile  db "File", 0
szNoteMenuEdit  db "Edit", 0
szNotePlaceholder db "Start typing...", 0
szFileNew       db "New", 0
szFileSave      db "Save", 0
szFileClose     db "Close", 0
szEditSelAll    db "Select All", 0
szEditClear     db "Clear All", 0
szFileContent   db "Sample file content.", 0
szSaveAsTitle   db "Save As", 0
szSaveAsFilename db "Filename:", 0
szSaveAsHint    db "Enter=Save  Esc=Cancel", 0

; Notepad state
np_cursor_row   dd 0
np_cursor_col   dd 0
np_num_lines    dd 1
np_scroll_top   dd 0
np_menu_open    db 0            ; 0=closed, 1=File, 2=Edit
np_has_saved    db 0            ; 1 if file has been saved
np_save_done_msg db 0           ; 1 = show "Saved!" overlay
np_save_dialog  db 0            ; 1 = save-as dialog is showing
np_saveas_cursor dd 0
np_saved_num_lines dd 0
np_save_total_bytes dd 0

; BMP viewer state
bmp_width       dd 0
bmp_height      dd 0
bmp_data_offset dd 0
bmp_bpp         dd 0
szSavedMsg      db "Saved!", 0

; --- Settings strings ---
szSetDisplay    db "Display", 0
szSetRes        db "Resolution:", 0
szSetBpp        db "Color Depth: 32-bit", 0
szSetMemory     db "Memory", 0
szSetMem512     db "Total RAM: 512 MB", 0
szSetKernel     db "Kernel", 0
szSetArch       db "Architecture: x86-64", 0
szSetBoot       db "Boot Mode: BIOS (Legacy)", 0
szSetVSync      db "VSync", 0
szSetFPS        db "Show FPS", 0
szRes800        db "800x600", 0
szRes1024       db "1024x768", 0
szRes1280       db "1280x720", 0
szRes1920       db "1920x1080", 0

extern vsync_enabled
extern fps_show
extern display_set_mode
extern cursor_init
extern scr_width
extern scr_height


; --- About strings ---
szIconN         db "N", 0
szAboutName     db "NexusOS", 0
szAboutVer      db "Version 3.0", 0
szAboutArch     db "x86-64 Assembly Kernel", 0
szAboutDesc     db "A graphical desktop OS", 0
szAboutCopy     db "(c) 2026 NexusOS Project", 0

; Paint strings
szPaintTitle db "Paint", 0
paint_filename_83 db "PAINT   BMP"
paint_palette_colors:
    dd 0xFF000000 ; Black
    dd 0xFFFFFFFF ; White
    dd 0xFFFF0000 ; Red
    dd 0xFF00FF00 ; Green
    dd 0xFF0000FF ; Blue
    dd 0xFFFFFF00 ; Yellow
    dd 0xFF00FFFF ; Cyan
    dd 0xFFFF00FF ; Magenta

; Paint state
paint_save_active db 0
paint_save_buf times 16 db 0
paint_save_len dd 0
szExtBmp db ".BMP", 0
paint_color dd 0xFF000000
paint_brush_size dd 2

; Terminal command strings
szCmdHelp db "help", 0
szCmdVer  db "ver", 0
szCmdCls  db "cls", 0
szCmdDir  db "dir", 0
szCmdTime db "time", 0
szCmdEcho db "echo", 0
szCmdLs   db "ls", 0
szCmdClear db "clear", 0
szCmdExit db "exit", 0
szCmdPwd  db "pwd", 0
szCmdDate db "date", 0
szCmdDebug db "debug", 0
szCmdXDebug db "xdebug", 0
szCmdRestart db "restart", 0
szCmdReboot db "reboot", 0
szCmdUsb db "usb", 0
szCmdMouse db "mouse", 0
szCmdTouchpad db "touchpad", 0
szCmdIdebug db "idebug", 0

section .bss
term_debug_buf: resb 256
term_input:     resb 64
term_echo_buf:  resb 128
notepad_buf:    resb NP_BUF_SIZE
np_line_len:    resd NP_MAX_LINES
np_saved_content: resb NP_BUF_SIZE
np_saved_line_len: resd NP_MAX_LINES
fat16_name_buf: resb 16
fat16_size_buf: resb 20
exp_rename_buf: resb 24
exp_newfolder_buf: resb 24
np_saveas_buf: resb 24
np_saveas_83:  resb 12
