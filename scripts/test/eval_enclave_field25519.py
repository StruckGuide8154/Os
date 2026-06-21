#!/usr/bin/env python3
# Track-10 enclave gateware A1: verify the GF(2^255-19) field core
# (src/enclave/rtl/field25519.py) against a Python pow/% reference.
#
# "Done" means every field op matches the reference over >=1000 random vectors
# plus fixed known-answer cases (including the awkward boundaries: 0, 1, p-1,
# and operands chosen to exercise the carry-fold reduction).

import os
import random
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))

from amaranth.sim import Simulator                       # noqa: E402
from enclave.rtl.field25519 import (Field25519, P,       # noqa: E402
                                    OP_ADD, OP_SUB, OP_MUL, OP_SQR, OP_INV)

FAILURES = []


def check(label, ok, detail=''):
    print('[field25519] %-40s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                         (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def run_op(op, a, b):
    dut = Field25519()
    out = {}

    async def tb(ctx):
        ctx.set(dut.a, a)
        ctx.set(dut.b, b)
        ctx.set(dut.op, op)
        ctx.set(dut.start, 1)
        await ctx.tick()
        ctx.set(dut.start, 0)
        for _ in range(2000):       # invert needs ~510 cycles; bound generously
            if ctx.get(dut.done):
                break
            await ctx.tick()
        else:
            raise AssertionError('Field25519 never asserted done')
        out['r'] = ctx.get(dut.result)

    sim = Simulator(dut)
    sim.add_clock(1e-6)
    sim.add_testbench(tb)
    sim.run()
    return out['r']


def ref(op, a, b):
    if op == OP_ADD:
        return (a + b) % P
    if op == OP_SUB:
        return (a - b) % P
    if op == OP_MUL:
        return (a * b) % P
    if op == OP_SQR:
        return (a * a) % P
    if op == OP_INV:
        return pow(a, P - 2, P)
    raise ValueError(op)


# ---- fixed known-answer / boundary cases --------------------------------
KAT = [
    (OP_ADD, P - 1, 1),         # wraps to 0
    (OP_ADD, P - 1, P - 1),     # exercises double fold
    (OP_SUB, 0, 1),             # wraps to p-1
    (OP_SUB, 5, 9),
    (OP_MUL, P - 1, P - 1),     # (p-1)^2
    (OP_MUL, 0, 12345),
    (OP_SQR, P - 1, 0),
    (OP_SQR, 2, 0),
    (OP_INV, 1, 0),
    (OP_INV, 2, 0),
    (OP_INV, P - 1, 0),
]
NAMES = {OP_ADD: 'add', OP_SUB: 'sub', OP_MUL: 'mul', OP_SQR: 'sqr', OP_INV: 'inv'}
for op, a, b in KAT:
    got = run_op(op, a, b)
    want = ref(op, a, b)
    check('KAT %s(%d,%d)' % (NAMES[op], a % 97, b % 97), got == want,
          'got %d want %d' % (got, want))
    if op == OP_INV:        # cross-check a * a^-1 == 1
        check('inv-roundtrip a=%d' % (a % 97), (a * got) % P == 1)

# ---- differential vs Python over random vectors -------------------------
random.seed(0x25519)
# >=1000 add/sub/mul/sqr vectors; invert is ~510 cycles each so sample fewer.
for n in range(1000):
    a = random.randrange(P)
    b = random.randrange(P)
    op = random.choice([OP_ADD, OP_SUB, OP_MUL, OP_SQR])
    got = run_op(op, a, b)
    want = ref(op, a, b)
    if got != want:
        check('diff %s #%d' % (NAMES[op], n), False, 'got %d want %d' % (got, want))
        break
else:
    check('1000 random add/sub/mul/sqr vectors', True)

for n in range(40):
    a = random.randrange(1, P)
    got = run_op(OP_INV, a, 0)
    want = ref(OP_INV, a, 0)
    if got != want or (a * got) % P != 1:
        check('diff inv #%d' % n, False, 'a=%d got %d' % (a, got))
        break
else:
    check('40 random invert vectors', True)

if FAILURES:
    print('\nFAILED %d:' % len(FAILURES))
    for fr in FAILURES:
        print('  - ' + fr)
    sys.exit(1)
print('\nall field25519 gateware vectors pass')
