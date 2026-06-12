# Grit Verification

This page is normative for structural edits.

Run `scripts/test/test_verify_all.ps1` after any include graph, L3, syscall, GUI, filesystem,
boot, driver, Cache32Max, or SMP change.

## Current Stages

1. Source guards
2. Generated source map
3. Complexity dashboard
4. Invariant registry
5. Docs references
6. Complexity thresholds
7. Ownership registry
8. BIOS debug build
9. BIOS release build
10. UEFI debug build
11. UEFI release build
12. UEFI smoke boot
13. L3 app marker validation
14. Cache32Max BIOS boot
15. SMP marker validation

## Serial Gates

- `scripts/test/test_smoke_uefi.ps1` checks boot, CPU/cache/memory, GUI, and marker output.
- `scripts/test/test_l3_app_markers.ps1` launches Notepad through serial, sends text input,
  and requires app launch, success return, and L3 callback markers.
- `scripts/test/test_cache32_boot.ps1` checks the strict 32MB BIOS profile.
- `scripts/test/test_smp_boot.ps1` validates SMP marker counters from the Cache32Max log.
