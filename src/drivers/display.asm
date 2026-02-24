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

section .text

; --- Initialize display driver ---
; Reads VBE info from 0x9000 (set by stage2)
global display_init
display_init:
    ; Read framebuffer address (full 64-bit for UEFI compatibility)
    mov rax, [0x9000]
    mov [fb_addr], rax

    ; Read dimensions
    mov eax, [0x9008]
    mov [scr_width], eax
    mov eax, [0x900C]
    mov [scr_height], eax
    mov eax, [0x9010]
    mov [scr_pitch], eax

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

.init_ok:
    ; Set back buffer address
    mov qword [bb_addr], BACK_BUFFER_ADDR

    ; Clear back buffer
    xor edi, edi             ; Black (color arg in edi)
    call display_clear

    ret

; --- Set pixel ---
; EDI = x, ESI = y, EDX = color (0x00RRGGBB)
global pixel_set
pixel_set:
    push rax
    push rbx
    ; Bounds check
    cmp edi, 0
    jl .done
    cmp edi, [scr_width]
    jge .done
    cmp esi, 0
    jl .done
    cmp esi, [scr_height]
    jge .done

    ; Calculate offset: y * pitch + x * 4
    mov eax, esi
    imul eax, [scr_pitch]
    lea eax, [eax + edi * 4]
    mov rbx, [bb_addr]
    mov [rbx + rax], edx

.done:
    pop rbx
    pop rax
    ret

; --- Fill rectangle (SSE2 optimized) ---
; EDI = x, ESI = y, EDX = w, ECX = h, R8D = color
global fill_rect
fill_rect:
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

    ; Clip to screen bounds
    mov r9d, edi             ; x
    mov r10d, esi            ; y
    mov r11d, edx            ; w
    mov r12d, ecx            ; h
    mov r13d, r8d            ; color

    ; Clip left
    cmp r9d, 0
    jge .clip_right
    add r11d, r9d            ; Reduce width
    xor r9d, r9d             ; x = 0
.clip_right:
    mov eax, r9d
    add eax, r11d
    cmp eax, [scr_width]
    jle .clip_top
    mov r11d, [scr_width]
    sub r11d, r9d
.clip_top:
    cmp r10d, 0
    jge .clip_bottom
    add r12d, r10d
    xor r10d, r10d
.clip_bottom:
    mov eax, r10d
    add eax, r12d
    cmp eax, [scr_height]
    jle .clip_done
    mov r12d, [scr_height]
    sub r12d, r10d
.clip_done:
    ; Validate dimensions
    cmp r11d, 0
    jle .rect_done
    cmp r12d, 0
    jle .rect_done

    ; Calculate starting offset
    mov eax, r10d
    imul eax, [scr_pitch]
    lea eax, [eax + r9d * 4]
    mov rbx, [bb_addr]
    add rbx, rax

    ; Prepare SSE2 color vector: broadcast color to all 4 dword lanes
    movd xmm0, r13d
    pshufd xmm0, xmm0, 0    ; xmm0 = [color, color, color, color]

    movsxd rsi, dword [scr_pitch]

    ; Simple robust fill using rep stosd
    mov rdi, rbx             ; RDI = starting address in back buffer
    mov ecx, r11d            ; ECX = width in pixels
.row_loop:
    push rdi
    push rcx
    mov eax, r13d            ; Color
    rep stosd                ; Fill row
    pop rcx
    pop rdi

    add rdi, rsi             ; Next row (add pitch)
    dec r12d
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
global draw_char
draw_char:
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
    mov eax, r11d
    imul eax, [scr_pitch]
    lea eax, [eax + r10d * 4]
    mov r14, [bb_addr]
    add r14, rax              ; r14 = pointer to first pixel of char in BB

    movsxd r15, dword [scr_pitch]  ; pitch for row advance

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
    mov r9d, r11d
    imul r9d, [scr_pitch]
    lea r9d, [r9d + r10d * 4]
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
global draw_string
draw_string:
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
global draw_hline
draw_hline:
    push r8
    mov r8d, ecx             ; color
    mov ecx, 1               ; height = 1
    call fill_rect
    pop r8
    ret

; --- Draw vertical line ---
; EDI = x, ESI = y, EDX = height, ECX = color
global draw_vline
draw_vline:
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
    imul eax, [scr_pitch]
    lea eax, [eax + edi * 4]
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
global draw_rect_outline
draw_rect_outline:
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
    mov edx, [rsp + 16]     ; w saved
    call draw_hline

    ; Bottom line
    mov edi, [rsp + 24]     ; x
    mov esi, [rsp + 16 + 8] ; y
    add esi, [rsp]           ; + h - 1
    dec esi
    mov edx, [rsp + 16]     ; w
    mov ecx, r8d
    call draw_hline

    ; Left line
    mov edi, [rsp + 24]
    mov esi, [rsp + 16 + 8]
    mov edx, [rsp]           ; h
    mov ecx, r8d
    call draw_vline

    ; Right line
    mov edi, [rsp + 24]
    add edi, [rsp + 16]     ; x + w - 1
    dec edi
    mov esi, [rsp + 16 + 8]
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
global display_flip
display_flip:
    push rax
    push rcx
    push rsi
    push rdi

    ; Check VSync
    cmp byte [vsync_enabled], 1
    jne .no_vsync_wait
    call wait_vsync
.no_vsync_wait:

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

    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; --- Flip rectangle from back buffer to framebuffer (SSE2 NT) ---
; EDI = x, ESI = y, EDX = w, ECX = h
global display_flip_rect
display_flip_rect:
    push rax
    push rbx
    push r8
    push r9
    push r10
    push r11
    push r12

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
    cmp edx, 0
    jle .fr_done
    cmp ecx, 0
    jle .fr_done

    ; Calculate starting offset
    mov eax, esi
    imul eax, [scr_pitch]
    lea r8d, [eax + edi * 4]

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
global display_clear
display_clear:
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
global fb_addr, bb_addr, scr_width, scr_height, scr_pitch

fb_addr:    dq 0
bb_addr:    dq BACK_BUFFER_ADDR
scr_width:  dd SCREEN_WIDTH
scr_height: dd SCREEN_HEIGHT
scr_pitch:  dd SCREEN_PITCH
vsync_enabled: db 1        ; Enabled by default (uses PIT fallback on AMD/UEFI)
fps_show:      db 1
last_vsync_tick: dq 0      ; PIT tick count at last vsync
global last_vsync_tick
global vsync_enabled, fps_show
global fps_count, last_fps, frame_count, start_tick
fps_count:     dd 0
last_fps:      dd 0
frame_count:   dd 0
start_tick:    dq 0

; --- Wait for VSync / Frame Pacing ---
; On real AMD/UEFI hardware port 0x3DA is unreliable for vsync.
; Strategy: first try 0x3DA (works on VGA/QEMU), fall back to PIT-tick pacing.
; vsync_target_ticks = PIT ticks per frame (100Hz PIT: 180fps -> ~0.55 ticks -> 1 tick min)
; We use a hybrid: try 0x3DA with a long timeout; if it times out too fast, use PIT.
global wait_vsync
wait_vsync:
    push rax
    push rdx
    push rcx
    push rbx

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
    pop rbx
    pop rcx
    pop rdx
    pop rax
    ret

; --- Set Video Mode (Bochs VBE) ---
; EDI = width, ESI = height, EDX = bpp
; Returns 0 on success, -1 on failure
global display_set_mode
display_set_mode:
    push rbx
    push rdx
    push rax

    ; Wait for VSync before switching mode to ensure clean timing
    call wait_vsync

    ; Reset FPS counters to avoid weird spikes
    mov dword [frame_count], 0
    mov rax, [tick_count]
    mov [start_tick], rax

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
    pop rax     ; Restore EDX (BPP) into RAX temporarily
    push rax    ; Put it back
    mov rax, [rsp]
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

    ; Clear back buffer completely (using new resolution)
    xor edi, edi
    call display_clear

    xor eax, eax ; Success
    jmp .set_ret

.set_fail:
    mov rax, -1
.set_ret:
    pop rax
    pop rdx
    pop rbx
    ret

global vsync_enabled, fps_show, fps_count, last_fps
