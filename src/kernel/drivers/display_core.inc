; --- Initialize display driver ---
; Reads loader-provided framebuffer info.
; auto-wrapped (FN_BEGIN emits global): global display_init
FN_BEGIN display_init, 0, 0, FN_RET_SCALAR
    ; Read framebuffer address (full 64-bit for UEFI compatibility)
    mov rax, [abs VBE_INFO_ADDR + VBE_FB_ADDR_OFF]
    mov [fb_addr], rax

    ; Read dimensions
    mov eax, [abs VBE_INFO_ADDR + VBE_WIDTH_OFF]
    mov [scr_width], eax
    mov eax, [abs VBE_INFO_ADDR + VBE_HEIGHT_OFF]
    mov [scr_height], eax
    mov eax, [abs VBE_INFO_ADDR + VBE_PITCH_OFF]
    mov [scr_pitch], eax
    mov [scr_pitch_q], rax

    ; SAFETY: Check for zero dimensions/pitch (loader failure)
    cmp dword [scr_width], 0
    jz .use_fallback
    cmp dword [scr_pitch], 0
    jnz .init_ok

.use_fallback:
    cmp dword [scr_width], 0
    jnz .fix_pitch_only
    mov dword [scr_width], 1024
    mov dword [scr_height], 768
.fix_pitch_only:
    mov eax, [scr_width]
    shl eax, 2
    mov [scr_pitch], eax
    mov [scr_pitch_q], rax

.init_ok:
    ; Latch the native framebuffer dimensions. Apps query these via
    ; SYS_DISPLAY_NATIVE to offer a "Use native resolution" choice that
    ; survives mode changes.
    mov eax, [scr_width]
    mov [fb_native_width], eax
    mov eax, [scr_height]
    mov [fb_native_height], eax

    ; Latch the loader's actual mapped framebuffer end. The loader sized the FB
    ; mapping and placed the unmapped guard page from VBE_HEIGHT*VBE_PITCH in the
    ; VBE_INFO block (uefi_loader_paging_exit.inc). Read those SAME fields here -
    ; NOT scr_height/scr_pitch_q, which the kernel may round/re-set independently
    ; and let drift above the mapped extent - so the flip backstop and the loader
    ; mapping cannot disagree by even one byte. See fb_mapped_end_q.
    mov eax, [abs VBE_INFO_ADDR + VBE_HEIGHT_OFF]
    mov ecx, [abs VBE_INFO_ADDR + VBE_PITCH_OFF]
    imul rax, rcx
    test rax, rax
    jz .fb_mapped_skip            ; degenerate VBE geometry -> leave 0 (fallback)
    add rax, [fb_addr]
    mov [fb_mapped_end_q], rax
.fb_mapped_skip:

    ; Set back buffer address
    mov rax, [abs VBE_INFO_ADDR + VBE_BACKBUF_OFF]
    test rax, rax
    jnz .have_backbuf
    mov rax, BACK_BUFFER_ADDR
.have_backbuf:
    mov [bb_addr], rax

    call display_recompute_layout
    call raster_select_default_target
    call amd_display_init

    ; Clear back buffer
    xor edi, edi             ; Black (color arg in edi)
    call display_clear

    ret

; Select the backbuffer as the destination for raster primitives.
global raster_select_default_target
raster_select_default_target:
    push rax
    mov rax, [bb_addr]
    mov [raster_target_addr], rax
    mov eax, [scr_width]
    mov [raster_target_width], eax
    mov eax, [scr_height]
    mov [raster_target_height], eax
    mov rax, [scr_pitch_q]
    mov [raster_target_pitch_q], rax
    pop rax
    ret

; Select the destination for a usermode raster syscall.
; EDI = L3 slot.  Slot 0 is the hidden wallpaper renderer; while its AP job is
; active, SVG raster primitives write directly into the wallpaper cache instead
; of mutating bb_addr globally.
;
; Acquires raster_target_lock before mutating the shared raster_target_*
; globals. Without this, the wallpaper rasterizer (running on an AP) and the
; BSP could both call this routine in parallel - the BSP's call would overwrite
; the AP's target mid-raster-op, sending the AP's pixel writes into bb_addr at
; framebuffer-pitch offsets computed for a packed-pitch cache. That produced
; the skewed-stripes wallpaper bug on real hardware (true SMP); QEMU TCG
; serialized vCPUs and hid it. Pair every call with raster_sc_release_target.
global raster_select_syscall_target
raster_select_syscall_target:
    push rax
.spin:
    mov al, 1
    xchg [raster_target_lock], al
    test al, al
    jnz .pause
    cmp edi, 0
    jne .use_default
    cmp byte [wallpaper_render_active], 1
    jne .use_default
    cmp dword [wallpaper_render_w], 0
    jle .use_default
    cmp dword [wallpaper_render_h], 0
    jle .use_default
    mov rax, [wallpaper_render_target_addr]
    mov [raster_target_addr], rax
    mov eax, [wallpaper_render_w]
    mov [raster_target_width], eax
    shl eax, 2
    mov [raster_target_pitch_q], rax
    mov eax, [wallpaper_render_h]
    mov [raster_target_height], eax
    pop rax
    ret
.use_default:
    mov rax, [bb_addr]
    mov [raster_target_addr], rax
    mov eax, [scr_width]
    mov [raster_target_width], eax
    mov eax, [scr_height]
    mov [raster_target_height], eax
    mov rax, [scr_pitch_q]
    mov [raster_target_pitch_q], rax
    pop rax
    ret
.pause:
    pause
    jmp .spin

; Reset the raster target to bb_addr and release raster_target_lock. Paired
; with raster_select_syscall_target at every raster-syscall epilog.
global raster_sc_release_target
raster_sc_release_target:
    push rax
    mov rax, [bb_addr]
    mov [raster_target_addr], rax
    mov eax, [scr_width]
    mov [raster_target_width], eax
    mov eax, [scr_height]
    mov [raster_target_height], eax
    mov rax, [scr_pitch_q]
    mov [raster_target_pitch_q], rax
    mov byte [raster_target_lock], 0
    pop rax
    ret

; --- Recompute window-manager layout for the current scr_width/scr_height
; The taskbar lives flush to the bottom edge; the clock is right-anchored
; in the taskbar; the start menu pops up from the start button. taskbar.asm
; previously baked these positions in as compile-time constants from
; SCREEN_WIDTH/SCREEN_HEIGHT. We now recompute them whenever the screen
; size changes so the taskbar follows the active mode.
;
; Layout constants (must match taskbar.asm - single source of truth would
; be nicer, but they're stable and only used here for the recompute):
;   TASKBAR_HEIGHT  = 36
;   CLOCK_WIDTH     = 64
;   START_MENU_H    = 200
;   BAT_IND_W       = 88
; auto-wrapped (FN_BEGIN emits global): global display_recompute_layout
FN_BEGIN display_recompute_layout, 0, 0, FN_RET_SCALAR
    mov eax, [scr_height]
    sub eax, TASKBAR_HEIGHT       ; taskbar Y = screen bottom - taskbar height
    mov [scr_taskbar_y], eax
    mov ecx, eax
    add ecx, 4                    ; +4 = start button / taskbar button Y inset
    mov [scr_start_btn_y], ecx
    mov [scr_tb_btn_y], ecx
    mov [scr_bat_ind_y], ecx
    mov ecx, eax
    add ecx, 10                   ; +10 = clock Y inset
    mov [scr_clock_y], ecx
    mov ecx, eax
    sub ecx, [tb_start_menu_h]    ; -START_MENU_H = start menu top (data-driven)
    mov [scr_start_menu_y], ecx

    mov eax, [scr_width]
    sub eax, CLOCK_WIDTH
    sub eax, 8                    ; right inset for clock
    mov [scr_clock_x], eax
    sub eax, 88                   ; -BAT_IND_W
    sub eax, 6                    ; gap between battery and clock
    mov [scr_bat_ind_x], eax

    ret

; --- Set pixel ---
; EDI = x, ESI = y, EDX = color (0x00RRGGBB)
; auto-wrapped (FN_BEGIN emits global): global pixel_set
FN_BEGIN pixel_set, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    ; Bounds check
    cmp edi, 0
    jl .done
    cmp edi, [raster_target_width]
    jge .done
    cmp esi, 0
    jl .done
    cmp esi, [raster_target_height]
    jge .done

    ; Calculate offset: y * pitch + x * 4
    movsxd rax, esi
    imul rax, [raster_target_pitch_q]
    movsxd rbx, edi
    lea rax, [rax + rbx * 4]
    mov rbx, [raster_target_addr]
    mov [rbx + rax], edx

.done:
    pop rbx
    pop rax
    ret

; --- Blend pixel with source-over alpha ---
; EDI = x, ESI = y, EDX = color (0xAARRGGBB)
; dst = src*a + dst*(255-a), per channel, 8-bit
FN_BEGIN blend_pixel, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push r8
    push r9
    push r10
    cmp edi, 0
    jl .bp_done
    cmp edi, [raster_target_width]
    jge .bp_done
    cmp esi, 0
    jl .bp_done
    cmp esi, [raster_target_height]
    jge .bp_done

    movsxd rax, esi
    imul rax, [raster_target_pitch_q]
    movsxd rbx, edi
    lea rax, [rax + rbx * 4]
    mov r10, [raster_target_addr]
    add r10, rax              ; r10 = &dst pixel

    mov ecx, edx              ; src ARGB
    shr ecx, 24
    and ecx, 0xFF             ; ecx = a
    test ecx, ecx
    jz .bp_done               ; fully transparent
    cmp ecx, 0xFF
    jne .bp_blend
    mov [r10], edx            ; opaque shortcut
    jmp .bp_done

.bp_blend:
    mov r9d, 255
    sub r9d, ecx              ; r9 = 255 - a
    mov eax, [r10]            ; dst pixel

    ; R channel
    mov r8d, edx
    shr r8d, 16
    and r8d, 0xFF             ; src R
    imul r8d, ecx
    mov ebx, eax
    shr ebx, 16
    and ebx, 0xFF             ; dst R
    imul ebx, r9d
    add r8d, ebx
    add r8d, 128
    shr r8d, 8                ; ~ /255
    and r8d, 0xFF
    shl r8d, 16
    mov ebx, r8d              ; ebx accumulates result

    ; G channel
    mov r8d, edx
    shr r8d, 8
    and r8d, 0xFF
    imul r8d, ecx
    mov eax, [r10]
    shr eax, 8
    and eax, 0xFF
    imul eax, r9d
    add r8d, eax
    add r8d, 128
    shr r8d, 8
    and r8d, 0xFF
    shl r8d, 8
    or ebx, r8d

    ; B channel
    mov r8d, edx
    and r8d, 0xFF
    imul r8d, ecx
    mov eax, [r10]
    and eax, 0xFF
    imul eax, r9d
    add r8d, eax
    add r8d, 128
    shr r8d, 8
    and r8d, 0xFF
    or ebx, r8d

    mov [r10], ebx
.bp_done:
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    pop rax
    ret
