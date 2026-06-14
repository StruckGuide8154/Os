#!/usr/bin/env python3
"""Fail a release build when public artifacts expose debug/security state."""

import argparse
import hashlib
import struct
import sys
from pathlib import Path


FORBIDDEN = (
    b"KS=",
    b"KLOG.TXT",
    b"-- Mouse Debug --",
    b"-- XHCI Debug --",
    b"Framebuffer (debug)",
    b"klog overlay -- live ring buffer",
    b"Dump to serial",
    b"xdebug",
    b"idebug",
    # 2026-06-13 static-analysis audit (finding 4): boot/security debug strings
    # must not survive into a public release image. These are all gated behind
    # ENABLE_DEBUG_SERIAL (off in -Release); their presence means a leak path.
    b"[SYSSIG]",
    b"[KERNSIG]",
    b"[UPDATE]",
    b"[QUORUM]",
    b"RING 3",
    b"L3TEST",
    b"L3 key ok",
)

# Track 7: a released artifact must carry NO symmetric *trust* key. These are the
# little-endian ASCII spellings of the legacy HMAC trust keys that used to ship
# inside the very images they authenticated (forgeable-by-reverse-engineering).
# After the single-Ed25519-root collapse they must be absent from every image.
# Precise byte patterns (not a blind entropy scan) so legitimate high-entropy
# data - Ed25519 keys/signatures, the public QRNG commitment - never false-trip.
FORBIDDEN_TRUST_KEYS = (
    (b"ISBOLBRG", "legacy app-blob HMAC key (hmac_boot_key / APP_BLOB_SIG_KEY)"),
    (b"GRMANIK!", "legacy app-manifest HMAC key (hmac_manifest_key)"),
)

# The development Secure Boot certificate subject. A true production release must
# not ship under the test DB cert; --allow-test-cert opts in for internal/QEMU
# builds (the default build path passes it, production signing does not).
TEST_CERT_SUBJECT = b"Grit Secure Boot Test DB"


def minimal_scalar(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise ValueError("truncated scalar")
    width = data[offset]
    if width not in (1, 2, 4) or offset + 1 + width > len(data):
        raise ValueError("invalid scalar width")
    return int.from_bytes(data[offset + 1:offset + 1 + width], "little"), offset + 1 + width


def envelope_fields(path: Path) -> dict[int, bytes]:
    data = path.read_bytes()
    if len(data) < 18 or data[:4] != b"GRSE":
        raise ValueError("invalid envelope header")
    field_count, header_len = struct.unpack_from("<HH", data, 10)
    if header_len < 18 or header_len > len(data):
        raise ValueError("invalid envelope header length")
    fields = {}
    offset = 18
    for _ in range(field_count):
        field_id, offset = minimal_scalar(data, offset)
        length, offset = minimal_scalar(data, offset)
        end = offset + length
        if end > header_len or field_id in fields:
            raise ValueError("invalid envelope TLV")
        fields[field_id] = data[offset:end]
        offset = end
    if offset != header_len:
        raise ValueError("envelope TLVs do not fill header")
    return fields


def fail(message: str) -> None:
    print(f"release-artifacts: FAILED: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_signed_pe(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 0x100 or data[:2] != b"MZ":
        fail(f"{path.name} is not a PE image")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_offset + 24 + 112 + 8 * 5 > len(data) or data[pe_offset:pe_offset + 4] != b"PE\0\0":
        fail(f"{path.name} has an invalid PE header")
    optional = pe_offset + 24
    if struct.unpack_from("<H", data, optional)[0] != 0x20B:
        fail(f"{path.name} is not PE32+")
    checksum = struct.unpack_from("<I", data, optional + 64)[0]
    cert_offset, cert_size = struct.unpack_from("<II", data, optional + 112 + 8 * 4)
    if checksum == 0:
        fail(f"{path.name} has no PE checksum")
    if cert_offset == 0 or cert_size < 8 or cert_offset + cert_size > len(data):
        fail(f"{path.name} has no valid Authenticode certificate table")
    cert_length, revision, cert_type = struct.unpack_from("<IHH", data, cert_offset)
    if cert_length < 8 or cert_length > cert_size or revision != 0x0200 or cert_type != 0x0002:
        fail(f"{path.name} has an invalid WIN_CERTIFICATE")
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--esp", required=True, type=Path)
    parser.add_argument(
        "--allow-test-cert",
        action="store_true",
        help="permit the development Secure Boot test-DB cert (internal/QEMU "
        "builds). Omit for a production release: the test cert is then rejected.",
    )
    args = parser.parse_args()
    esp = args.esp

    required = ("BOOTX64.EFI", "KERNEL.BIN", "APPS.BIN", "DATA.IMG", "KERNEL.ENV", "SYSSIG.ENV")
    for name in required:
        if not (esp / name).is_file():
            fail(f"missing {name}")
    if (esp / "BOOTCFG.TXT").exists():
        fail("BOOTCFG.TXT must not ship in release mode")

    loader = check_signed_pe(esp / "BOOTX64.EFI")
    for name in ("BOOTX64.EFI", "KERNEL.BIN", "APPS.BIN"):
        data = loader if name == "BOOTX64.EFI" else (esp / name).read_bytes()
        for marker in FORBIDDEN:
            if marker in data:
                fail(f"{name} contains forbidden marker {marker!r}")
        for pattern, what in FORBIDDEN_TRUST_KEYS:
            if pattern in data:
                fail(f"{name} ships a symmetric trust secret: {what} "
                     f"(pattern {pattern!r}). Authenticity must rest on the "
                     f"Ed25519 root only - see Track 7.")

    # Production releases must not be signed under the development test-DB cert.
    if not args.allow_test_cert and TEST_CERT_SUBJECT in loader:
        fail(f"BOOTX64.EFI is signed under the development cert "
             f"{TEST_CERT_SUBJECT!r}; a production release needs the production "
             f"signing cert (pass --allow-test-cert only for internal/QEMU builds).")

    # The signed loader must contain every exact payload commitment. A signed
    # but generic loader would otherwise leave the original substitution bug.
    for name in ("KERNEL.BIN", "APPS.BIN", "DATA.IMG", "KERNEL.ENV", "SYSSIG.ENV"):
        digest = hashlib.sha256((esp / name).read_bytes()).digest()
        if digest not in loader:
            fail(f"BOOTX64.EFI does not pin {name}")

    for name in ("KERNEL.ENV", "SYSSIG.ENV"):
        try:
            fields = envelope_fields(esp / name)
        except ValueError as exc:
            fail(f"{name}: {exc}")
        policy = fields.get(13)
        if policy is None or len(policy) != 32 or not any(policy):
            fail(f"{name} has no nonzero policy dependency commitment")

    print("release-artifacts: passed")


if __name__ == "__main__":
    main()
