; ============================================================================
; Grit v3.0 - Desktop Environment
; Data-driven icons with add/remove support
; ============================================================================
bits 64

%include "constants.inc"

; Icon layout
ICON_SIZE       equ 48
ICON_STRIDE     equ 84         ; vertical spacing per icon (48 + 20 gap + 16 label)
ICON_X          equ 24
ICON_BASE_Y     equ 24
ICON_HIT_X      equ 20
ICON_HIT_W      equ 96
MAX_DESK_ICONS  equ 8

section .text
global desktop_draw_icons
global desktop_handle_click
global desktop_has_icon
global desktop_add_icon
global desktop_remove_icon
global desktop_icons

extern render_rect
extern render_text
extern nx_icon_blit
extern app_launch
extern tb_start_menu_open
extern nx_icon_about_48
extern nx_icon_explorer_48
extern nx_icon_notepad_48
extern nx_icon_paint_48
extern nx_icon_settings_48
extern nx_icon_taskmgr_48
extern nx_icon_terminal_48

; ============================================================================
; Draw all desktop icons from the icon table
; ============================================================================
desktop_draw_icons:
    push rbx
    push r12
    push r13
    push r14

    xor r12d, r12d           ; slot index
    mov r14d, ICON_BASE_Y    ; current Y position

.draw_loop:
    cmp r12d, MAX_DESK_ICONS
    jge .draw_done

    movzx eax, byte [desktop_icons + r12]
    test al, al
    jz .draw_next             ; empty slot

    ; al = app ID. Look up icon info.
    mov r13d, eax             ; save app ID
    lea rbx, [icon_table]
    ; index = app_id - 2 (apps start at ID 2)
    sub eax, 2
    js .draw_next
    cmp eax, 8
    jge .draw_next
    imul eax, eax, 16        ; 16 bytes per entry: label_ptr + icon_ptr
    add rbx, rax

    ; Draw design-system 48px icon.
    mov rdi, [rbx + 8]
    mov rsi, ICON_X
    mov rdx, r14
    call nx_icon_blit

.draw_label:
    ; Draw label below icon with a small shadow so it remains readable over
    ; both dark and light SVG wallpapers.
    mov rdi, ICON_X
    lea esi, [r14d + ICON_SIZE + 4]
    mov rdx, [rbx]           ; label string pointer
    mov ecx, COLOR_BLACK
    mov r8d, -1               ; transparent bg
    call render_text
    mov edi, ICON_X - 1
    lea esi, [r14d + ICON_SIZE + 3]
    mov rdx, [rbx]
    mov ecx, COLOR_WHITE
    mov r8d, -1
    call render_text

.draw_next:
    inc r12d
    add r14d, ICON_STRIDE
    jmp .draw_loop

.draw_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; Handle desktop clicks: RDI=mouseX, RSI=mouseY
; Returns RAX: 0=not handled, 1=handled
; ============================================================================
desktop_handle_click:
    push rbx
    push r12
    push r13

    ; Close start menu
    mov byte [tb_start_menu_open], 0

    ; Accept clicks on the icon and its label, not just the 48px icon box.
    cmp edi, ICON_HIT_X
    jl .click_none
    cmp edi, ICON_HIT_X + ICON_HIT_W
    jg .click_none

    ; Find which icon slot
    xor r12d, r12d
    mov r13d, ICON_BASE_Y

.click_loop:
    cmp r12d, MAX_DESK_ICONS
    jge .click_none

    movzx eax, byte [desktop_icons + r12]
    test al, al
    jz .click_next

    ; Check Y range (icon + label area)
    cmp esi, r13d
    jl .click_next
    lea ecx, [r13d + ICON_SIZE + 20]
    cmp esi, ecx
    jg .click_next

    ; Hit! Launch this app
    movzx edi, byte [desktop_icons + r12]
    call app_launch
    mov rax, 1
    jmp .click_ret

.click_next:
    inc r12d
    add r13d, ICON_STRIDE
    jmp .click_loop

.click_none:
    xor eax, eax
.click_ret:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; desktop_has_icon: EDI=app_id -> EAX=1 if on desktop, 0 if not
; ============================================================================
desktop_has_icon:
    xor ecx, ecx
.has_loop:
    cmp ecx, MAX_DESK_ICONS
    jge .has_no
    cmp byte [desktop_icons + rcx], dil
    je .has_yes
    inc ecx
    jmp .has_loop
.has_yes:
    mov eax, 1
    ret
.has_no:
    xor eax, eax
    ret

; ============================================================================
; desktop_add_icon: EDI=app_id -> adds to first empty slot
; ============================================================================
desktop_add_icon:
    ; First check if already present
    push rdi
    call desktop_has_icon
    pop rdi
    test eax, eax
    jnz .add_done             ; already there

    xor ecx, ecx
.add_loop:
    cmp ecx, MAX_DESK_ICONS
    jge .add_done             ; no room
    cmp byte [desktop_icons + rcx], 0
    je .add_found
    inc ecx
    jmp .add_loop
.add_found:
    mov byte [desktop_icons + rcx], dil
.add_done:
    ret

; ============================================================================
; desktop_remove_icon: EDI=app_id -> removes from desktop
; ============================================================================
desktop_remove_icon:
    xor ecx, ecx
.rem_loop:
    cmp ecx, MAX_DESK_ICONS
    jge .rem_done
    cmp byte [desktop_icons + rcx], dil
    je .rem_found
    inc ecx
    jmp .rem_loop
.rem_found:
    mov byte [desktop_icons + rcx], 0
    ; Compact: shift remaining entries down
    lea edx, [ecx + 1]
.compact:
    cmp edx, MAX_DESK_ICONS
    jge .compact_zero
    movzx eax, byte [desktop_icons + rdx]
    mov byte [desktop_icons + rcx], al
    mov byte [desktop_icons + rdx], 0
    inc ecx
    inc edx
    jmp .compact
.compact_zero:
    mov byte [desktop_icons + rcx], 0
.rem_done:
    ret

; ============================================================================
; Data
; ============================================================================
section .data

; Desktop icon table: up to MAX_DESK_ICONS app IDs (0=empty)
; Default: Explorer(2), Terminal(3), Notepad(4), Task Manager(9), Ping(10)
desktop_icons:
    db 2, 3, 4, 9, 10, 0, 0, 0

; Icon info table: indexed by (app_id - 2), 16 bytes each
; Format: dq label_ptr, dq icon48_ptr
icon_table:
    ; App 2: File Explorer
    dq szMyPC
    dq nx_icon_explorer_48
    ; App 3: Terminal
    dq szTerminal
    dq nx_icon_terminal_48
    ; App 4: Notepad
    dq szNotepad
    dq nx_icon_notepad_48
    ; App 5: Settings
    dq szSettings
    dq nx_icon_settings_48
    ; App 6: Paint
    dq szPaint
    dq nx_icon_paint_48
    ; App 7: About
    dq szAbout
    dq nx_icon_about_48
    ; App 8: Security Probe (not shown on desktop; slot kept for indexing)
    dq szAbout
    dq nx_icon_about_48
    ; App 9: Task Manager
    dq szTaskMgr
    dq nx_icon_taskmgr_48
    ; App 10: Ping
    dq szPing
    dq nx_icon_terminal_48

szMyPC       db "My PC", 0
szTerminal   db "Terminal", 0
szNotepad    db "Notepad", 0
szSettings   db "Settings", 0
szPaint      db "Paint", 0
szAbout      db "About", 0
szTaskMgr    db "Task Mgr", 0
szPing       db "Network", 0

section .text
