#!/usr/bin/env python3
"""
GSEC proof: tss_init_for_core(edi=core_index) memory-safety bound.

Models the exact address arithmetic in src/kernel/core/tss.asm's
tss_init_for_core and shows:

  * OLD (no entry bound): a core index >= SMP_MAX_CORES (e.g. a raw sparse APIC
    id) drives the GDT TSS-descriptor write and the three AP-pool writes OUT OF
    BOUNDS.
  * NEW (fail-closed cmp edi,1 / cmp edi,SMP_MAX_CORES): every index outside
    [1, SMP_MAX_CORES-1] is rejected before any write; every accepted index
    lands strictly inside all four provisioned regions.

Pure arithmetic, no QEMU. Mirrors gdt.asm:106 (gdt64_tss_ap holds exactly
SMP_MAX_CORES-1 AP descriptor slots) and tss.asm pool sizings.
"""

SMP_MAX_CORES = 8            # constants.inc (GRIT_SMP / CACHE32 profile)

# Region capacities (element counts), from tss.asm .bss:
#   ap_ist_stacks:  16384*3*(SMP_MAX_CORES-1+1)  -> SMP_MAX_CORES IST blocks
#   ap_tss_pool:    112*(SMP_MAX_CORES-1+1)      -> SMP_MAX_CORES TSS structs
#   ap_rsp0_stacks: 16384*(SMP_MAX_CORES-1+1)    -> SMP_MAX_CORES RSP0 stacks
POOL_SLOTS = SMP_MAX_CORES                       # valid slot index: 0..POOL_SLOTS-1
# GDT: gdt64_tss (core 0/BSP) + gdt64_tss_ap = (SMP_MAX_CORES-1) AP descriptors,
# for core indices 1..SMP_MAX_CORES-1, each 16 bytes at 0x30 + core*16.
GDT_AP_SLOTS = SMP_MAX_CORES - 1                 # valid AP core index: 1..GDT_AP_SLOTS


def accesses(core_index):
    """Return the region indices tss_init_for_core would touch for this input."""
    slot = (core_index - 1) & 0xFFFFFFFF         # ecx = edi-1 (32-bit)
    return {
        "tss_pool_slot":  slot,                  # ap_tss_pool[slot], zeroes 112 B
        "rsp0_slot":      slot,                  # ap_rsp0_stacks[slot]
        "ist_block_slot": slot,                  # ap_ist_stacks[slot]
        "gdt_ap_core":    core_index,            # descriptor at 0x30 + core*16
    }


def in_bounds(core_index):
    a = accesses(core_index)
    return (0 <= a["tss_pool_slot"] < POOL_SLOTS
            and 0 <= a["rsp0_slot"] < POOL_SLOTS
            and 0 <= a["ist_block_slot"] < POOL_SLOTS
            and 1 <= a["gdt_ap_core"] <= GDT_AP_SLOTS)


def new_accepts(core_index):
    # cmp edi,1 / jb reject ; cmp edi,SMP_MAX_CORES / jae reject  (unsigned)
    e = core_index & 0xFFFFFFFF
    return (e >= 1) and (e < SMP_MAX_CORES)


def main():
    # Sweep the full range a raw APIC id could take (8-bit xAPIC) plus 0 and a
    # few 32-bit extremes.
    sweep = list(range(0, 256)) + [0xFF, 0x100, 0x1000, 0xFFFFFFFF]

    old_oob = [i for i in sweep if not in_bounds(i)]           # OLD would OOB
    new_admitted = [i for i in sweep if new_accepts(i)]

    # 1. Every index the NEW bound admits is provably in-bounds.
    bad_admit = [i for i in new_admitted if not in_bounds(i)]
    assert not bad_admit, f"NEW admitted OOB indices: {bad_admit}"

    # 2. The NEW bound admits EXACTLY the safe AP range [1, SMP_MAX_CORES-1].
    assert new_admitted == list(range(1, SMP_MAX_CORES)), new_admitted

    # 3. OLD (unbounded) is demonstrably unsafe: sparse/raw ids OOB, incl. a
    #    concrete GDT-descriptor overrun witness.
    assert 0 in old_oob                      # index 0 -> slot -1 (pool underflow)
    assert SMP_MAX_CORES in old_oob          # first past the GDT AP slots
    assert 0xFF in old_oob                    # a real sparse APIC id
    witness = accesses(0xFF)
    gdt_byte_off = 0x30 + witness["gdt_ap_core"] * 16
    gdt_limit = 0x30 + (GDT_AP_SLOTS + 1) * 16   # one past last valid AP slot end
    assert gdt_byte_off >= gdt_limit, "expected GDT overrun witness"

    print("PASS tss_init_for_core core-index bound")
    print(f"  SMP_MAX_CORES            = {SMP_MAX_CORES}")
    print(f"  NEW admits               = {new_admitted}  (== [1..{SMP_MAX_CORES-1}])")
    print(f"  NEW admitted-but-OOB     = {len(bad_admit)}  (must be 0)")
    print(f"  OLD OOB indices in sweep = {len(old_oob)}  (e.g. 0, {SMP_MAX_CORES}, 255)")
    print(f"  witness id=0xFF -> GDT write @0x{gdt_byte_off:X} "
          f">= GDT AP end 0x{gdt_limit:X}  (OOB descriptor write)")


if __name__ == "__main__":
    main()
