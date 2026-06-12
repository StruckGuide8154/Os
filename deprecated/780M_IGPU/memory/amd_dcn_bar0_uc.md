# AMD DCN BAR0 UC alias + ACPI EC dump (2026-05-25)

Hardware: Acer Nitro V16 AI (ANV16-42), Strix Point, Radeon 890M.
AMD display device: PCI bus 0x64 dev 0 fn 0, ID 1002:1900, class 0x030000.
Framebuffer aperture (GOP): phys 0xF800000000, 1920×1200×32, pitch 8192.
DCN register BAR0: **phys 0xFA10000000** (separate from FB aperture).
PCI Command (live): 0x00100006 - MEM (bit1) + BM (bit2) already on, no enable needed.

## What landed in code

All read-only; safe to ship; lazy-evaluated when user presses `=`.

### Files added/modified
- **NEW** `src/kernel/drivers/amd_dcn.asm` - full DCN probe + private UC alias mapping.
- Modified `src/kernel/drivers/acpi_ec.asm` - added `acpi_ec_dump_zone` reading
  EC RAM 0x00..0x1F and 0x70..0x8F into static buffers.
- Modified `src/kernel/kernel_build.asm` - `%include` for `amd_dcn.asm`.
- Modified `src/kernel/core/main.asm`:
  - `real_boot_diag_dump` (the `=` handler) extended with DCN + EC sections.
  - Helper `diag_emit_hexbytes` added (writes ECX bytes from [RBX] as 2-char hex into [RDI]).
  - String labels (`s_dcn_*`, `s_ec_*`) added in `.data`.
  - Wraps the new code in `push rbx / push rcx` because `diag_emit_hexbytes` clobbers them.

### Private UC alias (the key piece)
`amd_dcn_probe` (called from `=`) installs its own PT chain so we can read BAR0
through a known-UC mapping. The kernel's "normal" page tables for the BAR
region are **broken** - different boots show pte = `0x100023`, `0x63`, etc.
mapping virt `0xFA10000000` to nonsense phys (0x100000, 0x0, ...). Don't rely
on them.

- PML4 slot: **0x180** (virt base `0xFFFFC00000000000`) - confirmed unused by
  kernel (memory note: only PML4[1] used for 512GB lower-half identity).
- Three 4KB pages in `.data`, page-aligned: `amd_dcn_uc_pdpt`, `amd_dcn_uc_pd`,
  `amd_dcn_uc_pt`.
- PT entries 0..3 each map a 4KB page of BAR0 with flags `0x1B`
  (P|RW|PWT|PCD|A) = strong UC.
- Hooked into live CR3's PML4[0x180] each call; idempotent (zero-init guarded
  by `amd_dcn_uc_init`).
- `INVLPG` for each mapped page after PT writes.

### Symbols exposed (used by `=` output)
```
amd_dcn_bar0           q  BAR0 phys after low-flag-strip
amd_dcn_mmio_ok        b  1 if direct reads via kernel mapping completed
amd_dcn_pte_value/lvl  q,d  Walker result for BAR0 virt
amd_dcn_pat_index      d  PAT index decoded from PTE
amd_dcn_cache_type     d  6=WB, 0=UC, 1=WC, 4=WT, 5=WP, 7=UC- (raw PAT type)
amd_dcn_reg0000..000C  d  Direct reads via (broken) kernel mapping
amd_dcn_cfg_base       d  Packed PCI cfg base for AMD device
amd_dcn_cmd_pre/post   d  PCI Command before/after MEM|BM enable
amd_dcn_uc_ok          b  1 if UC-alias reads completed
amd_dcn_uc_r0000       d  MMIO read at BAR0+0x0000 via UC alias
amd_dcn_uc_r0004       d  MMIO read at BAR0+0x0004 via UC alias
amd_dcn_uc_r0008       d  Labeled "r1000" in diag - actual offset BAR0+0x1000
amd_dcn_uc_r000C       d  Labeled "r3000" in diag - actual offset BAR0+0x3000
amd_dcn_uc_walk_pte/lvl q,d  Walker result for UC virt addr (sanity check)
acpi_ec_dump_ok        b  1 if first EC read succeeded
acpi_ec_dump_low       32 bytes EC[0x00..0x1F]
acpi_ec_dump_high      32 bytes EC[0x70..0x8F]
```

## Verified data from hardware (Acer ANV16, 2026-05-25)

### DCN UC alias works
```
DCN UC walkLvl=1 walkPte=000000FA1000001B
DCN UC ok=1 r0000=40001001 r0004=00000004 r1000=40002001 r3000=40004001
```
- `walkPte` is bit-perfect: phys=BAR0, flags 0x1B. Install succeeded.
- The four MMIO reads are **AMD SOC15 IP version headers**: pattern
  `0x4000_<idx>001` with the middle nibble stepping `1→2→4` per page proves
  we're sampling distinct IP blocks at distinct physical addresses, not
  kernel sequential bytes. Real MMIO confirmed.

### ACPI EC dump works, AC bit identified
EC RAM dump (0x00..0x1F) across plug/unplug/replug snapshots:
```
plugged   : 0100000106001E410F1E010000000000020000005E0AC00A00000000000000000F
unplugged : 0000000106001E410F1E0100000000000200000076 0AD90A000000000000000F
plugged   : 0100000106001E410F1E010000000000020000000000000000000000000000000F
```
- **EC offset 0x00 byte = AC adapter present** (`0x01`=plugged, `0x00`=battery).
  Clean 1-bit signal.
- Bytes 0x14..0x17 are two little-endian 16-bit values that drift over time
  (`5E0A`/`C00A` → `760A`/`D90A`) - likely temps×10 (26.5°C-ish range) or
  fan tachs. Some boots show them 0 (sensors gated in low-power state?).
- 0x70..0x8F mostly zeros, trailing `005C1E2D41` static (board identifier?).

### Things to NOT redo
- PCI Command write: `cmdPre==cmdPost==0x00100006` - MEM+BM already on.
  My `amd_dcn_probe` does an idempotent enable but it's a no-op.
- Walking PTEs via the existing kernel mapping for BAR0: results are random
  garbage across boots. **Always use the UC alias.**
- Reading temps from a guessed EC offset: take live before/after snapshots
  with a specific physical change, diff bytes.

## Status update 2026-05-25 (post-implementation)

- **Task A: DONE - VERIFIED ON HARDWARE.** `battery.asm` gained Layout D,
  signature-gated on EC[0x07]==0x41 && EC[0x04]==0x06, reads AC from
  EC[0x00] bit0. Drives existing `battery_state` so the taskbar plug/
  battery icon flips live on plug/unplug. Battery percent unknown on this
  EC, pinned to 100. **CRITICAL BUG FOUND ALONGSIDE:** `battery_init`
  was declared `extern` in main.asm but never called - entire battery
  driver had been silently uninitialized since it was written. Now called
  from kmain right after `mouse_init` (`call battery_init`). First boot
  with both fixes showed plug icon correctly.

- **DCN 3.5 brightness - strategic pivot.** AMDGPU
  `drm/amd/display/dc/resource/dcn35/dcn35_resource.c` uses
  `dcn31_panel_cntl_create`, and `dcn31_panel_cntl.c` sends
  `cmd.panel_cntl` to DMUB firmware. There is NO CPU-accessible
  BL_PWM_CNTL register on DCN 3.1+/3.5 - backlight is owned by the DMUB
  microcontroller. The 1MB BAR0 sweep (BL hunt) was therefore futile and
  is now disabled (`amd_dcn.asm` still maps 1MB UC for IP enumeration
  but BL_hunt loop is dead-coded by leaving the table populated; the
  diag emit path is commented out in main.asm `real_boot_diag_dump`).
  Without DMUB, the screen sits at UEFI default (max) regardless of
  what Windows had set - confirmed empirically: setting min in Windows
  shows min in Windows after reboot, but max in GritOS, then still min
  back in Windows. Preference is stored somewhere persistent, but
  application of it requires DMUB or an EC PWM path.

- **EC RAM dumps for brightness hunt.** `acpi_ec_dump_zone` extended
  to also dump EC[0x20..0x6F] (80 bytes) into `acpi_ec_dump_mid`,
  surfaced in `=` overlay as `EC[20..6F]=` line. Diffed across
  Windows-min vs Windows-max boots: only EC[0x2E] shifted (0x02 vs
  0x00) and EC[0x34] drifted thermally (varied 0x3A/0x3C/0x42). Four
  constant 0xFF bytes at 0x3E/0x41/0x44/0x47 are NOT brightness - they
  are stable across slider position. EC[0x2E] is a weak candidate;
  values too small to be a 0..100 brightness scalar - possibly an
  event flag or step counter. Next step: write-probe EC[0x2E] from a
  keybinding, OR dump+parse DSDT to find the firmware's _BCM path.

- **DCN IP table fingerprint (Task B, verified).** Strix Point Radeon
  890M IP enumeration shows DCN block header at BAR0+0x4000 with
  value `0x40003071` → DCN 3.0.71 encoding consistent with DCN 3.5.
  Most other pages are pattern `0x4000_X001` SOC15 IP headers. Five
  high-entropy values at 0x4B000..0x4F000 (FD9E25F3 etc) likely
  encrypted/scratch - ignore. Full table preserved in
  `amd_dcn_ip_table` (256 dwords, 1KB).
- **Task B: instrumentation in.** `amd_dcn.asm` UC mapping bumped from 4 to
  256 pages (1MB at BAR0). After existing reads, fills `amd_dcn_ip_table`
  (256 dwords - one per 4KB page). `=` overlay emits non-zero entries as
  `IP+xxxxx=hhhhhhhh`, 4/line, via serial. One boot → full IP map.
- **Task C: instrumentation in (same boot).** Also fills `amd_dcn_bl_table`:
  4096 dwords (16KB) at BAR0+0x40000 stride 4. Overlay emits entries in
  plausible PWM-duty range (1..0xFFFF) as `BL+xxxxx=hhhhhhhh`. Picked the
  0x40000 window because DCN3.x DIO/ABM blocks typically land in
  BAR0+0x30000..0x60000; widen if the dump shows nothing useful.
- Build clean, UEFI smoke green. Artifacts copied to E:/EFI/BOOT/.
- **Next boot on Acer ANV16:** press `=`, photograph klog. Look for
  `IP+...` lines (cross-ref soc15_ip_offset.h to find DCN aperture) and
  `BL+...` lines (any near-mid value is a PWM candidate to write next).

## What's next - Tasks A / B / C (everything needed to act fresh)

### Task A - Plumb EC AC-present bit into WM/taskbar
**Goal:** taskbar shows live AC status, updates within ~1 second of plug change.
**Risk:** very low - read-only EC polling, already proven safe.

Steps:
1. Add a periodic poller. Easiest hook: existing main loop tick in
   `src/kernel/core/main.asm` already does per-tick work - add a 50-tick
   (500ms) modulo branch calling a new `acpi_ec_poll_status` function.
2. In `src/kernel/drivers/acpi_ec.asm`, add `acpi_ec_poll_status`:
   - `mov cl, 0x00` ; `call acpi_ec_read` ; write to `byte [system_ac_present]`
   - Also try `mov cl, 0x10` for lid (untested - confirm by reading then
     closing lid briefly while watching the value)
   - Export `system_ac_present`, `system_lid_closed` as globals.
3. Hook display: in `src/kernel/gui/taskbar.asm` find the clock-rendering area,
   draw a tiny plug-icon if `system_ac_present` else battery-icon. Use existing
   `draw_string` for an initial text indicator (`[AC]`/`[BAT]`) - easier than
   bitmap art.
4. Optional: post a WM event (find existing event-post helper, e.g. how
   keyboard events get posted) when the bit changes, so apps can react.

Files: `acpi_ec.asm` (+~30 lines), `main.asm` (+~10 lines tick hook),
`taskbar.asm` (+~20 lines drawing). No new kernel modules needed.

### Task B - Fingerprint DCN HW version
**Goal:** know exactly which DCN revision this is (DCN 3.5 expected for Strix
Point) so Task C can pick the right brightness register offset without guessing.
**Risk:** low - more MMIO reads through the existing UC alias, no writes.

Useful reads (offsets are AMDGPU public, won't fault on Strix):
- `mmRCC_DEV0_EPF0_STRAP0` - strap register, contains chip ID.
- DCN IP-block headers at the apertures already partially sampled:
  - `r0000` = first block (NBIO usually)
  - `r1000` = second block
  - `r3000` = fourth block
  - Need to also read 0x2000, 0x4000..0x10000 in 0x1000 steps to enumerate
    all IP blocks. Each non-zero `0x4000_X001` is an IP block.
- `mmDCEFCLK_CNTL` and `mmDC_VERSION` registers - DCN-specific but offset
  varies. Easier: just enumerate IP headers.

Steps:
1. Extend `amd_dcn_uc_pt` to map more pages (currently 4 pages = 16KB; bump
   to 64 pages = 256KB to cover BAR0+0x00..0x40000).
2. Add a loop in `amd_dcn_probe` that reads dword at every 0x1000 offset from
   0..0x40000 into a buffer (256 entries × 4 bytes = 1KB).
3. Surface in `=`: a compact dump like "IPs at offsets: 0000=40001001
   1000=40002001 3000=40004001 5000=... 8000=...". Filter zero/0xFFFF.
4. Cross-reference the IP-version values against AMDGPU's
   `drivers/gpu/drm/amd/include/soc15_ip_offset.h` (online; user can paste a
   table back). Each `0x4000_<nibble>001` maps to a known IP (DCN, NBIO,
   OSSSYS, MP0, MP1, SMU, etc).
5. Once DCN block aperture is identified, read DCN's own version register
   (typically at DCN_aperture + 0x40 = `mmDC_BASE+DCE_VERSION` reg).

No writes anywhere.

### Task C - Brightness control via DCN PWM
**Goal:** brightness up/down keys actually dim/brighten the eDP backlight.
**Risk:** **medium** - first write to GPU MMIO. Wrong offset = display can
blank, gpu_hang, or stuck-on. Recovery = reboot.

Strategy (only attempt after B confirms DCN version):
1. Identify ABM (Adaptive Backlight Mgmt) or DMU block from B's enumeration.
2. The eDP backlight PWM duty-cycle register on DCN 3.x is in the DIO
   (Display I/O) block. Typical name: `mmBL1_PWM_USER_LEVEL` or
   `mmBL1_PWM_TARGET_ABM_LEVEL`. Offset depends on DCN version.
3. **Before writing:** read the current PWM register value. If it looks like
   a reasonable duty-cycle (0..0xFFFF range typically), we have the right reg.
4. Write a fractionally-changed value (e.g. current ± 10%). User reports
   whether screen brightness changed. If yes, scale to 100% steps from
   keyboard shortcut.
5. Wire a keyboard shortcut in `src/kernel/core/main.asm` `process_key` -
   e.g. F1/F2 for brightness down/up, OR re-purpose the unused brightness
   scancodes (0xE0,0x6A/0x6B on Acer).

**Pre-flight checklist before C:**
- [ ] Task B completed; DCN version known.
- [ ] PWM register identified by name and aperture+offset.
- [ ] Tested first as a READ in `=` output to confirm sensible value range.
- [ ] User aware that a bad write may require a reboot.

## Quick handoff cheat-sheet for fresh context

To pick up cold:
1. Read this file + `MEMORY.md`.
2. Read `src/kernel/drivers/amd_dcn.asm` (full driver, ~280 lines).
3. Read `acpi_ec_dump_zone` in `src/kernel/drivers/acpi_ec.asm`.
4. Read `real_boot_diag_dump` in `src/kernel/core/main.asm` (line ~1837).
5. Build: `powershell.exe -ExecutionPolicy Bypass -File scripts/build/build_uefi.ps1`
6. Smoke: `powershell.exe -ExecutionPolicy Bypass -File scripts/test/test_smoke_uefi.ps1`
7. Deploy: `cp build/esp/EFI/BOOT/{BOOTX64.EFI,KERNEL.BIN,APPS.BIN,DATA.IMG} E:/EFI/BOOT/`
8. User boots Acer ANV16, presses `=`, photos klog. Look for `DCN UC` and
   `EC[00..1F]` lines.

User collaboration ground rules: user drives boot/keyboard; we send code,
they send back log photos. EC test pattern (plug/unplug/plug) is the
preferred way to discover EC byte semantics.
