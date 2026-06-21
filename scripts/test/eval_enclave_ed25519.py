#!/usr/bin/env python3
# Track-10 enclave gateware A3: verify the Ed25519 sign+verify core
# (src/enclave/rtl/ed25519.py) against RFC 8032 section 7.1 test vectors and
# differentially against the repo's RFC-validated host reference
# (scripts/build/ed25519_host.py, the same code already pinned to the published
# RFC vectors by eval_ed25519.py).
#
# The gateware uses the A0 SHA-512 block and A1 field core; it does the clamp,
# the mod-L reductions, Edwards scalar multiplication, point encode/decode and
# the cofactorless verify equation. "Done" = sign reproduces the published
# signature byte-for-byte AND verify accepts the genuine signature while
# rejecting tampered signature/message/key and non-canonical S.

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'build'))

from amaranth.sim import Simulator                       # noqa: E402
from enclave.rtl.ed25519 import Ed25519, MODE_SIGN, MODE_VERIFY  # noqa: E402
import ed25519_host                                      # noqa: E402

FAILURES = []


def check(label, ok, detail=''):
    print('[ed25519] %-44s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                      (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def sign_rtl(seed32, msg):
    dut = Ed25519()
    out = {}

    async def tb(ctx):
        ctx.set(dut.mode, MODE_SIGN)
        ctx.set(dut.sk, int.from_bytes(seed32, 'big'))
        ctx.set(dut.msg, int.from_bytes(msg, 'big') if msg else 0)
        ctx.set(dut.mlen, len(msg))
        ctx.set(dut.start, 1)
        await ctx.tick()
        ctx.set(dut.start, 0)
        for _ in range(20000):
            if ctx.get(dut.done):
                break
            await ctx.tick()
        else:
            raise AssertionError('Ed25519 sign never asserted done')
        out['r'] = ctx.get(dut.sig_r)
        out['s'] = ctx.get(dut.sig_s)

    sim = Simulator(dut)
    sim.add_clock(1e-6)
    sim.add_testbench(tb)
    sim.run()
    return (out['r'].to_bytes(32, 'little') + out['s'].to_bytes(32, 'little'))


def verify_rtl(pub32, msg, sig64):
    dut = Ed25519()
    out = {}

    async def tb(ctx):
        ctx.set(dut.mode, MODE_VERIFY)
        ctx.set(dut.pub, int.from_bytes(pub32, 'little'))
        ctx.set(dut.in_sigr, int.from_bytes(sig64[:32], 'little'))
        ctx.set(dut.in_sigs, int.from_bytes(sig64[32:], 'little'))
        ctx.set(dut.msg, int.from_bytes(msg, 'big') if msg else 0)
        ctx.set(dut.mlen, len(msg))
        ctx.set(dut.start, 1)
        await ctx.tick()
        ctx.set(dut.start, 0)
        for _ in range(20000):
            if ctx.get(dut.done):
                break
            await ctx.tick()
        else:
            raise AssertionError('Ed25519 verify never asserted done')
        out['v'] = ctx.get(dut.valid)

    sim = Simulator(dut)
    sim.add_clock(1e-6)
    sim.add_testbench(tb)
    sim.run()
    return out['v']


# ---- RFC 8032 section 7.1 vectors (seeds; empty/1-byte/2-byte messages) ---
VEC = [
    ('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', b''),
    ('4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb', b'\x72'),
    ('c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7', b'\xaf\x82'),
]

for i, (skh, msg) in enumerate(VEC):
    seed = bytes.fromhex(skh)
    pub = ed25519_host.public_key(seed)
    ref_sig = ed25519_host.sign(seed, msg)

    got_sig = sign_rtl(seed, msg)
    check('RFC 8032 TEST %d sign' % (i + 1), got_sig == ref_sig,
          got_sig.hex())
    check('RFC 8032 TEST %d verify (genuine)' % (i + 1),
          verify_rtl(pub, msg, ref_sig) == 1)

# ---- verify negatives on TEST 3 -----------------------------------------
seed = bytes.fromhex(VEC[2][0])
pub = ed25519_host.public_key(seed)
msg = VEC[2][1]
sig = ed25519_host.sign(seed, msg)

bad = bytearray(sig); bad[40] ^= 1
check('tampered S rejected', verify_rtl(pub, msg, bytes(bad)) == 0)
bad = bytearray(sig); bad[5] ^= 1
check('tampered R rejected', verify_rtl(pub, msg, bytes(bad)) == 0)
check('tampered message rejected', verify_rtl(pub, msg + b'!', sig) == 0)
badp = bytearray(pub); badp[3] ^= 1
check('wrong public key rejected', verify_rtl(bytes(badp), msg, sig) == 0)
bads = bytearray(sig)
sval = int.from_bytes(sig[32:], 'little') + ed25519_host.L
bads[32:] = sval.to_bytes(32, 'little')
check('non-canonical S (S+L) rejected', verify_rtl(pub, msg, bytes(bads)) == 0)

if FAILURES:
    print('\nFAILED %d:' % len(FAILURES))
    for fr in FAILURES:
        print('  - ' + fr)
    sys.exit(1)
print('\nall Ed25519 gateware vectors pass')
