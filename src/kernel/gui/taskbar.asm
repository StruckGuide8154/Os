; ============================================================================
; Grit v3.0 - Taskbar + Start Menu
; Now shows open windows with names and close (X) buttons
; ============================================================================
bits 64

%include "constants.inc"

; The taskbar follows the active screen mode. Y positions and the
; right-anchored X positions live in display.asm as runtime globals,
; recomputed by display_recompute_layout() on every mode change.
extern scr_taskbar_y, scr_clock_x, scr_clock_y
extern scr_start_btn_y, scr_start_menu_y
extern scr_tb_btn_y, scr_bat_ind_x, scr_bat_ind_y

; Start menu geometry. Item count, height, and per-item layout are all
; derived from the single `menu_entries` table at the bottom of this file
; - to add a row, append one MENU_ENTRY there; nothing else needs touching.
START_MENU_W      equ 200
START_MENU_X      equ 4
MENU_ITEM_H       equ 28
MENU_PAD_TOP      equ 8
MENU_PAD_BOTTOM   equ 8
MENU_COLOR_BG     equ COLOR_MENU_BG
MENU_COLOR_HL     equ COLOR_ACCENT

; Per-entry layout. Keep MENU_ENTRY_SIZE a power-of-friendly small struct.
MENU_ENTRY_SIZE   equ 24      ; icon(8) + label(8) + app(1) + flags(1) + pad(6)
MENU_OFF_ICON     equ 0
MENU_OFF_LABEL    equ 8
MENU_OFF_APP      equ 16
MENU_OFF_FLAGS    equ 17

MENU_FLAG_SEP_ABOVE equ 1     ; draw a thin separator line above this row
MENU_FLAG_DIM       equ 2     ; render label in gray instead of black

; Count + height come from the table - see menu_entries / menu_entries_end.
MENU_ITEM_COUNT equ (menu_entries_end - menu_entries) / MENU_ENTRY_SIZE
START_MENU_H    equ (MENU_PAD_TOP + MENU_ITEM_H * MENU_ITEM_COUNT + MENU_PAD_BOTTOM)

; Taskbar button layout
TB_BTN_START_X  equ (START_BTN_X + START_BTN_W + 8)  ; after start button
TB_BTN_W        equ 130          ; width per app button
TB_BTN_H        equ 28
TB_BTN_GAP      equ 4
TB_CLOSE_SIZE   equ 14           ; X button size inside taskbar button
TB_CLOSE_OFF_X  equ (TB_BTN_W - TB_CLOSE_SIZE - 4) ; X button offset from button left

%include "window_layout.inc"

; Battery indicator layout (to the left of the clock). Width/height are
; static; X/Y depend on the taskbar position and live in display.asm.
BAT_IND_W       equ 88           ; total width of battery area
BAT_IND_H       equ (TASKBAR_HEIGHT - 8)

; Battery state constants (must match battery.asm)
BAT_STATE_UNKNOWN   equ 0
BAT_STATE_AC        equ 1
BAT_STATE_DISCHARGE equ 2
BAT_STATE_CHARGING  equ 3

; Battery icon pixel dimensions (drawn manually)
BATT_ICON_W     equ 20
BATT_ICON_H     equ 12
PLUG_ICON_W     equ 14
PLUG_ICON_H     equ 14

section .text
; auto-wrapped (FN_BEGIN emits global): global tb_draw
; auto-wrapped (FN_BEGIN emits global): global tb_handle_click
global tb_start_menu_open
global tb_get_menu_item_at

extern render_rect
extern render_text
extern render_mark_dirty
extern nx_icon_blit
extern draw_hline
extern draw_vline
extern wm_close_window
extern wm_focused_window
extern desktop_has_icon
extern desktop_add_icon
extern desktop_remove_icon
extern battery_state
extern battery_percent
extern uint32_to_str
extern time_hours
extern time_minutes
extern nx_icon_about_16
extern nx_icon_close_16
extern nx_icon_explorer_16
extern nx_icon_file_16
extern nx_icon_notepad_16
extern nx_icon_paint_16
extern nx_icon_settings_16
extern nx_icon_start_16
extern nx_icon_taskmgr_16
extern nx_icon_terminal_16
extern app_bmp_draw
extern app_hl_about_draw
extern app_hl_explorer_draw
extern app_hl_explorer_properties_draw
extern app_hl_notepad_draw
extern app_hl_paint_draw
extern app_hl_settings_draw
extern app_hl_taskmgr_draw
extern app_hl_terminal_draw
%ifndef RELEASE_BUILD
extern app_security_probe_draw
%endif

%include "src/kernel/gui/taskbar_draw.inc"
%include "src/kernel/gui/taskbar_click.inc"
%include "src/kernel/gui/taskbar_data.inc"
