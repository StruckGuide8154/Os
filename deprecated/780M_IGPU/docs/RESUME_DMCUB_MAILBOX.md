# Resume: AMD DCN 3.1.4 / DMCUB Mailbox Bring-Up

## 2026-05-25 22:40 Linux CW4/VRAM mailbox fix

Latest hardware still showed `DMUB cmd stat=00000005`, `r1=00000000`,
`w1=00000040`: WPTR reached DMCUB, but firmware did not consume the command.

Rechecked upstream Linux AMDGPU DMUB:

- `dmub_srv_fb_cmd_execute()` flushes commands from framebuffer memory before
  advancing `DMCUB_INBOX1_WPTR`.
- Linux maps `DMUB_WINDOW_4_MAILBOX` through DMCUB CW4, then uses DMCUB
  internal mailbox addresses:
  - `INBOX1_BASE = 0x64000000`
  - `OUTBOX1_BASE = 0x64002000`
  - `INBOX1_SIZE = OUTBOX1_SIZE = 0x2000`

Patch applied in `src/kernel/drivers/amd_dcn.asm`:

- Mailbox backing moved from static low kernel RAM to VRAM just after the
  visible GOP framebuffer.
- The VRAM mailbox is mapped through the CPU UC alias.
- DMCUB CW4 is programmed with the translated mailbox FB/GPU address.
- INBOX1/OUTBOX1 now use the Linux CW4 base addresses instead of low physical
  addresses like `0023A000`.
- Ring status bit `0x10` means CW4 programming was written.

Validation passed:

- `scripts\build\build_uefi.ps1`
- `scripts\test\test_source_guards.ps1`
- `scripts\test\test_smoke_uefi.ps1`

Fresh build copied to `E:\` at 22:40:

- `E:\EFI\BOOT\KERNEL.BIN` size `1520740`
- `E:\EFI\BOOT\BOOTX64.EFI` size `66560`
- `E:\EFI\BOOT\APPS.BIN` size `1135752`
- `E:\EFI\BOOT\DATA.IMG` size `8355840`
- `E:\data.img` size `10485760`

Next boot should show `DMUB ring inFb=64000000 outFb=64002000`,
`inb1 size=00002000`, `outb1 size=00002000`, and ideally
`DMUB cmd stat=00000003`. If it still shows `00000005`, move to the fuller
Linux idle/IPS/PMFW exit path and shared-state signals.

## 2026-05-25 22:25 Continuation

The latest hardware photo showed the prior ring-command timeout case:

- `DMUB cmd stat=00000005`
- `w1=00000040`

So the command was queued but not consumed. The current build now sends
`DMUB_GPINT__IPS_DEBUG_WAKE` before the unchanged OUTBOX1_ENABLE ring command:

- wake request `0x10890000`
- wake ack target `0x00890000`
- command q0 remains `0000000104000047`

Build, source guards, and UEFI smoke passed. Fresh files were copied to
`E:\EFI\BOOT\*` and `E:\data.img`.

After the user asked to "copy to e:/", the same current build was recopied and
verified on `E:\`:

- `BOOTX64.EFI` size `66560`
- `KERNEL.BIN` size `1528932`
- `APPS.BIN` size `1135746`
- `DATA.IMG` size `8355840`
- root `data.img` size `10485760`

No guarantee was given that the hardware will boot successfully; the next boot
is a diagnostic wake-probe build. Good signs would be `gpStat=00000003` for the
IPS debug wake and `cmd stat=00000003` for DMCUB consuming the queued ring
command.

Next photo should capture:

- `DMUB ring inFb=... outFb=... gpStat=... gpReq=... gpResp=...`
- `DMUB gp2 dataOut=... polls=... t0=... t1=...`
- `DMUB cmd stat=... r0=... w0=... r1=... w1=...`
- `DMUB cmd q0=... q1=... t0=... t1=...`

If `gpStat=00000005` and `cmd stat=00000005`, simple GPINT wake was not enough;
next step is fuller Linux idle/IPS exit or PMFW/shared-state wake, not
brightness writes.

Date: 2026-05-25
Repo: `C:\Users\user\Documents\new`
Boot USB / ESP target: `E:\`

## Goal

Get AMD open-source Linux DCN 3.1.4 / DMCUB mailbox bring-up working on real hardware for the Ryzen/Radeon 780M-style iGPU path in GritOS.

## Current Build Copied To E:

Fresh UEFI build was copied to `E:\` after the 2026-05-25 21:58 update:

- `E:\EFI\BOOT\BOOTX64.EFI`
- `E:\EFI\BOOT\KERNEL.BIN`
- `E:\EFI\BOOT\APPS.BIN`
- `E:\EFI\BOOT\DATA.IMG`
- `E:\data.img`

Build source output was:

- `C:\Users\user\Documents\new\build\esp\EFI\BOOT\`

Verification already run:

- `powershell -NoProfile -File scripts\build\build_uefi.ps1`
- `powershell -NoProfile -File scripts\test\test_source_guards.ps1`
- `powershell -NoProfile -File scripts\test\test_smoke_uefi.ps1`

All passed. Final UEFI build had no NASM warnings.

## Latest Patch After User Photo

The user photo after the mailbox-write build showed the good part of the
experiment succeeded:

- `DMUB inb1 base=0023A000 size=00001000 rptr=00000000 wptr=00000000`
- `DMUB outb1 base=0023B000 size=00001000 rptr=00000000 wptr=00000000`
- `DMUB gpint in=10010000 ...`

Interpretation:

- The computed mailbox base translation and register writes landed.
- The GPINT request did not acknowledge during the previous raw CPU-spin poll.
- Linux confirms the ack condition is still correct: after writing
  `0x10010000`, ack is `0x00010000` because the status nibble clears.

Patch applied first:

- `amd_dcn_dmub_gpint_get_fw_version` now waits up to 50 PIT ticks instead of
  a tiny CPU loop.
- New status bit: `AMD_DMUB_GPINT_STATUS_TIMEOUT = 0x4`.
- The overlay now prints `DMUB gp2 dataOut=... polls=... t0=... t1=...`.

That timeout-only patch was superseded after checking Linux. Linux shows GPINT
is correct but is normally wrapped by `dc_wake_and_execute_gpint()`, which exits
DMUB idle/IPS before sending. So blindly booting a GPINT-only test is not useful.

Current patch:

- `amd_dcn_probe` no longer auto-sends GPINT.
- It still programs INBOX1/OUTBOX1 to the static 4KB+4KB rings.
- It now sends one Linux-style 64-byte inbox command:
  - `DMUB_CMD__OUTBOX1_ENABLE`
  - header dword `0x04000047` (`type=71`, `payload_bytes=4`)
  - payload dword `enable=1`
- It flushes pending command writes the same way Linux does: read back the
  queued 64-byte command before advancing `DMCUB_INBOX1_WPTR`.
- It advances `INBOX1_WPTR` to `0x40` and waits up to 50 PIT ticks for
  `INBOX1_RPTR` to advance to `0x40`.
- New overlay lines:
  - `DMUB cmd stat=... r0=... w0=... r1=... w1=...`
  - `DMUB cmd q0=... q1=... t0=... t1=...`

Next photo should focus on:

- `DMUB ring inFb=... outFb=... gpStat=... gpReq=... gpResp=...`
- `DMUB cmd stat=... r0=... w0=... r1=... w1=...`
- `DMUB cmd q0=... q1=... t0=... t1=...`
- `DMUB inb1 ...`
- `DMUB outb1 ...`

Expected:

- `cmd stat=00000003` means sent and DMCUB advanced RPTR to `0x40`.
- `cmd stat=00000005` means sent but timed out; likely DMCUB idle/IPS wake is
  required before both GPINT and inbox commands.
- `q0` should be `0000000104000047`; `q1` should be zero.

## Important Real-Hardware Findings From Photo

The latest boot photo showed:

- `FBPERF wcPlanPAT=... armed=1 activated=1`
- `DMUB ok=1`
- `DMUB scratch0=2409472B`
- `DMUB bits=0000012B`
- `DMUB state=0000000F`
- `DMUB inb1 base=09E3F2CC size=05A3F2C8 rptr=3E936069 wptr=32D3696C`
- `DMUB outb1 base=95E4FB20 size=99A4FB24 rptr=A2946984 wptr=AED46980`
- `DMUB gpint in=977EDC23 out=9B3EDC27 iflt=0DE4FBB0 dflt=81A4FBB4 uflt=AC4E4EB3`

Interpretation before the new patch:

- DMCUB firmware is alive and mailbox-ready bit is set.
- `state=0x0F` means enabled, not reset, mailbox bit, DAL firmware.
- Inbox/outbox registers were non-zero but not sane. Sizes/pointers looked like garbage-pattern values, not clean 4KB ring state.
- The previous checkout did not actually contain the ring write code implied by the photo; only read-only DMCUB register snapshots existed.

## Linux References Used

Official Linux source facts checked:

- `dcn_3_1_4_offset.h`
- `dmub_dcn31.c`
- `dmub_cmd.h`

Key offsets / behavior:

- DCN 3.1.4 uses `DCN_BASE__INST0_SEG2 = 0x34C0`.
- Register byte offset is `(0x34C0 + reg) * 4`.
- `regDMCUB_INBOX1_BASE_ADDRESS = 0x01d4` -> byte `0xDA50`.
- `regDMCUB_INBOX1_SIZE = 0x01d5` -> byte `0xDA54`.
- `regDMCUB_INBOX1_WPTR = 0x01d6` -> byte `0xDA58`.
- `regDMCUB_INBOX1_RPTR = 0x01d7` -> byte `0xDA5C`.
- `regDMCUB_OUTBOX1_BASE_ADDRESS = 0x01dc` -> byte `0xDA70`.
- `regDMCUB_OUTBOX1_SIZE = 0x01dd` -> byte `0xDA74`.
- `regDMCUB_OUTBOX1_WPTR = 0x01de` -> byte `0xDA78`.
- `regDMCUB_OUTBOX1_RPTR = 0x01df` -> byte `0xDA7C`.
- `regDMCUB_GPINT_DATAIN1 = 0x01f8` -> byte `0xDAE0`.
- `regDMCUB_GPINT_DATAOUT = 0x01f9` -> byte `0xDAE4`.
- `regDMCUB_SCRATCH7 = 0x01ea` -> byte `0xDAA8`.
- `regDCN_VM_FB_LOCATION_BASE = 0x0475` -> byte `0xE4D4`.
- `regDCN_VM_FB_OFFSET = 0x0477` -> byte `0xE4DC`.
- `DCN_VM_FB_LOCATION_BASE.FB_BASE` and `DCN_VM_FB_OFFSET.FB_OFFSET` are 24-bit fields shifted left by 24.
- Linux translation is `addr_out = sys_phys - fb_base + fb_offset`.
- `DMUB_GPINT__GET_FW_VERSION = 1`.
- GPINT request format is `status:4 command:12 param:16`, so GET_FW_VERSION request is `0x10010000`.
- DMCUB acknowledges GPINT by clearing the status nibble; expected ack value is `0x00010000`.
- GPINT FW version response is read from `DMCUB_SCRATCH7`.

## Code Changed

Main files:

- `C:\Users\user\Documents\new\src\kernel\drivers\amd_dcn.asm`
- `C:\Users\user\Documents\new\src\kernel\core\main.asm`

`amd_dcn.asm` now:

- Keeps the existing BAR0 UC alias at `AMD_DCN_UC_VBASE`.
- Adds a 7th private page-table page for a UC alias of static DMUB ring RAM.
- Adds static 8KB mailbox memory:
  - 4KB inbox
  - 4KB outbox
- Maps mailbox memory at `AMD_DCN_RING_UC_VBASE`.
- Computes:
  - decoded `fb_base = (DCN_VM_FB_LOCATION_BASE & 0x00FFFFFF) << 24`
  - decoded `fb_offset = (DCN_VM_FB_OFFSET & 0x00FFFFFF) << 24`
  - `ring_fb = ring_sys_phys - fb_base + fb_offset`
- Programs mailbox registers only if `ring_fb` fits in 32 bits.
- Runtime arm flag is currently enabled:
  - `amd_dcn_dmub_rings_arm: db 1`
- Writes:
  - `INBOX1_RPTR = 0`
  - `INBOX1_WPTR = 0`
  - `INBOX1_BASE = computed inbox FB addr`
  - `INBOX1_SIZE = 0x1000`
  - `OUTBOX1_RPTR = 0`
  - `OUTBOX1_WPTR = 0`
  - `OUTBOX1_BASE = computed outbox FB addr`
  - `OUTBOX1_SIZE = 0x1000`
- Sends GPINT GET_FW_VERSION by writing `0x10010000` to `DMCUB_GPINT_DATAIN1`.
- Polls for ack value `0x00010000`.
- Captures GPINT response from `SCRATCH7`.

`main.asm` now prints extra `=` boot diag lines:

- `DMUB fbBaseReg=... fbOffReg=... fbBase=... fbOff=...`
- `DMUB ring arm=... status=... sys=... fb=...`
- `DMUB ring inFb=... outFb=... gpStat=... gpReq=... gpResp=...`

## Expected Next Boot Overlay

After booting the copied `E:\` build, press `=`.

Important expected values:

- `DMUB ring arm=1`
- `status=00000007` means:
  - bit0 address OK
  - bit1 armed
  - bit2 mailbox registers written
- `status=00000008` means translated ring address did not fit 32-bit mailbox base; do not proceed until fixed.
- `DMUB inb1 size=00001000 rptr=00000000 wptr=00000000`
- `DMUB outb1 size=00001000 rptr=00000000 wptr=00000000`
- `DMUB state` should gain:
  - `0x20` inbox sane
  - `0x40` outbox sane
  - prior `0x0F` would become at least `0x6F` if both sane.
- `gpStat=00000003` means GPINT was sent and acked.
- `gpResp=` should become the firmware version from `SCRATCH7`.

## If Next Boot Fails Or Blanks

First quick rollback:

- In `src\kernel\drivers\amd_dcn.asm`, change:
  - `amd_dcn_dmub_rings_arm: db 1`
  - to `amd_dcn_dmub_rings_arm: db 0`
- Rebuild:
  - `powershell -NoProfile -File scripts\build\build_uefi.ps1`
- Copy output back to `E:\EFI\BOOT`.

This leaves GPINT and diagnostics but disables mailbox register programming.

## Next Engineering Step After Rings Are Sane

Do not jump straight into complex DMUB commands.

Next should be the smallest actual ring command after confirming:

- inbox/outbox base/size/rptr/wptr are sane
- `state` includes `INBOX_SANE | OUTBOX_SANE`
- GPINT GET_FW_VERSION acks

Then implement one minimal DMUB command packet in the inbox, update `INBOX1_WPTR`, and watch outbox/rptr behavior. Keep it gated and snapshot all ring header bytes before and after.
