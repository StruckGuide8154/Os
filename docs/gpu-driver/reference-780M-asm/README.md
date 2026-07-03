# AMD Phoenix 780M iGPU (DCN 3.5 / GFX11) — REFERENCE ASM (no longer deprecated)

> **Status (2026-06-23): un-deprecated, reclassified as REFERENCE.** This single-model
> asm bring-up is now the salvage reference for the active general AMD GPU driver effort.
> See `../TODO.md` for the live spec/plan. Do **not** resurrect this asm into the build
> (zero-asm + Track-8 ring-3 rules) — transliterate the *verified sequences* (SMN proxy,
> SMU mailbox, IP discovery) into GHL. The firmware blobs here are reused as-is.

## What this was

A native, from-scratch bring-up of the AMD Phoenix APU's integrated GPU
(Ryzen 7 7840U / 7840HS class, "Phoenix1", `gfx_11_0_3`, DCN 3.5). The goal
was full display + 3D acceleration without relying on UEFI GOP or external
firmware blobs beyond the AMD-signed microcontroller binaries.

Subsystems attempted:

- **DCN 3.5 display controller** - MMIO probe, BAR0 UC alias, PTE walk,
  DMUB (display microcontroller) mailbox bring-up to read-only diag.
- **GFX11 graphics pipeline** - SMU/MP1 handshake, GMC (memory controller),
  CP (command processor) ring scaffolding, PSP (platform security processor)
  firmware-load path, IMU (integrated microcontroller unit) autoload kick.
- **IP discovery** - parse the AMD IP-discovery binary out of VRAM to find
  MP0/MP1/GC/DCN/MMHUB base addresses without hardcoding.

## Status when retired

- Date retired: 2026-05-26
- Last working state:
  - DCN probe: BAR0 UC alias + PTE walk + register reads ran cleanly on real
    Phoenix HW. DMUB diag mailbox readable (cntl/scratch/inbox/outbox).
  - GFX11: scaffolding compiled and a Wave-3 path (PSP+RLC, CP PFP/ME/MEC
    load, IMU kick) was wired but never produced a successful CP ring NOP
    retire. PSP path on Phoenix was unresolved - MP0 SMN segment from Linux
    headers didn't match observed behaviour.
  - IP discovery: ramdisk fetch + dmub_fw_meta parse worked; live VRAM scan
    landed but never validated end-to-end.
- Ever shipped in a working build? **No** - only ran behind opt-in build
  flags (`-Gfx`, `-GfxWave3`, `-GfxWave3L`, `-GfxImuKick`, `-DiagLegacy`).
  Default builds never executed any of this code.

## Why retired

Two reasons:

1. **Too platform-specific.** Every line of this code targeted one APU
   family. Other AMD generations need different register layouts, firmware
   blobs, and SMU message sets. Other vendors (Intel, Nvidia, ARM Mali)
   share nothing.
2. **Pivot to widely-compatible interfaces only.** Grit will rely on
   UEFI GOP for the framebuffer (already working via `fbperf.asm` with WC
   mapping). Future acceleration, if any, will target portable abstractions
   (Vulkan-via-loader or compute-via-host) rather than per-vendor MMIO
   bring-up.

## What replaced it

Nothing - the feature is dropped. The UEFI GOP framebuffer + the WC-mapped
software compositor (`src/kernel/drivers/fbperf.asm`) cover everything the
active OS needs from the display side. Backlight control via DMUB inbox is
no longer pursued; if backlight is needed on Phoenix specifically, route
through ACPI EC scratch (see `src/kernel/drivers/acpi_ec.asm`) instead.

## Files preserved

Code:

| New path | Original path |
|---|---|
| `code/drivers/amd_dcn.asm` | `src/kernel/drivers/amd_dcn.asm` |
| `code/drivers/amd_dcn_fw.asm` | `src/kernel/drivers/amd_dcn_fw.asm` |
| `code/drivers/gpu/amd_gpu_mmio.asm` | `src/kernel/drivers/gpu/amd_gpu_mmio.asm` |
| `code/drivers/gpu/amd_smn.asm` | `src/kernel/drivers/gpu/amd_smn.asm` |
| `code/drivers/gpu/amd_smu.asm` | `src/kernel/drivers/gpu/amd_smu.asm` |
| `code/drivers/gpu/amd_gmc.asm` | `src/kernel/drivers/gpu/amd_gmc.asm` |
| `code/drivers/gpu/amd_cp_ring.asm` | `src/kernel/drivers/gpu/amd_cp_ring.asm` |
| `code/drivers/gpu/amd_psp.asm` | `src/kernel/drivers/gpu/amd_psp.asm` |
| `code/drivers/gpu/amd_psp_probe.asm` | `src/kernel/drivers/gpu/amd_psp_probe.asm` |
| `code/drivers/gpu/amd_psp_fwload.asm` | `src/kernel/drivers/gpu/amd_psp_fwload.asm` |
| `code/drivers/gpu/amd_ip_disc.asm` | `src/kernel/drivers/gpu/amd_ip_disc.asm` |
| `code/drivers/gpu/amd_imu.asm` | `src/kernel/drivers/gpu/amd_imu.asm` |
| `code/drivers/gpu/amd_gfx.asm` | `src/kernel/drivers/gpu/amd_gfx.asm` |
| `code/drivers/gpu/README.md` | `src/kernel/drivers/gpu/README.md` |
| `code/include/amdgpu_regs.inc` | `src/include/amdgpu_regs.inc` |
| `code/include/amdgpu_gfx.inc` | `src/include/amdgpu_gfx.inc` |
| `code/include/amdgpu_ppsmc.inc` | `src/include/amdgpu_ppsmc.inc` |

Tools and firmware:

| New path | Original path |
|---|---|
| `tools/build_shaders.ps1` | `tools/gpu/build_shaders.ps1` |
| `tools/fetch_phoenix_fw.sh` | `tools/gpu/fetch_phoenix_fw.sh` |
| `tools/pm4.py` | `tools/gpu/pm4.py` |
| `tools/test_pm4.py` | `tools/gpu/test_pm4.py` |
| `tools/shaders/` | `tools/gpu/shaders/` |
| `firmware/*.BIN` | `assets/firmware/*.BIN` (DCN35DMC, DCN314, GC115*, PHX*) |

Docs and notes:

| New path | Original path |
|---|---|
| `docs/gpu-bringup.md` | `docs/gpu-bringup.md` |
| `docs/gpu-bringup-verified.md` | `docs/gpu-bringup-verified.md` |
| `docs/RESUME_DMCUB_MAILBOX.md` | repo root |
| `docs/RESUME_DMCUB_MAILBOX_CURRENT.md` | repo root |

Memory files (auto-memory entries):

| New path | Original path |
|---|---|
| `memory/rendering_pivot.md` | `.claude/projects/.../memory/rendering_pivot.md` |
| `memory/dmub_parked.md` | (same) |
| `memory/gfx_phx_scaffolding.md` | (same) |
| `memory/feedback_mp1_base_verified.md` | (same) |
| `memory/amd_dcn_probe_prereq.md` | (same) |
| `memory/amd_dcn_bar0_uc.md` | (same) |

## Notes for future revisitors

If anyone resurrects this for Phoenix specifically:

- **MP1 SMN base on Strix is `0x03B10000`** - do NOT take this from Linux
  header tables, they're wrong for Strix/Phoenix. Confirmed by live probe.
- **The Phoenix MP0 path was the wall.** PSP bootloader handshake never
  resolved. NBIO SMN proxy was tried, retired as the wrong path. The
  IP-discovery reader (`amd_ip_disc.asm`) was meant to replace
  `amd_psp_probe.asm` but never validated.
- **`amd_dcn_probe` is a prerequisite for `gfx_bringup`.** It's what arms
  PCI MEM-decode + bus-master and sets up BAR0 UC alias. Without it every
  SMN read returns 0xFFFFFFFF.
- **DMUB owns backlight on DCN 3.1+/3.5.** There is no CPU-accessible
  BL_PWM register. Brightness must go through a DMUB packet (cmd.panel_cntl)
  or via ACPI EC scratch.
- **xHCI bulk IN short-packet completion code 13 is success.** Not related
  to GFX but burned half a session here - preserving it anyway.
- **WARNING: `gfx_bringup()` with `-GfxImuKick` can wedge the SoC.** It
  writes guessed IMU regs. Always cold-boot first if you re-enable this.

## main.asm residue

`src/kernel/core/main.asm` still contains the original DCN/DMUB diag-dump
block (~lines 2245-2872) and GFX11 bring-up diag block (~lines 2874+) as
inert source, wrapped in `%ifdef GRIT_DIAG_LEGACY` and
`%ifdef GRIT_GFX_BRINGUP`. Neither symbol is defined by any active build
configuration. Excising the source from main.asm is a follow-up cleanup
task - until then, do **not** add `-dGRIT_DIAG_LEGACY` or
`-dGRIT_GFX_BRINGUP` to any build command, or the dead code will try to
link against externs that no longer exist in the active tree.
