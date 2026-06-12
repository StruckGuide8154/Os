# Grit Boot Reference

This document covers the early boot chain and the files that own each stage.

## Boot Ownership

### BIOS path

1. `src/boot/mbr.asm`
   Stage 1. Exactly 512 bytes. Loads stage 2 and jumps to it.
2. `src/boot/stage2.asm`
   Real-mode/transition bootloader. Enables A20, gathers E820, sets VESA,
   loads the kernel, builds paging, enters protected mode and then long mode.
3. `src/boot/a20.asm`
   A20-line enable helpers used from stage 2.
4. `src/boot/vesa.asm`
   VBE mode setup in 16-bit real mode.
5. `src/boot/paging.asm`
   Early page-table setup for long mode.
6. `src/boot/gdt.asm`
   Transition GDTs plus `gdt64_init` used later by the kernel.
7. `src/kernel/core/entry.asm`
   Long-mode kernel entry at `_start`.

### UEFI path

1. `src/boot/uefi_loader.asm`
   `BOOTX64.EFI`. Loads `KERNEL.BIN`, sets up GOP/paging, and jumps to the
   kernel.
2. `src/kernel/core/entry.asm`
   Long-mode kernel entry at `_start`.

## Boot Files and Purpose

### `src/boot/mbr.asm`

- Role: BIOS stage-1 boot sector
- Key entrypoint: implicit `mbr_start`
- Owns:
  - segment/stack setup in real mode
  - reading stage 2 from disk
  - transferring control to `stage2.asm`

### `src/boot/stage2.asm`

- Role: BIOS stage-2 loader
- Key entrypoint: `stage2_entry`
- Owns:
  - saving boot drive
  - A20 enable
  - E820 memory-map collection
  - VESA mode setup and framebuffer info
  - loading the kernel at `0x100000`
  - long-mode transition

### `src/boot/a20.asm`

- Role: A20-line enable logic
- Main routines:
  - `enable_a20`
  - `check_a20`

### `src/boot/vesa.asm`

- Role: BIOS VBE/GOP-era framebuffer mode selection
- Main routine:
  - `setup_vesa`
- Writes framebuffer metadata to `VBE_INFO_ADDR` for later kernel use.

### `src/boot/paging.asm`

- Role: early identity-mapped paging
- Main routine:
  - `setup_paging`
- Owns:
  - PML4/PDPT/PD setup in low memory
  - first 4 GB identity mapping with 2 MB pages

### `src/boot/gdt.asm`

- Role: GDT definitions for transition and long mode
- Exported kernel-facing entrypoint:
  - `gdt64_init`

### `src/boot/uefi_loader.asm`

- Role: UEFI loader image
- Owns:
  - PE image headers
  - UEFI service use for file loading / GOP setup
  - handing off framebuffer/platform state to the kernel

### `src/kernel/core/entry.asm`

- Role: first kernel code in 64-bit mode
- Exported entrypoint:
  - `_start`
- Owns:
  - serial breadcrumb that the kernel was reached
  - transferring control to `kmain`

## Typical Boot-Debug Path

- If BIOS fails before mode switch: inspect `mbr.asm`, `stage2.asm`,
  `a20.asm`, `paging.asm`, and `gdt.asm`.
- If video mode/framebuffer info is wrong: inspect `vesa.asm` or
  `uefi_loader.asm`, then `src/kernel/drivers/display.asm`.
- If the kernel is reached but crashes early: start at `src/kernel/core/entry.asm`
  and `src/kernel/core/main.asm`.
