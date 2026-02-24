; ============================================================================
; NexusOS v3.0 - Kernel Main (Free-running render loop)
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

; Serial char macro for debugging
%macro SER 1
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, %1
    out dx, al
    pop rdx
    pop rax
%endmacro

section .text
global kmain

; Kernel
extern idt_init
extern pic_init
extern pit_init
extern acpi_init
extern apic_init
extern ioapic_init
extern spi_init
extern spi_hid_init
extern acpi_pci_init

; Drivers
; Drivers
extern mouse_init
extern usb_hid_init
extern i2c_hid_init
extern i2c_hid_poll
extern battery_init
extern battery_poll
extern keyboard_init
extern display_init
extern mouse_check_moved
extern mouse_x
extern mouse_y
extern mouse_buttons
extern mouse_moved
extern usb_poll_mouse
extern keyboard_read
extern keyboard_repeat_tick
extern keyboard_available
extern kb_numlock

extern frame_count
extern start_tick
extern last_fps
extern fps_show
extern tick_count
extern uint32_to_str
extern render_text


; GUI
extern wm_init
extern render_init
extern cursor_init
extern wm_create_window
extern wm_create_window_ex
extern wm_draw_desktop
extern wm_draw_window
extern desktop_draw_icons
extern tb_draw
extern cursor_draw
extern cursor_hide
extern render_flush
extern render_mark_full
extern wm_handle_mouse_event
extern wm_close_window
extern tb_handle_click
extern desktop_handle_click
extern wm_focused_window
extern wm_window_count
extern wm_draw_drag_outline
extern wm_drag_window_id
extern render_restore_backbuffer
extern render_mark_dirty
extern render_save_backbuffer
extern display_flip_rect
extern bb_addr
extern scr_pitch

; Filesystem
extern fat16_init

; Apps
extern app_launch
extern app_show_context_menu
extern ctx_menu_visible

; Start menu submenu
extern tb_handle_rclick
extern tb_draw_submenu
extern tb_handle_submenu_click
extern sm_submenu_open

; Window struct offsets (must match window.asm)
WIN_OFF_FLAGS   equ 40
WIN_OFF_KEYFN   equ 120
WIN_OFF_APPDATA equ 136

; FPS overlay region (small rect that gets updated each frame)
FPS_REGION_X    equ 8
FPS_REGION_Y    equ 8
FPS_REGION_W    equ 112      ; Covers "FPS: XXXXX" (14 chars * 8px)
FPS_REGION_H    equ 20       ; 16px font height + 4px padding

extern fill_rect

; Debug logging variables
section .data
debug_y: dd 40

section .text

; debug_print - Helper to print string to screen AND serial
; RSI = string pointer
global debug_print
debug_print:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    
    ; --- Serial Output (0x3F8) ---
    mov rdx, rsi
.serial_loop:
    movzx eax, byte [rdx]
    test al, al
    jz .serial_done
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    inc rdx
    jmp .serial_loop
.serial_done:
    ; Newline for serial
    mov dx, 0x3F8
    mov al, 13
    out dx, al
    mov al, 10
    out dx, al

    ; --- Screen Output ---
    ; Check if display is initialized (bb_addr != 0)
    mov rax, [bb_addr]
    test rax, rax
    jz .done
    
    ; Draw background bar for text
    mov edi, 0
    mov esi, [debug_y]
    mov edx, 800
    mov ecx, 16
    mov r8d, 0x00000000
    call fill_rect
    
    ; Draw text
    mov edi, 10
    mov esi, [debug_y]
    mov rdx, rsi     ; string was in RSI
    mov ecx, 0x0000FF00 ; Green text
    mov r8d, 0x00000000 ; Black bg
    call render_text

    ; Advance Y
    add dword [debug_y], 16
    ; NOTE: No display_flip here - avoid 1fps flicker during init.
    ; Serial output (above) captures all debug messages.

.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

kmain:
    ; Init display immediately - replaces UEFI white screen with black
    call display_init
    call display_flip
    SER 'A'

    ; 1. Initialize Hardware
    call idt_init
    SER 'B'
    call pic_init
    SER 'C'
    call pit_init
    SER 'D'
    ; Initialize advanced hardware
    call acpi_init
    SER 'E'
    call apic_init
    SER 'F'
    call ioapic_init
    SER 'G'
    call spi_init
    SER 'H'
    call spi_hid_init
    SER 'I'
    SER 'J'
    SER 'K'
    
    mov rsi, szBootMsg
    call debug_print

    sti

    call keyboard_init

    ; Init mouse before disabling interrupts again
    cli
    call mouse_init
    sti

    mov rsi, szUsbInit
    call debug_print

    ; Init USB HID (XHCI) - this can take hundreds of ms
    call usb_hid_init

    mov rsi, szUsbDone
    call debug_print
    
    mov rsi, szI2cInit
    call debug_print

    ; Init I2C HID touchpad
    call i2c_hid_init
    
    mov rsi, szI2cDone
    call debug_print

    ; Init battery/power status
    call battery_init

    ; Initialize filesystem
    call fat16_init

    ; 2. Initialize GUI
    call render_init
    call wm_init
    call cursor_init

    ; 3. Flush any spurious keyboard events from init
.flush_keys:
    call keyboard_read
    test eax, eax
    jnz .flush_keys

    ; 4. Initial Draw
    mov byte [scene_dirty], 1

    ; 5. Free-running Event + Render Loop
.loop:
    ; --- Poll USB Mouse ---
    call usb_poll_mouse

    ; --- Poll I2C/SPI HID Touchpad (Fallback to Polling since APIC routing may not be reliable on all boards) ---
    call i2c_hid_poll
    call spi_hid_poll

    ; --- Poll battery status (throttled internally) ---
    call battery_poll

    ; --- Process all pending input events ---
    call process_mouse
    ; Fire repeat key if a key is held
    call keyboard_repeat_tick
    ; Drain entire keyboard buffer each frame
.pk_drain:
    call process_keyboard
    call keyboard_available
    test eax, eax
    jnz .pk_drain

    ; --- Render frame ---
    call render_frame

    jmp .loop

; ============================================================================
; Process mouse input - sets scene_dirty if needed
; ============================================================================
process_mouse:
    call mouse_check_moved
    test al, al
    jz .pm_done

    ; Hide cursor before any redraw
    call cursor_hide

    ; Get state
    mov edi, [mouse_x]
    mov esi, [mouse_y]
    movzx edx, byte [mouse_buttons]

    ; Save for later
    push rdi
    push rsi
    push rdx

    ; Pass to window manager (handles drag, close btn, client clicks)
    call wm_handle_mouse_event
    mov r15, rax             ; save return: 1=drag active

    ; Restore for taskbar/desktop
    pop rdx
    pop rsi
    pop rdi

    ; If drag is active, skip taskbar/desktop processing
    test r15, r15
    jnz .pm_set_dirty

    ; Check left click
    test dl, 1
    jz .pm_check_rclick

    ; Check if submenu is open and handle click on it first
    call tb_handle_submenu_click
    test eax, eax
    jnz .pm_set_dirty

    ; Save state
    push rdx
    push rdi
    push rsi
    call tb_handle_click

    ; Check if menu item was selected (rax >= 2 means app launch)
    cmp rax, 2
    jl .pm_tb_no_app

    ; Launch app
    pop rsi
    pop rdi
    pop rdx
    push rdx
    mov rdi, rax
    call app_launch
    jmp .pm_handled_click

.pm_tb_no_app:
    pop rsi
    pop rdi
    test rax, rax
    jnz .pm_handled_click_pop

    ; Desktop click - dismiss context menu and submenu
    mov byte [ctx_menu_visible], 0
    mov byte [sm_submenu_open], 0
    call desktop_handle_click

.pm_handled_click_pop:
    pop rdx
    jmp .pm_set_dirty

.pm_handled_click:
    pop rdx

.pm_set_dirty:
    mov byte [scene_dirty], 1
.pm_done:
    ret

.pm_check_rclick:
    ; Check right click for context menu
    test dl, 2
    jz .pm_no_click

    ; Try start menu right-click first (add/remove from desktop)
    call tb_handle_rclick
    test eax, eax
    jnz .pm_rclick_done
    ; Not in start menu - show explorer context menu
    call app_show_context_menu
.pm_rclick_done:
    mov byte [scene_dirty], 1
    ret

.pm_no_click:
    ; If dragging, mark dirty for outline updates
    cmp qword [wm_drag_window_id], -1
    jne .pm_set_dirty
    ; Just cursor movement - redraw cursor at new position
    mov edi, [mouse_x]
    mov esi, [mouse_y]
    call cursor_draw
    ret

; ============================================================================
; Process keyboard input - sets scene_dirty if needed
; ============================================================================
process_keyboard:
    call keyboard_read
    test eax, eax
    jz .pk_done

    ; EAX = [pressed:8][mods:8][ascii:8][scancode:8]
    mov ecx, eax
    shr ecx, 24
    test cl, cl
    jz .pk_done              ; Release event, ignore

    mov bl, al               ; scancode
    mov cl, ah               ; ASCII

    ; --- Determine if this is an arrow/nav key ---
    cmp byte [kb_numlock], 0
    jne .pk_numlock_on

    ; --- NumLock OFF: arrows move mouse, */- click ---
    cmp bl, 0xC8
    je .pk_key_up
    cmp bl, 0xD0
    je .pk_key_down
    cmp bl, 0xCB
    je .pk_key_left
    cmp bl, 0xCD
    je .pk_key_right
    cmp cl, '*'
    je .pk_key_lclick
    cmp cl, '-'
    je .pk_key_rclick
    jmp .pk_forward_to_window

.pk_numlock_on:
    jmp .pk_forward_to_window

.pk_forward_to_window:
    ; If a window is focused, forward key to it
    mov r8, [wm_focused_window]
    cmp r8, -1
    je .pk_done
    cmp r8, MAX_WINDOWS
    jge .pk_done

    push rax
    mov rax, r8
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .pk_no_focus_pop

    mov r9, [rax + WIN_OFF_KEYFN]
    test r9, r9
    jz .pk_no_focus_pop

    ; Call key_fn(window_ptr=rdi, key_event=esi)
    mov rdi, rax
    pop rax
    push rax
    mov esi, eax
    call r9

    pop rax
    mov byte [scene_dirty], 1
    ret

.pk_no_focus_pop:
    pop rax
.pk_done:
    ret

    ; --- Arrow key mouse movement (NumLock OFF) ---
.pk_key_up:
    call cursor_hide
    mov eax, [mouse_y]
    sub eax, 5
    jns .pk_set_y
    xor eax, eax
.pk_set_y:
    mov [mouse_y], eax
    mov byte [mouse_moved], 1
    mov byte [scene_dirty], 1
    ret

.pk_key_down:
    call cursor_hide
    mov eax, [mouse_y]
    add eax, 5
    cmp eax, SCREEN_HEIGHT - 1
    jle .pk_set_y2
    mov eax, SCREEN_HEIGHT - 1
.pk_set_y2:
    mov [mouse_y], eax
    mov byte [mouse_moved], 1
    mov byte [scene_dirty], 1
    ret

.pk_key_left:
    call cursor_hide
    mov eax, [mouse_x]
    sub eax, 5
    jns .pk_set_x
    xor eax, eax
.pk_set_x:
    mov [mouse_x], eax
    mov byte [mouse_moved], 1
    mov byte [scene_dirty], 1
    ret

.pk_key_right:
    call cursor_hide
    mov eax, [mouse_x]
    add eax, 5
    cmp eax, SCREEN_WIDTH - 1
    jle .pk_set_x2
    mov eax, SCREEN_WIDTH - 1
.pk_set_x2:
    mov [mouse_x], eax
    mov byte [mouse_moved], 1
    mov byte [scene_dirty], 1
    ret

.pk_key_lclick:
    call cursor_hide
    mov byte [mouse_buttons], 1
    mov edi, [mouse_x]
    mov esi, [mouse_y]
    mov edx, 1
    push rdi
    push rsi
    call wm_handle_mouse_event
    pop rsi
    pop rdi
    call tb_handle_click
    cmp rax, 2
    jl .pk_kc_no_app
    mov rdi, rax
    call app_launch
    jmp .pk_kc_handled
.pk_kc_no_app:
    test rax, rax
    jnz .pk_kc_handled
    call desktop_handle_click
.pk_kc_handled:
    mov byte [mouse_buttons], 0
    mov byte [scene_dirty], 1
    ret

.pk_key_rclick:
    call cursor_hide
    mov edi, [mouse_x]
    mov esi, [mouse_y]
    call tb_handle_rclick
    test eax, eax
    jnz .pk_kr_done
    mov edi, [mouse_x]
    mov esi, [mouse_y]
    call app_show_context_menu
.pk_kr_done:
    mov byte [scene_dirty], 1
    ret

; ============================================================================
; Render one frame - ultra-fast path for unchanged scenes
; Key insight: when scene is clean, we only need to update FPS text region
; (100 pixels wide x 16 pixels tall) instead of the full 3MB framebuffer
; ============================================================================
render_frame:
    ; Check if dragging
    cmp qword [wm_drag_window_id], -1
    jne .rf_draw_drag

    ; --- Normal frame ---
    cmp byte [scene_dirty], 0
    je .rf_fast_path

    ; Scene changed - full redraw
    call cursor_hide
    call wm_draw_desktop
    call desktop_draw_icons
    call tb_draw
    call tb_draw_submenu

    ; Update FPS counter
    call .rf_update_fps

    ; Draw FPS text directly into backbuffer (before save)
    call .rf_draw_fps_text

    ; Save entire scene (with FPS text baked in) as cache
    call render_save_backbuffer
    mov byte [scene_dirty], 0

    ; Full flip to VRAM
    call render_mark_full
    call render_flush

    ; Draw cursor on top of front buffer
    mov edi, [mouse_x]
    mov esi, [mouse_y]
    call cursor_draw
    ret

.rf_fast_path:
    ; === FAST PATH: Scene unchanged ===
    ; Only update FPS text region (~6KB instead of 3MB).
    ; Do NOT hide/redraw cursor here - that causes visible flicker
    ; because the cursor disappears from VRAM between hide and draw.
    ; Cursor is only moved in process_mouse when it actually changes.

    call .rf_update_fps

    ; Restore just the FPS region from cache to clear old text
    call .rf_restore_fps_region

    ; Draw new FPS text into backbuffer
    call .rf_draw_fps_text

    ; Flip only the FPS region from backbuffer to VRAM
    mov edi, FPS_REGION_X
    mov esi, FPS_REGION_Y
    mov edx, FPS_REGION_W
    mov ecx, FPS_REGION_H
    call display_flip_rect

    ret

.rf_draw_drag:
    ; --- Drag path: need full backbuffer restore for outline ---
    call cursor_hide
    call render_restore_backbuffer
    call wm_draw_drag_outline
    call .rf_update_fps
    call .rf_draw_fps_text
    call render_mark_full
    call render_flush
    mov edi, [mouse_x]
    mov esi, [mouse_y]
    call cursor_draw
    ret

; --- Helper: Update FPS counter (increment + check 1-second boundary) ---
.rf_update_fps:
    inc dword [frame_count]
    mov rax, [tick_count]
    mov rbx, [start_tick]
    sub rax, rbx
    cmp rax, 100             ; 1 second (100 ticks)
    jl .rf_fps_no_update
    mov eax, [frame_count]
    mov [last_fps], eax
    mov dword [frame_count], 0
    mov rax, [tick_count]
    mov [start_tick], rax
.rf_fps_no_update:
    ret

; --- Helper: Draw FPS text into backbuffer ---
.rf_draw_fps_text:
    cmp byte [fps_show], 1
    jne .rf_fps_text_done

    mov edi, [last_fps]
    lea rsi, [fps_str]
    call uint32_to_str

    mov rdi, 10
    mov rsi, 10
    lea rdx, [szFPSPrefix]
    mov ecx, 0x00FFFF00      ; Yellow
    mov r8d, COLOR_DESKTOP_BG ; Opaque BG (avoid needing restore for text area)
    call render_text

    mov rdi, 50
    mov rsi, 10
    lea rdx, [fps_str]
    mov ecx, 0x00FFFF00      ; Yellow
    mov r8d, COLOR_DESKTOP_BG
    call render_text

.rf_fps_text_done:
    ret

; --- Helper: Restore just the FPS region from cached backbuffer ---
; Copies FPS_REGION_W * FPS_REGION_H pixels from save buffer to backbuffer
.rf_restore_fps_region:
    push rdi
    push rsi
    push rcx
    push rax

    ; Calculate offset for FPS region: y*pitch + x*4
    mov eax, FPS_REGION_Y
    imul eax, [scr_pitch]
    add eax, FPS_REGION_X * 4

    mov rdi, [bb_addr]
    add rdi, rax              ; dest = backbuffer + offset
    mov rsi, BACK_BUFFER_SAVE_ADDR
    add rsi, rax              ; src = save buffer + offset

    movsxd rcx, dword [scr_pitch]
    mov eax, FPS_REGION_H     ; row count

.rfr_row:
    ; Copy one row of FPS region (FPS_REGION_W * 4 bytes)
    push rdi
    push rsi
    push rax
    mov ecx, FPS_REGION_W     ; pixels per row
    rep movsd                  ; copy dwords (4 bytes per pixel)
    pop rax
    pop rsi
    pop rdi

    ; Advance to next row
    movsxd rcx, dword [scr_pitch]
    add rdi, rcx
    add rsi, rcx
    dec eax
    jnz .rfr_row

    pop rax
    pop rcx
    pop rsi
    pop rdi
    ret

szFPSPrefix db "FPS:", 0
fps_str     times 16 db 0
scene_dirty db 1              ; 1 = scene needs full redraw

szBootMsg db "Booting NexusOS v3.0...", 0
szUsbInit db "Initializing USB HID (XHCI)...", 0
szUsbDone db "USB HID Init Complete.", 0
szI2cInit db "Initializing I2C HID (Touchpad)...", 0
szI2cDone db "I2C HID Init Complete.", 0
