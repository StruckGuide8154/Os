%ifndef GRIT_WINDOW_INC
%define GRIT_WINDOW_INC

; ============================================================================
; Grit v3.0 - User Window/App Constants
; Shared constants for built-in apps and future external user apps.
; ============================================================================

WIN_OFF_X       equ 8
WIN_OFF_Y       equ 16
WIN_OFF_W       equ 24
WIN_OFF_H       equ 32
WIN_OFF_FLAGS   equ 40
WIN_OFF_DRAWFN  equ 112
WIN_OFF_KEYFN   equ 120
WIN_OFF_CLICKFN equ 128
WIN_OFF_APPDATA equ 136
; Optional drag callback: fn(win_ptr, client_x, client_y). Fired by the WM
; while the left mouse button is held after an initial press inside the
; window's client area, even if the cursor leaves the window's bounds. Same
; calling convention as click_fn. Zero (default) means "no drag handler".
WIN_OFF_DRAGFN   equ 144
; Optional right-click callback: fn(win_ptr, client_x, client_y). Fired once
; on right-button-down in the window's client area. Apps use it for context
; menus or any other secondary action.
WIN_OFF_RCLICKFN equ 152

APP_EXPLORER    equ 2
APP_TERMINAL    equ 3
APP_NOTEPAD     equ 4
APP_SETTINGS    equ 5
APP_PAINT       equ 6
APP_ABOUT       equ 7
APP_SECURITY_PROBE equ 8
APP_TASKMGR     equ 9
APP_PING        equ 10
APP_MEDIA       equ 11

APP_SLOT_PARAM_OFF         equ 0x17C000
APP_SLOT_PARAM_SZ          equ 256
APP_SLOT_BMP_FILE_OFF     equ 0x17D000
APP_SLOT_BMP_FILE_SZ      equ 262144
APP_SLOT_PAINT_CANVAS_OFF equ 0x1BD000
APP_SLOT_PAINT_CANVAS_SZ  equ 120000
APP_SLOT_SAVE_BMP_OFF     equ 0x1DB000
APP_SLOT_SAVE_BMP_SZ      equ 131072

%endif
