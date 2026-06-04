; All per-instance app state must live in .text (between app_blob_start and
; app_blob_end) so that slot-relative addressing `slot_base + (sym - app_blob_start)`
; produces an offset inside the 1 MB slot. Symbols left in .data end up past
; app_blob_end and every slot-relative access points to garbage.
section .text

; ----------------------------------------------------------------------------
; Named paint palette color constants (ARGB 0xAARRGGBB, opaque alpha 0xFF).
; Values copied verbatim from the original inline literals.
; ----------------------------------------------------------------------------
STATE_PAL_BLACK   equ 0xFF000000   ; palette slot 0 + default paint color (black)
STATE_PAL_WHITE   equ 0xFFFFFFFF   ; palette slot 1 (white)
STATE_PAL_RED     equ 0xFFFF0000   ; palette slot 2 (red)
STATE_PAL_GREEN   equ 0xFF00FF00   ; palette slot 3 (green)
STATE_PAL_BLUE    equ 0xFF0000FF   ; palette slot 4 (blue)
STATE_PAL_YELLOW  equ 0xFFFFFF00   ; palette slot 5 (yellow)
STATE_PAL_CYAN    equ 0xFF00FFFF   ; palette slot 6 (cyan)
STATE_PAL_MAGENTA equ 0xFFFF00FF   ; palette slot 7 (magenta)

; --- Window titles ---
szExplorerTitle db "File Explorer", 0
szTermTitle     db "Terminal", 0
szNotepadTitle  db "Notepad", 0
szSettingsTitle db "Settings", 0
szAboutTitle    db "About NexusOS", 0
szTaskMgrTitle  db "Task Manager", 0
szPingTitle     db "Networking", 0
szMediaTitle    db "Media Player", 0

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
exp_prop_visible db 0           ; 1 = Properties overlay shown inside Explorer window

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
app_open_cmd_buf   times APP_SLOT_PARAM_SZ db 0
app_open_param_buf times APP_SLOT_PARAM_SZ db 0
app_open_comp_buf  times 64 db 0
app_open_83_buf    times 11 db 0
szAppNameExplorer db "explorer", 0
szAppNameTerminal db "terminal", 0
szAppNameNotepad  db "notepad", 0
szAppNameSettings db "settings", 0
szAppNamePaint    db "paint", 0
szAppNameAbout    db "about", 0
szAppNameSecurity db "security", 0
szAppNameSecurityProbe db "security_probe", 0
szAppNamePing     db "ping", 0
szAppNameMedia    db "media", 0
szAppNameRoot     db "root", 0

; Context menu state (legacy explorer.inc — retained for back-compat).
ctx_menu_visible db 0
ctx_menu_x      dd 0
ctx_menu_y      dd 0

; Explorer context-menu state used by the NexusHL explorer.
; exp_ctx_x / exp_ctx_y are client-area coordinates relative to the explorer
; window's client origin (not absolute screen coords like ctx_menu_x/y).
exp_ctx_visible db 0
exp_ctx_x       dd 0
exp_ctx_y       dd 0

; Rename mode state
exp_rename_active  db 0
exp_rename_cursor  dd 0

; New folder mode state
exp_newfolder_active  db 0
exp_newfolder_cursor  dd 0
exp_newfolder_done_msg db 0
term_ls_buf      times 512 db 0
term_debug_buf   times 1024 db 0
term_echo_buf    times 128 db 0

; --- Terminal strings ---
szTermWelcome   db "NexusOS Terminal v3.0", 0
szTermVer       db "Type 'help' for commands", 0
szTermHelpHint  db "----------------------------", 0
szTermPrompt    db "C:\> ", 0
szCursor        db "_", 0
szCmdUnknown    db "  Unknown command. Type help.", 0
szCmdHelpOut    db "  help cd dir ver cls debug restart exit", 0
szCmdVerOut     db "  NexusOS v3.0 (x86-64)", 0
szCmdDirOut     db "  Documents  Pictures  System", 0
szCmdCdErr      db "  Directory not found.", 0
szEmptyDir      db "(empty)", 0
szCmdCd         db "cd ", 0
szCmdDir        db "dir", 0
szCmdLs         db "ls", 0
szPathSub       db "C:\...", 0
szBackBtn       db "[Up]", 0

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
np_saveloc_cursor dd 0
np_save_field dd 0              ; 0 = filename, 1 = location
np_saved_num_lines dd 0
np_save_total_bytes dd 0

; BMP viewer state
bmp_width       dd 0
bmp_height      dd 0
bmp_data_offset dd 0
bmp_bpp         dd 0
szSavedMsg      db "Saved!", 0
szL3DrawOk      db "L3 draw ok", 0
szL3ClickOk     db "L3 click ok", 0
szL3KeyOk       db "L3 key ok", 0
szL3T0          db "L3T0", 0
szL3T4          db "L3T4", 0
szL3T5          db "L3T5", 0
szL3T6          db "L3T6", 0
szL3T8          db "L3T8", 0
szL3T11         db "L3T11", 0
szL3T13         db "L3T13", 0
szL3T14         db "L3T14", 0
szL3T7          db "L3T7", 0
szL3T9          db "L3T9", 0
szL3T12         db "L3T12", 0
szL3T15         db "L3T15", 0
szL3T16         db "L3T16", 0
szL3T17         db "L3T17", 0
szL3WndTitle    db "L3TEST", 0
szL3Tmp83       db "L3TEST  TXT"
szL3TmpData     db "L3OK"

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
    dd STATE_PAL_BLACK   ; Black
    dd STATE_PAL_WHITE   ; White
    dd STATE_PAL_RED     ; Red
    dd STATE_PAL_GREEN   ; Green
    dd STATE_PAL_BLUE    ; Blue
    dd STATE_PAL_YELLOW  ; Yellow
    dd STATE_PAL_CYAN    ; Cyan
    dd STATE_PAL_MAGENTA ; Magenta

; Paint state
paint_save_active db 0
paint_save_buf times 16 db 0
paint_save_len dd 0
szExtBmp db ".BMP", 0
paint_color dd STATE_PAL_BLACK
paint_brush_size dd 2

; Terminal command strings
szCmdHelp db "help", 0
szCmdVer  db "ver", 0
szCmdCls  db "cls", 0
szCmdTime db "time", 0
szCmdEcho db "echo", 0
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

align 8
term_input:        times 64 db 0
notepad_buf:       times NP_BUF_SIZE db 0
np_line_len:       times (NP_MAX_LINES*4) db 0
np_saved_content:  times NP_BUF_SIZE db 0
np_saved_line_len: times (NP_MAX_LINES*4) db 0
fat16_name_buf:    times 16 db 0
fat16_size_buf:    times 20 db 0
exp_rename_buf:    times 24 db 0
exp_newfolder_buf: times 24 db 0
np_saveas_buf:     times 24 db 0
np_saveas_83:      times 12 db 0
np_saveloc_buf:    times 24 db 0
np_saveloc_83:     times 12 db 0
