# Mathematical Fault Checks

`tools/security/check_mathematical_faults.ps1` runs a deterministic scanner for
faults that follow directly from source/build math. It is intentionally not a
heuristic audit: a finding is emitted only when the checker can name the trigger,
the CPU/security fault, the evidence, and the fix.

Current model:

- L3 app W^X manifest fail-closed behavior.
- Default v1 manifest installation for every copied slot.
- Embedded GritHL app writable data placement in `.appdata`.
- Restoration back to `.text` after generated `.appdata`/`.bss`.
- App blob framing: page-aligned start, page-aligned `app_blob_code_end`, and
  `.appdata` inside `[app_blob_start, app_blob_end)`.
- Built `APPS.BIN` size against `L3_APP_BLOB_PLACE_CAP`, using the release
  artifact at `build/esp/EFI/BOOT/APPS.BIN` when present.
- Slot-local public buffer intervals against `APP_SLOT_SIZE`,
  `L3_SLOT_USER_STACK_GUARD_OFF`, and each other.
- Literal GritHL `/ 0` and `% 0` expressions.
- Straight-line assembly `div`/`idiv` by a register proven zero immediately in
  the same block.
- Optional NASM listing geometry: if a fresh listing with `app_blob_code_end` is
  available, registered callback symbols are checked against the executable code
  window so an NX instruction-fetch fault is caught before QEMU.

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/security/check_mathematical_faults.ps1
```

Useful report formats:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/security/check_mathematical_faults.ps1 -Format markdown -Output build/mathematical_faults.md
powershell -NoProfile -ExecutionPolicy Bypass -File tools/security/check_mathematical_faults.ps1 -Format json -Output build/mathematical_faults.json
```

Exit code is `0` only when no mathematically triggerable faults are found.
