; ============================================================================
; NexusOS v3.0 - VBE Framebuffer Display Driver (SSE2 Optimized)
; Pixel, rect, char, string, blit, double buffer
; Uses SSE2 non-temporal stores for VRAM writes (massive speedup)
; Uses SSE2 128-bit fills for back buffer operations (4 pixels/instruction)
; ============================================================================
bits 64

%include "constants.inc"
extern tick_count
extern frame_count
extern start_tick
extern serial_putc
extern wallpaper_render_active
extern wallpaper_render_target_addr
extern wallpaper_render_w
extern wallpaper_render_h
extern amd_display_init
extern amd_display_set_mode
extern amd_display_active

section .text

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
; BSP could both call this routine in parallel — the BSP's call would overwrite
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
; Layout constants (must match taskbar.asm — single source of truth would
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

; --- Blend horizontal span (source-over) ---
; EDI = x, ESI = y, EDX = len, ECX = color (0xAARRGGBB)
FN_BEGIN blend_span, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push r12
    push r13
    push r14
    push rdi
    push rsi
    push rdx
    push rcx

    movsxd r12, edi
    movsxd r13, esi
    movsxd r14, edx           ; len
    test r14, r14
    jle .bs_done

    ; Clip y
    cmp r13, 0
    jl .bs_done
    mov eax, [scr_height]
    cmp r13, rax
    jge .bs_done

    ; Clip left
    cmp r12, 0
    jge .bs_cl_right
    add r14, r12              ; len += x (x is negative)
    xor r12d, r12d
.bs_cl_right:
    cmp r14, 0
    jle .bs_done
    mov eax, [scr_width]
    cmp r12, rax
    jge .bs_done
    mov rbx, rax
    sub rbx, r12              ; max width from x
    cmp r14, rbx
    jle .bs_loop
    mov r14, rbx
.bs_loop:
    test r14, r14
    jle .bs_done
    mov edi, r12d
    mov esi, r13d
    mov edx, ecx
    push rcx
    call blend_pixel
    pop rcx
    inc r12
    dec r14
    jmp .bs_loop
.bs_done:
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rax
    ret

; --- Blend horizontal span from a per-pixel ARGB buffer (source-over) ---
; EDI = x, ESI = y, EDX = len, RCX = src buffer (len * 4 bytes, ARGB each)
; One syscall replaces `len` calls to blend_pixel — used by the SVG raster
; scanline filler to avoid the kernel round-trip per pixel.
FN_BEGIN blend_span_argb, 0, 0, FN_RET_SCALAR
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
    push r12
    push r13
    push r14
    push r15

    movsxd r12, edi               ; r12 = x
    movsxd r13, esi               ; r13 = y
    movsxd r14, edx               ; r14 = len
    mov    r15, rcx               ; r15 = src buffer pointer

    test r14, r14
    jle .bsa_done

    ; Clip y
    cmp r13, 0
    jl .bsa_done
    mov eax, [scr_height]
    cmp r13, rax
    jge .bsa_done

    ; Clip left: if x < 0, skip (-x) pixels at the start of the source buffer.
    cmp r12, 0
    jge .bsa_cl_right
    mov rax, r12
    neg rax                       ; rax = -x = pixels to skip
    add r14, r12                  ; len += x (x is negative)
    jle .bsa_done
    lea r15, [r15 + rax * 4]      ; advance src past skipped pixels
    xor r12d, r12d
.bsa_cl_right:
    mov eax, [raster_target_width]
    cmp r12, rax
    jge .bsa_done
    mov rbx, rax
    sub rbx, r12
    cmp r14, rbx
    jle .bsa_setup
    mov r14, rbx                  ; clip len to remaining row width
.bsa_setup:
    ; dst row addr = bb_addr + y * pitch + x * 4
    mov rax, r13
    imul rax, [scr_pitch_q]
    mov rdi, [raster_target_addr]
    add rdi, rax
    lea rdi, [rdi + r12 * 4]         ; rdi = dst pixel pointer
    mov rsi, r15                     ; rsi = src pixel pointer
    mov ecx, r14d                    ; ecx = pixel count

.bsa_loop:
    mov eax, [rsi]                ; eax = src ARGB
    add rsi, 4
    mov edx, eax
    shr edx, 24
    and edx, 0xFF                 ; edx = sa
    jz .bsa_next                  ; fully transparent
    cmp edx, 0xFF
    jne .bsa_blend
    mov [rdi], eax                ; opaque
    jmp .bsa_next

.bsa_blend:
    ; r9d = 255 - sa
    mov r9d, 255
    sub r9d, edx
    mov r8d, [rdi]                ; dst ARGB

    ; R channel:  (sr*sa + dr*(255-sa) + 128) >> 8
    mov r10d, eax
    shr r10d, 16
    and r10d, 0xFF
    imul r10d, edx                ; sr*sa
    mov r11d, r8d
    shr r11d, 16
    and r11d, 0xFF
    imul r11d, r9d                ; dr*(255-sa)
    add r10d, r11d
    add r10d, 128
    shr r10d, 8
    and r10d, 0xFF
    shl r10d, 16
    mov ebx, r10d                 ; ebx accumulates output

    ; G channel
    mov r10d, eax
    shr r10d, 8
    and r10d, 0xFF
    imul r10d, edx
    mov r11d, r8d
    shr r11d, 8
    and r11d, 0xFF
    imul r11d, r9d
    add r10d, r11d
    add r10d, 128
    shr r10d, 8
    and r10d, 0xFF
    shl r10d, 8
    or ebx, r10d

    ; B channel
    mov r10d, eax
    and r10d, 0xFF
    imul r10d, edx
    mov r11d, r8d
    and r11d, 0xFF
    imul r11d, r9d
    add r10d, r11d
    add r10d, 128
    shr r10d, 8
    and r10d, 0xFF
    or ebx, r10d

    mov [rdi], ebx

.bsa_next:
    add rdi, 4
    dec ecx
    jnz .bsa_loop

.bsa_done:
    pop r15
    pop r14
    pop r13
    pop r12
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

; --- Blend horizontal span from ARGB buffer (screen blend mode) ---
; EDI = x, ESI = y, EDX = len, RCX = src buffer (len * 4 bytes, ARGB each)
; Implements CSS mix-blend-mode: screen. The back buffer is opaque, so the
; per-channel result is:  out = sa*screen(d,s) + (255-sa)*d, where
; screen(d,s) = s + d - s*d/255. Unlike source-over there is no opaque
; shortcut: an opaque source still mixes with the backdrop via screen().
FN_BEGIN blend_span_argb_screen, 0, 0, FN_RET_SCALAR
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
    push r12
    push r13
    push r14
    push r15

    movsxd r12, edi               ; r12 = x
    movsxd r13, esi               ; r13 = y
    movsxd r14, edx               ; r14 = len
    mov    r15, rcx               ; r15 = src buffer pointer

    test r14, r14
    jle .bss_done

    cmp r13, 0
    jl .bss_done
    mov eax, [scr_height]
    cmp r13, rax
    jge .bss_done

    cmp r12, 0
    jge .bss_cl_right
    mov rax, r12
    neg rax
    add r14, r12
    jle .bss_done
    lea r15, [r15 + rax * 4]
    xor r12d, r12d
.bss_cl_right:
    mov eax, [raster_target_width]
    cmp r12, rax
    jge .bss_done
    mov rbx, rax
    sub rbx, r12
    cmp r14, rbx
    jle .bss_setup
    mov r14, rbx
.bss_setup:
    mov rax, r13
    imul rax, [scr_pitch_q]
    mov rdi, [raster_target_addr]
    add rdi, rax
    lea rdi, [rdi + r12 * 4]         ; rdi = dst pixel pointer
    mov rsi, r15                     ; rsi = src pixel pointer

.bss_loop:
    mov eax, [rsi]                ; eax = src ARGB
    add rsi, 4
    mov edx, eax
    shr edx, 24
    and edx, 0xFF                 ; edx = sa
    jz .bss_next                  ; fully transparent
    mov r9d, 255
    sub r9d, edx                  ; r9d = 255 - sa
    mov r8d, [rdi]                ; r8d = dst ARGB
    xor ebx, ebx                  ; ebx accumulates output

    ; R channel
    mov r10d, eax
    shr r10d, 16
    and r10d, 0xFF                ; r10d = s
    mov r11d, r8d
    shr r11d, 16
    and r11d, 0xFF                ; r11d = d
    mov ecx, r10d
    imul ecx, r11d
    add ecx, 128
    shr ecx, 8                    ; ecx = s*d/255
    add r10d, r11d
    sub r10d, ecx                 ; r10d = screen(d,s)
    imul r10d, edx                ; screen*sa
    mov ecx, r11d
    imul ecx, r9d                 ; d*(255-sa)
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 16
    or ebx, ecx

    ; G channel
    mov r10d, eax
    shr r10d, 8
    and r10d, 0xFF
    mov r11d, r8d
    shr r11d, 8
    and r11d, 0xFF
    mov ecx, r10d
    imul ecx, r11d
    add ecx, 128
    shr ecx, 8
    add r10d, r11d
    sub r10d, ecx
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 8
    or ebx, ecx

    ; B channel
    mov r10d, eax
    and r10d, 0xFF
    mov r11d, r8d
    and r11d, 0xFF
    mov ecx, r10d
    imul ecx, r11d
    add ecx, 128
    shr ecx, 8
    add r10d, r11d
    sub r10d, ecx
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    or ebx, ecx

    mov [rdi], ebx

.bss_next:
    add rdi, 4
    dec r14d
    jnz .bss_loop

.bss_done:
    pop r15
    pop r14
    pop r13
    pop r12
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

; --- Blend horizontal span from ARGB buffer (multiply blend mode) ---
; EDI = x, ESI = y, EDX = len, RCX = src buffer (len * 4 bytes, ARGB each)
; CSS mix-blend-mode: multiply over an opaque back buffer:
; out = sa*multiply(d,s) + (255-sa)*d, multiply(d,s)=d*s/255.
FN_BEGIN blend_span_argb_multiply, 0, 0, FN_RET_SCALAR
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
    push r12
    push r13
    push r14
    push r15

    movsxd r12, edi
    movsxd r13, esi
    movsxd r14, edx
    mov    r15, rcx

    test r14, r14
    jle .bsm_done
    cmp r13, 0
    jl .bsm_done
    mov eax, [raster_target_height]
    cmp r13, rax
    jge .bsm_done
    cmp r12, 0
    jge .bsm_cl_right
    mov rax, r12
    neg rax
    add r14, r12
    jle .bsm_done
    lea r15, [r15 + rax * 4]
    xor r12d, r12d
.bsm_cl_right:
    mov eax, [raster_target_width]
    cmp r12, rax
    jge .bsm_done
    mov rbx, rax
    sub rbx, r12
    cmp r14, rbx
    jle .bsm_setup
    mov r14, rbx
.bsm_setup:
    mov rax, r13
    imul rax, [raster_target_pitch_q]
    mov rdi, [raster_target_addr]
    add rdi, rax
    lea rdi, [rdi + r12 * 4]
    mov rsi, r15

.bsm_loop:
    mov eax, [rsi]
    add rsi, 4
    mov edx, eax
    shr edx, 24
    and edx, 0xFF
    jz .bsm_next
    mov r9d, 255
    sub r9d, edx
    mov r8d, [rdi]
    xor ebx, ebx

    ; R channel
    mov r10d, eax
    shr r10d, 16
    and r10d, 0xFF
    mov r11d, r8d
    shr r11d, 16
    and r11d, 0xFF
    imul r10d, r11d
    add r10d, 128
    shr r10d, 8                    ; multiply(d,s)
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 16
    or ebx, ecx

    ; G channel
    mov r10d, eax
    shr r10d, 8
    and r10d, 0xFF
    mov r11d, r8d
    shr r11d, 8
    and r11d, 0xFF
    imul r10d, r11d
    add r10d, 128
    shr r10d, 8
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    shl ecx, 8
    or ebx, ecx

    ; B channel
    mov r10d, eax
    and r10d, 0xFF
    mov r11d, r8d
    and r11d, 0xFF
    imul r10d, r11d
    add r10d, 128
    shr r10d, 8
    imul r10d, edx
    mov ecx, r11d
    imul ecx, r9d
    add ecx, r10d
    add ecx, 128
    shr ecx, 8
    and ecx, 0xFF
    or ebx, ecx

    mov [rdi], ebx

.bsm_next:
    add rdi, 4
    dec r14d
    jnz .bsm_loop

.bsm_done:
    pop r15
    pop r14
    pop r13
    pop r12
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

; --- Fill rectangle (SSE2 optimized) ---
; EDI = x, ESI = y, EDX = w, ECX = h, R8D = color
; auto-wrapped (FN_BEGIN emits global): global fill_rect
FN_BEGIN fill_rect, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r9
    push r10
    push r11
    push r12
    push r13

    ; Clip to screen bounds.  Keep all geometry and address math in 64-bit
    ; registers so hostile 32-bit inputs cannot wrap back into kernel memory.
    movsxd r9, edi           ; x
    movsxd r10, esi          ; y
    movsxd r11, edx          ; w
    movsxd r12, ecx          ; h
    mov r13d, r8d            ; color

    ; Clip left
    cmp r9, 0
    jge .clip_right
    add r11, r9              ; Reduce width
    xor r9d, r9d             ; x = 0
.clip_right:
    cmp r11, 0
    jle .rect_done
    mov eax, [scr_width]
    cmp r9, rax
    jae .rect_done
    mov rbx, rax
    mov rax, r9
    add rax, r11
    cmp rax, rbx
    jbe .clip_top
    mov r11, rbx
    sub r11, r9
.clip_top:
    cmp r10, 0
    jge .clip_bottom
    add r12, r10
    xor r10d, r10d
.clip_bottom:
    cmp r12, 0
    jle .rect_done
    mov eax, [scr_height]
    cmp r10, rax
    jae .rect_done
    mov rbx, rax
    mov rax, r10
    add rax, r12
    cmp rax, rbx
    jbe .clip_done
    mov r12, rbx
    sub r12, r10
.clip_done:
    ; Validate dimensions
    cmp r11, 0
    jle .rect_done
    cmp r12, 0
    jle .rect_done

    ; Calculate starting offset
    mov rax, r10
    imul rax, [scr_pitch_q]
    lea rax, [rax + r9 * 4]
    mov rbx, [bb_addr]
    add rbx, rax

    ; Prepare SSE2 color vector: broadcast color to all 4 dword lanes
    movd xmm0, r13d
    pshufd xmm0, xmm0, 0    ; xmm0 = [color, color, color, color]

    mov rsi, [scr_pitch_q]

    ; Simple robust fill using rep stosd
    mov rdi, rbx             ; RDI = starting address in back buffer
    mov rcx, r11             ; RCX = width in pixels
.row_loop:
    push rdi
    push rcx
    mov eax, r13d            ; Color
    rep stosd                ; Fill row
    pop rcx
    pop rdi

    add rdi, rsi             ; Next row (add pitch)
    dec r12
    jnz .row_loop

.rect_done:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Draw single character (optimized fast path) ---
; EDI = x, ESI = y, DL = character, ECX = fg_color, R8D = bg_color
; auto-wrapped (FN_BEGIN emits global): global draw_char
FN_BEGIN draw_char, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    movzx r9d, dl            ; Character
    mov r10d, edi             ; x
    mov r11d, esi             ; y
    mov r12d, ecx             ; fg color
    mov r13d, r8d             ; bg color

    ; Get font data pointer
    sub r9d, FONT_FIRST_CHAR
    cmp r9d, FONT_NUM_CHARS
    jge .char_done
    cmp r9d, 0
    jl .char_done

    extern font_data
    lea rbx, [font_data]
    shl r9d, 4               ; * 16 bytes per char
    add rbx, r9

    ; Quick reject: if entirely off-screen, skip
    cmp r10d, [scr_width]
    jge .char_done
    cmp r11d, [scr_height]
    jge .char_done
    mov eax, r10d
    add eax, FONT_WIDTH
    cmp eax, 0
    jle .char_done
    mov eax, r11d
    add eax, FONT_HEIGHT
    cmp eax, 0
    jle .char_done

    ; FAST PATH: if character is fully on-screen (x>=0 && x+8<=width && y>=0 && y+16<=height)
    ; we can skip all per-pixel clipping and use direct writes
    cmp r10d, 0
    jl .slow_path
    mov eax, r10d
    add eax, 8
    cmp eax, [scr_width]
    jg .slow_path
    cmp r11d, 0
    jl .slow_path
    mov eax, r11d
    add eax, 16
    cmp eax, [scr_height]
    jg .slow_path

    ; === FAST PATH: No clipping needed ===
    ; Pre-calculate row start in back buffer
    movsxd rax, r11d
    imul rax, [scr_pitch_q]
    lea rax, [rax + r10 * 4]
    mov r14, [bb_addr]
    add r14, rax              ; r14 = pointer to first pixel of char in BB

    mov r15, [scr_pitch_q]     ; pitch for row advance

    mov r9d, 16               ; 16 rows
.fast_row:
    movzx eax, byte [rbx]     ; Font row byte

    ; Check if transparent bg - if so, we must handle per-pixel
    cmp r13d, -1
    je .fast_row_transparent

    ; Opaque background: write all 8 pixels unconditionally (2 dwords at a time)
    ; Pixel 0 (MSB)
    test al, 0x80
    mov ecx, r13d             ; assume bg
    cmovnz ecx, r12d          ; if bit set, use fg
    mov [r14], ecx
    ; Pixel 1
    test al, 0x40
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 4], ecx
    ; Pixel 2
    test al, 0x20
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 8], ecx
    ; Pixel 3
    test al, 0x10
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 12], ecx
    ; Pixel 4
    test al, 0x08
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 16], ecx
    ; Pixel 5
    test al, 0x04
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 20], ecx
    ; Pixel 6
    test al, 0x02
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 24], ecx
    ; Pixel 7 (LSB)
    test al, 0x01
    mov ecx, r13d
    cmovnz ecx, r12d
    mov [r14 + 28], ecx

    jmp .fast_row_next

.fast_row_transparent:
    ; Transparent background: only write foreground pixels
    test al, 0x80
    jz .ft1
    mov [r14], r12d
.ft1:
    test al, 0x40
    jz .ft2
    mov [r14 + 4], r12d
.ft2:
    test al, 0x20
    jz .ft3
    mov [r14 + 8], r12d
.ft3:
    test al, 0x10
    jz .ft4
    mov [r14 + 12], r12d
.ft4:
    test al, 0x08
    jz .ft5
    mov [r14 + 16], r12d
.ft5:
    test al, 0x04
    jz .ft6
    mov [r14 + 20], r12d
.ft6:
    test al, 0x02
    jz .ft7
    mov [r14 + 24], r12d
.ft7:
    test al, 0x01
    jz .fast_row_next
    mov [r14 + 28], r12d

.fast_row_next:
    inc rbx                   ; Next font row
    add r14, r15              ; Next screen row
    dec r9d
    jnz .fast_row
    jmp .char_done

.slow_path:
    ; === SLOW PATH: Per-pixel clipping (edge cases) ===
    mov r14d, 16             ; Row counter
.char_row:
    ; Skip row if Y out of bounds
    cmp r11d, 0
    jl .skip_row
    cmp r11d, [scr_height]
    jge .char_done           ; All remaining rows are off-screen

    movzx eax, byte [rbx]    ; Font row byte
    mov ecx, 8               ; 8 pixels per row

    ; Calculate row start pointer
    push r9
    movsxd r9, r11d
    imul r9, [scr_pitch_q]
    movsxd rax, r10d
    lea r9, [r9 + rax * 4]
    mov rdi, [bb_addr]
    add rdi, r9
    pop r9

    ; Track current X for clipping
    push r9
    mov r9d, r10d            ; Current pixel X

.char_pixel:
    ; Clip X
    cmp r9d, 0
    jl .skip_pixel
    cmp r9d, [scr_width]
    jge .row_done_pop

    test al, 0x80            ; Test MSB
    jz .bg_pixel
    mov dword [rdi], r12d    ; Foreground
    jmp .next_pixel
.bg_pixel:
    cmp r13d, -1             ; -1 = transparent background
    je .next_pixel
    mov dword [rdi], r13d    ; Background
.next_pixel:
.skip_pixel:
    shl al, 1
    add rdi, 4
    inc r9d
    dec ecx
    jnz .char_pixel

.row_done_pop:
    pop r9

.skip_row:
    inc rbx                  ; Next font row
    inc r11d                 ; Next screen row
    dec r14d
    jnz .char_row

.char_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop rbx
    pop rax
    ret

; --- Draw null-terminated string ---
; EDI = x, ESI = y, RDX = pointer to string, ECX = fg_color, R8D = bg_color
; auto-wrapped (FN_BEGIN emits global): global draw_string
FN_BEGIN draw_string, 0, 0, FN_RET_SCALAR
    push rbx
    push r9
    push r10
    push r11

    mov r9d, edi             ; Current x
    mov r10d, esi            ; y
    mov rbx, rdx             ; String pointer
    mov r11d, ecx            ; fg color (preserve for all chars)

    ; Quick reject: if string Y is entirely off-screen, skip
    cmp r10d, [scr_height]
    jge .str_done
    mov eax, r10d
    add eax, FONT_HEIGHT
    cmp eax, 0
    jle .str_done

.str_loop:
    movzx eax, byte [rbx]
    test al, al
    jz .str_done

    ; Skip chars that are entirely past right edge
    cmp r9d, [scr_width]
    jge .str_done

    ; Draw character (draw_char handles left-edge clipping)
    mov edi, r9d
    mov esi, r10d
    mov dl, al
    mov ecx, r11d
    ; R8D already has bg_color
    call draw_char

    add r9d, FONT_WIDTH      ; Advance x by character width
    inc rbx
    jmp .str_loop

.str_done:
    pop r11
    pop r10
    pop r9
    pop rbx
    ret

; --- Draw horizontal line ---
; EDI = x, ESI = y, EDX = width, ECX = color
; auto-wrapped (FN_BEGIN emits global): global draw_hline
FN_BEGIN draw_hline, 0, 0, FN_RET_SCALAR
    push r8
    mov r8d, ecx             ; color
    mov ecx, 1               ; height = 1
    call fill_rect
    pop r8
    ret

; Target-aware scanline used by SVG raster primitives only. Normal GUI chrome
; uses draw_hline/fill_rect above, which always write to the real backbuffer.
draw_hline_raster:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    push r9
    push r10
    movsxd r9, edi            ; x
    movsxd r10, esi           ; y
    movsxd rbx, edx           ; width
    test rbx, rbx
    jle .done
    cmp r10, 0
    jl .done
    mov eax, [raster_target_height]
    cmp r10, rax
    jge .done
    cmp r9, 0
    jge .clip_right
    add rbx, r9
    jle .done
    xor r9d, r9d
.clip_right:
    mov eax, [raster_target_width]
    cmp r9, rax
    jge .done
    mov rdi, rax
    sub rdi, r9
    cmp rbx, rdi
    jle .addr
    mov rbx, rdi
.addr:
    mov rax, r10
    imul rax, [raster_target_pitch_q]
    lea rax, [rax + r9 * 4]
    mov rdi, [raster_target_addr]
    add rdi, rax
    mov eax, ecx
    mov rcx, rbx
    rep stosd
.done:
    pop r10
    pop r9
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; --- Draw vertical line ---
; EDI = x, ESI = y, EDX = height, ECX = color
; auto-wrapped (FN_BEGIN emits global): global draw_vline
FN_BEGIN draw_vline, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push r8

    ; Clip
    cmp edi, 0
    jl .vl_done
    cmp edi, [scr_width]
    jge .vl_done

    mov r8d, ecx             ; color
    mov eax, esi             ; y
    mov ebx, edx             ; height

.vl_loop:
    cmp ebx, 0
    jle .vl_done
    cmp eax, 0
    jl .vl_next
    cmp eax, [scr_height]
    jge .vl_done

    ; Write pixel
    push rax
    imul rax, [scr_pitch_q]
    movsxd rcx, edi
    lea rax, [rax + rcx * 4]
    mov rcx, [bb_addr]
    mov [rcx + rax], r8d
    pop rax

.vl_next:
    inc eax
    dec ebx
    jmp .vl_loop

.vl_done:
    pop r8
    pop rbx
    pop rax
    ret

; --- Draw rectangle outline ---
; EDI = x, ESI = y, EDX = w, ECX = h, R8D = color
; auto-wrapped (FN_BEGIN emits global): global draw_rect_outline
FN_BEGIN draw_rect_outline, 0, 0, FN_RET_SCALAR
    push rdi
    push rsi
    push rdx
    push rcx
    push r8

    ; Save params
    push rdi                 ; x
    push rsi                 ; y
    push rdx                 ; w
    push rcx                 ; h

    ; Top line
    mov ecx, r8d
    mov edx, [rsp + 8]      ; w
    call draw_hline

    ; Bottom line
    mov edi, [rsp + 24]     ; x
    mov esi, [rsp + 16]     ; y
    add esi, [rsp]           ; + h - 1
    dec esi
    mov edx, [rsp + 8]      ; w
    mov ecx, r8d
    call draw_hline

    ; Left line
    mov edi, [rsp + 24]
    mov esi, [rsp + 16]
    mov edx, [rsp]           ; h
    mov ecx, r8d
    call draw_vline

    ; Right line
    mov edi, [rsp + 24]
    add edi, [rsp + 8]      ; x + w - 1
    dec edi
    mov esi, [rsp + 16]
    mov edx, [rsp]
    mov ecx, r8d
    call draw_vline

    add rsp, 32
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; ============================================================================
; SSE2 Non-Temporal Flip: back buffer -> framebuffer (VRAM)
; Uses MOVNTDQ to bypass CPU cache - massive speedup for VRAM writes
; ============================================================================

; --- Flip entire back buffer to framebuffer ---
; auto-wrapped (FN_BEGIN emits global): global display_flip
FN_BEGIN display_flip, 0, 0, FN_RET_SCALAR
    push rax
    push rcx
    push rsi
    push rdi
    extern fbperf_flip_full_begin
    extern fbperf_flip_full_end
    call fbperf_flip_full_begin

    mov rdi, [fb_addr]       ; Destination: framebuffer (VRAM)
    mov rsi, [bb_addr]       ; Source: back buffer (RAM)

    ; Calculate total size in bytes: pitch * height
    mov eax, [scr_pitch]
    imul eax, [scr_height]
    mov ecx, eax             ; Total bytes

    ; SSE2 non-temporal copy: 128 bytes per iteration (8x movntdq)
    shr ecx, 7               ; / 128 for 128-byte chunks
    jz .flip_tail

.flip_sse_loop:
    ; Load 128 bytes from RAM (cached, fast)
    movdqa xmm0, [rsi]
    movdqa xmm1, [rsi + 16]
    movdqa xmm2, [rsi + 32]
    movdqa xmm3, [rsi + 48]
    movdqa xmm4, [rsi + 64]
    movdqa xmm5, [rsi + 80]
    movdqa xmm6, [rsi + 96]
    movdqa xmm7, [rsi + 112]
    ; Store 128 bytes to VRAM (non-temporal, bypasses cache)
    movntdq [rdi], xmm0
    movntdq [rdi + 16], xmm1
    movntdq [rdi + 32], xmm2
    movntdq [rdi + 48], xmm3
    movntdq [rdi + 64], xmm4
    movntdq [rdi + 80], xmm5
    movntdq [rdi + 96], xmm6
    movntdq [rdi + 112], xmm7
    add rsi, 128
    add rdi, 128
    dec ecx
    jnz .flip_sse_loop

    ; Memory fence to ensure all NT stores are visible
    sfence

.flip_tail:
    ; Handle remaining bytes (< 128) with rep movsq
    mov eax, [scr_pitch]
    imul eax, [scr_height]
    and eax, 127             ; Remainder
    mov ecx, eax
    shr ecx, 3
    rep movsq
    mov ecx, eax
    and ecx, 7
    rep movsb

    call fbperf_flip_full_end
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; --- Flip rectangle from back buffer to framebuffer (SSE2 NT) ---
; EDI = x, ESI = y, EDX = w, ECX = h
; auto-wrapped (FN_BEGIN emits global): global display_flip_rect
FN_BEGIN display_flip_rect, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push r8
    push r9
    push r10
    push r11
    push r12
    extern fbperf_flip_rect_begin
    extern fbperf_flip_rect_end
    extern fbperf_flip_rect_note_size
    call fbperf_flip_rect_begin

    ; Clip
    cmp edi, 0
    jge .fr_noclip_l
    add edx, edi
    xor edi, edi
.fr_noclip_l:
    cmp esi, 0
    jge .fr_noclip_t
    add ecx, esi
    xor esi, esi
.fr_noclip_t:
    mov eax, edi
    add eax, edx
    cmp eax, [scr_width]
    jle .fr_noclip_r
    mov edx, [scr_width]
    sub edx, edi
.fr_noclip_r:
    mov eax, esi
    add eax, ecx
    cmp eax, [scr_height]
    jle .fr_noclip_b
    mov ecx, [scr_height]
    sub ecx, esi
.fr_noclip_b:
    ; Hard backstop against corrupt geometry. The clip above bounds the rect to
    ; scr_width/scr_height, but if THOSE globals are themselves garbage (corrupt
    ; VBE/GOP state) the clip is a no-op and a bad width/row-count would drive the
    ; movntdq loop below off the end of RAM in a multi-GB copy that never returns
    ; (boot hang). Cap the post-clip extents to 8192 px — far above any real
    ; panel — so no caller can ever turn this into an unbounded copy.
    cmp edx, 8192
    jle .fr_w_cap_ok
    mov edx, 8192
.fr_w_cap_ok:
    cmp ecx, 8192
    jle .fr_h_cap_ok
    mov ecx, 8192
.fr_h_cap_ok:
    cmp edx, 0
    jle .fr_done
    cmp ecx, 0
    jle .fr_done

    ; Note clipped rect size for fbperf bytes accounting.
    push rdi
    push rsi
    mov  edi, edx
    mov  esi, ecx
    call fbperf_flip_rect_note_size
    pop  rsi
    pop  rdi

    ; Calculate starting offset
    movsxd r8, esi
    imul r8, [scr_pitch_q]
    movsxd rax, edi
    lea r8, [r8 + rax * 4]

    mov r9, [fb_addr]
    add r9, r8
    mov r10, [bb_addr]
    add r10, r8

    mov r11d, edx            ; Width in pixels
    shl r11d, 2              ; Width in bytes
    mov r12d, ecx            ; Row count

.fr_row:
    ; Copy one row using SSE2 non-temporal stores
    mov rdi, r9              ; Dest (VRAM)
    mov rsi, r10             ; Src (RAM)
    mov ecx, r11d            ; Bytes this row

    ; Check 16-byte alignment of destination for movntdq
    test rdi, 15
    jnz .fr_row_unaligned

    ; SSE2 NT copy: 64 bytes per iteration (aligned path)
    mov eax, ecx
    shr eax, 6               ; / 64
    jz .fr_row_small

.fr_sse_row:
    movdqu xmm0, [rsi]       ; Unaligned load (source may not be aligned)
    movdqu xmm1, [rsi + 16]
    movdqu xmm2, [rsi + 32]
    movdqu xmm3, [rsi + 48]
    movntdq [rdi], xmm0      ; NT store (dest is aligned)
    movntdq [rdi + 16], xmm1
    movntdq [rdi + 32], xmm2
    movntdq [rdi + 48], xmm3
    add rsi, 64
    add rdi, 64
    dec eax
    jnz .fr_sse_row

.fr_row_small:
    ; Remaining bytes with qword/byte copy
    mov ecx, r11d
    and ecx, 63
    shr ecx, 3
    rep movsq
    mov ecx, r11d
    and ecx, 7
    rep movsb
    jmp .fr_row_advance

.fr_row_unaligned:
    ; Fallback: rep movsq for unaligned rows
    shr ecx, 3
    rep movsq
    mov ecx, r11d
    and ecx, 7
    rep movsb

.fr_row_advance:
    movsxd rax, dword [scr_pitch]
    add r9, rax
    add r10, rax

    dec r12d
    jnz .fr_row

    sfence                   ; Ensure NT stores are visible

.fr_done:
    call fbperf_flip_rect_end
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbx
    pop rax
    ret

; --- Clear back buffer with color (SSE2 optimized) ---
; EDI = color
; auto-wrapped (FN_BEGIN emits global): global display_clear
FN_BEGIN display_clear, 0, 0, FN_RET_SCALAR
    push rax
    push rcx
    push rdi
    push rdx

    ; Broadcast color to XMM register
    movd xmm0, edi
    pshufd xmm0, xmm0, 0    ; xmm0 = [color, color, color, color]

    mov rdi, [bb_addr]

    ; Calculate total pixels
    mov ecx, [scr_width]
    imul ecx, [scr_height]
    mov eax, ecx             ; Save total pixels

    ; SSE2 fill: 4 pixels (16 bytes) per iteration
    shr ecx, 2               ; / 4 for 128-bit chunks
    jz .clear_tail

.clear_sse_loop:
    movdqa [rdi], xmm0
    add rdi, 16
    dec ecx
    jnz .clear_sse_loop

.clear_tail:
    ; Remaining 0-3 pixels
    and eax, 3
    jz .clear_done
    mov ecx, eax
    mov eax, edi             ; color is still in original edi... no wait, rdi was overwritten
    ; We need to re-get the color. It was in the original edi arg, but rdi was overwritten.
    ; Use XMM0 - extract the dword from it
    movd eax, xmm0
.clear_tail_loop:
    mov [rdi], eax
    add rdi, 4
    dec ecx
    jnz .clear_tail_loop

.clear_done:
    pop rdx
    pop rdi
    pop rcx
    pop rax
    ret

section .data
global fb_addr, bb_addr, scr_width, scr_height, scr_pitch, scr_pitch_q
; --- Native framebuffer (set once by boot loader, never overwritten) ----
; Apps and Settings read these to discover the monitor's native resolution
; via SYS_DISPLAY_NATIVE. display_set_mode changes scr_* but leaves these.
global fb_native_width, fb_native_height
; --- Runtime window-manager layout (recomputed on every mode change) ----
; constants.inc used to derive TASKBAR_Y / CLOCK_X / etc. at assemble time
; from SCREEN_WIDTH and SCREEN_HEIGHT. Now those are dynamic, so taskbar.asm
; and friends load these globals instead of using compile-time symbols.
global scr_taskbar_y, scr_clock_x, scr_clock_y
global scr_start_btn_y, scr_start_menu_y
global scr_tb_btn_y, scr_bat_ind_x, scr_bat_ind_y
extern tb_start_menu_h
; --- Display flags (bit 0 vsync, bit 1 fps, bit 2 stretch) --------------
; STRETCH is "plumbing for now": when set, display_set_mode will allow
; modes that differ from the native fb size and (later) cause display_flip
; to scale the back buffer to the fb. Today display_flip is 1:1 so the
; effective behavior is unchanged regardless of the bit. The bit is
; persisted across mode changes so Settings can toggle it cleanly.
global display_stretch
global raster_target_addr, raster_target_width, raster_target_height, raster_target_pitch_q

fb_addr:    dq 0
bb_addr:    dq 0
scr_width:  dd SCREEN_WIDTH
scr_height: dd SCREEN_HEIGHT
scr_pitch:  dd SCREEN_PITCH
scr_pitch_q: dq SCREEN_PITCH
raster_target_addr:    dq BACK_BUFFER_ADDR
raster_target_width:   dd SCREEN_WIDTH
raster_target_height:  dd SCREEN_HEIGHT
raster_target_pitch_q: dq SCREEN_PITCH
; Serializes mutation of the raster_target_* fields above between the BSP
; and the wallpaper renderer running on an AP. Held only across a single
; raster syscall: acquire in raster_select_syscall_target, release in
; raster_sc_release_target.
align 8
raster_target_lock: db 0
fb_native_width:  dd SCREEN_WIDTH
fb_native_height: dd SCREEN_HEIGHT
scr_taskbar_y:    dd (SCREEN_HEIGHT - TASKBAR_HEIGHT)
scr_clock_x:      dd (SCREEN_WIDTH - CLOCK_WIDTH - 8)
scr_clock_y:      dd (SCREEN_HEIGHT - TASKBAR_HEIGHT + 10)
scr_start_btn_y:  dd (SCREEN_HEIGHT - TASKBAR_HEIGHT + 4)
scr_start_menu_y: dd (SCREEN_HEIGHT - TASKBAR_HEIGHT - 200)   ; - START_MENU_H
scr_tb_btn_y:     dd (SCREEN_HEIGHT - TASKBAR_HEIGHT + 4)
scr_bat_ind_x:    dd (SCREEN_WIDTH - CLOCK_WIDTH - 8 - 88 - 6) ; - (BAT_IND_W + 6)
scr_bat_ind_y:    dd (SCREEN_HEIGHT - TASKBAR_HEIGHT + 4)
vsync_enabled: db 0        ; Disabled by default (uses PIT fallback on AMD/UEFI)
fps_show:      db 1
display_stretch: db 0
last_vsync_tick: dq 0      ; PIT tick count at last vsync
global last_vsync_tick
global vsync_enabled, fps_show
extern fps_count, last_fps, frame_count, start_tick

; --- Wait for VSync / Frame Pacing ---
; On real AMD/UEFI hardware port 0x3DA is unreliable for vsync.
; Strategy: first try 0x3DA (works on VGA/QEMU), fall back to PIT-tick pacing.
; vsync_target_ticks = PIT ticks per frame (100Hz PIT: 180fps -> ~0.55 ticks -> 1 tick min)
; We use a hybrid: try 0x3DA with a long timeout; if it times out too fast, use PIT.
; auto-wrapped (FN_BEGIN emits global): global wait_vsync
FN_BEGIN wait_vsync, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx
    push rax

    ; Check if interrupts are enabled. If they are disabled (IF=0), we are likely 
    ; in an ISR or Syscall. Since tick_count won't increment in this state, 
    ; we must skip the PIT-based pacing to avoid deadlocking/stalling.
    pushf
    pop rax
    test eax, 0x200         ; Bit 9 = Interrupt Flag
    jz .vsync_done_pop      ; Masked? Skip vsync wait.

    ; Quick check: does 0x3DA work at all? (VGA retrace signal)
    ; On AMD UEFI/GOP hardware 0x3DA returns 0 always - skip it entirely.
    ; We detect this by checking if 0x3DA ever has bit 0x08 set.
    ; Instead: use a very short probe (1000 iters) to check for any activity.
    mov dx, 0x3DA
    mov ecx, 2000          ; Short probe: ~0.2ms at 100ns/IO
.probe_3da:
    in al, dx
    test al, 0x08
    jnz .vga_active        ; 0x3DA is live - use it
    dec ecx
    jnz .probe_3da
    ; 0x3DA never went high - not a real VGA controller, use PIT
    jmp .pit_fallback

.vga_active:
    ; 0x3DA is working - do full VGA vsync wait
    ; Wait for retrace to end first (if currently in retrace)
    mov ecx, 100000
.wait_retrace_end:
    in al, dx
    test al, 0x08
    jz .wait_retrace_start
    dec ecx
    jnz .wait_retrace_end
    jmp .pit_fallback       ; Stuck in retrace - fall back

.wait_retrace_start:
    mov ecx, 100000        ; ~10ms timeout
.wait_loop:
    in al, dx
    test al, 0x08
    jnz .vsync_done        ; Got retrace pulse - success
    dec ecx
    jnz .wait_loop
    ; Timed out waiting for retrace start - fall back to PIT pacing

.pit_fallback:
    ; PIT-based frame pacing: wait until tick_count advances by at least 1
    ; This gives ~100fps max (one frame per 10ms tick) when 0x3DA doesn't work.
    ; At 180Hz monitor, frames will pace to ~100fps which is smooth enough.
    ; last_vsync_tick holds the tick count when we last flipped.
    mov rax, [tick_count]
    mov rbx, [last_vsync_tick]
    ; If tick_count > last_vsync_tick, a new tick has occurred - proceed
    cmp rax, rbx
    jg .pit_new_tick
    ; Same tick - spin briefly checking tick_count (don't busy-loop forever)
    mov ecx, 5000000       ; max spin ~1.7ms at 3GHz
.pit_spin:
    mov rax, [tick_count]
    cmp rax, rbx
    jg .pit_new_tick
    dec ecx
    jnz .pit_spin
    ; Still no new tick - just proceed (avoid stalling)
    jmp .vsync_done
.pit_new_tick:
    mov [last_vsync_tick], rax

.vsync_done:
.vsync_done_pop:
    pop rax
    pop rdx
    pop rcx
    pop rbx
    ret

; --- Set Video Mode (Bochs VBE) ---
; EDI = width, ESI = height, EDX = bpp
; Returns 0 on success, -1 on failure
; auto-wrapped (FN_BEGIN emits global): global display_set_mode
; display_set_mode: source marker for guard checks; FN_BEGIN emits the label.
FN_BEGIN display_set_mode, 0, 0, FN_RET_SCALAR
    push rbx
    push r12

    ; Only 32bpp modes that fit the fixed boot back-buffer are safe here.
    ; Both kernel callers and SYS_DISPLAY_SET_MODE share this boundary.
    mov rax, rdi
    or  rax, rsi
    or  rax, rdx
    shr rax, 32
    jnz .set_fail
    test edi, edi
    jz .set_fail
    test esi, esi
    jz .set_fail
    cmp edx, 32
    jne .set_fail
    mov r12d, edx
    mov eax, edi
    mul esi
    jo .set_fail
    cmp eax, BOOT_BACK_BUFFER_SIZE / 4
    ja .set_fail

    ; Wait for VSync before switching mode to ensure clean timing
    call wait_vsync

    ; Reset FPS counters to avoid weird spikes
    mov dword [frame_count], 0
    mov rax, [tick_count]
    mov [start_tick], rax

    ; Real AMD display hardware is driven by the AMD provider. It accepts the
    ; firmware/native GOP mode and rejects unsafe non-native switches for now,
    ; so NexusOS never pokes Bochs VBE ports on AMD laptops.
    cmp byte [amd_display_active], 1
    jne .try_bochs_vbe
    call amd_display_set_mode
    jmp .set_ret

.try_bochs_vbe:
    ; Check if Bochs VBE is available (Port 0x1CE index 0 should be >= 0xB0C0)
    mov dx, 0x1CE
    mov ax, 0x00
    out dx, ax
    mov dx, 0x1CF
    in ax, dx
    cmp ax, 0xB0C0
    jl .set_fail
    cmp ax, 0xB0D0
    jg .set_fail

    ; Set X res (Index 1)
    mov dx, 0x1CE
    mov ax, 0x01
    out dx, ax
    mov dx, 0x1CF
    mov ax, di
    out dx, ax

    ; Set Y res (Index 2)
    mov dx, 0x1CE
    mov ax, 0x02
    out dx, ax
    mov dx, 0x1CF
    mov ax, si
    out dx, ax

    ; Set BPP (Index 3)
    mov dx, 0x1CE
    mov ax, 0x03
    out dx, ax
    mov dx, 0x1CF
    mov eax, r12d
    out dx, ax

    ; Set Virtual Width (Index 6) to match Physical Width
    mov dx, 0x1CE
    mov ax, 0x06
    out dx, ax
    mov dx, 0x1CF
    mov ax, di
    out dx, ax

    ; Reset X Offset (Index 8) to 0
    mov dx, 0x1CE
    mov ax, 0x08
    out dx, ax
    mov dx, 0x1CF
    xor ax, ax
    out dx, ax

    ; Reset Y Offset (Index 9) to 0
    mov dx, 0x1CE
    mov ax, 0x09
    out dx, ax
    mov dx, 0x1CF
    xor ax, ax
    out dx, ax

    ; Enable + LFB (Index 4, val 0x41)
    mov dx, 0x1CE
    mov ax, 0x04
    out dx, ax
    mov dx, 0x1CF
    mov ax, 0x41
    out dx, ax

    ; Update global vars
    mov [scr_width], edi
    mov [scr_height], esi
    imul edi, 4
    mov [scr_pitch], edi
    mov eax, edi
    mov [scr_pitch_q], rax

    ; Recompute WM layout so taskbar/clock/start-menu follow the new mode
    call display_recompute_layout
    call raster_select_default_target

    ; Clear back buffer completely (using new resolution)
    xor edi, edi
    call display_clear

    xor eax, eax ; Success
    jmp .set_ret

.set_fail:
    mov rax, -1
.set_ret:
    pop r12
    pop rbx
    ret

; ============================================================================
; SVG rasterizer primitives (used by usermode SVG renderer via syscalls).
; All routines write to the back buffer and clip to screen bounds.
; ============================================================================

; --- Draw arbitrary line (Bresenham) ---
; EDI = x0, ESI = y0, EDX = x1, ECX = y1, R8D = color
FN_BEGIN draw_line, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14

    movsxd r9,  edi          ; x0
    movsxd r10, esi          ; y0
    movsxd r11, edx          ; x1
    movsxd r12, ecx          ; y1
    mov    r13d, r8d         ; color

    mov rax, r11
    sub rax, r9              ; x1 - x0
    mov rbx, 1               ; sx = +1
    jns .ln_dx_ok
    neg rax
    mov rbx, -1
.ln_dx_ok:                   ; rax = dx (>=0), rbx = sx

    mov rcx, r12
    sub rcx, r10             ; y1 - y0
    mov rdx, 1               ; sy = +1
    jns .ln_dy_ok
    neg rcx
    mov rdx, -1
.ln_dy_ok:
    neg rcx                  ; rcx = -|dy|  (i.e. dy <= 0)

    mov r14, rax
    add r14, rcx             ; err = dx + dy

.ln_loop:
    push rax
    push rbx
    push rcx
    push rdx
    mov edi, r9d
    mov esi, r10d
    mov edx, r13d
    call pixel_set
    pop rdx
    pop rcx
    pop rbx
    pop rax

    cmp r9, r11
    jne .ln_step
    cmp r10, r12
    je .ln_done
.ln_step:
    lea rdi, [r14 + r14]     ; e2 = 2*err
    cmp rdi, rcx             ; if e2 >= dy
    jl .ln_skip_x
    add r14, rcx
    add r9, rbx
.ln_skip_x:
    cmp rdi, rax             ; if e2 <= dx
    jg .ln_skip_y
    add r14, rax
    add r10, rdx
.ln_skip_y:
    jmp .ln_loop

.ln_done:
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Fill circle (scanline via SSE sqrt) ---
; EDI = cx, ESI = cy, EDX = r, ECX = color
FN_BEGIN fill_circle, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    sub rsp, 16
    movdqu [rsp], xmm0

    movsxd r9,  edi          ; cx
    movsxd r10, esi          ; cy
    movsxd r11, edx          ; r
    mov    r13d, ecx         ; color

    test r11, r11
    jl .fc_done              ; negative radius is invalid/no-op
    jnz .fc_scan

    ; Degenerate circle: SVG treats r=0 as a single point for our filled
    ; raster primitive. Clipping is still delegated to pixel_set.
    mov edi, r9d
    mov esi, r10d
    mov edx, r13d
    call pixel_set
    jmp .fc_done

.fc_scan:
    mov r12, r11
    neg r12                  ; r12 = y_off = -r
.fc_row:
    cmp r12, r11
    jg .fc_done

    ; dx_sq = r*r - y*y
    mov rax, r11
    imul rax, rax
    mov rbx, r12
    imul rbx, rbx
    sub rax, rbx
    js .fc_next              ; defensive

    cvtsi2sd xmm0, rax
    sqrtsd xmm0, xmm0
    cvttsd2si rax, xmm0      ; rax = dx (floor)

    mov edi, r9d
    sub edi, eax             ; cx - dx
    mov esi, r10d
    add esi, r12d            ; cy + y_off
    lea edx, [eax + eax + 1] ; 2*dx + 1
    mov ecx, r13d
    call draw_hline_raster

.fc_next:
    inc r12
    jmp .fc_row
.fc_done:
    movdqu xmm0, [rsp]
    add rsp, 16
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Fill triangle (flat-top/flat-bottom scanline) ---
; EDI = pointer to 6 int32 coords [x0,y0,x1,y1,x2,y2], ESI = color
FN_BEGIN fill_triangle, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rbp, rdi             ; rbp = coords ptr
    mov r15d, esi            ; r15d = color

    ; Load v0/v1/v2 into r8..r13 (signed 64-bit)
    movsxd r8,  dword [rbp + 0]    ; x0
    movsxd r9,  dword [rbp + 4]    ; y0
    movsxd r10, dword [rbp + 8]    ; x1
    movsxd r11, dword [rbp + 12]   ; y1
    movsxd r12, dword [rbp + 16]   ; x2
    movsxd r13, dword [rbp + 20]   ; y2

    ; Sort by Y ascending: ensure y0<=y1<=y2 by pairwise swaps
    cmp r9, r11
    jle .ft_s1
    xchg r8, r10
    xchg r9, r11
.ft_s1:
    cmp r11, r13
    jle .ft_s2
    xchg r10, r12
    xchg r11, r13
.ft_s2:
    cmp r9, r11
    jle .ft_sorted
    xchg r8, r10
    xchg r9, r11
.ft_sorted:
    ; Degenerate: collinear triangle. Draw the three edges so single-line
    ; inputs do not expand into a stair-stepped filled wedge.
    mov rax, r10
    sub rax, r8              ; x1-x0
    mov rbx, r13
    sub rbx, r9              ; y2-y0
    imul rax, rbx
    mov rcx, r12
    sub rcx, r8              ; x2-x0
    mov rbx, r11
    sub rbx, r9              ; y1-y0
    imul rcx, rbx
    sub rax, rcx
    jnz .ft_not_collinear

    mov r14, r8
    mov edi, r8d
    mov esi, r9d
    mov edx, r10d
    mov ecx, r11d
    mov r8d, r15d
    call draw_line
    mov edi, r10d
    mov esi, r11d
    mov edx, r12d
    mov ecx, r13d
    mov r8d, r15d
    call draw_line
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r9d
    mov r8d, r15d
    call draw_line
    jmp .ft_done

.ft_not_collinear:
    ; Degenerate: y0==y2 -> single horizontal line
    cmp r9, r13
    jne .ft_general

    ; min/max of x0,x1,x2 -> hline at y0
    mov rax, r8
    mov rbx, r8
    cmp r10, rax
    jge .ft_d1
    mov rax, r10
.ft_d1:
    cmp r10, rbx
    jle .ft_d2
    mov rbx, r10
.ft_d2:
    cmp r12, rax
    jge .ft_d3
    mov rax, r12
.ft_d3:
    cmp r12, rbx
    jle .ft_d4
    mov rbx, r12
.ft_d4:
    mov edi, eax
    mov esi, r9d
    mov edx, ebx
    sub edx, eax
    inc edx
    mov ecx, r15d
    call draw_hline_raster
    jmp .ft_done

.ft_general:
    ; Iterate scanline y from y0 to y2 inclusive (rcx = current y)
    mov rcx, r9
.ft_yloop:
    cmp rcx, r13
    jg .ft_done

    ; Long edge xa = x0 + (x2-x0) * (y - y0) / (y2 - y0)
    mov rax, r12
    sub rax, r8              ; x2-x0
    mov rbx, rcx
    sub rbx, r9              ; y - y0
    imul rax, rbx            ; (x2-x0)*(y-y0)
    mov rbx, r13
    sub rbx, r9              ; y2-y0 (>0 here since not flat)
    cqo
    idiv rbx                 ; rax = (x2-x0)*(y-y0) / (y2-y0)
    add rax, r8              ; xa
    mov r14, rax

    ; Short edge xb depends on which half
    cmp rcx, r11
    jl .ft_upper
    ; Lower: xb = x1 + (x2-x1)*(y-y1) / (y2-y1)
    cmp r13, r11
    je .ft_skip              ; flat-bottom: y2==y1, undefined; skip safely
    mov rax, r12
    sub rax, r10             ; x2-x1
    mov rbx, rcx
    sub rbx, r11             ; y-y1
    imul rax, rbx
    mov rbx, r13
    sub rbx, r11             ; y2-y1
    cqo
    idiv rbx
    add rax, r10             ; xb
    jmp .ft_have_xb

.ft_upper:
    cmp r11, r9
    je .ft_skip              ; flat-top
    mov rax, r10
    sub rax, r8              ; x1-x0
    mov rbx, rcx
    sub rbx, r9
    imul rax, rbx
    mov rbx, r11
    sub rbx, r9
    cqo
    idiv rbx
    add rax, r8              ; xb

.ft_have_xb:
    ; left = min(xa, xb), width = |xa-xb|+1
    cmp rax, r14
    jle .ft_have_lr
    xchg rax, r14
.ft_have_lr:                 ; rax = left, r14 = right
    mov edi, eax
    mov esi, ecx
    mov edx, r14d
    sub edx, eax
    inc edx
    push rcx
    mov ecx, r15d
    call draw_hline_raster
    pop rcx

.ft_skip:
    inc rcx
    jmp .ft_yloop

.ft_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Raster primitives smoke self-test ---
; Exercises draw_line / fill_circle / fill_triangle with normal + degenerate
; inputs. Verifies a few deterministic pixels and prints the result to COM1.
FN_BEGIN raster_self_test, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8

    xor ebx, ebx             ; failure flag

    ; Line: normal
    mov edi, 100
    mov esi, 100
    mov edx, 200
    mov ecx, 150
    mov r8d, 0x00FF0000
    call draw_line
    ; Line: zero-length
    mov edi, 50
    mov esi, 50
    mov edx, 50
    mov ecx, 50
    mov r8d, 0x0000FF00
    call draw_line
    mov eax, 50
    imul rax, [scr_pitch_q]
    mov ecx, 50
    lea rax, [rax + rcx * 4]
    mov rdx, [bb_addr]
    cmp dword [rdx + rax], 0x0000FF00
    je .rst_line_ok
    mov ebx, 1
.rst_line_ok:
    ; Line: off-screen (negative coords) — clipping path
    mov edi, -50
    mov esi, -50
    mov edx, 300
    mov ecx, 300
    mov r8d, 0x000000FF
    call draw_line

    ; Circle: normal
    mov edi, 400
    mov esi, 300
    mov edx, 40
    mov ecx, 0x00FFFF00
    call fill_circle
    ; Circle: r=0 (single clipped pixel)
    mov edi, 10
    mov esi, 10
    mov edx, 0
    mov ecx, 0x00808080
    call fill_circle
    mov eax, 10
    imul rax, [scr_pitch_q]
    mov ecx, 10
    lea rax, [rax + rcx * 4]
    mov rdx, [bb_addr]
    cmp dword [rdx + rax], 0x00808080
    je .rst_circle0_ok
    mov ebx, 1
.rst_circle0_ok:
    ; Circle: r=1
    mov edi, 500
    mov esi, 300
    mov edx, 1
    mov ecx, 0x00FFFFFF
    call fill_circle

    ; Triangle: normal (use stack scratch)
    sub rsp, 32
    mov dword [rsp + 0],  600
    mov dword [rsp + 4],  100
    mov dword [rsp + 8],  700
    mov dword [rsp + 12], 200
    mov dword [rsp + 16], 550
    mov dword [rsp + 20], 250
    mov rdi, rsp
    mov esi, 0x00FF00FF
    call fill_triangle
    ; Triangle: degenerate (collinear)
    mov dword [rsp + 0],  10
    mov dword [rsp + 4],  10
    mov dword [rsp + 8],  20
    mov dword [rsp + 12], 10
    mov dword [rsp + 16], 30
    mov dword [rsp + 20], 10
    mov rdi, rsp
    mov esi, 0x00808080
    call fill_triangle
    mov eax, 10
    imul rax, [scr_pitch_q]
    mov ecx, 20
    lea rax, [rax + rcx * 4]
    mov rdx, [bb_addr]
    cmp dword [rdx + rax], 0x00808080
    je .rst_triangle_ok
    mov ebx, 1
.rst_triangle_ok:
    add rsp, 32

    test ebx, ebx
    jz .rst_emit_ok
    lea rsi, [rel rst_fail_msg]
    jmp .rst_loop

.rst_emit_ok:
    lea rsi, [rel rst_ok_msg]
.rst_loop:
    mov al, [rsi]
    test al, al
    jz .rst_done
    call serial_putc
    inc rsi
    jmp .rst_loop
.rst_done:

    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .data
rst_ok_msg: db '[RST] OK', 13, 10, 0
rst_fail_msg: db '[RST] FAIL', 13, 10, 0

section .text
