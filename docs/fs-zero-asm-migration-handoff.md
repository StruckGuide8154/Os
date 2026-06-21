# FS stack → zero-asm GHL migration — handoff

Goal: migrate the whole FAT16 filesystem stack + `SYS_FS_*` syscall handlers
from assembly to zero-asm GritHL, preserving every security invariant, and fix
the real-HW File Explorer garbage-listing bug along the way.

Branch: `track2-residuals`. Compile contract for kernel GHL modules:
`python src\user\grithl\compiler\gritc.py SRC -o build\ghl\NAME.asm -L src\user\grithl\lib --embed --target kernel --forbid-asm --safety-manifest build\ghl\safety\NAME.safety.json`
Full build: `scripts\build\build_uefi.ps1` (cwd MUST be repo root).

## Phase 0 — stabilize the asm first ✅ DONE (full build verified)
- Removed shipped debug spew (`SER 'F'/'I'`, `ser_print_hex64`, `'FX'`) from
  `.sc_fs_entry_info` in `src/kernel/proc/syscall_handlers_sys_fs.inc`.
- Root-caused + fixed the corruption: `fat16_init` (`src/kernel/fs/fat16_init.inc`)
  and `fat16_change_dir` (`src/kernel/fs/fat16_nav.inc`) ignored the
  `ata_read_sectors` return when filling FAT/root caches → on real HW a failed/
  short PIO read left garbage DRAM walked as directory data (corrupt names +
  ~2^32 sizes). Both now `test eax,eax / jnz .init_fail`/`.cd_fail` (fail-closed).
- **TODO for user:** boot this on the real laptop and confirm the listing is
  clean (or empty), since QEMU can't reproduce the bug.

## Phase 1 — GHL skeleton w/ `reserve` ✅ DONE
- New `src/kernel/grithlk/fat16_core.ghl`. Big buffers (`fat16_fat_cache` 64 KiB,
  `fat16_file_buf` 64 KiB, `fat16_root_cache` 16 KiB, `fat16_sector_buf`) use the
  new `reserve NAME[N];` .bss/NOBITS primitive → zero image bytes.
- Geometry state as `data ...: 1 x 4;`. LE helpers `f16_rd_u16/u32`,
  `f16_wr_u16/u32`. NOTE: GHL has NO native 16-bit store — `f16_wr_u16` (two
  `sb`) is mandatory for FAT entries + 2-byte dir fields; `sw` would clobber the
  adjacent 2 bytes.

## Phase 2 — read path ✅ DONE (compiles standalone)
In `fat16_core.ghl`: `gfat16_init` (drive probe + "NEXUSOS " marker + BPB parse +
cache fill, all reads checked/fail-closed), `gfat16_count_root_files`,
`gfat16_file_count`, `gfat16_get_entry`, `gfat16_get_file_size`,
`gfat16_read_file`, range-checked `f16_cluster_lba`, `f16_fat_next`, canary
seed/check via `kernel_panic_canary`.

## Phase 3 — write path ✅ DONE (compiles standalone, 62 KB asm)
In `fat16_core.ghl`: `gfat16_write_file`, `gfat16_delete_entry`,
`gfat16_rename_entry`, `gfat16_mkdir`, `gfat16_flush_fats`,
`gfat16_flush_current_dir`, helpers `f16_free_chain`, `f16_find_free_cluster`,
`f16_name_eq/copy`, `f16_dir_cluster_is_empty`. Functions are namespaced
`gfat16_*` so the live asm stays in use and the build stays green.

## Phase 4 — nav / cwd / TOCTOU snapshot + WIRING ✅ DONE (full build green)
Ported the remaining asm into the SAME `fat16_core.ghl` module (shares the cache/
state directly — cross-module `extern` of `reserve`/`data` left unattempted) and
swapped the live driver:
- `fat16_change_dir(cluster)` — root (contiguous, fail-closed) or subdir (chain
  walk into the cleared 16 KiB cache, truncate-not-overrun), canary-checked,
  stamps `fat16_cache_owner = NONE`.
- `fat16_switch_to(r15 slot) preserves(all)`, `fat16_sync_root`.
- Per-slot cwd + TOCTOU snapshot in kernel `.bss` via `reserve`
  (`fat16_slot_cwd`, `fat16_cache_owner`, `fat16_entry_snap_armed`,
  `fat16_entry_snap`); `fat16_entry_info_snapshot` / `_snapshot_verify`
  (fail-closed) / `_snapshot_clear`.
- Swap done: `gfat16_*` → `fat16_*`; `fat16.asm` %include in `kernel_build.asm`
  replaced by `build/ghl/fat16_core.asm`; module added to `$KernelModules` in
  `build_uefi.ps1`; the 5 legacy files deleted. The magic FAT16_* VAs are NOT
  relied on by the dispatcher (handle→pointer goes through `fat16_get_entry`;
  `syscall.asm` keeps its own local FAT16_ROOT_CACHE/MAX_ENTRIES equ for the
  index bound only), so the `.bss` buffers needed no repointing.

(original notes below)

Port the remaining asm (`fat16_nav.inc`, snapshot block in `fat16_nav.inc`):
- `fat16_change_dir(ax=cluster)` — load root (contiguous) or subdir (cluster
  chain) into `fat16_root_cache`, 16 KiB truncation guard, canary check, stamp
  `fat16_cache_owner = NONE`.
- Per-slot cwd: `fat16_slot_cwd[APP_SLOT_COUNT]` (resw), `fat16_cache_owner`
  (resd, sentinel `0xFFFFFFFF`), `fat16_switch_to` — reload live cache to the
  calling slot's cwd when ownership differs. Indexed by `r15` (slot id) →
  use GHL explicit-register param form: `fn fat16_switch_to(r15 slot) preserves(all)`.
- TOCTOU snapshot (security_todo §5): `fat16_entry_info_snapshot(rdi ent, esi slot)`,
  `fat16_entry_snapshot_verify` (fail-closed on divergence), `fat16_entry_snapshot_clear`.
  Per-slot BSS arrays `fat16_entry_snap_armed[]`, `fat16_entry_snap[]`
  (FAT16_SNAP_STRIDE=17). Must stay OUTSIDE the ring-3 arena.
- Decide cross-module data sharing: simplest is to keep nav in the SAME
  `fat16_core.ghl` module (shares cache/state directly); GHL cross-module
  `extern` of `data`/`reserve` symbols is unverified.

THEN the swap:
1. Rename `gfat16_*` → `fat16_*` (match the asm global names exactly:
   `fat16_init`, `fat16_file_count`, `fat16_get_entry`, `fat16_get_file_size`,
   `fat16_read_file`, `fat16_write_file`, `fat16_delete_entry`,
   `fat16_rename_entry`, `fat16_mkdir`, `fat16_change_dir`, `fat16_switch_to`,
   `fat16_sync_root`, `fat16_entry_info_snapshot`, `fat16_entry_snapshot_verify`,
   `fat16_entry_snapshot_clear`, `fat16_list_dir` if still referenced).
2. Add the GHL module(s) to `$KernelModules` in `scripts/build/build_uefi.ps1`
   (and any BIOS build path `scripts/build/build_bios.ps1` / `build_ghl.ps1`).
3. Remove the four `%include`s from `src/kernel/fs/fat16.asm` (and drop the file
   from `src/kernel/kernel_build.asm` if it's no longer needed), or empty it.
4. Re-check the `.sc_fs_*` handlers in
   `src/kernel/proc/syscall_handlers_sys_fs.inc` + `syscall_handlers_gui_wm.inc`
   (`.sc_fs_read` snapshot verify) still call the same symbol names / ABI
   (e.g. `fat16_switch_to` is the first instruction of every FS handler and
   `preserves(all)`).
5. Verify the `FAT16_*` buffer addresses: the asm used magic VAs (0xD00000 /
   0x1A00000 Cache32Max). The GHL `reserve` buffers live in kernel .bss instead.
   Anything else that hardcoded those VAs must be repointed (grep
   `FAT16_SECTOR_BUF|FAT16_ROOT_CACHE|FAT16_FAT_CACHE|FAT16_FILE_BUF|FAT16_DIR_CACHE`).

## Phase 5 — enforcement + verify ✅ DONE
- `tools/security/legacy_asm_inventory.txt`: the 5 fat16 lines pruned (the
  inventory only shrinks). `check_no_asm.ps1 -InventoryGuard` → PASS.
- Track-8 frozen `driver_inventory.txt`: fat16 was never a Track-8 driver, so no
  change; the guard self-test still PASSes (21 frozen, shrink-only).
- `tools/security/ghlk_safety_budget.json` ratcheted up by exactly the one new
  module (unsafe 42→43, broad 41→42, extern contracts 416→426); all other
  budgets unchanged. The budget only ever increases for a real added module.
- `build_uefi.ps1` green with `--forbid-asm` (incl. the KASLR A/B byte-identity
  pass). `scripts/test/test_ghl_security_guards.ps1` → `[ghl-security] PASS`.
- **TODO for user (unchanged from Phase 0):** QEMU can't reproduce the real-HW
  garbage-listing; boot on the real laptop and confirm File Explorer lists
  clean and open/rename/new-folder/delete round-trip. (Automated QEMU smoke:
  `scripts/test/test_explorer_app_markers.ps1`.)

## Key gotchas
- GHL stores: `sb`=8, `sw`=32, `sq`=64. NO 16-bit store → use `f16_wr_u16`.
- `reserve` = .bss (zero image bytes); `data` = real image bytes (use only for
  small geometry state).
- `&fnname` is allowed (used for the canary panic `rsi=site`).
- Build cwd must be repo root.
- `ata_*` ABI: `(rdi=LBA, rsi=buf, edx=count) -> 0 ok / -1 err`. Drive byte is
  the extern `ata_drive_sel`.
- See memory: `fat16_unchecked_read_garbage_listing`.
