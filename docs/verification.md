# Grit Verification

This page is normative for structural edits.

Run `scripts/test/test_verify_all.ps1` after any include graph, L3, syscall, GUI, filesystem,
boot, driver, Cache32Max, or SMP change.

## Current Stages

1. Source guards
2. Installable driver framework
3. XML/SVG contracts
4. GritHL XML/SVG fixtures
5. Generated source map
6. Complexity dashboard
7. Invariant registry
8. Docs references
9. Complexity thresholds
10. Ownership registry
11. BIOS debug build
12. BIOS release build
13. UEFI debug build
14. UEFI release build
15. UEFI smoke boot
16. L3 app marker validation
17. Explorer marker validation
18. Cache32Max BIOS boot
19. SMP marker validation

## Serial Gates

- `scripts/test/test_smoke_uefi.ps1` checks boot, CPU/cache/memory, GUI, and marker output.
- `scripts/test/test_l3_app_markers.ps1` launches Notepad through serial, sends text input,
  and requires app launch, success return, and L3 callback markers.
- `scripts/test/test_explorer_app_markers.ps1` launches Explorer through serial and requires
  app launch, success return, and L3 callback markers.
- `scripts/test/test_cache32_boot.ps1` checks the strict 32MB BIOS profile.
- `scripts/test/test_smp_boot.ps1` validates SMP marker counters from the Cache32Max log.

## Generated Outputs And Test Isolation

The full suite is not read-only. Builds and boot tests rewrite files under `build/`, including
BIOS and UEFI images, generated reports, and these serial logs:

- `build/smoke_uefi_serial.log`
- `build/l3_app_serial.log`
- `build/explorer_app_serial.log`
- `build/cache32_serial.log`

Treat those files as disposable test output. To separate generated changes from source changes,
run:

```powershell
.\tools\dev\report_dirty_files.ps1 -IncludeUntracked
```

The UEFI smoke, Notepad, and Explorer tests use serial TCP port `5555` and QEMU monitor port
`4444`. Run them serially, not in parallel. Their cleanup currently stops any
`qemu-system-x86_64` process, so close or save unrelated interactive QEMU work before starting
the full suite. The Cache32Max test is narrower and stops only the QEMU process that owns its
BIOS disk image.
