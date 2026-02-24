; ============================================================================
; NexusOS v3.0 - Window Manager
; ============================================================================
bits 64

%include "constants.inc"

; Window structure layout (256 bytes per window, qword fields):
;   0: ID          8: X           16: Y          24: Width
;  32: Height     40: Flags       48: Title (64 bytes inline)
; 112: draw_fn   120: key_fn     128: click_fn   136: app_data

WIN_OFF_ID      equ 0
WIN_OFF_X       equ 8
WIN_OFF_Y       equ 16
WIN_OFF_W       equ 24
WIN_OFF_H       equ 32
WIN_OFF_FLAGS   equ 40
WIN_OFF_TITLE   equ 48
WIN_OFF_DRAWFN  equ 112
WIN_OFF_KEYFN   equ 120
WIN_OFF_CLICKFN equ 128
WIN_OFF_APPDATA equ 136

section .text
global wm_init
global wm_create_window
global wm_create_window_ex
global wm_draw_window
global wm_draw_desktop
global wm_handle_mouse_event
global wm_get_window_at
global wm_close_window
global wm_window_count
global wm_focused_window
global wm_drag_window_id

extern render_rect
extern render_text
extern render_line
extern render_get_backbuffer
extern render_mark_dirty
extern render_save_backbuffer
extern memcpy
extern cursor_mode

wm_init:
    ; Zero out window pool
    mov rdi, WINDOW_POOL_ADDR
    mov rcx, MAX_WINDOWS * WINDOW_STRUCT_SIZE
    xor rax, rax
    rep stosb
    mov qword [wm_window_count], 0
    mov qword [wm_drag_window_id], -1
    mov qword [wm_focused_window], -1
    ret

; Create window (simple): RDI=title, RSI=x, RDX=y, RCX=w, R8=h
; Returns RAX = window ID (-1 on fail)
wm_create_window:
    push r9
    xor r9, r9          ; draw_fn = NULL (default content)
    call wm_do_create
    pop r9
    ret

; Create window (extended): RDI=title, RSI=x, RDX=y, RCX=w, R8=h, R9=draw_fn
; [rsp+8]=app_data after call (or set after via returned ID)
; Returns RAX = window ID (-1 on fail)
wm_create_window_ex:
    call wm_do_create
    ret

wm_do_create:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Save args
    mov r12, rdi         ; title
    mov r13, rsi         ; x
    mov r14, rdx         ; y
    mov r15, rcx         ; w
    ; r8 = h, r9 = draw_fn already in regs

    cmp qword [wm_window_count], MAX_WINDOWS
    jge .fail

    ; Unfocus all existing windows
    push r8
    push r9
    mov rbx, WINDOW_POOL_ADDR
    xor ecx, ecx
.unfocus_loop:
    cmp ecx, MAX_WINDOWS
    je .unfocus_done
    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .unfocus_next
    and qword [rbx + WIN_OFF_FLAGS], ~WF_FOCUSED
.unfocus_next:
    add rbx, WINDOW_STRUCT_SIZE
    inc ecx
    jmp .unfocus_loop
.unfocus_done:
    pop r9
    pop r8

    ; Find free slot
    mov rbx, WINDOW_POOL_ADDR
    xor ecx, ecx
.find_loop:
    cmp ecx, MAX_WINDOWS
    je .fail
    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .found_slot
    add rbx, WINDOW_STRUCT_SIZE
    inc ecx
    jmp .find_loop

.found_slot:
    ; Zero entire slot first
    push rcx
    push rdi
    push r8
    push r9
    mov rdi, rbx
    xor eax, eax
    mov ecx, WINDOW_STRUCT_SIZE
    rep stosb
    pop r9
    pop r8
    pop rdi
    pop rcx

    ; ecx = slot index, rbx = ptr
    mov qword [rbx + WIN_OFF_ID], rcx
    mov [rbx + WIN_OFF_X], r13
    mov [rbx + WIN_OFF_Y], r14
    mov [rbx + WIN_OFF_W], r15
    mov [rbx + WIN_OFF_H], r8

    ; Flags = Active | Visible | Focused
    mov rax, WF_VISIBLE | WF_ACTIVE | WF_FOCUSED
    mov [rbx + WIN_OFF_FLAGS], rax

    ; Copy title (up to 63 chars)
    push rsi
    push rdi
    mov rsi, r12
    lea rdi, [rbx + WIN_OFF_TITLE]
    mov eax, 63
.copy_title:
    test eax, eax
    jz .title_done
    lodsb
    stosb
    test al, al
    jz .title_null
    dec eax
    jmp .copy_title
.title_null:
.title_done:
    mov byte [rdi], 0
    pop rdi
    pop rsi

    ; Set draw callback
    mov [rbx + WIN_OFF_DRAWFN], r9

    ; Update globals
    movzx eax, cx
    mov [wm_focused_window], rax
    inc qword [wm_window_count]

    mov rax, rcx         ; Return window ID
    jmp .done

.fail:
    mov rax, -1
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Close window by ID: RDI = window ID
wm_close_window:
    cmp rdi, MAX_WINDOWS
    jge .close_ret
    push rax
    push rbx
    mov rax, rdi
    mov rbx, WINDOW_STRUCT_SIZE
    imul rax, rbx
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_FLAGS], 0   ; Clear all flags (inactive)
    dec qword [wm_window_count]
    ; If this was focused, clear focus
    cmp [wm_focused_window], rdi
    jne .close_nofocus
    mov qword [wm_focused_window], -1
.close_nofocus:
    pop rbx
    pop rax
.close_ret:
    ret

; Draw all windows (painter's algorithm)
wm_draw_desktop:
    push rbx
    push r12

    ; 1. Desktop background
    mov rdi, 0
    mov rsi, 0
    mov rdx, SCREEN_WIDTH
    mov rcx, SCREEN_HEIGHT
    mov r8, COLOR_DESKTOP_BG
    call render_rect

    ; 2. Draw non-focused windows first, then focused
    ; Pass 1: non-focused
    mov rbx, WINDOW_POOL_ADDR
    xor r12d, r12d
.draw_nf:
    cmp r12d, MAX_WINDOWS
    je .draw_focused_pass
    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .next_nf
    test qword [rbx + WIN_OFF_FLAGS], WF_VISIBLE
    jz .next_nf
    test qword [rbx + WIN_OFF_FLAGS], WF_MINIMIZED
    jnz .next_nf
    test qword [rbx + WIN_OFF_FLAGS], WF_FOCUSED
    jnz .next_nf
    mov rdi, r12
    call wm_draw_window
.next_nf:
    add rbx, WINDOW_STRUCT_SIZE
    inc r12d
    jmp .draw_nf

    ; Pass 2: focused window on top
.draw_focused_pass:
    mov rax, [wm_focused_window]
    cmp rax, -1
    je .draw_done
    cmp rax, MAX_WINDOWS
    jge .draw_done
    ; Check it's active+visible
    mov rbx, rax
    imul rbx, WINDOW_STRUCT_SIZE
    add rbx, WINDOW_POOL_ADDR
    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .draw_done
    test qword [rbx + WIN_OFF_FLAGS], WF_VISIBLE
    jz .draw_done
    test qword [rbx + WIN_OFF_FLAGS], WF_MINIMIZED
    jnz .draw_done
    mov rdi, rax
    call wm_draw_window

.draw_done:
    pop r12
    pop rbx
    ret

; Draw a specific window: RDI = window ID
wm_draw_window:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Calculate struct pointer
    mov rax, rdi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov rbx, rax

    ; Load dimensions
    mov r12, [rbx + WIN_OFF_X]
    mov r13, [rbx + WIN_OFF_Y]
    mov r14, [rbx + WIN_OFF_W]
    mov r15, [rbx + WIN_OFF_H]

    ; --- Shadow ---
    mov rdi, r12
    add rdi, 3
    mov rsi, r13
    add rsi, 3
    mov rdx, r14
    mov rcx, r15
    mov r8d, 0x00181818
    call render_rect

    ; --- Outer border ---
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8d, COLOR_WINDOW_BORDER
    call render_rect

    ; --- Client area ---
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov rcx, r15
    sub rcx, TITLEBAR_HEIGHT
    sub rcx, BORDER_WIDTH
    ; Clamp to at least 0
    cmp rcx, 0
    jle .skip_client
    cmp rdx, 0
    jle .skip_client
    mov r8d, COLOR_WINDOW_BG
    call render_rect
.skip_client:

    ; --- Title bar ---
    mov rdi, r12
    add rdi, BORDER_WIDTH
    mov rsi, r13
    add rsi, BORDER_WIDTH
    mov rdx, r14
    sub rdx, BORDER_WIDTH * 2
    mov ecx, TITLEBAR_HEIGHT - BORDER_WIDTH
    mov rax, [rbx + WIN_OFF_FLAGS]
    test rax, WF_FOCUSED
    jnz .tb_focused
    mov r8d, COLOR_TITLEBAR_UNF
    jmp .tb_draw
.tb_focused:
    mov r8d, COLOR_TITLEBAR
.tb_draw:
    call render_rect

    ; --- Title text ---
    mov rdi, r12
    add rdi, 8
    mov rsi, r13
    add rsi, 5
    lea rdx, [rbx + WIN_OFF_TITLE]
    mov ecx, COLOR_TEXT_WHITE
    ; bg = titlebar color
    mov rax, [rbx + WIN_OFF_FLAGS]
    test rax, WF_FOCUSED
    jnz .tt_focused
    mov r8d, COLOR_TITLEBAR_UNF
    jmp .tt_draw
.tt_focused:
    mov r8d, COLOR_TITLEBAR
.tt_draw:
    call render_text

    ; --- Close button [X] ---
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE + 4
    mov rsi, r13
    add rsi, 4
    mov edx, CLOSE_BTN_SIZE
    mov ecx, CLOSE_BTN_SIZE
    mov r8d, COLOR_CLOSE_BTN
    call render_rect

    ; Close X label
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE + 1
    mov rsi, r13
    add rsi, 5
    mov rdx, szCloseX
    mov ecx, COLOR_TEXT_WHITE
    mov r8d, COLOR_CLOSE_BTN
    call render_text

    ; --- Minimize button [-] ---
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE * 2 + 8
    mov rsi, r13
    add rsi, 4
    mov edx, MIN_BTN_SIZE
    mov ecx, MIN_BTN_SIZE
    mov r8d, COLOR_MIN_BTN
    call render_rect

    ; Min label
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE * 2 + 5
    mov rsi, r13
    add rsi, 5
    mov rdx, szMinDash
    mov ecx, COLOR_TEXT_BLACK
    mov r8d, COLOR_MIN_BTN
    call render_text

    ; --- App content ---
    ; Call draw_fn if set, else default content
    mov rax, [rbx + WIN_OFF_DRAWFN]
    test rax, rax
    jz .default_content

    ; Call app draw: rdi = window struct ptr
    mov rdi, rbx
    call rax
    jmp .content_done

.default_content:
    ; Default: show "Empty Window"
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 8
    mov rdx, szEmptyWin
    mov ecx, 0x00888888
    mov r8d, COLOR_WINDOW_BG
    call render_text

.content_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Handle mouse input: RDI=mouseX, RSI=mouseY, RDX=buttons
wm_handle_mouse_event:
    push r12
    push r13
    push r14
    push rbx

    mov r12, rdi         ; mouseX
    mov r13, rsi         ; mouseY
    mov r14, rdx         ; buttons

    ; If dragging, handle drag (hold-and-release mode)
    cmp qword [wm_drag_window_id], -1
    jne .dragging

    ; Need left button down to start anything
    test r14, 1
    jz .mouse_done

    ; Find window under cursor
    mov rdi, r12
    mov rsi, r13
    call wm_get_window_at
    cmp rax, -1
    je .desktop_click

    ; Got window ID in rax
    mov rbx, rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    ; rax = window struct ptr, rbx = window ID

    ; Check close button hit
    mov r8, [rax + WIN_OFF_X]
    add r8, [rax + WIN_OFF_W]
    sub r8, CLOSE_BTN_SIZE + 4
    mov r9, [rax + WIN_OFF_Y]
    add r9, 4
    cmp r12, r8
    jl .not_close
    mov r10, r8
    add r10, CLOSE_BTN_SIZE
    cmp r12, r10
    jg .not_close
    cmp r13, r9
    jl .not_close
    mov r10, r9
    add r10, CLOSE_BTN_SIZE
    cmp r13, r10
    jg .not_close
    ; Close this window
    mov rdi, rbx
    call wm_close_window
    jmp .mouse_done

.not_close:
    ; Check minimize button hit
    mov r8, [rax + WIN_OFF_X]
    add r8, [rax + WIN_OFF_W]
    sub r8, CLOSE_BTN_SIZE * 2 + 8
    mov r9, [rax + WIN_OFF_Y]
    add r9, 4
    cmp r12, r8
    jl .not_minimize
    mov r10, r8
    add r10, MIN_BTN_SIZE
    cmp r12, r10
    jg .not_minimize
    cmp r13, r9
    jl .not_minimize
    mov r10, r9
    add r10, MIN_BTN_SIZE
    cmp r13, r10
    jg .not_minimize
    ; Minimize
    or qword [rax + WIN_OFF_FLAGS], WF_MINIMIZED
    and qword [rax + WIN_OFF_FLAGS], ~WF_VISIBLE
    jmp .mouse_done

.not_minimize:
    ; Check titlebar for drag
    mov r8, [rax + WIN_OFF_Y]
    mov r9, r13
    sub r9, r8           ; relative Y
    cmp r9, TITLEBAR_HEIGHT
    jg .client_click

    ; Start drag (hold-and-release mode)
    mov [wm_drag_window_id], rbx
    mov r8, [rax + WIN_OFF_X]
    mov r10, r12
    sub r10, r8
    mov [wm_drag_off_x], r10
    mov [wm_drag_off_y], r9
    ; Initialize preview at current window position
    mov r8, [rax + WIN_OFF_X]
    mov [wm_drag_preview_x], r8
    mov r8, [rax + WIN_OFF_Y]
    mov [wm_drag_preview_y], r8
    mov r8, [rax + WIN_OFF_W]
    mov [wm_drag_preview_w], r8
    mov r8, [rax + WIN_OFF_H]
    mov [wm_drag_preview_h], r8
    ; Set move cursor
    mov byte [cursor_mode], 1
    
    ; Save clean desktop state for smooth dragging
    call render_save_backbuffer
    
    jmp .set_focus

.client_click:
    ; Check if app has click_fn
    mov r8, [rax + WIN_OFF_CLICKFN]
    test r8, r8
    jz .set_focus
    ; Call click_fn(window_ptr, mouseX_rel, mouseY_rel)
    push rax
    mov rdi, rax         ; window ptr
    mov rsi, r12
    sub rsi, [rax + WIN_OFF_X]
    sub rsi, BORDER_WIDTH
    mov rdx, r13
    sub rdx, [rax + WIN_OFF_Y]
    sub rdx, TITLEBAR_HEIGHT
    call r8
    pop rax

.set_focus:
    ; Unfocus all, focus this one
    push rcx
    push rbx
    mov rcx, WINDOW_POOL_ADDR
    xor edx, edx
.focus_loop:
    cmp edx, MAX_WINDOWS
    je .focus_done
    and qword [rcx + WIN_OFF_FLAGS], ~WF_FOCUSED
    add rcx, WINDOW_STRUCT_SIZE
    inc edx
    jmp .focus_loop
.focus_done:
    pop rbx
    pop rcx
    ; rbx = window ID, recompute ptr
    mov rax, rbx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    or qword [rax + WIN_OFF_FLAGS], WF_FOCUSED
    mov [wm_focused_window], rbx
    jmp .mouse_done

.desktop_click:
    mov qword [wm_focused_window], -1
    jmp .mouse_done

.dragging:
    mov rbx, [wm_drag_window_id]
    cmp rbx, -1
    je .stop_drag

    ; Button released? -> drop the window
    test r14, 1
    jz .stop_drag

    ; Calculate new position
    mov r8, r12
    sub r8, [wm_drag_off_x]
    mov r9, r13
    sub r9, [wm_drag_off_y]
    ; Clamp Y
    cmp r9, -10
    jge .drag_clamp_ok
    mov r9, -10
.drag_clamp_ok:
    ; Mark OLD position edges as dirty (to erase/restore)
    push r8
    push r9
    push r10
    push r11
    mov r8, [wm_drag_preview_x]
    mov r9, [wm_drag_preview_y]
    mov r10, [wm_drag_preview_w]
    mov r11, [wm_drag_preview_h]
    call wm_mark_outline_dirty
    pop r11
    pop r10
    pop r9
    pop r8

    mov [wm_drag_preview_x], r8
    mov [wm_drag_preview_y], r9
    
    ; Mark NEW position edges as dirty (to draw)
    push r8
    push r9
    push r10
    push r11
    ; r8=newX, r9=newY
    mov r10, [wm_drag_preview_w]
    mov r11, [wm_drag_preview_h]
    call wm_mark_outline_dirty
    pop r11
    pop r10
    pop r9
    pop r8

    ; Update window position immediately
    mov rax, rbx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov [rax + WIN_OFF_X], r8
    mov [rax + WIN_OFF_Y], r9

    jmp .mouse_done       ; Button still down -> continue dragging

.stop_drag:
    ; Drop: release the window at current position
    mov qword [wm_drag_window_id], -1
    mov byte [cursor_mode], 0
    mov eax, 1
    jmp .mouse_ret


.mouse_done:
    xor eax, eax               ; return 0 = not handled / no drag active
    cmp qword [wm_drag_window_id], -1
    je .mouse_ret
    mov eax, 1                  ; return 1 = drag is active, skip other handlers
.mouse_ret:
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

; Draw drag outline (called from main loop when dragging)
; Uses wm_drag_preview_x/y/w/h to draw a 2px rectangle outline
global wm_draw_drag_outline
wm_draw_drag_outline:
    cmp qword [wm_drag_window_id], -1
    je .outline_ret

    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, [wm_drag_preview_x]    ; x
    mov r13, [wm_drag_preview_y]    ; y
    mov r14, [wm_drag_preview_w]    ; w
    mov r15, [wm_drag_preview_h]    ; h

    ; Top edge: full width, 2px tall
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, 2
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    ; Bottom edge
    mov edi, r12d
    mov esi, r13d
    add esi, r15d
    sub esi, 2
    mov edx, r14d
    mov ecx, 2
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    ; Left edge
    mov edi, r12d
    mov esi, r13d
    mov edx, 2
    mov ecx, r15d
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    ; Right edge
    mov edi, r12d
    add edi, r14d
    sub edi, 2
    mov esi, r13d
    mov edx, 2
    mov ecx, r15d
    mov r8d, COLOR_HIGHLIGHT
    call render_rect

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.outline_ret:
    ret

wm_mark_outline_dirty:
    ; Args: R8=x, R9=y, R10=w, R11=h
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    
    ; Top
    mov edi, r8d
    mov esi, r9d
    mov edx, r10d
    mov ecx, 2
    call render_mark_dirty
    
    ; Bottom
    mov edi, r8d
    mov esi, r9d
    add esi, r11d
    sub esi, 2
    mov edx, r10d
    mov ecx, 2
    call render_mark_dirty
    
    ; Left
    mov edi, r8d
    mov esi, r9d
    mov edx, 2
    mov ecx, r11d
    call render_mark_dirty
    
    ; Right
    mov edi, r8d
    add edi, r10d
    sub edi, 2
    mov esi, r9d
    mov edx, 2
    mov ecx, r11d
    call render_mark_dirty

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Find topmost window at (X, Y): RDI=x, RSI=y -> RAX=window ID or -1
wm_get_window_at:
    push r12
    push r8
    push r9

    ; Check focused window first (it's drawn on top)
    mov rax, [wm_focused_window]
    cmp rax, -1
    je .scan_all
    cmp rax, MAX_WINDOWS
    jge .scan_all
    mov r12, rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .scan_all
    test qword [rax + WIN_OFF_FLAGS], WF_VISIBLE
    jz .scan_all
    ; Bounds check
    mov r8, [rax + WIN_OFF_X]
    cmp rdi, r8
    jl .scan_all
    add r8, [rax + WIN_OFF_W]
    cmp rdi, r8
    jge .scan_all
    mov r9, [rax + WIN_OFF_Y]
    cmp rsi, r9
    jl .scan_all
    add r9, [rax + WIN_OFF_H]
    cmp rsi, r9
    jge .scan_all
    mov rax, r12
    jmp .found

.scan_all:
    mov r12, MAX_WINDOWS
    dec r12
.check_loop:
    cmp r12, 0
    jl .not_found
    mov rax, r12
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .continue
    test qword [rax + WIN_OFF_FLAGS], WF_VISIBLE
    jz .continue
    ; Bounds
    mov r8, [rax + WIN_OFF_X]
    cmp rdi, r8
    jl .continue
    add r8, [rax + WIN_OFF_W]
    cmp rdi, r8
    jge .continue
    mov r9, [rax + WIN_OFF_Y]
    cmp rsi, r9
    jl .continue
    add r9, [rax + WIN_OFF_H]
    cmp rsi, r9
    jge .continue
    mov rax, r12
    jmp .found
.continue:
    dec r12
    jmp .check_loop

.not_found:
    mov rax, -1
.found:
    pop r9
    pop r8
    pop r12
    ret

section .data
szCloseX      db "X", 0
szMinDash     db "-", 0
szEmptyWin    db "Empty Window", 0

global wm_window_count
global wm_focused_window
wm_window_count   dq 0
wm_focused_window dq -1
wm_drag_window_id dq -1
wm_drag_off_x     dq 0
wm_drag_off_y     dq 0
global wm_drag_preview_x
global wm_drag_preview_y
global wm_drag_preview_w
global wm_drag_preview_h
wm_drag_preview_x dq 0          ; outline X position
wm_drag_preview_y dq 0          ; outline Y position
wm_drag_preview_w dq 0          ; outline width
wm_drag_preview_h dq 0          ; outline height
