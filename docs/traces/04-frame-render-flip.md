# Trace 04 - Frame Render → Back-Buffer Composition → Display Flip

## Entry

`kmain` infinite loop in `kernel/core/main.asm`. One iteration = one frame.

## Step-by-step

| # | File:Line | Action |
|---|---|---|
| 1 | main.asm | poll inputs (`process_mouse`, `keyboard_repeat_tick`, drain `kb_buffer`, USB/I2C/SPI HID polls) |
| 2 | main.asm | branches to `.do_render` if `scene_dirty != 0` or first frame |
| 3 | main.asm `.rf_render` | `call render_begin` - clears dirty rect list |
| 4 | render | `call wm_draw_all_windows` - iterates `window_pool[0..MAX_WINDOWS]` with `WF_ACTIVE`; for each: |
|   |   | • `wm_draw_window`: titlebar fill_rect, border draw_rect_outline, draw_string title, content callback `WIN_OFF_DRAWFN` |
| 5 | render | `call desktop_draw_icons` (if no fullscreen window) |
| 6 | render | `call tb_draw` - taskbar buttons + clock + battery |
| 7 | render | `call cursor_hide` (restore old bg from cursor_bg_save) |
| 8 | render | `call cursor_draw(mouse_x, mouse_y)` - saves new bg, XORs cursor |
| 9 | render | `call render_flush` - `display_flip` or `display_flip_rect(s)` per dirty rect |
| 10 | display.asm `display_flip` | row-by-row `rep movsd` from `bb_addr` to `[fb_addr]` |

## Back buffer layout

- `bb_addr` → kernel-allocated buffer of size `scr_width * scr_height * 4` (BGRA8888)
- `scr_pitch` = bytes per row (usually `scr_width * 4`)
- Pixel at (x,y) = `bb_addr + y*scr_pitch + x*4`

## draw_string contract (Round 2 verified)

`render_text` (gui/render.asm:40) is `jmp draw_string`. Signature:
- EDI = x
- ESI = y
- RDX = ASCII string pointer (null-terminated)
- ECX = foreground 0xRRGGBB color (BGRA in memory)
- R8D = background color, or -1 (=0xFFFFFFFF) for transparent

## fill_rect / draw_hline / draw_vline contract

- EDI=x, ESI=y, EDX=w (or length), ECX=h, R8D=color
- Clipped to (0, 0, scr_width, scr_height) inside.

## draw_rect_outline (Round 2 fix)

Stack after entry pushes (rdi=x, rsi=y, rdx=w, rcx=h):
- `[rsp+0]=h`, `[rsp+8]=w`, `[rsp+16]=y`, `[rsp+24]=x`

Top: uses original rdi/rsi; edx=w from `[rsp+8]`. Bottom: edi=x from `[rsp+24]`, esi=y from `[rsp+16]` + h - 1, edx=w from `[rsp+8]`. Left: x from `[rsp+24]`, y from `[rsp+16]`. Right: x+w-1 from `[rsp+24]+[rsp+8]-1`, y from `[rsp+16]`.

(Pre-fix: bottom/left ESI used `[rsp+16+8]=[rsp+24]=x`; both EDX(w) used `[rsp+16]=y`; right `add edi` used `[rsp+16]=y`. Every rect had four broken edges.)

## Failure modes

- vsync 0x3DA spin → 30ms/frame on AMD UEFI. MEMORY.md fix #15: 2k-iter probe, fall back to PIT after.
- display_flip used inside `debug_print` caused 1fps; fix #12 removed.

## Invariants

- back-buffer always equals last fully-rendered scene.
- cursor_bg_save always equals the back-buffer pixels under the cursor BEFORE cursor was drawn.
- after `display_flip`, framebuffer pixel == back-buffer pixel.
