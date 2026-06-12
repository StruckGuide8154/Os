# Grit TODO Checklist

This checklist is based on the current repository state, the latest verification
run, the complexity report, and the existing audit notes. It is intentionally
specific: each item should either close a known gap, improve verification, or
reduce maintenance risk.

## P0: Verification Blockers

- [ ] Fix final `scripts\test\test_verify_all.ps1` failure: `scripts\test\test_smp_boot.ps1` reports `Missing extended SMP counters`.
- [ ] Inspect why `build/cache32_serial.log` contains bare `SMP:` lines instead of the expected extended format: `SMP:<detected>/<target>/<started>/<alive>/<parked>`.
- [ ] Verify whether `perfdiag_print_smp` in `src/kernel/core/perfdiag.asm` is being called in the Cache32Max BIOS boot path.
- [ ] Confirm whether the SMP counters are missing because boot logging is truncated, the marker format changed, or AP startup state is not initialized before printing.
- [ ] Add or adjust a serial marker that always emits extended SMP counters after AP startup, before `scripts\test\test_smp_boot.ps1` reads the log.
- [ ] Re-run `.\scripts\test\test_smp_boot.ps1` alone until it passes.
- [ ] Re-run full `.\scripts\test\test_verify_all.ps1` after the SMP marker fix.
- [ ] Investigate the Cache32 build warning/error during full verify: `WriteAllBytes ... file with a user-mapped section open`.
- [ ] Ensure QEMU is fully stopped before rebuilding `build\Grit.img`.
- [ ] Consider making `scripts\test\test_cache32_boot.ps1` delete/retry the image only after confirming no QEMU process holds it.

## P0: Test And Guard Staleness

- [x] Fix `scripts\test\test_security_probe.ps1` F2 static guard: it expects literal `fat16_read_file:` but `src/kernel/fs/fat16.asm` now uses `FN_BEGIN fat16_read_file`.
- [x] Re-run `.\scripts\test\test_security_probe.ps1` after updating the regex.
- [x] Keep the F2 guard checking the real property: read cluster into `FAT16_FILE_BUF`, then copy bounded length to caller buffer.
- [x] Add a runtime F2 assertion if possible, so the security probe does not rely only on source regex shape.
- [x] Check all static regex guards for macro-era drift: `FN_BEGIN`, `FN_DECL`, generated labels, auto-wrapped globals.
- [x] Make security probe failures distinguish "pattern stale" from "property absent".

## P0/P1: L3 Correctness

- [ ] Add a dedicated L3 stress test that repeatedly opens Notepad, types, closes, reopens, and verifies app state resets correctly.
- [ ] Test slot reuse: launch app in the same window slot after close and verify stale slot memory is not reused incorrectly.
- [ ] Verify `L3_SLOT_MAGIC_OFF` behavior in `src/kernel/proc/usermode.asm`.
- [ ] Decide whether app launch should clear slot magic, force blob copy, or call a user-mode init hook.
- [ ] Confirm Notepad typed characters appear visually, not only in serial markers.
- [ ] Add a serial marker for app init vs callback draw vs key event to distinguish first-copy bugs from redraw bugs.
- [ ] Test nested or re-entrant L3 calls: key repeat while app callback is already active.
- [ ] Add an explicit guard against entering the same slot's callback while it is already in ring 3.
- [ ] Add a counter for unmatched `U...` ring-3 entries vs `R...` returns in serial tests.
- [ ] Add a test that intentionally sends invalid callback pointers and expects syscall rejection.

## P1: User/App Boundary

- [ ] Move more app state initialization into user-mode app code instead of kernel launcher globals.
- [ ] Define a formal app lifecycle: `init`, `draw`, `click`, `key`, `close`.
- [ ] Document which app state is copied from `app_blob_start..app_blob_end` and which state is per-slot runtime.
- [ ] Add a slot-local allocator or simple app heap instead of relying on fixed addresses.
- [ ] Make `APP_SLOT_SIZE` pressure visible in a build report.
- [ ] Add a test that fills a slot near capacity and verifies shadow window, stack, runtime frame, and app blob do not overlap.
- [ ] Add a negative test for app code trying to dereference live kernel window pointers.
- [ ] Add per-syscall tests for invalid pointers: below app arena, above arena, kernel address, null, unaligned edge.

## P1: Syscall Surface

- [ ] Generate syscall docs from source or validate docs against source automatically.
- [ ] Add a syscall table count check that also verifies documented range `0..21`.
- [ ] Add per-syscall return-value tests for validation failure.
- [ ] Add tests for `SYS_FS_DELETE`, `SYS_FS_RENAME`, and `SYS_FS_MKDIR` edge cases.
- [ ] Test negative and huge window IDs for `SYS_WM_CLOSE` and `SYS_WM_HANDLERS`.
- [ ] Test `SYS_DISPLAY_SET_MODE` overflow paths: width * height * 4 overflow, zero dimensions, unsupported bpp.
- [ ] Test `SYS_FS_READ` with buffer exactly at end of app arena.
- [ ] Test `SYS_FS_WRITE` with final partial cluster and verify no overread.
- [ ] Test `SYS_FS_FORMAT_NAME` with invalid opaque handles.
- [ ] Consider a syscall fuzz harness that runs inside QEMU and emits compact serial result markers.

## P1: Filesystem And FAT16

- [ ] Split `src/kernel/fs/fat16.asm`, currently about 1353 lines.
- [ ] Separate directory enumeration, file read/write, metadata mutation, and formatting helpers.
- [ ] Add FAT16 tests for long directory chains.
- [ ] Add FAT16 tests for full root directory.
- [ ] Add FAT16 tests for full FAT/no free clusters.
- [ ] Add FAT16 tests for deleting non-empty directories.
- [ ] Add FAT16 tests for duplicate rename/mkdir.
- [ ] Add crash-resilience notes: what happens if write succeeds but root sync fails?
- [ ] Add a consistency checker for `data.img`.
- [ ] Verify all FAT16 metadata writes are bounded to valid sectors.

## P1: SMP And APIC

- [ ] Fix SMP serial marker format first.
- [ ] Confirm `madt_enabled_cpu_count`, `smp_target_cores`, `smp_started_cores`, `smp_alive_cores`, and `smp_parked_cores` agree.
- [ ] Test 1-core, 2-core, 4-core, and 8-core QEMU topologies.
- [ ] Add timeout markers for AP startup failure.
- [ ] Print LAPIC IDs in a compact marker for debugging.
- [ ] Verify AP stacks are unique and aligned.
- [ ] Verify APs do not enter GUI/kernel init paths intended only for BSP.
- [ ] Add a stress test for timer interrupts after AP startup.
- [ ] Decide whether PIC should eventually be masked after IOAPIC handoff.
- [ ] Document current dual PIC/IOAPIC EOI policy.

## P1: Large File Refactors

- [ ] Split `src/boot/boot.asm`, currently about 2153 lines.
- [ ] Split `src/kernel/drivers/xhci.asm`, currently about 1920 lines.
- [ ] Split `src/kernel/drivers/usb_hid.asm`, currently about 1351 lines.
- [ ] Split `src/kernel/drivers/i2c_hid.asm`, currently about 1153 lines.
- [ ] Split `src/kernel/drivers/hid_parser.asm`, currently about 1129 lines.
- [ ] Split `src/boot/uefi_loader.asm`, currently about 1072 lines.
- [ ] Split `src/kernel/proc/syscall.asm`, currently about 912 lines.
- [ ] Split `src/kernel/gui/window.asm`, currently about 892 lines.
- [ ] Split `src/kernel/gui/taskbar.asm`, currently about 806 lines.
- [ ] Keep each split gated by full verify, because assembly include order and fixed addresses are fragile.

## P1: Driver Hardening

- [ ] Audit `src/kernel/drivers/xhci.asm` for the suspicious comment around line 1751: `Wrong - should use eax not ecx`.
- [ ] Turn that comment into either a fix, a test, or remove it if false.
- [ ] Add xHCI tests for multiple devices/ports if QEMU can emulate them.
- [ ] Add USB malformed descriptor fixtures and expected parser outcomes.
- [ ] Add HID parser tests for report sizes 0, 1, 8, 16, 32, and greater than 32 bits.
- [ ] Add HID parser tests for long items and truncated items.
- [ ] Add I2C HID timeout tests.
- [ ] Add SPI HID timeout tests.
- [ ] Add battery driver fallback tests for layout A/B detection.
- [ ] Audit all driver functions for callee-saved register preservation.

## P1: Boot And Memory

- [ ] Decide whether dead `memory_init` in `src/kernel/core/memory.asm` should be deleted or wired into `kmain`.
- [ ] If wired in, ensure it consumes the real E820 map instead of stale assumptions.
- [ ] Add boot marker for memory map parse success/failure.
- [ ] Add a test for low-memory BIOS profile and UEFI OVMF floor separately.
- [ ] Reduce fixed-address duplication where possible.
- [ ] Move fixed address ownership into fewer include files.
- [ ] Expand invariant checks for every fixed address listed in the complexity dashboard.
- [ ] Verify `APP_DATA_ADDR`, syscall stacks, GUI buffers, FAT buffers, and boot buffers cannot overlap under BIOS and UEFI profiles.

## P2: GritHL

- [ ] Use `docs/ghl-beyond-zero-trust-todo.md` as the master plan for the
      GHL-only beyond-zero-trust architecture: no new `.asm`, no new `.inc`, no
      inline assembly, signed everything, release privacy by default, and
      partitioned authority that survives single-component compromise.
- [ ] Add compiler tests for `src/user/grithl/compiler/gritc.py`: lex, parse, sema, emit.
- [ ] Add golden output tests for `hello.ghl`, `explorer.ghl`, and `notepad.ghl`.
- [ ] Add source maps from GHL lines to generated assembly labels.
- [ ] Add better compiler errors with line/column context for semantic failures.
- [ ] Define what `app "<Name>" { stack = N }` currently does vs future loader behavior.
- [ ] Add support or explicit rejection tests for reserved syntax like arrays.
- [ ] Validate generated callbacks always return through the expected L3 path.
- [ ] Add a generated-app ABI manifest and validate it against `docs/app-loader-format.md`.

## P2: GUI And User Experience

- [ ] Verify Notepad insert/delete/save/open visually in QEMU screenshots.
- [ ] Verify Explorer launch, open file, directory navigation, and repeated open/close.
- [ ] Verify Terminal accepts input without stale repeat bytes.
- [ ] Add screenshot-based smoke tests for desktop icons and windows.
- [ ] Add screenshot-based test for dragging a window and verifying content follows.
- [ ] Add screenshot-based test for focus changes.
- [ ] Add screenshot-based test for close button behavior.
- [ ] Add redraw invalidation tests: overlapping windows, taskbar, cursor restore.
- [ ] Improve UI polish after correctness: text clipping, active window state, basic scroll indicators.

## P2: Documentation

- [ ] Update `docs/verification.md` with the current full stage list, including Explorer marker validation.
- [ ] Add a "known flaky/generated outputs" section explaining which tests rewrite `build`.
- [ ] Update `docs/audit-checklist.md` with the current SMP failure status.
- [ ] Promote recurring audit findings into permanent check scripts where practical.
- [ ] Document L3 slot memory layout with an ASCII map.
- [ ] Document app lifecycle once decided.
- [ ] Document current monolithic app limitation and exact migration path to external app packs.
- [ ] Add troubleshooting docs for QEMU serial marker failures.

## P2: Repo Hygiene

- [ ] Decide whether generated build artifacts should be tracked or ignored.
- [x] Clean up accidental `NUL`/`null` files if they are not intentional.
- [x] Separate `Unrelated` Kinect files from the OS repo or document why they live here.
- [x] Add a script that reports dirty generated files separately from dirty source files.
- [ ] Normalize line endings for source and generated files.
- [ ] Consider putting QEMU logs under a dedicated ignored `build/logs` folder.
- [ ] Add a short before-commit checklist: full verify, security probe, screenshot sanity, git diff source-only.

## P3: Stretch Goals

- [ ] External app packer instead of built-ins linked into the kernel image.
- [ ] Real process scheduling beyond callback-style ring-3 execution.
- [ ] Per-process address spaces or at least stronger per-slot isolation.
- [ ] User-mode fault recovery: kill bad app/window instead of freezing OS.
- [ ] Basic executable loader format based on `docs/app-loader-format.md`.
- [ ] More filesystem support: subdirectory writes, larger files, maybe FAT32 later.
- [ ] Better hardware matrix: QEMU BIOS, QEMU UEFI, real laptop, USB keyboard/mouse, touchpad.
- [ ] Automated screenshot diffing for GUI regressions.
- [ ] A compact kernel panic screen with exception vector, RIP, slot, syscall number, and current app.
