# GritHL Zero-Asm Roadmap

Goal: all maintained OS code should be expressible in GritHL/GritHLK without
source-level `asm {}` escape blocks.

## Non-negotiable Rules

- New migrated modules should compile with `gritc.py --forbid-asm`.
- Security-critical modules should also compile with `--deny-unsafe` unless
  they are a deliberately audited hardware/boot boundary.
- Boot-target modules compile with `--target boot`, which forbids inline asm by
  default.
- Privileged operations must be named intrinsics, not arbitrary text. Examples:
  `write_cr0`, `write_cr4`, `lgdt`, `lidt`, `ltr`, `intn`, `inb`, and `outb`.
- Dangerous primitives require explicit source declarations such as
  `unsafe boot_int;`, `unsafe boot_io;`, `unsafe kernel_priv;`, or
  `unsafe raw_mem;`. `--deny-unsafe` rejects those declarations.
- Unsupported execution modes must fail closed. The boot target now emits
  structured 16/32/64-bit functions for the safe subset covered by tests.

## Progress

- 2026-06-03: First production-representative **boot** leaf migrated -
  `src/boot/ghl/a20_wait.ghl` (A20 port-I/O: 8042 polls + fast-A20 enable).
  Compiles under `--target boot --forbid-asm`, rejected by `--deny-unsafe`
  (declared `unsafe boot_io` I/O boundary), NASM-assembles. Gated in
  `scripts/test/test_gritc_security.ps1`. Not yet wired into the live boot
  (rest of `a20.asm` needs segment-override memory access). The live UEFI
  loader + BIOS path also had every in-code magic literal named into
  `src/include/uefi_abi.inc` + `bios_boot.inc` (byte-identical; see
  `docs/maintainability-todo.md` §2 note 3). Full module-by-module conversion
  order and the compiler-feature ladder are in `docs/grithl-boot-conversion.md`.

- 2026-06-05: **Driver-core migration scoped; first kernel block/atomic intrinsics
  landed.** An attempt to migrate the six oversized drivers
  (`rtl8156`/`xhci`/`display`/`usb_hid`/`i2c_hid`/`fat16`) into GritHLK found that
  only *leaf helpers* are portable today (the `usb_hid_helpers.ghl` pattern); the
  hardware *cores* hit missing codegen. Gap analysis + the new intrinsics are in
  "Driver-core codegen gap" below. Added `rep_stosd` / `rep_movsd` (dword block
  fill/copy) and `atomic_xchg` (LOCK'd dword exchange - the spinlock primitive),
  all `--target kernel` + `kernel_priv`, covered by
  `tests/ghl_kernel/noasm_intrinsics.ghl`. Purely additive: `KERNEL.BIN` sha256
  unchanged, full build green, `test_gritc_security.ps1` green.
- 2026-06-05 (later): **SSE2/XMM data-path model landed** - `xmm_loadu`/`xmm_loada`/
  `xmm_store`/`xmm_store_nt`/`xmm_bcast32` (statement-form, bare xmm operand) +
  `isqrt`. This clears the last codegen blocker for porting `display` (and the GUI
  blit paths). All new intrinsics are kernel-mode-only by interception (they fall
  through to normal function resolution in `--target user`, which fixed a collision
  with an app-defined `isqrt`). Build green, `KERNEL.BIN` sha256 still unchanged
  (`B87BD36...`), `test_gritc_security.ps1` green. See "Driver-core codegen gap".

## Driver-core codegen gap (what blocks "drivers in only GHL")

The six driver cores need codegen that does not yet exist. Mapped to drivers,
worst-first:

1. **SSE2 / XMM data path** - `display.asm` is ~99% non-temporal VRAM blits
   (`movntdq`/`movdqa`/`pshufd`/`rep stosd` fills). **Landed 2026-06-05.** Rather
   than a full XMM type/register model (a large change to the GP-accumulator stack
   machine), the SSE2 ops are exposed as statement-form intrinsics that take a
   bare xmm register name - the same explicit-register discipline as
   `push_reg`/`set_reg`. The loop structure stays ordinary GHL `while`/`if`.
   Intrinsics: `xmm_loadu(XMM,addr)` (`movdqu`), `xmm_loada` (`movdqa` load),
   `xmm_store(addr,XMM)` (`movdqa` store), `xmm_store_nt(addr,XMM)` (`movntdq`
   non-temporal - pair the loop with `sfence()`), `xmm_bcast32(XMM,val32)`
   (`movd`+`pshufd`, the dword broadcast for fills). The 16-byte alignment contract
   of `movdqa`/`movntdq` is the author's responsibility (same as the driver). A
   compile test reproduces display's 128-byte streaming copy + broadcast fill loops
   and emits the identical mnemonic set. `rep_stosd` covers the simple dword fill.
   These also unblock the GUI blit fast paths.
2. **Scalar floating point** - `display` `fill_circle` uses `sqrtsd`/`cvttsd2si`.
   **Landed** (`isqrt(n) -> floor(sqrt(n))`, the cvtsi2sd/sqrtsd/cvttsd2si idiom;
   exact for n < 2^52, clobbers xmm0). Kernel-only (falls through to a normal
   function call in `--target user`, since user apps may define their own `isqrt`).
3. **Atomic / lock primitives** - `display` `raster_select_*` spinlocks. **Landed**
   (`atomic_xchg`). A `lock`-prefixed `atomic_add`/`cmpxchg` may follow if other
   drivers need them.
4. **Dword block fill/copy** - fills and ring copies. **Landed** (`rep_stosd`,
   `rep_movsd`; `rep_movsq` already existed).
5. **Everything else (MMIO state machines)** - `xhci`/`i2c_hid`/`rtl8156` cores are
   already expressible with existing primitives (`lw`/`sw` are 32-bit MMIO
   load/store, `inb`/`outb`/`ind`/`outd`, `lb`/`lq`/`sb`/`sq`). These are blocked on
   *effort/parity-risk* (large boot-path-sensitive state machines), not on missing
   codegen - port them incrementally behind serial-parity once SSE2 unblocks the
   GUI/display thrust.

Order of attack: ~~(1) XMM model → unblocks `display` + GUI~~ **DONE** (2026-06-05;
items 1-4 above all landed); then the incremental behavior-parity port of
`display` itself (write the blit/fill loops in GHL using the new intrinsics,
verify against serial/screendump), followed by the MMIO drivers. The codegen
floor for "drivers in only GHL" is now reached - what remains is the per-driver
parity-port effort, not missing compiler primitives.

## Compiler Track

1. Keep `--forbid-asm` green for all new GritHLK modules.
2. Replace existing asm-shim clusters with explicit-register functions and
   named intrinsics.
3. Grow first-class boot codegen beyond the current safe subset:
   far mode-switch paths, PE/COFF headers, relocation tables, disk-address
   packet declarations, and richer typed data records.
4. Convert boot files module-by-module with byte or deterministic serial parity
   tests before deleting the source assembly.
5. Make `--forbid-asm` the default for `--target kernel` after legacy modules
   have migrated. Keep an explicit legacy escape flag only for archaeology.

## Verification Track

- Compile gates:
  `scripts/test/test_gritc_security.ps1` covers zero-asm enforcement, boot layout
  emission, low-level intrinsic compilation, structured real-mode functions,
  unsafe-capability rejection, and a NASM-assembled 512-byte boot sector ending
  in `55 AA`.
- Migration gates:
  each converted module should have either byte-identical output where layout is
  fixed, or deterministic serial behavior comparison where instruction identity
  is intentionally allowed to change.
- Security review:
  new intrinsics must be narrow, argument-checked, target-gated, and documented
  here before use in production boot/kernel modules.
