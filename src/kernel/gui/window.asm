; ============================================================================
; NexusOS v3.0 - Window Manager
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
global wm_get_window_at
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

FN_BEGIN wm_init, 0, 0, FN_RET_VOID
    push rbx
    ; Zero out window pool
    mov rdi, WINDOW_POOL_ADDR
    mov rcx, MAX_WINDOWS * WINDOW_STRUCT_SIZE
    xor rax, rax
    rep stosb
    mov qword [wm_window_count], 0
    mov qword [wm_drag_window_id], -1
    mov qword [wm_app_drag_window_id], -1
    mov qword [wm_focused_window], -1

    ; Slot 0 = native NexusHL wallpaper renderer. Set it up like a regular
    ; window so wm_draw_desktop_background can call into app_hl_wallpaper_draw
    ; through call_app_l3 / the normal l3 ABI.
    mov rbx, WINDOW_POOL_ADDR
    mov qword [rbx + WIN_OFF_ID], 0
    mov qword [rbx + WIN_OFF_X], 0
    mov qword [rbx + WIN_OFF_Y], 0
    mov eax, [scr_width]
    mov [rbx + WIN_OFF_W], rax
    mov eax, [scr_height]
    mov [rbx + WIN_OFF_H], rax
    ; Note: NO flags. Slot 0 is invisible to window iteration (focus, hit
    ; testing, draw loop) -- it only exists to give call_app_l3 a stable
    ; per-slot L3 arena for the wallpaper renderer.
    mov qword [rbx + WIN_OFF_FLAGS], 0
    lea rax, [rel app_hl_wallpaper_draw]
    mov [rbx + WIN_OFF_DRAWFN], rax
    xor edi, edi
    call l3_slot_base
    mov [rbx + WIN_OFF_APPDATA], rax

    ; Give the hidden wallpaper renderer a PCB so expensive SVG callbacks can
    ; be pinned to an AP home_core instead of falling back to the BSP.
    lea rdi, [rel app_hl_wallpaper_draw]
    xor esi, esi
    xor edx, edx
    call process_create
    mov [wallpaper_process_id], eax

    pop rbx
    FN_END wm_init
    ret

; Create window (simple): RDI=title, RSI=x, RDX=y, RCX=w, R8=h
; Returns RAX = window ID (-1 on fail)
FN_BEGIN wm_create_window, 5, 0, FN_RET_HANDLE
    xor r9d, r9d
    FN_END wm_create_window
    jmp wm_do_create

FN_BEGIN wm_create_window_ex, 6, 0, FN_RET_HANDLE
    FN_END wm_create_window_ex
    jmp wm_do_create

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

    mov rax, r13
    or  rax, r14
    or  rax, r15
    or  rax, r8
    shr rax, 32
    jnz .fail
    cmp r15d, MIN_WINDOW_W
    jb .fail
    cmp r8d, MIN_WINDOW_H
    jb .fail
    mov eax, r13d
    add eax, r15d
    jc .fail
    cmp eax, SCREEN_WIDTH
    ja .fail
    mov eax, r14d
    add eax, r8d
    jc .fail
    cmp eax, SCREEN_HEIGHT
    ja .fail

    ; Slot 0 is reserved for the native desktop wallpaper renderer's
    ; NexusHL state. Normal windows use slots 1..MAX_WINDOWS-1.
    cmp qword [wm_window_count], MAX_WINDOWS - 1
    jge .fail

    ; Unfocus all existing windows
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

    ; Find free slot
    mov rbx, WINDOW_POOL_ADDR + WINDOW_STRUCT_SIZE
    mov ecx, 1
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
    mov rdi, rbx
    xor eax, eax
    mov ecx, WINDOW_STRUCT_SIZE
    rep stosb
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

    ; Set draw callback
    mov [rbx + WIN_OFF_DRAWFN], r9
    push rcx
    movzx edi, cx
    call l3_slot_base
    pop rcx
    mov [rbx + WIN_OFF_APPDATA], rax

    ; Register process
    mov rdi, r9
    movzx rsi, cx
    movzx rdx, cx
    call process_create

    ; Update globals
    movzx eax, cx
    mov [wm_focused_window], rax
    inc qword [wm_window_count]

    mov rax, rcx         ; Return window ID
    jmp .done

.fail:
    mov rax, -1
.done:
    FN_END wm_create_window_ex
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Close window by ID: RDI = window ID
FN_BEGIN wm_close_window, 1, 0, FN_RET_VOID
    ; Use unsigned compare: jge treats rdi as signed, so a caller-supplied
    ; negative index (e.g. -1) falls through and lets the code below write
    ; WIN_OFF_FLAGS at WINDOW_POOL_ADDR + rdi*256 -- a limited kernel write.
    cmp rdi, MAX_WINDOWS
    jae .close_ret
    push rax
    push rbx
    call process_kill_window
    mov rax, rdi
    mov rbx, WINDOW_STRUCT_SIZE
    imul rax, rbx
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_FLAGS], 0   ; Clear all flags (inactive)
    dec qword [wm_window_count]
    ; If this was focused, move focus to another active visible window so the
    ; user can keep working after closing a launched document.
    cmp [wm_focused_window], rdi
    jne .close_nofocus
    call wm_focus_top_active
.close_nofocus:
    pop rbx
    pop rax
.close_ret:
    FN_END wm_close_window
    ret

wm_focus_top_active:
    push rax
    push rbx
    push rcx
    mov rcx, MAX_WINDOWS
    dec rcx
.fta_loop:
    cmp rcx, 0
    jl .fta_none
    mov rax, rcx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .fta_next
    test qword [rax + WIN_OFF_FLAGS], WF_VISIBLE
    jz .fta_next
    test qword [rax + WIN_OFF_FLAGS], WF_MINIMIZED
    jnz .fta_next
    mov rbx, WINDOW_POOL_ADDR
    xor eax, eax
.fta_clear_loop:
    cmp eax, MAX_WINDOWS
    je .fta_set
    and qword [rbx + WIN_OFF_FLAGS], ~WF_FOCUSED
    add rbx, WINDOW_STRUCT_SIZE
    inc eax
    jmp .fta_clear_loop
.fta_set:
    mov rax, rcx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    or qword [rax + WIN_OFF_FLAGS], WF_FOCUSED
    mov [wm_focused_window], rcx
    jmp .fta_done
.fta_next:
    dec rcx
    jmp .fta_loop
.fta_none:
    mov qword [wm_focused_window], -1
.fta_done:
    pop rcx
    pop rbx
    pop rax
    ret

; Draw all windows (painter's algorithm)
FN_BEGIN wm_draw_desktop, 0, 0, FN_RET_VOID
    push rbx
    push r12

    ; 1. Desktop background
    call wm_draw_desktop_background
    cmp byte [wallpaper_render_active], 0
    jne .draw_done

    ; 1b. Desktop icons (between background and windows so apps cover them)
    call desktop_draw_icons

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
    FN_END wm_draw_desktop
    pop r12
    pop rbx
    ret

; Desktop background renderer. Drives the NexusHL wallpaper app
; (app_hl_wallpaper_draw -> svg_render on the inline SVG strings) through the
; standard l3 ABI. Each theme has its own raster cache so changing backgrounds
; is a cache blit, not a full SVG render in the interactive frame loop.
FN_BEGIN wm_draw_desktop_background, 0, 0, FN_RET_VOID
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Until the user picks a wallpaper in Settings, the desktop uses a plain
    ; solid fill. This keeps the SVG rasterizer (a multi-second, syscall-heavy
    ; pass) entirely off the boot path so no core stalls while booting.
    cmp byte [wallpaper_selected], 0
    jne .have_wallpaper
    call wm_bg_fill_solid
    jmp .done
.have_wallpaper:
    movzx r12d, byte [desktop_bg_theme]
    cmp r12d, 2
    ja .theme_zero
.theme_ready:
    call wm_wallpaper_cache_addr
    mov r15, rax
    mov [wallpaper_cache_active_addr], r15

    mov ecx, [scr_width]
    cmp [wallpaper_cache_w], ecx
    jne .invalidate_all
    mov ecx, [scr_height]
    cmp [wallpaper_cache_h], ecx
    jne .invalidate_all
    cmp byte [wallpaper_cache_valid_by_theme + r12], 1
    jne .render
    cmp byte [wallpaper_cache_valid], 1
    jne .render
    mov rdi, r15
    call wm_bg_restore_cache
    mov byte [wallpaper_cache_presented], 1
    jmp .done

.theme_zero:
    xor r12d, r12d
    mov byte [desktop_bg_theme], 0
    jmp .theme_ready

.invalidate_all:
    mov byte [wallpaper_cache_valid], 0
    mov byte [wallpaper_cache_valid_by_theme + 0], 0
    mov byte [wallpaper_cache_valid_by_theme + 1], 0
    mov byte [wallpaper_cache_valid_by_theme + 2], 0
    mov byte [wallpaper_cache_presented], 0

.render:
    cmp byte [wallpaper_render_state], 1
    je .poll_render
    ; Refresh slot 0's shadow window to the current resolution before invoking
    ; the renderer -- wallpaper.nxh reads display_current_width/height through
    ; syscalls so this is only defense in depth.
    mov rbx, WINDOW_POOL_ADDR
    mov eax, [scr_width]
    mov [rbx + WIN_OFF_W], rax
    mov eax, [scr_height]
    mov [rbx + WIN_OFF_H], rax

    mov eax, [scr_width]
    mov [wallpaper_render_w], eax
    mov eax, [scr_height]
    mov [wallpaper_render_h], eax
    mov [wallpaper_render_theme], r12d
    mov [wallpaper_render_target_addr], r15
    mov byte [wallpaper_cache_presented], 0

    lea rax, [rel app_hl_wallpaper_draw]
    mov [wallpaper_render_pack + 0], rax
    mov [wallpaper_render_pack + 8], rbx
    mov qword [wallpaper_render_pack + 16], 0
    mov qword [wallpaper_render_pack + 24], 0

    mov byte [wallpaper_render_active], 1
    mov edi, [wallpaper_process_id]
    test edi, edi
    jle .render_unavailable
    lea rsi, [rel wallpaper_render_job]
    xor edx, edx
    xor r8d, r8d                       ; low priority background work
    call process_submit_job
    cmp eax, -1
    je .render_unavailable
    mov [wallpaper_render_handle], eax
    mov byte [wallpaper_render_state], 1
    mov byte [scene_dirty], 1
    jmp .done

.poll_render:
    call wm_poll_wallpaper_render
    cmp byte [wallpaper_render_state], 1
    je .render_still_pending
    cmp byte [wallpaper_cache_valid_by_theme + r12], 1
    jne .render
    cmp byte [wallpaper_cache_valid], 1
    jne .render
    mov rdi, r15
    call wm_bg_restore_cache
    mov byte [wallpaper_cache_presented], 1
    jmp .done

.render_still_pending:
    mov byte [scene_dirty], 1
    jmp .done

.render_unavailable:
    mov byte [wallpaper_render_active], 0
    mov byte [wallpaper_cache_presented], 1
    call wm_bg_fill_solid

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    FN_END wm_draw_desktop_background
    ret

; Poll the background wallpaper job without waiting for it. This is called from
; the BSP render loop so completed jobs are reaped without blocking core 0.
FN_BEGIN wm_poll_wallpaper_render, 0, 0, FN_RET_VOID
    cmp byte [wallpaper_render_state], 1
    jne .poll_done
    mov edi, [wallpaper_render_handle]
    call workqueue_done
    test eax, eax
    jz .poll_done
    mov edi, [wallpaper_render_handle]
    call workqueue_reap
    mov byte [wallpaper_render_state], 0
    mov byte [scene_dirty], 1
.poll_done:
    FN_END wm_poll_wallpaper_render
    ret

; Runs on an AP through process_submit_job. It renders the wallpaper app into
; the selected wallpaper cache. SVG raster syscalls select that cache as their
; destination, so this job never mutates bb_addr and the BSP can keep using the
; real backbuffer.
wallpaper_render_job:
    push rbx
    push r12
    push r13

    lea rdi, [rel app_callback_lock]
    call wq_lock

    lea rdi, [rel wallpaper_render_pack]
    call call_app_l3_packed

    call raster_select_default_target

    mov eax, [wallpaper_render_w]
    mov [wallpaper_cache_w], eax
    mov eax, [wallpaper_render_h]
    mov [wallpaper_cache_h], eax
    mov eax, [wallpaper_render_theme]
    cmp eax, 2
    ja .skip_theme_valid
    mov byte [wallpaper_cache_valid_by_theme + rax], 1
.skip_theme_valid:
    mov byte [wallpaper_cache_valid], 1

    lea rdi, [rel app_callback_lock]
    call wq_unlock
    mov byte [wallpaper_render_active], 0
    mov byte [scene_dirty], 1
    xor eax, eax

    pop r13
    pop r12
    pop rbx
    ret

wm_wallpaper_cache_addr:
    cmp r12d, 1
    je .cache1
    cmp r12d, 2
    je .cache2
    mov rax, WALLPAPER_CACHE0_ADDR
    ret
.cache1:
    mov rax, WALLPAPER_CACHE1_ADDR
    ret
.cache2:
    mov rax, WALLPAPER_CACHE2_ADDR
    ret

; Paint the back buffer with the plain desktop color. Used as the background
; whenever no wallpaper has been selected yet (notably the whole boot path) so
; the expensive SVG rasterizer never runs unprompted. Preserves all registers.
wm_bg_fill_solid:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    mov rdi, [bb_addr]
    mov r8d, [scr_height]
    mov r9d, [scr_width]
    mov rdx, [scr_pitch_q]          ; bytes per scanline
    mov eax, r9d
    shl eax, 2
    sub rdx, rax                    ; rdx = end-of-row gap (pitch - width*4)
    mov eax, DESKTOP_SOLID_COLOR
.fs_row:
    test r8d, r8d
    jz .fs_done
    mov ecx, r9d
    rep stosd                       ; EAX is preserved across rep stosd
    add rdi, rdx
    dec r8d
    jmp .fs_row
.fs_done:
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

wm_bg_save_cache:
    push rdi
    push rsi
    push rcx
    push rdx
    push r8
    push r9

    mov rsi, [bb_addr]
    mov r8d, [scr_height]
    mov r9d, [scr_width]
.save_row:
    test r8d, r8d
    jz .save_done
    mov ecx, r9d
    rep movsd
    mov rax, [scr_pitch_q]
    mov rdx, r9
    shl rdx, 2
    add rsi, rax
    sub rsi, rdx
    dec r8d
    jmp .save_row
.save_done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rsi
    pop rdi
    ret

wm_bg_restore_cache:
    push rdi
    push rsi
    push rcx
    push rdx
    push r8
    push r9

    mov rsi, rdi
    mov rdi, [bb_addr]
    mov r8d, [scr_height]
    mov r9d, [scr_width]
.restore_row:
    test r8d, r8d
    jz .restore_done
    mov ecx, r9d
    rep movsd
    mov rax, [scr_pitch_q]
    mov rdx, r9
    shl rdx, 2
    add rdi, rax
    sub rdi, rdx
    dec r8d
    jmp .restore_row
.restore_done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rsi
    pop rdi
    ret

; Draw a soft diamond from one-pixel scanlines.
; EDI=cx, ESI=cy, EDX=radius, R8D=color.
wm_bg_diamond:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12d, edi                  ; cx
    mov r13d, esi                  ; cy
    mov r14d, edx                  ; radius
    mov r15d, r8d                  ; color
    mov ebx, edx
    neg ebx                        ; dy = -radius
.diamond_loop:
    cmp ebx, r14d
    jg .diamond_done
    mov eax, ebx
    test eax, eax
    jge .abs_ok
    neg eax
.abs_ok:
    mov edx, r14d
    sub edx, eax                   ; half width
    jle .diamond_next
    mov edi, r12d
    sub edi, edx                   ; x
    mov esi, r13d
    add esi, ebx                   ; y
    mov ecx, 1
    mov r8d, r15d
    shl edx, 1                     ; width
    call render_rect
.diamond_next:
    inc ebx
    jmp .diamond_loop
.diamond_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Draw a specific window: RDI = window ID
FN_BEGIN wm_draw_window, 1, 0, FN_RET_VOID
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

    ; --- Raised bevel border (VGA98 style) ---
    ; Outer black frame
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8d, COLOR_BEVEL_XDK
    call render_rect

    ; Top highlight
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, COLOR_BEVEL_LT
    call draw_hline

    ; Left highlight
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    mov rcx, COLOR_BEVEL_LT
    call draw_vline

    ; Bottom shadow (1px up from outer)
    mov rdi, r12
    mov rsi, r13
    add rsi, r15
    sub rsi, 1
    mov rdx, r14
    mov rcx, COLOR_BEVEL_DK
    call draw_hline

    ; Right shadow (1px left from outer)
    mov rdi, r12
    add rdi, r14
    sub rdi, 1
    mov rsi, r13
    mov rdx, r15
    mov rcx, COLOR_BEVEL_DK
    call draw_vline

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

    ; Close icon
    mov rdi, r12
    add rdi, r14
    sub rdi, CLOSE_BTN_SIZE + 3
    mov rsi, r13
    add rsi, 5
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, nx_icon_close_16
    call nx_icon_blit

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
    cmp rax, app_media_draw
    jne .dispatch_user_draw
    mov rdi, rbx
    call app_media_draw
    jmp .draw_done
.dispatch_user_draw:
    mov rdi, rax
    mov rsi, rbx         ; arg0: window_ptr
    xor edx, edx         ; arg1
    xor ecx, ecx         ; arg2
    call dispatch_app_callback
.draw_done:
    jmp .content_done

.default_content:
    ; Default: show "Empty Window"
    mov rdi, r12
    add rdi, BORDER_WIDTH + 8
    mov rsi, r13
    add rsi, TITLEBAR_HEIGHT + 8
    mov rdx, szEmptyWin
    mov ecx, COLOR_TEXT_GRAY
    mov r8d, COLOR_WINDOW_BG
    call render_text

.content_done:
    FN_END wm_draw_window
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Handle mouse input: RDI=mouseX, RSI=mouseY, RDX=buttons
FN_BEGIN wm_handle_mouse_event, 3, 0, FN_RET_SCALAR
    push r12
    push r13
    push r14
    push r15
    push rbx

    mov r12, rdi         ; mouseX
    mov r13, rsi         ; mouseY
    mov r14, rdx         ; buttons
    xor r15d, r15d       ; handled client click

    ; If dragging, handle drag (hold-and-release mode)
    cmp qword [wm_drag_window_id], -1
    jne .dragging

    ; App-drag in flight? Route mouse-move to the latched window's drag_fn
    ; or release the latch on button-up. Takes precedence over click/focus
    ; routing for as long as the left button stays down, so drag events keep
    ; flowing even when the cursor leaves the window's bounds.
    cmp qword [wm_app_drag_window_id], -1
    jne .app_drag_active

    ; Right-button down is a separate app callback, fired only on the press
    ; edge. This lets apps own context menus instead of using a global "Open"
    ; menu that cannot know the app's local state.
    test r14, 2
    jz .need_left_button
    test qword [wm_last_buttons], 2
    jnz .mouse_done
    jmp .right_click

.need_left_button:
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
    
    ; Save clean composed state for smooth dragging. This is independent from
    ; WALLPAPER_CACHE_ADDR, which stores only the selected/blitted wallpaper.
    call render_save_backbuffer
    
    jmp .set_focus

.client_click:
    ; Check if app has click_fn
    mov r8, [rax + WIN_OFF_CLICKFN]
    test r8, r8
    jz .set_focus
    ; The stored CLICKFN is CPI-tag-signed at install time (cpi_sign_callback in
    ; SYS_WM_HANDLERS stamps a tag into the top 16 bits). Authenticate and STRIP
    ; the tag to recover the raw kernel-image VA before interning/dispatching —
    ; exactly as the KEYFN dispatch in main.asm does. Dispatching the still-tagged
    ; value iretq's to a non-canonical RIP (0xXXXX0000........) -> ring-3 #GP, i.e.
    ; the click freeze. cpi_verify_callback returns the raw fn in rax (or panics on
    ; a forged tag); rax currently holds &window, so preserve it across the call.
    push rax                          ; &window
    mov rdi, r8                       ; stored (tagged) click_fn
    mov rsi, rax                      ; &window
    mov rdx, WIN_OFF_CLICKFN          ; field offset bound into the tag
    call cpi_verify_callback
    mov r8, rax                       ; raw (untagged) click_fn
    pop rax                           ; restore &window
    test r8, r8
    jz .set_focus
    test qword [wm_last_buttons], 1
    jnz .client_click_already_down

    ; Button-down edge inside a window's client area. If this window also
    ; installed a drag_fn, latch a drag session: subsequent ticks will route
    ; mouse-move events to drag_fn via the .app_drag_active path until the
    ; left button is released. Seed last_x/last_y with the press position so
    ; the very first move-tick only fires after the cursor actually moves.
    mov r9, [rax + WIN_OFF_DRAGFN]
    test r9, r9
    jz .client_click_no_drag_latch
    mov [wm_app_drag_window_id], rbx
    mov r10, r12
    sub r10, [rax + WIN_OFF_X]
    sub r10, BORDER_WIDTH
    mov [wm_app_drag_last_x], r10
    mov r10, r13
    sub r10, [rax + WIN_OFF_Y]
    sub r10, TITLEBAR_HEIGHT
    mov [wm_app_drag_last_y], r10
.client_click_no_drag_latch:

    mov r10, [wm_focused_window]
    mov [wm_click_focus_before], r10
    push rax
    push r8
    SER 'c'
    push rdi
    mov rdi, rax
    call ser_print_hex64
    SER ':'
    mov rdi, r12
    call ser_print_hex64
    SER ':'
    mov rdi, r13
    call ser_print_hex64
    pop rdi
    pop r8
    pop rax
    mov r11, r8
    SER 'm'
    mov rdx, r12
    sub rdx, [rax + WIN_OFF_X]
    sub rdx, BORDER_WIDTH     ; client_x (relX)
    mov rcx, r13
    sub rcx, [rax + WIN_OFF_Y]
    sub rcx, TITLEBAR_HEIGHT  ; client_y (relY)
    ; §6 trampoline: intern the click_fn into the kernel-owned per-slot table,
    ; then take the call target FROM THAT KERNEL TABLE (via wm_cb_resolve) so a
    ; forged window-struct qword can never be the WM's jump target. rbx =
    ; window/slot index; rax = win ptr; r11 = target; rdx/rcx = client coords
    ; (preserved by wm_cb_intern/_resolve).
    push rax
    push rdx
    push rcx
    mov edi, ebx                  ; slot index
    mov esi, WM_CB_FIELD_CLICK
    mov rdx, r11                  ; target to intern
    call wm_cb_intern             ; eax = slot-local callback id
    mov edi, eax
    call wm_cb_resolve            ; rax = trusted target from kernel BSS
    mov r11, rax
    pop rcx
    pop rdx
    pop rsi                       ; arg0: window ptr (was rax)
    mov rdi, r11                  ; target from kernel table, not the window
    test rdi, rdi
    jz .click_done
    call dispatch_app_callback
    SER 'n'
.click_done:
    ; A client click can launch or focus another window. Keep that new focus
    ; instead of forcing focus back to the clicked window after the callback.
    mov rax, [wm_focused_window]
    cmp rax, [wm_click_focus_before]
    jne .click_preserve_focus
    mov r15d, 1
    jmp .set_focus
.click_preserve_focus:
    mov eax, 1
    jmp .mouse_ret

.client_click_already_down:
    mov r15d, 1

.right_click:
    ; Find window under cursor
    mov rdi, r12
    mov rsi, r13
    call wm_get_window_at
    cmp rax, -1
    je .mouse_done

    mov rbx, rax
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR

    ; Only client-area right clicks go to apps; titlebar/chrome stays owned by
    ; the WM and does not open a global fallback menu.
    mov r8, [rax + WIN_OFF_Y]
    mov r9, r13
    sub r9, r8
    cmp r9, TITLEBAR_HEIGHT
    jle .mouse_done

    mov r11, [rax + WIN_OFF_RCLICKFN]
    test r11, r11
    jz .mouse_done
    ; CPI: authenticate + STRIP the tag before interning (mirror .client_click).
    ; RCLICKFN is cpi_sign_callback'd at install (launch.inc); interning the
    ; still-tagged pointer dispatches to a non-canonical RIP -> ring-3 #GP (the
    ; freeze). cpi_verify_callback clobbers rax, and rax holds &window (live
    ; below), so preserve it across the call.
    push rax                          ; &window
    mov rdi, r11                       ; stored (tagged) rclick_fn
    mov rsi, rax                       ; &window
    mov rdx, WIN_OFF_RCLICKFN          ; field offset bound into the tag
    call cpi_verify_callback
    mov r11, rax                       ; raw (untagged) rclick_fn
    pop rax                            ; restore &window
    test r11, r11
    jz .mouse_done
    mov rdx, r12
    sub rdx, [rax + WIN_OFF_X]
    sub rdx, BORDER_WIDTH
    mov rcx, r13
    sub rcx, [rax + WIN_OFF_Y]
    sub rcx, TITLEBAR_HEIGHT
    ; §6 trampoline: intern the rclick_fn and invoke by id so the call target
    ; comes from the kernel-owned table. rbx = window/slot index; rax = win ptr;
    ; r11 = target; rdx/rcx = client coords.
    push rdx
    push rcx
    mov edi, ebx                 ; slot index
    mov esi, WM_CB_FIELD_RCLICK
    mov rdx, r11                 ; target to intern
    mov r8, rax                  ; stash win ptr (wm_cb_intern preserves r8)
    call wm_cb_intern
    mov edi, eax                 ; id
    mov rsi, r8                  ; arg0 = window ptr
    pop rcx
    pop rdx
    call wm_cb_trampoline
    mov eax, 1
    jmp .mouse_ret

.set_focus:
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
    ; rbx = window ID, recompute ptr
    mov rax, rbx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    or qword [rax + WIN_OFF_FLAGS], WF_FOCUSED
    mov [wm_focused_window], rbx
    test r15d, r15d
    jnz .handled_mouse_ret
    jmp .mouse_done

.handled_mouse_ret:
    mov eax, 1
    jmp .mouse_ret

.desktop_click:
    ; Clear WF_FOCUSED on every window or wm_draw_desktop's two-pass
    ; renderer will skip the previously focused window (non-focused pass
    ; rejects WF_FOCUSED, focused pass rejects -1) and the app vanishes.
    mov rcx, WINDOW_POOL_ADDR
    xor edx, edx
.dc_clear_loop:
    cmp edx, MAX_WINDOWS
    je .dc_clear_done
    and qword [rcx + WIN_OFF_FLAGS], ~WF_FOCUSED
    add rcx, WINDOW_STRUCT_SIZE
    inc edx
    jmp .dc_clear_loop
.dc_clear_done:
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
    ; Keep the WHOLE window on-screen. App draw routines that write straight
    ; into the framebuffer (notably the media player's scaler, which historically
    ; clamped only vertically) fault the entire OS if handed a client rect that
    ; extends past a screen edge. Clamp X to [0, scr_width - w] and Y to
    ; [0, scr_height - h]; pin to 0 if the window is larger than the screen.
    mov rax, rbx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    ; --- X ---
    mov r10d, [scr_width]
    sub r10d, [rax + WIN_OFF_W]          ; max_x = scr_width - w
    movsxd r10, r10d
    jns .clamp_x_max
    xor r10, r10                          ; wider than screen -> pin left
.clamp_x_max:
    cmp r8, r10
    jle .clamp_x_lo
    mov r8, r10
.clamp_x_lo:
    test r8, r8
    jns .clamp_y
    xor r8, r8
.clamp_y:
    ; --- Y ---
    mov r11d, [scr_height]
    sub r11d, [rax + WIN_OFF_H]          ; max_y = scr_height - h
    movsxd r11, r11d
    jns .clamp_y_max
    xor r11, r11                          ; taller than screen -> pin top
.clamp_y_max:
    cmp r9, r11
    jle .clamp_y_lo
    mov r9, r11
.clamp_y_lo:
    test r9, r9
    jns .drag_clamp_ok
    xor r9, r9
.drag_clamp_ok:
    ; Mark OLD position edges as dirty (to erase/restore)
    push r8
    push r9
    mov r8, [wm_drag_preview_x]
    mov r9, [wm_drag_preview_y]
    mov r10, [wm_drag_preview_w]
    mov r11, [wm_drag_preview_h]
    call wm_mark_outline_dirty
    pop r9
    pop r8

    mov [wm_drag_preview_x], r8
    mov [wm_drag_preview_y], r9

    push r8
    push r9
    mov r10, [wm_drag_preview_w]
    mov r11, [wm_drag_preview_h]
    call wm_mark_outline_dirty
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

; ----------------------------------------------------------------------------
; App-drag dispatch
;
; Entered when [wm_app_drag_window_id] != -1, i.e. a previous click started a
; drag session on a window that installed a drag_fn. On every mouse-poll tick:
;
;   * left button released  -> clear the latch and exit (no event emitted).
;   * window slot reused    -> bail out silently (defensive — the app may
;                              have closed mid-drag and a new window now
;                              owns the slot).
;   * cursor moved          -> dispatch drag_fn(win_ptr, client_x, client_y)
;                              and record the new position.
;
; client_x / client_y are computed the same way as click_fn (relative to the
; window's client origin, below the titlebar and inside the border) and may
; be negative or exceed window dimensions when the cursor drags outside the
; window — apps are expected to clip. r12=mouseX, r13=mouseY, r14=buttons.
.app_drag_active:
    test r14, 1
    jz .app_drag_release

    mov rbx, [wm_app_drag_window_id]
    cmp rbx, -1
    je .mouse_done

    mov rax, rbx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .app_drag_release
    mov r11, [rax + WIN_OFF_DRAGFN]
    test r11, r11
    jz .app_drag_release
    ; CPI: authenticate + STRIP the tag before interning (mirror .client_click).
    ; DRAGFN is cpi_sign_callback'd at install (launch.inc); interning the
    ; still-tagged pointer dispatches to a non-canonical RIP -> ring-3 #GP (the
    ; drag freeze on file-open, since a click latches a drag session).
    ; cpi_verify_callback clobbers rax, and rax holds &window (live below), so
    ; preserve it across the call.
    push rax                          ; &window
    mov rdi, r11                       ; stored (tagged) drag_fn
    mov rsi, rax                       ; &window
    mov rdx, WIN_OFF_DRAGFN            ; field offset bound into the tag
    call cpi_verify_callback
    mov r11, rax                       ; raw (untagged) drag_fn
    pop rax                            ; restore &window
    test r11, r11
    jz .app_drag_release

    ; client_x = mouseX - WIN_X - BORDER_WIDTH
    mov rdx, r12
    sub rdx, [rax + WIN_OFF_X]
    sub rdx, BORDER_WIDTH
    ; client_y = mouseY - WIN_Y - TITLEBAR_HEIGHT
    mov rcx, r13
    sub rcx, [rax + WIN_OFF_Y]
    sub rcx, TITLEBAR_HEIGHT

    ; Skip dispatch if neither coord changed since the last fired event.
    ; The poll tick can fire many times a frame; collapsing same-position
    ; ticks keeps the L3 trampoline cost down for stationary holds.
    mov r8, [wm_app_drag_last_x]
    cmp r8, rdx
    jne .app_drag_dispatch
    mov r8, [wm_app_drag_last_y]
    cmp r8, rcx
    je .app_drag_handled

.app_drag_dispatch:
    mov [wm_app_drag_last_x], rdx
    mov [wm_app_drag_last_y], rcx
    ; §6 trampoline: intern the drag_fn and invoke by id so the call target
    ; comes from the kernel-owned table. rbx = window/slot index (=
    ; wm_app_drag_window_id); rax = win ptr; r11 = target; rdx/rcx = coords.
    push rdx
    push rcx
    mov edi, ebx                ; slot index
    mov esi, WM_CB_FIELD_DRAG
    mov rdx, r11               ; target to intern
    mov r8, rax                ; stash win ptr (wm_cb_intern preserves r8)
    call wm_cb_intern
    mov edi, eax               ; id
    mov rsi, r8                ; arg0 = window ptr
    pop rcx
    pop rdx
    call wm_cb_trampoline

.app_drag_handled:
    mov eax, 1
    jmp .mouse_ret

.app_drag_release:
    mov qword [wm_app_drag_window_id], -1
    jmp .mouse_done


.mouse_done:
    xor eax, eax               ; return 0 = not handled / no drag active
    cmp qword [wm_drag_window_id], -1
    je .mouse_ret
    mov eax, 1                  ; return 1 = drag is active, skip other handlers
.mouse_ret:
    FN_END wm_handle_mouse_event
    mov [wm_last_buttons], r14
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; Draw drag outline (called from main loop when dragging)
; Uses wm_drag_preview_x/y/w/h to draw a 2px rectangle outline
global wm_draw_drag_outline
FN_BEGIN wm_draw_drag_outline, 0, 0, FN_RET_VOID
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
    FN_END wm_draw_drag_outline
    ret

wm_mark_outline_dirty:
    ; Args: R8=x, R9=y, R10=w, R11=h
    push r8
    push r9
    push r10
    push r11
    mov edi, r8d
    mov esi, r9d
    mov edx, r10d
    mov ecx, 2
    call render_mark_dirty
    mov edi, r8d
    mov esi, r9d
    add esi, r11d
    sub esi, 2
    mov edx, r10d
    mov ecx, 2
    call render_mark_dirty
    mov edi, r8d
    mov esi, r9d
    mov edx, 2
    mov ecx, r11d
    call render_mark_dirty
    mov edi, r8d
    add edi, r10d
    sub edi, 2
    mov esi, r9d
    mov edx, 2
    mov ecx, r11d
    call render_mark_dirty
    pop r11
    pop r10
    pop r9
    pop r8
    ret

; Find topmost window at (X, Y): RDI=x, RSI=y -> RAX=window ID or -1
FN_BEGIN wm_get_window_at, 2, 0, FN_RET_HANDLE
    push r12

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
    FN_END wm_get_window_at
    pop r12
    ret

; ============================================================================
; §6 — Kernel-owned per-slot callback trampoline
;
; Threat: today the WM invokes app callbacks by reading a RAW function pointer
; straight out of the window struct (WIN_OFF_CLICKFN/KEYFN/DRAGFN/RCLICKFN) and
; jumping to it, so the invocation target is a ring-3-influenced qword.
;
; This adds a kernel-owned indirection so the WM's invocation no longer trusts
; the window-struct qword as the call target. Each (slot, field) callback is
; INTERNED — the pointer is copied into a per-slot callback table that lives in
; KERNEL BSS, OUTSIDE the ring-3 app arena (so an app's own slot-memory write
; bug can't forge an entry) — and the WM then dispatches by ID through
; wm_cb_resolve/wm_cb_trampoline, which read the target from the kernel table.
; The window struct's qword is reduced to "intern input", not "the address we
; jump to". Same per-slot-array + index discipline as the handle table
; (src/kernel/proc/handle_table.inc): one fixed-size row per slot, kernel BSS.
;
; SCOPE (strict file ownership; other agents edit syscall.asm / main.asm /
; launch.inc concurrently):
;   - INVOCATION sites this file owns are routed through the table:
;     CLICKFN (.client_click), RCLICKFN (.right_click), DRAGFN
;     (.app_drag_active). The call target is taken from wm_cb_table, not the
;     window struct.
;   - REGISTRATION (apps installing a callback) lives in syscall.asm
;     (.sc_wm_handlers, CLICKFN/KEYFN) and src/user/apps/launch.inc (KEYFN
;     direct write) — NOT owned here. The full ABI cutover (app registers a
;     slot-local ID instead of a raw pointer; the kernel interns at
;     registration time via wm_cb_intern) requires those owners to call
;     wm_cb_intern at the store site and have apps pass an ID. Until then we
;     intern lazily at dispatch, which still removes the raw pointer from the
;     WM's call target and gives the table a single trusted fill point.
;   - KEYFN INVOCATION lives in main.asm (the two WIN_OFF_KEYFN dispatch
;     sites) — NOT owned here. That owner should swap
;     `mov rdi,[win+KEYFN]; call dispatch_app_callback` for the same
;     intern+`call wm_cb_trampoline` shape used below (field id
;     WM_CB_FIELD_KEY reserved for it).
;   - If CPI-lite callback signing (cpi_sign/verify_callback) lands/relands in
;     this dispatch path, intern the CPI-VERIFIED pointer (defense in depth):
;     verify first, then pass the cleaned pointer to wm_cb_intern.
; ============================================================================

; Per-(slot,field) callback target table — kernel BSS, indexed
; [slot * WM_CB_FIELDS + field]. Holds the trusted kernel-image VA the WM will
; actually jump to. A zero entry means "no callback interned".
WM_CB_FIELD_CLICK   equ 0
WM_CB_FIELD_KEY     equ 1            ; reserved for the main.asm KEYFN site
WM_CB_FIELD_DRAG    equ 2
WM_CB_FIELD_RCLICK  equ 3
WM_CB_FIELDS        equ 4

; wm_cb_intern — record a callback target for (slot, field) in the kernel-owned
; table and return its slot-local id.
;   EDI = slot index (== window index for app windows), 0..MAX_WINDOWS-1
;   ESI = field id (WM_CB_FIELD_*)
;   RDX = target (0 allowed -> "no callback").
; Returns:
;   EAX = packed slot-local callback id (slot * WM_CB_FIELDS + field) + 1, or
;         0 if (slot,field) is out of range OR target is 0. The +1 bias keeps a
;         valid id non-zero so 0 stays a clean "none" sentinel.
; Clobbers RAX, RCX. Preserves RDI/RSI/RDX/R8 and the rest.
wm_cb_intern:
    cmp edi, MAX_WINDOWS
    jae .ci_fail
    cmp esi, WM_CB_FIELDS
    jae .ci_fail
    test rdx, rdx
    jz .ci_fail                       ; no target -> no id
    mov eax, edi
    imul eax, WM_CB_FIELDS
    add eax, esi                      ; eax = flat row index
    mov ecx, eax                      ; save row index for the id
    lea rax, [rel wm_cb_table + rax*8]
    mov [rax], rdx                    ; store target
    lea eax, [rcx + 1]                ; id = row + 1 (non-zero)
    ret
.ci_fail:
    xor eax, eax
    ret

; wm_cb_resolve — look up a slot-local callback id in the kernel-owned table and
; return the stored TRUSTED target. Single read point the dispatch sites take
; their call target from; the window struct is never the source here.
;   EDI = slot-local callback id (as returned by wm_cb_intern; 0 = none)
; Returns:
;   RAX = trusted target, or 0 if id is 0 / out of range / table slot empty.
; Clobbers RAX, RCX. Preserves RSI/RDX/R8 etc. so callers can keep args live.
; File-local leaf helper (no FN_BEGIN trace frame on this hot path); the future
; cross-file KEYFN consumer in main.asm should call wm_cb_trampoline, not this.
wm_cb_resolve:
    test edi, edi
    jz .cr_none
    lea eax, [rdi - 1]                ; flat row index
    cmp eax, MAX_WINDOWS * WM_CB_FIELDS
    jae .cr_none
    lea rcx, [rel wm_cb_table]
    mov rax, [rcx + rax*8]            ; trusted target
    ret
.cr_none:
    xor eax, eax
    ret

; wm_cb_trampoline — the kernel-owned invoker. Resolve a slot-local callback id
; against the table and dispatch the stored TRUSTED target.
;   EDI = slot-local callback id (0 = none)
;   RSI = window ptr (arg0); RDX = arg1; RCX = arg2
; Returns dispatch_app_callback's rax, or 0 (no call) if the id resolves empty.
; Clobbers per dispatch_app_callback. Exposed (FN_BEGIN -> global) so the
; main.asm KEYFN dispatch site can route through it in a later cutover.
FN_BEGIN wm_cb_trampoline, 4, 0, FN_RET_SCALAR
    push rsi
    push rdx
    push rcx
    call wm_cb_resolve                ; rax = trusted target from kernel BSS
    pop rcx
    pop rdx
    pop rsi
    test rax, rax
    jz .ct_none
    mov rdi, rax                      ; target from KERNEL table, not the window
    call dispatch_app_callback
    FN_END wm_cb_trampoline
    ret
.ct_none:
    xor eax, eax
    FN_END wm_cb_trampoline
    ret

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
; titlebar window-drag above — that one moves the whole window; this one
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

; §6 per-slot callback target table (kernel BSS — OUTSIDE the ring-3 app arena,
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
