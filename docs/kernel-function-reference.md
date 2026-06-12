# Grit Kernel Function Reference

This is the exported kernel surface grouped by subsystem. It is intentionally
organized by owning file first so bug-fixing starts at the right module.

## Core

### `src/kernel/core/entry.asm`

`_start`
- First kernel entrypoint after the bootloader.
- Jumps into `kmain`.

### `src/kernel/core/main.asm`

`kmain`
- Top-level kernel bring-up and main loop owner.

`process_keyboard`
- Main keyboard event processing path after low-level driver intake.

`process_mouse`
- Main mouse event processing path after low-level driver intake.

`debug_print`
- Serial/screen debug output helper used throughout the kernel.

`serial_poll_command`
- Polls serial/command input path used for debug/control.

State globals:
- `gui_initialized`
- `scene_dirty`
- `szBootMsg`
- `szUsbInit`
- `szUsbDone`
- `szI2cInit`
- `szI2cDone`
- `szUsermodeIn`

### `src/kernel/core/idt.asm`

`idt_init`
- Builds and loads the 64-bit IDT.

### `src/kernel/core/isr.asm`

`isr_common_stub`
- Common exception stub backend.

`irq_common_stub`
- Common IRQ stub backend.

### `src/kernel/core/memory.asm`

`memory_init`
- Initializes the physical page allocator from the memory map.

`page_alloc`
- Allocates one 4 KB physical page.

`page_free`
- Frees one 4 KB physical page.

`memory_get_free`
- Reports free memory/page availability.

State globals:
- `free_page_count`

### `src/kernel/core/pic.asm`

`pic_init`
- Remaps and initializes the legacy PIC.

`pic_eoi_master`
- Sends EOI to the master PIC.

`pic_eoi_slave`
- Sends EOI to the slave PIC.

`pic_mask_irq`
- Masks a PIC IRQ line.

`pic_unmask_irq`
- Unmasks a PIC IRQ line.

### `src/kernel/core/pit.asm`

`pit_init`
- Initializes the PIT timer.

`pit_handler`
- Timer interrupt handler backend.

State globals:
- `tick_count`
- `last_fps`
- `frame_count`
- `start_tick`
- `time_hours`
- `time_minutes`

### `src/kernel/core/tss.asm`

`tss64`
- TSS structure storage.

`tss_init`
- Initializes/loads the TSS.

## Architecture / Platform Discovery

### `src/kernel/arch/rsdp.asm`

`rsdp_find`
- Finds the ACPI RSDP.

### `src/kernel/arch/acpi.asm`

`acpi_init`
- Main ACPI bring-up entrypoint. Owns table discovery and downstream init.

### `src/kernel/arch/madt.asm`

`madt_init`
- Parses the MADT and feeds interrupt-controller setup.

### `src/kernel/arch/aml_parser.asm`

`aml_init`
- Initializes AML parser state against DSDT/SSDT content.

`aml_find_object`
- Finds AML objects by name/path.

`aml_evaluate`
- Evaluates a supported AML object.

State globals:
- `aml_dsdt_base`
- `aml_dsdt_end`

### `src/kernel/arch/apic.asm`

`apic_init`
- Initializes the local APIC.

`apic_eoi`
- Sends EOI through the APIC path.

### `src/kernel/arch/ioapic.asm`

`ioapic_init`
- Initializes the IOAPIC.

`ioapic_set_irq`
- Programs one IOAPIC routing entry.

State globals:
- `ioapic_base`
- `touchpad_irq`

## Drivers

### `src/kernel/drivers/acpi_pci.asm`

`acpi_pci_init`
- Initializes PCI MMCONFIG enumeration from ACPI MCFG.

State globals:
- `mcfg_base`

### `src/kernel/drivers/acpi_ec.asm`

`acpi_ec_init`
- Initializes EC access path.

`acpi_ec_read`
- Reads one EC register.

`acpi_ec_write`
- Writes one EC register.

### `src/kernel/drivers/ata.asm`

`ata_read_sectors`
- ATA PIO sector read.

`ata_write_sectors`
- ATA PIO sector write.

`ata_drive_select_byte`
- Drive/head select byte helper/state.

`ata_drive_sel`
- Current ATA drive-selection state.

### `src/kernel/drivers/battery.asm`

`battery_init`
- Initializes battery polling state.

`battery_poll`
- Polls battery/AC state.

State globals:
- `battery_state`
- `battery_percent`

### `src/kernel/drivers/display.asm`

`display_init`
- Initializes framebuffer/backbuffer state from bootloader handoff.

`pixel_set`
- Writes one pixel.

`fill_rect`
- Fills a rectangle.

`draw_char`
- Draws one glyph.

`draw_string`
- Draws a string.

`draw_hline`
- Horizontal line primitive.

`draw_vline`
- Vertical line primitive.

`draw_rect_outline`
- Rectangle outline primitive.

`display_flip`
- Full framebuffer flip.

`display_flip_rect`
- Dirty-rect flip.

`display_clear`
- Clears the display/backbuffer.

`wait_vsync`
- Waits for the next VSync-compatible point.

`display_set_mode`
- Changes display mode/resolution state.
- On AMD display hardware, routes through the AMD display provider and only
  accepts the native firmware/GOP mode in this phase.

State globals:
- `fb_addr`
- `bb_addr`
- `scr_width`
- `scr_height`
- `scr_pitch`
- `last_vsync_tick`
- `vsync_enabled`
- `fps_show`

### `src/kernel/drivers/amd_display.asm`

`amd_display_init`
- Claims AMD Radeon 780M / AMD display PCI hardware and latches the boot
  framebuffer as the active native mode.

`amd_display_set_mode`
- AMD display mode-setting entrypoint. Accepts the native 32bpp firmware/GOP
  mode and rejects unsafe non-native switches.

### `src/kernel/drivers/keyboard.asm`

`keyboard_init`
- Initializes PS/2 keyboard handling.

`keyboard_handler`
- IRQ1 keyboard handler backend.

`keyboard_read`
- Reads one buffered key event.

`keyboard_available`
- Tests whether key input is available.

State globals:
- `keyboard_repeat_tick`
- `kb_numlock`

### `src/kernel/drivers/mouse.asm`

`mouse_init`
- Initializes PS/2 mouse handling.

`mouse_wait_input`
- 8042/mouse synchronization helper.

`mouse_handler`
- IRQ12 handler backend.

`mouse_read`
- Reads buffered mouse state/event data.

`mouse_get_pos`
- Returns current mouse position.

`mouse_get_buttons`
- Returns current mouse-button state.

`mouse_check_moved`
- Tests whether pointer state changed.

`uefi_mouse_poll`
- UEFI-side mouse polling helper.

`mouse_debug_dump`
- Dumps mouse debug state.

State globals:
- `mouse_x`
- `mouse_y`
- `mouse_buttons`
- `mouse_moved`
- `mouse_init_status`

### `src/kernel/drivers/pci.asm`

`pci_read_conf_dword`
- Reads one PCI config dword.

`pci_write_conf_dword`
- Writes one PCI config dword.

### `src/kernel/drivers/spi.asm`

`spi_init`
- Initializes the SPI controller path.

`spi_transfer`
- Performs a SPI transaction.

State globals:
- `spi_type`
- `spi_base`

### `src/kernel/drivers/spi_hid.asm`

`spi_hid_init`
- Initializes HID-over-SPI device handling.

`spi_hid_poll`
- Polls SPI HID input.

### `src/kernel/drivers/usb.asm`

`usb_init`
- USB controller discovery / legacy-init entrypoint.

### `src/kernel/drivers/usb_hid.asm`

`usb_hid_init`
- Initializes primary USB HID path.

`usb_hid_init_same_ctrl`
- Initializes same-controller secondary path.

`usb_hid_init_slot2`
- Initializes the slot-2 USB HID path.

`usb_poll_mouse`
- Polls USB mouse state.

State globals:
- `usb_mouse_active`
- `usb_no_xhci`

### `src/kernel/drivers/xhci.asm`

`xhci_init`
- Finds and initializes the XHCI controller.

`xhci_probe`
- Probes XHCI ports/devices.

`xhci_submit_cmd`
- Queues an XHCI command.

`xhci_poll_event`
- Polls the XHCI event ring.

`xhci_find_port`
- Finds the first matching XHCI port.

`xhci_find_port_next`
- Finds the next matching XHCI port.

`xhci_enable_slot`
- Issues ENABLE_SLOT.

`xhci_address_device`
- Issues ADDRESS_DEVICE.

`xhci_ring_doorbell`
- Rings the XHCI doorbell.

`xhci_queue_ctrl_trb`
- Queues a control transfer TRB.

`xhci_queue_int_trb`
- Queues an interrupt TRB on the primary path.

`xhci_queue_int_trb2`
- Queues an interrupt TRB on the secondary path.

`xhci_configure_endpoint`
- Issues CONFIGURE_ENDPOINT.

`xhci_flush_events`
- Flushes or drains the event ring.

`xhci_debug_dump`
- Dumps controller debug state.

State globals include:
- `xhci_active`
- `xhci_pci_search_start`
- `xhci_pci_this_start`
- `xhci_op_base`
- `xhci_slot2_mode`
- `xhci_max_ports`
- `xhci_int_enqueue`
- `xhci_int_cycle`
- `xhci_port_num`
- `xhci_port_speed`
- `xhci_slot_id`
- `xhci_int_ep_dci`
- `xhci_slot2_id`
- `xhci_int_ep2_dci`
- `xhci_int_enqueue2`
- `xhci_int_cycle2`

### `src/kernel/drivers/hid_parser.asm`

`hid_parse_report_desc`
- Parses a HID report descriptor into shared parsed-layout globals.

`hid_extract_field`
- Extracts an unsigned field from a HID report.

`hid_extract_field_signed`
- Extracts a signed field from a HID report.

`hid_process_touchpad_report`
- Interprets touchpad reports using the parsed layout.

`gesture_update`
- Gesture engine update path.

State globals include:
- parsed report metadata (`hid_parsed_*`)
- gesture/mouse integration globals (`gesture_tap_click`, `mouse_scroll_y`,
  `mouse_pinch_delta`)

### `src/kernel/drivers/i2c_hid.asm`

`i2c_hid_init`
- Initializes I2C HID touchpad path.

`i2c_hid_poll`
- Polls I2C HID touchpad input/state machine.

`i2c_hid_debug_dump`
- Dumps I2C HID debug state.

State globals:
- `i2c_hid_active`

## Filesystem

### `src/kernel/fs/fat16.asm`

`fat16_init`
- Initializes FAT16 metadata and caches.

`fat16_list_dir`
- Lists current directory entries.

`fat16_read_file`
- Reads a file from a FAT16 entry handle.

`fat16_write_file`
- Writes/creates a file from an 8.3 name and source buffer.

`fat16_delete_entry`
- Deletes a file or empty directory from the current directory cache, frees its
  FAT chain, and flushes metadata to disk.

`fat16_rename_entry`
- Renames an entry in the current directory cache after checking for duplicates.

`fat16_mkdir`
- Creates a real single-cluster FAT16 directory with `.` and `..` entries.

`fat16_flush_current_dir`
- Flushes the current directory cache, whether it currently represents root or
  a loaded subdirectory.

`fat16_flush_fats`
- Flushes the cached FAT table to all configured FAT copies.

`fat16_get_file_size`
- Reports file size.

`fat16_file_count`
- Returns count of valid entries in the current directory cache.

`fat16_get_entry`
- Returns an opaque FAT16 directory-entry handle for the current directory cache.

`fat16_change_dir`
- Switches the current directory cache.

`fat16_sync_root`
- Compatibility wrapper that flushes the current directory cache.

`fat16_debug_dump_root`
- Debug-dumps root/current directory cache state.

## GUI

### `src/kernel/gui/render.asm`

`render_init`
- Initializes render-layer state.

`render_rect`
- Rectangle draw helper used by GUI and syscalls.

`render_text`
- Text draw helper used by GUI and syscalls.

`render_line`
- Line helper used by GUI paths.

`render_get_backbuffer`
- Returns backbuffer pointer/state.

`render_mark_dirty`
- Marks a dirty rectangle.

`render_mark_full`
- Marks the full screen dirty.

`render_flush`
- Flushes pending dirty state to display.

`render_save_backbuffer`
- Saves backbuffer state for overlays/drag.

`render_restore_backbuffer`
- Restores saved backbuffer state.

### `src/kernel/gui/window.asm`

`wm_init`
- Clears and initializes the window pool.

`wm_create_window`
- Simple window-creation helper.

`wm_create_window_ex`
- Full window creation path with title/callback/app-data setup.

`wm_draw_window`
- Draws one window.

`wm_draw_desktop`
- Draws all visible windows and desktop-level composition.

`wm_handle_mouse_event`
- Main mouse event router for windowing.

`wm_get_window_at`
- Hit-tests a window at screen coordinates.

`wm_close_window`
- Closes a window id and clears slot state.

`wm_draw_drag_outline`
- Draws drag preview/outline.

State globals:
- `wm_window_count`
- `wm_focused_window`
- `wm_drag_window_id`
- `wm_drag_preview_x`
- `wm_drag_preview_y`
- `wm_drag_preview_w`
- `wm_drag_preview_h`

### `src/kernel/gui/taskbar.asm`

`tb_draw`
- Draws the taskbar.

`tb_handle_click`
- Handles taskbar clicks.

`tb_get_menu_item_at`
- Hit-tests start-menu entries.

`tb_handle_rclick`
- Handles taskbar right-click path.

`tb_draw_submenu`
- Draws the taskbar submenu.

`tb_handle_submenu_click`
- Handles submenu click path.

State globals:
- `tb_start_menu_open`
- `sm_submenu_open`

### `src/kernel/gui/desktop.asm`

`desktop_draw_icons`
- Draws desktop icons.

`desktop_handle_click`
- Handles desktop icon clicks.

`desktop_has_icon`
- Tests icon presence.

`desktop_add_icon`
- Adds a desktop icon.

`desktop_remove_icon`
- Removes a desktop icon.

State globals:
- `desktop_icons`

### `src/kernel/gui/cursor.asm`

`cursor_init`
- Initializes cursor state and backing storage.

`cursor_hide`
- Restores saved background under the cursor.

`cursor_update`
- Updates cursor state.

`cursor_draw`
- Draws the cursor.

State globals:
- `cursor_mode`

## Libraries

### `src/kernel/lib/string.asm`

`fn_strlen`
- String length.

`fn_strcmp`
- String compare.

`fn_strcpy`
- String copy.

`fn_memcpy`
- Memory copy.

`fn_memset`
- Byte memset.

`fn_memsetd`
- Dword memset.

`fn_itoa`
- Integer to string.

`fn_itoa_dec2`
- Two-digit decimal formatting helper.

`uint32_to_str`
- Unsigned 32-bit integer to string.

### `src/kernel/lib/math.asm`

`fn_clamp`
- Clamp value into range.

`fn_min`
- Minimum.

`fn_max`
- Maximum.

`fn_abs`
- Absolute value.

`fn_rect_intersect`
- Rectangle intersection test/helper.

### `src/kernel/lib/font.asm`

`font_data`
- Font glyph data blob.
