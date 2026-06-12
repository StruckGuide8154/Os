# GritOS Ownership Registry

This page is normative for maintainer routing. Use it before editing a subsystem.

| Area | Owner File | Guard |
|---|---|---|
| Kernel build map | `src/kernel/kernel_build.asm` | `tools/generate_source_map.ps1` |
| L3 callback entry/return | `src/kernel/proc/usermode.asm` | `scripts/test/test_source_guards.ps1` |
| L3 runtime frame offsets | `src/include/l3_runtime.inc` | `tools/check_invariants.ps1` |
| Syscall entry/dispatch | `src/kernel/proc/syscall.asm` | `scripts/test/test_source_guards.ps1` |
| Syscall validation | `src/kernel/proc/syscall_validation.inc` | `scripts/test/test_source_guards.ps1` |
| Process records | `src/kernel/proc/process.asm` | `tools/check_invariants.ps1` |
| User slot memory | `src/include/constants.inc` | `tools/check_invariants.ps1` |
| Paging user/kernel split | `src/boot/paging.asm` | `scripts/test/test_source_guards.ps1` |
| Window structure offsets | `src/include/window_layout.inc` | `tools/check_invariants.ps1` |
| Window manager | `src/kernel/gui/window.asm` | `tools/check_complexity_thresholds.ps1` |
| FAT16 operations | `src/kernel/fs/fat16.asm` | `tools/check_complexity_thresholds.ps1` |
| Cache32Max boot profile | `scripts/test/test_cache32_boot.ps1` | `scripts/test/test_verify_all.ps1` |
| SMP serial markers | `scripts/test/test_smp_boot.ps1` | `scripts/test/test_verify_all.ps1` |

Every structural edit must run `scripts/test/test_verify_all.ps1` before the next split.
