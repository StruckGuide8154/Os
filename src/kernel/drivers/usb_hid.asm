; ============================================================================
; Grit v3.0 - USB HID Mouse Driver
; Implements USB HID protocol over XHCI
; ============================================================================
bits 64

%include "constants.inc"

; DEBUG: set current enumeration stage and bump the cross-pass high-water mark.
; usb_dbg_stage is reset to 0 each usb_hid_init pass; usb_dbg_stage_max is NOT,
; so it records the furthest any pass ever reached (boot pass included).
%macro STAGE 1
    mov byte [usb_dbg_stage], %1
    cmp byte [usb_dbg_stage_max], %1
    jae %%no_bump
    mov byte [usb_dbg_stage_max], %1
%%no_bump:
%endmacro

extern xhci_init
extern xhci_submit_cmd
extern xhci_queue_ctrl_trb
extern xhci_queue_int_trb
extern xhci_queue_int_trb2
extern xhci_ring_doorbell
extern xhci_poll_event
extern xhci_find_port
extern xhci_find_port_next
extern xhci_enable_slot
extern xhci_address_device
extern xhci_disable_slot
extern xhci_flush_events
extern xhci_pci_search_start
extern xhci_pci_this_start
extern xhci_probe
extern xhci_slot_id
extern xhci_slot2_mode
extern xhci_int_ep_dci
extern xhci_slot2_id
extern xhci_int_ep2_dci
extern xhci_int_enqueue2
extern xhci_int_cycle2
extern xhci_port_num
extern xhci_port_speed
extern xhci_op_base
extern xhci_max_ports

; --- MMIO bounds gate (security_todo.md §8) ---------------------------------
; usb_hid reaches the controller exclusively through xhci_op_base (an offset
; inside the xHCI BAR registered as MMIO_DRV_XHCI by mmio_drv_caps_init), so its
; PORTSC pokes are gated under that same id. mmio_bounds_assert preserves caller
; regs but reads rdi/rsi/edx; the macro saves/restores those three. Skipped when
; base==0 so a no-USB boot that never registered the BAR doesn't spuriously panic.
extern mmio_bounds_assert
%macro USBHID_MMIO_ASSERT 2        ; %1 = access addr/base reg, %2 = window (legacy, unused)
    push rdi
    push rsi
    push rdx
    mov rdi, %1
    test rdi, rdi
    jz %%skip
    ; 8-byte probe at the base (a PORTSC reg = xhci_op_base+0x400+...), NOT the
    ; whole window: the base is an offset inside the xHCI BAR, so a full-window
    ; span from here overshoots the registered region. Validates the base is in
    ; the BAR; offsets are < window. %2 kept for call-site compatibility.
    mov esi, 8
    mov edx, MMIO_DRV_XHCI
    call mmio_bounds_assert
%%skip:
    pop rdx
    pop rsi
    pop rdi
%endmacro
extern xhci_port1_num
extern debug_print
extern fat16_write_file
extern hid_parse_report_desc
extern hid_process_touchpad_report
extern hid_parsed_report_bytes
extern hid_parsed_has_report_id

extern mouse_x
extern mouse_y
extern mouse_buttons
extern mouse_moved
extern mouse_scroll_y
extern scr_width, scr_height
extern tick_count

section .text
; auto-wrapped (FN_BEGIN emits global): global usb_hid_init
; auto-wrapped (FN_BEGIN emits global): global usb_hid_init_same_ctrl
; auto-wrapped (FN_BEGIN emits global): global usb_hid_init_slot2
; auto-wrapped (FN_BEGIN emits global): global usb_poll_mouse
; auto-wrapped (FN_BEGIN emits global): global usb_hid_flush_log

; ============================================================================
; USB probe log helpers. This is intentionally narrow: it persists the HID/xHCI
; probe path to USBLOG.TXT on the Grit FAT data volume for real-hardware boots.
; ============================================================================
; usb_log_ch / usb_log_str / usb_log_crlf / usb_log_hex_nib were migrated to
; zero-asm GritHLK - see src/kernel/grithlk/usb_hid_helpers.ghl (compiled to
; build/ghl/usb_hid_helpers.asm, %include'd by kernel_build.asm BEFORE this
; file). Same global names + same custom register ABI (al/rsi in, all regs
; preserved). The hex/kv formatters below stay in asm and call those globals.

usb_log_hex8:
    push rax
    shr al, 4
    call usb_log_hex_nib
    pop rax
    push rax
    call usb_log_hex_nib
    pop rax
    ret

usb_log_hex16:
    push rax
    shr ax, 8
    call usb_log_hex8
    pop rax
    push rax
    call usb_log_hex8
    pop rax
    ret

usb_log_hex32:
    push rax
    shr eax, 16
    call usb_log_hex16
    pop rax
    push rax
    call usb_log_hex16
    pop rax
    ret

usb_log_kv8:
    call usb_log_str
    mov al, bl
    call usb_log_hex8
    call usb_log_crlf
    ret

usb_log_kv16:
    call usb_log_str
    mov ax, bx
    call usb_log_hex16
    call usb_log_crlf
    ret

; usb_hid_flush_log was migrated to zero-asm GritHLK -
; see src/kernel/grithlk/usb_hid_helpers.ghl. Same global name + ABI
; (no args; persists usb_log_buf to USBLOG.TXT via fat16_write_file).
%include "src/kernel/drivers/usb_hid_init.inc"
%include "src/kernel/drivers/usb_hid_poll.inc"
%include "src/kernel/drivers/usb_hid_slot2.inc"
%include "src/kernel/drivers/usb_hid_data.inc"
