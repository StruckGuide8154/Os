# GritOS Memory Map Reference

This document collects the fixed-address regions and major in-memory ownership
rules used across boot, kernel, drivers, GUI, and ring 3.

Primary source: `C:\Users\user\Documents\new\src\include\constants.inc`

## Low Memory and Boot Handoff

| Address | Meaning | Owner |
|---|---|---|
| `0x7E00` | Stage-2 load address | `src/boot/stage2.asm` |
| `0x1FF0` | E820 entry count | `src/boot/stage2.asm` |
| `0x2000` | E820 memory map | `src/boot/stage2.asm` |
| `0x9000` | VBE/GOP framebuffer info block | `src/boot/vesa.asm`, `src/boot/uefi_loader.asm` |
| `0x9100` | Saved boot drive byte | BIOS boot path |
| `0x70000` | Page-table base | `src/boot/paging.asm` |

## Kernel Core

| Address | Meaning | Owner |
|---|---|---|
| `0x100000` | Kernel load address | bootloaders + `src/kernel/core/entry.asm` |
| `0xC00000` | Kernel stack top | `src/kernel/core/entry.asm` |
| `0xC10000` | IDT base region | `src/kernel/core/idt.asm`, `src/kernel/core/tss.asm` |
| `0xC20000` | Kernel data / heap start | shared kernel region |
| `0xE00000` | Physical-page bitmap | `src/kernel/core/memory.asm` |

## Graphics and Windowing

| Address | Meaning | Owner |
|---|---|---|
| `0x1000000` | Display backbuffer | `src/kernel/drivers/display.asm`, `src/kernel/gui/render.asm` |
| `0x2400000` | Cursor background-save area | `src/kernel/gui/cursor.asm` |
| `0x2410000` | Window pool base | `src/kernel/gui/window.asm` |
| `0x2420000` | Event-buffer region | shared GUI/input region |
| `0x3000000` | Liquid-metal wallpaper cache | `src/kernel/gui/window.asm` |
| `0x3900000` | Glass-ribbons wallpaper cache | `src/kernel/gui/window.asm` |
| `0x4200000` | Frosted-bloom wallpaper cache | `src/kernel/gui/window.asm` |
| `0x4C00000` | Saved backbuffer / drag/restore region | `src/kernel/gui/render.asm` |

The GUI composition region starts at `0x1000000`; the boot backbuffer occupies
`0x1000000..0x1900000`. XHCI, FAT16, and network-driver DMA buffers live above
that range so device DMA cannot overwrite rendered pixels or mouse reports.

## Ring-3 App Arenas and Runtime

| Address | Meaning | Owner |
|---|---|---|
| `0x2600000` | App slot arena base | `src/kernel/proc/usermode.asm`, `src/kernel/gui/window.asm` |
| `0x2600000 + slot * 0x100000` | Per-slot app arena | `src/kernel/proc/usermode.asm` |
| `0x2F00000` | Kernel-only syscall-stack region | `src/kernel/proc/usermode.asm`, `src/kernel/proc/syscall.asm` |

### App slot rules

- Each slot is `APP_SLOT_SIZE = 0x100000` bytes.
- The slot stores:
  - user code/data
  - a shadow window struct near the end of the slot
  - per-slot callback-local state
- `WIN_OFF_APPDATA` points at the slot base for a window.

## USB / XHCI Fixed Region

These addresses are reserved by the USB stack and should not be repurposed
without auditing `src/kernel/drivers/xhci.asm`, `src/kernel/drivers/usb_hid.asm`,
and `src/kernel/drivers/hid_parser.asm`.

| Address | Meaning |
|---|---|
| `0x1900000` | XHCI DCBAA |
| `0x1910000` | XHCI command ring |
| `0x1920000` | XHCI ERST |
| `0x1930000` | XHCI event ring |
| `0x1940000` | XHCI scratchpad region |
| `0x1950000` | XHCI device context slot 1 |
| `0x1960000` | XHCI input context |
| `0x1970000` | XHCI control ring |
| `0x1980000` | XHCI interrupt ring |
| `0x1990000` | XHCI control-buffer region |
| `0x19A0000` | XHCI mouse buffer slot 1 |
| `0x19B0000` | XHCI device context slot 2 |
| `0x19C0000` | XHCI interrupt ring slot 2 |
| `0x19D0000` | XHCI mouse buffer slot 2 |
| `0x19E0000` | XHCI control ring slot 2 |
| `0x19F0000` | End of XHCI reserved region |

## Network Driver DMA Regions

| Address | Meaning |
|---|---|
| `0x1B00000` | RTL8139 RX buffer |
| `0x1B04000` | RTL8139 TX buffer |
| `0x1B10000` | RTL8156 bulk-IN ring |
| `0x1B20000` | RTL8156 bulk-OUT ring |
| `0x1B30000` | RTL8156 RX buffer |
| `0x1B40000` | RTL8156 TX buffer |
| `0x1B50000` | RTL8156 scratch buffer |
| `0x1B60000` | RTL8156 xHCI device context |
| `0x1B70000` | RTL8156 xHCI control ring |

## FAT16 Driver Scratch Regions

These addresses are owned by `src/kernel/fs/fat16.asm`.

Under `GRIT_CACHE32_MAX`, these cold buffers move to the `0x1A00000` region.

| Address | Meaning |
|---|---|
| `0xD00000` | FAT16 sector buffer |
| `0xD01000` | FAT table cache |
| `0xD11000` | root/current directory cache |
| `0xD21000` | file read buffer |
| `0xD31000` | directory cache |

## Shared Scratch Buffers Used By Built-in Apps

These constants are exposed in `src/user/lib/grit_window.inc` and are
currently allowed by syscall validation because the built-in apps use them.

| Address | Meaning | Current use |
|---|---|---|
| `0x950000` | app BMP file scratch | BMP viewer path in `src/user/apps/shell.inc` |
| `0x990000` | paint canvas buffer | Paint app in `src/user/apps/paint.inc` |

These are not ideal long-term boundaries. They are documented here so they are
visible during future hardening work.

## Screen and UI Constants

Important global geometry constants:

- `SCREEN_WIDTH = 1024`
- `SCREEN_HEIGHT = 768`
- `SCREEN_BPP = 32`
- `SCREEN_PITCH = 4096`
- `TASKBAR_HEIGHT = 36`
- `TITLEBAR_HEIGHT = 24`
- `BORDER_WIDTH = 2`

## Ownership Rules

- If an address is in a fixed reserved region, treat the owning subsystem as
  authoritative.
- Do not add new fixed buffers casually; prefer extending the owning
  subsystem's documented region or moving data into per-slot/per-object storage.
- When moving any fixed address, update:
  - `constants.inc`
  - subsystem code
  - syscall validation exceptions
  - this document
