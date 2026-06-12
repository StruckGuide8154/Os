section .data
szCloseX      db "X", 0
szMinDash     db "-", 0
szEmptyWin    db "Empty Window", 0

global wm_window_count
global wm_focused_window
wm_window_count   dq 0
wm_focused_window dq -1
wm_click_focus_before dq -1
wm_drag_window_id dq -1
wm_drag_off_x     dq 0
wm_drag_off_y     dq 0
; App-drag (per-window drag callback) tracking. Independent from the
; titlebar window-drag above - that one moves the whole window; this one
; routes mouse-move events to the app while the left button stays held.
; Latched on left-button-down inside a client area whose window has a
; non-zero WIN_OFF_DRAGFN. Cleared on left-button release.
wm_app_drag_window_id dq -1
wm_app_drag_last_x    dq 0
wm_app_drag_last_y    dq 0
global wm_drag_preview_x
global wm_drag_preview_y
global wm_drag_preview_w
global wm_drag_preview_h
wm_drag_preview_x dq 0          ; outline X position
wm_drag_preview_y dq 0          ; outline Y position
wm_drag_preview_w dq 0          ; outline width
wm_drag_preview_h dq 0          ; outline height
wm_last_buttons   dq 0
desktop_bg_theme  db 0
; 0 = no wallpaper chosen yet -> desktop draws a solid colour and the SVG
; rasterizer never runs. Set to 1 by SYS_DESKTOP_SET_BG when the user picks a
; theme in Settings; only then is a wallpaper rendered.
wallpaper_selected db 0
wallpaper_cache_valid db 0
wallpaper_cache_presented db 0
wallpaper_cache_valid_by_theme db 0, 0, 0
align 8
wallpaper_cache_active_addr dq WALLPAPER_CACHE0_ADDR
align 4
wallpaper_cache_w dd 0
wallpaper_cache_h dd 0
wallpaper_process_id dd -1
wallpaper_render_state db 0
wallpaper_render_active db 0
times 2 db 0
wallpaper_render_handle dd -1
wallpaper_render_theme dd 0
wallpaper_render_w dd 0
wallpaper_render_h dd 0
wallpaper_render_target_addr dq WALLPAPER_CACHE0_ADDR
align 64
wallpaper_render_pack times 32 db 0

; §6 per-slot callback target table (kernel BSS - OUTSIDE the ring-3 app arena,
; so a slot-memory write bug can't forge an entry). One trusted kernel-image VA
; per (slot, field). Indexed [slot * WM_CB_FIELDS + field]; a zero entry means
; "no callback interned". BSS-zero = empty, so no boot seed is needed; a
; recycled slot re-interns on its next dispatch. Mirrors the per-slot handle
; table's kernel-BSS discipline.
section .bss
align 16
global wm_cb_table
wm_cb_table  resq MAX_WINDOWS * WM_CB_FIELDS

section .text
