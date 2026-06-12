# GritHL Boot Conversion Boundary

Status: boot target landed; first production I/O leaf migrated
(`src/boot/ghl/a20_wait.ghl`, 2026-06-03); full boot-file migration ladder below.

The active GritHL/GritHLK compiler (`src/user/grithl/compiler/gritc.py`) now
has an explicit `--target boot` mode. It forbids inline `asm {}` by default and
supports:

- `bits 16`, `bits 32`, and `bits 64` output modes
- `org` and exact flat-binary offsets
- structured 16/32/64-bit boot functions for the current safe subset
- explicit-register BIOS-style call sites
- BIOS interrupts via `intn(vector)`
- port I/O via `inb` / `outb`
- segment loads and `lgdt`
- boot-sector padding and signatures via `pad_to` and `boot_signature`

The following production files should remain audited assembly until each has a
byte or behavior parity fixture and has been migrated module-by-module:

- `src/boot/mbr.asm`
- `src/boot/stage2.asm`
- `src/boot/a20.asm`
- `src/boot/vesa.asm`
- `src/boot/paging.asm`
- `src/boot/gdt.asm`
- `src/boot/uefi_loader.asm`
- `src/boot/boot.asm`

A maintainable conversion must keep using first-class boot-language features
instead of wrapping these files in large `asm {}` strings. Current compile gates
live in `scripts/test/test_gritc_security.ps1`, including a NASM-assembled
512-byte boot-sector fixture.

## First migrated leaf (2026-06-03)

`src/boot/ghl/a20_wait.ghl` is the first production-representative boot leaf
re-expressed as zero-asm GritHL. It covers the *pure port-I/O* parts of
`a20.asm`: the 8042 keyboard-controller status polls (`a20_wait_kbd_in`,
`a20_wait_kbd_out`) and the port-`0x92` fast-A20 enable (`a20_fast_enable`).
It compiles under `--target boot --forbid-asm`, declares `unsafe boot_io`
(so `--deny-unsafe` rejects it as an audited hardware boundary), and NASM-
assembles. Gated by `tests/ghl_boot/a20_wait.ghl` in `test_gritc_security.ps1`
(compile + assemble + deny-unsafe rejection). It is **not yet wired into the
live boot** - the rest of `a20.asm` (`check_a20`) needs segment-override memory
access, which the boot target cannot emit (see the feature ladder below).

## Phase 3 - module-by-module migration order + required compiler features

Migration runs strictly leaf-up, easiest first, each step gated by a fixture and
a parity check (byte-identical where layout is fixed; deterministic serial
behavior where instruction identity legitimately changes). The compiler features
are added narrow + argument-checked + `--target boot`-gated + documented in
`docs/grithl-security-model.md` BEFORE use in production boot code.

### Compiler feature ladder (smallest missing first)

1. **Segment-override memory load/store** - `seg_load8(seg, off)` /
   `seg_store8(seg, off, val)` emitting `mov al,[es:di]` style accesses under a
   new `unsafe seg_mem;` capability. Blocks: `check_a20` (`[es:di]`/`[ds:si]`
   wrap test), VESA info-block field reads. *Fixture:* `seg_mem.ghl` - round-trip
   a byte through `0x0000:di` and `0xFFFF:si`, assemble, byte-check.
2. **FLAGS save/restore** - `pushf()`/`popf()` intrinsics. Blocks: `check_a20`
   (preserves caller FLAGS). *Fixture:* assemble + opcode-check `9C`/`9D`.
3. **String/data emit + BIOS teletype print helper** - a `db`-string data record
   already exists; add a structured 16-bit print loop calling INT 10h. Blocks the
   `msg_*` failure paths in `a20.asm`/`vesa.asm`/`stage2.asm`.
4. **Disk Address Packet (DAP) typed record + INT 13h AH=42h** - Blocks
   `stage2.asm` kernel load (`kern_dap`). *Fixture:* emit a 16-byte DAP, field-
   offset check.
5. **Far mode-switch path** - `farjmp` exists for the 16->32 bit transition;
   extend with protected-mode entry prologue (CR0.PE set + flush) so `stage2.asm`
   PM/LM switch is expressible. *Fixture:* assemble a minimal real->PM stub.
6. **`lidt`/`ltr` + control-register intrinsics for 64-bit** - `write_cr0/cr3/cr4`
   already exist in kernel mode; expose under `--target boot` with `unsafe
   boot_lgdt;`-style caps. Blocks the 64-bit paging/LM entry in both loaders.
7. **PE/COFF image-header emit + `.reloc` section + UEFI MS-x64 call ABI** - the
   largest item; needed for the UEFI loader. Add a typed `pe_image { ... }`
   record (header fields named, not magic) and a `uefi_call(fn, a, b, c, d)`
   intrinsic that lays down the rcx/rdx/r8/r9 + 32-byte shadow-space MS-x64 ABI.
   *Fixtures:* a PE header whose bytes match the current hand-built one; a
   `uefi_call` shadow-space layout check.

### BIOS path migration order (build_bios.ps1 artifacts)

| # | Module | Needs features | Parity |
|---|---|---|---|
| 1 | `a20.asm` I/O leaf (done) | inb/outb/while/& (have) | assemble + gate |
| 2 | `a20.asm` `check_a20` | (1) seg_mem, (2) pushf/popf | byte vs current `a20.asm` |
| 3 | `vesa.asm` | (1) seg_mem, (3) print, intn | serial: mode-set reached |
| 4 | `gdt.asm` data tables | typed descriptor records | byte-identical (data only) |
| 5 | `paging.asm` | (6) cr3/paging intrinsics, named PT bases (have) | byte-identical |
| 6 | `stage2.asm` | (3)(4)(5) DAP + PM/LM switch | serial milestones `2..8` |
| 7 | `mbr.asm` | (4) DAP, boot_signature (have) | byte-identical (512 B) |

### UEFI loader migration order (BOOTX64.EFI)

The UEFI loader is gated entirely behind feature (7). Order once it lands:
`uefi_loader_data.inc` (GDT/GUID/string data - typed records, byte-identical) →
`uefi_loader_pe.inc` (PE header via `pe_image`) → `uefi_loader_defs.inc`
(constants already named in `src/include/uefi_abi.inc`) → graphics/files/storage
(UEFI protocol calls via `uefi_call`) → entry/paging_exit/trampoline (mode switch
+ paging) last. Each step holds BOOTX64.EFI byte-identical where the layout is
fixed, otherwise QEMU serial-milestone parity.

### Security invariants the conversion MUST preserve (tie to security_todo.md)

Every migrated module must keep all existing boot-time isolation intact - W^X/NX
per page, SMEP/SMAP, page-table permission split (supervisor vs USER arena),
per-slot stack guard pages, KASLR slide, and the fail-closed storage contract.
The capability model makes this *stronger*, not weaker: a compromised boot leaf
declared `unsafe boot_io` cannot reach memory it never declared, and
`--deny-unsafe` keeps non-boundary modules free of any hardware authority. See
`docs/grithl-security-model.md` for the per-intrinsic rationale.
