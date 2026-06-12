#!/usr/bin/env python3
"""
Track-2 (signed everything) - build-time host envelope writer.

Produces a valid v1 signed-artifact envelope
(docs/signed-artifact-envelope.md) for a payload file and writes it to
an output file.  This tool is intentionally kept OUT of the running OS
image.

Usage:
    python write_envelope.py [options] --payload <file> --out <file>

    --payload FILE      Payload to embed (required).
    --out FILE          Output envelope file (required).
    --type KIND         Artifact type name or number (default: app).
    --domain DOMAIN     Target domain name or number (default: app).
    --device-id N       Exact target device id, hex or decimal (default: 0).
    --device-class N    Device class id, hex or decimal (default: 0).
                        If --device-id is 0 and --device-class is 0 the
                        envelope targets device_id=1 (placeholder).
    --role ROLE         Signer role name or number (default: app_store).
    --not-before N      Validity window start (unix seconds, default: 0).
    --not-after N       Validity window end   (unix seconds, default: 2^32-1).
    --version N         MONOTONIC_VERSION (default: 1).
    --rollback N        ROLLBACK_COUNTER  (default: 1).
    --epoch N           REVOCATION_EPOCH  (default: 1).
    --min-cosigners N   COSIGNER_ROLES min_count (default: per-class floor).
    --allowed-mask N    COSIGNER_ROLES allowed_mask (default: 0x3F all roles).
    --required-mask N   COSIGNER_ROLES required_mask (default: per-class).
    --sig-count N       Number of placeholder 64-byte Ed25519 signature slots
                        to append (default: matches min-cosigners).
    --provenance FILE   32-byte raw build provenance hash file (optional;
                        defaults to SHA-256 of the payload).
    --policy-dep FILE   32-byte raw policy dependency hash file (optional;
                        defaults to zero hash for non-runnable types).

Output: a self-contained .envelope file containing the canonical TLV header
followed by the payload and N×64 placeholder signature slots.

NOTE on signature crypto: the signature slots are filled with 0x5A bytes as
placeholders; real threshold Ed25519 signing is the next Track-2 increment.
The host writer is intentionally crypto-agnostic: it emits the correct
canonical bytes so a signer tool (or hsm-bridge script) can replace the
signature block in-place or append real signatures.

Wire layout (v1, docs/signed-artifact-envelope.md):
  offset 0  : magic 'N','X','S','E'
  offset 4  : schema_version u16
  offset 6  : artifact_type  u16
  offset 8  : target_domain  u16
  offset 10 : field_count    u16  (12..64)
  offset 12 : header_len     u16  (offset of payload start)
  offset 14 : payload_len    u32
  offset 18 : TLV records (field ids strictly ascending)
  ...       : payload
  ...       : signature block (N × 64 bytes)
"""

import argparse
import hashlib
import os
import struct
import sys


# ---------------------------------------------------------------------------
# Artifact type and domain name maps (kept in sync with signed_envelope.ghl)
# ---------------------------------------------------------------------------
ART = {
    'boot': 1, 'kernel': 2, 'hypervisor': 3, 'driver': 4, 'app': 5,
    'policy': 6, 'config': 7, 'update': 8, 'recovery': 9,
}
ART_INV = {v: k for k, v in ART.items()}

DOMAIN = {
    'boot': 1, 'kernel': 2, 'hypervisor': 3, 'driver': 4, 'app': 5,
    'policy': 6, 'recovery': 7,
}
DOMAIN_INV = {v: k for k, v in DOMAIN.items()}

ROLE = {
    'boot': 1, 'kernel': 2, 'driver': 3, 'app_store': 4,
    'policy': 5, 'update': 6, 'recovery': 7,
}
ROLE_INV = {v: k for k, v in ROLE.items()}

# Default signer role per artifact type (must match signed_artifact_check.ghl).
DEFAULT_ROLE = {1: 1, 2: 2, 3: 2, 4: 3, 5: 4, 6: 5, 7: 5, 8: 6, 9: 7}

# Default domain per artifact type.
DEFAULT_DOMAIN = {1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 6, 8: 1, 9: 7}

# Runnable types require POLICY_DEPENDENCY (bits 0..12 = REQUIRED_RUNNABLE).
RUNNABLE_TYPES = {1, 2, 3, 4, 5}

# Per-class threshold policy (mirrors security_threshold_class_* in
# threshold_check.ghl).  Keys are ART_* int values.
CLASS_MIN_COUNT = {1: 3, 2: 3, 3: 3, 4: 2, 5: 2, 6: 2, 7: 2, 8: 3, 9: 3}
CLASS_REQUIRED_MASK = {
    1: 0x03, 2: 0x03, 3: 0x03, 4: 0x04, 5: 0x04,
    6: 0x04, 7: 0x04, 8: 0x0B, 9: 0x13,
}


# ---------------------------------------------------------------------------
# Canonical TLV encoding
# ---------------------------------------------------------------------------
def enc_minimal(v):
    """Canonical minimal-width LE scalar: width byte + LE value."""
    if v <= 0xFF:
        return bytes([1, v])
    if v <= 0xFFFF:
        return bytes([2]) + struct.pack('<H', v)
    return bytes([4]) + struct.pack('<I', v)


def enc_tlv(field_id, value_bytes):
    """One canonical TLV record: [id_enc][len_enc][value]."""
    return enc_minimal(field_id) + enc_minimal(len(value_bytes)) + value_bytes


# ---------------------------------------------------------------------------
# Envelope assembly
# ---------------------------------------------------------------------------
def pick_signing_roles(min_cosigners, allowed_mask, required_mask):
    """Choose the threshold-role set to sign with: every required role, then
    the lowest allowed roles until min_cosigners distinct roles are reached."""
    roles = [r for r in range(1, 7) if required_mask & (1 << (r - 1))]
    for r in range(1, 7):
        if len(roles) >= min_cosigners:
            break
        if (allowed_mask & (1 << (r - 1))) and r not in roles:
            roles.append(r)
    return sorted(roles)


def build_envelope(payload, kind, domain, role,
                   device_id, device_class,
                   not_before, not_after,
                   version, rollback, epoch,
                   min_cosigners, allowed_mask, required_mask,
                   sig_count, provenance_hash, policy_dep_hash,
                   sign_roles=None):
    """Assemble a canonical v1 envelope for *payload* bytes."""

    ph = hashlib.sha256(payload).digest()

    # Target device TLV (6 bytes: u16 kind + u32 value).
    if device_id != 0:
        target_bytes = struct.pack('<HI', 1, device_id)   # EXACT
    elif device_class != 0:
        target_bytes = struct.pack('<HI', 2, device_class)  # CLASS
    else:
        target_bytes = struct.pack('<HI', 1, 1)   # fallback placeholder

    # COSIGNER_ROLES: u16 min_count + u16 allowed_mask + u16 required_mask
    cosigner_bytes = struct.pack('<HHH', min_cosigners, allowed_mask, required_mask)

    # Field ids (1-based, strictly ascending order - must match FIELD_ID_* in reader).
    fields = [
        (1,  struct.pack('<H', kind)),           # FIELD_ID_TYPE
        (2,  struct.pack('<H', domain)),         # FIELD_ID_DOMAIN
        (3,  target_bytes),                      # FIELD_ID_TARGET_DEVICE
        (4,  ph),                                # FIELD_ID_HASH
        (5,  struct.pack('<H', 1)),              # FIELD_ID_SCHEMA_VERSION
        (6,  struct.pack('<H', role)),           # FIELD_ID_SIGNER_ROLE
        (7,  struct.pack('<II', not_before, not_after)),  # FIELD_ID_VALIDITY
        (8,  struct.pack('<I', version)),        # FIELD_ID_MONOTONIC_VERSION
        (9,  struct.pack('<I', rollback)),       # FIELD_ID_ROLLBACK_COUNTER
        (10, cosigner_bytes),                    # FIELD_ID_COSIGNER_ROLES
        (11, struct.pack('<I', epoch)),          # FIELD_ID_REVOCATION_EPOCH
        (12, provenance_hash),                   # FIELD_ID_BUILD_PROVENANCE
    ]
    if kind in RUNNABLE_TYPES:
        fields.append((13, policy_dep_hash))     # FIELD_ID_POLICY_DEPENDENCY

    tlv_bytes = b''.join(enc_tlv(fid, val) for fid, val in fields)

    field_count = len(fields)
    header_len = 18 + len(tlv_bytes)
    payload_len = len(payload)

    header = (b'GRSE'
              + struct.pack('<HHHHH', 1, kind, domain, field_count, header_len)
              + struct.pack('<I', payload_len))

    # Signature block: real Ed25519 threshold signatures over the canonical
    # bytes (header + TLV region + payload), one 64-byte sig per cosigner
    # role, using the DEV role keys (ed25519_host.py).  Pass sign_roles=[]
    # to emit 0x5A placeholder slots instead (e.g. for an external HSM signer
    # that replaces the block in-place).
    canonical = header + tlv_bytes + payload
    if sign_roles is None:
        sign_roles = pick_signing_roles(min_cosigners, allowed_mask, required_mask)
    if sign_roles:
        import ed25519_host
        signature_block = b''.join(
            ed25519_host.sign(ed25519_host.dev_role_secret(r), canonical)
            for r in sign_roles)
    else:
        signature_block = bytes([0x5A] * (64 * sig_count))  # placeholder slots

    return canonical + signature_block


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_int(s):
    return int(s, 0)


def resolve_name_or_int(s, table, label):
    if s.isdigit() or (s.startswith('0x') or s.startswith('0X')):
        return int(s, 0)
    v = table.get(s.lower())
    if v is None:
        sys.exit("Unknown %s '%s'; valid names: %s"
                 % (label, s, ', '.join(sorted(table))))
    return v


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--payload', required=True, metavar='FILE')
    p.add_argument('--out',     required=True, metavar='FILE')
    p.add_argument('--type',    default='app',       metavar='KIND')
    p.add_argument('--domain',  default=None,        metavar='DOMAIN')
    p.add_argument('--device-id',    default='0',    metavar='N')
    p.add_argument('--device-class', default='0',    metavar='N')
    p.add_argument('--role',    default=None,        metavar='ROLE')
    p.add_argument('--not-before', default='0',      metavar='N', dest='not_before')
    p.add_argument('--not-after',  default='4294967295', metavar='N', dest='not_after')
    p.add_argument('--version',  default='1',        metavar='N')
    p.add_argument('--rollback', default='1',        metavar='N')
    p.add_argument('--epoch',    default='1',        metavar='N')
    p.add_argument('--min-cosigners', default=None,  metavar='N', dest='min_cosigners')
    p.add_argument('--allowed-mask',  default='0x3F', metavar='N', dest='allowed_mask')
    p.add_argument('--required-mask', default=None,  metavar='N', dest='required_mask')
    p.add_argument('--sig-count', default=None,      metavar='N', dest='sig_count')
    p.add_argument('--provenance', default=None,     metavar='FILE')
    p.add_argument('--policy-dep', default=None,     metavar='FILE', dest='policy_dep')
    p.add_argument('--sign-roles', default=None,     metavar='R,R,..', dest='sign_roles',
                   help='threshold role indices (1..6) to sign with; '
                        '"none" emits 0x5A placeholder slots; default: '
                        'required roles + lowest allowed up to min-cosigners')
    args = p.parse_args()

    # Resolve artifact type.
    kind = resolve_name_or_int(args.type, ART, 'artifact type')
    if kind not in ART_INV:
        sys.exit("Artifact type %d out of range [1..9]" % kind)

    # Resolve domain (default: canonical domain for the type).
    if args.domain is None:
        domain = DEFAULT_DOMAIN[kind]
    else:
        domain = resolve_name_or_int(args.domain, DOMAIN, 'target domain')
    if domain not in DOMAIN_INV:
        sys.exit("Domain %d out of range [1..7]" % domain)

    # Resolve role (default: canonical role for the type).
    if args.role is None:
        role = DEFAULT_ROLE[kind]
    else:
        role = resolve_name_or_int(args.role, ROLE, 'signer role')

    device_id    = parse_int(args.device_id)
    device_class = parse_int(args.device_class)
    not_before   = parse_int(args.not_before)
    not_after    = parse_int(args.not_after)
    version      = parse_int(args.version)
    rollback     = parse_int(args.rollback)
    epoch        = parse_int(args.epoch)

    # Threshold quorum: default to the per-class floor.
    class_min  = CLASS_MIN_COUNT[kind]
    class_req  = CLASS_REQUIRED_MASK[kind]
    min_cosigners = parse_int(args.min_cosigners) if args.min_cosigners else class_min
    allowed_mask  = parse_int(args.allowed_mask)
    required_mask = parse_int(args.required_mask) if args.required_mask else class_req

    if min_cosigners < class_min:
        sys.exit("--min-cosigners %d is below the class floor %d for %s"
                 % (min_cosigners, class_min, ART_INV.get(kind, kind)))

    sig_count = parse_int(args.sig_count) if args.sig_count else min_cosigners

    if args.sign_roles is None:
        sign_roles = None   # auto: required roles + lowest allowed
    elif args.sign_roles.lower() == 'none':
        sign_roles = []     # placeholder slots
    else:
        sign_roles = sorted(set(int(r, 0) for r in args.sign_roles.split(',')))
        for r in sign_roles:
            if not 1 <= r <= 6:
                sys.exit("--sign-roles entries must be threshold roles 1..6")

    # Load payload.
    with open(args.payload, 'rb') as fh:
        payload = fh.read()

    # Build provenance hash (default: SHA-256 of payload).
    if args.provenance:
        with open(args.provenance, 'rb') as fh:
            provenance_hash = fh.read()
        if len(provenance_hash) != 32:
            sys.exit("Provenance file must be exactly 32 bytes")
    else:
        provenance_hash = hashlib.sha256(payload).digest()

    # Policy dependency hash (default: zero bytes for non-runnable; required for runnable).
    if args.policy_dep:
        with open(args.policy_dep, 'rb') as fh:
            policy_dep_hash = fh.read()
        if len(policy_dep_hash) != 32:
            sys.exit("Policy-dep file must be exactly 32 bytes")
    elif kind in RUNNABLE_TYPES:
        # For runnable types, zero hash is a placeholder; the caller should
        # supply a real policy dependency hash via --policy-dep.
        policy_dep_hash = b'\x00' * 32
    else:
        policy_dep_hash = b'\x00' * 32

    envelope = build_envelope(
        payload, kind, domain, role,
        device_id, device_class,
        not_before, not_after,
        version, rollback, epoch,
        min_cosigners, allowed_mask, required_mask,
        sig_count, provenance_hash, policy_dep_hash,
        sign_roles=sign_roles,
    )

    with open(args.out, 'wb') as fh:
        fh.write(envelope)

    payload_len = len(payload)
    total_len   = len(envelope)
    sig_bytes   = sig_count * 64

    print("[write_envelope] wrote %d bytes total  "
          "(%d header + %d payload + %d sig-slots x64)"
          % (total_len, total_len - payload_len - sig_bytes, payload_len, sig_count))
    print("[write_envelope] type=%s domain=%s role=%s "
          "min_cosigners=%d allowed=0x%02X required=0x%02X epoch=%d"
          % (ART_INV.get(kind, kind), DOMAIN_INV.get(domain, domain),
             ROLE_INV.get(role, role),
             min_cosigners, allowed_mask, required_mask, epoch))
    if sign_roles == []:
        print("[write_envelope] NOTE: signature slots are 0x5A placeholders "
              "(--sign-roles none)")
    else:
        import ed25519_host
        eff = sign_roles if sign_roles is not None else \
            pick_signing_roles(min_cosigners, allowed_mask, required_mask)
        print("[write_envelope] signed canonical bytes with DEV Ed25519 role "
              "key(s): %s" % ', '.join(
                  '%d(%s)' % (r, ed25519_host.ROLE_NAMES[r]) for r in eff))
    return 0


if __name__ == '__main__':
    sys.exit(main())
