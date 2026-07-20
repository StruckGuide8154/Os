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
LIB_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'lib')
COMPILER = os.path.join(COMPILER_DIR, 'gritc.py')
# The real invariant module. A meta-test may point the evaluator at a PLANTED
# copy (with e.g. a new authority bit or a wrong constant) via the
# GHL_INVARIANT_MODULE env var to prove the proof/translation-validation catch
# the drift; production runs always use the real source.
MODULE = os.environ.get(
    'GHL_INVARIANT_MODULE',
    os.path.join(ROOT, 'src', 'tools', 'security', 'invariant_check.ghl'))
INVARIANT_DIR = os.path.join(ROOT, 'tests', 'security', 'invariants')
VECTOR_DIR = os.path.join(ROOT, 'tests', 'security', 'invariants', 'vectors')

# AUTH_SPACE is the bounded authority/domain enumeration space. Its WIDTH is
# discovered dynamically from the AUTH_* bits declared in invariant_check.ghl
# (see discover_auth_width / set_auth_space) so that introducing a new authority
# bit automatically widens every exhaustive proof - the proof can never silently
# fall behind the policy it derives from. The module-level default below is a
# placeholder; main()/the helpers call set_auth_space() after loading the real
# module to bind it to the real bit-width.
AUTH_BITS = 7
AUTH_SPACE = tuple(range(1 << AUTH_BITS))
BOOL_SPACE = (0, 1)


def discover_auth_width(mod):
    """Derive the authority bit-width from the AUTH_* constants of the real
    GHL invariant module. The width is `1 + position of the highest AUTH_* bit`,
    so the enumeration space (0 .. 2**width - 1) always covers every declared
    authority bit AND every combination below it. Adding `const AUTH_NEW = 128;`
    to invariant_check.ghl automatically grows the space to 8 bits."""
    auth_consts = {n: v for n, v in mod.consts.items() if n.startswith('AUTH_')}
    if not auth_consts:
        raise EvalError("no AUTH_* constants found in %s; cannot derive the "
                        "authority bit-width" % MODULE)
    bad = {n: v for n, v in auth_consts.items()
           if v <= 0 or (v & (v - 1)) != 0}
    if bad:
        raise EvalError("AUTH_* constants must each be a single non-zero bit; "
                        "offending: %s" % ', '.join(
                            "%s=%d" % (n, v) for n, v in sorted(bad.items())))
    highest = max(auth_consts.values())
    return highest.bit_length()  # e.g. 64 -> 7, 128 -> 8


def set_auth_space(mod):
    """Bind the global AUTH_SPACE/AUTH_BITS to the real module's bit-width.
    Called before exhaustive_specs() builds its generators (which close over the
    global AUTH_SPACE name), so the spec table inherits the dynamic width."""
    global AUTH_BITS, AUTH_SPACE
    AUTH_BITS = discover_auth_width(mod)
    AUTH_SPACE = tuple(range(1 << AUTH_BITS))
    return AUTH_BITS

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


_U64 = (1 << 64) - 1
_CAPMAC_SM_A = 0x9E3779B97F4A7C15
_CAPMAC_SM_B = 0xC2B2AE3D27D4EB4F
_CAPMAC_C1 = 0xBF58476D1CE4E5B9
_CAPMAC_C2 = 0x94D049BB133111EB
_CAPMAC_G0 = 0xD1B54A32D192ED03
_CAPMAC_G1 = 0xA0761D6478BD642F


def _cap_mask_mac_lane(canary, slot, mask, gamma):
    base = (canary ^ (((slot & 0xFF) * _CAPMAC_SM_A) & _U64) ^
            (((mask & 0xFFFF) * _CAPMAC_SM_B) & _U64) ^ 0x5C) & _U64
    x = (base ^ gamma) & _U64
    x = ((x ^ (x >> 30)) * _CAPMAC_C1) & _U64
    x = ((x ^ (x >> 27)) * _CAPMAC_C2) & _U64
    return (x ^ (x >> 31)) & _U64


def _cap_mask_mac(canary, slot, mask):
    return (_cap_mask_mac_lane(canary, slot, mask, _CAPMAC_G0),
            _cap_mask_mac_lane(canary, slot, mask, _CAPMAC_G1))


def _planted_cap_hmac(dump_canary, live_canary, slot, mask,
                      planted_lane0, planted_lane1, accepted):
    live_lane0, live_lane1 = _cap_mask_mac(live_canary, slot, mask)
    if accepted == 0:
        return 1
    return 1 if (planted_lane0 == live_lane0 and
                 planted_lane1 == live_lane1) else 0


def _cap_mac_candidates(dump_canary, live_canary, slot, mask):
    """Small, high-signal 128-bit bound: genuine replay, legitimate live MAC,
    and independent corruption of either lane. This covers the two-lane AND
    predicate without attempting an intractable 2**128 enumeration."""
    dump0, dump1 = _cap_mask_mac(dump_canary, slot, mask)
    live0, live1 = _cap_mask_mac(live_canary, slot, mask)
    return ((dump0, dump1), (live0, live1),
            (live0 ^ 1, live1), (live0, live1 ^ 1))


def exhaustive_specs(mod):
    """The bounded theorem table for the current Track-3 invariants."""
    auth_memory = mod.consts['AUTH_MEMORY_GRANT']
    auth_mint_identity = mod.consts['AUTH_MINT_IDENTITY']
    auth_dma = mod.consts['AUTH_DMA_MAP']
    auth_persist = mod.consts['AUTH_PERSIST']
    auth_global = mod.consts['AUTH_GLOBAL']

    # Track 11 (structural CFI) modeling spaces. These are NOT AUTH_* bits, so
    # they leave the authority enumeration width untouched; each is a small,
    # high-signal range that still covers every equal/unequal and member/non-
    # member combination for its predicate.
    cfi_typeids = range(mod.consts['CFI_TYPEID_COUNT'])
    cfi_offsets = range(mod.consts['CFI_OFFSET_SPAN'])
    cfi_writers = range(mod.consts['CFI_WRITER_COUNT'])

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
            'cases': ((dump_c, live_c, slot, mask, lane0, lane1, accepted)
                      for dump_c in (0x00, 0x11, 0x7F)
                      for live_c in (0x11, 0x22, 0x7F)
                      for slot in (0, 3, 7)
                      for mask in (0x0001, 0x0801, 0xFFFF)
                      for lane0, lane1 in _cap_mac_candidates(
                          dump_c, live_c, slot, mask)
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
        # Track 11 (structural CFI + memory-safety-by-construction) L4 modeling
        # theorems. Proven over their bounded typeid/offset/writer spaces; they
        # bound what a *sound* emitter may admit before the L1/L2 codegen exists.
        # FORWARD-TARGET-IN-SET: admitted iff the target's typeid equals the call
        # site's AND the target is a table member (both required).
        'INV-CFI-FORWARD-TARGET-IN-SET': {
            'predicate': 'inv_cfi_forward_target_in_set',
            'cases': ((site, target, member)
                      for site in cfi_typeids
                      for target in cfi_typeids
                      for member in BOOL_SPACE),
            'expect': lambda args: 1 if (args[0] == args[1] and args[2] != 0) else 0,
        },
        # NO-MIDFUNCTION-ENTRY: admitted iff the target offset is 0 (the entry);
        # every non-zero offset (a mid-function gadget entry) is rejected.
        'INV-CFI-NO-MIDFUNCTION-ENTRY': {
            'predicate': 'inv_cfi_no_offset_entry',
            'cases': ((offset,) for offset in cfi_offsets),
            'expect': lambda args: 1 if args[0] == 0 else 0,
        },
        # SAFESTACK-RETURN-NO-FOREIGN-WRITE: a write to a return slot is admitted
        # iff the writer is the canonical push/ret path. The expect fn is CONSTANT
        # in a non-canonical writer for a return slot (only the canonical id is
        # admitted); non-return-slot writes are vacuously admitted.
        'INV-SAFESTACK-RETURN-NO-FOREIGN-WRITE': {
            'predicate': 'inv_safestack_return_unwritable',
            'cases': ((writer, canonical, is_return)
                      for writer in cfi_writers
                      for canonical in cfi_writers
                      for is_return in BOOL_SPACE),
            'expect': lambda args: 1 if (args[2] == 0 or args[0] == args[1]) else 0,
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
        set_auth_space(mod)
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
          "%d-bit authority state spaces (%d predicate evaluation(s)); "
          "bit-width derived from the AUTH_* constants of invariant_check.ghl"
          % (len(invariants), AUTH_BITS, checked_total))
    return 0


def _emit_invariant_asm(out_path):
    """Compile invariant_check.ghl with the PRODUCTION compiler to assembly -
    the same `gritc.py ... --forbid-asm --deny-unsafe` invocation the Track-3
    runner already uses for the trusted enforcement path. Returns the emitted
    asm text. Raises EvalError on any compile failure."""
    import subprocess
    cmd = [sys.executable, COMPILER, MODULE, '-o', out_path,
           '-L', LIB_DIR, '--embed', '--target', 'kernel',
           '--forbid-asm', '--deny-unsafe']
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True)
    if proc.returncode != 0:
        raise EvalError("invariant_check.ghl failed to compile for translation "
                        "validation:\n%s" % proc.stdout)
    with open(out_path, 'r', encoding='utf-8') as fh:
        return fh.read()


# Immediate operands (decimal) emitted in an x86-64 instruction, e.g.
# `mov rcx, 4`, `and rax, 8`, `cmp rsi, 64`. The bit constants the model proves
# about are carried into the binary as these immediates.
_IMM_RE = __import__('re').compile(r'\b(?:mov|and|or|xor|cmp|test|add|sub)\b'
                                   r'[^;]*?,\s*(\d+)\b')


def _emitted_fns(asm_text):
    """Split emitted asm into {fn_name: set(immediate ints)}. gritc emits a
    uniform `; ===== fn <name>  <...> =====` banner before EVERY function body
    (global FN_BEGIN/FN_END functions and plain-label private helpers alike), so
    a function body runs from its banner to the next banner (or EOF)."""
    import re
    fns = {}
    cur = None
    banner_re = re.compile(r'^;\s*=+\s*fn\s+([A-Za-z_][A-Za-z0-9_]*)\b')
    for line in asm_text.splitlines():
        mb = banner_re.match(line)
        if mb:
            cur = mb.group(1)
            fns.setdefault(cur, set())
            continue
        if cur is not None:
            code = line.split(';', 1)[0]
            for m in _IMM_RE.finditer(code):
                fns[cur].add(int(m.group(1)))
    return fns


# The proven authority semantics, stated as FIXED literals INDEPENDENT of the
# module source. These are the bit values the proofs, the containment claim
# table (docs/track3-invariant-proofs.md §1/§3) and the enforcement call sites
# all assume: the scheduler-denied bit is AUTH_MEMORY_GRANT=1, the IPC-denied
# bit is AUTH_MINT_IDENTITY=2, etc. Hard-coding them here (rather than re-reading
# mod.consts) is deliberate: it makes this an INDEPENDENT oracle, so a source
# const that silently changes value (which would otherwise still "prove" a
# different, weaker property) is caught as a mismatch against the emitted code.
TV_EXPECTED = {
    'inv_scheduler_no_memory_grant':        [1],    # AUTH_MEMORY_GRANT
    'inv_ipc_no_identity_forge':            [2],    # AUTH_MINT_IDENTITY
    'inv_driver_no_dma_mint':               [4],    # AUTH_DMA_MAP
    'inv_pt_no_persist_without_threshold':  [8],    # AUTH_PERSIST
    # Exact 128-bit cap-mask MAC constants mirrored from syscall_secure.ghl.
    'cap_mask_mac_lane': [
        92, 255, 65535,
        11400714819323198485,  # CAPMAC_SM_A
        14029467366897019727,  # CAPMAC_SM_B
        13787848793156543929,  # CAPMAC_C1
        10723151780598845931,  # CAPMAC_C2
    ],
    'inv_planted_cap_hmac_rejected': [
        15111065706836454659,  # CAPMAC_G0
        11562461410679940143,  # CAPMAC_G1
    ],
}


def translation_validation_bindings(mod):
    """Each entry binds a proven predicate to the authority constant(s) it MUST
    exercise, as FIXED literals (the documented model semantics), and ALSO
    cross-checks that the module's own const of that name still equals the fixed
    literal. The translation-validation step then asserts that exact value is an
    emitted immediate in the compiled function body. Two independent oracles
    (the fixed literal here and the gritc-emitted immediate) must agree, so a
    consistently-changed source const is still caught. This is NOT a full
    refinement proof of control flow; it is a mechanical authority-constant
    binding between the proven model and the emitted artifact."""
    c = mod.consts
    name_for_value = {
        1: 'AUTH_MEMORY_GRANT', 2: 'AUTH_MINT_IDENTITY',
        4: 'AUTH_DMA_MAP', 8: 'AUTH_PERSIST',
        92: 'KDOM_CAP_MASK', 255: 'CAPMAC_SLOT_MASK',
        65535: 'CAPMAC_MASK_MASK',
        11400714819323198485: 'CAPMAC_SM_A',
        14029467366897019727: 'CAPMAC_SM_B',
        13787848793156543929: 'CAPMAC_C1',
        10723151780598845931: 'CAPMAC_C2',
        15111065706836454659: 'CAPMAC_G0',
        11562461410679940143: 'CAPMAC_G1',
    }
    out = []
    for fn, vals in TV_EXPECTED.items():
        const_names = [name_for_value[v] for v in vals]
        out.append((fn, vals, const_names))
    # The const-vs-literal cross-check itself is performed in
    # run_translation_validation (it needs to record each result as a check).
    return out, c


def run_translation_validation(mod):
    """Translation-validation pass (model <-> emitted code).

    Closes the model<->code gap for the authority constants: the exhaustive
    proofs interpret the GHL predicate source, while the trusted path COMPILES
    that same source. Here we compile it with the production gritc and confirm
    the proven authority-bit constants are exactly the immediates emitted into
    the artifact, so the proof binds to the compiled bits and not just the
    parse. Honesty: this validates the authority CONSTANTS only - it is a
    bounded mechanical translation check, not a seL4-style refinement proof of
    the whole control flow."""
    import tempfile
    set_auth_space(mod)
    bindings, consts = translation_validation_bindings(mod)
    out_dir = tempfile.mkdtemp(prefix='ghl-tv-')
    out_path = os.path.join(out_dir, 'invariant_check.asm')
    try:
        asm = _emit_invariant_asm(out_path)
    except EvalError as e:
        sys.stderr.write("[tv] %s\n" % e)
        return 2
    finally:
        try:
            if os.path.isfile(out_path):
                os.remove(out_path)
            os.rmdir(out_dir)
        except OSError:
            pass

    fns = _emitted_fns(asm)
    failures = []
    checked = 0
    for fn, required, const_names in bindings:
        if fn not in fns:
            failures.append("predicate fn '%s' was not emitted by gritc "
                            "(missing function body in the artifact)" % fn)
            continue
        emitted = fns[fn]
        for val, nm in zip(required, const_names):
            checked += 1
            # Oracle 1: the module's own named const must still equal the fixed
            # documented literal (catches a consistently-renamed/revalued const).
            src_val = consts.get(nm)
            src_ok = (src_val == val)
            # Oracle 2: that fixed literal must be an immediate emitted by gritc
            # into this function body (binds the proof to the compiled bits).
            emit_ok = val in emitted
            ok = src_ok and emit_ok
            print("[tv]   %-38s %-18s expect %-4d src=%-4s emitted [%s]"
                  % (fn, nm, val,
                     str(src_val), 'ok' if ok else 'MISMATCH'))
            if not src_ok:
                failures.append("%s: source const %s=%s != documented proven "
                                "value %d (model drift)" % (fn, nm, src_val, val))
            if not emit_ok:
                failures.append("%s: proven authority value %d (%s) is NOT an "
                                "emitted immediate (emitted=%s) - model/code drift"
                                % (fn, val, nm, sorted(emitted)))

    if failures:
        sys.stderr.write("[tv] FAIL - %d problem(s):\n" % len(failures))
        for f in failures:
            sys.stderr.write("  - %s\n" % f)
        return 1
    print("[tv] translation-validation passed: %d security-model constant(s) across "
          "%d predicate(s) match between the proven model and the gritc-emitted "
          "artifact (bounded constant-binding check, not a full refinement proof)"
          % (checked, len(bindings)))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exhaustive', action='store_true',
                    help='prove current invariants over the bounded authority '
                         'space (bit-width derived from invariant_check.ghl)')
    ap.add_argument('--translation-validation', action='store_true',
                    help='compile invariant_check.ghl with gritc and check the '
                         'proven authority constants match the emitted immediates')
    args = ap.parse_args()

    mod = Module(MODULE)
    if args.translation_validation:
        return run_translation_validation(mod)
    if args.exhaustive:
        return run_exhaustive(mod)
    return run_vectors(mod)


if __name__ == '__main__':
    sys.exit(main())
