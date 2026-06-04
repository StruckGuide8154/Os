; ============================================================================
; NexusOS v3.0 - Taskbar + Start Menu
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
; — to add a row, append one MENU_ENTRY there; nothing else needs touching.
START_MENU_W      equ 200
START_MENU_X      equ 4
MENU_ITEM_H       equ 28
MENU_PAD_TOP      equ 8
MENU_PAD_BOTTOM   equ 8
MENU_COLOR_BG     equ COLOR_SURFACE
MENU_COLOR_HL     equ COLOR_ACCENT

; Per-entry layout. Keep MENU_ENTRY_SIZE a power-of-friendly small struct.
MENU_ENTRY_SIZE   equ 24      ; icon(8) + label(8) + app(1) + flags(1) + pad(6)
MENU_OFF_ICON     equ 0
MENU_OFF_LABEL    equ 8
MENU_OFF_APP      equ 16
MENU_OFF_FLAGS    equ 17

MENU_FLAG_SEP_ABOVE equ 1     ; draw a thin separator line above this row
MENU_FLAG_DIM       equ 2     ; render label in gray instead of black

; Count + height come from the table — see menu_entries / menu_entries_end.
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
extern app_security_probe_draw

; Draw the taskbar + start menu
FN_BEGIN tb_draw, 0, 0, FN_RET_SCALAR
    push rbx
    push r12
    push r13
    push r14

    ; 1. Taskbar Background — spans the full current screen width
    mov rdi, 0
    mov esi, [scr_taskbar_y]
    mov edx, [scr_width]
    mov rcx, TASKBAR_HEIGHT
    mov r8d, COLOR_TASKBAR_BG
    call render_rect

    ; Raised bevel top edge of taskbar
    mov rdi, 0
    mov esi, [scr_taskbar_y]
    mov edx, [scr_width]
    mov rcx, COLOR_BEVEL_LT
    call draw_hline

    ; 2. Start Button
    mov rdi, START_BTN_X
    mov esi, [scr_start_btn_y]
    mov rdx, START_BTN_W
    mov rcx, START_BTN_H
    mov r8d, COLOR_START_BTN
    call render_rect

    ; Start icon + text
    mov rdi, nx_icon_start_16
    mov rsi, START_BTN_X + 8
    mov edx, [scr_start_btn_y]
    add edx, 6
    call nx_icon_blit
    mov rdi, START_BTN_X + 28
    mov esi, [scr_start_btn_y]
    add esi, 7
    mov rdx, szStart
    mov ecx, COLOR_TEXT_BLACK
    mov r8d, COLOR_START_BTN
    call render_text

    ; 3. Draw open window buttons on taskbar
    mov rbx, WINDOW_POOL_ADDR   ; current window struct
    xor r12d, r12d               ; window slot index
    mov r13d, TB_BTN_START_X     ; current X position for next button

.tb_win_loop:
    cmp r12d, MAX_WINDOWS
    jge .tb_win_done

    ; Check if this slot is active
    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .tb_win_next

    ; Draw button background (VGA98 face color)
    mov r8d, COLOR_CHROME_FACE   ; default face
    mov rax, [wm_focused_window]
    cmp eax, r12d
    jne .tb_not_focused
    mov r8d, COLOR_SURFACE       ; focused: slightly lighter
.tb_not_focused:
    test qword [rbx + WIN_OFF_FLAGS], WF_MINIMIZED
    jz .tb_not_min
    mov r8d, COLOR_CHROME_FACE   ; minimized: same face
.tb_not_min:
    mov edi, r13d
    mov esi, [scr_tb_btn_y]
    mov edx, TB_BTN_W
    mov ecx, TB_BTN_H
    call render_rect

    ; Focus indicator: a narrow accent strip, not a dark text background.
    mov rax, [wm_focused_window]
    cmp eax, r12d
    jne .tb_no_focus_strip
    mov edi, r13d
    mov esi, [scr_tb_btn_y]
    mov edx, 3
    mov ecx, TB_BTN_H
    mov r8d, COLOR_ACCENT
    call render_rect
.tb_no_focus_strip:

    ; Draw app icon from the window's draw callback.
    mov rdi, rbx
    call tb_icon_for_window
    test rax, rax
    jz .tb_skip_icon
    mov rdi, rax
    lea esi, [r13d + 7]
    mov edx, [scr_tb_btn_y]
    add edx, 6
    call nx_icon_blit
.tb_skip_icon:

    ; Draw button border (1px lighter top edge)
    ; Draw window title text (truncated to fit)
    lea rdx, [rbx + WIN_OFF_TITLE]
    ; Check first byte - skip if empty title
    cmp byte [rdx], 0
    je .tb_skip_text
    mov edi, r13d
    add edi, 28                  ; room for icon + padding
    mov esi, [scr_tb_btn_y]
    add esi, 7
    mov ecx, COLOR_TEXT_BLACK
    ; Match the text background to the button fill so inactive/minimized
    ; buttons do not show dark boxes behind titles.
    mov r8d, COLOR_CHROME_FACE
    mov rax, [wm_focused_window]
    cmp eax, r12d
    jne .tb_txt_bg_ok
    mov r8d, COLOR_SURFACE
.tb_txt_bg_ok:
    test qword [rbx + WIN_OFF_FLAGS], WF_MINIMIZED
    jz .tb_txt_bg_ok2
    mov r8d, COLOR_CHROME_FACE
.tb_txt_bg_ok2:
    call render_text
.tb_skip_text:

    ; Draw X close button (small red square at right side of button)
    mov edi, r13d
    add edi, TB_CLOSE_OFF_X
    mov esi, [scr_tb_btn_y]
    add esi, 7
    mov edx, TB_CLOSE_SIZE
    mov ecx, TB_CLOSE_SIZE
    mov r8d, COLOR_CLOSE_BTN
    call render_rect

    ; Draw close icon on close button
    mov edi, r13d
    add edi, TB_CLOSE_OFF_X - 1
    mov esi, [scr_tb_btn_y]
    add esi, 6
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, nx_icon_close_16
    call nx_icon_blit

    ; Advance X position for next button
    add r13d, TB_BTN_W + TB_BTN_GAP

.tb_win_next:
    add rbx, WINDOW_STRUCT_SIZE
    inc r12d
    jmp .tb_win_loop

.tb_win_done:

    ; 4. Clock area - format HH:MM into szTime
    push rax
    push rcx
    ; Hours
; This section in taskbar.asm is now correct because time_hours is a db
    movzx eax, byte [time_hours]
    mov bl, 10
    div bl              ; al = tens, ah = ones
    add ax, 0x3030      ; convert both to ASCII
    mov [szTime], al
    mov [szTime+1], ah
    mov byte [szTime+2], ':'
    ; Minutes
    movzx eax, byte [time_minutes]
    mov bl, 10
    div bl
    add ax, 0x3030
    mov [szTime+3], al
    mov [szTime+4], ah

    pop rcx
    pop rax
    mov edi, [scr_clock_x]
    mov esi, [scr_clock_y]
    mov rdx, szTime
    mov ecx, COLOR_TEXT_BLACK
    mov r8d, COLOR_TASKBAR_BG
    call render_text

    ; 5. Battery/power indicator
    call tb_draw_battery

    ; 6. Start menu overlay (if open)
    cmp byte [tb_start_menu_open], 0
    je .no_menu

    ; Menu background
    mov rdi, START_MENU_X
    mov esi, [scr_start_menu_y]
    mov rdx, START_MENU_W
    mov rcx, START_MENU_H
    mov r8d, MENU_COLOR_BG
    call render_rect

    ; Menu border: raised bevel
    mov rdi, START_MENU_X
    mov esi, [scr_start_menu_y]
    mov rdx, START_MENU_W
    mov rcx, COLOR_BEVEL_LT
    call draw_hline
    mov rdi, START_MENU_X
    mov esi, [scr_start_menu_y]
    mov rdx, START_MENU_H
    mov rcx, COLOR_BEVEL_LT
    call draw_vline
    mov rdi, START_MENU_X + START_MENU_W - 1
    mov esi, [scr_start_menu_y]
    mov rdx, START_MENU_H
    mov rcx, COLOR_BEVEL_DK
    call draw_vline
    mov rdi, START_MENU_X
    mov esi, [scr_start_menu_y]
    add esi, START_MENU_H - 1
    mov rdx, START_MENU_W
    mov rcx, COLOR_BEVEL_DK
    call draw_hline

    ; Iterate the entry table — one row per entry, with optional separator
    ; above and dim color, both driven by the per-entry flags byte.
    lea rbx, [rel menu_entries]
    xor r12d, r12d                       ; r12 = row index
.menu_row_loop:
    cmp r12d, MENU_ITEM_COUNT
    jge .menu_rows_done

    movzx r14d, byte [rbx + MENU_OFF_FLAGS]

    ; Optional separator above this row (drawn in the top padding slot)
    test r14d, MENU_FLAG_SEP_ABOVE
    jz .no_sep
    mov rdi, START_MENU_X + 8
    mov esi, [scr_start_menu_y]
    mov eax, r12d
    imul eax, MENU_ITEM_H
    add esi, eax
    add esi, MENU_PAD_TOP
    mov rdx, START_MENU_W - 16
    mov rcx, 1
    mov r8d, 0x00555588
    call render_rect
.no_sep:

    ; Icon at (X+8, menu_y + pad + row*H)
    mov rdi, [rbx + MENU_OFF_ICON]
    mov rsi, START_MENU_X + 8
    mov edx, [scr_start_menu_y]
    mov eax, r12d
    imul eax, MENU_ITEM_H
    add edx, eax
    add edx, MENU_PAD_TOP
    call nx_icon_blit

    ; Label text 2px below the icon line; pick color per flags
    mov rdi, START_MENU_X + 36
    mov esi, [scr_start_menu_y]
    mov eax, r12d
    imul eax, MENU_ITEM_H
    add esi, eax
    add esi, MENU_PAD_TOP + 2
    mov rdx, [rbx + MENU_OFF_LABEL]
    mov ecx, COLOR_TEXT_BLACK
    test r14d, MENU_FLAG_DIM
    jz .label_color_ok
    mov ecx, COLOR_TEXT_GRAY
.label_color_ok:
    mov r8d, MENU_COLOR_BG
    call render_text

    add rbx, MENU_ENTRY_SIZE
    inc r12d
    jmp .menu_row_loop
.menu_rows_done:

.no_menu:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; tb_draw_battery - Draw battery/power indicator in taskbar right area
;
; Layout (BAT_IND_X, TASKBAR_Y+4):
;   State 1 (AC only):      [plug icon] "AC"
;   State 2 (discharging):  [battery icon] "75%"
;   State 3 (charging):     [battery icon][plug icon] "75%"
;   State 0 (unknown):      nothing drawn
; ============================================================================
tb_draw_battery:
    push rbx
    push r12
    push r13

    movzx eax, byte [battery_state]
    cmp al, BAT_STATE_UNKNOWN
    jne .bat_start

    ; Unknown state: blink a red X every second or so
    mov edi, [scr_bat_ind_x]
    add edi, 4
    mov esi, [scr_taskbar_y]
    add esi, 11
    mov rdx, szNoBat
    mov ecx, 0x00FF0000        ; Red text
    mov r8d, COLOR_TASKBAR_BG
    call render_text
    jmp .bat_done

.bat_start:
    ; Clear the background area first
    mov edi, [scr_bat_ind_x]
    mov esi, [scr_bat_ind_y]
    mov edx, BAT_IND_W
    mov ecx, BAT_IND_H
    mov r8d, COLOR_TASKBAR_BG
    call render_rect

    movzx eax, byte [battery_state]
    cmp al, BAT_STATE_AC
    je .draw_ac_only

    ; States 2 (discharging) and 3 (charging): draw battery icon
    ; Battery outline: 20x12 px at (scr_bat_ind_x, scr_taskbar_y+10)
    mov r12d, [scr_bat_ind_x]   ; icon X
    mov r13d, [scr_taskbar_y]
    add r13d, 10               ; icon Y

    ; Battery body outline (white rectangle 18x12, then nub 2x4 on right)
    ; Outer border
    mov edi, r12d
    mov esi, r13d
    mov edx, 18
    mov ecx, 12
    mov r8d, 0x00AAAAAA        ; Light gray border
    call render_rect

    ; Inner fill (black background for body)
    mov edi, r12d
    inc edi
    mov esi, r13d
    inc esi
    mov edx, 16
    mov ecx, 10
    mov r8d, 0x00111111
    call render_rect

    ; Nub (+ terminal) on right side, centered vertically
    mov edi, r12d
    add edi, 18
    mov esi, r13d
    add esi, 4
    mov edx, 3
    mov ecx, 4
    mov r8d, 0x00AAAAAA
    call render_rect

    ; Fill bar inside battery body based on percentage
    ; Fill width = percent * 14 / 100 (max fill = 14px inside 16px body)
    movzx eax, byte [battery_percent]
    imul eax, 14
    xor edx, edx
    mov ecx, 100
    div ecx                    ; EAX = fill width (0-14)
    test eax, eax
    jz .bat_no_fill

    ; Choose fill color based on %
    movzx ecx, byte [battery_percent]
    mov r8d, 0x0022CC22        ; Green (>20%)
    cmp ecx, 20
    jg .fill_color_ok
    mov r8d, 0x00CC2222        ; Red (<=20%)
.fill_color_ok:
    ; If charging, use different color
    movzx ecx, byte [battery_state]
    cmp ecx, BAT_STATE_CHARGING
    jne .fill_not_charging
    mov r8d, 0x002288FF        ; Blue fill when charging
.fill_not_charging:
    mov edi, r12d
    inc edi                    ; +1 for border
    mov esi, r13d
    inc esi                    ; +1 for border
    ; EDX still has fill width from division? No, EDX was clobbered by div.
    ; EAX has fill width.
    push rax
    mov edx, eax               ; fill width
    mov ecx, 10                ; fill height
    call render_rect
    pop rax

.bat_no_fill:
    ; If charging, also draw plug icon to the right of battery
    movzx eax, byte [battery_state]
    cmp al, BAT_STATE_CHARGING
    jne .bat_draw_text

    ; Draw plug icon at (scr_bat_ind_x + BATT_ICON_W + 4, scr_taskbar_y+10)
    mov edi, [scr_bat_ind_x]
    add edi, BATT_ICON_W + 4
    mov esi, [scr_taskbar_y]
    add esi, 10
    call tb_draw_plug_icon

    ; Text X: to the right of battery + plug icons
    mov r12d, [scr_bat_ind_x]
    add r12d, BATT_ICON_W + PLUG_ICON_W + 10
    jmp .bat_draw_pct_text

.bat_draw_text:
    ; Just battery: text to right of battery icon
    mov r12d, [scr_bat_ind_x]
    add r12d, BATT_ICON_W + 4

.bat_draw_pct_text:
    ; Build "XX%" string
    movzx edi, byte [battery_percent]
    lea rsi, [bat_pct_str]
    call uint32_to_str
    ; Append '%'
    lea rsi, [bat_pct_str]
.find_end:
    cmp byte [rsi], 0
    je .append_pct
    inc rsi
    jmp .find_end
.append_pct:
    mov byte [rsi], '%'
    mov byte [rsi + 1], 0

    mov edi, r12d
    mov esi, [scr_taskbar_y]
    add esi, 12
    lea rdx, [bat_pct_str]
    mov ecx, COLOR_TEXT_BLACK
    mov r8d, COLOR_TASKBAR_BG
    call render_text
    jmp .bat_done

.draw_ac_only:
    ; AC only: draw plug icon + "AC" text
    mov edi, [scr_bat_ind_x]
    add edi, 4
    mov esi, [scr_taskbar_y]
    add esi, 11
    call tb_draw_plug_icon

    mov edi, [scr_bat_ind_x]
    add edi, PLUG_ICON_W + 8
    mov esi, [scr_taskbar_y]
    add esi, 12
    lea rdx, [szAC]
    mov ecx, COLOR_TEXT_BLACK
    mov r8d, COLOR_TASKBAR_BG
    call render_text

.bat_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; tb_draw_plug_icon - Draw a small pixel-art plug icon
; EDI = X (base), ESI = Y (base)  (14x14 pixels total)
; ============================================================================
tb_draw_plug_icon:
    push r14
    push r15

    mov r14d, edi
    mov r15d, esi
    mov r8d, 0x00FFDD44

    ; Left prong: (X+3, Y), 2 wide, 4 tall
    lea edi, [r14 + 3]
    mov esi, r15d
    mov edx, 2
    mov ecx, 4
    call render_rect

    ; Right prong: (X+9, Y), 2 wide, 4 tall
    lea edi, [r14 + 9]
    mov esi, r15d
    mov edx, 2
    mov ecx, 4
    call render_rect

    ; Body: (X+1, Y+4), 12 wide, 5 tall
    lea edi, [r14 + 1]
    lea esi, [r15 + 4]
    mov edx, 12
    mov ecx, 5
    call render_rect

    ; Cord: (X+5, Y+9), 4 wide, 4 tall
    lea edi, [r14 + 5]
    lea esi, [r15 + 9]
    mov edx, 4
    mov ecx, 4
    call render_rect

    pop r15
    pop r14
    ret

; tb_icon_for_window: RDI=window struct -> RAX=16px icon pointer.
; The window manager does not store an app id yet, so taskbar icons are mapped
; from each window's draw callback. Unknown document/viewer windows fall back
; to the generic file icon.
tb_icon_for_window:
    mov rax, [rdi + WIN_OFF_DRAWFN]
    cmp rax, app_hl_explorer_draw
    je .explorer
    cmp rax, app_hl_explorer_properties_draw
    je .explorer
    cmp rax, app_hl_terminal_draw
    je .terminal
    cmp rax, app_hl_notepad_draw
    je .notepad
    cmp rax, app_hl_settings_draw
    je .settings
    cmp rax, app_hl_paint_draw
    je .paint
    cmp rax, app_hl_about_draw
    je .about
    cmp rax, app_hl_taskmgr_draw
    je .taskmgr
    cmp rax, app_security_probe_draw
    je .about
    cmp rax, app_bmp_draw
    je .file
.file:
    mov rax, nx_icon_file_16
    ret
.explorer:
    mov rax, nx_icon_explorer_16
    ret
.terminal:
    mov rax, nx_icon_terminal_16
    ret
.notepad:
    mov rax, nx_icon_notepad_16
    ret
.settings:
    mov rax, nx_icon_settings_16
    ret
.paint:
    mov rax, nx_icon_paint_16
    ret
.about:
    mov rax, nx_icon_about_16
    ret
.taskmgr:
    mov rax, nx_icon_taskmgr_16
    ret

; Handle click on taskbar / start menu
; RDI = Mouse X, RSI = Mouse Y
; Returns: RAX = 0 (not handled), 1 (handled, no app), or 2..6 (menu item 0..4 clicked)
FN_BEGIN tb_handle_click, 0, 0, FN_RET_SCALAR
    push rbx
    push r12
    push r13

    ; Check if start menu is open and click is inside it
    cmp byte [tb_start_menu_open], 0
    je .check_taskbar

    ; Check bounds of start menu
    cmp rdi, START_MENU_X
    jl .close_menu
    cmp rdi, START_MENU_X + START_MENU_W
    jg .close_menu
    movsxd rax, dword [scr_start_menu_y]
    cmp rsi, rax
    jl .close_menu
    movsxd rax, dword [scr_taskbar_y]
    cmp rsi, rax
    jge .check_taskbar

    ; Click inside menu - determine which item
    mov rax, rsi
    movsxd rcx, dword [scr_start_menu_y]
    sub rax, rcx
    sub rax, 8
    cmp rax, 0
    jl .close_menu
    xor rdx, rdx
    mov rcx, MENU_ITEM_H
    div rcx

    ; Validate range
    cmp rax, MENU_ITEM_COUNT
    jge .close_menu

    ; Close menu and return the app id for this menu row.
    mov byte [tb_start_menu_open], 0
    mov rcx, MENU_ENTRY_SIZE
    mul rcx                       ; rax = row * MENU_ENTRY_SIZE
    lea rcx, [rel menu_entries]
    movzx rax, byte [rcx + rax + MENU_OFF_APP]
    jmp .tb_click_ret

.close_menu:
    mov byte [tb_start_menu_open], 0
    mov rax, 1
    jmp .tb_click_ret

.check_taskbar:
    ; Check if within taskbar Y range
    movsxd rax, dword [scr_taskbar_y]
    cmp rsi, rax
    jl .not_handled

    ; Check Start Button
    cmp rdi, START_BTN_X
    jl .check_tb_windows
    cmp rdi, START_BTN_X + START_BTN_W
    jg .check_tb_windows

    ; Clicked start button - toggle menu
    xor byte [tb_start_menu_open], 1
    mov rax, 1
    jmp .tb_click_ret

.check_tb_windows:
    ; Close menu
    mov byte [tb_start_menu_open], 0

    ; Check if click is on one of the window buttons
    ; Iterate active windows and check X ranges
    mov rbx, WINDOW_POOL_ADDR
    xor r12d, r12d               ; slot index
    mov r13d, TB_BTN_START_X     ; current button X

.tb_click_loop:
    cmp r12d, MAX_WINDOWS
    jge .tb_click_none

    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .tb_click_next

    ; Check if click X is within this button
    cmp edi, r13d
    jl .tb_click_next_active
    mov eax, r13d
    add eax, TB_BTN_W
    cmp edi, eax
    jge .tb_click_next_active

    ; Click Y must be within button height
    cmp esi, [scr_tb_btn_y]
    jl .tb_click_next_active
    mov eax, [scr_tb_btn_y]
    add eax, TB_BTN_H
    cmp esi, eax
    jge .tb_click_next_active

    ; Click is on this button. Check if on the X close area
    mov eax, r13d
    add eax, TB_CLOSE_OFF_X
    cmp edi, eax
    jl .tb_btn_activate
    ; Click is on X button - close this window
    push rdi
    push rsi
    mov rdi, r12               ; window ID
    call wm_close_window
    pop rsi
    pop rdi
    mov rax, 1
    jmp .tb_click_ret

.tb_btn_activate:
    ; Click on window name area - restore and focus
    ; If minimized, un-minimize
    test qword [rbx + WIN_OFF_FLAGS], WF_MINIMIZED
    jz .tb_btn_focus
    and qword [rbx + WIN_OFF_FLAGS], ~WF_MINIMIZED
    or qword [rbx + WIN_OFF_FLAGS], WF_VISIBLE

.tb_btn_focus:
    ; Unfocus all windows, then focus this one
    mov rcx, WINDOW_POOL_ADDR
    xor edx, edx
.tb_unfocus_loop:
    cmp edx, MAX_WINDOWS
    je .tb_unfocus_done
    and qword [rcx + WIN_OFF_FLAGS], ~WF_FOCUSED
    add rcx, WINDOW_STRUCT_SIZE
    inc edx
    jmp .tb_unfocus_loop
.tb_unfocus_done:
    or qword [rbx + WIN_OFF_FLAGS], WF_FOCUSED
    mov [wm_focused_window], r12
    mov rax, 1
    jmp .tb_click_ret

.tb_click_next_active:
    add r13d, TB_BTN_W + TB_BTN_GAP
.tb_click_next:
    add rbx, WINDOW_STRUCT_SIZE
    inc r12d
    jmp .tb_click_loop

.tb_click_none:
    mov rax, 1
    jmp .tb_click_ret

.not_handled:
    xor rax, rax

.tb_click_ret:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; Handle right-click on start menu: RDI=mouseX, RSI=mouseY
; Returns RAX: 0=not handled, 1=handled
; ============================================================================
; auto-wrapped (FN_BEGIN emits global): global tb_handle_rclick
FN_BEGIN tb_handle_rclick, 0, 0, FN_RET_SCALAR
    push rbx

    ; First check if submenu is open and click is inside it
    cmp byte [sm_submenu_open], 0
    je .rc_check_menu

    ; Check if click is inside the submenu (2 items: 20px each + 4px pad)
    mov eax, [sm_submenu_x]
    cmp edi, eax
    jl .rc_close_sub
    add eax, SM_SUB_W
    cmp edi, eax
    jg .rc_close_sub
    mov eax, [sm_submenu_y]
    cmp esi, eax
    jl .rc_close_sub
    add eax, SM_SUB_H
    cmp esi, eax
    jg .rc_close_sub

    ; Click inside submenu - determine which item
    mov eax, esi
    sub eax, [sm_submenu_y]
    xor edx, edx
    mov ecx, 22
    div ecx
    ; eax = item index (0 = add/remove)
    test eax, eax
    jnz .rc_close_sub         ; only 1 item

    ; Toggle desktop icon for the saved app
    movzx edi, byte [sm_submenu_app]
    call desktop_has_icon
    test eax, eax
    jnz .rc_remove
    ; Add to desktop
    movzx edi, byte [sm_submenu_app]
    call desktop_add_icon
    jmp .rc_close_sub
.rc_remove:
    movzx edi, byte [sm_submenu_app]
    call desktop_remove_icon

.rc_close_sub:
    mov byte [sm_submenu_open], 0
    mov rax, 1
    jmp .rc_ret

.rc_check_menu:
    ; Is start menu open?
    cmp byte [tb_start_menu_open], 0
    je .rc_not_handled

    ; Check bounds of start menu
    cmp edi, START_MENU_X
    jl .rc_not_handled
    cmp edi, START_MENU_X + START_MENU_W
    jg .rc_not_handled
    cmp esi, [scr_start_menu_y]
    jl .rc_not_handled
    cmp esi, [scr_taskbar_y]
    jge .rc_not_handled

    ; Right-click inside menu - determine which item
    mov eax, esi
    sub eax, [scr_start_menu_y]
    sub eax, 8
    cmp eax, 0
    jl .rc_not_handled
    xor edx, edx
    mov ecx, MENU_ITEM_H
    div ecx

    ; Items 0-4 are apps (Explorer thru Paint), item 5 is About
    cmp eax, MENU_ITEM_COUNT
    jge .rc_not_handled

    ; eax = menu row index. Look up the app id; keep the row in r9 for Y placement.
    mov r9d, eax                  ; r9 = row index (preserved)
    mov rcx, MENU_ENTRY_SIZE
    mul rcx                       ; rax = row * MENU_ENTRY_SIZE
    lea rcx, [rel menu_entries]
    movzx edx, byte [rcx + rax + MENU_OFF_APP]
    mov byte [sm_submenu_app], dl
    mov dword [sm_submenu_x], START_MENU_X + START_MENU_W + 2
    mov ecx, r9d
    imul ecx, MENU_ITEM_H
    add ecx, [scr_start_menu_y]
    add ecx, 4
    mov [sm_submenu_y], ecx
    mov byte [sm_submenu_open], 1
    mov rax, 1
    jmp .rc_ret

.rc_not_handled:
    xor eax, eax
.rc_ret:
    pop rbx
    ret

; ============================================================================
; Draw start menu submenu (called from tb_draw when submenu is open)
; ============================================================================
SM_SUB_W  equ 160
SM_SUB_H  equ 26

; auto-wrapped (FN_BEGIN emits global): global tb_draw_submenu
FN_BEGIN tb_draw_submenu, 0, 0, FN_RET_SCALAR
    cmp byte [sm_submenu_open], 0
    je .sub_ret

    push rax

    ; Background
    mov edi, [sm_submenu_x]
    mov esi, [sm_submenu_y]
    mov edx, SM_SUB_W
    mov ecx, SM_SUB_H
    mov r8d, 0x001E1E3E
    call render_rect

    ; Border top
    mov edi, [sm_submenu_x]
    mov esi, [sm_submenu_y]
    mov edx, SM_SUB_W
    mov ecx, 1
    mov r8d, COLOR_BEVEL_LT
    call render_rect

    ; Determine text: "Add to Desktop" or "Remove from Desktop"
    movzx edi, byte [sm_submenu_app]
    call desktop_has_icon
    test eax, eax
    jnz .sub_show_remove

    ; Show "Add to Desktop"
    mov edi, [sm_submenu_x]
    add edi, 8
    mov esi, [sm_submenu_y]
    add esi, 5
    mov rdx, szSubAdd
    mov ecx, COLOR_TEXT_BLACK
    mov r8d, 0x001E1E3E
    call render_text
    jmp .sub_draw_done

.sub_show_remove:
    mov edi, [sm_submenu_x]
    add edi, 8
    mov esi, [sm_submenu_y]
    add esi, 5
    mov rdx, szSubRemove
    mov ecx, 0x00FF8888
    mov r8d, 0x001E1E3E
    call render_text

.sub_draw_done:
    pop rax
.sub_ret:
    ret

; ============================================================================
; Handle left-click on submenu (called from main loop)
; Returns RAX: 0=not in submenu, 1=handled
; ============================================================================
; auto-wrapped (FN_BEGIN emits global): global tb_handle_submenu_click
FN_BEGIN tb_handle_submenu_click, 0, 0, FN_RET_SCALAR
    cmp byte [sm_submenu_open], 0
    je .smc_no

    ; Check if click is inside the submenu
    mov eax, [sm_submenu_x]
    cmp edi, eax
    jl .smc_close
    add eax, SM_SUB_W
    cmp edi, eax
    jg .smc_close
    mov eax, [sm_submenu_y]
    cmp esi, eax
    jl .smc_close
    add eax, SM_SUB_H
    cmp esi, eax
    jg .smc_close

    ; Click inside submenu - toggle desktop icon
    push rdi
    push rsi
    movzx edi, byte [sm_submenu_app]
    call desktop_has_icon
    test eax, eax
    jnz .smc_do_remove
    pop rsi
    pop rdi
    push rdi
    push rsi
    movzx edi, byte [sm_submenu_app]
    call desktop_add_icon
    jmp .smc_close_pop
.smc_do_remove:
    pop rsi
    pop rdi
    push rdi
    push rsi
    movzx edi, byte [sm_submenu_app]
    call desktop_remove_icon
.smc_close_pop:
    pop rsi
    pop rdi
    mov byte [sm_submenu_open], 0
    mov rax, 1
    ret

.smc_close:
    mov byte [sm_submenu_open], 0
    mov rax, 1
    ret

.smc_no:
    xor eax, eax
    ret

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
szMenuAbout    db "About NexusOS", 0

; ============================================================================
; Start menu entry table — single source of truth for the menu.
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
