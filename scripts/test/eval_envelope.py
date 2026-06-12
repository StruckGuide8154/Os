#!/usr/bin/env python3
# Track-2 (signed everything) reject-matrix evaluator.
#
# This does NOT re-implement the verifier. It parses the REAL GHL sources -
# the in-kernel reader `src/kernel/grithlk/envelope_reader.ghl` plus the two
# policy kernels it calls (`signed_envelope.ghl`, `signed_artifact_check.ghl`)
# - with the production compiler's own lexer/parser (gritc.lex / gritc.parse),
# then interprets `envelope_verify` against REAL envelope byte blobs, with the
# lb/lw/lq raw-memory builtins mapped onto the blob. So every reject-matrix
# case below executes the exact decode+decide logic that ships in the kernel.
#
# Each case builds a v1 envelope (docs/signed-artifact-envelope.md) and
# asserts the exact ENVR_* reason code, fulfilling the Track-2 requirement
# that every reject-matrix row has an executable negative test (and that a
# fully valid envelope is accepted).
#
# The interpreter supports the integer subset the modules use plus `while`
# (bounded) and byte loads. Anything else is a hard error, so it can never
# silently "pass" logic it did not actually evaluate.

import hashlib
import os
import struct
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
COMPILER_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler')
MODULES = [
    os.path.join(ROOT, 'src', 'tools', 'security', 'signed_envelope.ghl'),
    os.path.join(ROOT, 'src', 'tools', 'security', 'signed_artifact_check.ghl'),
    os.path.join(ROOT, 'src', 'tools', 'security', 'threshold_check.ghl'),
    os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'envelope_reader.ghl'),
]
MAX_LOOP_ITERS = 1 << 20

sys.path.insert(0, COMPILER_DIR)
import gritc  # noqa: E402  (the production GHL compiler - source of truth)


class EvalError(Exception):
    pass


class Unit:
    """The real reader + policy kernels, loaded as one same-unit namespace
    (mirroring how kernel_build.asm %includes them into one NASM unit)."""

    def __init__(self, paths):
        self.consts = {}
        self.fns = {}
        self.mem = b''
        for path in paths:
            with open(path, 'r', encoding='utf-8') as fh:
                src = fh.read()
            decls = gritc.parse(gritc.lex(src, path), path)
            for d in decls:
                k = d.get('k')
                if k == 'const':
                    if d.get('symbolic'):
                        continue
                    name, val = d['name'], d['val']
                    if name in self.consts and self.consts[name] != val:
                        raise EvalError(
                            "const %s disagrees across modules (%d vs %d)"
                            % (name, self.consts[name], val))
                    self.consts[name] = val
                elif k == 'fn':
                    if d.get('regparams') or d.get('naked'):
                        raise EvalError("fn '%s' is register-param/naked" % d['name'])
                    if d['name'] in self.fns:
                        raise EvalError("duplicate fn across modules: %s" % d['name'])
                    self.fns[d['name']] = d

    # --- memory builtins (the blob under test) -----------------------------

    def _load(self, addr, size, signed):
        if addr < 0 or addr + size > len(self.mem):
            raise EvalError("out-of-blob load at 0x%x size %d (blob %d bytes) - "
                            "the reader walked outside its bounds"
                            % (addr, size, len(self.mem)))
        fmt = {1: 'B', 4: ('i' if signed else 'I'), 8: 'Q'}[size]
        return struct.unpack_from('<' + fmt, self.mem, addr)[0]

    # --- interpreter (integer subset + while + loads) ----------------------

    def call(self, name, args):
        if name == 'lb':
            return self._load(args[0], 1, False)
        if name == 'lw':
            return self._load(args[0], 4, True)   # movsxd: sign-extended dword
        if name == 'lq':
            return self._load(args[0], 8, False)
        if name not in self.fns:
            raise EvalError("no such fn: %s" % name)
        fn = self.fns[name]
        params = fn['params']
        if len(args) != len(params):
            raise EvalError("%s expects %d args, got %d" % (name, len(params), len(args)))
        env = dict(zip(params, args))
        ret = self._exec_block(fn['body'], env)
        if ret is None:
            raise EvalError("%s fell through without returning" % name)
        return ret

    def _exec_block(self, stmts, env):
        for st in stmts:
            r = self._exec_stmt(st, env)
            if r is not None:
                return r
        return None

    def _exec_stmt(self, st, env):
        k = st['k']
        if k == 'return':
            if st['expr'] is None:
                raise EvalError("bare `return;` not supported")
            return self._eval(st['expr'], env)
        if k == 'let':
            env[st['name']] = self._eval(st['expr'], env)
            return None
        if k == 'assign':
            lhs = st['lhs']
            if lhs.get('k') != 'ident':
                raise EvalError("only simple-variable assignment supported")
            env[lhs['name']] = self._eval(st['rhs'], env)
            return None
        if k == 'if':
            if self._eval(st['cond'], env) != 0:
                return self._exec_block(st['then'], env)
            if st['els'] is not None:
                return self._exec_block(st['els'], env)
            return None
        if k == 'while':
            iters = 0
            while self._eval(st['cond'], env) != 0:
                iters += 1
                if iters > MAX_LOOP_ITERS:
                    raise EvalError("while loop exceeded %d iterations" % MAX_LOOP_ITERS)
                r = self._exec_block(st['body'], env)
                if r is not None:
                    return r
            return None
        if k == 'expr':
            self._eval(st['expr'], env)
            return None
        raise EvalError("unsupported statement: %s" % k)

    def _eval(self, e, env):
        k = e['k']
        if k == 'int':
            return e['val']
        if k == 'ident':
            nm = e['name']
            if nm in env:
                return env[nm]
            if nm in self.consts:
                return self.consts[nm]
            raise EvalError("unknown identifier: %s" % nm)
        if k == 'neg':
            return -self._eval(e['expr'], env)
        if k == 'not':
            return 0 if self._eval(e['expr'], env) != 0 else 1
        if k == 'call':
            return self.call(e['name'], [self._eval(a, env) for a in e['args']])
        if k == 'bin':
            return self._binop(e['op'], self._eval(e['lhs'], env), self._eval(e['rhs'], env))
        raise EvalError("unsupported expression: %s" % k)

    def _binop(self, op, a, b):
        ops = {
            '&': lambda: a & b, '|': lambda: a | b, '^': lambda: a ^ b,
            '+': lambda: a + b, '-': lambda: a - b, '*': lambda: a * b,
            '<<': lambda: a << b, '>>': lambda: a >> b,
            '==': lambda: 1 if a == b else 0, '!=': lambda: 1 if a != b else 0,
            '<': lambda: 1 if a < b else 0, '>': lambda: 1 if a > b else 0,
            '<=': lambda: 1 if a <= b else 0, '>=': lambda: 1 if a >= b else 0,
            '&&': lambda: 1 if (a != 0 and b != 0) else 0,
            '||': lambda: 1 if (a != 0 or b != 0) else 0,
            '/': lambda: a // b, '%': lambda: a % b,
        }
        if op not in ops:
            raise EvalError("unsupported operator: %s" % op)
        return ops[op]()


# --------------------------- envelope builder -------------------------------

def enc_scalar(v):
    """Canonical minimal-width scalar: width byte + LE value."""
    if v <= 0xFF:
        return bytes([1, v])
    if v <= 0xFFFF:
        return bytes([2]) + struct.pack('<H', v)
    return bytes([4]) + struct.pack('<I', v)


def enc_tlv(field_id, value, id_width=None, len_width=None):
    """One canonical TLV record; widths overridable for negative tests."""
    def enc(v, width):
        if width is None:
            return enc_scalar(v)
        return bytes([width]) + v.to_bytes(width, 'little')
    return enc(field_id, id_width) + enc(len(value), len_width) + value


# Verifier context shared by all cases.
CTX = dict(now=1000, device_id=0x11, device_class=0x22,
           required_version=5, required_counter=3, required_epoch=2)

PAYLOAD = b'GritOS test artifact payload bytes'


def base_fields(unit, payload):
    c = unit.consts
    h = hashlib.sha256(payload).digest()
    return [
        (c['FIELD_ID_TYPE'], struct.pack('<H', c['ART_APP'])),
        (c['FIELD_ID_DOMAIN'], struct.pack('<H', 5)),                      # DOMAIN_APP
        (c['FIELD_ID_TARGET_DEVICE'], struct.pack('<HI', 1, CTX['device_id'])),  # EXACT
        (c['FIELD_ID_HASH'], h),
        (c['FIELD_ID_SCHEMA_VERSION'], struct.pack('<H', 1)),
        (c['FIELD_ID_SIGNER_ROLE'], struct.pack('<H', 4)),                 # ROLE_APP_STORE
        (c['FIELD_ID_VALIDITY'], struct.pack('<II', 500, 2000)),
        (c['FIELD_ID_MONOTONIC_VERSION'], struct.pack('<I', 5)),
        (c['FIELD_ID_ROLLBACK_COUNTER'], struct.pack('<I', 3)),
        (c['FIELD_ID_COSIGNER_ROLES'], struct.pack('<HHH', 2, 0x3F, 0x0C)),
        (c['FIELD_ID_REVOCATION_EPOCH'], struct.pack('<I', 2)),
        (c['FIELD_ID_BUILD_PROVENANCE'], b'\xAB' * 32),
        (c['FIELD_ID_POLICY_DEPENDENCY'], b'\xCD' * 32),
    ]


def build(unit, payload=PAYLOAD, fields=None, magic=b'GRSE', schema=1, kind=5,
          domain=5, field_count=None, header_len=None, payload_len=None,
          sig_len=64, tlv_raw=None, total_pad=0):
    """Assemble a v1 envelope; every knob overridable for negative tests."""
    if fields is None:
        fields = base_fields(unit, payload)
    tlv = b''.join(enc_tlv(fid, val) for fid, val in fields) if tlv_raw is None else tlv_raw
    if field_count is None:
        field_count = len(fields)
    real_header_len = 18 + len(tlv)
    if header_len is None:
        header_len = real_header_len
    if payload_len is None:
        payload_len = len(payload)
    blob = (magic + struct.pack('<HHHHH', schema, kind, domain, field_count,
                                header_len)
            + struct.pack('<I', payload_len)
            + tlv + payload + b'\x5A' * sig_len + b'\x00' * total_pad)
    return blob


def run_case(unit, blob, payload=PAYLOAD, total_len=None):
    """Place the blob + the caller-computed payload hash in fresh memory and
    interpret the real envelope_verify over it."""
    base = 0x1000
    digest = hashlib.sha256(payload).digest()
    mem = bytearray(base) + bytearray(blob)
    hash_ptr = len(mem)
    mem += digest
    unit.mem = bytes(mem)
    if total_len is None:
        total_len = len(blob)
    return unit.call('envelope_verify', [
        base, total_len, hash_ptr, CTX['now'], CTX['device_id'],
        CTX['device_class'], CTX['required_version'], CTX['required_counter'],
        CTX['required_epoch']])


def matrix_cases(unit):
    """name -> (expected ENVR_* const name, blob builder)."""
    c = unit.consts

    def mut(field_id, value):
        flds = [(fid, value if fid == field_id else val)
                for fid, val in base_fields(unit, PAYLOAD)]
        return build(unit, fields=flds)

    def drop(field_id):
        flds = [(fid, val) for fid, val in base_fields(unit, PAYLOAD)
                if fid != field_id]
        return build(unit, fields=flds)

    bad_hash = bytearray(hashlib.sha256(PAYLOAD).digest())
    bad_hash[0] ^= 0xFF

    dup_tlv = b''.join(enc_tlv(fid, val) for fid, val in base_fields(unit, PAYLOAD))
    dup_tlv += enc_tlv(c['FIELD_ID_REVOCATION_EPOCH'], struct.pack('<I', 2))

    flds = base_fields(unit, PAYLOAD)
    noncanon_tlv = enc_tlv(flds[0][0], flds[0][1], id_width=2)  # id 1 in 2 bytes
    noncanon_tlv += b''.join(enc_tlv(fid, val) for fid, val in flds[1:])

    return {
        # -- reject matrix (docs/track2-signed-everything-todo.md) ----------
        'unsigned_artifact': ('ENVR_ERR_TILING', lambda: build(unit, sig_len=0)),
        'malformed_bad_magic': ('ENVR_ERR_MAGIC', lambda: build(unit, magic=b'EVIL')),
        'malformed_short': ('ENVR_ERR_BOUNDS', lambda: build(unit)[:10]),
        'malformed_overflow_offsets': ('ENVR_ERR_BOUNDS', lambda: build(unit, header_len=0xFFFF)),
        'mismatched_artifact_type': ('ENVR_ERR_TYPE_MISMATCH',
                                     lambda: mut(c['FIELD_ID_TYPE'], struct.pack('<H', c['ART_KERNEL']))),
        'wrong_target_domain': ('ENVR_ERR_TYPE_MISMATCH',
                                lambda: mut(c['FIELD_ID_DOMAIN'], struct.pack('<H', 2))),
        'wrong_target_device': ('ENVR_ERR_TARGET_DEVICE',
                                lambda: mut(c['FIELD_ID_TARGET_DEVICE'], struct.pack('<HI', 1, 0x99))),
        'wrong_target_device_class': ('ENVR_ERR_TARGET_DEVICE',
                                      lambda: mut(c['FIELD_ID_TARGET_DEVICE'], struct.pack('<HI', 2, 0x77))),
        'expired_signature_window': ('ENVR_ERR_WINDOW',
                                     lambda: mut(c['FIELD_ID_VALIDITY'], struct.pack('<II', 500, 900))),
        'not_yet_valid_window': ('ENVR_ERR_WINDOW',
                                 lambda: mut(c['FIELD_ID_VALIDITY'], struct.pack('<II', 1500, 2000))),
        'stale_revocation_epoch': ('ENVR_ERR_EPOCH',
                                   lambda: mut(c['FIELD_ID_REVOCATION_EPOCH'], struct.pack('<I', 1))),
        'replayed_artifact': ('ENVR_ERR_REPLAY',
                              lambda: mut(c['FIELD_ID_ROLLBACK_COUNTER'], struct.pack('<I', 2))),
        'downgraded_artifact': ('ENVR_ERR_DOWNGRADE',
                                lambda: mut(c['FIELD_ID_MONOTONIC_VERSION'], struct.pack('<I', 4))),
        'wrong_role_for_type': ('ENVR_ERR_ROLE',
                                lambda: mut(c['FIELD_ID_SIGNER_ROLE'], struct.pack('<H', 3))),
        'payload_hash_mismatch': ('ENVR_ERR_HASH_MISMATCH',
                                  lambda: mut(c['FIELD_ID_HASH'], bytes(bad_hash))),
        'missing_required_field': ('ENVR_ERR_MISSING_FIELD',
                                   lambda: drop(c['FIELD_ID_POLICY_DEPENDENCY'])),
        'duplicate_field': ('ENVR_ERR_TLV_ORDER',
                            lambda: build(unit, tlv_raw=dup_tlv, field_count=14)),
        'noncanonical_scalar_width': ('ENVR_ERR_TLV_CANONICAL',
                                      lambda: build(unit, tlv_raw=noncanon_tlv)),
        # -- additional structural negatives --------------------------------
        'trailing_garbage_in_header': ('ENVR_ERR_TRAILING',
                                       lambda: build(unit, tlv_raw=dup_tlv[:-7] + b'\x00' * 7,
                                                     field_count=13)),
        # signature_len is DERIVED (total - header - payload), so a gap between
        # payload and signatures cannot exist as such: it surfaces as a
        # non-multiple-of-64 signature region and is rejected there.
        'payload_signature_gap': ('ENVR_ERR_SIGBLOCK',
                                  lambda: build(unit, total_pad=8)),
        'oversized_signature_block': ('ENVR_ERR_TILING',
                                      lambda: build(unit, sig_len=4160)),
        'partial_signature_block': ('ENVR_ERR_SIGBLOCK',
                                    lambda: build(unit, sig_len=96)),
        'unknown_critical_field': ('ENVR_ERR_TLV_UNKNOWN',
                                   lambda: build(unit, tlv_raw=dup_tlv[:0]
                                                 + b''.join(enc_tlv(f, v) for f, v in base_fields(unit, PAYLOAD))
                                                 + enc_tlv(40, b'\x01'),
                                                 field_count=14)),
        'bad_field_count_range': ('ENVR_ERR_HEADER', lambda: build(unit, field_count=70)),
        # -- quorum / threshold cases ----------------------------------------
        # ART_APP class floor: min_count>=2, required_mask must include POLICY(4).
        # Declare min_count=1 (below the class floor of 2).
        'quorum_count_below_class_floor': ('ENVR_ERR_QUORUM',
                                           lambda: mut(c['FIELD_ID_COSIGNER_ROLES'],
                                                       struct.pack('<HHH', 1, 0x3F, 0x0C))),
        # required_mask=0x03 (BOOT+KERNEL) but ART_APP requires POLICY(4) in required_mask.
        'quorum_missing_required_role': ('ENVR_ERR_QUORUM',
                                         lambda: mut(c['FIELD_ID_COSIGNER_ROLES'],
                                                     struct.pack('<HHH', 2, 0x3F, 0x03))),
        # allowed_mask=0x01 (only BOOT) - popcount(1) < min_count(2), rule invalid.
        'quorum_allowed_mask_too_narrow': ('ENVR_ERR_QUORUM',
                                           lambda: mut(c['FIELD_ID_COSIGNER_ROLES'],
                                                       struct.pack('<HHH', 2, 0x01, 0x01))),
        # -- the accept case -------------------------------------------------
        'valid_envelope_accept': ('ENVR_OK', lambda: build(unit)),
    }


FIXTURE_DIR = os.path.join(ROOT, 'tests', 'security', 'fixtures', 'signed_envelope')


def fixture_case_names():
    """Every signed_envelope fixture that names a matrix_case must map to a
    real executable case here - keeps the .fixture files and this evaluator
    from drifting apart."""
    names = []
    if not os.path.isdir(FIXTURE_DIR):
        return names
    for fname in sorted(os.listdir(FIXTURE_DIR)):
        if not fname.endswith('.fixture'):
            continue
        with open(os.path.join(FIXTURE_DIR, fname), 'r', encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if line.startswith('matrix_case'):
                    names.append((fname, line.split('=', 1)[1].strip()))
    return names


def main():
    unit = Unit(MODULES)
    cases = matrix_cases(unit)
    failures = []
    for fname, case_name in fixture_case_names():
        if case_name not in cases:
            failures.append("fixture %s names unknown matrix_case '%s'"
                            % (fname, case_name))
    for name in sorted(cases):
        want_name, builder = cases[name]
        want = unit.consts[want_name]
        try:
            got = run_case(unit, builder())
        except EvalError as e:
            failures.append("%s raised: %s" % (name, e))
            print("[envelope] %-32s -> EvalError  expect %s  [FAIL]" % (name, want_name))
            continue
        ok = (got == want)
        print("[envelope] %-32s -> %-2d expect %-2d (%s)  [%s]"
              % (name, got, want, want_name, 'ok' if ok else 'FAIL'))
        if not ok:
            failures.append("%s returned %d, expected %d (%s)"
                            % (name, got, want, want_name))

    accepts = sum(1 for n in cases if cases[n][0] == 'ENVR_OK')
    rejects = len(cases) - accepts
    print("[envelope] executed envelope_verify (real kernel GHL source) on "
          "%d case(s): %d accept, %d reject" % (len(cases), accepts, rejects))
    if failures:
        sys.stderr.write("[envelope] FAIL - %d problem(s):\n" % len(failures))
        for f in failures:
            sys.stderr.write("  - %s\n" % f)
        return 1
    print("[envelope] reject matrix fully enforced; valid envelope accepted")
    return 0


if __name__ == '__main__':
    sys.exit(main())
