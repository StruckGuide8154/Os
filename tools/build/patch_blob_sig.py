#!/usr/bin/env python3
"""
User-blob signature patcher (security_todo.md §9 "Sign the user blob").

Computes the kernel-verified HMAC-SHA256 over the built-in user blob and patches the
expected MAC + the KASLR sliding-offset exclusion table into the raw kernel
image(s) at build time, BEFORE the KASLR diff. See:
  - src/include/app_blob_sig.inc          (shared key + marker + threat model)
  - src/kernel/grithlk/crypto.ghl        (runtime verifier)

THREAT MODEL (docs/STATUS.md): root of trust is measured boot + a kernel-held
key, NOT silicon; a physical attacker with the boot medium is out of scope. A
symmetric, kernel-held-key MAC is the right primitive - the key lives in the
kernel and the verifier IS the kernel. We do NOT use Ed25519.

KEY CONSISTENCY: APP_BLOB_SIG_KEY below MUST equal the value in
app_blob_sig.inc. The key is a fixed constant compiled into the kernel, so the
MAC computed here (build time) and by the kernel (runtime) use the same key by
construction - they match iff the covered blob bytes match.

KASLR CANONICALIZATION: the default build is KASLR-on, so the embedded blob is
relocated at boot and its absolute qwords slide. We derive those sliding offsets
by diffing the two ORG passes (the same SLIDE test extract_kaslr_fixups uses),
EXCLUDE them from the MAC by folding 0x00 for those 8-byte windows, and emit the
ascending blob-relative offset list into the kernel so the runtime verifier
skips the same windows. The MAC therefore covers every non-relocated blob byte
and is slide-independent; the relocated address words are excluded by design.

MAC = HMAC-SHA256(KEY8_LE, covered_blob), where covered_blob folds 0x00 for
each KASLR-sliding qword. The runtime verifier in crypto.ghl performs the same
canonicalization before comparing the 32-byte digest patched here.

The blob region is [start_marker, end_marker + len(end_marker)), i.e. exactly
the embedded [app_blob_start, app_blob_end) the kernel hashes at runtime.

Usage:
  patch_blob_sig.py --a KERNEL.A.RAW --b KERNEL.B.RAW [--image EXTRA ...]
"""
import argparse
import hmac
import hashlib
import sys

MASK64 = (1 << 64) - 1

# MUST equal APP_BLOB_SIG_KEY in src/include/app_blob_sig.inc ("GRBLOBSI").
APP_BLOB_SIG_KEY = 0x4752424C4F425349
# MUST equal APP_BLOB_SIG_MAX_FIXUPS in src/include/app_blob_sig.inc.
MAX_FIXUPS = 128
# KASLR slide between the two ORG passes (matches extract_kaslr_fixups SLIDE).
SLIDE = 0x100000

# App-blob sentinels (match apps.asm / extract_apps.ps1). The MAC covers the
# region [start, end + len(end_marker)) == embedded [app_blob_start, app_blob_end).
APPS_START_MARKER = bytes((0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                           0x42, 0x53, 0x54, 0x52, 0x54, 0xDE, 0xAD, 0xBE))
APPS_END_MARKER = bytes((0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                         0x42, 0x45, 0x4E, 0x44, 0x21, 0xCA, 0xFE, 0xBE))

# 16-byte locator preceding {MAC[32], count dword, offsets dword[MAX_FIXUPS]}
# (match APP_BLOB_SIG_MARKER in app_blob_sig.inc: "GRBLOBSI"+"GMAC!"+0xDEC0DE).
SIG_MARKER = bytes((0x4E, 0x58, 0x42, 0x4C, 0x4F, 0x42, 0x53, 0x49,
                    0x47, 0x4D, 0x41, 0x43, 0x21, 0xDE, 0xC0, 0xDE))


def die(msg):
    sys.stderr.write("patch-blob-sig: FATAL: " + msg + "\n")
    sys.exit(1)


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
    return start, end + len(APPS_END_MARKER)   # include the end sentinel


def derive_sliding_offsets(blob_a, blob_b):
    """Blob-relative offsets of qwords that slide by SLIDE between ORG passes.

    Mirrors extract_kaslr_fixups.derive_fixups, scoped to the blob region."""
    if len(blob_a) != len(blob_b):
        die("blob length differs between ORG passes")
    n = len(blob_a)
    offs = []
    i = 0
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
                f"but is not part of a qword that slid by 0x{SLIDE:X} -- a non-"
                f"relocation diff in the blob means the build is not "
                f"reproducible and the MAC cannot be canonicalized.")
        offs.append(matched)
        i = matched + 8
    return offs


def canonical_blob(blob, sliding_offsets):
    """Return blob bytes with each KASLR-sliding qword replaced by zero bytes."""
    out = bytearray(blob)
    for off in sliding_offsets:
        for k in range(8):
            out[off + k] = 0
    return bytes(out)


def compute_mac(blob, sliding_offsets):
    """HMAC-SHA256(KEY8_LE, canonical_blob)."""
    key = APP_BLOB_SIG_KEY.to_bytes(8, "little")
    return hmac.new(key, canonical_blob(blob, sliding_offsets), hashlib.sha256).digest()


def patch_image(path, mac, offsets, blob_len):
    with open(path, "rb") as f:
        buf = bytearray(f.read())
    s, e = blob_region(buf)
    # A and B legitimately differ inside the blob (relocated qwords); only the
    # LENGTH must agree, so the same offset table applies to every image.
    if e - s != blob_len:
        die(f"blob length in {path} ({e - s}) differs from reference "
            f"({blob_len}) -- mismatched image?")
    sig = find_unique(buf, SIG_MARKER, "blob-sig")
    slot = sig + len(SIG_MARKER)
    need = 32 + 4 + 4 * MAX_FIXUPS
    if slot + need > len(buf):
        die(f"sig table runs past end of {path}")
    out = bytearray()
    out += mac
    out += len(offsets).to_bytes(4, "little")
    for off in offsets:
        out += off.to_bytes(4, "little")
    out += b"\x00\x00\x00\x00" * (MAX_FIXUPS - len(offsets))
    buf[slot:slot + need] = out
    with open(path, "wb") as f:
        f.write(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="KERNEL.A.RAW (ORG 0x100000)")
    ap.add_argument("--b", required=True, help="KERNEL.B.RAW (ORG 0x200000)")
    ap.add_argument("--image", action="append", default=[],
                    help="extra image(s) to patch identically (optional)")
    args = ap.parse_args()

    with open(args.a, "rb") as f:
        a = bytearray(f.read())
    with open(args.b, "rb") as f:
        b = bytearray(f.read())

    sa, ea = blob_region(a)
    sb, eb = blob_region(b)
    blob_a = bytes(a[sa:ea])
    blob_b = bytes(b[sb:eb])
    if len(blob_a) != len(blob_b):
        die("app-blob length differs between A and B")

    offsets = derive_sliding_offsets(blob_a, blob_b)
    offsets.sort()
    if len(offsets) > MAX_FIXUPS:
        die(f"blob has {len(offsets)} sliding qwords > capacity {MAX_FIXUPS}; "
            f"bump APP_BLOB_SIG_MAX_FIXUPS in src/include/app_blob_sig.inc and "
            f"MAX_FIXUPS here.")

    # The MAC is computed over the pass-A blob with the sliding windows zeroed,
    # which equals the runtime (relocated) blob with the same windows zeroed.
    mac = compute_mac(blob_a, offsets)

    for path in (args.a, args.b, *args.image):
        patch_image(path, mac, offsets, len(blob_a))

    print(f"  blob-sig: blob {len(blob_a)} bytes, {len(offsets)} sliding qwords "
          f"excluded, HMAC-SHA256 {mac.hex()} patched into "
          f"{2 + len(args.image)} image(s)")


if __name__ == "__main__":
    main()
