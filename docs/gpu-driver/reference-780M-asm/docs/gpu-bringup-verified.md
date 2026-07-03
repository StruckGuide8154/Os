# GFX11 bring-up - what verified on Strix Point hardware (2026-05-26)

Reference for tasks H/I/J that **landed on real silicon** - every value, offset,
and sequence that produced `state=4` on the Acer Nitro V16 (gfx1150) boot.

This file is canon. If something stops working in the future, diff what
you're doing against this list. If a Wave-3 attempt wedges anything, revert
to this baseline.

---

## Hardware target

| Field | Value |
|---|---|
| SoC | AMD Strix Point (Phoenix family successor) |
| GPU IP | GFX11.5 (gfx1150), GC 11.5 |
| BAR0 (physical) | `0x000000FA10000000` |
| BAR2 doorbell (physical) | `0x0000000000000000260010E0` (low 32 = `0x260010E0`) |
| Mapping | BAR0 mapped UC via PAT slot 2 by `amd_display.asm` |

---

## SMN proxy (the master key)

The single most important thing we learned: **on APU, the SMU and PSP are
not in BAR0**. They sit on the SoC fabric and are reached via the NBIO
indirect-access pair inside BAR0.

| Register | BAR0 byte offset | BAR0 dword offset |
|---|---|---|
| `BIF_BX0_PCIE_INDEX2` | `0x38` | `0x0E` |
| `BIF_BX0_PCIE_DATA2`  | `0x3C` | `0x0F` |

Access pattern (`amd_smn.asm`):

```nasm
smn_r32(uint32 smn_addr):
    write32(BAR0[0x0E], smn_addr)   ; latch INDEX2
    return read32(BAR0[0x0F])       ; read DATA2

smn_w32(uint32 smn_addr, uint32 val):
    write32(BAR0[0x0E], smn_addr)
    write32(BAR0[0x0F], val)
```

**Safety note from a later wedge**: reading DATA2 from an unmapped segment
returns last-bus-data (looks like junk but doesn't fault). **Writing** DATA2
to an unmapped segment can wedge NBIO. Read-only segment probes are always
safe; speculative writes are not.

---

## Stage H - SMU mailbox (`amd_smu.asm`)

### MP1 (SMU) SMN segment - **VERIFIED**

| Symbol | SMN address | Notes |
|---|---|---|
| `MP1_BASE_SMN` | `0x03B10000` | mp_13_0_4 SEG4 alias |
| `C2PMSG_66` (msg) | `0x03B10A08` | `MP1_BASE_SMN + 0x0282 * 4` |
| `C2PMSG_82` (arg) | `0x03B10A48` | `MP1_BASE_SMN + 0x0292 * 4` |
| `C2PMSG_90` (resp) | `0x03B10A68` | `MP1_BASE_SMN + 0x029A * 4` |

### Mailbox protocol - **VERIFIED**

1. Poll `C2PMSG_90` until non-zero (drains stale response)
2. Write 0 to `C2PMSG_90`
3. Write argument to `C2PMSG_82`
4. Write message ID to `C2PMSG_66` ← kicks SMU
5. Poll `C2PMSG_90` until non-zero - value is the response

### PPSMC message IDs - **smu_v13_0_4 (Strix), VERIFIED**

| ID | Name | Behaviour observed |
|---|---|---|
| `0x01` | `TestMessage` | Returns `0x01` (OK) in C2PMSG_90 *and* writes `0x01` to C2PMSG_82. **Does NOT echo `arg+1`** (that's a dGPU-only convention). |
| `0x13` | `DisallowGfxOff` | Returns `0x13` (message-ID echo) in C2PMSG_90. That counts as accepted on this firmware. |

> **NO `PowerUpGfx` exists on APU.** GFX is powered by ABL/PSP at boot.
> Task H's job is just to confirm the mailbox is alive and ask the SMU
> not to clock-gate GFX away while we touch it.

### Stage-H state after success - **VERIFIED**

```
state=2 (GPU_STATE_GFX_POWERED)
SMU test=00000001 disGfx=00000013 lastMsg=00000013
SMN c2p90=00000013 c2p66=00000013 c2p82=00000013
```

GFX `SCRATCH_REG0` round-tripped with `0xCAFEF00D` (separate from the SMU
work - proves GC MMIO is alive after DisallowGfxOff).

---

## Stage I - GFXHUB context-0 page table (`amd_gmc.asm`)

### Hub choice - **VERIFIED**

GFX clients (CP/MEC/RLC/shaders) translate through **GFXHUB** (`regGCVM_*`),
NOT MMHUB (`regMMVM_*`). MMHUB serves DCN/VCN/SDMA-MM. The original task
ticket said "GCVM_CONTEXT0_*" and that turned out to be correct - we wasted
one boot programming MMHUB before catching this.

### GC block base - **VERIFIED**

```
GC_BASE = 0x00001260 * 4 = 0x4980  (byte offset within BAR0)
```

All `regGCVM_*` offsets are GC-block-relative dwords; absolute dword =
`(GC_BASE / 4) + reg_dword`.

### GFXHUB context-0 register offsets - **VERIFIED**

| Symbol | Dword (within GC) | Notes |
|---|---|---|
| `GCVM_CONTEXT0_CNTL` | `0x0BF0` | |
| `GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32` | `0x0BFC` | |
| `GCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32` | `0x0BFD` | |
| `GCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32` | `0x0C4C` | in pages (>>12) |
| `GCVM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32` | `0x0C4D` | |
| `GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32` | `0x0C9C` | inclusive end, in pages |
| `GCVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32` | `0x0C9D` | |
| `GCVM_INVALIDATE_ENG0_REQ` | `0x0D90` | |
| `GCVM_INVALIDATE_ENG0_ACK` | `0x0DA0` | **ENG0 never acks** - reserved for KIQ |
| `GCVM_L2_PROTECTION_FAULT_STATUS` | `0x0C31` | |
| `GCVM_L2_PROTECTION_FAULT_ADDR_LO32` | `0x0C34` | |
| `GCVM_L2_PROTECTION_FAULT_ADDR_HI32` | `0x0C35` | |

### Memory map for Stage I - **VERIFIED**

```
GPU_PT_ROOT     = 0x10000000   (4 KiB)
GPU_WORK_BASE   = 0x10000000   (identity range)
PT covers       = 0x10000000 .. 0x10200000  (2 MiB single block)
```

### The single PTE - **VERIFIED**

```
PTE = GPU_WORK_BASE              ; 0x10000000 (PFN already aligned)
    | GPU_PTE_RWX                ; VALID|SYSTEM|COHERENT|READ|WRITE|EXECUTE
    | GPU_PTE_BLOCK              ; bit 54 - "this non-leaf entry IS the leaf"
```

NASM gotcha: `OR rax, GPU_PTE_BLOCK` won't fit in `OR-imm32` because bit
54 is set. Use `mov rbx, GPU_PTE_BLOCK; or rax, rbx`.

### Stage-I sequence - **VERIFIED**

1. Zero the PT region (`rep stosq`)
2. Write the single PTE at offset 0 of `GPU_PT_ROOT`
3. Write `PT_BASE_LO/HI` = `GPU_PT_ROOT` (byte address, NOT shifted)
4. Write `PT_START_LO/HI` = `GPU_WORK_BASE >> 12` (in pages)
5. Write `PT_END_LO/HI` = `(GPU_WORK_BASE + 0x200000 - 1) >> 12`
6. Write `CONTEXT0_CNTL = 0x01FFFC03` ← canonical Linux enable value
7. Read back `CONTEXT0_CNTL` → must equal `0x01FFFC03`
8. Write `INVALIDATE_ENG0_REQ = 0x00F80001`
   - bit 0 (PER_VMID_INVALIDATE_REQ[0]) = 1
   - bits 23..19 (INVALIDATE_L2_PTES + L2_PDE0..2 + L1_PTES) = 1
9. Poll `INVALIDATE_ENG0_ACK[0]` - **expected to time out** on ENG0 (KIQ-reserved); proceed regardless
10. Read fault status / faddr for diag - non-zero is expected and informational

### Stage-I state after success - **VERIFIED**

```
state=3 (GPU_STATE_GMC_READY)
GMC step=7 ack=00000000 cntl=01FFFC03
GMC faddr=D8B2EA4BD4F2EA4F     ← garbage-looking, but that's a real fault on
                                  unrelated client probes outside our 2 MiB.
                                  Informational, not a blocker.
```

### Critical Stage-I lessons

- **Invalidate ENG0 does not ack on bare metal**; that's KIQ's engine. Driver-
  usable engines start at index 3 per Linux's `vm_inv_eng_bitmap = 0x1FFF8`.
  For Wave-1 we just skip the ack - there's nothing to flush on a fresh PT.
- **The fault after context enable is real and expected.** When you enable
  ctx 0, every GFX client immediately starts translating through your PT.
  Anything that touches outside the 2 MiB window faults. Future waves should
  either expand the mapping or only enable the context for the duration of
  a submission.

---

## Stage J - CP GFX ring + doorbell (`amd_cp_ring.asm`)

### CP register offsets - **VERIFIED**

| Symbol | Dword (within GC) |
|---|---|
| `CP_RB0_BASE` | `0x3040` |
| `CP_RB0_BASE_HI` | `0x30B1` |
| `CP_RB0_CNTL` | `0x3041` |
| `CP_RB0_RPTR_ADDR` | `0x3042` |
| `CP_RB0_RPTR_ADDR_HI` | `0x3043` |
| `CP_RB0_WPTR` | `0x3074` |
| `CP_RB0_WPTR_HI` | `0x3075` |

### Ring memory layout - **VERIFIED**

```
GPU_CP_RING_BASE     = 0x10010000   (64 KiB)
GPU_CP_RPTR_ADDR     = 0x10020000   (4 KiB)
GPU_CP_RING_LOG2_DWORDS = 13        (8K dwords)
```

### CNTL value computed and verified - **VERIFIED**

```
CP_RB0_CNTL_CONFIGURE = (13)
                      | (10 << 8)        ; BLKSZ = BUFSZ - 3
                      | (1  << 25)       ; RPTR_WRITEBACK_ENABLE
                      | (1  << 27)       ; RB_NO_UPDATE (CP won't chase ring
                                         ;   until microcode load releases it)
                      = 0x0A000A0D
```

### Stage-J sequence - **VERIFIED**

1. Zero `GPU_CP_RING_BASE` (64 KiB)
2. Zero `GPU_CP_RPTR_ADDR` (4 KiB)
3. Write `CP_RB0_BASE` = `GPU_CP_RING_BASE >> 2` = `0x04004000` (dword address)
4. Write `CP_RB0_BASE_HI` = `(GPU_CP_RING_BASE >> 2) >> 32` = `0`
5. Write `CP_RB0_RPTR_ADDR` = `GPU_CP_RPTR_ADDR` (byte address)
6. Write `CP_RB0_RPTR_ADDR_HI` = 0
7. Zero `CP_RB0_WPTR` and `CP_RB0_WPTR_HI`
8. Write `CP_RB0_CNTL` = `0x0A000A0D`
9. Read back CNTL/BASE → must match exactly
10. Read BAR2 from PCI config offset `0x18` (with 64-bit BAR handling) → stash
    in `gpu_doorbell_base`

### Stage-J state after success - **VERIFIED**

```
state=4 (GPU_STATE_RING_ALLOCATED)
CP step=3 cntl=0A000A0D base=04004000
db=00000000260010E0
```

### CP is still halted

After J, `CP_ME_CNTL` is unchanged (CP held in reset). The ring is
configured but the CP isn't chasing it - that's what Wave-3 K/L (microcode
load) and the eventual unhalt will fix. **This is intentional.** Releasing
CP before microcode is loaded is a hardware hang.

---

## Build & deploy that worked

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build\build_uefi.ps1 -Gfx
```

The `-Gfx` switch flips on `-dGRIT_GFX_BRINGUP` which:
- Includes `src/kernel/drivers/gpu/*.asm` from `kernel_build.asm`
- Activates the `%ifdef GRIT_GFX_BRINGUP` diag block in `main.asm`
- Causes `gfx_bringup()` to be called from `main.asm` after `amd_dcn_probe`

Deploy:
```
cp build/esp/EFI/BOOT/{BOOTX64.EFI,KERNEL.BIN,APPS.BIN,DATA.IMG} E:/EFI/BOOT/
cp build/data.img E:/data.img
```

---

## What we deliberately did NOT do (and why)

| Skipped | Why |
|---|---|
| `PPSMC_MSG_PowerUpGfx` | Does not exist on APU. GFX is auto-powered. |
| Strict TestMessage `arg+1` echo check | smu_v13_0_4 firmware writes the result code (1) into C2PMSG_82, not `arg+1`. |
| MMHUB context-0 programming | GFX uses GFXHUB. MMHUB serves other clients. |
| TLB-invalidate ACK as a gate | ENG0 is KIQ-reserved; never acks for direct driver writes. Informational only. |
| GFXHUB fault-status as a gate | Fault on enable is expected (other clients translate). Informational only. |
| Releasing CP from reset (`CP_ME_CNTL`) | No microcode loaded → instant hang. Deferred to Wave-3 L. |
| Direct BAR0 access to MP0 (PSP) regs | **Wedged NBIO/SMN once.** PSP must go through the same NBIO SMN proxy as SMU. |

---

## Quick "is the baseline still working?" checklist

Reboot with `-Gfx`. The overlay should show, in order, at the bottom:

```
GFX state=4 stage=74 smu=00000013 fault=E08ACFC9
GFX bar0=000000FA10000000 db=00000000260010E0
SMN c2p90=00000013 c2p66=00000013 c2p82=00000013
SMU test=00000001 disGfx=00000013 lastMsg=00000013
GMC step=7 ack=00000000 cntl=01FFFC03
GMC faddr=D8B2EA4BD4F2EA4F     ← any non-FFFF value is fine
CP   step=3 cntl=0A000A0D base=04004000
```

**The five must-haves:**
1. `state=4`
2. `cntl=01FFFC03` (GFXHUB context-0 enabled)
3. `cntl=0A000A0D` (CP RB0)
4. `base=04004000` (CP ring base in dwords)
5. `db=` non-zero (doorbell BAR captured)

If ANY of those go wrong, the regression is in H/I/J - not in Wave-3 stuff.
Wave-3 code paths are all gated behind `GRIT_GFX_WAVE3_FIRE` /
`GRIT_GFX_WAVE3_L_FIRE`, so just don't define those and you're back to
the verified baseline.

---

## If a Wave-3 attempt wedges the box

Symptoms to watch for:
- All SMN reads return identical junk → NBIO state machine stuck
- GFX overlay freezes mid-render → likely a CP/GMC fault wave from a bad
  PSP TMR pointer
- DCN goes blank → bad NBIO write disturbed display clocks

Recovery: power-cycle, rebuild **without** the Wave-3 fire flags
(`-Gfx` alone is fine - Wave-3 modules are included but unused). The
verified H/I/J path doesn't depend on anything Wave-3 ever wrote.
