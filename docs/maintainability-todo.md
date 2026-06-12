# Maintainability TODOs

Status: **draft / working backlog**
Owner: @StruckGuide8154
Last measured: 2026-06-01 (commit `fe78edd`)
Scope: `src/` only - `deprecated/` is excluded.

This document tracks the work needed to move every sector and segment toward an
**Excellent** maintainability rating. It pairs a measured backlog (what is wrong
today) with a target spec (what "Excellent" means, including traceability) so the
two can be checked against each other.

Signals are the same ones the repo already tracks in
[`tools/complexity_dashboard.ps1`](../tools/complexity_dashboard.ps1):
file size (>700 lines is the project "large file" flag), magic-constant density
(`0x` literals ≥5 hex digits), TODO/STUB/FIXME count, and public-label/export
surface (`global`).

---

## 1. Rating model

| Rating | Meaning | Rough gate |
|---|---|---|
| 🟢 Excellent | meets the full spec in §4 | no file >700 lines; magic density low; 0 stray TODO/STUB; traceability complete |
| 🟢 Good | healthy, minor cleanup | no file >700 lines; a few magic constants |
| 🟡 Fair | one structural problem | a single oversized file *or* magic-heavy |
| 🟠 Watch | accumulating debt | mix of size + magic + TODO |
| 🔴 Heavy | needs decomposition | dominated by a multi-thousand-line monolith |

---

## 2. Sector backlog (subsystem level)

Measured 2026-06-01. `Largest` = biggest single file in the sector.
¹ **0 bare** magic literals: every `0x...` ≥5-digit value in these three sectors
is now either a named `equ` (in [`src/include/arch_regs.inc`](../src/include/arch_regs.inc),
[`src/include/net_driver.inc`](../src/include/net_driver.inc), or a documented
local `equ` in the PoC) or appears only inside an explanatory comment. Each
register/MSR/MMIO constant cites its spec section (§4.2). Promoted Good→Excellent
2026-06-01 (build verified green).
³ **Boot magic + TODO sweep 2026-06-03 (live UEFI loader + BIOS path).** Every
bare ≥5-hex-digit operand literal in the *active* loader (the 12
`uefi_loader_*.inc` files behind BOOTX64.EFI) and the BIOS path
(`mbr/stage2/a20/gdt/vesa/paging`) was replaced with a named constant defined in
a `src/include/` header - new `uefi_abi.inc` (PE/COFF, UEFI BootServices/GOP/SFS/
BlockIO offsets, FAT32 layout, EFI file OpenMode, KASLR PRNG, paging flag/size
bits) and `bios_boot.inc` (E820/SMAP/VBE2/EFER) - each value carrying a spec
citation (UEFI 2.10 / PE-COFF / FAT32 / Intel SDM §). **Every boot artifact
stayed byte-identical** (BOOTX64.EFI / mbr.bin / stage2.bin sha256 unchanged;
verified by `scripts/test/boot_parity.ps1`). The residual sector count (153,
down from 197) is now dominated by the out-of-scope `boot.asm`/`boot_uefi_*.inc`
orphan (85) plus the §4.2 *floor* in-scope: ~13 `equ`/`%define` definition lines,
~27 explanatory-comment occurrences, and 9 packed GDT-descriptor / GUID data
defs (each carrying a spec comment). **Zero bare in-code operand literals remain
in the in-scope boot files.** The 3 stray `TODO Phase 1b.*` markers in
`uefi_loader_storage_extents.inc` are cleared: 1b.2/1b.3 were already implemented
(checkboxes corrected), 1b.4 is a tracked issue (#21) referenced in-code. Not
promoted: `boot.asm` (2,339) and `uefi_loader.asm` (2,214 incl. includes) remain
oversized - boot-sensitive splits intentionally deferred.
² **Magic sweep (agents) 2026-06-01.** Bare `0x...` ≥5-digit literals in these two
sectors were replaced with descriptive `equ` constants (value copied byte-for-byte;
verified). The residual count is now ≈ the number of *distinct* named constants
(each `equ` definition line still holds its literal once - this is the §4.2 floor,
not debt). Per-file: notepad 40→13, paint 24→8, shell 8→2, launch 5→2,
state 9→8, terminal 7→5, media_viewer 23→21; diag probe 46→35. Builds green
(`build_uefi.ps1` + `build_probe.ps1`). Neither sector is promoted: both remain
🟠 Watch because the oversized-file blocker (media_viewer 1,805; probe 1,990) is
untouched - splitting those is boot-/runtime-sensitive manual work, intentionally
not fanned out to agents.

> **2026-06-10 update - the table below is stale on size/TODO columns.** The
> byte-identical split program (§3a) decomposed every >700-line monolith in
> `kernel/drivers`, `kernel/fs`, `kernel/gui`, `kernel/lib`, and `kernel/proc`
> except `syscall_dispatch_core.inc` (727 - single `syscall_entry` local-label
> scope, no safe seam) and `syscall_user.inc` (723). Stray TODO/STUB/FIXME is
> **zero repo-wide** (§3b). Remaining oversized: `src/diag/uefi_mouse_probe.asm`
> (2,202), `src/user/apps/launch.inc` (1,671), `media_viewer` parts, and the
> font data tables (data, not logic). Re-measure per §5 before re-rating.

| Sector | Files | Lines | Largest | TODO | Magic | Rating | Primary action |
|---|--:|--:|--:|--:|--:|---|---|
| `src/user/lib` | 3 | 173 | 98 | 0 | 4 | 🟢 Excellent | hold the line |
| `src/user/templates` | 1 | 30 | 30 | 0 | 1 | 🟢 Excellent | hold the line |
| `src/user/poc` | 9 | 619 | 238 | 0 | 0¹ | 🟢 Excellent | hold the line |
| `src/kernel/net` | 9 | 1,887 | 482 | 0 | 0¹ | 🟢 Excellent | hold the line |
| `src/kernel/arch` | 6 | 1,069 | 479 | 0 | 0¹ | 🟢 Excellent | hold the line |
| `src/kernel/lib` | 5 | 2,437 | 1,519 | 0 | 2 | 🟡 Fair | split the 1,519-line file |
| `src/resources/design-system` | 6 | 2,188 | 978 | 0 | 15 | 🟡 Fair | split the 978-line file |
| `src/include` | 20 | 4,026 | 707 | 1 | 115 | 🟡 Fair | name magic constants; headers should be the *source* of names |
| `src/kernel/fs` | 1 | 1,733 | 1,733 | 0 | 15 | 🟡 Fair | split `fat16.asm` into read/dir/alloc |
| `src/kernel/gui` | 7 | 4,877 | 1,813 | 0 | 20 | 🟡 Fair | split `window.asm` |
| `src/user/apps` | 11 | 7,663 | 1,805 | 1 | 64² | 🟠 Watch | magic ↓ (119→64); still blocked on splitting `media_viewer.inc` |
| `src/boot` | 8 | 5,786 | 2,339 | 0³ | 153³ | 🟠 Watch | live UEFI loader + BIOS path swept (§4.2 floor reached); 3 TODOs cleared; still blocked on oversized `boot.asm`/`uefi_loader.asm` split |
| `src/diag` | 1 | 1,990 | 1,990 | 0 | 35² | 🟠 Watch | magic ↓ (46→35); still one giant probe file - modularize or gate |
| `src/kernel/drivers` | 21 | 20,795 | 3,282 | 1 | 152 | 🔴 Heavy | largest sector; split top 3 drivers |
| `src/kernel/proc` | 6 | 9,051 | 4,942 | 0 | 39 | 🔴 Heavy | **decompose `syscall.asm`** |
| `src/kernel/core` | 13 | 8,645 | 4,970 | 2 | 98 | 🔴 Heavy | **decompose `main.asm`** |

---

## 3. Segment backlog (file level)

### 3a. Oversized files (>700-line flag) - split candidates, worst first

- [x] ~~[`src/kernel/core/main.asm`](../src/kernel/core/main.asm)~~ - **fully decomposed + ZERO-ASM** (2026-06-03). main.asm no longer exists: its logic lives in [`src/kernel/grithlk/`](../src/kernel/grithlk/) (the GritHLK kernel-emit modules) and its data/state in [`core_runtime_state.asm`](../src/kernel/core/core_runtime_state.asm). **Every GritHLK module is now genuinely structured GritHLK with NO inline asm** - `grep -E '^\s*asm\s+"' src/kernel/grithlk/*.ghl` is empty, and the kernel build compiles each module with `--forbid-asm` (a reintroduced shim breaks the build). Verified: full UEFI build green, headless boot markers (CPU:/CACHE:/MEMCAP:/`M12K*F!`) pass, the `[K0..L3]` boot-stage sequence emits, and a QEMU screendump shows the desktop/icons/taskbar/FPS rendering correctly.
  - **Converted modules** (behavior-parity, not byte-identical - emitted stream differs like the cpu_acct port): `boot_diag`, `debug_overlay`, `serial_console`, `serial_poll`, `kernel_console`, `context_menu`, `input_dispatch`, `kernel_lifecycle` (kmain), `frame_present` (render_frame + live-refresh). Previously done: `cpu_acct`, `serial_diag`.
  - **Dead code deleted**: the four `real_boot_diag_*` modules (~1,400 asm lines, `%ifdef`-gated debug with 200+ inline externs) + their two live call sites (the `=` keybind / serial command) were removed rather than ported - a verbatim port was pointless, and deletion satisfies "no asm" with no default-build behavior change.
  - **Compiler additions (gritc.py) that made full zero-asm possible**: (1) `cfg "NAME" {..}` / `cfg !"NAME" {..}` build-config conditionals → NASM `%ifdef`/`%ifndef` (kmain's ENABLE_SMAP/CET/KPTI/SHADOW_STACK_POC/FBPERF_NO_WC/GRIT_SMP/PROBE_NK_PT paths); (2) `ind()`/`outd()` 32-bit port I/O intrinsics (PCI CF8/CFC config access, inline in debug_overlay); (3) `const NAME = extern;` symbolic-constant passthrough (reference a kernel `equ` by name - NASM resolves it - instead of duplicating its value, used throughout frame_present). These join the earlier explicit-register ABI + `preserves(...)` + privileged intrinsics.
- [x] [`src/kernel/proc/syscall.asm`](../src/kernel/proc/syscall.asm) - ~~**4,942** lines. Dispatcher + hardening in one file.~~ Split 2026-06-02 into a 284-line orchestrator + 10 `syscall_*.inc` modules (largest `syscall_security.inc` at 641). Pure textual `%include` split - `KERNEL.BIN` byte-identical pre/post (sha256 verified). Handler slices stay in `syscall_entry`'s local-label scope.
- [x] [`src/kernel/drivers/rtl8156.asm`](../src/kernel/drivers/rtl8156.asm) - ~~3,282~~ Split 2026-06-10 into a 134-line orchestrator + 8 `rtl8156_*.inc` modules (largest `rtl8156_phy.inc` at 562). Pure textual `%include` split - `KERNEL.BIN` byte-identical pre/post (sha256 verified).
- [x] [`src/kernel/drivers/xhci.asm`](../src/kernel/drivers/xhci.asm) - ~~2,641~~ Split 2026-06-10 into a 55-line orchestrator + 7 `xhci_*.inc` modules (largest `xhci_init.inc` at 653). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/drivers/display.asm`](../src/kernel/drivers/display.asm) - ~~2,502~~ Split 2026-06-10 into a 28-line orchestrator + 5 `display_*.inc` modules (largest `display_flip.inc` at 607). Byte-identical `KERNEL.BIN` (sha256 verified). Cut points respect `FN_BEGIN` local-label scopes.
- [ ] [`src/boot/boot.asm`](../src/boot/boot.asm) - 2,339 (also 3 TODO/STUB)
- [ ] [`src/boot/uefi_loader.asm`](../src/boot/uefi_loader.asm) - 2,214 (3 TODO/STUB - most of any file)
- [x] [`src/kernel/drivers/usb_hid.asm`](../src/kernel/drivers/usb_hid.asm) - ~~1,996~~ Split 2026-06-10 into a 157-line orchestrator + 4 `usb_hid_*.inc` modules (largest `usb_hid_poll.inc` at 631). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/diag/uefi_mouse_probe.asm`](../src/diag/uefi_mouse_probe.asm) - ~~2,160~~ split 2026-06-10 into 5 `uefi_mouse_probe_*.inc` modules (largest 589) + 200-line orchestrator; KERNEL.PROBE.RAW sha256 byte-identical.
- [ ] [`src/user/apps/media_viewer.inc`](../src/user/apps/media_viewer.inc) - 1,956
- [x] [`src/kernel/gui/window.asm`](../src/kernel/gui/window.asm) - ~~1,023~~ Split 2026-06-10 into a 78-line orchestrator + 4 `window_*.inc` modules (largest `window_draw.inc` at 353). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/user/apps/launch.inc`](../src/user/apps/launch.inc) - ~~1,704~~ split 2026-06-10 into 4 `launch_*.inc` modules (largest 580) + 13-line orchestrator; KERNEL.BIN + APPS.BIN sha256 byte-identical.
- [x] [`src/kernel/fs/fat16.asm`](../src/kernel/fs/fat16.asm) - ~~1,791~~ Split 2026-06-10 into a 91-line orchestrator + 4 `fat16_*.inc` modules (largest `fat16_nav.inc` at 508). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/lib/xml.asm`](../src/kernel/lib/xml.asm) - ~~1,609~~ Split 2026-06-10 into an 81-line orchestrator + 3 `xml_*.inc` modules (largest `xml_parse.inc` at 618). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/drivers/hid_parser.asm`](../src/kernel/drivers/hid_parser.asm) - ~~1,400~~ Split 2026-06-10 into a 62-line orchestrator + 4 `hid_parser_*.inc` modules (largest `hid_parser_parse.inc` at 510). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/drivers/fbperf.asm`](../src/kernel/drivers/fbperf.asm) - ~~1,251~~ Split 2026-06-10 into a 67-line orchestrator + 4 `fbperf_*.inc` modules (largest `fbperf_get.inc` at 502). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/proc/process.asm`](../src/kernel/proc/process.asm) - ~~1,224~~ Split 2026-06-10 into a 38-line orchestrator + 4 `process_*.inc` modules (largest `process_callbacks.inc` at 465). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/drivers/rtl8139.asm`](../src/kernel/drivers/rtl8139.asm) - ~~1,146~~ Split 2026-06-10 into a 56-line orchestrator + 4 `rtl8139_*.inc` modules (largest `rtl8139_init.inc` at 370). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/gui/taskbar.asm`](../src/kernel/gui/taskbar.asm) - ~~1,131~~ Split 2026-06-10 into a 115-line orchestrator + 3 `taskbar_*.inc` modules (largest `taskbar_draw.inc` at 563). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/drivers/mouse.asm`](../src/kernel/drivers/mouse.asm) - ~~1,019~~ Split 2026-06-10 into a 19-line orchestrator + 4 `mouse_*.inc` modules (largest `mouse_init.inc` at 400). Byte-identical `KERNEL.BIN` (sha256 verified).
- [x] [`src/kernel/proc/workqueue.asm`](../src/kernel/proc/workqueue.asm) - ~~783~~ Split 2026-06-10 into a 153-line orchestrator + 2 `workqueue_*.inc` modules (largest `workqueue_worker.inc` at 384). Byte-identical `KERNEL.BIN` (sha256 verified).
- `src/kernel/proc/syscall_dispatch_core.inc` (727) - **skipped 2026-06-10**: the file is a single `syscall_entry` body containing only `.local` labels (no top-level seams), so any cut would break local-label scope. Leave intact.
- [x] [`src/kernel/proc/usermode.asm`](../src/kernel/proc/usermode.asm) - split 2026-06-01 into a 24-line wrapper plus focused `usermode_*.inc` files; largest resulting file is `usermode_paging.inc` at 329 lines. Build verified with deterministic UEFI path.
- [ ] [`src/kernel/drivers/i2c_hid.asm`](../src/kernel/drivers/i2c_hid.asm) - 1,612
- [ ] [`src/kernel/lib/*`](../src/kernel/lib) - 1,519-line file
- [ ] [`src/resources/design-system/*`](../src/resources/design-system) - 978-line file

### 3b. Stray TODO/STUB/FIXME - resolve or convert to tracked issues

> ✅ **CLEARED 2026-06-10.** The dashboard's TODO regex is now case-sensitive
> (`-CaseSensitive`, word-bounded) and the `## TODO/STUB/FIXME Counts` section
> of a fresh `tools/complexity_dashboard.ps1` run is **empty** - zero stray
> markers across `src/`. Genuine unfinished phases were converted to tracked
> issue references (ramdisk write-back → #21); the rest were prose false
> positives, reworded. §4.3 is met repo-wide.

> ⚠️ **Measurement bug (found 2026-06-01).** The dashboard's TODO metric is
> **case-insensitive** (`Select-String` default), so the per-file counts in §2/§5
> are mostly false positives: every `security_todo.md` / `maintainability-todo.md`
> spec cross-reference (~80+, which are *good* traceability), the word "stub" in
> prose, the `IRQ_STUB`/`isr_common_stub` identifiers, and the literal string
> `"todo.txt"` all match. The **genuine** stray-debt markers are only these:
>
> - [x] [`src/boot/uefi_loader.asm`](../src/boot/uefi_loader.asm) - ~~3 (`TODO Phase 1b.2/1b.3/1b.4`)~~ cleared 2026-06-03. 1b.2 (root-dir DATA.IMG walk) and 1b.3 (FAT32 chain→extent coalesce) were already implemented in `uefi_loader_storage_extents.inc` (`fat32_find_dirent` / `fat32_emit_data_extents`); the stale `[ ]` checkboxes were corrected to `[x]`. 1b.4 (partition-relative→absolute LBA, needs a kernel NVMe/USB-MSC backing driver) is a tracked issue (#21), referenced in-code via `see #21`.
> - [x] [`src/kernel/drivers/ramdisk.asm`](../src/kernel/drivers/ramdisk.asm) - ~~1 (`TODO(Phase 4)`)~~ converted 2026-06-10: write-back is blocked on the kernel block-device driver, same blocker as issue #21; comment now reads `Phase 4 plan (see #21)` per §4.3 (tracked issue, no stray marker).
> - [x] [`src/user/apps/media_viewer.inc`](../src/user/apps/media_viewer.inc) - ~~1 (`No scrolling (TODO)`)~~ **done** (verified 2026-06-10): renderer consumption landed - `media_viewer_vector.inc` `nx_media_blit_xml` skips `mp_text_scroll_line` lines before drawing; `media.ghl`/`media_player.ghl` own the key handling. No `TODO` markers remain anywhere under `src/user/apps/`.
> - [x] [`src/kernel/proc/process.asm`](../src/kernel/proc/process.asm) - ~~1 (a `stub` body note, line 627)~~ false positive: `process_find_by_window` is implemented; the comment said the body "was a stub" (historical prose). Reworded 2026-06-10.
>
> **Action:** make the dashboard regex case-sensitive and exclude `*_todo.md`
> filename matches before chasing §4.3. Until then the TODO column is not a
> trustworthy gate signal. The genuine markers above should be converted to tracked
> issues (per §4.3) rather than deleted, since they encode real unfinished phases.


- [x] [`src/boot/uefi_loader.asm`](../src/boot/uefi_loader.asm) - ~~3~~ cleared 2026-06-03 (1b.2/1b.3 already implemented; 1b.4 → issue #21, `see #21` in-code)
- [x] [`src/user/poc/poc_standalone_prelude.inc`](../src/user/poc/poc_standalone_prelude.inc) - ~~1~~ resolved (was a doc x-ref, reworded to `spec ref: security_todo.md §13`)
- [x] [`src/user/apps/media_viewer.inc`](../src/user/apps/media_viewer.inc) - ~~1~~ done 2026-06-10 (scroll renderer consumption verified in `media_viewer_vector.inc`; no TODO markers under `src/user/apps/`)
- [x] [`src/kernel/drivers/ramdisk.asm`](../src/kernel/drivers/ramdisk.asm) - ~~1~~ converted 2026-06-10 to tracked issue ref (`Phase 4 plan (see #21)`)
- [x] Measured boot - SHA-256/HMAC owner is `src/kernel/grithlk/crypto.ghl`; old hand-written assembly implementation removed.
- [x] [`src/kernel/core/kernel_lockdown.asm`](../src/kernel/core/kernel_lockdown.asm) - ~~1~~ false positive (prose "this TODO targets"); reworded 2026-06-10 to cite security_todo.md §9
- [x] [`src/include/kpti.inc`](../src/include/kpti.inc) - ~~1~~ false positive: `ENTRY-STUB RELOCATION` heading (identifier-style prose, not stray debt); left as-is

### 3c. Magic-constant hotspots - name in headers

- [x] `src/boot` - ~~197~~ → 153 (2026-06-03 sweep of the live UEFI loader + BIOS
  path; named via `src/include/uefi_abi.inc` + `bios_boot.inc`, byte-identical).
  Residual = out-of-scope `boot.asm` orphan (85) + §4.2 floor (equ defs +
  comments + packed descriptor/GUID data defs). Zero bare in-code operand
  literals remain in the in-scope files.
- [ ] `src/kernel/drivers` - 152
- [x] `src/user/apps` - ~~119~~ → 64 (agent sweep 2026-06-01; residual ≈ distinct `equ` defs)
- [ ] `src/include` - 115 (headers should *define* names, not contain raw literals)
- [ ] `src/kernel/core` - 98
- [x] `src/diag` - ~~46~~ → 35 (agent sweep 2026-06-01)

---

## 4. Spec: what "Excellent" requires

> Fill in / tighten the criteria below. A sector is **Excellent** only when every
> segment in it passes all of these. Treat the unchecked boxes as the definition
> of done.

### 4.1 Size & structure
- [ ] No source file exceeds **700 lines** (project flag). Target working size ≤ ~400.
- [ ] Each file has a single clear responsibility (one driver / one subsystem phase / one app).
- [ ] Public label (`global`) surface per file is minimal and intentional.

### 4.2 Constants & data
- [ ] No bare magic numbers in `.asm`; every `0x...` ≥5 hex digits is a **named** constant.
- [ ] Names are *defined* in `src/include/` headers and referenced everywhere else.
- [ ] MMIO/register offsets carry a comment citing the spec section they come from.

### 4.3 Debt
- [x] Zero stray `TODO`/`STUB`/`FIXME`. Anything unfinished is a tracked GitHub issue, referenced by number in the code comment. *(met repo-wide 2026-06-10; dashboard TODO section empty)*

### 4.4 Traceability  *(expand this - user to spec)*
- [ ] Every public function appears in [`docs/kernel-function-reference.md`](kernel-function-reference.md).
- [ ] Every syscall is traceable: number → handler → capability → doc entry in [`docs/syscalls.md`](syscalls.md).
- [ ] Every invariant has an ID and is registered in [`docs/invariant-registry.md`](invariant-registry.md), with the asserting site referencing that ID.
- [ ] Every memory region is registered in [`docs/memory-map-reference.md`](memory-map-reference.md) and [`docs/ownership-registry.md`](ownership-registry.md).
- [ ] Each subsystem has an end-to-end trace doc under [`docs/traces/`](traces/).
- [ ] Commits/PRs touching a sector reference the relevant spec ID (requirement ↔ code ↔ test ↔ doc chain).
- [ ] *(TODO: define the traceability ID scheme - e.g. `REQ-xxxx`, `INV-xxxx`, `SYS-xxxx` - and where the master matrix lives.)*

### 4.5 Verification gate
- [ ] `tools/complexity_dashboard.ps1` re-run shows the file off every "over 700" / TODO list.
- [ ] `tools/check_complexity_thresholds.ps1` passes for the sector.
- [ ] Relevant `scripts/test/*` pass; trace docs still match behavior.

---

## 5. How to re-measure

```powershell
# regenerate the committed dashboard
pwsh tools/complexity_dashboard.ps1        # -> build/reports/complexity-dashboard.md
pwsh tools/check_complexity_thresholds.ps1 # gate
```

Update the "Last measured" date and the §2 table whenever the numbers move.
