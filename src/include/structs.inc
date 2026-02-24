; ============================================================================
; NexusOS v3.0 - Structure Definitions
; ============================================================================

; --- Window structure (256 bytes) ---
struc window_t
    .id:            resd 1      ; 0x00: Unique window ID
    .x:             resd 1      ; 0x04: Position X
    .y:             resd 1      ; 0x08: Position Y
    .w:             resd 1      ; 0x0C: Total width (including border)
    .h:             resd 1      ; 0x10: Total height (including titlebar+border)
    .client_x:      resd 1      ; 0x14: Client area X offset from window
    .client_y:      resd 1      ; 0x18: Client area Y offset from window
    .client_w:      resd 1      ; 0x1C: Client area width
    .client_h:      resd 1      ; 0x20: Client area height
    .flags:         resd 1      ; 0x24: WF_* flags
    .z_order:       resd 1      ; 0x28: Z-order (higher = on top)
                    resd 1      ; 0x2C: padding
    .title:         resq 1      ; 0x30: Pointer to title string
    .draw_fn:       resq 1      ; 0x38: App draw callback (rdi=window_ptr)
    .key_fn:        resq 1      ; 0x40: App keypress callback (rdi=window_ptr, esi=key)
    .click_fn:      resq 1      ; 0x48: App click callback (rdi=window_ptr, esi=x, edx=y)
    .app_data:      resq 1      ; 0x50: App-private data pointer
    .drag_ox:       resd 1      ; 0x58: Drag offset X (mouse_x - window_x at drag start)
    .drag_oy:       resd 1      ; 0x5C: Drag offset Y
    .padding:       resb 160    ; Pad to 256 bytes
endstruc

; --- Key event (4 bytes) ---
struc key_event_t
    .scancode:      resb 1      ; Raw scancode
    .ascii:         resb 1      ; ASCII translation (0 if special key)
    .modifiers:     resb 1      ; KMOD_* flags
    .pressed:       resb 1      ; 1=pressed, 0=released
endstruc

; --- Mouse event (16 bytes) ---
struc mouse_event_t
    .x:             resd 1      ; Absolute cursor X
    .y:             resd 1      ; Absolute cursor Y
    .buttons:       resb 1      ; Button state (bit0=left, bit1=right, bit2=middle)
    .event_type:    resb 1      ; MEVT_* type
    .padding:       resb 6      ; Pad to 16 bytes
endstruc

; --- Rectangle (16 bytes) ---
struc rect_t
    .x:             resd 1
    .y:             resd 1
    .w:             resd 1
    .h:             resd 1
endstruc

; --- E820 memory map entry (24 bytes) ---
struc e820_entry_t
    .base:          resq 1      ; Base address
    .length:        resq 1      ; Length in bytes
    .type:          resd 1      ; 1=usable, 2=reserved, 3=ACPI reclaimable
    .acpi:          resd 1      ; ACPI extended attributes
endstruc
