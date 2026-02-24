; ============================================================================
; NexusOS v3.0 - Taskbar + Start Menu
; Now shows open windows with names and close (X) buttons
; ============================================================================
bits 64

%include "constants.inc"

START_MENU_W    equ 200
START_MENU_H    equ 200
START_MENU_X    equ 4
START_MENU_Y    equ (TASKBAR_Y - START_MENU_H)
MENU_ITEM_H     equ 28
MENU_COLOR_BG   equ 0x001E1E3E
MENU_COLOR_HL   equ 0x003355AA
MENU_ITEM_COUNT equ 6

; Taskbar button layout
TB_BTN_START_X  equ (START_BTN_X + START_BTN_W + 8)  ; after start button
TB_BTN_W        equ 130          ; width per app button
TB_BTN_H        equ 28
TB_BTN_GAP      equ 4
TB_BTN_Y        equ (TASKBAR_Y + 4)
TB_CLOSE_SIZE   equ 14           ; X button size inside taskbar button
TB_CLOSE_OFF_X  equ (TB_BTN_W - TB_CLOSE_SIZE - 4) ; X button offset from button left

WIN_OFF_FLAGS   equ 40
WIN_OFF_TITLE   equ 48

; Battery indicator layout (to the left of the clock)
BAT_IND_W       equ 88           ; total width of battery area
BAT_IND_X       equ (CLOCK_X - BAT_IND_W - 6)
BAT_IND_Y       equ (TASKBAR_Y + 4)
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
global tb_draw
global tb_handle_click
global tb_start_menu_open
global tb_get_menu_item_at

extern render_rect
extern render_text
extern render_mark_dirty
extern wm_close_window
extern wm_focused_window
extern desktop_has_icon
extern desktop_add_icon
extern desktop_remove_icon
extern battery_state
extern battery_percent
extern uint32_to_str

; Draw the taskbar + start menu
tb_draw:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push rbx
    push r12
    push r13
    push r14

    ; 1. Taskbar Background
    mov rdi, 0
    mov rsi, TASKBAR_Y
    mov rdx, SCREEN_WIDTH
    mov rcx, TASKBAR_HEIGHT
    mov r8d, COLOR_TASKBAR_BG
    call render_rect

    ; Highlight line at top
    mov rdi, 0
    mov rsi, TASKBAR_Y
    mov rdx, SCREEN_WIDTH
    mov rcx, 1
    mov r8d, COLOR_TASKBAR_TOP
    call render_rect

    ; 2. Start Button
    mov rdi, START_BTN_X
    mov rsi, START_BTN_Y
    mov rdx, START_BTN_W
    mov rcx, START_BTN_H
    mov r8d, COLOR_START_BTN
    call render_rect

    ; Start Text
    mov rdi, START_BTN_X + 12
    mov rsi, START_BTN_Y + 6
    mov rdx, szStart
    mov ecx, COLOR_TEXT_WHITE
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

    ; Draw button background
    ; Focused windows get a brighter color
    mov r8d, 0x002A2A4E          ; default: unfocused dark
    mov rax, [wm_focused_window]
    cmp eax, r12d
    jne .tb_not_focused
    mov r8d, 0x003355AA          ; focused: bright blue
.tb_not_focused:
    ; Minimized windows get slightly different look
    test qword [rbx + WIN_OFF_FLAGS], WF_MINIMIZED
    jz .tb_not_min
    mov r8d, 0x00222244          ; minimized: darker
.tb_not_min:
    mov edi, r13d
    mov esi, TB_BTN_Y
    mov edx, TB_BTN_W
    mov ecx, TB_BTN_H
    call render_rect

    ; Draw button border (1px lighter top edge)
    mov edi, r13d
    mov esi, TB_BTN_Y
    mov edx, TB_BTN_W
    mov ecx, 1
    mov r8d, 0x004466AA
    call render_rect

    ; Draw window title text (truncated to fit)
    lea rdx, [rbx + WIN_OFF_TITLE]
    ; Check first byte - skip if empty title
    cmp byte [rdx], 0
    je .tb_skip_text
    mov edi, r13d
    add edi, 6                   ; padding from left
    mov esi, TB_BTN_Y + 7
    mov ecx, COLOR_TEXT_WHITE
    ; Background color for text depends on focus
    mov r8d, 0x002A2A4E
    mov rax, [wm_focused_window]
    cmp eax, r12d
    jne .tb_txt_bg_ok
    mov r8d, 0x003355AA
.tb_txt_bg_ok:
    test qword [rbx + WIN_OFF_FLAGS], WF_MINIMIZED
    jz .tb_txt_bg_ok2
    mov r8d, 0x00222244
.tb_txt_bg_ok2:
    call render_text
.tb_skip_text:

    ; Draw X close button (small red square at right side of button)
    mov edi, r13d
    add edi, TB_CLOSE_OFF_X
    mov esi, TB_BTN_Y + 7
    mov edx, TB_CLOSE_SIZE
    mov ecx, TB_CLOSE_SIZE
    mov r8d, COLOR_CLOSE_BTN
    call render_rect

    ; Draw "X" text on close button
    mov edi, r13d
    add edi, TB_CLOSE_OFF_X + 3
    mov esi, TB_BTN_Y + 8
    mov rdx, szTbClose
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, COLOR_CLOSE_BTN
    call render_text

    ; Advance X position for next button
    add r13d, TB_BTN_W + TB_BTN_GAP

.tb_win_next:
    add rbx, WINDOW_STRUCT_SIZE
    inc r12d
    jmp .tb_win_loop

.tb_win_done:

    ; 4. Clock area
    mov rdi, CLOCK_X
    mov rsi, CLOCK_Y
    mov rdx, szTime
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, COLOR_TASKBAR_BG
    call render_text

    ; 5. Battery/power indicator
    call tb_draw_battery

    ; 6. Start menu overlay (if open)
    cmp byte [tb_start_menu_open], 0
    je .no_menu

    ; Menu background
    mov rdi, START_MENU_X
    mov rsi, START_MENU_Y
    mov rdx, START_MENU_W
    mov rcx, START_MENU_H
    mov r8d, MENU_COLOR_BG
    call render_rect

    ; Menu border (top line)
    mov rdi, START_MENU_X
    mov rsi, START_MENU_Y
    mov rdx, START_MENU_W
    mov rcx, 1
    mov r8d, 0x004466AA
    call render_rect

    ; Menu border (left line)
    mov rdi, START_MENU_X
    mov rsi, START_MENU_Y
    mov rdx, 1
    mov rcx, START_MENU_H
    mov r8d, 0x004466AA
    call render_rect

    ; Menu border (right line)
    mov rdi, START_MENU_X + START_MENU_W - 1
    mov rsi, START_MENU_Y
    mov rdx, 1
    mov rcx, START_MENU_H
    mov r8d, 0x00333366
    call render_rect

    ; --- Menu Item: File Explorer (icon + text) ---
    mov rdi, START_MENU_X + 8
    mov rsi, START_MENU_Y + 8
    mov rdx, 20
    mov rcx, 20
    mov r8d, 0x00CCAA44     ; Folder yellow
    call render_rect
    mov rdi, START_MENU_X + 36
    mov rsi, START_MENU_Y + 10
    mov rdx, szMenuExplorer
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, MENU_COLOR_BG
    call render_text

    ; --- Menu Item: Terminal ---
    mov rdi, START_MENU_X + 8
    mov rsi, START_MENU_Y + 8 + MENU_ITEM_H
    mov rdx, 20
    mov rcx, 20
    mov r8d, 0x00222222     ; Terminal dark
    call render_rect
    mov rdi, START_MENU_X + 36
    mov rsi, START_MENU_Y + 10 + MENU_ITEM_H
    mov rdx, szMenuTerm
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, MENU_COLOR_BG
    call render_text

    ; --- Menu Item: Notepad ---
    mov rdi, START_MENU_X + 8
    mov rsi, START_MENU_Y + 8 + MENU_ITEM_H * 2
    mov rdx, 20
    mov rcx, 20
    mov r8d, 0x00FFFFFF     ; White notepad
    call render_rect
    mov rdi, START_MENU_X + 36
    mov rsi, START_MENU_Y + 10 + MENU_ITEM_H * 2
    mov rdx, szMenuNotepad
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, MENU_COLOR_BG
    call render_text

    ; --- Menu Item: Settings ---
    mov rdi, START_MENU_X + 8
    mov rsi, START_MENU_Y + 8 + MENU_ITEM_H * 3
    mov rdx, 20
    mov rcx, 20
    mov r8d, 0x00888888     ; Gray gear
    call render_rect
    mov rdi, START_MENU_X + 36
    mov rsi, START_MENU_Y + 10 + MENU_ITEM_H * 3
    mov rdx, szMenuSettings
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, MENU_COLOR_BG
    call render_text

    ; --- Menu Item: Paint ---
    mov rdi, START_MENU_X + 8
    mov rsi, START_MENU_Y + 8 + MENU_ITEM_H * 4
    mov rdx, 20
    mov rcx, 20
    mov r8d, 0x00FF8800     ; Orange
    call render_rect
    mov rdi, START_MENU_X + 36
    mov rsi, START_MENU_Y + 10 + MENU_ITEM_H * 4
    mov rdx, szMenuPaint
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, MENU_COLOR_BG
    call render_text

    ; --- Separator ---
    mov rdi, START_MENU_X + 8
    mov rsi, START_MENU_Y + 8 + MENU_ITEM_H * 5
    mov rdx, START_MENU_W - 16
    mov rcx, 1
    mov r8d, 0x00555588
    call render_rect

    ; --- Menu Item: About NexusOS ---
    mov rdi, START_MENU_X + 36
    mov rsi, START_MENU_Y + 14 + MENU_ITEM_H * 5
    mov rdx, szMenuAbout
    mov ecx, COLOR_TEXT_GRAY
    mov r8d, MENU_COLOR_BG
    call render_text

.no_menu:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
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
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13

    movzx eax, byte [battery_state]
    cmp al, BAT_STATE_UNKNOWN
    jne .bat_start

    ; Unknown state: blink a red X every second or so
    mov edi, BAT_IND_X + 4
    mov esi, TASKBAR_Y + 11
    mov rdx, szNoBat
    mov ecx, 0x00FF0000        ; Red text
    mov r8d, COLOR_TASKBAR_BG
    call render_text
    jmp .bat_done

.bat_start:
    ; Clear the background area first
    mov edi, BAT_IND_X
    mov esi, BAT_IND_Y
    mov edx, BAT_IND_W
    mov ecx, BAT_IND_H
    mov r8d, COLOR_TASKBAR_BG
    call render_rect

    movzx eax, byte [battery_state]
    cmp al, BAT_STATE_AC
    je .draw_ac_only

    ; States 2 (discharging) and 3 (charging): draw battery icon
    ; Battery outline: 20x12 px at (BAT_IND_X, TASKBAR_Y+10)
    mov r12d, BAT_IND_X        ; icon X
    mov r13d, TASKBAR_Y + 10   ; icon Y

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

    ; Draw plug icon at (BAT_IND_X + BATT_ICON_W + 4, TASKBAR_Y+10)
    mov edi, BAT_IND_X + BATT_ICON_W + 4
    mov esi, TASKBAR_Y + 10
    call tb_draw_plug_icon

    ; Text X: to the right of battery + plug icons
    mov r12d, BAT_IND_X + BATT_ICON_W + PLUG_ICON_W + 10
    jmp .bat_draw_pct_text

.bat_draw_text:
    ; Just battery: text to right of battery icon
    mov r12d, BAT_IND_X + BATT_ICON_W + 4

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
    mov esi, TASKBAR_Y + 12
    lea rdx, [bat_pct_str]
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, COLOR_TASKBAR_BG
    call render_text
    jmp .bat_done

.draw_ac_only:
    ; AC only: draw plug icon + "AC" text
    mov edi, BAT_IND_X + 4
    mov esi, TASKBAR_Y + 11
    call tb_draw_plug_icon

    mov edi, BAT_IND_X + PLUG_ICON_W + 8
    mov esi, TASKBAR_Y + 12
    lea rdx, [szAC]
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, COLOR_TASKBAR_BG
    call render_text

.bat_done:
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; tb_draw_plug_icon - Draw a small pixel-art plug icon
; EDI = X (base), ESI = Y (base)  (14x14 pixels total)
; ============================================================================
tb_draw_plug_icon:
    push rbx
    push r14
    push r15
    push r8
    push rcx
    push rdx

    mov r14d, edi              ; save base X
    mov r15d, esi              ; save base Y
    mov r8d, 0x00FFDD44        ; yellow/gold

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

    pop rdx
    pop rcx
    pop r8
    pop r15
    pop r14
    pop rbx
    ret

; Handle click on taskbar / start menu
; RDI = Mouse X, RSI = Mouse Y
; Returns: RAX = 0 (not handled), 1 (handled, no app), or 2..6 (menu item 0..4 clicked)
tb_handle_click:
    push rbx
    push rcx
    push rdx
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
    cmp rsi, START_MENU_Y
    jl .close_menu
    cmp rsi, TASKBAR_Y
    jge .check_taskbar

    ; Click inside menu - determine which item
    mov rax, rsi
    sub rax, START_MENU_Y
    sub rax, 8
    cmp rax, 0
    jl .close_menu
    xor rdx, rdx
    mov rcx, MENU_ITEM_H
    div rcx

    ; Validate range
    cmp rax, MENU_ITEM_COUNT
    jge .close_menu

    ; Close menu and return item index + 2
    mov byte [tb_start_menu_open], 0
    add rax, 2
    jmp .tb_click_ret

.close_menu:
    mov byte [tb_start_menu_open], 0
    mov rax, 1
    jmp .tb_click_ret

.check_taskbar:
    ; Check if within taskbar Y range
    cmp rsi, TASKBAR_Y
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
    cmp esi, TB_BTN_Y
    jl .tb_click_next_active
    mov eax, TB_BTN_Y + TB_BTN_H
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
    push rcx
    push rdx
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
    pop rdx
    pop rcx
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
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; Handle right-click on start menu: RDI=mouseX, RSI=mouseY
; Returns RAX: 0=not handled, 1=handled
; ============================================================================
global tb_handle_rclick
tb_handle_rclick:
    push rbx
    push rcx
    push rdx

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
    cmp esi, START_MENU_Y
    jl .rc_not_handled
    cmp esi, TASKBAR_Y
    jge .rc_not_handled

    ; Right-click inside menu - determine which item
    mov eax, esi
    sub eax, START_MENU_Y
    sub eax, 8
    cmp eax, 0
    jl .rc_not_handled
    xor edx, edx
    mov ecx, MENU_ITEM_H
    div ecx

    ; Items 0-4 are apps (Explorer thru Paint), item 5 is About
    cmp eax, MENU_ITEM_COUNT
    jge .rc_not_handled

    ; Save app ID and open submenu next to the item
    add eax, 2                ; app_id = menu_index + 2
    mov byte [sm_submenu_app], al
    mov dword [sm_submenu_x], START_MENU_X + START_MENU_W + 2
    ; Y = menu item Y position
    mov ecx, eax
    sub ecx, 2
    imul ecx, MENU_ITEM_H
    add ecx, START_MENU_Y + 4
    mov [sm_submenu_y], ecx
    mov byte [sm_submenu_open], 1
    mov rax, 1
    jmp .rc_ret

.rc_not_handled:
    xor eax, eax
.rc_ret:
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; Draw start menu submenu (called from tb_draw when submenu is open)
; ============================================================================
SM_SUB_W  equ 160
SM_SUB_H  equ 26

global tb_draw_submenu
tb_draw_submenu:
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
    mov r8d, 0x004466AA
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
    mov ecx, COLOR_TEXT_WHITE
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
global tb_handle_submenu_click
tb_handle_submenu_click:
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
szMenuAbout    db "About NexusOS", 0

global tb_start_menu_open
tb_start_menu_open db 0

; Start menu submenu state
global sm_submenu_open
sm_submenu_open db 0
sm_submenu_app  db 0          ; app ID being right-clicked
sm_submenu_x    dd 0
sm_submenu_y    dd 0

szSubAdd    db "Add to Desktop", 0
szSubRemove db "Remove from Desktop", 0
bat_pct_str times 8 db 0      ; "100%" + null, with room
