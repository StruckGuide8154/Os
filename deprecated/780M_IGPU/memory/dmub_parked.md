---
name: dmub-parked
description: DMUB/DCN firmware bring-up paused 2026-05-25; project pivoted to GPU-accelerated rendering instead. Resume only for backlight/PSR.
metadata: 
  node_type: memory
  type: project
  originSessionId: 780f13ff-57d6-48cd-9fde-01cb68641e66
---

# DMUB bring-up - PARKED 2026-05-25

**Status:** Phase 1 (read-only blob parse) landed on `dev` but hardware
shows `FW stat=00000001` (file not found at runtime - fat16 lookup or
init-order bug, not investigated). Phase 2 (reset + load + release) not
started.

**Why parked:** User clarified the real goal is "iGPU rendering stuff,"
not panel backlight control. DMCUB does not draw pixels - it's a
power/PSR/backlight microcontroller. Even a fully working DMUB mailbox
would not move us closer to hardware-accelerated rendering. The GFX
block (GC 11.5 on Strix) is a separate engine with its own firmware
(CP_ME, CP_MEC, RLC, MES, SDMA) and PSP front-door.

**Why:** Continuing DMUB would be 1-2 weeks of hardware iteration for a
side quest. Pivoting to either (a) faster CPU rendering paths or
(b) GFX bring-up is the better use of time.

**How to apply:** If a future task asks about DMUB, backlight, PSR,
panel power, or hotplug - this work is the right starting point and
the notes below are accurate. For anything 3D / compute / VCN - DMUB
is irrelevant; this file does not apply.

## State on disk (2026-05-25)
- Latest commit `334e84f` (DMUB: ship DCN3.5/3.1.4 firmware + read-only
  blob parser). Branch `dev`, not merged to master.
- `assets/firmware/DCN35DMC.BIN` (522KB) and `DCN314.BIN` (350KB)
  mirrored from linux-firmware; packaged into `data.img` by
  `build_uefi.ps1` (FAT bumped to 12MB).
- `src/kernel/drivers/amd_dcn_fw.asm` parses the dmcub_firmware_header
  + scans for `dmub_fw_meta_info` magic. Called from `=` overlay.
- `src/kernel/drivers/amd_dcn.asm` has CW4 mailbox at VRAM
  `0x64000000/0x64002000`, 8KB rings. Last hardware photo:
  `cmd stat=00000005` (sent + timeout - firmware in deep IPS, won't
  consume inbox commands).

## What was learned (keep, may apply elsewhere)
- DCN 3.5 on Strix Point uses DCN 3.1.4-ish register layout but
  CW6 register offsets differ - our 3.1.4 offsets returned junk
  (`top=3C09476B` etc., should be `top=...80000000` if mapped).
- BAR0 needs UC PT alias to MMIO-poke DMCUB; we have an 8MB UC window.
- DMCUB boot_status bits in `SCRATCH0`: `0x12B` includes bit3 =
  `RESTORE_REQUIRED` (deep IPS). Driver must run IPS-exit handshake
  via shared_state (CW6) before the firmware will consume the inbox.
- `dmub_srv_fb_cmd_execute`: write cmd → read back to flush posted
  writes → advance `INBOX1_WPTR`.

## Mirrored Linux references (still on disk)
`C:/tmp/dmub-src/`:
- `dmub_cmd.h`, `dmub_cmd_latest.h` (structs, command IDs)
- `dmub_dcn31.c`, `dmub_dcn314.c`, `dmub_dcn31.h` (host driver)
- `dmub_srv.c`, `dmub_srv.h` (driver API + meta parser)
- `dcn_3_1_4_offset.h`, `dcn_3_1_4_sh_mask.h` (register offsets)
- `dc/dc_dmub_srv.c` (THE reference for `exit_low_power_state` /
  IPS-restore handshake)
- `amdgpu_dm.c`, `amdgpu_ucode.h` (firmware loader top-level)

## To resume
1. Debug why `amd_dcn_fw_probe` reports `FW stat=00000001` despite
   `DCN35DMC.BIN` being in DATA.IMG. Most likely: fat16 not init'd
   when probe runs, or root-cache scan misses the entry. Add a status
   bit `0x40` set on probe entry to distinguish "didn't run" from
   "ran, fat16 returned 0 files."
2. After Phase 1 reports `stat=00000026`, implement Phase 2 per the
   step list in [[dmub-phase2-plan]] (preserved below).

## Phase 2 plan (preserved from old notes)
After good Phase 1, mirror `dmub_dcn31_setup_windows` +
`dmub_dcn31_reset_release`:
1. Allocate ~1MB GPU-visible work region above visible GOP FB.
2. Window layout: CW0=inst_const(509KB) CW1=stack(64KB) CW2=bss(0)
   CW3=data(81KB) CW4=mailbox(16KB, already done) CW5=trace(64KB)
   CW6=fw_state(1KB) CW7=scratch.
3. `DMCUB_CNTL2.SOFT_RESET=1`, then clear. Poke `DMCUB_SEC_CNTL`.
4. Copy `inst_const` (`ucode_off + 0x100`, `0x7f5a0` bytes) into CW0
   via UC alias.
5. Program CW0-CW7 registers per `dcn_3_1_4_offset.h` indices
   0x0193-0x01c4 (formula `(SEG2_base=0x34C0 + idx) * 4`). Verify
   offsets against DCN 3.5 header if available.
6. Release reset. Poll `SCRATCH0` up to 500ms for
   `DAL_FW | MAILBOX_READY | HW_POWER_INIT_DONE`.
7. Send `OUTBOX1_ENABLE` through existing mailbox path.

Gate the whole thing behind `amd_dcn_dmub_fw_reload_arm: db 0` so a
bad build doesn't blank the panel - flip to 1 only after diag looks
clean.

## DCN 3.5 expected meta values (from blob parse)
- inst_const_bytes = 0x7f6a0 (509KB)
- bss_data_bytes   = 0
- fw_region_size   = 0x146c0 (81KB)
- trace_buf_size   = 0x10010 (64KB)
- shared_state_size= 0x400 (4 features × 256B)
- fw_version       = 0x9004700
- feature_bits     = 0x5 (shared_state_link_detection +
                          cursor_offload_v1_support)
