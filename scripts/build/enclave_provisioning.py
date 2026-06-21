#!/usr/bin/env python3
"""Track 10 one-time enrollment and revocation policy model."""

import base64
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ed25519_host

CERT_SCHEMA = "grit.enclave-device-cert.v1"
REV_SCHEMA = "grit.enclave-revocation.v1"
AUTHORITY_ROLE = 3  # POLICY/enrollment authority in the CI key model
HEX256 = re.compile(r"^[0-9a-f]{64}$")
IDENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def _sign_authority(payload):
    return base64.b64encode(ed25519_host.sign(ed25519_host.dev_role_secret(AUTHORITY_ROLE), canonical(payload))).decode("ascii")


def _verify_authority(payload, signature):
    try:
        raw = base64.b64decode(signature, validate=True)
    except Exception:
        return False
    return ed25519_host.verify(ed25519_host.dev_role_public(AUTHORITY_ROLE), canonical(payload), raw)


class ProvisioningBoard:
    """Private seed models an in-board generated PUF-bound identity key."""

    def __init__(self, device_id, puf_seed):
        self.device_id = device_id
        self._secret = hashlib.sha512(b"Grit-PUF-device-v1\0" + puf_seed).digest()[:32]
        self.public_key = ed25519_host.public_key(self._secret)
        self.locked = False

    def prove(self, challenge):
        return ed25519_host.sign(self._secret, b"GRIT-ENROLL-POP-V1\0" + challenge)

    def lock(self):
        if self.locked:
            return False
        self.locked = True
        return True


def issue_certificate(board, challenge, proof, board_class, minimum_counter, epoch):
    if board.locked or minimum_counter < 1 or epoch < 1:
        raise ValueError("board state or certificate counters invalid")
    message = b"GRIT-ENROLL-POP-V1\0" + challenge
    if not ed25519_host.verify(board.public_key, message, proof):
        raise ValueError("device proof-of-possession failed")
    body = {
        "schema": CERT_SCHEMA,
        "device_id": board.device_id,
        "public_key": board.public_key.hex(),
        "board_class": board_class,
        "minimum_bitstream_counter": minimum_counter,
        "enrollment_epoch": epoch,
    }
    record = {"certificate": body, "signature": _sign_authority(body)}
    board.lock()
    return record


def verify_certificate(record):
    if not isinstance(record, dict) or set(record) != {"certificate", "signature"}:
        return False
    body = record.get("certificate")
    expected = {"schema", "device_id", "public_key", "board_class",
                "minimum_bitstream_counter", "enrollment_epoch"}
    if not isinstance(body, dict) or set(body) != expected or body.get("schema") != CERT_SCHEMA:
        return False
    if not all(isinstance(body.get(k), str) and IDENT.fullmatch(body[k]) for k in ("device_id", "board_class")):
        return False
    try:
        pub = bytes.fromhex(body["public_key"])
    except (TypeError, ValueError):
        return False
    if len(pub) != 32:
        return False
    for key in ("minimum_bitstream_counter", "enrollment_epoch"):
        value = body.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            return False
    return _verify_authority(body, record.get("signature"))


def issue_revocation(device_id, public_key_hex, epoch, reason, replacement_id=""):
    if epoch < 1 or reason not in ("lost", "stolen", "cloned", "retired", "compromised"):
        raise ValueError("invalid revocation")
    body = {"schema": REV_SCHEMA, "device_id": device_id,
            "public_key_sha256": hashlib.sha256(bytes.fromhex(public_key_hex)).hexdigest(),
            "reason": reason, "effective_epoch": epoch, "replacement_id": replacement_id}
    return {"revocation": body, "signature": _sign_authority(body)}


def verify_revocation(record):
    if not isinstance(record, dict) or set(record) != {"revocation", "signature"}:
        return False
    body = record.get("revocation")
    expected = {"schema", "device_id", "public_key_sha256", "reason", "effective_epoch", "replacement_id"}
    if not isinstance(body, dict) or set(body) != expected or body.get("schema") != REV_SCHEMA:
        return False
    if not isinstance(body.get("device_id"), str) or not IDENT.fullmatch(body["device_id"]):
        return False
    if not isinstance(body.get("replacement_id"), str) or (body["replacement_id"] and not IDENT.fullmatch(body["replacement_id"])):
        return False
    if not isinstance(body.get("public_key_sha256"), str) or not HEX256.fullmatch(body["public_key_sha256"]):
        return False
    if body.get("reason") not in ("lost", "stolen", "cloned", "retired", "compromised"):
        return False
    if not isinstance(body.get("effective_epoch"), int) or isinstance(body.get("effective_epoch"), bool) or body["effective_epoch"] < 1:
        return False
    return _verify_authority(body, record.get("signature"))


class EnrollmentRegistry:
    def __init__(self, minimum_epoch=1):
        self.minimum_epoch = minimum_epoch
        self.certificates = {}
        self.revocations = {}

    def enroll(self, record):
        if not verify_certificate(record):
            return False, "invalid-certificate"
        body = record["certificate"]
        if body["enrollment_epoch"] < self.minimum_epoch:
            return False, "stale-epoch"
        if body["device_id"] in self.certificates:
            return False, "duplicate-device"
        if any(c["certificate"]["public_key"] == body["public_key"] for c in self.certificates.values()):
            return False, "duplicate-key"
        self.certificates[body["device_id"]] = record
        return True, "enrolled"

    def revoke(self, record):
        if not verify_revocation(record):
            return False, "invalid-revocation"
        body = record["revocation"]
        if body["effective_epoch"] <= self.minimum_epoch:
            return False, "epoch-not-forward"
        cert = self.certificates.get(body["device_id"])
        if cert is None:
            return False, "unknown-device"
        expected = hashlib.sha256(bytes.fromhex(cert["certificate"]["public_key"])).hexdigest()
        if body["public_key_sha256"] != expected:
            return False, "key-mismatch"
        self.minimum_epoch = body["effective_epoch"]
        self.revocations[body["device_id"]] = record
        return True, "revoked"

    def admits(self, device_id):
        cert = self.certificates.get(device_id)
        if cert is None or device_id in self.revocations:
            return False
        return cert["certificate"]["enrollment_epoch"] >= self.minimum_epoch
