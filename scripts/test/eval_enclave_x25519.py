#!/usr/bin/env python3
# Track-10 enclave gateware A2: verify the X25519 Montgomery-ladder core
# (src/enclave/rtl/x25519.py) against the RFC 7748 section 5.2 test vectors and
# differentially against an independent Python X25519 reference.

import os
import random
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))

from amaranth.sim import Simulator                       # noqa: E402
from enclave.rtl.x25519 import X25519                    # noqa: E402

P = (1 << 255) - 19
A24 = 121665
FAILURES = []


def check(label, ok, detail=''):
    print('[x25519] %-44s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                     (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


# ---- independent Python reference (RFC 7748) ----------------------------
def clamp(k):
    k = list(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return int.from_bytes(bytes(k), 'little')


def x25519_ref(k_bytes, u_bytes):
    k = clamp(k_bytes)
    u = int.from_bytes(u_bytes, 'little') & ((1 << 255) - 1)
    x1 = u
    x2, z2, x3, z3 = 1, 0, u, 1
    swap = 0
    for t in reversed(range(255)):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt
        A = (x2 + z2) % P; AA = (A * A) % P
        B = (x2 - z2) % P; BB = (B * B) % P
        E = (AA - BB) % P
        C = (x3 + z3) % P
        D = (x3 - z3) % P
        DA = (D * A) % P; CB = (C * B) % P
        x3 = ((DA + CB) ** 2) % P
        z3 = (x1 * ((DA - CB) ** 2)) % P
        x2 = (AA * BB) % P
        z2 = (E * (AA + A24 * E)) % P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P


def to_int(b):
    return int.from_bytes(b, 'little')


# ---- DUT driver ---------------------------------------------------------
def x25519_rtl(k_int, u_int):
    dut = X25519()
    out = {}

    async def tb(ctx):
        ctx.set(dut.k, k_int)
        ctx.set(dut.u, u_int)
        ctx.set(dut.start, 1)
        await ctx.tick()
        ctx.set(dut.start, 0)
        for _ in range(200000):     # ladder ~255 + invert ~510 cycles
            if ctx.get(dut.done):
                break
            await ctx.tick()
        else:
            raise AssertionError('X25519 never asserted done')
        out['r'] = ctx.get(dut.result)

    sim = Simulator(dut)
    sim.add_clock(1e-6)
    sim.add_testbench(tb)
    sim.run()
    return out['r']


# ---- RFC 7748 section 5.2 known-answer vectors --------------------------
V1_K = bytes.fromhex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4')
V1_U = bytes.fromhex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c')
V1_OUT = 'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552'

V2_K = bytes.fromhex('4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d')
V2_U = bytes.fromhex('e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493')
V2_OUT = '95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957'

# reference self-check against the published constants first.
check('ref vector 1', x25519_ref(V1_K, V1_U).to_bytes(32, 'little').hex() == V1_OUT)
check('ref vector 2', x25519_ref(V2_K, V2_U).to_bytes(32, 'little').hex() == V2_OUT)

# DUT against the same published vectors.
g1 = x25519_rtl(to_int(V1_K), to_int(V1_U)).to_bytes(32, 'little').hex()
check('RFC 7748 vector 1 (DUT)', g1 == V1_OUT, g1)
g2 = x25519_rtl(to_int(V2_K), to_int(V2_U)).to_bytes(32, 'little').hex()
check('RFC 7748 vector 2 (DUT)', g2 == V2_OUT, g2)

# ---- iterated test (RFC 7748 section 5.2): k=u=9, 1x on DUT, 1000x on ref --
NINE = (9).to_bytes(32, 'little')
ITER1 = '422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079'
ITER1000 = '684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51'

# 1x iterated vector on the DUT.
d1 = x25519_rtl(to_int(NINE), to_int(NINE))
check('iterated 1x (DUT)', d1.to_bytes(32, 'little').hex() == ITER1,
      d1.to_bytes(32, 'little').hex())

# 1000x iterated vector: the reference (already DUT-validated above for one
# step) carries the published constant; iterating it 1000x on the DUT would be
# ~2e5 cycles x1000 and is impractical in pysim, so the loop runs on the ref.
k = bytearray(NINE)
u = bytearray(NINE)
for _ in range(1000):
    r = x25519_ref(k, u).to_bytes(32, 'little')
    k, u = bytearray(r), bytearray(k)
check('iterated 1000x (ref vs published)', bytes(k).hex() == ITER1000, bytes(k).hex())

# ---- differential vs reference over random scalars ----------------------
random.seed(0xABCDEF)
for n in range(12):
    kb = bytes(random.randrange(256) for _ in range(32))
    ub = bytes(random.randrange(256) for _ in range(32))
    got = x25519_rtl(to_int(kb), to_int(ub))
    want = x25519_ref(kb, ub)
    if got != want:
        check('diff #%d' % n, False, '%x != %x' % (got, want))
        break
else:
    check('12 random differential vectors', True)

if FAILURES:
    print('\nFAILED %d:' % len(FAILURES))
    for fr in FAILURES:
        print('  - ' + fr)
    sys.exit(1)
print('\nall X25519 gateware vectors pass')
