---
name: feedback-mp1-base-verified
description: "Strix Point MP1 SMN base is 0x03B10000 - verified on hardware; do not \"fix\" it against Linux yellow_carp_offset.h tables."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 763eb8e5-03f4-445b-bb1e-05093d3c086b
---

On Strix Point (gfx1150, Acer Nitro V16) the SMU MP1 SMN base is **0x03B10000**.
This is empirically verified - the verified baseline at `docs/gpu-bringup-verified.md`
reaches `state=4` with this base and shows `c2p90=00000013` (DisallowGfxOff echo).

**Why:** I once "corrected" it to `0x0243FC00` based on `yellow_carp_offset.h`
(`MP1_BASE__INST0_SEG1`, with `regMP1_SMN_C2PMSG_66_BASE_IDX = 1`). User reverted
with a strong note: 0x0243FC00 is MP0/PSP territory on this SKU, and touching MP1
at the PSP base produces silence. The Linux header→SEG mapping for SMN bases is
not a reliable source of truth on its own - the value that actually answers is
the one verified on silicon.

**How to apply:** Before changing `MP1_BASE_SMN` in [amd_smu.asm](../../src/kernel/drivers/gpu/amd_smu.asm),
check `docs/gpu-bringup-verified.md`. If the verified doc names a value, that's
canon. Same applies to MP0/PSP base - verify on hardware, not from header tables.

If `smu=FFFFFFFF` shows up on a new boot, first hypothesis should be **NBIO SMN
proxy not routing** (or a different machine than the verified one - check BAR0
and PCI id), not "the base is wrong." Related: [[fbperf_wc_landed]].
