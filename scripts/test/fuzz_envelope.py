#!/usr/bin/env python3
# Track-2 (signed everything) P1 parser-safety suite: fuzz + differential +
# canonical round-trip property tests over the REAL in-kernel envelope reader.
#
# Builds on eval_envelope.py's interpreter, which executes the production GHL
# sources (envelope_reader.ghl + policy kernels) via the production compiler's
# lexer/parser. Three Track-2 P1 requirements are covered:
#
#   1. FUZZ - structure-aware mutations (malformed TLV, length overflow,
#      duplicate fields, unknown critical ids, width games, truncation,
#      splices) plus raw random blobs are fed to the interpreted
#      `envelope_verify`. Safety invariants per input:
#        - the reader never loads outside [base, base+total_len)
#          (the fuzz memory layout places the blob at the END of the
#          interpreter address space, so ANY overread raises),
#        - the bounded-loop cap is never hit (no unbounded walk),
#        - the result is a defined ENVR_* code.
#   2. DIFFERENTIAL - an independent clean-room Python verifier (`ref_verify`,
#      written from docs/signed-artifact-envelope.md + the policy tables, NOT
#      from the reader's control flow) must agree accept/reject with the
#      kernel reader on every input.
#   3. PROPERTY - for every ACCEPTED envelope x:
#      canonicalize(decode(x)) == x  (decode to fields, re-emit the canonical
#      wire encoding, byte-identical).
#
# Deterministic by default (fixed seed) so CI is reproducible; pass
# --seed/--iters to explore.

import argparse
import hashlib
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_envelope as ev  # the reject-matrix evaluator: real-source interpreter

# ---------------------------------------------------------------------------
# Kernel-side execution (the real GHL reader, interpreted)
# ---------------------------------------------------------------------------

DIGEST_AT = 0x100          # caller-computed payload hash lives BELOW the blob
BLOB_AT = DIGEST_AT + 32   # blob is the LAST thing in memory: overread => raise


def kernel_verify(unit, blob, digest):
    """Run the real envelope_verify with the blob at the end of the address
    space so any out-of-bounds load raises EvalError (a safety failure)."""
    mem = bytearray(DIGEST_AT) + digest + blob
    unit.mem = bytes(mem)
    c = ev.CTX
    return unit.call('envelope_verify', [
        BLOB_AT, len(blob), DIGEST_AT, c['now'], c['device_id'],
        c['device_class'], c['required_version'], c['required_counter'],
        c['required_epoch']])


# ---------------------------------------------------------------------------
# Independent reference verifier (clean-room from the spec + policy tables)
# ---------------------------------------------------------------------------

FIELD_LEN = {1: 2, 2: 2, 3: 6, 4: 32, 5: 2, 6: 2, 7: 8, 8: 4, 9: 4,
             10: 6, 11: 4, 12: 32, 13: 32}
ROLE_FOR_KIND = {1: (1,), 2: (2,), 3: (2,), 4: (3,), 5: (4,), 6: (5,),
                 7: (5,), 8: (6,), 9: (7,)}
CLASS_MIN = {1: 3, 2: 3, 3: 3, 4: 2, 5: 2, 6: 2, 7: 2, 8: 3, 9: 3}
CLASS_REQ = {1: 3, 2: 3, 3: 3, 4: 4, 5: 4, 6: 4, 7: 4, 8: 11, 9: 19}
ALL_ROLES = 63
REQUIRED_BASE = 4095        # field bits 0..11
REQUIRED_RUNNABLE = 8191    # + POLICY_DEPENDENCY for kinds 1..5
MAX_TOTAL = 16777216
MAX_PAYLOAD = 8388608
MAX_SIG = 4096


def _canonical_width_ok(width, value):
    if width == 1:
        return value <= 0xFF
    if width == 2:
        return 0xFF < value <= 0xFFFF
    if width == 4:
        return value > 0xFFFF
    return False


def ref_decode(blob):
    """Independent decoder: returns (header tuple, ordered field list,
    payload bytes, sig bytes) or None on any structural violation."""
    n = len(blob)
    if n < 18 or n > MAX_TOTAL:
        return None
    if blob[0:4] != b'GRSE':
        return None
    schema, kind, domain, field_count, header_len = struct.unpack_from('<HHHHH', blob, 4)
    payload_len = struct.unpack_from('<I', blob, 14)[0]
    if schema != 1 or not 1 <= kind <= 9 or not 1 <= domain <= 7:
        return None
    if not 12 <= field_count <= 64:
        return None
    if header_len < 18 or header_len > n:
        return None
    if payload_len > MAX_PAYLOAD or header_len + payload_len > n:
        return None
    sig_len = n - header_len - payload_len
    if sig_len <= 0 or sig_len > MAX_SIG or sig_len % 64 != 0:
        return None
    # TLV region [18, header_len): strictly ascending known ids, canonical
    # minimal widths, exact per-id value lengths, exact tiling.
    p, prev_id, fields = 18, 0, []
    for _ in range(field_count):
        if p + 1 > header_len:
            return None
        id_width = blob[p]
        if id_width not in (1, 2, 4) or p + 2 + id_width > header_len:
            return None
        field_id = int.from_bytes(blob[p + 1:p + 1 + id_width], 'little')
        len_width = blob[p + 1 + id_width]
        if len_width not in (1, 2, 4) or p + 2 + id_width + len_width > header_len:
            return None
        field_len = int.from_bytes(blob[p + 2 + id_width:p + 2 + id_width + len_width], 'little')
        vptr = p + 2 + id_width + len_width
        if vptr + field_len > header_len:
            return None
        if not _canonical_width_ok(id_width, field_id):
            return None
        if not _canonical_width_ok(len_width, field_len):
            return None
        if field_id <= prev_id:
            return None
        if FIELD_LEN.get(field_id, 0) != field_len:
            return None
        fields.append((field_id, blob[vptr:vptr + field_len]))
        prev_id = field_id
        p = vptr + field_len
    if p != header_len:
        return None
    payload = blob[header_len:header_len + payload_len]
    sigs = blob[header_len + payload_len:]
    return (schema, kind, domain, field_count, header_len, payload_len), fields, payload, sigs


def ref_verify(blob, digest, ctx):
    """Clean-room accept/reject decision (True = accept)."""
    dec = ref_decode(blob)
    if dec is None:
        return False
    (schema, kind, domain, _fc, _hl, _pl), fields, payload, _sigs = dec
    f = dict(fields)
    required = REQUIRED_RUNNABLE if kind <= 5 else REQUIRED_BASE
    present = 0
    for fid, _ in fields:
        present |= 1 << (fid - 1)
    if (present & required) != required:
        return False
    # signed routing fields must match the unsigned header
    if struct.unpack('<H', f[1])[0] != kind:
        return False
    if struct.unpack('<H', f[2])[0] != domain:
        return False
    if struct.unpack('<H', f[5])[0] != 1:
        return False
    epoch = struct.unpack('<I', f[11])[0]
    if epoch < 1 or epoch < ctx['required_epoch']:
        return False
    tk, tv = struct.unpack('<HI', f[3])
    if tv == 0:
        return False
    if tk == 1:
        if ctx['device_id'] == 0 or tv != ctx['device_id']:
            return False
    elif tk == 2:
        if ctx['device_class'] == 0 or tv != ctx['device_class']:
            return False
    else:
        return False
    role = struct.unpack('<H', f[6])[0]
    if role not in ROLE_FOR_KIND[kind]:
        return False
    nb, na = struct.unpack('<II', f[7])
    if na < nb or ctx['now'] < nb or ctx['now'] > na:
        return False
    if struct.unpack('<I', f[8])[0] < ctx['required_version']:
        return False
    if struct.unpack('<I', f[9])[0] < ctx['required_counter']:
        return False
    if f[4] != digest:
        return False
    min_count, allowed, req = struct.unpack('<HHH', f[10])
    if min_count < CLASS_MIN[kind]:
        return False
    if (req & CLASS_REQ[kind]) != CLASS_REQ[kind]:
        return False
    if (allowed & req) != req:
        return False
    if allowed == 0 or (allowed & ALL_ROLES) != allowed:
        return False
    if bin(allowed & ALL_ROLES).count('1') < min_count:
        return False
    return True


def canonicalize(blob):
    """Re-emit the canonical wire encoding from the decoded structure.
    Property: byte-identical to the input for every accepted envelope."""
    dec = ref_decode(blob)
    if dec is None:
        return None
    (schema, kind, domain, field_count, _hl, payload_len), fields, payload, sigs = dec
    tlv = b''.join(ev.enc_tlv(fid, val) for fid, val in fields)
    return (b'GRSE'
            + struct.pack('<HHHHH', schema, kind, domain, field_count, 18 + len(tlv))
            + struct.pack('<I', payload_len)
            + tlv + payload + sigs)


# ---------------------------------------------------------------------------
# Corpus: valid envelopes across every artifact class
# ---------------------------------------------------------------------------

PAYLOADS = [b'', b'A', b'GritOS fuzz corpus payload ' * 3, bytes(range(256))]


def corpus_fields(unit, kind, domain, payload, target_kind):
    c = unit.consts
    target_value = ev.CTX['device_id'] if target_kind == 1 else ev.CTX['device_class']
    return [
        (c['FIELD_ID_TYPE'], struct.pack('<H', kind)),
        (c['FIELD_ID_DOMAIN'], struct.pack('<H', domain)),
        (c['FIELD_ID_TARGET_DEVICE'], struct.pack('<HI', target_kind, target_value)),
        (c['FIELD_ID_HASH'], hashlib.sha256(payload).digest()),
        (c['FIELD_ID_SCHEMA_VERSION'], struct.pack('<H', 1)),
        (c['FIELD_ID_SIGNER_ROLE'], struct.pack('<H', ROLE_FOR_KIND[kind][0])),
        (c['FIELD_ID_VALIDITY'], struct.pack('<II', 500, 2000)),
        (c['FIELD_ID_MONOTONIC_VERSION'], struct.pack('<I', 5)),
        (c['FIELD_ID_ROLLBACK_COUNTER'], struct.pack('<I', 3)),
        (c['FIELD_ID_COSIGNER_ROLES'],
         struct.pack('<HHH', CLASS_MIN[kind], ALL_ROLES, CLASS_REQ[kind])),
        (c['FIELD_ID_REVOCATION_EPOCH'], struct.pack('<I', 2)),
        (c['FIELD_ID_BUILD_PROVENANCE'], b'\xAB' * 32),
        (c['FIELD_ID_POLICY_DEPENDENCY'], b'\xCD' * 32),
    ]


def build_corpus(unit):
    """(blob, fields, payload) per (kind, domain, target-kind, payload) combo."""
    out = []
    for kind in range(1, 10):
        for domain in (1, 4, 7):
            for tk in (1, 2):
                payload = PAYLOADS[(kind + domain + tk) % len(PAYLOADS)]
                fields = corpus_fields(unit, kind, domain, payload, tk)
                blob = ev.build(unit, payload=payload, fields=fields,
                                kind=kind, domain=domain,
                                sig_len=64 * CLASS_MIN[kind])
                out.append((blob, fields, payload))
    return out


# ---------------------------------------------------------------------------
# Mutators (structure-aware + dumb)
# ---------------------------------------------------------------------------

def mutate(rng, unit, item):
    """Return a mutated blob from a corpus item (blob, fields, payload)."""
    blob, fields, payload = item
    kind = rng.randrange(15)

    def rebuild(flds, **kw):
        kw.setdefault('payload', payload)
        kw.setdefault('kind', struct.unpack_from('<H', blob, 6)[0])
        kw.setdefault('domain', struct.unpack_from('<H', blob, 8)[0])
        kw.setdefault('sig_len', len(blob) - struct.unpack_from('<H', blob, 12)[0] - len(payload))
        return ev.build(unit, fields=flds, **kw)

    if kind == 0:    # flip 1..8 random bytes anywhere
        b = bytearray(blob)
        for _ in range(rng.randrange(1, 9)):
            i = rng.randrange(len(b))
            b[i] ^= rng.randrange(1, 256)
        return bytes(b)
    if kind == 1:    # truncate
        return blob[:rng.randrange(len(blob))]
    if kind == 2:    # extend with junk
        return blob + bytes(rng.randrange(256) for _ in range(rng.randrange(1, 200)))
    if kind == 3:    # hammer a header scalar with an extreme
        b = bytearray(blob)
        off = rng.choice((4, 6, 8, 10, 12))
        struct.pack_into('<H', b, off,
                         rng.choice((0, 1, 0xFF, 0x100, 0xFFFF, len(blob) & 0xFFFF)))
        return bytes(b)
    if kind == 4:    # payload_len overflow games
        b = bytearray(blob)
        struct.pack_into('<I', b, 14, rng.choice(
            (0, 1, len(blob), len(blob) - 18, 0x7FFFFFFF, 0xFFFFFFFF,
             MAX_PAYLOAD, MAX_PAYLOAD + 1)))
        return bytes(b)
    if kind == 5:    # duplicate a field
        i = rng.randrange(len(fields))
        return rebuild(fields + [fields[i]], field_count=len(fields) + 1)
    if kind == 6:    # shuffle field order
        flds = list(fields)
        rng.shuffle(flds)
        return rebuild(flds)
    if kind == 7:    # drop a field
        i = rng.randrange(len(fields))
        return rebuild(fields[:i] + fields[i + 1:], field_count=len(fields) - 1)
    if kind == 8:    # unknown critical id (incl. huge / path-traversal-ish blob)
        fid = rng.choice((14, 40, 255, 0x1234, 0xFFFFFFF0))
        val = rng.choice((b'\x01', b'../../boot' * 4, bytes(64)))
        return rebuild(fields + [(fid, val)], field_count=len(fields) + 1)
    if kind == 9:    # non-minimal scalar width on a random record
        i = rng.randrange(len(fields))
        widths = {'id_width': rng.choice((2, 4))} if rng.random() < 0.5 \
            else {'len_width': rng.choice((2, 4))}
        tlv = b''
        for j, (fid, val) in enumerate(fields):
            tlv += ev.enc_tlv(fid, val, **(widths if j == i else {}))
        return rebuild(fields, tlv_raw=tlv)
    if kind == 10:   # wrong value length for a known field
        i = rng.randrange(len(fields))
        fid, val = fields[i]
        val = val + b'\x00' if rng.random() < 0.5 else val[:-1]
        return rebuild(fields[:i] + [(fid, val)] + fields[i + 1:])
    if kind == 11:   # signature block length games
        return rebuild(fields, sig_len=rng.choice(
            (0, 1, 63, 65, 96, 4096, 4097, 4160, 64 * 64, 64 * 65)))
    if kind == 12:   # field_count lies
        return rebuild(fields, field_count=rng.choice((0, 1, 11, 12, 14, 64, 65, 0xFFFF)))
    if kind == 13:   # mutate one field's value bytes (stays canonical)
        i = rng.randrange(len(fields))
        fid, val = fields[i]
        v = bytearray(val)
        v[rng.randrange(len(v))] ^= rng.randrange(1, 256)
        return rebuild(fields[:i] + [(fid, bytes(v))] + fields[i + 1:])
    # kind == 14: splice the front of this blob onto the tail of another
    cut = rng.randrange(1, len(blob))
    return blob[:cut] + blob[-(rng.randrange(1, len(blob))):]


def random_blob(rng):
    n = rng.randrange(0, 600)
    b = bytes(rng.randrange(256) for _ in range(n))
    if rng.random() < 0.5 and n >= 4:   # half get the magic so they go deeper
        b = b'GRSE' + b[4:]
    return b


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def digest_for(blob):
    """The payload SHA-256 the CALLER would compute (it hashes whatever the
    header says is the payload region; garbage headers hash empty)."""
    if len(blob) >= 18:
        header_len = struct.unpack_from('<H', blob, 12)[0]
        payload_len = struct.unpack_from('<I', blob, 14)[0]
        if 18 <= header_len <= len(blob) and header_len + payload_len <= len(blob):
            return hashlib.sha256(blob[header_len:header_len + payload_len]).digest()
    return hashlib.sha256(b'').digest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--iters', type=int, default=1500)
    ap.add_argument('--seed', type=int, default=20260610)
    args = ap.parse_args()

    unit = ev.Unit(ev.MODULES)
    valid_codes = set(v for k, v in unit.consts.items()
                      if k == 'ENVR_OK' or k.startswith('ENVR_ERR_'))
    rng = random.Random(args.seed)
    corpus = build_corpus(unit)
    failures = []
    accepts = rejects = 0

    def check(label, blob):
        nonlocal accepts, rejects
        digest = digest_for(blob)
        try:
            code = kernel_verify(unit, blob, digest)
        except ev.EvalError as e:
            failures.append('%s: reader SAFETY violation: %s (blob %d bytes: %s...)'
                            % (label, e, len(blob), blob[:32].hex()))
            return
        if code not in valid_codes:
            failures.append('%s: undefined reason code %d' % (label, code))
            return
        accepted = (code == unit.consts['ENVR_OK'])
        ref = ref_verify(blob, digest, ev.CTX)
        if accepted != ref:
            failures.append('%s: DIFFERENTIAL split - kernel=%s(code %d) ref=%s '
                            '(blob %d bytes: %s...)'
                            % (label, 'accept' if accepted else 'reject', code,
                               'accept' if ref else 'reject', len(blob),
                               blob[:48].hex()))
            return
        if accepted:
            accepts += 1
            canon = canonicalize(blob)
            if canon != blob:
                failures.append('%s: PROPERTY canonicalize(decode(x)) != x '
                                '(%d vs %d bytes)' % (label, len(canon or b''),
                                                      len(blob)))
        else:
            rejects += 1

    # 1) every corpus envelope must be accepted by BOTH and round-trip
    for i, (blob, _f, _p) in enumerate(corpus):
        check('corpus[%d]' % i, blob)
    if accepts != len(corpus):
        failures.append('corpus: only %d/%d valid envelopes accepted'
                        % (accepts, len(corpus)))

    # 2) fuzz: structure-aware mutations of corpus items + raw random blobs
    for i in range(args.iters):
        if i % 5 == 4:
            blob = random_blob(rng)
        else:
            blob = mutate(rng, unit, corpus[rng.randrange(len(corpus))])
        check('fuzz[%d]' % i, blob)

    print('[envelope-fuzz] %d corpus + %d fuzz inputs: %d accepted, %d rejected '
          '(seed %d)' % (len(corpus), args.iters, accepts, rejects, args.seed))
    if failures:
        sys.stderr.write('[envelope-fuzz] FAIL - %d problem(s):\n' % len(failures))
        for f in failures[:25]:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[envelope-fuzz] no safety violations, no differential splits, '
          'canonical round-trip holds on all accepts')
    return 0


if __name__ == '__main__':
    sys.exit(main())
