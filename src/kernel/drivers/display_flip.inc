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
    push rdx
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    cld
    extern fbperf_flip_full_begin
    extern fbperf_flip_full_end
    call fbperf_flip_full_begin

    ; Full-screen presents use the same per-row guarded path as dirty rects.
    ; The old monolithic rep/SIMD copy repeatedly #GP'd in QEMU's GOP/LFB path
    ; near the end of the visible aperture and left half-presented frames.
    xor edi, edi
    xor esi, esi
    mov edx, [scr_width]
    mov ecx, [scr_height]
    call display_flip_rect
    call fbperf_flip_full_end
    pop rdx
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
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    cld
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
    mov r8, [fb_mapped_end_q]   ; loader-mapped fb_end (immune to mode-set drift)
    test r8, r8
    jnz .fr_have_end
    ; Fallback (display_init has not latched yet): recompute from live globals.
    mov r8, [fb_addr]
    movsxd rax, dword [fb_native_height]
    imul rax, [scr_pitch_q]
    add r8, rax              ; r8 = fb_end (exclusive)
.fr_have_end:
    ; Sanity-clamp r8 into a physically possible range. The loader can map at
    ; most MAX_FB_WIDTH*MAX_FB_HEIGHT*4 bytes past fb_addr, so any larger value
    ; in fb_mapped_end_q is corruption (a clobbered/garbage ~6 GB end was seen
    ; defeating the per-row backstop in a debug-overlay #PF storm). Force
    ; r8 into [fb_addr+1, fb_addr + MAX_FB_BYTES] so no corrupt bound can ever
    ; let the row loop below walk a store past the real mapped framebuffer.
    push rcx
    mov rax, [fb_addr]
    mov rcx, rax
    add rcx, (MAX_FB_WIDTH * MAX_FB_HEIGHT * 4)   ; hard physical ceiling
    cmp r8, rcx
    jbe .fr_end_hi_ok
    mov r8, rcx
.fr_end_hi_ok:
    cmp r8, rax              ; r8 must sit strictly above fb_addr
    ja  .fr_end_lo_ok
    mov r8, rcx              ; <= base (incl. 0) -> use the ceiling
.fr_end_lo_ok:
    pop rcx
    ; Cap the row count to the tallest mode the loader will ever map, so a
    ; clobbered height cannot spin the loop off the bottom of the framebuffer.
    cmp r12d, MAX_FB_HEIGHT
    jbe .fr_rows_ok
    mov r12d, MAX_FB_HEIGHT
.fr_rows_ok:
    ; Pull the effective end bound down by one 128-byte SSE chunk. The per-row
    ; movntdq loop copies in 64-byte chunks and rowbytes need not be 64-aligned,
    ; so the final chunk can round up to ~0x40 past the byte-exact row end; if a
    ; row ends exactly at the real fb_end that rounding lands in the unmapped
    ; guard page (the per-frame ring-0 #PF storm). Bounding to fb_end-0x80 keeps
    ; every store, including the rounded tail, strictly inside the mapped FB.
    sub r8, 0x80

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

    ; HARD per-row destination clamp. r8 = fb_mapped_end_q (first byte past the
    ; mapped framebuffer; the loader leaves an unmapped guard page there). Clamp
    ; the bytes copied this row to (r8 - r9) so a corrupt/oversized rowbytes -
    ; whatever its origin - can NEVER drive rdi past the mapped FB into the guard
    ; page (the per-frame ring-0 #PF storm seen in debug builds). For every
    ; legitimate row (r8 - r9) >= rowbytes, so this is a no-op. edx holds the
    ; clamped count for the tail copies.
    mov rax, r8
    sub rax, r9             ; bytes available to fb_end (signed)
    jle .fr_row_advance     ; r9 at/after fb_end -> copy nothing this row
    mov ecx, r11d           ; rowbytes
    cmp ecx, eax
    jbe .fr_clamp_ok
    mov ecx, eax            ; clamp to available
.fr_clamp_ok:
    mov edx, ecx            ; clamped bytes-this-row (used by the tail paths)

    ; Check 16-byte alignment of destination for movntdq
    test rdi, 15
    jnz .fr_row_unaligned

    ; SSE2 NT copy: 64 bytes per iteration (aligned path). Bound the loop with
    ; an end pointer derived from the already-clamped row byte count. This is a
    ; second, local safety boundary: even if a volatile counter is corrupted,
    ; the NT-store cursor can never escape this row and reach the framebuffer
    ; guard page. RBX is scratch here and is recomputed by the next row guard.
    mov eax, ecx
    and eax, -64             ; bytes covered by complete 64-byte chunks
    lea rbx, [rdi + rax]     ; exclusive end of the SSE portion
    cmp rdi, rbx
    jae .fr_row_small

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
    cmp rdi, rbx
    jb .fr_sse_row

.fr_row_small:
    ; Remaining bytes with qword/byte copy (clamped count in edx)
    mov ecx, edx
    and ecx, 63
    shr ecx, 3
    rep movsq
    mov ecx, edx
    and ecx, 7
    rep movsb
    jmp .fr_row_advance

.fr_row_unaligned:
    ; Fallback: rep movsq for unaligned rows (clamped count in edx)
    mov ecx, edx
    shr ecx, 3
    rep movsq
    mov ecx, edx
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
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    cld

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
    movdqu [rdi], xmm0       ; bb_addr is RAM; tolerate unaligned allocator output
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
; tb_start_menu_h retired with taskbar.asm (ring-3 shell owns the Start menu).
; --- Display flags (bit 0 vsync, bit 1 fps, bit 2 stretch) --------------
; STRETCH is "plumbing for now": when set, display_set_mode will allow
; modes that differ from the native fb size and (later) cause display_flip
; to scale the back buffer to the fb. Today display_flip is 1:1 so the
; effective behavior is unchanged regardless of the bit. The bit is
; persisted across mode changes so Settings can toggle it cleanly.
global display_stretch
global raster_target_tbl

fb_addr:    dq 0
bb_addr:    dq 0
scr_width:  dd SCREEN_WIDTH
scr_height: dd SCREEN_HEIGHT
scr_pitch:  dd SCREEN_PITCH
scr_pitch_q: dq SCREEN_PITCH
; Raster target record (addr/width/height/pitch at RTGT_* offsets, see
; constants.inc). Slot 0 of this table is the single shared raster destination;
; the hot per-pixel primitives address it ABSOLUTELY ([raster_target_tbl +
; RTGT_*]). A per-core GS-base scheme was tried but is unusable in this flat
; no-swapgs model: every kernel entry/exit reloads the GS selector (smap.inc
; SANITIZE_SEG_*), zeroing GS base, so [gs:RTGT_*] dereferenced a null slot and
; every blit page-faulted. The table layout (per-core slots) is kept as infra.
align 64
raster_target_tbl: times SMP_MAX_CORES * RTGT_STRIDE db 0
; Serializes mutation of the shared raster target across a single raster syscall
; (acquire in raster_select_syscall_target, release in raster_sc_release_target).
; The BSP compositor never runs concurrently with an AP wallpaper raster because
; render_frame defers the whole frame while wallpaper_render_active (frame_present
; .ghl); the lock guards the brief select/release window against that AP path.
align 8
raster_target_lock: db 0
fb_native_width:  dd SCREEN_WIDTH
fb_native_height: dd SCREEN_HEIGHT
; Authoritative first-byte-past-the-mapped-framebuffer VA. The loader maps
; [fb_addr, fb_addr + VBE_HEIGHT*VBE_PITCH) and leaves ONE guard page unmapped
; right after (uefi_loader_paging_exit.inc) so an overrun faults instead of
; clobbering the adjacent VBE-MMIO BAR. display_set_mode can later re-set
; scr_height/scr_pitch_q to a TALLER mode WITHOUT remapping VRAM, so the flip
; backstop must clamp to what the loader actually mapped - not to the current
; (possibly larger) scr_* globals, which would walk a full flip straight into
; the guard page every frame. Latched once in display_init from the SAME VBE
; fields the loader used, so the two cannot drift. 0 = not yet latched.
global fb_mapped_end_q
fb_mapped_end_q: dq 0
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
; target_fps : frame-rate cap when vsync is OFF. Default 180. Clamped 5..1000 by
;              the pacer. 0 is treated as "uncapped" (pace to PIT only).
; vsync_hz   : target refresh used when vsync_enabled != 0. Default 180; the
;              user's real panel is 180. Clamped 5..1000 by the pacer.
; The pacer (frame_pacing.ghl) reads these every frame, so a live write from the
; settings UI takes effect on the next frame with no extra wiring.
target_fps:    dd 180    ; frame-rate cap when vsync is OFF (clamped 5..1000)
vsync_hz:      dd 180    ; target refresh when vsync is ON (clamped 5..1000)
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
    ; so Grit never pokes Bochs VBE ports on AMD laptops.
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

