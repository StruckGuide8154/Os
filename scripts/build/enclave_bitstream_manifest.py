#!/usr/bin/env python3
"""Create and verify deterministic signed Track 10 bitstream manifests."""

import argparse
import base64
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ed25519_host

SCHEMA = "grit.enclave-bitstream.v1"
SIGNING_ROLE = 4  # UPDATE
MANIFEST_FIELDS = {
    "schema", "artifact", "board_class", "slot", "version",
    "rollback_counter", "bitstream_sha256", "source_sha256", "sources",
    "toolchain", "build_epoch", "root_key_id",
}
RECORD_FIELDS = {"manifest", "signature", "signer_role"}
HEX256 = re.compile(r"^[0-9a-f]{64}$")
TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def parse_record_bytes(raw, require_canonical=True):
    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    if not isinstance(raw, bytes):
        raise ValueError("record must be bytes")
    try:
        record = json.loads(raw.decode("ascii"), object_pairs_hook=no_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid manifest JSON") from exc
    if require_canonical and raw not in (canonical(record), canonical(record) + b"\n"):
        raise ValueError("manifest JSON is not canonical")
    return record


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def source_digest(root, paths):
    h = hashlib.sha256()
    root_abs = os.path.abspath(root)
    for relative in sorted(p.replace("\\", "/") for p in paths):
        if relative.startswith("/") or any(p in ("", ".", "..") for p in relative.split("/")):
            raise ValueError("source path must be normalized and relative")
        full = os.path.abspath(os.path.join(root_abs, relative))
        if os.path.commonpath((root_abs, full)) != root_abs:
            raise ValueError("source escapes source root")
        h.update(relative.encode("utf-8") + b"\0")
        with open(full, "rb") as stream:
            h.update(stream.read())
        h.update(b"\0")
    return h.hexdigest()


def root_key_id():
    return hashlib.sha256(ed25519_host.dev_role_public(SIGNING_ROLE)).hexdigest()


def validate_manifest(manifest):
    """Return (valid, reason). Unknown fields fail closed."""
    if not isinstance(manifest, dict) or set(manifest) != MANIFEST_FIELDS:
        return False, "manifest-fields"
    if manifest["schema"] != SCHEMA or manifest["artifact"] != "fpga-bitstream":
        return False, "identity"
    if not isinstance(manifest["board_class"], str) or not TOKEN.fullmatch(manifest["board_class"]):
        return False, "board-class"
    if manifest["slot"] not in ("A", "B"):
        return False, "slot"
    for field in ("version", "rollback_counter", "build_epoch"):
        value = manifest[field]
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
            return False, field
    if manifest["version"] < 1 or manifest["rollback_counter"] < 1 or manifest["build_epoch"] != 0:
        return False, "counter-policy"
    for field in ("bitstream_sha256", "source_sha256", "root_key_id"):
        if not isinstance(manifest[field], str) or not HEX256.fullmatch(manifest[field]):
            return False, field
    if manifest["root_key_id"] != root_key_id():
        return False, "root-key"
    sources = manifest["sources"]
    if not isinstance(sources, list) or not sources or sources != sorted(set(sources)):
        return False, "sources-order"
    for path in sources:
        if not isinstance(path, str) or not path or "\\" in path or path.startswith("/"):
            return False, "source-path"
        parts = path.split("/")
        if any(part in ("", ".", "..") for part in parts):
            return False, "source-path"
    tools = manifest["toolchain"]
    if not isinstance(tools, dict) or not tools:
        return False, "toolchain"
    if list(tools) != sorted(tools):
        return False, "toolchain-order"
    for name, version in tools.items():
        if not isinstance(name, str) or not TOKEN.fullmatch(name):
            return False, "tool-name"
        if not isinstance(version, str) or not TOKEN.fullmatch(version):
            return False, "tool-version"
    return True, "ok"


def make_manifest(bitstream, source_root, sources, toolchain, version, rollback, slot, board_class):
    if version < 1 or rollback < 1 or slot not in ("A", "B"):
        raise ValueError("invalid version, rollback counter, or slot")
    manifest = {
        "schema": SCHEMA,
        "artifact": "fpga-bitstream",
        "board_class": board_class,
        "slot": slot,
        "version": version,
        "rollback_counter": rollback,
        "bitstream_sha256": sha256_file(bitstream),
        "source_sha256": source_digest(source_root, sources),
        "sources": sorted(p.replace("\\", "/") for p in sources),
        "toolchain": dict(sorted(toolchain.items())),
        "build_epoch": 0,
        "root_key_id": root_key_id(),
    }
    valid, reason = validate_manifest(manifest)
    if not valid:
        raise ValueError("invalid manifest: " + reason)
    return manifest


def sign_manifest(manifest):
    sig = ed25519_host.sign(ed25519_host.dev_role_secret(SIGNING_ROLE), canonical(manifest))
    return {"manifest": manifest, "signature": base64.b64encode(sig).decode("ascii"), "signer_role": "UPDATE"}


def verify_record(record, bitstream=None, source_root=None):
    if not isinstance(record, dict) or set(record) != RECORD_FIELDS or record.get("signer_role") != "UPDATE":
        return False
    manifest = record.get("manifest")
    valid, _ = validate_manifest(manifest)
    if not valid:
        return False
    try:
        sig = base64.b64decode(record["signature"], validate=True)
    except Exception:
        return False
    if not ed25519_host.verify(ed25519_host.dev_role_public(SIGNING_ROLE), canonical(manifest), sig):
        return False
    if bitstream is not None and sha256_file(bitstream) != manifest["bitstream_sha256"]:
        return False
    if source_root is not None:
        try:
            if source_digest(source_root, manifest["sources"]) != manifest["source_sha256"]:
                return False
        except (OSError, ValueError):
            return False
    return True


def admit_update(record, current_rollback, active_slot, bitstream=None):
    if not verify_record(record, bitstream):
        return False, "signature-or-digest"
    m = record["manifest"]
    if m["rollback_counter"] <= current_rollback:
        return False, "rollback"
    if m["slot"] == active_slot:
        return False, "active-slot"
    return True, "stage-inactive-slot"


def self_test_message(record):
    return b"GRIT-ENCLAVE-SELFTEST-V1\0" + hashlib.sha256(canonical(record["manifest"])).digest()


def sign_self_test(record, device_secret):
    return ed25519_host.sign(device_secret, self_test_message(record))


class ABUpdateController:
    """Executable power-fail-safe update policy; flash writes are abstracted."""

    def __init__(self, active_slot, committed_floor, device_public_key):
        if active_slot not in ("A", "B") or committed_floor < 0:
            raise ValueError("invalid initial update state")
        self.active_slot = active_slot
        self.floor = committed_floor
        self.device_public_key = device_public_key
        self.state = "stable"
        self.pending = None
        self.previous_slot = None

    def stage(self, record, bitstream=None):
        if self.state != "stable":
            return False, "busy"
        ok, reason = admit_update(record, self.floor, self.active_slot, bitstream)
        if not ok:
            return False, reason
        self.pending = record
        self.state = "staged"
        return True, "staged"

    def begin_trial(self):
        if self.state != "staged":
            return False, "not-staged"
        self.previous_slot = self.active_slot
        self.active_slot = self.pending["manifest"]["slot"]
        self.state = "trial"
        return True, "trial"

    def confirm(self, signature):
        if self.state != "trial":
            return False, "not-trial"
        if not ed25519_host.verify(self.device_public_key, self_test_message(self.pending), signature):
            return False, "bad-self-test"
        self.floor = self.pending["manifest"]["rollback_counter"]
        self.pending = None
        self.previous_slot = None
        self.state = "stable"
        return True, "committed"

    def fail_trial(self):
        if self.state != "trial":
            return False, "not-trial"
        self.active_slot = self.previous_slot
        self.pending = None
        self.previous_slot = None
        self.state = "stable"
        return True, "rolled-back"

    def power_loss(self):
        if self.state == "trial":
            return self.fail_trial()
        if self.state == "staged":
            self.pending = None
            self.state = "stable"
            return True, "discarded-unconfirmed-stage"
        return True, "stable"


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    create.add_argument("--bitstream", required=True)
    create.add_argument("--source-root", required=True)
    create.add_argument("--source", action="append", required=True)
    create.add_argument("--tool", action="append", required=True, metavar="NAME=VERSION")
    create.add_argument("--version", required=True, type=int)
    create.add_argument("--rollback", required=True, type=int)
    create.add_argument("--slot", choices=("A", "B"), required=True)
    create.add_argument("--board-class", required=True)
    create.add_argument("--out", required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--bitstream")
    verify.add_argument("--source-root")
    args = parser.parse_args()
    if args.command == "create":
        tools = dict(item.split("=", 1) for item in args.tool)
        record = sign_manifest(make_manifest(args.bitstream, args.source_root, args.source, tools,
                                             args.version, args.rollback, args.slot, args.board_class))
        with open(args.out, "wb") as stream:
            stream.write(canonical(record) + b"\n")
        return 0
    with open(args.manifest, "rb") as stream:
        try:
            record = parse_record_bytes(stream.read())
        except ValueError:
            return 1
    return 0 if verify_record(record, args.bitstream, args.source_root) else 1


if __name__ == "__main__":
    sys.exit(main())
