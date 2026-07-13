# Boot-progress block tracer (`-BootTrace`)

A debug-only visual tracer for **pre-GUI freezes / halts on real hardware**. It
paints a marching grid of colored squares to the GOP framebuffer, one per boot
stage. When the machine hangs before the desktop appears, **the last (rightmost,
lowest) block painted is the last stage that *completed*** — the very next stage
is where it wedged.

It needs no serial cable, no debugger: you read it off the screen.

## Enabling

```powershell
scripts\build\build_uefi.ps1 -BootTrace
```

`-BootTrace` defines `GRIT_BOOT_TRACE` for both the loader and the kernel. It is
**debug-only** (refused with `-Release`). Without the flag every hook compiles to
nothing, so default/release images are unchanged.

## What you see

Two horizontal bands of ~18 px squares near the top-left of the screen:

| Band | Painter | Position | Source |
|------|---------|----------|--------|
| **Top** (y=4)     | UEFI loader (`BOOTX64.EFI`) | one row | `src/boot/uefi_loader_boottrace.inc` |
| **Lower** (y≥30)  | kernel `kmain`             | wraps to extra rows as needed | `src/kernel/grithlk/boot_timing.ghl` |

Blocks march left→right (wrapping down). Color cycles every 8 (red, orange,
yellow, green, cyan, blue, magenta, white) purely to make counting easier — the
**position/order** is the signal, not the hue.

Each kernel block corresponds 1:1 with a serial `[xx]` marker (COM1), so if you
*do* have serial, the two-char tag is the authoritative stage id. The visual
block is the no-serial fallback.

> **Composite-wipe note:** a full-screen frame composite clears the band, after
> which later blocks repaint. The first composite is `display_flip` (kernel block
> "Df"); the next is the first `render_frame` ("L2"). So at a freeze you may not
> see the *earliest* blocks (wiped by the most recent composite), but the
> **rightmost/last block is always the last completed stage** — which is the
> thing you're after. A freeze itself stops all composites, so nothing erases the
> final state.

## Loader band (top row) — order

| # | Stage finished |
|---|----------------|
| 0 | GOP framebuffer ready (`gop_init`) |
| 1 | boot-owned regions allocated |
| 2 | EFI_SIMPLE_POINTER_PROTOCOL located |
| 3 | `KERNEL.BIN` loaded |
| 4 | `DATA.IMG` ramdisk loaded |
| 5 | signed envelopes (`SYSSIG.ENV`/…) loaded |
| 6 | `DATA.IMG` LBA extents resolved |
| 7 | KASLR entropy captured |
| 8 | identity page tables built (`setup_paging`) |
| 9 | about to `ExitBootServices` (last loader FB draw before kernel handoff) |

If the top band stops before block 0, the hang is in the earliest loader steps
(watchdog disable / `claim_pages`) — before a framebuffer exists, so no block can
be drawn there; the serial `SER` markers (`E C F W T G S J`) still cover it.

## Kernel band (lower) — order

Block index ↔ serial tag ↔ stage. (Feature-gated stages — `Di/Df` need
`FEAT_DISPLAY_INIT`, `K9` needs `-BootAnim`, `FX` needs the FBPERF bench — drop
out when disabled, shifting later indices; the serial tag stays canonical.)

| # | Tag | Stage finished |
|---|-----|----------------|
| 0 | K0 | `kmain` entered, `memory_init` + `boot_features_init` |
| 1 | K1 | early CPU policy (SMAP/SMEP, CET detect) |
| 2 | K2 | app blob extent init |
| 3 | Di | `display_init` |
| 4 | Df | `display_flip` (first composite) |
| 5 | K3 | display ready + debug self-tests |
| 6 | Id | `idt_init` |
| 7 | Gd | `gdt64_init` |
| 8 | Ts | `tss_init` |
| 9 | Cy | `kernel_canary_init` |
| 10 | Ch | `slot_cap_hmac_init` |
| 11 | N4 | Track-4 nx self-tests |
| 12 | K4 | descriptors/canary/cap-HMAC ready |
| 13 | MD | `measured_boot_init` |
| 14 | Am | `app_manifest_verify` |
| 15 | As | `app_segment_verify` |
| 16 | Gi | `gate_device_id_init` |
| 17 | Fl | `floor_store_load` |
| 18 | Gt | `gate_time_set` (clock high-water + RTC) |
| 19 | K5 | verifier context ready; crypto offloaded |
| 20 | Ss | syscall-stack guard PTs |
| 21 | Si | `syscall_init` |
| 22 | K6 | syscall path initialized |
| 23 | Sc | `scheduler_init` |
| 24 | Pc | `pic_init` |
| 25 | Pt | `pit_init` |
| 26 | Ml | `mmio_register_lapic` |
| 27 | K7 | scheduler/timer/MMIO pre-IRQ done |
| 28 | RD | ramdisk registered |
| 29 | FF | FAT16 cache fill done |
| 30 | St | `sti` — interrupts live |
| 31 | Kb | `keyboard_init` |
| 32 | K8 | storage/input ready |
| 33 | K9 | boot animation returned (`-BootAnim` only) |
| 34 | AC | `acpi_init` |
| 35 | AP | `apic_init` |
| 36 | IO | `ioapic_init` |
| 37 | SP | `spi_init` |
| 38 | SH | `spi_hid_init` |
| 39 | R9 | `rtl8139_init` |
| 40 | FB | FBPERF WC arm/activate |
| 41 | L0 | SMP workqueue + APs up |
| 42 | DJ | device-enum job dispatched (async, on an AP) |
| 43 | K5 | signed-verify job dispatched (async, on an AP) |
| 44 | Pd | `perfdiag_init` |
| 45 | Ri | `render_init` |
| 46 | Ci | `cursor_init` |
| 47 | WM | `wm_init` |
| 48 | L1 | **GUI initialized** |
| 49 | Ca | `cpu_acct_init` |
| 50 | L2 | first frame rendered (composite) |
| 51 | FX | 64-flip FBPERF bench (debug + bench feature) |
| 52 | DW | device-enum job joined |
| 53 | KW | K5 signed-verify job joined (fail-closed) |
| 54 | L3 | kernel lockdown complete |
| 55 | L4 | security-status snapshot |

### `measured_boot_init` sub-blocks (debug pinpointing)

To bisect a real-hardware wedge that stops on the **second cyan block (`K4`)**, the
single `MD` stage is now preceded by five fine-grained sub-blocks painted from
*inside* `measured_boot_init` (`src/kernel/grithlk/crypto.ghl`). They exist only
in `-BootTrace` builds and shift the indices of every block from `MD` onward by 5.

| after `K4`, square # | tag | painted once this sub-step COMPLETED |
|----------------------|-----|--------------------------------------|
| 1 | `m0` | entered `measured_boot_init` (past the `mb_done` guard) |
| 2 | `m1` | `sha256_self_test` KAT passed |
| 3 | `m2` | span 1 hashed (`_start` → `app_blob_start`) |
| 4 | `m3` | span 2 hashed (`app_blob_end` → `_kernel_text_end`) |
| 5 | `m4` | signed app-manifest folded |
| 6 | `MD` | `measured_boot_init` returned (final digest) |

**Reading it:** count how many squares appear *after* the second cyan (`K4`):

* **0 more** (still stops on `K4`) → the wedge is *before* `measured_boot_init`
  runs — i.e. not inside it; look between the `K4` mark and the call site.
* stops on **`m0`** → `sha256_self_test` (KAT) hangs/panics.
* stops on **`m1`** → span-1 read faults (low kernel text not mapped on real HW).
* stops on **`m2`** → span-2 read faults (text *after* the app blob not mapped —
  the most likely loader page-coverage / KASLR-relocation gap).
* stops on **`m3`** → app-manifest table read faults.
* stops on **`m4`** → `sha256_final` (no memory reads; would point elsewhere).
* **`MD` and beyond appear** → `measured_boot_init` is NOT the culprit; the freeze
  is a later stage.

After L4 the free-running main loop starts and `render_frame_guarded` composites
every iteration, so the band is overwritten by the live desktop — by then the
GUI is up and pre-GUI freeze tracing no longer applies.

## How it works

* Geometry (fb base / width / pitch) is read straight from the loader handoff
  block `VBE_INFO_ADDR = 0x9000`, so the painter works from the very first
  `kmain` stage — it needs no display driver state.
* Kernel: `boot_block_next()` is called from `boot_mark()`
  (`boot_timing.ghl`), the single chokepoint every kernel stage already routes
  through (`bootlog2` → `boot_mark`, plus all the direct `boot_mark` tags). Block
  painting happens *before* the timing-table cap, so blocks keep marching even
  past `MAX_MARKS`.
* Loader: the `BOOTBLK` macro (`uefi_loader_defs.inc`) calls `bootblk_next`
  (`uefi_loader_boottrace.inc`), which saves/restores every register + flags.
* To add a finer marker, drop a `boot_mark('X','y')` in `kmain` (kernel) or a
  `BOOTBLK` after a `call` in `uefi_loader_entry.inc` (loader). Keep loader/kernel
  geometry constants (`BT_BLK_SIZE=18`, `BT_BLK_STRIDE=22`) in lockstep.
