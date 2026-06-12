#!/usr/bin/env python3
"""
Per-app integrity manifest patcher.

Phase-1 additive build side for docs/per-app-integrity-manifest.md:
  - reads the assembled app_integrity_table emitted by src/user/apps.asm
  - computes SHA-256 for each declared app segment, with the same KASLR-sliding
    qwords zeroed as patch_blob_sig.py
  - patches each digest plus an HMAC-SHA256 over the fixed-size manifest table
    into both raw kernel ORG passes before KASLR wrapping

The old whole-blob HMAC remains in place; this tool only makes the new manifest
available to later runtime cutover work.
"""
import argparse
import hashlib
import hmac
import sys

MASK64 = (1 << 64) - 1
SLIDE = 0x100000

# MUST match APP_MANIFEST_KEY in src/include/app_manifest.inc ("GRMANIK!").
APP_MANIFEST_KEY = 0x214B494E414D5247
APP_MANIFEST_MAX = 32
APP_MANIFEST_ENTRY_SIZE = 44
APP_MANIFEST_TABLE_BYTES = 4 + (APP_MANIFEST_ENTRY_SIZE * APP_MANIFEST_MAX) + 32

APPS_START_MARKER = bytes((0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                           0x42, 0x53, 0x54, 0x52, 0x54, 0xDE, 0xAD, 0xBE))
APPS_END_MARKER = bytes((0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                         0x42, 0x45, 0x4E, 0x44, 0x21, 0xCA, 0xFE, 0xBE))
MANIFEST_MARKER = bytes((0x47, 0x52, 0x4D, 0x41, 0x4E, 0x49, 0x46, 0x45,
                         0x53, 0x54, 0x54, 0x42, 0x4C, 0xC0, 0xDE, 0x01))


def die(msg):
    sys.stderr.write("gen-app-manifest: FATAL: " + msg + "\n")
    sys.exit(1)


def read_file(path):
    with open(path, "rb") as f:
        return bytearray(f.read())


def write_file(path, buf):
    with open(path, "wb") as f:
        f.write(buf)


def find_unique(buf, needle, what):
    first = buf.find(needle)
    if first < 0:
        die(f"{what} marker not found in kernel image")
    if buf.find(needle, first + 1) >= 0:
        die(f"{what} marker found more than once -- ambiguous patch target")
    return first


def blob_region(buf):
    start = find_unique(buf, APPS_START_MARKER, "app-blob start")
    end = buf.find(APPS_END_MARKER, start + len(APPS_START_MARKER))
    if end < 0:
        die("app-blob end marker not found after start marker")
    return start, end + len(APPS_END_MARKER)


def manifest_slot(buf):
    marker = find_unique(buf, MANIFEST_MARKER, "app-manifest")
    slot = marker + len(MANIFEST_MARKER)
    if slot + APP_MANIFEST_TABLE_BYTES > len(buf):
        die("app-manifest table runs past end of kernel image")
    return slot


def derive_sliding_offsets(blob_a, blob_b):
    if len(blob_a) != len(blob_b):
        die("blob length differs between ORG passes")
    offs = []
    i = 0
    n = len(blob_a)
    while i < n:
        if blob_a[i] == blob_b[i]:
            i += 1
            continue
        matched = None
        for j in range(max(0, i - 7), i + 1):
            if j + 8 > n:
                continue
            va = int.from_bytes(blob_a[j:j + 8], "little")
            vb = int.from_bytes(blob_b[j:j + 8], "little")
            if (vb - va) & MASK64 == SLIDE:
                matched = j
                break
        if matched is None:
            die(f"blob byte at blob-offset 0x{i:X} differs between ORG passes "
                f"but is not part of a qword that slid by 0x{SLIDE:X}")
        offs.append(matched)
        i = matched + 8
    return sorted(offs)


def parse_entries(buf, slot, blob_len):
    count = int.from_bytes(buf[slot:slot + 4], "little")
    if count > APP_MANIFEST_MAX:
        die(f"app-manifest count {count} exceeds capacity {APP_MANIFEST_MAX}")

    entries = []
    entries_off = slot + 4
    seen_ids = set()
    for idx in range(count):
        off = entries_off + idx * APP_MANIFEST_ENTRY_SIZE
        app_id = int.from_bytes(buf[off:off + 4], "little")
        seg_off = int.from_bytes(buf[off + 4:off + 8], "little")
        seg_size = int.from_bytes(buf[off + 8:off + 12], "little")
        if app_id in seen_ids:
            die(f"duplicate app_id {app_id} in manifest")
        seen_ids.add(app_id)
        if seg_size == 0:
            die(f"app_id {app_id} has zero-size segment")
        if seg_off + seg_size > blob_len:
            die(f"app_id {app_id} segment 0x{seg_off:X}+0x{seg_size:X} "
                f"exceeds blob length 0x{blob_len:X}")
        entries.append((app_id, seg_off, seg_size, off))

    return entries


def segment_digest(blob, seg_off, seg_size, sliding_offsets):
    seg = bytearray(blob[seg_off:seg_off + seg_size])
    seg_end = seg_off + seg_size
    for fix in sliding_offsets:
        if seg_off <= fix and fix + 8 <= seg_end:
            local = fix - seg_off
            seg[local:local + 8] = b"\x00" * 8
    return hashlib.sha256(bytes(seg)).digest()


def compute_manifest_mac(table_without_marker):
    key = APP_MANIFEST_KEY.to_bytes(8, "little")
    covered = table_without_marker[:4 + APP_MANIFEST_ENTRY_SIZE * APP_MANIFEST_MAX]
    return hmac.new(key, covered, hashlib.sha256).digest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="KERNEL.A.RAW (ORG 0x100000)")
    ap.add_argument("--b", required=True, help="KERNEL.B.RAW (ORG 0x200000)")
    ap.add_argument("--image", action="append", default=[],
                    help="extra image(s) to patch identically (optional)")
    ap.add_argument("--export-table", default=None, metavar="FILE",
                    help="also write marker + patched table bytes (the "
                         "SYSSIG.ENV envelope payload) to FILE")
    args = ap.parse_args()

    a = read_file(args.a)
    b = read_file(args.b)
    sa, ea = blob_region(a)
    sb, eb = blob_region(b)
    blob_a = bytes(a[sa:ea])
    blob_b = bytes(b[sb:eb])
    if len(blob_a) != len(blob_b):
        die("app-blob length differs between A and B")

    slot_a = manifest_slot(a)
    slot_b = manifest_slot(b)
    if a[slot_a:slot_a + APP_MANIFEST_TABLE_BYTES] != b[slot_b:slot_b + APP_MANIFEST_TABLE_BYTES]:
        die("assembled manifest table differs between ORG passes before patching")

    entries = parse_entries(a, slot_a, len(blob_a))
    sliding_offsets = derive_sliding_offsets(blob_a, blob_b)
    digests = [segment_digest(blob_a, seg_off, seg_size, sliding_offsets)
               for _app_id, seg_off, seg_size, _entry_off in entries]

    patched_table = bytearray(a[slot_a:slot_a + APP_MANIFEST_TABLE_BYTES])
    for (_app_id, _seg_off, _seg_size, entry_off), digest in zip(entries, digests):
        local = entry_off - slot_a
        patched_table[local + 12:local + 44] = digest
    mac = compute_manifest_mac(bytes(patched_table))
    patched_table[-32:] = mac

    for path in (args.a, args.b, *args.image):
        buf = read_file(path)
        slot = manifest_slot(buf)
        s, e = blob_region(buf)
        if e - s != len(blob_a):
            die(f"blob length in {path} differs from reference")
        if buf[slot:slot + 4] != a[slot_a:slot_a + 4]:
            die(f"manifest count in {path} differs from reference")
        # Preserve each image's assembled app_id/offset/size words, but patch
        # the build-filled digest/MAC bytes identically.
        for (_app_id, _seg_off, _seg_size, ref_entry_off), digest in zip(entries, digests):
            local = ref_entry_off - slot_a
            entry_off = slot + local
            buf[entry_off + 12:entry_off + 44] = digest
        mac_off = slot + 4 + APP_MANIFEST_ENTRY_SIZE * APP_MANIFEST_MAX
        buf[mac_off:mac_off + 32] = mac
        write_file(path, buf)

    if args.export_table:
        # Marker + patched table = the exact app_integrity_table bytes the
        # kernel holds at runtime (KASLR-stable by construction: the digests
        # zero the sliding qwords). This is the Track-2 SYSSIG.ENV payload.
        write_file(args.export_table, MANIFEST_MARKER + bytes(patched_table))

    labels = ", ".join(str(app_id) for app_id, _off, _size, _entry_off in entries)
    print(f"  app-manifest: {len(entries)} segment digests patched "
          f"({len(sliding_offsets)} sliding qwords partitioned), "
          f"HMAC-SHA256 {mac.hex()}, app_ids [{labels}]")


if __name__ == "__main__":
    main()
