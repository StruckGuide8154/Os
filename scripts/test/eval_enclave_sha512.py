#!/usr/bin/env python3
# Track-10 enclave gateware: verify the REAL SHA-512 block compressor
# (src/enclave/rtl/sha512.py) against FIPS 180-4 / NIST known-answer vectors.
#
# The RTL processes one 1024-bit block given a chaining value; this harness does
# standard SHA-512 padding + multi-block chaining in Python and cycle-simulates
# the core, then compares the final digest to the published test vectors AND to
# Python's hashlib over random messages (differential check). "Done" for a crypto
# primitive means the vectors pass -- nothing weaker.

import hashlib
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))

from amaranth.sim import Simulator                       # noqa: E402
from enclave.rtl.sha512 import SHA512Block, IV           # noqa: E402

FAILURES = []


def check(label, ok, detail=''):
    print('[sha512] %-46s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                     (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def pad(msg: bytes):
    ml = len(msg) * 8
    m = msg + b'\x80'
    while (len(m) % 128) != 112:
        m += b'\x00'
    m += ml.to_bytes(16, 'big')
    return [m[i:i + 128] for i in range(0, len(m), 128)]


def blocks_to_int(block: bytes) -> int:
    return int.from_bytes(block, 'big')      # word0 in the MSBs, matches RTL


def h_words_to_int(words) -> int:
    v = 0
    for wd in words:
        v = (v << 64) | wd
    return v


def sha512_rtl(msg: bytes) -> bytes:
    dut = SHA512Block()
    result = {}

    async def tb(ctx):
        h = h_words_to_int(IV)
        for blk in pad(msg):
            ctx.set(dut.h_in, h)
            ctx.set(dut.block, blocks_to_int(blk))
            ctx.set(dut.start, 1)
            await ctx.tick()
            ctx.set(dut.start, 0)
            # 82-cycle bound; stop as soon as done strobes.
            for _ in range(120):
                if ctx.get(dut.done):
                    break
                await ctx.tick()
            else:
                raise AssertionError('SHA512Block never asserted done')
            h = ctx.get(dut.h_out)
            await ctx.tick()
        result['digest'] = h.to_bytes(64, 'big')

    sim = Simulator(dut)
    sim.add_clock(1e-6)
    sim.add_testbench(tb)
    sim.run()
    return result['digest']


# ---- FIPS 180-4 published known-answer vectors --------------------------
KAT = {
    b'': ('cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce'
          '47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e'),
    b'abc': ('ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
             '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f'),
    (b'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno'
     b'ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu'):
        ('8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018'
         '501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909'),
}

for msg, want in KAT.items():
    got = sha512_rtl(msg).hex()
    check('KAT len=%d' % len(msg), got == want, 'got %s' % got)

# ---- differential vs hashlib over varied/odd lengths --------------------
import random                                            # noqa: E402
random.seed(0xC0FFEE)
for n in [1, 55, 111, 112, 127, 128, 129, 200, 256]:
    msg = bytes(random.randrange(256) for _ in range(n))
    got = sha512_rtl(msg)
    want = hashlib.sha512(msg).digest()
    check('diff hashlib n=%d' % n, got == want, got.hex())

if FAILURES:
    print('\nFAILED %d:' % len(FAILURES))
    for fr in FAILURES:
        print('  - ' + fr)
    sys.exit(1)
print('\nall SHA-512 gateware vectors pass')
