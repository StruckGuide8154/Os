; ============================================================================
; Grit v3.0 - VBE Framebuffer Display Driver (SSE2 Optimized)
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

%include "src/kernel/drivers/display_core.inc"
%include "src/kernel/drivers/display_blend.inc"
%include "src/kernel/drivers/display_draw.inc"
%include "src/kernel/drivers/display_flip.inc"
%include "src/kernel/drivers/display_shapes.inc"
