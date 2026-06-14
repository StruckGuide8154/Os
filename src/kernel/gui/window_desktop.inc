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

; Desktop background renderer. Drives the GritHL wallpaper app
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
    ; the renderer -- wallpaper.ghl reads display_current_width/height through
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

; Runs on an AP through process_submit_job. It renders the authored SVG into the
; selected wallpaper cache at full quality. The callback lock is required while
; shared ring-3 page-table isolation is active; dispatch_app_callback therefore
; refuses to wait on this lock while wallpaper_render_active is set, keeping the
; BSP compositor and input loop responsive during this long AP job.
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

; wm_bg_fill_solid, wm_bg_save_cache, wm_bg_restore_cache, wm_bg_diamond migrated
; to src/kernel/grithlk/wm_helpers.ghl (zero-asm; per-pixel dword loops replace
; the rep stosd/movsd with a byte-identical pixel stream). DESKTOP_SOLID_COLOR is
; mirrored as a const there.

