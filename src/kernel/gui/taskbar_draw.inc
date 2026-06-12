; Draw the taskbar + start menu
FN_BEGIN tb_draw, 0, 0, FN_RET_SCALAR
    push rbx
    push r12
    push r13
    push r14

    ; 1. Taskbar Background - spans the full current screen width
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

    ; Iterate the entry table - one row per entry, with optional separator
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
%ifndef RELEASE_BUILD
    cmp rax, app_security_probe_draw
    je .about
%endif
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