# DMUB mailbox resume - 2026-05-25 22:25

## 2026-05-25 22:40 Linux CW4/VRAM mailbox fix

The user's latest photo still showed failure:

- `DMUB cmd stat=00000005`
- `r1=00000000`
- `w1=00000040`

So CPU writes and `INBOX1_WPTR=0x40` reached the DMCUB register block, but
firmware still did not consume the command.

Rechecked upstream Linux AMDGPU DMUB code:

- `dmub_srv_fb_cmd_execute()` flushes queued commands from framebuffer memory,
  then advances `DMCUB_INBOX1_WPTR`.
- Linux initializes the mailbox as `DMUB_WINDOW_4_MAILBOX`, maps that memory
  into DMCUB CW4, and sets:
  - `DMCUB_REGION3_CW4_BASE_ADDRESS = 0x64000000`
  - `DMCUB_REGION3_CW4_TOP_ADDRESS = 0x64004000 | enable`
  - `DMCUB_INBOX1_BASE_ADDRESS = 0x64000000`
  - `DMCUB_OUTBOX1_BASE_ADDRESS = 0x64002000`
  - ring size `0x2000` per ring, matching Linux `DMUB_RB_SIZE`

Patch now applied in `src/kernel/drivers/amd_dcn.asm`:

- DMUB mailbox backing moved from static low kernel RAM to VRAM just after the
  visible GOP framebuffer.
- That VRAM mailbox is mapped through the existing CPU UC alias.
- DMCUB CW4 is programmed to translate the mailbox FB/GPU address.
- INBOX1/OUTBOX1 now use the Linux CW4 DMCUB addresses instead of low physical
  addresses like `0023A000`.
- Ring status now includes `0x10` when CW4 programming was written.

Fresh build copied to `E:\`:

- `E:\EFI\BOOT\BOOTX64.EFI` size `66560`, timestamp `2026-05-25 22:39:50`
- `E:\EFI\BOOT\KERNEL.BIN` size `1520740`, timestamp `2026-05-25 22:40:32`
- `E:\EFI\BOOT\APPS.BIN` size `1135752`, timestamp `2026-05-25 22:40:32`
- `E:\EFI\BOOT\DATA.IMG` size `8355840`, timestamp `2026-05-25 22:40:32`
- `E:\data.img` size `10485760`, timestamp `2026-05-25 22:40:32`

Validation passed:

- `powershell.exe -ExecutionPolicy Bypass -File scripts\build\build_uefi.ps1`
- `powershell.exe -ExecutionPolicy Bypass -File scripts\test\test_source_guards.ps1`
- `powershell.exe -ExecutionPolicy Bypass -File scripts\test\test_smoke_uefi.ps1`

Next boot should show:

- `DMUB ring ... status=00000017` in the normal programmed case
  (`addr_ok|armed|written|cw4`).
- `DMUB ring inFb=64000000 outFb=64002000`
- `DMUB inb1 base=64000000 size=00002000 ...`
- `DMUB outb1 base=64002000 size=00002000 ...`
- Good command result is still `DMUB cmd stat=00000003` and `r1=00000040`.

If this still times out, the mailbox backing/window is no longer the likely
issue; proceed to the fuller Linux idle/IPS/PMFW exit path and shared-state
signals, not brightness writes.

## Latest update from Codex resume

The user's 2026-05-25 22:19 hardware photo showed the expected timeout case
from the prior build:

- `DMUB cmd stat=00000005`
- `w1=00000040`

Interpretation: the OUTBOX1_ENABLE command was queued (`WPTR=0x40`) but DMCUB
did not advance `RPTR`, so the inbox path still needs a wake/idle-exit step
before commands are consumed.

Patch now applied in `src/kernel/drivers/amd_dcn.asm`:

- After `amd_dcn_dmub_prepare_mailbox`, call `amd_dcn_dmub_gpint_ips_debug_wake`.
- This sends `DMUB_GPINT__IPS_DEBUG_WAKE` (`command=137`) through DATAIN1:
  - request `0x10890000`
  - expected ack `0x00890000`
- The existing benign inbox command remains unchanged:
  - `DMUB_CMD__OUTBOX1_ENABLE`
  - q0 should still be `0000000104000047`

Fresh build has been copied to:

- `E:\EFI\BOOT\BOOTX64.EFI`
- `E:\EFI\BOOT\KERNEL.BIN`
- `E:\EFI\BOOT\APPS.BIN`
- `E:\EFI\BOOT\DATA.IMG`
- `E:\data.img`

Validation passed after this patch:

- `powershell.exe -ExecutionPolicy Bypass -File scripts\build\build_uefi.ps1`
- `powershell.exe -ExecutionPolicy Bypass -File scripts\test\test_source_guards.ps1`
- `powershell.exe -ExecutionPolicy Bypass -File scripts\test\test_smoke_uefi.ps1`

User asked to copy again after validation; the same current build was recopied
to `E:\` and verified present there:

- `E:\EFI\BOOT\BOOTX64.EFI` size `66560`
- `E:\EFI\BOOT\KERNEL.BIN` size `1528932`
- `E:\EFI\BOOT\APPS.BIN` size `1135746`
- `E:\EFI\BOOT\DATA.IMG` size `8355840`
- `E:\data.img` size `10485760`

Important: no promise was made that the hardware boot will work. The honest
expectation is that this build tests the most likely next missing step: DMCUB
IPS/idle wake before the mailbox ring command. If wake succeeds, `gpStat`
should become `00000003`; if the ring command is consumed, `cmd stat` should
become `00000003`.

Next hardware boot: press `=` and photograph these lines:

- `DMUB ring inFb=... outFb=... gpStat=... gpReq=... gpResp=...`
- `DMUB gp2 dataOut=... polls=... t0=... t1=...`
- `DMUB cmd stat=... r0=... w0=... r1=... w1=...`
- `DMUB cmd q0=... q1=... t0=... t1=...`
- `DMUB inb1 base=... size=... rptr=... wptr=...`
- `DMUB outb1 base=... size=... rptr=... wptr=...`
- `DMUB gpint in=... out=... iflt=... dflt=... uflt=...`

Expected useful cases:

- `gpReq=10890000` and `gpStat=00000003`: IPS debug wake acked.
- `cmd stat=00000003`: wake was enough; DMCUB consumed the ring command.
- `gpStat=00000005` and `cmd stat=00000005`: simple GPINT wake did not work;
  next step is not brightness writes, it is implementing the fuller Linux
  idle/IPS exit path or finding the PMFW/shared-state gate.

Do not start brightness writes yet.

Repo: `C:\Users\user\Documents\new`
Boot USB / ESP: `E:\`
Target: Acer ANV16 / AMD Strix Point iGPU, DCN 3.5-ish block, using DCN3.1.4 DMCUB register offsets for current probe.

## Current state

The latest correct build has been copied to:

- `E:\EFI\BOOT\BOOTX64.EFI`
- `E:\EFI\BOOT\KERNEL.BIN`
- `E:\EFI\BOOT\APPS.BIN`
- `E:\EFI\BOOT\DATA.IMG`
- `E:\data.img`

Validation already run after the final patch:

- `powershell.exe -ExecutionPolicy Bypass -File scripts\build\build_uefi.ps1`
- `powershell.exe -ExecutionPolicy Bypass -File scripts\test\test_source_guards.ps1`
- `powershell.exe -ExecutionPolicy Bypass -File scripts\test\test_smoke_uefi.ps1`

All passed. Final UEFI build had no NASM warnings.

## What the last hardware photo proved

Before this final patch, hardware boot showed:

- DMUB/DMCUB registers are readable through the BAR0 UC alias.
- `DMUB scratch0=2409472B`
- `DMUB bits=0000012B`
- DMCUB is enabled, not reset, DAL FW bit set, mailbox-ready bit set.
- Our mailbox register programming landed:
  - `DMUB inb1 base=0023A000 size=00001000 rptr=00000000 wptr=00000000`
  - `DMUB outb1 base=0023B000 size=00001000 rptr=00000000 wptr=00000000`
- GPINT write stayed as `gpint in=10010000`, so GET_FW_VERSION did not ack in that build.

## Linux driver conclusion

Checked local Linux AMDGPU DMUB sources in `C:\tmp\dmub-src` and upstream codebrowser.

Facts:

- GPINT request packing was correct:
  - `status:4 | command_code:12 | param:16`
  - `GET_FW_VERSION` request = `0x10010000`
  - ack should become `0x00010000` after firmware clears status nibble.
- Linux's direct GPINT wait is microsecond-scale, usually 30us from DC paths.
- Linux wraps GPINT through `dc_wake_and_execute_gpint()`, which exits DMUB idle/IPS first.
- Therefore a GPINT-only next boot is not useful; if GPINT ignores DATAIN1, the likely missing piece is idle/IPS wake, not timeout length.
- Linux ring commands are 64-byte entries. It writes command bytes, reads the queued command back to flush posted writes, then advances `DMCUB_INBOX1_WPTR`.

## Final code change

Main files changed:

- `src/kernel/drivers/amd_dcn.asm`
- `src/kernel/core/main.asm`

`amd_dcn_probe` now:

- Keeps BAR0 mapped through private 8MB UC alias.
- Programs static 4KB INBOX1 and 4KB OUTBOX1 rings.
- No longer auto-sends GPINT.
- Sends one Linux-style inbox ring command:
  - `DMUB_CMD__OUTBOX1_ENABLE`
  - header dword `0x04000047` (`type=71`, `payload_bytes=4`)
  - payload dword `enable=1`
  - first qword should be `0000000104000047`
- Flushes command writes by reading back the 64-byte command, matching Linux `dmub_rb_flush_pending`.
- Advances `INBOX1_WPTR` to `0x40`.
- Waits up to 50 PIT ticks for `INBOX1_RPTR` to advance to `0x40`.

New overlay lines:

- `DMUB cmd stat=... r0=... w0=... r1=... w1=...`
- `DMUB cmd q0=... q1=... t0=... t1=...`

Command status bits:

- `0x1` sent
- `0x2` RPTR advanced to `0x40`
- `0x4` timeout
- `0x8` ring busy before sending

Expected good case:

- `DMUB cmd stat=00000003`
- `r0=00000000`
- `w0=00000000`
- `r1=00000040`
- `w1=00000040`
- `q0=0000000104000047`
- `q1=0000000000000000`

Timeout case:

- `DMUB cmd stat=00000005`
- Means command was queued but firmware did not advance RPTR. Next likely task is implement Linux's DMUB idle/IPS wake/restore path before GPINT or inbox commands.

Busy case:

- `DMUB cmd stat=00000008`
- Means RPTR/WPTR were nonzero before sending; do not overwrite live firmware queue. Need capture those values and decide whether to preserve firmware rings instead of replacing them.

## What to do after reboot

Boot GritOS from the updated USB/ESP, press `=`, photograph/paste these lines:

- `DMUB ring arm=... status=... sys=... fb=...`
- `DMUB ring inFb=... outFb=...`
- `DMUB cmd stat=... r0=... w0=... r1=... w1=...`
- `DMUB cmd q0=... q1=... t0=... t1=...`
- `DMUB inb1 base=... size=... rptr=... wptr=...`
- `DMUB outb1 base=... size=... rptr=... wptr=...`
- `DMUB gpint in=... out=... iflt=... dflt=... uflt=...`

Do not start brightness writes yet. First confirm the inbox ring command path is alive.

## Rollback if boot blanks or wedges

In `src/kernel/drivers/amd_dcn.asm`, set:

`amd_dcn_dmub_rings_arm: db 0`

Then rebuild with:

`powershell.exe -ExecutionPolicy Bypass -File scripts\build\build_uefi.ps1`

Copy `build\esp\EFI\BOOT\*` back to `E:\EFI\BOOT`.
