# FAT16 RAM disk (`DATA.IMG`)

## Why

Grit's filesystem driver (`src/kernel/fs/fat16.asm`) reads sectors via
`ata_read_sectors`, which talks to legacy IDE ports `0x1F0-0x1F7`. That works
under QEMU when we attach `build/data.img` with `-drive if=ide`. On a modern
laptop (NVMe storage, USB boot) there is no legacy IDE controller, those
ports return `0xFF`, the FAT16 signature check fails, and the entire data
volume is unreadable - which is why real-hardware boots used to show only
`USBLOG.TXT` (created by a write into the zeroed in-memory root cache) and
the boot animation never played (no `BOOTANIM.NBA` to find).

## How it works

| Stage             | Component                                                              |
| ----------------- | ---------------------------------------------------------------------- |
| Build             | [`scripts/build/build_uefi.ps1`](../scripts/build/build_uefi.ps1)      |
| Boot load         | [`src/boot/uefi_loader.asm`](../src/boot/uefi_loader.asm) `load_data_img` |
| Boot info offsets | [`src/include/boot_memory.inc`](../src/include/boot_memory.inc) `VBE_RAMDISK_*` |
| Kernel register   | [`src/kernel/drivers/ramdisk.asm`](../src/kernel/drivers/ramdisk.asm) `ramdisk_init` |
| Block I/O shim    | [`src/kernel/drivers/ata.asm`](../src/kernel/drivers/ata.asm) fast paths |

1. The UEFI build script writes the FAT partition slice of `data.img` to
   `build/esp/EFI/BOOT/DATA.IMG`. The on-ESP file contains *only* the
   partition (BPB + FATs + root dir + data clusters), not the leading
   `KERNEL_START_SECTOR + KERNEL_SECTORS` zero header.
2. At boot the UEFI loader allocates `DATA_IMG_MAX_SIZE` (16 MiB today) of
   `EfiLoaderData` pages, reads `DATA.IMG` into them via the UEFI Simple
   File Protocol, and writes `(base, size)` to `VBE_INFO` at
   `VBE_RAMDISK_BASE_OFF` / `VBE_RAMDISK_SIZE_OFF`. Missing or oversize
   file: fields stay zero, kernel falls back to ATA PIO.
3. Early in `kmain` (before `fat16_init`) the kernel calls `ramdisk_init`,
   which reads those fields and calls `ramdisk_register(base, FAT16_PART_LBA, sectors)`.
4. Every `ata_read_sectors` / `ata_write_sectors` first calls
   `ramdisk_intercept_read` / `_write`. If the LBA range lies inside the
   registered window the request is satisfied with a `rep movsb` and the
   function returns success without touching the IDE ports. LBAs outside
   the window fall through to the legacy PIO path - this preserves
   correctness on QEMU's `if=ide` data disk and any future real disk.

The kernel's view is identical in both cases: the same `fat16_init`,
the same root cache, the same explorer. There is no per-callsite branch
on "are we on real HW" - the indirection lives in one place.

## Boundary semantics

The interceptor returns one of three values:

| Return | Meaning                                       | Caller action       |
| ------ | --------------------------------------------- | ------------------- |
| `1`    | Request fully inside the registered window    | Done, return OK     |
| `0`    | Request fully outside the window              | Fall through to ATA |
| `-1`   | Request straddles the window boundary         | Treat as I/O error  |

A "partial overlap" should never happen at runtime: `fat16.asm` only ever
addresses LBAs in `[FAT16_PART_LBA, FAT16_PART_LBA + partition_sectors)`,
which is exactly the registered window. The `-1` path exists to catch
future callers that accidentally cross the boundary.

## Persistence

Writes hit RAM only. They are *not* written back to `DATA.IMG` on the boot
USB - sessions reset on reboot. This matches QEMU's behavior when running
without `-snapshot=off`, and it avoids needing an NVMe/AHCI/USB-MSC writer
in the kernel.

To make a change persistent: edit the source that build_uefi.ps1 bakes into
the image (e.g. add new dir entries in the build script) and rebuild.

## Adding files to the image

Files are seeded by `build_uefi.ps1`'s `Write-DirEntry` / `Write-FileData`
helpers around the existing `README.TXT` / `HELLO.TXT` / `BOOTANIM.NBA`
calls. The same data ends up in both `build/data.img` (QEMU IDE) and
`build/esp/EFI/BOOT/DATA.IMG` (real HW ramdisk) because the latter is a
slice of the former.

## Raising the size cap

If the partition grows past `DATA_IMG_MAX_SIZE` (16 MiB):

1. Bump `DATA_IMG_MAX_SIZE` in `src/include/boot_memory.inc`.
2. Bump `$dataImgMax` in `scripts/build/build_uefi.ps1`.
3. Confirm the boot USB has the extra free space.

The loader's `AllocatePages` request scales automatically from the constant.

## Caveats

- BIOS boot (`build_bios.ps1`, `src/boot/stage2.asm`) does not load
  `DATA.IMG` today. BIOS QEMU still works because it uses the IDE drive
  attached by `scripts/run/run_bios.ps1`. Bringing the ramdisk path to
  BIOS would mean reading `DATA.IMG` from the same FAT partition Stage 2
  already parses; deferred until needed.
- The registered region must be a single contiguous physical range. UEFI's
  `AllocatePages` provides this. Splitting across multiple ranges would
  require extending `ramdisk_register` to a table.
- Future RAM-only volumes (e.g. `/tmp`) can reuse the same
  `ramdisk_register` API by passing a different `lba_base`, provided the
  filesystem driver is taught to use that base.
