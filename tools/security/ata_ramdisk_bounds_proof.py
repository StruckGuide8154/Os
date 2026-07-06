#!/usr/bin/env python3
# ============================================================================
# GSEC proof: ata.asm sector-count ceiling + ramdisk_classify range safety
# 2026-07-06 daily security run (storage tier).
#
# Models the two block-layer bounds gates and proves, empirically over the
# adversarial input space, that the hardened versions can never classify an
# out-of-region request as "inside" (which would drive a rep-movsb OOB), while
# exhibiting the pre-fix wrap witnesses that could.
#
# Runs standalone: `python3 ata_ramdisk_bounds_proof.py` (no QEMU, no build).
# ============================================================================
M32 = 0xFFFFFFFF
SECTOR = 512
ATA_MAX_SECTORS_PER_CALL = 128          # constants.inc
DATA_IMG_MAX_SIZE = 0x2000000           # boot_memory.inc (32 MiB)
REGION_MAX_SECTORS = DATA_IMG_MAX_SIZE // SECTOR   # 65536


def ata_cap_accepts(count):
    """ata_read/write_sectors entry gate: `cmp edx,CAP / ja reject`."""
    return (count & M32) <= ATA_MAX_SECTORS_PER_CALL


def classify_old(lba, base, count, region_sectors):
    """Pre-fix ramdisk_classify (32-bit range add). Returns (verdict, oob).
    verdict: 'inside' | 'partial' | 'outside'. oob = True if an 'inside'
    verdict would let rep-movsb read/write past the region in bytes."""
    lba &= M32
    if lba < base:                       # .maybe_outside (32-bit add)
        if ((lba + count) & M32) > base:
            return 'partial', False
        return 'outside', False
    offset = (lba - base) & M32
    end = (offset + count) & M32         # <-- 32-bit wrap
    if end > region_sectors:
        return 'partial', False
    # inside: rep-movsb touches [offset*512, offset*512 + count*512)
    byte_end = offset * SECTOR + count * SECTOR
    oob = byte_end > region_sectors * SECTOR
    return 'inside', oob


def classify_new(lba, base, count, region_sectors):
    """Hardened ramdisk_classify (64-bit range add) + ata cap upstream."""
    if not ata_cap_accepts(count):       # ata entry rejects before classify
        return 'rejected', False
    lba &= M32
    if lba < base:
        if (lba + count) > base:         # 64-bit, no wrap
            return 'partial', False
        return 'outside', False
    offset = lba - base
    end = offset + count                 # 64-bit, cannot wrap (both < 2^32)
    if end > region_sectors:
        return 'partial', False
    byte_end = offset * SECTOR + count * SECTOR
    oob = byte_end > region_sectors * SECTOR
    return 'inside', oob


def sweep():
    base = 4160                          # FAT16_PART_LBA
    region = 32768                       # a representative registered size
    old_oob = new_oob = new_inside = 0
    old_wrap_witnesses = []
    # Representative + boundary + adversarial (near-2^32) inputs.
    counts = ([0, 1, 2, 127, 128, 129, 256, 1000, 65535, 65536,
               region, region + 1] +
              [M32 - base - k for k in range(0, 8)] +      # wrap the range add
              [M32, M32 - 1, 0x80000000, 0xFFFF0000])
    lbas = [0, 1, base - 1, base, base + 1, base + region - 1,
            base + region, base + region + 1, M32 - 4, M32]
    for lba in lbas:
        for count in counts:
            vo, oob_o = classify_old(lba, base, count, region)
            vn, oob_n = classify_new(lba, base, count, region)
            if vo == 'inside' and oob_o:
                old_oob += 1
                if len(old_wrap_witnesses) < 5:
                    old_wrap_witnesses.append((lba, count))
            if vn == 'inside':
                new_inside += 1
                # HARD INVARIANT: a NEW 'inside' verdict is memory-safe.
                assert not oob_n, f"NEW OOB inside! lba={lba} count={count}"
                # and the ata cap must have admitted it
                assert ata_cap_accepts(count)
            if oob_n:
                new_oob += 1
    return old_oob, new_oob, new_inside, old_wrap_witnesses


def cap_check():
    # Every count the FS layer actually passes must survive the cap;
    # everything above it must be rejected fail-closed.
    legit = [1, 32, 64, 128]             # floor=1, root<=32, fat/file<=128
    for c in legit:
        assert ata_cap_accepts(c), f"legit count {c} wrongly rejected"
    for c in [129, 256, 65535, 65536, M32]:
        assert not ata_cap_accepts(c), f"oversized count {c} wrongly accepted"
    # static-assert mirror: a capped transfer never exceeds the ramdisk window
    assert ATA_MAX_SECTORS_PER_CALL * SECTOR <= DATA_IMG_MAX_SIZE


if __name__ == '__main__':
    cap_check()
    old_oob, new_oob, new_inside, wit = sweep()
    print(f"ata count cap: legit<=128 accepted, >128 rejected      -> OK")
    print(f"classify OLD  : OOB 'inside' verdicts (32-bit wrap)     -> {old_oob}")
    print(f"classify NEW  : OOB 'inside' verdicts                   -> {new_oob}")
    print(f"classify NEW  : safe 'inside' verdicts exercised        -> {new_inside}")
    if wit:
        print(f"OLD wrap witnesses (lba,count): {wit}")
    assert old_oob > 0, "expected pre-fix wrap witnesses"
    assert new_oob == 0, "post-fix must never OOB"
    print("PROOF HOLDS: cap rejects oversized counts; hardened classify never "
          "mis-passes an out-of-region request.")
