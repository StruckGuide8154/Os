# Grit External App ABI and Loader Format

This is the next-step contract for turning the current built-in app layer into a
real external app model without rewriting the syscall boundary again.

## Goals

- Keep the current syscall ABI stable for both built-ins and external apps.
- Let future apps be authored in assembly or an assembly-targeting HLL.
- Avoid exposing kernel virtual addresses as part of the app contract.

## Proposed binary shape

Use a flat binary with a small fixed header followed by code/data.

### Header

Offset `0x00`
- Magic: `GRSAPP64`

Offset `0x08`
- ABI version (`u16`)

Offset `0x0A`
- Flags (`u16`)

Offset `0x0C`
- Total image size (`u32`)

Offset `0x10`
- Entry RVA (`u32`)

Offset `0x14`
- Draw callback RVA (`u32`, optional, `0` if none)

Offset `0x18`
- Click callback RVA (`u32`, optional, `0` if none)

Offset `0x1C`
- Key callback RVA (`u32`, optional, `0` if none)

Offset `0x20`
- Right-click callback RVA (`u32`, optional, `0` if none)

Offset `0x24`
- Drag callback RVA (`u32`, optional, `0` if none)

Offset `0x28`
- Requested stack size (`u32`)

Offset `0x2C`
- Reserved

## Loader rules

1. Read the binary into a per-app slot arena.
2. Verify magic and ABI version.
3. Reject images larger than `APP_SLOT_SIZE`.
4. Rebase callback RVAs against the slot base.
5. Install only validated callback targets through the same rules already used
   by syscall validation.
6. Keep kernel objects out of the app image; only the slot arena is app-owned.

## Callback contract

The callback names used today are the contract future HLL output should target:

- `draw`
  Input: `RDI = shadow window pointer`
- `click`
  Input: `RDI = shadow window pointer`, `RSI = mouse x`, `RDX = mouse y`
- `key`
  Input: `RDI = shadow window pointer`, `RSI = key value`
- `right_click`
  Input: `RDI = shadow window pointer`, `RSI = mouse x`, `RDX = mouse y`
- `drag`
  Input: `RDI = shadow window pointer`, `RSI = mouse x`, `RDX = mouse y`

Callbacks return with `ret`. If an app deliberately exits through the
trampoline, it uses `SYS_APP_DONE`.

## Includes for app authors

Minimum include set:

- `src/user/lib/grit_app.inc`
- `src/user/lib/grit_window.inc`

This keeps the syscall numbers and window/app constants stable for both
handwritten assembly and future code generators.

## What remains to implement

- A file-to-slot loader in `src/kernel/proc`
- Optional relocation support beyond simple RVA rebasing
- A tiny app registry / launcher that can enumerate external app binaries
- Packaging docs for the future assembly-based HLL toolchain
