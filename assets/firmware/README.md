# DMCUB firmware blobs

These are the AMD DMCUB (Display MicroController Unit B) firmware images
from the upstream `linux-firmware` repository, mirrored verbatim. GritOS
loads them at boot to drive AMD GPU display features (panel control,
brightness, IPS power management, etc.).

Source: <https://gitlab.com/kernel-firmware/linux-firmware/-/tree/main/amdgpu>

License: redistributable per the linux-firmware license terms (see
upstream `WHENCE` file for the AMD ucode entry).

| File on FAT (8.3) | Original name              | Target hardware                  |
|-------------------|----------------------------|----------------------------------|
| DCN35DMC.BIN      | `dcn_3_5_dmcub.bin`        | DCN 3.5 - Strix Point, Phoenix2  |
| DCN314.BIN        | `dcn_3_1_4_dmcub.bin`      | DCN 3.1.4 - Phoenix1             |
| GC115RLC.BIN      | `gc_11_5_0_rlc.bin`        | GFX11.5 RLC-G - Strix Point      |
| GC115PFP.BIN      | `gc_11_5_0_pfp.bin`        | GFX11.5 CP PFP - Strix Point     |
| GC115ME.BIN       | `gc_11_5_0_me.bin`         | GFX11.5 CP ME - Strix Point      |
| GC115MEC.BIN      | `gc_11_5_0_mec.bin`        | GFX11.5 CP MEC - Strix Point     |

Layout (per `dmcub_firmware_header_v1_0` in amdgpu_ucode.h):
- 0x00..0x28: common firmware header (size, version, ucode offset, crc)
- 0x28..0x30: dmcub fields (inst_const_bytes, bss_data_bytes)
- `ucode_off..ucode_off+0x100`: PSP header (skip)
- After PSP: instruction-const region (firmware code + read-only data)
- Last 0x100 of inst_const: PSP footer (skip)
- 64-byte `dmub_fw_meta_info` lives in the last 16 bytes of the
  scannable region - search at `(size - 0x100 - i - 64)` for i in 0..16
- Magic = `0x444D5542` ("DMUB" little-endian)

Update by re-downloading from upstream when new ucode versions are
released. Do not modify in place.

## Status (2026-05-26)

- `DCN35DMC.BIN`, `DCN314.BIN`, `GC115RLC.BIN` are present.
- `GC115PFP.BIN`, `GC115ME.BIN`, `GC115MEC.BIN` are referenced by the
  Wave 3 Task L loader and by the build's FAT16 packing step, but the
  blobs themselves are NOT in-tree yet. Fetch the linux-firmware files
  `amdgpu/gc_11_5_0_{pfp,me,mec}.bin` and copy them in here as
  `GC115PFP.BIN`, `GC115ME.BIN`, `GC115MEC.BIN` (rename to 8.3 per the
  table above; build script consumes them by 8.3 name) before running
  a Task L build (`-GfxWave3L`).
- `gc_11_5_0_mes.bin` / `mes_kiq.bin` are Task M and not wired yet.
