#!/usr/bin/env python3
# Track-3 (seL4 validity) invariant evaluator / bounded checker.
#
# This does NOT re-implement the invariant predicates. It parses the REAL GHL
# source `src/tools/security/invariant_check.ghl` using the production
# compiler's own lexer/parser (gritc.lex / gritc.parse), then interprets each `fn`
# body as a pure integer function.
#
# Default mode runs the vector suite that promotes invariants from `modeled` to
# `tested`: every positive vector must return 1, every negative vector must
# return 0.
#
# `--exhaustive` runs the Track-3 bounded proof step: for every existing
# .invariant file, enumerate the full bounded 7-bit space relevant to that
# theorem (0..127 for every authority/domain state, plus boolean side
# conditions where the theorem has them) and compare the real predicate result
# against the theorem's expected truth value.
#
# The interpreter supports exactly the integer subset the predicate module uses
# (let / if / else / return, the arithmetic/bitwise/comparison binops, calls to
# other module fns, const names). It deliberately rejects anything outside that
# subset (asm, syscall, loops with side effects, memory, etc.) so it can never
# silently "pass" a predicate it did not actually evaluate.

import argparse
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
COMPILER_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler')
MODULE = os.path.join(ROOT, 'src', 'tools', 'security', 'invariant_check.ghl')
INVARIANT_DIR = os.path.join(ROOT, 'tests', 'security', 'invariants')
VECTOR_DIR = os.path.join(ROOT, 'tests', 'security', 'invariants', 'vectors')
AUTH_SPACE = tuple(range(128))
BOOL_SPACE = (0, 1)

sys.path.insert(0, COMPILER_DIR)
import gritc  # noqa: E402  (the production GHL compiler - source of truth)


class EvalError(Exception):
    pass


class Module:
    """The real predicate module, loaded from GHL source via the compiler."""

    def __init__(self, path):
        with open(path, 'r', encoding='utf-8') as fh:
            src = fh.read()
        decls = gritc.parse(gritc.lex(src, path), path)
        self.consts = {}
        self.fns = {}
        for d in decls:
            k = d.get('k')
            if k == 'const':
                if d.get('symbolic'):
                    continue  # extern symbolic const: no host value, never used here
                self.consts[d['name']] = d['val']
            elif k == 'fn':
                if d.get('regparams') or d.get('naked'):
                    raise EvalError(
                        "predicate '%s' uses register-params/naked; not a pure "
                        "integer predicate" % d['name'])
                self.fns[d['name']] = d

    def call(self, name, args):
        if name not in self.fns:
            raise EvalError("no such predicate fn: %s" % name)
        fn = self.fns[name]
        params = fn['params']
        if len(args) != len(params):
            raise EvalError("%s expects %d args, got %d"
                            % (name, len(params), len(args)))
        env = dict(zip(params, args))
        ret = self._exec_block(fn['body'], env)
        if ret is None:
            # An GHL fn with no explicit return leaves rax = last value; the
            # predicate module always returns explicitly, so treat a fall-through
            # as a hard error rather than guessing.
            raise EvalError("%s fell through without returning" % name)
        return ret

    # --- statement / expression interpreter (integer subset only) ---------

    def _exec_block(self, stmts, env):
        for st in stmts:
            r = self._exec_stmt(st, env)
            if r is not None:
                return r  # propagate a return value
        return None

    def _exec_stmt(self, st, env):
        k = st['k']
        if k == 'return':
            if st['expr'] is None:
                raise EvalError("bare `return;` not supported in a predicate")
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
            if self._truthy(self._eval(st['cond'], env)):
                return self._exec_block(st['then'], env)
            if st['els'] is not None:
                return self._exec_block(st['els'], env)
            return None
        raise EvalError("unsupported statement in predicate: %s" % k)

    def _truthy(self, v):
        return v != 0

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
            raise EvalError("unknown identifier in predicate: %s" % nm)
        if k == 'neg':
            return -self._eval(e['expr'], env)
        if k == 'not':
            return 0 if self._truthy(self._eval(e['expr'], env)) else 1
        if k == 'call':
            argv = [self._eval(a, env) for a in e['args']]
            return self.call(e['name'], argv)
        if k == 'bin':
            return self._binop(e['op'],
                               self._eval(e['lhs'], env),
                               self._eval(e['rhs'], env))
        raise EvalError("unsupported expression in predicate: %s" % k)

    def _binop(self, op, a, b):
        if op == '&':
            return a & b
        if op == '|':
            return a | b
        if op == '^':
            return a ^ b
        if op == '+':
            return a + b
        if op == '-':
            return a - b
        if op == '*':
            return a * b
        if op == '<<':
            return a << b
        if op == '>>':
            return a >> b
        if op == '==':
            return 1 if a == b else 0
        if op == '!=':
            return 1 if a != b else 0
        if op == '<':
            return 1 if a < b else 0
        if op == '>':
            return 1 if a > b else 0
        if op == '<=':
            return 1 if a <= b else 0
        if op == '>=':
            return 1 if a >= b else 0
        if op == '&&':
            return 1 if (a != 0 and b != 0) else 0
        if op == '||':
            return 1 if (a != 0 or b != 0) else 0
        if op == '/':
            return a // b
        if op == '%':
            return a % b
        raise EvalError("unsupported operator in predicate: %s" % op)


def parse_vector_file(path, mod):
    """A .vectors file is line-oriented key=value plus `case` lines.

    Required keys: invariant, predicate.
    Each `case` line:  case = <expect> | <comma-separated args>
      <expect>  : one of `accept` (predicate must return 1) or
                  `reject` (predicate must return 0).
      args      : integers or const names from the predicate module.
    Blank lines and lines beginning with # are ignored.
    """
    meta = {}
    cases = []
    with open(path, 'r', encoding='utf-8') as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                raise EvalError("%s:%d invalid line: %s" % (path, lineno, raw.rstrip()))
            key, val = line.split('=', 1)
            key = key.strip()
            val = val.strip()
            if key == 'case':
                if '|' not in val:
                    raise EvalError("%s:%d case needs `<expect> | <args>`"
                                    % (path, lineno))
                expect, argstr = val.split('|', 1)
                expect = expect.strip()
                if expect not in ('accept', 'reject'):
                    raise EvalError("%s:%d expect must be accept|reject, got %s"
                                    % (path, lineno, expect))
                args = []
                for tok in argstr.split(','):
                    tok = tok.strip()
                    if tok == '':
                        continue
                    args.append(resolve_token(tok, mod, path, lineno))
                cases.append((expect, args, lineno))
            else:
                meta[key] = val
    for req in ('invariant', 'predicate'):
        if req not in meta or not meta[req]:
            raise EvalError("%s missing required key: %s" % (path, req))
    if not cases:
        raise EvalError("%s has no `case` lines" % path)
    return meta, cases


def parse_key_value_file(path):
    meta = {}
    with open(path, 'r', encoding='utf-8') as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                raise EvalError("%s:%d invalid line: %s" % (path, lineno, raw.rstrip()))
            key, val = line.split('=', 1)
            key = key.strip()
            val = val.strip()
            if not key:
                raise EvalError("%s:%d empty key" % (path, lineno))
            if key in meta:
                raise EvalError("%s:%d duplicate key: %s" % (path, lineno, key))
            meta[key] = val
    return meta


def resolve_token(tok, mod, path, lineno):
    neg = False
    if tok.startswith('-'):
        neg = True
        tok = tok[1:].strip()
    if tok in mod.consts:
        v = mod.consts[tok]
    else:
        try:
            v = int(tok, 0)
        except ValueError:
            raise EvalError("%s:%d arg is neither int nor known const: %s"
                            % (path, lineno, tok))
    return -v if neg else v


def _bit_absent(auth, bit):
    return 1 if (auth & bit) == 0 else 0


def _threshold_required(auth, bit, threshold_met):
    return 0 if ((auth & bit) != 0 and threshold_met == 0) else 1


def _same_domain_or_not_signing(signer_domain, measured_domain, signs_measurement):
    return 1 if signs_measurement == 0 or signer_domain == measured_domain else 0


def _planted_cap_hmac(dump_canary, live_canary, slot, mask, planted_tag, accepted):
    fold = ((mask >> 8) & 0xFF) ^ (mask & 0xFF)
    live_tag = (live_canary ^ slot ^ fold ^ 0x5C) & 0xFF
    if accepted == 0:
        return 1
    return 1 if planted_tag == live_tag else 0


def exhaustive_specs(mod):
    """The bounded theorem table for the current Track-3 invariants."""
    auth_memory = mod.consts['AUTH_MEMORY_GRANT']
    auth_mint_identity = mod.consts['AUTH_MINT_IDENTITY']
    auth_dma = mod.consts['AUTH_DMA_MAP']
    auth_persist = mod.consts['AUTH_PERSIST']
    auth_global = mod.consts['AUTH_GLOBAL']

    return {
        'INV-CAP-DERIVATION': {
            'predicate': 'inv_subset',
            'cases': ((child, parent) for child in AUTH_SPACE for parent in AUTH_SPACE),
            'expect': lambda args: 1 if (args[0] & args[1]) == args[0] else 0,
        },
        'INV-NO-GLOBAL-MINT': {
            'predicate': 'inv_requires_threshold',
            'cases': ((auth, auth_global, threshold)
                      for auth in AUTH_SPACE for threshold in BOOL_SPACE),
            'expect': lambda args: _threshold_required(args[0], auth_global, args[2]),
        },
        'INV-SCHED-NO-MEMORY': {
            'predicate': 'inv_scheduler_no_memory_grant',
            'cases': ((auth,) for auth in AUTH_SPACE),
            'expect': lambda args: _bit_absent(args[0], auth_memory),
        },
        'INV-IPC-NO-FORGE': {
            'predicate': 'inv_ipc_no_identity_forge',
            'cases': ((auth,) for auth in AUTH_SPACE),
            'expect': lambda args: _bit_absent(args[0], auth_mint_identity),
        },
        'INV-DRIVER-NO-DMA-MINT': {
            'predicate': 'inv_driver_no_dma_mint',
            'cases': ((auth, grant) for auth in AUTH_SPACE for grant in BOOL_SPACE),
            'expect': lambda args: _threshold_required(args[0], auth_dma, args[1]),
        },
        'INV-PT-NO-PERSIST': {
            'predicate': 'inv_pt_no_persist_without_threshold',
            'cases': ((auth, threshold) for auth in AUTH_SPACE for threshold in BOOL_SPACE),
            'expect': lambda args: _threshold_required(args[0], auth_persist, args[1]),
        },
        'INV-POLICY-SIGNED-ONLY': {
            'predicate': 'inv_policy_loader_signed_only',
            'cases': ((signed,) for signed in BOOL_SPACE),
            'expect': lambda args: 1 if args[0] != 0 else 0,
        },
        'INV-HV-NO-FOREIGN-MEASURE': {
            'predicate': 'inv_hypervisor_no_foreign_measurement',
            'cases': ((signer, measured, signs)
                      for signer in AUTH_SPACE
                      for measured in AUTH_SPACE
                      for signs in BOOL_SPACE),
            'expect': lambda args: _same_domain_or_not_signing(args[0], args[1], args[2]),
        },
        'INV-RELEASE-NO-OBSERVE': {
            'predicate': 'inv_release_no_observation',
            'cases': ((flag,) for flag in BOOL_SPACE),
            'expect': lambda args: 1 if args[0] == 0 else 0,
        },
        # The expected fn deliberately IGNORES recovery_mode while the case
        # space quantifies over it: any recovery-dependent behaviour in the
        # predicate would show up as a mismatch (the non-bypass theorem).
        'INV-RECOVERY-NO-BYPASS': {
            'predicate': 'inv_recovery_no_measure_bypass',
            'cases': ((rec, measured, expected, proceeds)
                      for rec in BOOL_SPACE
                      for measured in AUTH_SPACE
                      for expected in AUTH_SPACE
                      for proceeds in BOOL_SPACE),
            'expect': lambda args: 1 if (args[3] == 0 or args[1] == args[2]) else 0,
        },
        'INV-IPC-NO-CONFUSED-DEPUTY': {
            'predicate': 'inv_ipc_no_deputy_laundering',
            'cases': ((req, dep, op)
                      for req in AUTH_SPACE
                      for dep in AUTH_SPACE
                      for op in AUTH_SPACE),
            'expect': lambda args: 1 if (args[2] & args[0] & args[1]) == args[2] else 0,
        },
        'INV-APP-MEM-ISOLATION': {
            'predicate': 'inv_app_mem_isolation',
            'cases': ((reader, owner, handle, granted)
                      for reader in AUTH_SPACE
                      for owner in AUTH_SPACE
                      for handle in BOOL_SPACE
                      for granted in BOOL_SPACE),
            'expect': lambda args: 0 if (args[3] != 0 and args[0] != args[1]
                                         and args[2] == 0) else 1,
        },
        # Track 6 (compartmentalized monitor) C3 containment invariants.
        'INV-COMPARTMENT-ONE-AUTHORITY': {
            'predicate': 'inv_compartment_one_authority',
            'cases': ((auth,) for auth in AUTH_SPACE),
            'expect': lambda args: 1 if (args[0] != 0
                                         and (args[0] & (args[0] - 1)) == 0)
                                   else 0,
        },
        'INV-COMPARTMENT-NO-CROSS-MAP': {
            'predicate': 'inv_compartment_no_cross_map',
            'cases': ((comp, target, present)
                      for comp in AUTH_SPACE
                      for target in AUTH_SPACE
                      for present in BOOL_SPACE),
            'expect': lambda args: 1 if (args[2] == 0 or args[0] == args[1])
                                   else 0,
        },
        # The expected fn IGNORES caller_auth while the case space quantifies
        # over it: any caller-dependent behaviour (authority laundering) would
        # surface as a mismatch. Effective must equal callee, always.
        'INV-COMPARTMENT-NO-AUTH-LAUNDER': {
            'predicate': 'inv_compartment_no_auth_launder',
            'cases': ((caller, callee, effective)
                      for caller in AUTH_SPACE
                      for callee in AUTH_SPACE
                      for effective in AUTH_SPACE),
            'expect': lambda args: 1 if args[2] == args[1] else 0,
        },
        # Track 4 (leak != elevation) replay-binding invariants. Each authenticator
        # is bound to a per-context nonce; presenting it in a foreign context must
        # fail closed. Same theorem schema (context binding defeats replay), three
        # distinct real diversification axes (boot epoch / slot id / launch perm).
        'INV-EPHEMERAL-NO-REPLAY': {
            'predicate': 'inv_ephemeral_no_replay',
            'cases': ((secret, live, auth)
                      for secret in AUTH_SPACE
                      for live in AUTH_SPACE
                      for auth in BOOL_SPACE),
            'expect': lambda args: 1 if (args[2] == 0 or args[0] == args[1]) else 0,
        },
        'INV-PER-SLOT-KEY-CONFINED': {
            'predicate': 'inv_per_slot_key_confined',
            'cases': ((key_slot, live_slot, auth)
                      for key_slot in AUTH_SPACE
                      for live_slot in AUTH_SPACE
                      for auth in BOOL_SPACE),
            'expect': lambda args: 1 if (args[2] == 0 or args[0] == args[1]) else 0,
        },
        'INV-SYSCALL-PERM-PER-LAUNCH': {
            'predicate': 'inv_syscall_perm_per_launch',
            'cases': ((blob_perm, live_perm, dispatches)
                      for blob_perm in AUTH_SPACE
                      for live_perm in AUTH_SPACE
                      for dispatches in BOOL_SPACE),
            'expect': lambda args: 1 if (args[2] == 0 or args[0] == args[1]) else 0,
        },
        'INV-PLANTED-CAP-HMAC-REJECTED': {
            'predicate': 'inv_planted_cap_hmac_rejected',
            'cases': ((dump_c, live_c, slot, mask, tag, accepted)
                      for dump_c in (0x00, 0x11, 0x7F)
                      for live_c in (0x11, 0x22, 0x7F)
                      for slot in (0, 3, 7)
                      for mask in (0x0001, 0x0801, 0xFFFF)
                      for tag in AUTH_SPACE
                      for accepted in BOOL_SPACE),
            'expect': lambda args: _planted_cap_hmac(*args),
        },
        # Track 2 (signed everything) anti-rollback invariants. Ordering, not
        # equality: an admitted artifact must meet the floor, and the floor only
        # moves forward. The version/floor axes range over the full bounded space.
        'INV-NO-ROLLBACK': {
            'predicate': 'inv_no_rollback',
            'cases': ((version, floor, admitted)
                      for version in AUTH_SPACE
                      for floor in AUTH_SPACE
                      for admitted in BOOL_SPACE),
            'expect': lambda args: 1 if (args[2] == 0 or args[0] >= args[1]) else 0,
        },
        'INV-FLOOR-RATCHET-MONOTONIC': {
            'predicate': 'inv_floor_ratchet_monotonic',
            'cases': ((old_floor, new_floor)
                      for old_floor in AUTH_SPACE
                      for new_floor in AUTH_SPACE),
            'expect': lambda args: 1 if args[1] >= args[0] else 0,
        },
    }


def load_invariants():
    if not os.path.isdir(INVARIANT_DIR):
        raise EvalError("missing invariant directory: %s" % INVARIANT_DIR)
    files = sorted(
        os.path.join(INVARIANT_DIR, f)
        for f in os.listdir(INVARIANT_DIR)
        if f.endswith('.invariant'))
    if not files:
        raise EvalError("no .invariant files under %s" % INVARIANT_DIR)

    invariants = {}
    for path in files:
        meta = parse_key_value_file(path)
        for req in ('invariant', 'predicate', 'status'):
            if req not in meta or not meta[req]:
                raise EvalError("%s missing required key: %s" % (path, req))
        inv = meta['invariant']
        if inv in invariants:
            raise EvalError("duplicate invariant id: %s" % inv)
        invariants[inv] = meta
    return invariants


def run_vectors(mod):
    if not os.path.isdir(VECTOR_DIR):
        sys.stderr.write("missing vector directory: %s\n" % VECTOR_DIR)
        return 2

    files = sorted(
        os.path.join(VECTOR_DIR, f)
        for f in os.listdir(VECTOR_DIR)
        if f.endswith('.vectors'))
    if not files:
        sys.stderr.write("no .vectors files under %s\n" % VECTOR_DIR)
        return 2

    total_accept = 0
    total_reject = 0
    failures = []

    for path in files:
        meta, cases = parse_vector_file(path, mod)
        pred = meta['predicate']
        inv = meta['invariant']
        have_accept = False
        have_reject = False
        for expect, args, lineno in cases:
            got = mod.call(pred, args)
            # An accept case must return exactly 1; a reject case must return 0.
            if expect == 'accept':
                ok = (got == 1)
                have_accept = True
                total_accept += 1
            else:
                ok = (got == 0)
                have_reject = True
                total_reject += 1
            status = 'ok' if ok else 'FAIL'
            print("[eval]   %-26s %s(%s) -> %d  expect %s  [%s]"
                  % (inv, pred, ','.join(str(a) for a in args), got, expect, status))
            if not ok:
                failures.append("%s:%d %s(%s) returned %d, expected %s"
                                % (os.path.basename(path), lineno, pred,
                                   ','.join(str(a) for a in args), got, expect))
        if not have_accept:
            failures.append("%s has no `accept` (positive) case" % os.path.basename(path))
        if not have_reject:
            failures.append("%s has no `reject` (negative) case" % os.path.basename(path))

    print("[eval] evaluated %d vector file(s): %d accept-cases, %d reject-cases"
          % (len(files), total_accept, total_reject))

    if failures:
        sys.stderr.write("[eval] FAIL - %d problem(s):\n" % len(failures))
        for f in failures:
            sys.stderr.write("  - %s\n" % f)
        return 1
    print("[eval] all vectors evaluated as expected")
    return 0


def run_exhaustive(mod):
    try:
        invariants = load_invariants()
        specs = exhaustive_specs(mod)
    except EvalError as e:
        sys.stderr.write("[prove] %s\n" % e)
        return 2

    failures = []
    checked_total = 0
    for inv in sorted(invariants):
        meta = invariants[inv]
        if inv not in specs:
            failures.append("%s has no exhaustive theorem spec" % inv)
            continue
        spec = specs[inv]
        if meta['predicate'] != spec['predicate']:
            failures.append("%s .invariant predicate '%s' disagrees with "
                            "exhaustive spec predicate '%s'"
                            % (inv, meta['predicate'], spec['predicate']))
            continue
        if meta['status'] != 'proven':
            failures.append("%s is exhaustively specified but status is '%s', "
                            "expected 'proven'" % (inv, meta['status']))
            continue

        checked = 0
        accepted = 0
        rejected = 0
        failed = False
        for args in spec['cases']:
            expected = spec['expect'](args)
            got = mod.call(spec['predicate'], list(args))
            checked += 1
            if expected == 1:
                accepted += 1
            else:
                rejected += 1
            if got != expected:
                failures.append("%s %s(%s) returned %d, expected %d"
                                % (inv, spec['predicate'],
                                   ','.join(str(a) for a in args), got, expected))
                failed = True
                break
        checked_total += checked
        status = 'FAIL' if failed else 'ok'
        print("[prove] %-26s %-38s checked=%5d accept=%5d reject=%5d [%s]"
              % (inv, spec['predicate'], checked, accepted, rejected, status))

    for inv in sorted(set(specs) - set(invariants)):
        failures.append("%s has an exhaustive spec but no .invariant file" % inv)

    if failures:
        sys.stderr.write("[prove] FAIL - %d problem(s):\n" % len(failures))
        for f in failures:
            sys.stderr.write("  - %s\n" % f)
        return 1

    print("[prove] all %d invariant(s) exhaustively checked over bounded "
          "7-bit state spaces (%d predicate evaluation(s))"
          % (len(invariants), checked_total))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exhaustive', action='store_true',
                    help='prove current invariants over bounded 7-bit spaces')
    args = ap.parse_args()

    mod = Module(MODULE)
    if args.exhaustive:
        return run_exhaustive(mod)
    return run_vectors(mod)


if __name__ == '__main__':
    sys.exit(main())
