#!/usr/bin/env python3
# Track-8 / Track-3: INV-DRIVER-NO-DMA-MINT re-proven against the REAL broker.
#
# The original Track-3 proof ran over the abstract 2-variable predicate
# `inv_driver_no_dma_mint(driver_auth, dma_grant_present)`. This harness
# re-proves the theorem against the shipping enforcement code: it parses
# `src/kernel/grithlk/driver_host.ghl` with the production compiler's own
# lexer/parser (gritc.lex / gritc.parse) and interprets the actual broker
# functions (drvhost_grant_dma, drvhost_dma_contained, drvhost_dma_alloc,
# drvhost_dma_map, drvhost_mmio_write_dma_ptr, ...) over a modeled data
# segment with 64-bit wrap-around arithmetic, GHL's SIGNED comparisons and
# logical shifts - the same integer semantics the emitted x86-64 has.
#
# Theorem (broker form): a DMA-reachable address can be programmed into a
# device ONLY if it lies fully inside a {base,end} window recorded for the
# CALLING driver_id in the grant table, and a window can be recorded for a
# driver ONLY through the broker's own fail-closed grant discipline
# (capability-gated, policy-ceiling-bounded). A compromised driver can
# neither self-mint a window nor reach a sibling's.
#
# Proof sections:
#   P1  drvhost_dma_contained is SOUND (==1 implies true unsigned containment
#       in a window owned by the queried id) over an exhaustive bounded space
#       including adversarially planted malformed rows, and COMPLETE for
#       well-formed rows.
#   P2  drvhost_grant_dma mints a row only for a RUNNING driver holding
#       DRV_CAP_DMA, never on zero-length windows, and never mutates the
#       table on a refused request (no partial mint).
#   P3  drvhost_dma_alloc keeps every driver's granted-DMA total inside its
#       signed policy ceiling across alloc sequences (including overflow and
#       size-mask edges); a refused alloc leaves accounting and table untouched.
#   P4  drvhost_mmio_write_dma_ptr performs the raw pointer write ONLY when
#       the register lies in the caller's MMIO grant AND the pointer VALUE
#       lies in the caller's OWN DMA grant - a sibling's window never
#       satisfies it (the cross-driver no-mint case).
#   P5  drvhost_grant_mmio_for requires the PnP-controller capability on the
#       granter; an ordinary driver cannot route windows to a sibling.
#   P6  drvhost_dma_map maps only a window base the caller was granted, is
#       idempotent on the same base, and refuses a second live mapping.
#
# `--selftest` proves the harness cannot rot into a no-op: it re-runs the
# proof over PLANTED broken copies of the broker (ownership check dropped,
# capability gate dropped, pointer-value containment dropped) and requires
# each mutation to be caught.
#
# The interpreter supports exactly the integer subset driver_host.ghl uses
# (let / assign / if / else / while / return, calls, the lb/lh/lw/lq loads,
# sb/sh/sw/sq stores, atomic_xchg, &symbol address-of). Anything else is a
# hard error, so it can never silently "pass" logic it did not evaluate.

import argparse
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
COMPILER_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler')
MODULE = os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'driver_host.ghl')
MAX_LOOP_ITERS = 1 << 16
DATA_BASE = 0x100000        # arbitrary non-zero base for the modeled segment

sys.path.insert(0, COMPILER_DIR)
import gritc  # noqa: E402  (the production GHL compiler - source of truth)

U64 = (1 << 64) - 1


def s64(v):
    """Interpret a 64-bit pattern as GHL's signed comparison operand."""
    v &= U64
    return v - (1 << 64) if v >= (1 << 63) else v


class EvalError(Exception):
    pass


class Violation(Exception):
    """A proof property failed against the (possibly mutated) broker source."""


class Program:
    """driver_host.ghl parsed ONCE: consts, fns, and the data-segment layout.
    Cheap fresh-memory Units are spawned from this for every proof state."""

    def __init__(self, src, path=MODULE):
        self.consts = {}
        self.fns = {}
        self.data = {}            # name -> (base, size)
        addr = DATA_BASE
        for d in gritc.parse(gritc.lex(src, path), path):
            k = d.get('k')
            if k == 'const':
                if d.get('symbolic'):
                    continue
                self.consts[d['name']] = d['val']
            elif k == 'fn':
                if d.get('regparams') or d.get('naked'):
                    raise EvalError("fn '%s' is register-param/naked" % d['name'])
                self.fns[d['name']] = d
            elif k == 'data':
                if d.get('strval') is not None:
                    raise EvalError("string data '%s' unsupported" % d['name'])
                count = 1
                for kind, val in d['factors']:
                    count *= val if kind == 'num' else self.consts[val]
                size = count * d['width']
                addr = (addr + 7) & ~7
                self.data[d['name']] = (addr, size)
                addr += size
            elif k in ('module', 'unsafe', 'extern', 'global', 'align'):
                continue
            else:
                raise EvalError("unsupported top-level decl: %s" % k)
        self.mem_size = addr - DATA_BASE


class Unit:
    """One fresh broker state: writable modeled data segment + observation log.
    Extern kernel primitives and the raw hardware-boundary helpers are
    intercepted so every device-visible access is OBSERVED, never performed.
    The stubs are deliberately adversarially permissive - the proof must not
    lean on THEIR checks, only on the broker's own."""

    def __init__(self, prog):
        self.p = prog
        self.mem = bytearray(prog.mem_size)
        self.raw_log = []         # observed raw MMIO boundary operations
        self.next_phys = 0x400000

        def page_alloc_contig(pages):
            phys = self.next_phys
            self.next_phys += max(int(pages), 1) * 0x1000
            return phys

        self.stubs = {
            'page_alloc_contig': page_alloc_contig,
            'l3_map_driver_dma':
                lambda slot, phys, ln: 0xDEAD0000 + int(slot) * 0x10000,
            'l3_unmap_driver_dma': lambda slot: 0,
        }

    # --- modeled data segment (per-symbol bounds; OOB is a hard error) ------

    def _locate(self, addr, size):
        for name, (base, sz) in self.p.data.items():
            if base <= addr < base + sz:
                if addr + size > base + sz:
                    raise EvalError(
                        "access at 0x%x size %d crosses out of data symbol %s "
                        "(an out-of-bounds table index in the broker)"
                        % (addr, size, name))
                return addr - DATA_BASE
        raise EvalError("access at 0x%x size %d outside every data symbol - "
                        "the broker dereferenced an unmodeled address"
                        % (addr, size))

    def _load(self, addr, size, signed):
        off = self._locate(addr, size)
        v = int.from_bytes(self.mem[off:off + size], 'little')
        if signed and v >= (1 << (8 * size - 1)):
            v -= 1 << (8 * size)
        return v & U64

    def _store(self, addr, size, val):
        off = self._locate(addr, size)
        self.mem[off:off + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(
            size, 'little')

    # Test-bench pokes/peeks, addressed symbolically.
    def poke(self, name, index, width, val):
        self._store(self.p.data[name][0] + index * width, width, val)

    def peek(self, name, index, width):
        return self._load(self.p.data[name][0] + index * width, width, False)

    def snapshot(self, *names):
        out = []
        for name in names:
            base, sz = self.p.data[name]
            off = base - DATA_BASE
            out.append(bytes(self.mem[off:off + sz]))
        return out

    # --- interpreter --------------------------------------------------------

    def call(self, name, args):
        if name == 'lb':
            return self._load(args[0], 1, False)
        if name == 'lh':
            return self._load(args[0], 2, False)
        if name == 'lw':
            return self._load(args[0], 4, True)    # movsxd: sign-extended
        if name == 'lq':
            return self._load(args[0], 8, False)
        if name == 'sb':
            self._store(args[0], 1, args[1]); return 0
        if name == 'sh':
            self._store(args[0], 2, args[1]); return 0
        if name == 'sw':
            self._store(args[0], 4, args[1]); return 0
        if name == 'sq':
            self._store(args[0], 8, args[1]); return 0
        if name == 'atomic_xchg':
            old = self._load(args[0], 4, False)
            self._store(args[0], 4, args[1])
            return old
        if name.startswith('drvhost_raw_mmio_'):
            # The named hardware boundary: OBSERVE, never perform. A logged
            # entry is the proof-relevant event "the device saw this access".
            self.raw_log.append((name, tuple(a & U64 for a in args)))
            return 0
        if name in self.stubs:
            return self.stubs[name](*args) & U64
        if name not in self.p.fns:
            raise EvalError("no such fn and no stub: %s" % name)
        fn = self.p.fns[name]
        params = fn['params']
        if len(args) != len(params):
            raise EvalError("%s expects %d args, got %d"
                            % (name, len(params), len(args)))
        env = dict(zip(params, [a & U64 for a in args]))
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
                    raise EvalError("while exceeded %d iterations" % MAX_LOOP_ITERS)
                r = self._exec_block(st['body'], env)
                if r is not None:
                    return r
            return None
        if k == 'exprstmt':
            self._eval(st['expr'], env)
            return None
        raise EvalError("unsupported statement: %s" % k)

    def _eval(self, e, env):
        k = e['k']
        if k == 'int':
            return e['val'] & U64
        if k == 'ident':
            nm = e['name']
            if nm in env:
                return env[nm]
            if nm in self.p.consts:
                return self.p.consts[nm] & U64
            raise EvalError("unknown identifier: %s" % nm)
        if k == 'addr':
            nm = e['name']
            if nm not in self.p.data:
                raise EvalError("&%s: not a data symbol" % nm)
            return self.p.data[nm][0]
        if k == 'neg':
            return (-self._eval(e['expr'], env)) & U64
        if k == 'not':
            return 0 if self._eval(e['expr'], env) != 0 else 1
        if k == 'call':
            return self.call(e['name'], [self._eval(a, env) for a in e['args']])
        if k == 'bin':
            return self._binop(e['op'], self._eval(e['lhs'], env),
                               self._eval(e['rhs'], env))
        raise EvalError("unsupported expression: %s" % k)

    def _binop(self, op, a, b):
        # 64-bit wrap-around arithmetic, SIGNED comparisons, logical shifts -
        # the exact semantics gritc emits for x86-64 (the GHL numeric
        # gotchas: signed `<`, logical `>>`, mask-after-wrap).
        if op == '&':
            return a & b
        if op == '|':
            return a | b
        if op == '^':
            return a ^ b
        if op == '+':
            return (a + b) & U64
        if op == '-':
            return (a - b) & U64
        if op == '*':
            return (a * b) & U64
        if op == '<<':
            return (a << (b & 63)) & U64
        if op == '>>':
            return (a & U64) >> (b & 63)
        if op == '==':
            return 1 if a == b else 0
        if op == '!=':
            return 1 if a != b else 0
        if op == '<':
            return 1 if s64(a) < s64(b) else 0
        if op == '>':
            return 1 if s64(a) > s64(b) else 0
        if op == '<=':
            return 1 if s64(a) <= s64(b) else 0
        if op == '>=':
            return 1 if s64(a) >= s64(b) else 0
        if op == '&&':
            return 1 if (a != 0 and b != 0) else 0
        if op == '||':
            return 1 if (a != 0 or b != 0) else 0
        raise EvalError("unsupported operator: %s" % op)


# ===========================================================================
# Proof bench
# ===========================================================================

CODE_HASH = 0x1122334455667788


def C(prog, name):
    return prog.consts[name]


def install_driver(u, slot, caps, dma_cap):
    """Admit a driver through the REAL control-plane path (policy install +
    slot-derived registration), exactly as the loader will."""
    rc = u.call('drvhost_policy_install', [slot, caps, CODE_HASH, dma_cap])
    if rc != C(u.p, 'DRV_OK'):
        raise Violation("policy_install(slot=%d) refused rc=%d" % (slot, rc))
    drv = u.call('drvhost_register_slot', [slot, caps])
    if drv != slot + 1:
        raise Violation("register_slot(slot=%d) -> %d" % (slot, drv))
    return drv


def plant_dma_rows(u, rows):
    """Adversarially write raw rows into the DMA grant table (a state only a
    broker bug could produce - the proof must still deny cross-driver reach)."""
    for i, (owner, base, end) in enumerate(rows):
        u.poke('dg_drv', i, 4, owner)
        u.poke('dg_base', i, 8, base)
        u.poke('dg_end', i, 8, end)
    u.poke('dg_count', 0, 4, len(rows))


def ref_contained(rows, drv, addr, ln):
    """Independent unsigned reference: true containment in a drv-owned row."""
    if ln == 0 or addr + ln > (1 << 64):
        return 0
    for owner, base, end in rows:
        if owner == drv and base <= addr and addr + ln <= end:
            return 1
    return 0


def p1_contained_soundness(prog):
    """P1: exhaustive soundness (+ completeness on well-formed rows) of
    drvhost_dma_contained over planted two-row tables."""
    checks = 0
    bases = (0x0, 0x1000, 0x2000)
    ends = (0x1000, 0x2000, 0x3000, 0x800)   # includes end < base malformation
    lens = (0, 1, 4, 0x1000, 0x1001, (1 << 63), U64)
    addrs = (0, 0xFFF, 0x1000, 0x1FFC, 0x2000, 0x2FFF, 0x3000, (1 << 63))
    for o1 in (1, 2):
        for b1 in bases:
            for e1 in ends:
                for o2 in (1, 2):
                    for b2 in bases:
                        for e2 in ends:
                            rows = ((o1, b1, e1), (o2, b2, e2))
                            u = Unit(prog)
                            plant_dma_rows(u, rows)
                            wellformed = all(e >= b for _, b, e in rows)
                            for drv in (1, 2, 3):
                                for addr in addrs:
                                    for ln in lens:
                                        got = u.call('drvhost_dma_contained',
                                                     [drv, addr, ln])
                                        ref = ref_contained(rows, drv, addr, ln)
                                        checks += 1
                                        if got == 1 and ref != 1:
                                            raise Violation(
                                                "P1 UNSOUND: contained(drv=%d, addr=0x%x, "
                                                "len=0x%x)==1 outside every drv-owned row %r"
                                                % (drv, addr, ln, rows))
                                        if (wellformed and ln < (1 << 63)
                                                and addr < (1 << 63) and got != ref):
                                            raise Violation(
                                                "P1 INCOMPLETE: contained(drv=%d, addr=0x%x, "
                                                "len=0x%x)==%d, reference %d, rows %r"
                                                % (drv, addr, ln, got, ref, rows))
    return checks


def p2_grant_gate(prog):
    """P2: drvhost_grant_dma mints only for RUNNING+DRV_CAP_DMA, refuses
    zero-length windows, and never mutates state on refusal."""
    checks = 0
    states = [C(prog, n) for n in ('DRV_ST_NONE', 'DRV_ST_REGISTERED',
                                   'DRV_ST_RUNNING', 'DRV_ST_QUARANTINE',
                                   'DRV_ST_DEAD')]
    cap_dma = C(prog, 'DRV_CAP_DMA')
    cap_mmio = C(prog, 'DRV_CAP_MMIO')
    drv_max = C(prog, 'DRV_MAX')
    for drv in (0, 1, drv_max - 1, drv_max, drv_max + 1):
        for st in states:
            for caps in (0, cap_mmio, cap_dma, cap_dma | cap_mmio):
                for base, ln in ((0x5000, 0), (0x5000, 0x1000),
                                 (U64 - 0xFFF, 0x2000), (0, U64)):
                    u = Unit(prog)
                    if 1 <= drv < drv_max:
                        u.poke('drv_state', drv, 4, st)
                        u.poke('drv_caps_eff', drv, 4, caps)
                    before = u.snapshot('dg_drv', 'dg_base', 'dg_end', 'dg_count')
                    rc = u.call('drvhost_grant_dma', [drv, base, ln])
                    after = u.snapshot('dg_drv', 'dg_base', 'dg_end', 'dg_count')
                    checks += 1
                    # The broker's wrap refusal is the signed comparison
                    # s64(base+len) < s64(base); mirror it exactly.
                    end = (base + ln) & U64
                    allowed = (1 <= drv < drv_max
                               and st == C(prog, 'DRV_ST_RUNNING')
                               and (caps & cap_dma) != 0
                               and ln != 0
                               and s64(end) >= s64(base))
                    if rc == C(prog, 'DRV_OK'):
                        if not allowed:
                            raise Violation(
                                "P2: grant_dma minted for drv=%d state=%d caps=0x%x "
                                "base=0x%x len=0x%x" % (drv, st, caps, base, ln))
                        if u.peek('dg_drv', 0, 4) != drv:
                            raise Violation("P2: minted row owner != requesting id")
                    else:
                        if allowed:
                            raise Violation(
                                "P2: legitimate grant refused rc=%d (drv=%d "
                                "base=0x%x len=0x%x)" % (rc, drv, base, ln))
                        if after != before:
                            raise Violation(
                                "P2: refused grant STILL mutated the table "
                                "(drv=%d state=%d caps=0x%x base=0x%x len=0x%x)"
                                % (drv, st, caps, base, ln))
    return checks


def p3_alloc_ceiling(prog):
    """P3: across alloc sequences the granted total never exceeds the signed
    ceiling; refused allocs leave accounting and the grant table unchanged."""
    checks = 0
    edge_lens = (0, 1, 0xFFF, 0x1000, 0x1001, 0x3000, (1 << 32), (1 << 63), U64)
    for cap in (0, 0x1000, 0x2000, 0x5000):
        for seq in ((0x1000, 0x1000, 0x1000), (0x800, 0x800, 0x800),
                    edge_lens, (0x5000, 0x1000)):
            u = Unit(prog)
            drv = install_driver(u, 0, C(prog, 'DRV_CAP_DMA'), cap)
            for ln in seq:
                before = u.snapshot('dg_drv', 'dg_base', 'dg_end', 'dg_count')
                used_before = u.peek('drv_dma_used', drv, 8)
                phys = u.call('drvhost_dma_alloc', [drv, ln])
                checks += 1
                if phys != 0:
                    need = ((ln + 4095) & U64) & 0xFFFFF000
                    got = u.call('drv_dma_grant_len', [drv, phys])
                    if got != need:
                        raise Violation(
                            "P3: alloc(len=0x%x) granted len 0x%x != rounded 0x%x"
                            % (ln, got, need))
                else:
                    if (u.snapshot('dg_drv', 'dg_base', 'dg_end', 'dg_count')
                            != before or u.peek('drv_dma_used', drv, 8)
                            != used_before):
                        raise Violation(
                            "P3: refused alloc(len=0x%x) mutated grants/accounting"
                            % ln)
                total = 0
                for i in range(u.peek('dg_count', 0, 4)):
                    if u.peek('dg_drv', i, 4) == drv:
                        total += (u.peek('dg_end', i, 8)
                                  - u.peek('dg_base', i, 8))
                if total > cap:
                    raise Violation(
                        "P3 CEILING BREACH: driver %d holds 0x%x granted DMA "
                        "bytes over its signed cap 0x%x (after len=0x%x)"
                        % (drv, total, cap, ln))
    return checks


def p4_pointer_no_mint(prog):
    """P4: the DMA-pointer MMIO write reaches the device ONLY for a register in
    the caller's MMIO grant and a pointer value in the caller's OWN DMA grant."""
    checks = 0
    cap_mmio = C(prog, 'DRV_CAP_MMIO')
    cap_dma = C(prog, 'DRV_CAP_DMA')
    cap_irq = C(prog, 'DRV_CAP_IRQ')
    for caps1 in (cap_mmio | cap_dma, cap_mmio, cap_dma, 0):
        u = Unit(prog)
        d1 = install_driver(u, 11, caps1 if caps1 else cap_irq, 0x2000)
        d2 = install_driver(u, 1, cap_mmio | cap_dma, 0x2000)
        u.poke('drv_caps_eff', d1, 4, caps1)   # exact adversarial mask
        u.call('drvhost_grant_mmio', [d1, 0x1000, 0x100])  # ERR_CAP w/o MMIO
        u.call('drvhost_grant_mmio', [d2, 0x9000, 0x10])
        p1 = u.call('drvhost_dma_alloc', [d1, 0x1000])     # 0 w/o DMA cap
        p2 = u.call('drvhost_dma_alloc', [d2, 0x1000])
        if p2 == 0:
            raise Violation("P4 bench: sibling allocation refused")
        for addr in (0x0FFC, 0x1000, 0x1020, 0x1028, 0x1030,
                     0x1038, 0x10FC, 0x9000):
            for width in (0, 1, 2, 4, 8, 16):
                for dma_addr in (p1, (p1 + 0xFFF) if p1 else 1,
                                 p2, p2 + 0x800, 0x666000, 0):
                    u.raw_log = []
                    rc = u.call('drvhost_mmio_write_dma_ptr',
                                [d1, addr, dma_addr, width])
                    checks += 1
                    wrote = [e for e in u.raw_log
                             if e[0] in ('drvhost_raw_mmio_wr64',
                                         'drvhost_raw_mmio_write32')]
                    register_ok = addr in (0x1020, 0x1028, 0x1030)
                    own_dma = p1 != 0 and p1 <= dma_addr < p1 + 0x1000
                    allowed = ((caps1 & cap_mmio) and (caps1 & cap_dma)
                               and width == 8 and register_ok and own_dma)
                    if (rc == C(prog, 'DRV_OK')) != bool(allowed):
                        raise Violation(
                            "P4: write_dma_ptr caps=0x%x addr=0x%x width=%d "
                            "dma_addr=0x%x rc=%d (own grant [0x%x,+0x1000), "
                            "sibling [0x%x,+0x1000))"
                            % (caps1, addr, width, dma_addr, rc, p1, p2))
                    if rc != C(prog, 'DRV_OK') and wrote:
                        raise Violation("P4: refused request still reached the device")
                    if rc == C(prog, 'DRV_OK'):
                        if not wrote or wrote[0][1][1] != dma_addr:
                            raise Violation("P4: accepted write not observed as issued")
    return checks


def p7_generic_writes_cannot_bypass_pointer_gate(prog):
    """P7: every generic MMIO width refuses an access overlapping any of the
    three protected VirtIO queue-address registers; ordinary registers remain
    writable through the same grant."""
    u = Unit(prog)
    caps = C(prog, 'DRV_CAP_MMIO') | C(prog, 'DRV_CAP_DMA')
    drv = install_driver(u, 11, caps, 0x1000)
    if u.call('drvhost_grant_mmio', [drv, 0x1000, 0x100]) != C(prog, 'DRV_OK'):
        raise Violation('P7 bench: MMIO grant refused')
    if u.peek('drv_virtio_common', drv, 8) != 0x1000:
        raise Violation('P7 bench: common_cfg protection was not latched')
    checks = 0
    writers = ((1, 'drvhost_mmio_wr8'), (2, 'drvhost_mmio_wr16'),
               (4, 'drvhost_mmio_write32'), (8, 'drvhost_mmio_wr64'))
    for width, fn in writers:
        for addr in (0x101F, 0x1020, 0x1021, 0x1028, 0x1030,
                     0x1037, 0x1038, 0x1050):
            u.raw_log = []
            rc = u.call(fn, [drv, addr, 0x666000])
            checks += 1
            end = addr + width
            overlaps = addr < 0x1038 and end > 0x1020
            allowed = not overlaps and end <= 0x1100
            if (rc == C(prog, 'DRV_OK')) != allowed:
                raise Violation('P7: %s addr=0x%x width=%d rc=%d overlaps=%s'
                                % (fn, addr, width, rc, overlaps))
            if rc != C(prog, 'DRV_OK') and u.raw_log:
                raise Violation('P7: refused generic write reached hardware')
    return checks


def p5_cross_grant_gate(prog):
    """P5: only a PnP-controller (DRV_CAP_PCICFG) may grant windows to a
    DIFFERENT driver; ordinary drivers are refused."""
    checks = 0
    cap_irq = C(prog, 'DRV_CAP_IRQ')
    for granter_caps in (0, C(prog, 'DRV_CAP_MMIO'), C(prog, 'DRV_CAP_DMA'),
                         C(prog, 'DRV_CAP_PCICFG')):
        for target_caps in (0, C(prog, 'DRV_CAP_MMIO')):
            u = Unit(prog)
            g = install_driver(u, 0, granter_caps or cap_irq, 0)
            t = install_driver(u, 1, target_caps or cap_irq, 0)
            u.poke('drv_caps_eff', g, 4, granter_caps)
            u.poke('drv_caps_eff', t, 4, target_caps)
            rc = u.call('drvhost_grant_mmio_for', [g, t, 0x7000, 0x100])
            checks += 1
            allowed = ((granter_caps & C(prog, 'DRV_CAP_PCICFG')) != 0
                       and (target_caps & C(prog, 'DRV_CAP_MMIO')) != 0)
            if (rc == C(prog, 'DRV_OK')) != allowed:
                raise Violation(
                    "P5: grant_mmio_for granter_caps=0x%x target_caps=0x%x rc=%d"
                    % (granter_caps, target_caps, rc))
    return checks


def p6_map_own_base_only(prog):
    """P6: dma_map maps only a granted base of the CALLER, idempotently."""
    checks = 0
    u = Unit(prog)
    d1 = install_driver(u, 0, C(prog, 'DRV_CAP_DMA'), 0x4000)
    d2 = install_driver(u, 1, C(prog, 'DRV_CAP_DMA'), 0x4000)
    p1 = u.call('drvhost_dma_alloc', [d1, 0x1000])
    p1b = u.call('drvhost_dma_alloc', [d1, 0x1000])
    p2 = u.call('drvhost_dma_alloc', [d2, 0x1000])
    if 0 in (p1, p1b, p2):
        raise Violation("P6 bench: allocation unexpectedly refused")
    cases = [
        (d1, p1, True),          # own base -> mapped
        (d1, p1, True),          # same base again -> same VA (idempotent)
        (d1, p1b, False),        # second live mapping -> refused
        (d1, p1 + 0x10, False),  # mid-window, not a base -> refused
        (d1, p2, False),         # sibling's base -> refused (no cross reach)
        (d2, p1, False),         # and symmetrically
        (3, p1, False),          # unregistered id -> refused
    ]
    first_va = None
    for drv, phys, expect in cases:
        va = u.call('drvhost_dma_map', [drv, phys])
        checks += 1
        if expect:
            if va == 0:
                raise Violation("P6: own-base map refused (drv=%d phys=0x%x)"
                                % (drv, phys))
            if first_va is None:
                first_va = va
            elif va != first_va:
                raise Violation("P6: idempotent remap returned a different VA")
        elif va != 0:
            raise Violation("P6: map minted a VA for a non-granted base "
                            "(drv=%d phys=0x%x)" % (drv, phys))
    return checks


PROOFS = [
    ('P1 dma_contained soundness/completeness', p1_contained_soundness),
    ('P2 grant gate + no partial mint', p2_grant_gate),
    ('P3 alloc ceiling + refusal purity', p3_alloc_ceiling),
    ('P4 pointer programming no-mint', p4_pointer_no_mint),
    ('P5 cross-grant controller gate', p5_cross_grant_gate),
    ('P6 map own base only', p6_map_own_base_only),
    ('P7 generic pointer bypass closed', p7_generic_writes_cannot_bypass_pointer_gate),
]

# Planted mutations for --selftest: each drops one enforcement clause the
# theorem depends on; the proof run over the mutated source MUST fail.
MUTATIONS = [
    ('ownership check dropped (cross-driver reach)',
     'if lw(&dg_drv + i * 4) == id {',
     'if 1 {'),
    ('capability gate dropped from grant_dma',
     'fn drvhost_grant_dma(id, base, len) {\n'
     '    if drv_has_cap(id, DRV_CAP_DMA) == 0 { return DRV_ERR_CAP; }',
     'fn drvhost_grant_dma(id, base, len) {'),
    ('pointer-value containment dropped from write_dma_ptr',
     '    if drvhost_dma_contained(id, dma_addr, 1) == 0 { return DRV_ERR_GRANT; }',
     '    if 0 == 1 { return DRV_ERR_GRANT; }'),
    ('generic pointer-register guard dropped',
     '    if drv_mmio_overlaps_dma_ptr(id, addr, 4) != 0 { return DRV_ERR_GRANT; }',
     '    if 0 != 0 { return DRV_ERR_GRANT; }'),
]


def run_proofs(src):
    prog = Program(src)
    total = 0
    for name, fn in PROOFS:
        n = fn(prog)
        total += n
        print('[drvhost-dma-mint] %-42s [ok] %d checks' % (name, n))
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true',
                    help='prove the harness catches planted broken brokers')
    args = ap.parse_args()

    with open(MODULE, 'r', encoding='utf-8') as fh:
        real_src = fh.read()

    if args.selftest:
        for label, pat, repl in MUTATIONS:
            if pat not in real_src:
                print('[drvhost-dma-mint] SELFTEST FAIL: mutation anchor for '
                      '"%s" not found - driver_host.ghl drifted; re-anchor the '
                      'mutation' % label, file=sys.stderr)
                return 1
            mutated = real_src.replace(pat, repl)
            try:
                run_proofs(mutated)
            except (Violation, EvalError) as v:
                print('[drvhost-dma-mint] selftest: %-48s caught (%s...)'
                      % (label, str(v)[:60]))
                continue
            print('[drvhost-dma-mint] SELFTEST FAIL: planted "%s" was NOT '
                  'caught - the proof no longer tests that clause' % label,
                  file=sys.stderr)
            return 1
        print('[drvhost-dma-mint] selftest PASS: every planted broken broker '
              'was caught')
        return 0

    try:
        total = run_proofs(real_src)
    except (Violation, EvalError) as v:
        print('[drvhost-dma-mint] FAIL: %s' % v, file=sys.stderr)
        return 1
    print('[drvhost-dma-mint] PASS: INV-DRIVER-NO-DMA-MINT holds against the '
          'real broker (%d checks over drvhost_grant_dma/dma_contained/'
          'dma_alloc/dma_map/mmio_write_dma_ptr/grant_mmio_for)' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
