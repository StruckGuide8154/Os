# GritOS Reference Index

This is the maintainer-facing map of the codebase. The goal is to let you find
the owning file and exported entrypoints for a bug or feature without tracing
through the whole tree first.

## Start Here

- `syscalls.md`
  Ring-3 syscall ABI, validation rules, and return semantics.
- `usermode-reference.md`
  Ring-3 callback path, slot/runtime layout, and user app ownership model.
- `kernel-function-reference.md`
  Exported kernel entrypoints grouped by subsystem and owning file.
- `memory-map-reference.md`
  Fixed-address regions, scratch buffers, and reserved memory ownership.
- `invariant-registry.md`
  Normative fixed addresses, L3 slot layout, syscall range, and callback rules.
- `ownership-registry.md`
  Normative owner file and guard for each critical subsystem.
- `data-layout-reference.md`
  Live structure layouts for windows, processes, runtime frames, and FAT16.
- `state-machine-reference.md`
  Maintainer-level event/state flow for GUI, input, FAT16, and USB/HID.
- `boot-reference.md`
  BIOS/UEFI boot flow and early-platform setup files.
- `architecture.md`
  High-level runtime flow from boot to kernel to ring 3.
- `source-layout.md`
  Tree structure and editing rules.
- `verification.md`
  Normative staged build, serial boot, L3 app, Cache32Max, and SMP checks.
- `build/reports/source-map.md`
  Generated include order, exported labels, and fixed-address references.
- `build/reports/complexity-dashboard.md`
  Generated large-file, export, fixed-address, and TODO/STUB/FIXME counts.
- `app-authoring.md`
  User-app development surface today.
- `grithl-gui.md`
  GritHL immediate-mode GUI library and widget ownership rules.
- `app-loader-format.md`
  Proposed future external app binary and loader contract.
- `multicore.md`
  SMP work queue: offloading heavy work to application processors.

## By Problem Area

### Boot and bring-up

- Kernel entry is in `src/kernel/core/entry.asm`
- BIOS path is documented in `boot-reference.md`
- UEFI path is documented in `boot-reference.md`

### Interrupts, timers, and CPU setup

- `src/kernel/core/idt.asm`
- `src/kernel/core/isr.asm`
- `src/kernel/core/pic.asm`
- `src/kernel/core/pit.asm`
- `src/kernel/core/tss.asm`
- See `kernel-function-reference.md`

### Memory and allocation

- `src/kernel/core/memory.asm`
- See `kernel-function-reference.md`

### ACPI, APIC, and platform discovery

- `src/kernel/arch/*.asm`
- `src/kernel/drivers/acpi_*.asm`
- See `kernel-function-reference.md`

### Filesystem and storage

- `src/kernel/fs/fat16.asm`
- `src/kernel/drivers/ata.asm`
- See `kernel-function-reference.md`

### Display and GUI

- `src/kernel/drivers/display.asm`
- `src/kernel/gui/render.asm`
- `src/kernel/gui/window.asm`
- `src/kernel/gui/taskbar.asm`
- `src/kernel/gui/desktop.asm`
- `src/kernel/gui/cursor.asm`
- See `kernel-function-reference.md`

### Input and HID

- `src/kernel/drivers/keyboard.asm`
- `src/kernel/drivers/mouse.asm`
- `src/kernel/drivers/usb*.asm`
- `src/kernel/drivers/i2c_hid.asm`
- `src/kernel/drivers/spi*.asm`
- `src/kernel/drivers/hid_parser.asm`
- See `kernel-function-reference.md`

### Ring-3 callbacks, syscalls, and process/runtime state

- `src/kernel/proc/usermode.asm`
- `src/kernel/proc/syscall.asm`
- `src/kernel/proc/process.asm`
- See `usermode-reference.md`, `syscalls.md`, and `data-layout-reference.md`

### Built-in user apps

- `src/user/apps.asm`
- `src/user/apps/*.inc`
- `src/user/lib/*.inc`
- See `usermode-reference.md` and `app-authoring.md`

### Memory maps and fixed buffers

- `memory-map-reference.md`
- `data-layout-reference.md`

### State machines and live subsystem flow

- `state-machine-reference.md`

### Multi-core and offloading heavy work

- `src/kernel/proc/workqueue.asm`
- `src/kernel/arch/apic.asm` (AP bring-up)
- See `multicore.md`

## Quick "Where Do I Fix This?" Map

- Boot crash before kernel: `boot-reference.md`
- IRQ crash or exception vector issue: `kernel-function-reference.md` under
  `core`
- Wrong fixed address or overlapping scratch buffer: `memory-map-reference.md`
- Confusing live struct offsets or slot layout: `data-layout-reference.md`
- Broken mouse/keyboard/touchpad: `kernel-function-reference.md` under
  `drivers`, then `state-machine-reference.md`
- Files not reading/writing: `kernel-function-reference.md` under `fs`
- File create/rename/delete/mkdir ABI: `syscalls.md` and
  `src/user/lib/grit_fs.inc`
- Window/callback bug: `kernel-function-reference.md` under `gui` plus
  `usermode-reference.md` and `data-layout-reference.md`
- Syscall reject or privilege bug: `syscalls.md` plus `src/kernel/proc/syscall.asm`
- Ring-3 callback return-path bug: `usermode-reference.md`
- Built-in app behavior bug: `usermode-reference.md` plus the owning file under
  `src/user/apps`
