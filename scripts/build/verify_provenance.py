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
#   4. (optional) --expect-revision REV : the embedded source.revision matches.
#   5. (optional) --expect-artifact NAME=SHA : an embedded artifact hash matches.
#
# Exit 0 = provenance verified; exit 1 = any failure.
# =============================================================================

import argparse
import json
import os
import struct
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'build'))

import ed25519_host           # noqa: E402
import write_envelope as we   # noqa: E402


def parse_envelope(blob):
    """Return (statement_dict, canonical_bytes, sig_block, kind, min_cosigners,
    allowed_mask, required_mask)."""
    if blob[:4] != b'GRSE':
        raise ValueError('bad magic (not a GRSE envelope)')
    schema, kind, domain, field_count, header_len = struct.unpack('<HHHHH', blob[4:14])
    payload_len = struct.unpack('<I', blob[14:18])[0]
    payload_start = header_len
    payload_end = payload_start + payload_len
    if payload_end > len(blob):
        raise ValueError('payload overruns envelope')
    payload = blob[payload_start:payload_end]
    canonical = blob[:payload_end]
    sig_block = blob[payload_end:]

    # Walk the TLV region to recover COSIGNER_ROLES (field id 10).
    min_cosigners = we.CLASS_MIN_COUNT.get(kind, 2)
    allowed_mask = 0x3F
    required_mask = we.CLASS_REQUIRED_MASK.get(kind, 0)
    off = 18

    def read_minimal(o):
        width = blob[o]
        o += 1
        v = int.from_bytes(blob[o:o + width], 'little')
        return v, o + width

    for _ in range(field_count):
        fid, off = read_minimal(off)
        vlen, off = read_minimal(off)
        val = blob[off:off + vlen]
        off += vlen
        if fid == 10 and vlen == 6:
            min_cosigners, allowed_mask, required_mask = struct.unpack('<HHH', val)

    stmt = json.loads(payload.decode('utf-8'))
    return (stmt, canonical, sig_block, kind,
            min_cosigners, allowed_mask, required_mask)


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
    except (ValueError, KeyError, json.JSONDecodeError) as e:
        print("[provenance-verify] FAIL: %s" % e)
        return 1

    failures = []
    if args.expect_revision:
        rev = stmt.get('source', {}).get('revision', '')
        if rev != args.expect_revision:
            failures.append("revision mismatch: envelope %s != expected %s"
                            % (rev, args.expect_revision))
    if args.expect_artifact:
        embedded = {a['name']: a['sha256'] for a in stmt.get('artifacts', [])}
        for pair in args.expect_artifact:
            name, sha = pair.split('=', 1)
            if embedded.get(name) != sha:
                failures.append("artifact %s mismatch: envelope %s != expected %s"
                                % (name, embedded.get(name), sha))

    if failures:
        print("[provenance-verify] FAIL:")
        for f in failures:
            print("  - %s" % f)
        return 1

    role_names = ', '.join('%d(%s)' % (r, ed25519_host.ROLE_NAMES[r]) for r in roles)
    print("[provenance-verify] PASS: builder=%s rev=%s artifacts=%d signed-by=[%s]"
          % (stmt['builder']['id'], stmt['source']['revision'][:12],
             len(stmt.get('artifacts', [])), role_names))
    if args.do_print:
        print(json.dumps(stmt, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
