; ============================================================================
; Grit v3.0 - Window Manager
; ============================================================================
bits 64

section .text

%include "constants.inc"
%include "macros.inc"
%include "window_layout.inc"

section .text
global wm_init
global wm_create_window
global wm_create_window_ex
global wm_draw_window
global wm_draw_desktop
global wm_handle_mouse_event
; wm_get_window_at migrated to src/kernel/grithlk/wm_helpers.ghl (its `global`
; is emitted by that module's FN_BEGIN).
global wm_close_window
global wm_window_count
global wm_focused_window
global wm_drag_window_id
global desktop_bg_theme
global wallpaper_selected
global wallpaper_cache_valid
global wallpaper_cache_active_addr
global wallpaper_render_active
global wallpaper_cache_presented
global wallpaper_render_target_addr
global wallpaper_render_w
global wallpaper_render_h
global wm_poll_wallpaper_render

; Plain desktop fill colour used until a wallpaper is selected (0x00RRGGBB).
DESKTOP_SOLID_COLOR equ 0x00202632

extern render_rect
extern render_text
extern render_line
extern nx_icon_blit
extern render_get_backbuffer
extern render_mark_dirty
extern render_save_backbuffer
extern draw_hline
extern draw_vline
extern bb_addr
extern scr_pitch_q
extern memcpy
extern cursor_mode
extern call_app_l3
extern dispatch_app_callback           ; Stage 2d cross-core chokepoint
extern cpi_verify_callback             ; CPI-lite: authenticate tagged callback ptrs
extern call_app_l3_packed
extern process_submit_job
extern workqueue_done
extern workqueue_reap
extern wq_lock
extern wq_unlock
extern app_callback_lock
extern raster_select_default_target
extern ser_print_hex64
extern process_kill_window
extern process_create
extern l3_slot_base
extern desktop_draw_icons
extern nx_icon_close_16
extern app_hl_wallpaper_draw
extern app_media_draw
extern scr_width
extern scr_height
extern scene_dirty

%include "src/kernel/gui/window_lifecycle.inc"
%include "src/kernel/gui/window_desktop.inc"
%include "src/kernel/gui/window_draw.inc"
%include "src/kernel/gui/window_data.inc"
