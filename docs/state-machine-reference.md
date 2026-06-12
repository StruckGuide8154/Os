# GritOS State Machine Reference

This document describes the important maintainer-level state machines and
interaction flows for GUI/input/USB subsystems.

## Windowing and GUI Event Flow

Primary owners:

- `src/kernel/gui/window.asm`
- `src/kernel/gui/taskbar.asm`
- `src/kernel/gui/desktop.asm`
- `src/kernel/gui/cursor.asm`
- `src/kernel/proc/usermode.asm`

### Mouse/click flow

1. Low-level pointer state is updated by:
   - `mouse.asm`
   - `usb_hid.asm`
   - `i2c_hid.asm`
   - `spi_hid.asm`
2. Kernel main/input processing forwards events into:
   - `wm_handle_mouse_event`
   - taskbar/desktop click handlers
3. `wm_handle_mouse_event` decides:
   - titlebar drag
   - close/minimize hit
   - client-area click callback
   - focus change
4. If a user callback exists, it enters ring 3 via `call_app_l3`.

### Focus/visibility state

Key state globals:

- `wm_window_count`
- `wm_focused_window`
- `wm_drag_window_id`
- `wm_drag_preview_x/y/w/h`

State bits:

- `WF_ACTIVE`
- `WF_VISIBLE`
- `WF_FOCUSED`
- `WF_MINIMIZED`
- `WF_DRAGGING`

### Rendering flow

Owners:

- `src/kernel/gui/render.asm`
- `src/kernel/drivers/display.asm`
- `src/kernel/core/main.asm`

High-level flow:

1. Desktop/taskbar/windows render into the backbuffer.
2. Render layer tracks dirty/full state.
3. Display layer flips full screen or dirty rectangles.
4. Cursor hide/draw wraps the visible cursor update.

Important globals:

- `scene_dirty`
- `bb_addr`
- `fb_addr`
- `scr_width`
- `scr_height`
- `scr_pitch`
- `last_fps`
- `frame_count`

## Taskbar and Start Menu State

Owner:
- `src/kernel/gui/taskbar.asm`

Primary state globals:

- `tb_start_menu_open`
- `sm_submenu_open`
- `sm_submenu_app`
- `sm_submenu_x`
- `sm_submenu_y`
- `sm_prev_mouseX`
- `sm_prev_mouseY`

Maintainer notes:

- The taskbar has two layers of state:
  - the main start menu
  - the app submenu used for add/remove desktop icon actions
- Window buttons are drawn by scanning the live window pool.
- Battery and clock rendering share this draw path.

## Desktop Icon State

Owner:
- `src/kernel/gui/desktop.asm`

Primary exported state:

- `desktop_icons`

Main operations:

- `desktop_has_icon`
- `desktop_add_icon`
- `desktop_remove_icon`
- `desktop_handle_click`

The taskbar submenu uses these functions to pin/unpin apps to the desktop.

## Cursor State Machine

Owner:
- `src/kernel/gui/cursor.asm`

Main flow:

1. `cursor_init` resets state.
2. `cursor_hide` restores the background under the old cursor position.
3. `cursor_draw` saves background under the new position and draws the cursor.
4. `cursor_update` handles state updates between draw cycles.

Primary state:

- `cursor_mode`
- old/new cursor position and saved background storage

## Keyboard and Pointer Input State

### Keyboard

Owner:
- `src/kernel/drivers/keyboard.asm`

State globals:

- `keyboard_repeat_tick`
- `kb_numlock`

Flow:

1. IRQ1 handler captures scancode.
2. Driver translates into buffered events.
3. Higher-level processing routes it to focused window/app or shell logic.

### PS/2 mouse

Owner:
- `src/kernel/drivers/mouse.asm`

State globals:

- `mouse_x`
- `mouse_y`
- `mouse_buttons`
- `mouse_moved`
- `mouse_init_status`

Flow:

1. IRQ12 or polling path decodes 3-byte packets.
2. Shared mouse globals update.
3. GUI/input layer consumes those globals.

## HID Parsing and Gesture State

Owner:
- `src/kernel/drivers/hid_parser.asm`

This file is the normalization layer between transport-specific HID drivers and
the shared cursor/gesture state.

### Parsed descriptor state

Important globals:

- `hid_parsed_report_id`
- `hid_parsed_has_report_id`
- `hid_parsed_is_absolute`
- `hid_parsed_is_touchpad`
- `hid_parsed_report_bytes`
- `hid_parsed_x_bit_offset`
- `hid_parsed_x_bit_size`
- `hid_parsed_y_bit_offset`
- `hid_parsed_y_bit_size`
- `hid_parsed_btn_bit_offset`
- `hid_parsed_btn_count`
- `hid_parsed_tip_bit_offset`
- `hid_parsed_cid_bit_offset`
- `hid_parsed_cid_bit_size`
- `hid_parsed_cc_bit_offset`
- `hid_parsed_cc_bit_size`
- `hid_parsed_max_contacts`
- `hid_parsed_contact_stride`

These are populated by `hid_parse_report_desc`.

### Gesture state

Important globals:

- `gesture_prev_count`
- `gesture_tap_start_tick`
- `gesture_tap_start_x`
- `gesture_tap_start_y`
- `gesture_tap_pending`
- `gesture_tap_click`
- `gesture_scroll_active`
- `gesture_scroll_ref_y`
- `gesture_scroll_ref_x`
- `gesture_pinch_dist_prev`
- `gesture_swipe_dir`
- `mouse_pinch_delta`
- `mouse_scroll_y`

Maintainer notes:

- Transport drivers should treat HID parser output as the canonical normalized
  state instead of inventing new per-transport gesture logic.

## USB / XHCI State Machine

Primary owners:

- `src/kernel/drivers/xhci.asm`
- `src/kernel/drivers/usb_hid.asm`

### XHCI lifecycle

1. `xhci_init`
   - zeroes the reserved XHCI memory region
   - scans PCI for a controller
   - reads capabilities
   - takes ownership from BIOS
   - resets the controller
   - sets up scratchpad/DCBAA/command/event rings
   - programs registers
   - starts the controller
2. `xhci_probe`
   - walks ports and finds candidate devices
3. Device configuration:
   - `xhci_enable_slot`
   - `xhci_address_device`
   - `xhci_configure_endpoint`
4. Runtime I/O:
   - command ring via `xhci_submit_cmd`
   - event ring via `xhci_poll_event`
   - interrupt rings via `xhci_queue_int_trb` / `xhci_queue_int_trb2`

### Important XHCI state globals

- `xhci_active`
- `xhci_op_base`
- `xhci_max_ports`
- `xhci_slot_id`
- `xhci_slot2_id`
- `xhci_port_num`
- `xhci_port_speed`
- `xhci_int_ep_dci`
- `xhci_int_ep2_dci`
- `xhci_int_enqueue`
- `xhci_int_cycle`
- `xhci_int_enqueue2`
- `xhci_int_cycle2`

### USB HID lifecycle

Owner:
- `src/kernel/drivers/usb_hid.asm`

High-level flow:

1. Initialize controller/device path.
2. Fetch descriptors and configure interrupt endpoint.
3. Queue interrupt TRBs.
4. Poll/consume event data.
5. Hand report bytes to HID parsing and then to shared pointer state.

Primary state:

- `usb_mouse_active`
- `usb_no_xhci`

## I2C HID and SPI HID

Owners:

- `src/kernel/drivers/i2c_hid.asm`
- `src/kernel/drivers/spi_hid.asm`

Role:

- transport-specific device init and report retrieval
- handoff to `hid_parser.asm` for descriptor interpretation and gesture logic

Primary exported state:

- `i2c_hid_active`

Debug entrypoints:

- `i2c_hid_debug_dump`
- `xhci_debug_dump`
- `mouse_debug_dump`

## FAT16 Driver Flow

Owner:
- `src/kernel/fs/fat16.asm`

Lifecycle:

1. `fat16_init`
   - reads BPB
   - caches FAT and root directory
2. `fat16_change_dir`
   - switches current directory cache
3. `fat16_get_entry`
   - returns an opaque handle into current cache
4. `fat16_read_file` / `fat16_write_file`
   - follow FAT chains and ATA I/O
5. `fat16_sync_root`
   - flushes modified FAT/root state

Important rule:

- The current directory cache is part of the FAT16 driver's state machine.
  Bugs involving stale entries, invalid handles, or path confusion usually live
  here or at the syscall boundary.
