#!/usr/bin/env python3
"""
KASLR fixup extractor.

Inputs:
  --a PATH        kernel assembled with [org 0x100000]
  --b PATH        kernel assembled with [org 0x200000]
  --out PATH      wrapped KERNEL.BIN to emit
  [--apps-marker-start HEX] [--apps-marker-end HEX]
                  optional: hex marker bytes (default: matches extract_apps.ps1)
                  used only to validate apps blob is byte-identical between A and B

Mechanism:
  Every label-bearing absolute reference in the kernel image is emitted by
  NASM as an 8-byte little-endian qword (see CLAUDE.md / `dq label`). Sliding
  the org from 0x100000 to 0x200000 therefore changes exactly those qwords
  by +0x100000. Any other diff (e.g. `dd label` -- 4-byte absolute) is a
  bug we want to surface, not silently fix.

  We walk A and B byte-by-byte. On a differing byte we search the up-to-8
  windows that contain it for one where read_u64(B) - read_u64(A) == 0x100000;
  that window's offset is recorded as a fixup. On no match we abort with a
  hex context dump and the most likely cause.

Output container (matches loader expectations -- see src/boot/uefi_loader.asm):
   offset  size  field
   0x00    8     magic "GRKASLR0" (0x3052_4C53_414B_5247 little-endian)
   0x08    4     payload_size      (u32, bytes of payload)
   0x0C    4     entry_offset      (u32, kernel entry within payload; today 0)
   0x10    4     fixup_count       (u32)
   0x14    4     reserved          (must be 0)
   0x18    fixup_count * 4    fixup_offsets[] (u32 each, offset within payload)
   ...     payload_size       payload bytes (= raw KERNEL.A)
"""
import argparse
import struct
import sys

SLIDE = 0x100000

# Match extract_apps.ps1 exactly. The apps blob can contain absolute qword
# references to its embedded kernel copy. Those are safe inside the kernel
# payload because they are included in the normal fixup table. APPS.BIN is
# only used by the non-KASLR loader path; when KASLR is enabled, the loader
# leaves the APPS boot-info fields clear so the kernel falls back to the
# fixed-up embedded blob.
APPS_START_MARKER = bytes((0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                           0x42, 0x53, 0x54, 0x52, 0x54, 0xDE, 0xAD, 0xBE))
APPS_END_MARKER   = bytes((0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                           0x42, 0x45, 0x4E, 0x44, 0x21, 0xCA, 0xFE, 0xBE))

MAGIC = b"GRKASLR0"
HEADER_SIZE = 0x18


def die(msg):
    sys.stderr.write("kaslr-fixups: FATAL: " + msg + "\n")
    sys.exit(1)


def hex_window(buf, lo, hi):
    return buf[lo:hi].hex()


def find_apps_region(buf):
    s = buf.find(APPS_START_MARKER)
    if s < 0:
        return None
    e = buf.find(APPS_END_MARKER, s + len(APPS_START_MARKER))
    if e < 0:
        return None
    return (s, e + len(APPS_END_MARKER))


def derive_fixups(a, b):
    n = len(a)
    if len(b) != n:
        die(f"size mismatch: A={n} bytes, B={len(b)} bytes (both ORG builds "
            f"must produce identical-size output)")

    fixups = []
    i = 0
    while i < n:
        if a[i] == b[i]:
            i += 1
            continue
        # Look for an 8-byte window containing i where the qword slid by SLIDE.
        matched_j = None
        # Earliest possible window start = i-7 (i is the last byte of the qword).
        # Latest possible = i.
        for j in range(max(0, i - 7), i + 1):
            if j + 8 > n:
                continue
            va = int.from_bytes(a[j:j + 8], "little")
            vb = int.from_bytes(b[j:j + 8], "little")
            if (vb - va) & ((1 << 64) - 1) == SLIDE:
                matched_j = j
                break
        if matched_j is None:
            ctx_lo = max(0, i - 16)
            ctx_hi = min(n, i + 16)
            die(
                f"byte at offset 0x{i:08X} differs but is not part of a "
                f"qword absolute reference that slid by 0x{SLIDE:X}.\n"
                f"  A[0x{ctx_lo:08X}..0x{ctx_hi:08X}] = {hex_window(a, ctx_lo, ctx_hi)}\n"
                f"  B[0x{ctx_lo:08X}..0x{ctx_hi:08X}] = {hex_window(b, ctx_lo, ctx_hi)}\n"
                f"  Likely cause: a `dd label` (32-bit absolute) emitted in\n"
                f"  the kernel image. 32-bit absolutes are unsafe in 64-bit\n"
                f"  kernel code; rewrite as `dq label` (64-bit absolute) or\n"
                f"  `lea reg, [rel label]` (RIP-relative) and rebuild."
            )
        fixups.append(matched_j)
        i = matched_j + 8
    return fixups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--entry-offset", type=lambda s: int(s, 0), default=0,
                    help="kernel entry offset within payload (default 0)")
    args = ap.parse_args()

    with open(args.a, "rb") as f:
        a = f.read()
    with open(args.b, "rb") as f:
        b = f.read()

    # Sanity check: the apps blob markers must appear at the same offsets in
    # both ORG builds. Diffs inside the region are handled by derive_fixups().
    apps_a = find_apps_region(a)
    apps_b = find_apps_region(b)
    if apps_a is None and apps_b is None:
        pass  # no apps blob (e.g. minimal build)
    elif apps_a is None or apps_b is None:
        die("apps blob marker found in one ORG build but not the other -- "
            "did one assembly partially fail?")
    else:
        if apps_a != apps_b:
            die(f"apps blob region offsets differ: A={apps_a}, B={apps_b}. "
                f"This means something before the apps blob diverged in size, "
                f"which shouldn't happen.")

    fixups = derive_fixups(a, b)

    # Validate fixups: all distinct (a sliding qword can only start at one
    # offset), all within payload, table size sensible.
    if len(fixups) != len(set(fixups)):
        die("duplicate fixup offsets generated -- internal logic error")
    for off in fixups:
        if off + 8 > len(a):
            die(f"fixup offset 0x{off:X} extends past payload end")

    payload = a
    payload_size = len(payload)
    if payload_size > (1 << 32) - 1:
        die("payload too large for u32 size field")
    if len(fixups) > (1 << 32) - 1:
        die("fixup count too large for u32 field")
    if args.entry_offset >= payload_size:
        die(f"entry_offset 0x{args.entry_offset:X} >= payload_size 0x{payload_size:X}")

    header = MAGIC + struct.pack("<IIII",
                                 payload_size,
                                 args.entry_offset,
                                 len(fixups),
                                 0)
    assert len(header) == HEADER_SIZE
    table = b"".join(struct.pack("<I", off) for off in fixups)

    with open(args.out, "wb") as f:
        f.write(header)
        f.write(table)
        f.write(payload)

    print(f"  kaslr: {len(fixups)} fixups, payload {payload_size} bytes, "
          f"container {HEADER_SIZE + len(table) + payload_size} bytes")


if __name__ == "__main__":
    main()
