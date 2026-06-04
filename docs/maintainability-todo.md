# Maintainability TODOs

Status: **draft / working backlog**
Owner: @StruckGuide8154
Last measured: 2026-06-01 (commit `fe78edd`)
Scope: `src/` only — `deprecated/` is excluded.

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
¹ **0 bare** magic literals: every `0x…` ≥5-digit value in these three sectors
is now either a named `equ` (in [`src/include/arch_regs.inc`](../src/include/arch_regs.inc),
[`src/include/net_driver.inc`](../src/include/net_driver.inc), or a documented
local `equ` in the PoC) or appears only inside an explanatory comment. Each
register/MSR/MMIO constant cites its spec section (§4.2). Promoted Good→Excellent
2026-06-01 (build verified green).
² **Magic sweep (agents) 2026-06-01.** Bare `0x…` ≥5-digit literals in these two
sectors were replaced with descriptive `equ` constants (value copied byte-for-byte;
verified). The residual count is now ≈ the number of *distinct* named constants
(each `equ` definition line still holds its literal once — this is the §4.2 floor,
not debt). Per-file: notepad 40→13, paint 24→8, shell 8→2, launch 5→2,
state 9→8, terminal 7→5, media_viewer 23→21; diag probe 46→35. Builds green
(`build_uefi.ps1` + `build_probe.ps1`). Neither sector is promoted: both remain
🟠 Watch because the oversized-file blocker (media_viewer 1,805; probe 1,990) is
untouched — splitting those is boot-/runtime-sensitive manual work, intentionally
not fanned out to agents.

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
| `src/boot` | 8 | 5,786 | 2,339 | 3 | 197 | 🟠 Watch | **magic + TODO hotspot**; clear 3 TODOs |
| `src/diag` | 1 | 1,990 | 1,990 | 0 | 35² | 🟠 Watch | magic ↓ (46→35); still one giant probe file — modularize or gate |
| `src/kernel/drivers` | 21 | 20,795 | 3,282 | 1 | 152 | 🔴 Heavy | largest sector; split top 3 drivers |
| `src/kernel/proc` | 6 | 9,051 | 4,942 | 0 | 39 | 🔴 Heavy | **decompose `syscall.asm`** |
| `src/kernel/core` | 13 | 8,645 | 4,970 | 2 | 98 | 🔴 Heavy | **decompose `main.asm`** |

---

## 3. Segment backlog (file level)

### 3a. Oversized files (>700-line flag) — split candidates, worst first

- [ ] [`src/kernel/core/main.asm`](../src/kernel/core/main.asm) — **3,614** lines (was 4,970; -1,356 over 2 batches). Top structural outlier. **Decomposition via NexusHLK** (kernel emit mode of `nxhc.py`), 2026-06-01. Five modules now live under [`src/kernel/nexushlk/`](../src/kernel/nexushlk/): `serial_diag` (svg_dump leaves), `boot_diag` (diag_emit_*/svg_dump_serial/serial_forward_input), `debug_overlay` (usb_debug_overlay/ovl_*/usb_dbg_pci_scan), `cpu_acct` (cpu_acct_*), `serial_console` (serial_dispatch_control). Each compiled to `build/nxh/*.asm`, `%include`d after main.asm (order preserved, inside `[_start,_kernel_text_end)`). Build green + serial-diff behavior-verified (deterministic `-NoMemRandom -NoKaslr`); user-app outputs byte-identical.
  - ⚠️ **Maintainability caveat**: ports so far are *file-level only* — the bodies are still verbatim `asm{}` shims, because these routines use hand-rolled non-System-V register ABIs that nxhc's structured `fn` (System-V) can't express without rewriting (off-limits) callers. **True statement-level maintainability is blocked on a compiler feature**: explicit-register parameter binding in nxhc kernel mode (e.g. `fn f(rdi cursor, edx val) preserves(all)`). Until then, decomposition reduces file size + isolates subsystems but does not improve in-function readability.
  - `real_boot_diag_dump` (~1,584 lines) intentionally NOT ported — `%ifdef`-gated dead-code with 200+ inline externs; a verbatim string port would be pointless.
- [x] [`src/kernel/proc/syscall.asm`](../src/kernel/proc/syscall.asm) — ~~**4,942** lines. Dispatcher + hardening in one file.~~ Split 2026-06-02 into a 284-line orchestrator + 10 `syscall_*.inc` modules (largest `syscall_security.inc` at 641). Pure textual `%include` split — `KERNEL.BIN` byte-identical pre/post (sha256 verified). Handler slices stay in `syscall_entry`'s local-label scope.
- [ ] [`src/kernel/drivers/rtl8156.asm`](../src/kernel/drivers/rtl8156.asm) — 3,282
- [ ] [`src/kernel/drivers/xhci.asm`](../src/kernel/drivers/xhci.asm) — 2,641
- [ ] [`src/kernel/drivers/display.asm`](../src/kernel/drivers/display.asm) — 2,502
- [ ] [`src/boot/boot.asm`](../src/boot/boot.asm) — 2,339 (also 3 TODO/STUB)
- [ ] [`src/boot/uefi_loader.asm`](../src/boot/uefi_loader.asm) — 2,214 (3 TODO/STUB — most of any file)
- [ ] [`src/kernel/drivers/usb_hid.asm`](../src/kernel/drivers/usb_hid.asm) — 2,164
- [ ] [`src/diag/uefi_mouse_probe.asm`](../src/diag/uefi_mouse_probe.asm) — 2,160
- [ ] [`src/user/apps/media_viewer.inc`](../src/user/apps/media_viewer.inc) — 1,956
- [ ] [`src/kernel/gui/window.asm`](../src/kernel/gui/window.asm) — 1,813
- [ ] [`src/user/apps/launch.inc`](../src/user/apps/launch.inc) — 1,704
- [ ] [`src/kernel/fs/fat16.asm`](../src/kernel/fs/fat16.asm) — 1,733
- [x] [`src/kernel/proc/usermode.asm`](../src/kernel/proc/usermode.asm) — split 2026-06-01 into a 24-line wrapper plus focused `usermode_*.inc` files; largest resulting file is `usermode_paging.inc` at 329 lines. Build verified with deterministic UEFI path.
- [ ] [`src/kernel/drivers/i2c_hid.asm`](../src/kernel/drivers/i2c_hid.asm) — 1,612
- [ ] [`src/kernel/lib/*`](../src/kernel/lib) — 1,519-line file
- [ ] [`src/resources/design-system/*`](../src/resources/design-system) — 978-line file

### 3b. Stray TODO/STUB/FIXME — resolve or convert to tracked issues

> ⚠️ **Measurement bug (found 2026-06-01).** The dashboard's TODO metric is
> **case-insensitive** (`Select-String` default), so the per-file counts in §2/§5
> are mostly false positives: every `security_todo.md` / `maintainability-todo.md`
> spec cross-reference (~80+, which are *good* traceability), the word "stub" in
> prose, the `IRQ_STUB`/`isr_common_stub` identifiers, and the literal string
> `"todo.txt"` all match. The **genuine** stray-debt markers are only these:
>
> - [ ] [`src/boot/uefi_loader.asm`](../src/boot/uefi_loader.asm) — 3 (`TODO Phase 1b.2/1b.3/1b.4`)
> - [ ] [`src/kernel/drivers/ramdisk.asm`](../src/kernel/drivers/ramdisk.asm) — 1 (`TODO(Phase 4)`)
> - [ ] [`src/user/apps/media_viewer.inc`](../src/user/apps/media_viewer.inc) — 1 (`No scrolling (TODO)`)
>   - 2026-06-01 NexusHL-side assessment: not fixed in this pass because the XML line walk and draw origin live in the media viewer renderer split (`media_viewer_vector.inc` in the current working tree). Exact low-risk interface for the renderer worker: append a slot-local `mp_text_scroll_line: 4` field after `mp_dragging` in `src/user/nexushl/apps/media.nxh`; have the NexusHL key handler adjust it for text media; have the XML renderer read `app_hl_media_mp_text_scroll_line - app_blob_start`, skip that many LF-delimited lines before the first draw, and clamp at EOF. Mouse-wheel scrolling is not just a media app change: the current `window_t` ABI exposes draw/key/click callbacks only, with no wheel delta or scroll callback, so wheel support needs a WM callback/signature extension first.
> - [ ] [`src/kernel/drivers/process.asm`](../src/kernel/proc/process.asm) — 1 (a `stub` body note, line 627)
>
> **Action:** make the dashboard regex case-sensitive and exclude `*_todo.md`
> filename matches before chasing §4.3. Until then the TODO column is not a
> trustworthy gate signal. The genuine markers above should be converted to tracked
> issues (per §4.3) rather than deleted, since they encode real unfinished phases.


- [ ] [`src/boot/uefi_loader.asm`](../src/boot/uefi_loader.asm) — 3
- [x] [`src/user/poc/poc_standalone_prelude.inc`](../src/user/poc/poc_standalone_prelude.inc) — ~~1~~ resolved (was a doc x-ref, reworded to `spec ref: security_todo.md §13`)
- [ ] [`src/user/apps/media_viewer.inc`](../src/user/apps/media_viewer.inc) — 1
- [ ] [`src/kernel/drivers/ramdisk.asm`](../src/kernel/drivers/ramdisk.asm) — 1
- [ ] [`src/kernel/core/measured_boot.asm`](../src/kernel/core/measured_boot.asm) — 1
- [ ] [`src/kernel/core/kernel_lockdown.asm`](../src/kernel/core/kernel_lockdown.asm) — 1
- [ ] [`src/include/kpti.inc`](../src/include/kpti.inc) — 1

### 3c. Magic-constant hotspots — name in headers

- [ ] `src/boot` — 197 literals
- [ ] `src/kernel/drivers` — 152
- [x] `src/user/apps` — ~~119~~ → 64 (agent sweep 2026-06-01; residual ≈ distinct `equ` defs)
- [ ] `src/include` — 115 (headers should *define* names, not contain raw literals)
- [ ] `src/kernel/core` — 98
- [x] `src/diag` — ~~46~~ → 35 (agent sweep 2026-06-01)

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
- [ ] No bare magic numbers in `.asm`; every `0x…` ≥5 hex digits is a **named** constant.
- [ ] Names are *defined* in `src/include/` headers and referenced everywhere else.
- [ ] MMIO/register offsets carry a comment citing the spec section they come from.

### 4.3 Debt
- [ ] Zero stray `TODO`/`STUB`/`FIXME`. Anything unfinished is a tracked GitHub issue, referenced by number in the code comment.

### 4.4 Traceability  *(expand this — user to spec)*
- [ ] Every public function appears in [`docs/kernel-function-reference.md`](kernel-function-reference.md).
- [ ] Every syscall is traceable: number → handler → capability → doc entry in [`docs/syscalls.md`](syscalls.md).
- [ ] Every invariant has an ID and is registered in [`docs/invariant-registry.md`](invariant-registry.md), with the asserting site referencing that ID.
- [ ] Every memory region is registered in [`docs/memory-map-reference.md`](memory-map-reference.md) and [`docs/ownership-registry.md`](ownership-registry.md).
- [ ] Each subsystem has an end-to-end trace doc under [`docs/traces/`](traces/).
- [ ] Commits/PRs touching a sector reference the relevant spec ID (requirement ↔ code ↔ test ↔ doc chain).
- [ ] *(TODO: define the traceability ID scheme — e.g. `REQ-xxxx`, `INV-xxxx`, `SYS-xxxx` — and where the master matrix lives.)*

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
