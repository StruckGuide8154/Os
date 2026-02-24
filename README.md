# NexusOS v3.0

A 64-bit operating system written entirely in x86-64 assembly, featuring a graphical desktop environment.

## Prerequisites

| Tool | Version | Path |
|------|---------|------|
| [NASM](https://nasm.us/) | 2.16+ | `C:\Tools\nasm-2.16.03\nasm.exe` |
| [QEMU](https://www.qemu.org/download/) | Any recent | `C:\Program Files\qemu\` |
| OVMF firmware | — | Place `OVMF.fd` in `build\` (UEFI only) |

---

## Building

### UEFI (recommended)

```powershell
.\build_uefi.ps1
```

Outputs to `build\esp\EFI\BOOT\`:
- `BOOTX64.EFI` — UEFI bootloader
- `KERNEL.BIN` — NexusOS kernel
- `build\data.img` — FAT16 data disk

### BIOS (legacy)

```powershell
.\build_bios.ps1
```

Outputs to `build\`:
- `mbr.bin` — Stage 1 bootloader
- `stage2.bin` — Stage 2 bootloader
- `kernel.bin` — NexusOS kernel
- `NexusOS.img` — Combined bootable disk image

---

## Running in QEMU

### UEFI

```powershell
.\run_uefi.ps1
```

Launches with:
- OVMF UEFI firmware
- 512 MB RAM
- Standard VGA display
- xHCI USB controller with two USB mice
- Serial log → `build\serial_debug.log`
- QEMU monitor on `telnet://127.0.0.1:4444`

### BIOS

```powershell
.\run_bios.ps1
```

Launches with:
- 512 MB RAM
- Standard VGA display
- xHCI USB controller with USB mouse
- Serial log → `serial.log`

### Manual QEMU command (UEFI)

```powershell
& "C:\Program Files\qemu\qemu-system-x86_64.exe" `
    -bios build\OVMF.fd `
    -drive "file=fat:rw:build\esp" `
    -drive "file=build\data.img,format=raw,media=disk" `
    -m 512M `
    -vga std `
    -device qemu-xhci,id=xhci0 `
    -device usb-mouse,bus=xhci0.0 `
    -serial file:build\serial_debug.log `
    -no-reboot
```

### Manual QEMU command (BIOS)

```powershell
& "C:\Program Files\qemu\qemu-system-x86_64.exe" `
    -drive "file=build\NexusOS.img,format=raw,index=0,media=disk" `
    -m 512M `
    -vga std `
    -serial file:serial.log `
    -device nec-usb-xhci,id=xhci `
    -device usb-mouse,bus=xhci.0
```

> **Tip:** Use `-vga std` (not `virtio` or `cirrus`) for reliable PS/2 and display emulation.

---

## Booting on Real Hardware

### UEFI USB Drive

1. Build with `.\build_uefi.ps1`
2. Format a USB drive as FAT32
3. Copy the contents of `build\esp\` to the root of the USB drive — the drive should contain `EFI\BOOT\BOOTX64.EFI` and `EFI\BOOT\KERNEL.BIN`
4. Copy `build\data.img` to the USB root (optional — for FAT16 file access)
5. Boot the target machine and select the USB drive in the UEFI boot menu
6. Disable Secure Boot if required

**Tested hardware:** Acer Nitro ANV16-42 (AMD Ryzen 7 260, Zen 5, Radeon 780M)

---

## Debugging

### Serial output

Serial debug messages are written to COM1. In QEMU, capture them with:

```powershell
-serial file:build\serial_debug.log
```

**Expected boot trace:**
- UEFI: `ECGPTK!SWZ` — all stages passed
- BIOS: `12BC3K45678` — all stages passed

### QEMU monitor

Connect to the QEMU monitor while the VM is running:

```powershell
$tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$stream = $tcp.GetStream()
# Send commands e.g. "screendump build\screen.ppm`n"
```

Or use any Telnet client pointed at `127.0.0.1:4444`.

Useful monitor commands:
```
screendump build\screen.ppm   # capture screenshot as PPM
info registers                 # dump CPU registers
x /16xw 0x100000              # examine memory at kernel load address
```

---

## Project Structure

```
src/
  boot/         BIOS MBR, Stage 2, UEFI loader, A20, GDT, paging, VESA
  kernel/       Entry, IDT/ISR, PIC/PIT, ACPI, APIC, memory, FAT16
  drivers/      Display, keyboard, mouse, USB/xHCI, I2C HID, HID parser, PCI, ATA
  gui/          Desktop, window manager, taskbar, cursor, renderer, apps
  lib/          Font, string, math
  include/      constants.inc, macros.inc, structs.inc

build/          Build output (gitignored except helper scripts)
build_uefi.ps1  Build UEFI image
build_bios.ps1  Build BIOS image
run_uefi.ps1    Launch UEFI VM in QEMU
run_bios.ps1    Launch BIOS VM in QEMU
mkimg_uefi.ps1  Create UEFI disk image
mkimg.ps1       Create BIOS disk image
```

---

## Memory Map

| Address | Contents |
|---------|----------|
| `0x500` | GDT (copied at runtime) |
| `0x8000` | Trampoline code (UEFI) |
| `0x9000` | VBE/GOP framebuffer info (fb addr, width, height, pitch, bpp) |
| `0x70000` | Page tables (PML4 + PDPT, 512 GB mapped with 1 GB pages) |
| `0x100000` | Kernel load address |
| `0x200000` | Stack + IDT |
