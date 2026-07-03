---
name: gfx-phx-scaffolding
description: "2026-05-26 - Phoenix (Ryzen 780M, gfx_11_0_3) GFX bring-up scaffolding landed. PSP-via-NBIO retired; IMU autoload + IP discovery scaffolds added; awaiting FW blobs."
metadata: 
  node_type: memory
  type: project
  originSessionId: 79ae4c4f-c0dd-4153-adfe-d9b732b3b453
---

Hardware: Ryzen 780M = Phoenix iGPU = GC 11.0.3 / MP 13.0.5 / NBIO 7.7 / DCN 3.1.4.
NOT Strix Point (which is 11.5.0). Earlier code targeted Strix; corrected this session.

Landed 2026-05-26:
- Retired `psp_probe_mp0` from `gfx_bringup` and dropped its 6-segment diag rows. NBIO SMN proxy isn't the Phoenix MP0 path; amdgpu uses direct BAR0 MMIO on APUs.
- New stage `D` (IP discovery scan, read-only) before SMU. `amd_ip_disc.asm` scans FB BAR for the `$IPD` signature and parses MP0/MP1/GC/MMHUB/DCN/IMU bases.
- New stage `M` (IMU autoload TOC builder, read-only). `amd_imu.asm` walks FAT16 root for `PHXxxx.BIN` aliases and builds a `psp_gfx_uc_info[]` TOC at `GPU_PSP_FW_STAGING_BASE`. Kick is gated behind `-DGRIT_GFX_IMU_KICK` and only fires when `missing==0`.
- PCI cmd reg now force-enables MEMORY+BUS_MASTER on the AMD iGPU during pci_gpu_scan, and prints `cmd=` on the `PCIAMD` line.
- Register defs added (PROVISIONAL - verify against gc_11_0_3_offset.h): `GFX_IMU_FW_GTS_LO/HI`, `GFX_IMU_CORE_CTRL`, `RLC_RLCS_BOOTLOAD_STATUS`, `CP_PFP/ME/MEC_IC_BASE_*`. See `src/include/amdgpu_regs.inc`.
- Build verified with and without `-Gfx`.

**Why:** Get GFX bring-up unblocked on actual hardware (780M). The Strix Point assumptions in the old code couldn't work.

**How to apply:** Before any further hardware work, confirm `IPDISC found=` on the boot overlay. If 0, the FB scan path is wrong and we need to read the discovery table from the stolen-system-memory region instead. If 1, the printed MP0/MP1/GC bases are ground truth for all future register addressing.

**State after 2026-05-26 expanded session:**
- 10 Phoenix firmware blobs pulled from kernel.org (linux-firmware.git) → `assets/firmware/PHX*.BIN`. PSP SOS is intentionally absent (Phoenix loads it via ABL/SBIOS, not via OS).
- Build script (`scripts/build/build_uefi.ps1`) auto-bundles all PHX*.BIN into DATA.IMG; data.img cap bumped 16→32 MiB.
- IMU kick (`imu_autoload_kick`) is real, not a stub. Writes `GFX_IMU_FW_GTS_LO/HI`, releases IMU reset via `GFX_IMU_CORE_CTRL`, polls `RLC_RLCS_BOOTLOAD_STATUS`. On success advances state to `GPU_STATE_CP_LOADED` so existing `cp_gfx_start_nop` can fire.
- gfx_bringup now has stages D (IP disc), H, I, J, M (IMU TOC build), N (IMU kick), P (CP unhalt + NOP).
- New build flag `-GfxImuKick` arms the IMU kick + CP unhalt. **Without the flag, no new MMIO writes happen** - only diag globals populate.
- IP discovery FB scan retains a `ip_disc_scan_vram` fallback using mmMM_INDEX(0x0)/mmMM_DATA(0x1) that walks 4 candidate VRAM tops (256/512/1024/2048 MiB).

**Boot order recommendation:**
1. Cold boot with `-Gfx` only. Confirm: `cmd=` shows `0006` or `0007`; `IPDISC found=` reports something; `IMU autoload n=6 miss=00000000 kick=0` (kick=0 = untouched).
2. If miss=0, reboot with `-Gfx -GfxImuKick`. If `kick=3` and CP `state=8` (`GPU_STATE_CP_RUNNING`), CP retired its first NOP - that's working GFX.
3. If kick=2 (timeout), the IMU register offsets in `amdgpu_regs.inc` are guessed wrong; decode from a Linux box's `dmesg | grep -E 'GFX_IMU|RLC.*bootload'` or from gc_11_0_3_offset.h before retrying.

**Why:** Real boot-test ammunition. The PHX FW blobs are in place, the autoload path compiles end-to-end, and we have a kill-switch (`-GfxImuKick`) so one bad assumption can't wedge a default build.

**Known guessed values** (verify before flipping `-GfxImuKick`):
- `mmGFX_IMU_FW_GTS_LO = 0x4111`, `HI = 0x4112`
- `mmGFX_IMU_CORE_CTRL = 0x40B6`
- `mmRLC_RLCS_BOOTLOAD_STATUS = 0x4E03`

See `tools/gpu/fetch_phoenix_fw.sh` if blobs ever need re-fetching from a different mirror.
