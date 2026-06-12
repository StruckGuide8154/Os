# Runtime boot-parameter feature toggles (BOOTCFG.TXT)

A per-boot, no-rebuild mechanism to disable kernel attack surface (drivers,
subsystems, individual syscalls) and to bisect live framebuffer/render bugs.

## Mechanism

* The UEFI loader reads the OPTIONAL ESP file `\EFI\BOOT\BOOTCFG.TXT` into
  firmware RAM (`load_bootcfg`, `src/boot/uefi_loader_files.inc`) and publishes
  `(base, size)` in the boot-info struct at the fixed identity-mapped address
  `VBE_INFO` (0x9000), offsets `VBE_BOOTCFG_BASE_OFF` (0x70) /
  `VBE_BOOTCFG_SIZE_OFF` (0x78). See `src/include/boot_memory.inc`.
* Early in `kmain` (right after `memory_init`), `boot_features_init()`
  (`src/kernel/grithlk/boot_features.ghl`) parses that text into a 64-bit
  `feat_mask` in kernel BSS.
* **Default = everything ON.** If the file is absent (`size == 0`) the mask
  stays all-ones and boot is byte-for-byte identical to before. Fail-safe.
* Each disabled feature is logged to COM1 as `[FEAT] <name>=off` before the
  `[K1]` boot marker, so a serial capture shows exactly what was active.

## File format

Line-oriented, forgiving (whitespace/CR skipped, unknown names ignored):

```
# comment line
disable=cursor,present,pacing     # turn OFF a comma list
enable=mouse                      # turn back ON
setmode=0                         # per-feature key=0/1
```

Feature names (case-insensitive): `cursor`, `present`, `pacing`, `mouse`,
`hid`, `setmode`.

## Gates wired today

| name      | bit | gates                                                            |
|-----------|-----|------------------------------------------------------------------|
| cursor    | 1   | per-frame cursor blit (`cursor.ghl cursor_draw`)                 |
| present   | 2   | whole per-frame present/refresh path (`frame_present render_frame`) |
| pacing    | 4   | `frame_pace_wait()` in the main loop (`kernel_lifecycle`)        |
| mouse     | 8   | `mouse_init()`                                                   |
| hid       | 16  | `usb_hid_init` / `i2c_hid_init` / `spi_hid_init`                 |
| setmode   | 32  | `SYS_DISPLAY_SET_MODE` syscall handler (representative gate)     |

## Adding a new gate (one-liner pattern)

1. Give it a bit in `boot_features.ghl` (and mirror in `boot_memory.inc`):
   `const FEAT_FOO = (1 << 9);`
2. Register the name in `ft_match_name`:
   `if ft_streq(p, &nm_foo) != 0 { return FEAT_FOO; }`
   (+ a `data nm_foo: ... ;` string).
3. At the call site:
   * GHLK:  `if feat_on(FEAT_FOO) != 0 { foo(); }`
   * asm:   `mov rdi, FEAT_FOO` / `call feat_enabled` / `test rax,rax` / `jz skip`
     (`feat_enabled` preserves all registers except RAX).

## Build-time fallback

`boot_features_init` also honours optional build defines so gates are testable
before the file path is proven on a platform:
`-dFEAT_DEFAULT_DISABLE_CURSOR` (and `_PRESENT`, `_PACING`, `_MOUSE`, `_HID`).

## FB-bug bisection result (1664x262 scanout clobber)

A/B screendump test (`scripts/test/agent2_fbtest.ps1`), build
`build_uefi.ps1 -NoSmap -NoCet -NoSyscallPerm -NoMemRandom`:

* Run A (`disable=cursor,present,pacing`): surface = **1664 x 262** (clobber
  STILL present; `[FEAT]` lines confirmed in serial, gates active).
* Run B (no BOOTCFG, all on): surface = **1664 x 262** (clobber present).

Both runs show correct `scr_width=0x780 (1920) / scr_height=0x4B0 (1200)` at
boot in the FBPERF dump, then the scanout is clobbered later. Conclusion:
**the per-frame cursor blit, the frame_present refresh path, and frame pacing
are EXONERATED** - disabling all three does not stop the clobber. The trigger
lies elsewhere (candidate next probes: the FBPERF WC arm/activate path, the
debug-only 64-flip `display_flip` bench `[FX]`, or `display_init` itself -
none of which are render_frame). Extend the toggle set to bisect those next.
