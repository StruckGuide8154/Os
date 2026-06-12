---
name: amd-dcn-probe-prereq
description: "amd_dcn_probe is a prerequisite for gfx_bringup (PCI MEM-decode + BAR0 UC alias), not a diag - never gate it behind -DiagLegacy."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5f5a1cc7-7a3e-42dc-8c07-3bff95d5ebfa
---

`amd_dcn_probe` in [src/kernel/drivers/amd_dcn.asm](../../src/kernel/drivers/amd_dcn.asm)
does TWO things the SMN proxy depends on, even though its name says "probe":

1. **Enables PCI MEM-decode + bus-master** on the AMD display device's
   Command register. Without bit 1 set, the BAR0 register window is dead
   - reads return `0xFFFFFFFF`, writes black-hole.
2. **Installs the UC alias** for BAR0 at `AMD_DCN_UC_VBASE` (covers 8 MiB
   including the NBIO INDEX2/DATA2 pair at `BAR0+0x38/0x3C`).

`gfx_bringup` and everything downstream (`smn_r32/w32`, `smu_msg_send`,
`gmc_init`, `cp_ring_alloc`) **cannot work without both**. The GFX MMIO
helpers read raw `amd_display_bar0` - they do not set up decode or UC
themselves.

## The trap

The 2026-05-25 DMUB-park commit wrapped the diag block (which contained
the `call amd_dcn_probe` site) in `%ifdef GRIT_DIAG_LEGACY`. With
`-Gfx` alone, `amd_dcn_probe` then never ran, every SMN read returned
`0xFFFFFFFF`, and stage H died with `smu=FFFFFFFF test=0`. Looked
exactly like "NBIO proxy wedged" or "MP1 base wrong" - neither was true.

## Symptom recognition

If `c2p90=FFFFFFFF c2p66=FFFFFFFF c2p82=FFFFFFFF` on a boot that
previously reached state=4, with BAR0 and PCI id matching the verified
baseline: **first suspect is "amd_dcn_probe not called", not the SMN
base or proxy logic.**

## Fix shape

`main.asm` now calls `amd_dcn_probe` unconditionally inside the
`%ifdef GRIT_GFX_BRINGUP` block, right before `call gfx_bringup`.
Don't move it back into a diag-only gate. If the diag block gets
refactored, the bring-up call site stays put.

## Related

- [[feedback_mp1_base_verified]] - don't "fix" MP1 base from Linux headers.
- [[amd_dcn_bar0_uc]] - the UC alias mechanism itself.
- `docs/gpu-bringup-verified.md` - the canonical state=4 baseline.
