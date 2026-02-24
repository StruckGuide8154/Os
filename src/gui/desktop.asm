; ============================================================================
; NexusOS v3.0 - Desktop Environment
; Data-driven icons with add/remove support
; ============================================================================
bits 64

%include "constants.inc"

; Icon layout
ICON_SIZE       equ 48
ICON_STRIDE     equ 84         ; vertical spacing per icon (48 + 20 gap + 16 label)
ICON_X          equ 24
ICON_BASE_Y     equ 24
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
extern app_launch
extern tb_start_menu_open

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
    cmp eax, 6
    jge .draw_next
    imul eax, eax, 20        ; 20 bytes per entry: 4 color + 8 label_ptr + 4 detail_color + 4 pad
    add rbx, rax

    ; Draw icon background
    mov rdi, ICON_X
    mov rsi, r14
    mov rdx, ICON_SIZE
    mov rcx, ICON_SIZE
    mov r8d, [rbx]            ; icon color
    call render_rect

    ; Draw icon detail based on app type
    cmp r13d, 2
    je .detail_explorer
    cmp r13d, 3
    je .detail_terminal
    cmp r13d, 4
    je .detail_notepad
    cmp r13d, 5
    je .detail_settings
    cmp r13d, 6
    je .detail_paint
    jmp .draw_label

.detail_explorer:
    ; Folder tab
    mov rdi, ICON_X
    mov rsi, r14
    mov rdx, 20
    mov rcx, 8
    mov r8d, 0x00AA8822
    call render_rect
    jmp .draw_label

.detail_terminal:
    ; Green prompt ">_"
    mov rdi, ICON_X + 8
    lea esi, [r14d + 16]
    mov rdx, szPromptIcon
    mov ecx, 0x0000FF00
    mov r8d, 0x00222222
    call render_text
    jmp .draw_label

.detail_notepad:
    ; Lines on notepad
    mov rdi, ICON_X + 8
    lea esi, [r14d + 12]
    mov rdx, 32
    mov rcx, 2
    mov r8d, 0x00CCCCCC
    call render_rect
    mov rdi, ICON_X + 8
    lea esi, [r14d + 20]
    mov rdx, 28
    mov rcx, 2
    mov r8d, 0x00CCCCCC
    call render_rect
    mov rdi, ICON_X + 8
    lea esi, [r14d + 28]
    mov rdx, 32
    mov rcx, 2
    mov r8d, 0x00CCCCCC
    call render_rect
    jmp .draw_label

.detail_settings:
    ; Gear-like crosshair
    mov rdi, ICON_X + 20
    lea esi, [r14d + 8]
    mov rdx, 8
    mov rcx, 32
    mov r8d, 0x00AAAAAA
    call render_rect
    mov rdi, ICON_X + 8
    lea esi, [r14d + 20]
    mov rdx, 32
    mov rcx, 8
    mov r8d, 0x00AAAAAA
    call render_rect
    jmp .draw_label

.detail_paint:
    ; Color swatch
    mov rdi, ICON_X + 8
    lea esi, [r14d + 8]
    mov rdx, 14
    mov rcx, 14
    mov r8d, 0x00FF0000
    call render_rect
    mov rdi, ICON_X + 26
    lea esi, [r14d + 8]
    mov rdx, 14
    mov rcx, 14
    mov r8d, 0x000000FF
    call render_rect
    mov rdi, ICON_X + 8
    lea esi, [r14d + 26]
    mov rdx, 14
    mov rcx, 14
    mov r8d, 0x0000FF00
    call render_rect
    mov rdi, ICON_X + 26
    lea esi, [r14d + 26]
    mov rdx, 14
    mov rcx, 14
    mov r8d, 0x00FFFF00
    call render_rect
    jmp .draw_label

.draw_label:
    ; Draw label below icon
    mov rdi, ICON_X
    lea esi, [r14d + ICON_SIZE + 4]
    mov rdx, [rbx + 4]       ; label string pointer
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, -1               ; transparent bg
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

    ; Check if click is in icon column
    cmp edi, ICON_X
    jl .click_none
    cmp edi, ICON_X + ICON_SIZE
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
; Default: Explorer(2), Terminal(3), Notepad(4)
desktop_icons:
    db 2, 3, 4, 0, 0, 0, 0, 0

; Icon info table: indexed by (app_id - 2), 20 bytes each
; Format: dd color, dq label_ptr, dd 0 (pad)
icon_table:
    ; App 2: File Explorer
    dd 0x00CCAA44
    dq szMyPC
    dd 0
    dd 0
    ; App 3: Terminal
    dd 0x00222222
    dq szTerminal
    dd 0
    dd 0
    ; App 4: Notepad
    dd 0x00FFFFFF
    dq szNotepad
    dd 0
    dd 0
    ; App 5: Settings
    dd 0x00888888
    dq szSettings
    dd 0
    dd 0
    ; App 6: Paint
    dd 0x00FF8800
    dq szPaint
    dd 0
    dd 0
    ; App 7: About
    dd 0x00335577
    dq szAbout
    dd 0
    dd 0

szMyPC       db "My PC", 0
szTerminal   db "Terminal", 0
szNotepad    db "Notepad", 0
szSettings   db "Settings", 0
szPaint      db "Paint", 0
szAbout      db "About", 0
szPromptIcon db ">_", 0
