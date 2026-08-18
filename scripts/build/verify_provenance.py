#!/usr/bin/env python3
# =============================================================================
# verify_provenance.py - verify a signed provenance envelope (Track 1, sec->10).
#
# Verifies a PROVENANCE.ENV produced by gen_provenance.py THROUGH THE TRACK-2/7
# Ed25519 ROOT: it parses the Track-2 v1 envelope, recomputes the canonical
# signed bytes, and checks every threshold cosigner signature against the DEV
# role public keys (ed25519_host.dev_role_public) - the same root the kernel's
# envelope_verify_signed reader trusts. No new crypto.
#
# Checks:
#   1. envelope magic + structural sanity.
#   2. artifact-type == policy (the provenance class).
#   3. quorum: at least the per-class min cosigners are present and EVERY
#      signature verifies against the expected role pubkey.
#   4. signed statement semantic invariants (schema, identity, revision, hashes).
#   5. (optional) --expect-revision REV : the embedded source.revision matches.
#   6. (optional) --expect-artifact NAME=SHA : an embedded artifact hash matches.
#
# Exit 0 = provenance verified; exit 1 = any failure.
# =============================================================================

import argparse
import json
import os
import re
import struct
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'build'))

import ed25519_host           # noqa: E402
import write_envelope as we   # noqa: E402


FIXED_HEADER_LEN = 18
MIN_FIELD_COUNT = 12
MAX_FIELD_COUNT = 64
VALID_MINIMAL_WIDTHS = (1, 2, 4)
PROVENANCE_SCHEMA = 'grit-provenance-v1'
HEX40_RE = re.compile(r'^[0-9a-fA-F]{40}$')
HEX64_RE = re.compile(r'^[0-9a-fA-F]{64}$')


def parse_envelope(blob):
    """Return (statement_dict, canonical_bytes, sig_block, kind, min_cosigners,
    allowed_mask, required_mask).

    The verifier is a trust-boundary parser, so malformed envelopes must fail
    closed with ValueError rather than relying on Python slicing/index errors.
    """
    if len(blob) < FIXED_HEADER_LEN:
        raise ValueError('envelope shorter than fixed header')
    if blob[:4] != b'GRSE':
        raise ValueError('bad magic (not a GRSE envelope)')

    schema, kind, domain, field_count, header_len = struct.unpack('<HHHHH', blob[4:14])
    payload_len = struct.unpack('<I', blob[14:18])[0]

    if schema != 1:
        raise ValueError('unsupported schema version %d' % schema)
    if not MIN_FIELD_COUNT <= field_count <= MAX_FIELD_COUNT:
        raise ValueError('field count %d outside canonical range %d..%d'
                         % (field_count, MIN_FIELD_COUNT, MAX_FIELD_COUNT))
    if header_len < FIXED_HEADER_LEN:
        raise ValueError('header length %d smaller than fixed header' % header_len)
    if header_len > len(blob):
        raise ValueError('header length %d overruns envelope' % header_len)

    payload_start = header_len
    payload_end = payload_start + payload_len
    if payload_end > len(blob):
        raise ValueError('payload overruns envelope')

    payload = blob[payload_start:payload_end]
    canonical = blob[:payload_end]
    sig_block = blob[payload_end:]
    if len(sig_block) % 64 != 0:
        raise ValueError('signature block length is not a multiple of 64 bytes')

    # Walk the TLV region to recover COSIGNER_ROLES (field id 10). Every
    # boundary is checked against header_len so a hostile width/length cannot
    # read into payload/signature bytes or trigger an uncaught IndexError.
    min_cosigners = None
    allowed_mask = None
    required_mask = None
    off = FIXED_HEADER_LEN
    prev_fid = 0

    def read_minimal(o):
        if o >= header_len:
            raise ValueError('truncated minimal-width scalar')
        width = blob[o]
        o += 1
        if width not in VALID_MINIMAL_WIDTHS:
            raise ValueError('invalid minimal-width scalar size %d' % width)
        if o + width > header_len:
            raise ValueError('minimal-width scalar overruns header')
        raw = blob[o:o + width]
        value = int.from_bytes(raw, 'little')
        if width == 2 and value <= 0xFF:
            raise ValueError('non-minimal 2-byte scalar encoding')
        if width == 4 and value <= 0xFFFF:
            raise ValueError('non-minimal 4-byte scalar encoding')
        return value, o + width

    for _ in range(field_count):
        fid, off = read_minimal(off)
        if fid <= prev_fid:
            raise ValueError('TLV field ids are not strictly increasing')
        prev_fid = fid

        vlen, off = read_minimal(off)
        value_end = off + vlen
        if value_end > header_len:
            raise ValueError('TLV value overruns declared header')
        val = blob[off:value_end]
        off = value_end

        if fid == 10:
            if vlen != 6:
                raise ValueError('COSIGNER_ROLES must be exactly 6 bytes')
            min_cosigners, allowed_mask, required_mask = struct.unpack('<HHH', val)

    if off != header_len:
        raise ValueError('TLV region length does not match declared header length')
    if min_cosigners is None:
        raise ValueError('missing required COSIGNER_ROLES field')

    try:
        stmt = json.loads(payload.decode('utf-8'))
    except UnicodeDecodeError as e:
        raise ValueError('payload is not valid UTF-8') from e

    return (stmt, canonical, sig_block, kind,
            min_cosigners, allowed_mask, required_mask)


def _require_hex(value, width, label):
    if not isinstance(value, str):
        raise ValueError('%s must be a string' % label)
    matcher = HEX40_RE if width == 40 else HEX64_RE
    if not matcher.fullmatch(value):
        raise ValueError('%s must be exactly %d hexadecimal characters' % (label, width))


def validate_statement(stmt):
    """Validate semantic invariants of the signed provenance JSON.

    A valid Ed25519 signature authenticates bytes; it does not make malformed
    metadata meaningful. Keep the trust boundary fail-closed by rejecting signed
    statements whose identity, revision, artifact list, or hashes are not in the
    canonical shape produced by gen_provenance.py.
    """
    if not isinstance(stmt, dict):
        raise ValueError('provenance statement must be a JSON object')
    if stmt.get('schema') != PROVENANCE_SCHEMA:
        raise ValueError('unsupported provenance statement schema')

    builder = stmt.get('builder')
    if not isinstance(builder, dict):
        raise ValueError('builder must be an object')
    builder_id = builder.get('id')
    if not isinstance(builder_id, str) or not builder_id.strip():
        raise ValueError('builder.id must be a non-empty string')

    toolchain = builder.get('toolchain')
    if not isinstance(toolchain, dict):
        raise ValueError('builder.toolchain must be an object')
    _require_hex(toolchain.get('gritc_sha256'), 64, 'builder.toolchain.gritc_sha256')
    _require_hex(toolchain.get('ed25519_host_sha256'), 64,
                 'builder.toolchain.ed25519_host_sha256')
    if not isinstance(toolchain.get('nasm_version'), str) or not toolchain['nasm_version'].strip():
        raise ValueError('builder.toolchain.nasm_version must be a non-empty string')

    source = stmt.get('source')
    if not isinstance(source, dict):
        raise ValueError('source must be an object')
    if not isinstance(source.get('uri'), str) or not source['uri'].strip():
        raise ValueError('source.uri must be a non-empty string')
    _require_hex(source.get('revision'), 40, 'source.revision')

    artifacts = stmt.get('artifacts')
    if not isinstance(artifacts, list):
        raise ValueError('artifacts must be a list')
    seen_names = set()
    for index, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            raise ValueError('artifact %d must be an object' % index)
        name = artifact.get('name')
        if not isinstance(name, str) or not name.strip():
            raise ValueError('artifact %d name must be a non-empty string' % index)
        if name in seen_names:
            raise ValueError('duplicate artifact name %r' % name)
        seen_names.add(name)
        _require_hex(artifact.get('sha256'), 64, 'artifact %r sha256' % name)


def verify(blob):
    (stmt, canonical, sig_block, kind,
     min_cosigners, allowed_mask, required_mask) = parse_envelope(blob)

    if kind != we.ART['policy']:
        raise ValueError('provenance envelope must be artifact-type policy, got %d' % kind)

    roles = we.pick_signing_roles(min_cosigners, allowed_mask, required_mask)
    n = len(sig_block) // 64
    if n < min_cosigners:
        raise ValueError('under quorum: %d signature(s) < min %d' % (n, min_cosigners))
    if n != len(roles):
        raise ValueError('signature count %d != expected cosigner roles %d' % (n, len(roles)))

    for i, role in enumerate(roles):
        sig = sig_block[i * 64:(i + 1) * 64]
        pub = ed25519_host.dev_role_public(role)
        if not ed25519_host.verify(pub, canonical, sig):
            raise ValueError('signature %d (role %d %s) FAILED verification'
                             % (i, role, ed25519_host.ROLE_NAMES[role]))

    validate_statement(stmt)
    return stmt, roles


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('envelope', metavar='PROVENANCE.ENV')
    p.add_argument('--expect-revision', default=None, metavar='REV')
    p.add_argument('--expect-artifact', action='append', default=[], metavar='NAME=SHA')
    p.add_argument('--print', action='store_true', dest='do_print')
    args = p.parse_args()

    with open(args.envelope, 'rb') as fh:
        blob = fh.read()

    try:
        stmt, roles = verify(blob)
    except (ValueError, KeyError, json.JSONDecodeError, struct.error, TypeError) as e:
        print("[provenance-verify] FAIL: %s" % e)
        return 1

    failures = []
    if args.expect_revision:
        rev = stmt.get('source', {}).get('revision', '')
        if rev != args.expect_revision:
            failures.append("revision mismatch: envelope %s != expected %s"
                            % (rev, args.expect_revision))
    if args.expect_artifact:
        embedded = {a['name']: a['sha256'] for a in stmt['artifacts']}
        for pair in args.expect_artifact:
            if '=' not in pair:
                failures.append("invalid --expect-artifact value %r (expected NAME=SHA)" % pair)
                continue
            name, sha = pair.split('=', 1)
            if embedded.get(name) != sha:
                failures.append("artifact %s mismatch: envelope %s != expected %s"
                                % (name, embedded.get(name), sha))

    if failures:
        print("[provenance-verify] FAIL:")
        for f in failures:
            print("  - %s" % f)
        return 1

    builder_id = stmt['builder']['id']
    revision = stmt['source']['revision']
    artifact_count = len(stmt['artifacts'])

    role_names = ', '.join('%d(%s)' % (r, ed25519_host.ROLE_NAMES[r]) for r in roles)
    print("[provenance-verify] PASS: builder=%s rev=%s artifacts=%d signed-by=[%s]"
          % (builder_id, revision[:12], artifact_count, role_names))
    if args.do_print:
        print(json.dumps(stmt, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
