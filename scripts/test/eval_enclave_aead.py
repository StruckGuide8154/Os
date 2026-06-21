#!/usr/bin/env python3
# Track-10 enclave gateware A4: verify the ChaCha20-Poly1305 AEAD core
# (src/enclave/rtl/aead_chacha.py) against RFC 8439 known-answer vectors:
#   - section 2.4.2 : ChaCha20 keystream block
#   - section 2.8.2 : full AEAD seal (ciphertext + Poly1305 tag)
# plus a seal->open round-trip and a tamper-bit-flip negative (auth must fail).

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))

from amaranth.sim import Simulator                       # noqa: E402
from enclave.rtl.aead_chacha import (ChaCha20Block,      # noqa: E402
                                     AEADChaCha20Poly1305,
                                     OP_SEAL, OP_OPEN)

FAILURES = []


def check(label, ok, detail=''):
    print('[aead] %-46s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                   (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def chacha_block(key, nonce, counter):
    dut = ChaCha20Block()
    out = {}

    async def tb(ctx):
        ctx.set(dut.key, int.from_bytes(key, 'little'))
        ctx.set(dut.nonce, int.from_bytes(nonce, 'little'))
        ctx.set(dut.counter, counter)
        ctx.set(dut.start, 1)
        await ctx.tick()
        ctx.set(dut.start, 0)
        for _ in range(64):
            if ctx.get(dut.done):
                break
            await ctx.tick()
        out['ks'] = ctx.get(dut.ks)

    sim = Simulator(dut)
    sim.add_clock(1e-6)
    sim.add_testbench(tb)
    sim.run()
    return out['ks'].to_bytes(64, 'little')


def aead(op, key, nonce, aad, data, tag_in=b'\x00' * 16):
    dut = AEADChaCha20Poly1305()
    out = {}

    async def tb(ctx):
        ctx.set(dut.op, op)
        ctx.set(dut.key, int.from_bytes(key, 'little'))
        ctx.set(dut.nonce, int.from_bytes(nonce, 'little'))
        ctx.set(dut.aad, int.from_bytes(aad, 'little') if aad else 0)
        ctx.set(dut.aadlen, len(aad))
        ctx.set(dut.data, int.from_bytes(data, 'little') if data else 0)
        ctx.set(dut.datalen, len(data))
        ctx.set(dut.tag_in, int.from_bytes(tag_in, 'little'))
        ctx.set(dut.start, 1)
        await ctx.tick()
        ctx.set(dut.start, 0)
        for _ in range(4000):
            if ctx.get(dut.done):
                break
            await ctx.tick()
        else:
            raise AssertionError('AEAD never asserted done')
        n = len(data)
        ob = ctx.get(dut.out)
        out['out'] = ob.to_bytes((dut.out.width + 7) // 8, 'little')[:n]
        out['tag'] = ctx.get(dut.tag_out).to_bytes(16, 'little')
        out['ok'] = ctx.get(dut.auth_ok)

    sim = Simulator(dut)
    sim.add_clock(1e-6)
    sim.add_testbench(tb)
    sim.run()
    return out


# ---- RFC 8439 section 2.4.2: ChaCha20 keystream block -------------------
KEY = bytes(range(32))
NONCE_242 = bytes.fromhex('000000090000004a00000000')
ks = chacha_block(KEY, NONCE_242, 1)
EXP_242 = ('10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e'
           'd2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e')
check('RFC 8439 2.4.2 ChaCha20 keystream block', ks.hex() == EXP_242, ks.hex())

# ---- RFC 8439 section 2.8.2: AEAD seal ----------------------------------
PT = bytes.fromhex(
    '4c616469657320616e642047656e746c656d656e206f662074686520636c6173'
    '73206f66202739393a204966204920636f756c64206f6666657220796f75206f'
    '6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73'
    '637265656e20776f756c642062652069742e')
AAD = bytes.fromhex('50515253c0c1c2c3c4c5c6c7')
KEY2 = bytes.fromhex(
    '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f')
NONCE2 = bytes.fromhex('070000004041424344454647')
EXP_CT = ('d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6'
          '3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36'
          '92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc'
          '3ff4def08e4b7a9de576d26586cec64b6116')
EXP_TAG = '1ae10b594f09e26a7e902ecbd0600691'

res = aead(OP_SEAL, KEY2, NONCE2, AAD, PT)
check('RFC 8439 2.8.2 AEAD ciphertext', res['out'].hex() == EXP_CT, res['out'].hex())
check('RFC 8439 2.8.2 AEAD Poly1305 tag', res['tag'].hex() == EXP_TAG, res['tag'].hex())

# ---- seal -> open round-trip --------------------------------------------
opened = aead(OP_OPEN, KEY2, NONCE2, AAD, res['out'], res['tag'])
check('open round-trip recovers plaintext', opened['out'] == PT, opened['out'].hex())
check('open round-trip authenticates', opened['ok'] == 1)

# ---- tamper negatives ----------------------------------------------------
bad_ct = bytearray(res['out']); bad_ct[7] ^= 0x80
t1 = aead(OP_OPEN, KEY2, NONCE2, AAD, bytes(bad_ct), res['tag'])
check('tampered ciphertext fails auth', t1['ok'] == 0)

bad_tag = bytearray(res['tag']); bad_tag[0] ^= 1
t2 = aead(OP_OPEN, KEY2, NONCE2, AAD, res['out'], bytes(bad_tag))
check('tampered tag fails auth', t2['ok'] == 0)

bad_aad = bytearray(AAD); bad_aad[0] ^= 1
t3 = aead(OP_OPEN, KEY2, NONCE2, bytes(bad_aad), res['out'], res['tag'])
check('tampered AAD fails auth', t3['ok'] == 0)

# ---- empty plaintext / empty AAD edge case ------------------------------
e = aead(OP_SEAL, KEY2, NONCE2, b'', b'')
e_open = aead(OP_OPEN, KEY2, NONCE2, b'', b'', e['tag'])
check('empty seal/open authenticates', e_open['ok'] == 1)

if FAILURES:
    print('\nFAILED %d:' % len(FAILURES))
    for fr in FAILURES:
        print('  - ' + fr)
    sys.exit(1)
print('\nall ChaCha20-Poly1305 AEAD vectors pass')
