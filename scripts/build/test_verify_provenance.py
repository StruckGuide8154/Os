#!/usr/bin/env python3
"""Regression tests for the provenance trust-boundary parser."""

import json
import os
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verify_provenance as vp  # noqa: E402


def minimal(value):
    if value <= 0xFF:
        return b"\x01" + bytes([value])
    if value <= 0xFFFF:
        return b"\x02" + struct.pack("<H", value)
    return b"\x04" + struct.pack("<I", value)


def valid_envelope(payload=b"{}"):
    tlvs = []
    for fid in range(1, 13):
        if fid == 10:
            value = struct.pack("<HHH", 2, 0x3F, 0)
        else:
            value = b""
        tlvs.append(minimal(fid) + minimal(len(value)) + value)
    tlv_blob = b"".join(tlvs)
    header_len = vp.FIXED_HEADER_LEN + len(tlv_blob)
    fixed = b"GRSE" + struct.pack("<HHHHH", 1, 1, 0, 12, header_len)
    fixed += struct.pack("<I", len(payload))
    return fixed + tlv_blob + payload


def valid_statement():
    return {
        "schema": vp.PROVENANCE_SCHEMA,
        "builder": {
            "id": "github:StruckGuide8154/grit/.github/workflows/ghl-security.yml@refs/heads/master",
            "toolchain": {
                "gritc_sha256": "11" * 32,
                "ed25519_host_sha256": "22" * 32,
                "nasm_version": "2.16.03",
            },
        },
        "source": {
            "uri": "https://github.com/StruckGuide8154/grit",
            "revision": "33" * 20,
        },
        "artifacts": [
            {"name": "toolchain_pins.txt", "sha256": "44" * 32},
            {"name": "reproducible_digests.txt", "sha256": "55" * 32},
        ],
    }


class ParseEnvelopeTests(unittest.TestCase):
    def test_accepts_minimal_canonical_structure(self):
        stmt, canonical, sig_block, _, min_cosigners, allowed, required = vp.parse_envelope(valid_envelope())
        self.assertEqual(stmt, {})
        self.assertEqual(canonical, valid_envelope())
        self.assertEqual(sig_block, b"")
        self.assertEqual((min_cosigners, allowed, required), (2, 0x3F, 0))

    def test_rejects_truncated_header(self):
        with self.assertRaises(ValueError):
            vp.parse_envelope(b"GRSE")

    def test_rejects_payload_overrun(self):
        blob = bytearray(valid_envelope())
        payload_len = struct.unpack("<I", blob[14:18])[0]
        blob[14:18] = struct.pack("<I", payload_len + 1)
        with self.assertRaisesRegex(ValueError, "payload overruns envelope"):
            vp.parse_envelope(bytes(blob))

    def test_rejects_noncanonical_scalar_width(self):
        blob = bytearray(valid_envelope())
        # First field id is canonically encoded as width=1,value=1. Force width=2
        # without changing the declared header; the parser must reject before use.
        blob[18] = 2
        with self.assertRaisesRegex(ValueError, "minimal-width|non-minimal|overruns"):
            vp.parse_envelope(bytes(blob))

    def test_rejects_signature_tail_not_multiple_of_64(self):
        with self.assertRaisesRegex(ValueError, "signature block length"):
            vp.parse_envelope(valid_envelope() + b"x")

    def test_rejects_invalid_utf8_payload(self):
        with self.assertRaisesRegex(ValueError, "valid UTF-8"):
            vp.parse_envelope(valid_envelope(payload=b"\xff"))

    def test_rejects_duplicate_field_ids(self):
        blob = bytearray(valid_envelope())
        # Locate field 2's encoded id and rewrite it to 1, preserving lengths.
        off = vp.FIXED_HEADER_LEN
        off += 2 + 2  # field 1 id + zero-length value length
        self.assertEqual(blob[off:off + 2], b"\x01\x02")
        blob[off + 1] = 1
        with self.assertRaisesRegex(ValueError, "strictly increasing"):
            vp.parse_envelope(bytes(blob))

    def test_payload_json_must_parse(self):
        with self.assertRaises(json.JSONDecodeError):
            vp.parse_envelope(valid_envelope(payload=b"{"))


class StatementSemanticTests(unittest.TestCase):
    def test_accepts_canonical_statement(self):
        vp.validate_statement(valid_statement())

    def test_rejects_non_object_statement(self):
        with self.assertRaisesRegex(ValueError, "JSON object"):
            vp.validate_statement([])

    def test_rejects_wrong_schema(self):
        stmt = valid_statement()
        stmt["schema"] = "grit-provenance-v0"
        with self.assertRaisesRegex(ValueError, "schema"):
            vp.validate_statement(stmt)

    def test_rejects_empty_builder_id(self):
        stmt = valid_statement()
        stmt["builder"]["id"] = "   "
        with self.assertRaisesRegex(ValueError, "builder.id"):
            vp.validate_statement(stmt)

    def test_rejects_malformed_revision(self):
        stmt = valid_statement()
        stmt["source"]["revision"] = "not-a-commit"
        with self.assertRaisesRegex(ValueError, "source.revision"):
            vp.validate_statement(stmt)

    def test_rejects_malformed_toolchain_hash(self):
        stmt = valid_statement()
        stmt["builder"]["toolchain"]["gritc_sha256"] = "00"
        with self.assertRaisesRegex(ValueError, "gritc_sha256"):
            vp.validate_statement(stmt)

    def test_rejects_duplicate_artifact_names(self):
        stmt = valid_statement()
        stmt["artifacts"].append({"name": "toolchain_pins.txt", "sha256": "66" * 32})
        with self.assertRaisesRegex(ValueError, "duplicate artifact"):
            vp.validate_statement(stmt)

    def test_rejects_malformed_artifact_hash(self):
        stmt = valid_statement()
        stmt["artifacts"][0]["sha256"] = "xyz"
        with self.assertRaisesRegex(ValueError, "sha256"):
            vp.validate_statement(stmt)


class CosignerPolicyTests(unittest.TestCase):
    def test_accepts_policy_class_threshold(self):
        kind = vp.we.ART["policy"]
        vp.validate_cosigner_policy(kind, 2, 0x3F, vp.we.CLASS_REQUIRED_MASK[kind])

    def test_rejects_zero_signature_quorum(self):
        kind = vp.we.ART["policy"]
        with self.assertRaisesRegex(ValueError, "class policy range"):
            vp.validate_cosigner_policy(kind, 0, 0, 0)

    def test_rejects_required_role_not_allowed(self):
        kind = vp.we.ART["policy"]
        required = vp.we.CLASS_REQUIRED_MASK[kind]
        with self.assertRaisesRegex(ValueError, "must also be allowed"):
            vp.validate_cosigner_policy(kind, 2, 0x01, required)

    def test_rejects_class_required_role_removal(self):
        kind = vp.we.ART["policy"]
        with self.assertRaisesRegex(ValueError, "weakens"):
            vp.validate_cosigner_policy(kind, 2, 0x3F, 0)

    def test_rejects_unknown_role_bits(self):
        kind = vp.we.ART["policy"]
        with self.assertRaisesRegex(ValueError, "unknown roles"):
            vp.validate_cosigner_policy(kind, 2, 0x7F, vp.we.CLASS_REQUIRED_MASK[kind])

    def test_rejects_unsatisfiable_quorum(self):
        kind = vp.we.ART["policy"]
        required = vp.we.CLASS_REQUIRED_MASK[kind]
        with self.assertRaisesRegex(ValueError, "cannot satisfy"):
            vp.validate_cosigner_policy(kind, 3, required, required)


if __name__ == "__main__":
    unittest.main()
