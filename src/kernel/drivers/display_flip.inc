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
    ; (boot hang). Cap the post-clip extents to 8192 px - far above any real
    ; panel - so no caller can ever turn this into an unbounded copy.
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

    ; Clamp the rect ORIGIN inside the screen. The clip above only forces
    ; x>=0 / y>=0 and bounds w/h to scr_width/scr_height; it never rejects an
    ; origin that is AT or BEYOND the right/bottom edge. A dirty rect with a
    ; large positive x/y (off-screen / garbage window coords pushed through
    ; render_mark_dirty during a mouse drag) therefore survives the clip and
    ; produces a base pointer far outside the framebuffer -> the movntdq loop
    ; below walks off the LFB into QEMU std-vga's adjacent VBE-MMIO BAR (the
    ; "1664x262" scanout clobber) and, with a corrupt row count, into a
    ; multi-GB copy that never returns (UI freeze). Bail on an off-screen origin.
    cmp edi, [scr_width]
    jge .fr_done
    cmp esi, [scr_height]
    jge .fr_done

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

    ; Hard destination backstop, independent of the (possibly corrupt) scr_*
    ; geometry the clip above trusts. The real linear framebuffer spans
    ; [fb_addr, fb_addr + fb_native_height*scr_pitch_q). fb_native_height is
    ; written once by the loader and never overwritten, so it bounds the LFB
    ; even when scr_width/scr_height/x/y have been clobbered. r8 = fb_end; the
    ; per-row guard below stops the copy before any movntdq store could land
    ; at/after fb_end (i.e. in the adjacent VBE-MMIO BAR or off the end of RAM).
    mov r8, [fb_addr]
    movsxd rax, dword [fb_native_height]
    imul rax, [scr_pitch_q]
    add r8, rax              ; r8 = fb_end (exclusive)

.fr_row:
    ; Backstop: never start a row below fb_addr or write a row that reaches
    ; at/after fb_end. Either condition means corrupt geometry slipped through;
    ; stop cleanly rather than wild-write into the VBE-MMIO BAR / off RAM.
    cmp r9, [fb_addr]
    jb .fr_done
    movsxd rbx, r11d         ; bytes this row (>= 0)
    lea rax, [r9 + rbx]
    cmp rax, r8
    ja .fr_done
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
; --- Frame pacing tunables (written by the Settings Mouse/Display tab) ---
; target_fps : frame-rate cap when vsync is OFF. Default 60. Clamped 5..1000 by
;              the pacer. 0 is treated as "uncapped" (pace to PIT only).
; vsync_hz   : target refresh used when vsync_enabled != 0. Default 60; the
;              user's real panel is 180. Clamped 5..1000 by the pacer.
; The pacer (frame_pacing.ghl) reads these every frame, so a live write from the
; settings UI takes effect on the next frame with no extra wiring.
target_fps:    dd 60    ; frame-rate cap when vsync is OFF (clamped 5..1000)
vsync_hz:      dd 60     ; target refresh when vsync is ON (clamped 5..1000)
global last_vsync_tick
global vsync_enabled, fps_show, target_fps, vsync_hz
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
    ; so GritOS never pokes Bochs VBE ports on AMD laptops.
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
