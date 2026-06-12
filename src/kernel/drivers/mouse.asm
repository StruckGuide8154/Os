; ============================================================================
; GritOS v3.0 - PS/2 Mouse Driver
; Full 8042 controller init, IRQ12 handler, 3-byte packet protocol
; ============================================================================
bits 64

%include "constants.inc"

extern scr_width, scr_height
extern mouse_scroll_y

section .text

; --- Initialize PS/2 mouse (full 8042 sequence per OSDev wiki) ---
global mouse_init
%include "src/kernel/drivers/mouse_init.inc"
%include "src/kernel/drivers/mouse_handler.inc"
%include "src/kernel/drivers/mouse_debug.inc"
%include "src/kernel/drivers/mouse_data.inc"
