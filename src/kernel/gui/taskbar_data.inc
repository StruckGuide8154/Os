
section .data
szStart        db "START", 0
szTime         db "12:00", 0
szTbClose      db "X", 0
szNoBat        db "[NO BAT]", 0
szAC           db "AC", 0
szMenuExplorer db "File Explorer", 0
szMenuTerm     db "Terminal", 0
szMenuNotepad  db "Notepad", 0
szMenuSettings db "Settings", 0
szMenuPaint    db "Paint", 0
szMenuTaskMgr  db "Task Manager", 0
szMenuPing     db "Networking", 0
szMenuMedia    db "Media Player", 0
szMenuAbout    db "About Grit", 0

; ============================================================================
; Start menu entry table - single source of truth for the menu.
; To add a row: append one MENU_ENTRY line. Everything else (item count,
; menu height, draw loop, click hit-testing, app dispatch) updates automatically.
;
; MENU_ENTRY <icon ptr>, <label ptr>, <app id>, <flags>
;   flags = 0, MENU_FLAG_SEP_ABOVE, MENU_FLAG_DIM, or a bitwise OR
; ============================================================================
%macro MENU_ENTRY 4
    dq %1
    dq %2
    db %3
    db %4
    times 6 db 0
%endmacro

menu_entries:
    MENU_ENTRY nx_icon_explorer_16, szMenuExplorer, 2,  0
    MENU_ENTRY nx_icon_terminal_16, szMenuTerm,     3,  0
    MENU_ENTRY nx_icon_notepad_16,  szMenuNotepad,  4,  0
    MENU_ENTRY nx_icon_settings_16, szMenuSettings, 5,  0
    MENU_ENTRY nx_icon_paint_16,    szMenuPaint,    6,  0
    MENU_ENTRY nx_icon_taskmgr_16,  szMenuTaskMgr,  9,  0
    MENU_ENTRY nx_icon_terminal_16, szMenuPing,     10, 0
    MENU_ENTRY nx_icon_paint_16,    szMenuMedia,    11, 0
    MENU_ENTRY nx_icon_about_16,    szMenuAbout,    7,  (MENU_FLAG_SEP_ABOVE | MENU_FLAG_DIM)
menu_entries_end:

global tb_start_menu_open
tb_start_menu_open db 0

; Exported so display_recompute_layout can anchor the menu to the taskbar
; using the correct height for the current entry count.
global tb_start_menu_h
tb_start_menu_h dd START_MENU_H

; Start menu submenu state
global sm_submenu_open
sm_submenu_open db 0
sm_submenu_app  db 0          ; app ID being right-clicked
sm_submenu_x    dd 0
sm_submenu_y    dd 0
sm_prev_mouseX   dq -1
sm_prev_mouseY   dq -1

section .text
szSubAdd    db "Add to Desktop", 0
szSubRemove db "Remove from Desktop", 0
bat_pct_str times 8 db 0      ; "100%" + null, with room
