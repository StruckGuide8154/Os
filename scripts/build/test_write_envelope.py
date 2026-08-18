#!/usr/bin/env python3
"""Regression tests for security-sensitive write_envelope CLI behavior."""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("write_envelope.py")


def read_minimal(data, offset):
    width = data[offset]
    if width not in (1, 2, 4):
        raise AssertionError("invalid scalar width %d" % width)
    start = offset + 1
    end = start + width
    if end > len(data):
        raise AssertionError("truncated scalar")
    return int.from_bytes(data[start:end], "little"), end


def parse_tlvs(envelope):
    if envelope[:4] != b"GRSE":
        raise AssertionError("bad envelope magic")
    field_count = struct.unpack_from("<H", envelope, 10)[0]
    header_len = struct.unpack_from("<H", envelope, 12)[0]
    if not 18 <= header_len <= len(envelope):
        raise AssertionError("invalid header length")

    fields = {}
    offset = 18
    for _ in range(field_count):
        field_id, offset = read_minimal(envelope, offset)
        length, offset = read_minimal(envelope, offset)
        end = offset + length
        if end > header_len:
            raise AssertionError("TLV overruns header")
        fields[field_id] = envelope[offset:end]
        offset = end
    if offset != header_len:
        raise AssertionError("TLV region does not end at header boundary")
    return fields


def test_explicit_policy_dependency_is_preserved_without_require_flag():
    expected = bytes(range(1, 33))
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        payload = td / "payload.bin"
        policy = td / "policy.sha256"
        output = td / "artifact.env"
        payload.write_bytes(b"policy dependency regression payload")
        policy.write_bytes(expected)

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--payload", str(payload),
                "--out", str(output),
                "--type", "app",
                "--policy-dep", str(policy),
                "--sign-roles", "none",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        fields = parse_tlvs(output.read_bytes())
        actual = fields.get(13)
        assert actual == expected, (
            "explicit --policy-dep was not preserved: expected %r, got %r"
            % (expected, actual)
        )


def main():
    test_explicit_policy_dependency_is_preserved_without_require_flag()
    print("write_envelope regression tests: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
