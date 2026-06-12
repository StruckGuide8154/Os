#!/usr/bin/env python3
# Pure-Python RFC 8032 Ed25519 (host side, build/test tooling only).
#
# Used by write_envelope.py to emit REAL threshold signatures over the
# canonical envelope bytes, and by eval_ed25519.py as the independent
# reference implementation the in-kernel GHL verifier is differentially
# tested against.
#
# DEV KEYS: role keypairs are derived from FIXED public seeds so the host
# writer and the in-kernel pubkey table cannot drift during development.
# These provide NO secrecy - production signing replaces dev_role_secret()
# with real HSM-held keys and re-bakes the kernel pubkey table.

import hashlib

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, P - 2, P)) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _sha512(b):
    return hashlib.sha512(b).digest()


def _point_add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    d = 2 * z1 * z2 % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _scalar_mult(s, p):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _point_add(q, p)
        p = _point_add(p, p)
        s >>= 1
    return q


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if x == 0 and sign:
        return None
    if x & 1 != sign:
        x = P - x
    return x


G_Y = 4 * pow(5, P - 2, P) % P
G_X = _recover_x(G_Y, 0)
G = (G_X, G_Y, 1, G_X * G_Y % P)


def _compress(p):
    x, y, z, _ = p
    zinv = pow(z, P - 2, P)
    x, y = x * zinv % P, y * zinv % P
    return int.to_bytes(y | ((x & 1) << 255), 32, 'little')


def _decompress(b):
    n = int.from_bytes(b, 'little')
    y = n & ((1 << 255) - 1)
    x = _recover_x(y, n >> 255)
    if x is None:
        return None
    return (x, y, 1, x * y % P)


def secret_expand(secret32):
    h = _sha512(secret32)
    a = int.from_bytes(h[:32], 'little')
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(secret32):
    a, _ = secret_expand(secret32)
    return _compress(_scalar_mult(a, G))


def sign(secret32, msg):
    a, prefix = secret_expand(secret32)
    pub = _compress(_scalar_mult(a, G))
    r = int.from_bytes(_sha512(prefix + msg), 'little') % L
    rs = _compress(_scalar_mult(r, G))
    h = int.from_bytes(_sha512(rs + pub + msg), 'little') % L
    s = (r + h * a) % L
    return rs + int.to_bytes(s, 32, 'little')


def verify(pub32, msg, sig64):
    if len(pub32) != 32 or len(sig64) != 64:
        return False
    a = _decompress(pub32)
    r = _decompress(sig64[:32])
    if a is None or r is None:
        return False
    s = int.from_bytes(sig64[32:], 'little')
    if s >= L:
        return False
    h = int.from_bytes(_sha512(sig64[:32] + pub32 + msg), 'little') % L
    sb = _scalar_mult(s, G)
    rha = _point_add(r, _scalar_mult(h, a))
    # projective equality: X1*Z2 == X2*Z1 and Y1*Z2 == Y2*Z1
    return (sb[0] * rha[2] - rha[0] * sb[2]) % P == 0 and \
           (sb[1] * rha[2] - rha[1] * sb[2]) % P == 0


# --- DEV role keys (threshold role bit i+1 <-> role index 1..6) -------------
# 1=BOOT 2=KERNEL 3=POLICY 4=UPDATE 5=RECOVERY 6=AUDIT (threshold_check.ghl)

ROLE_NAMES = {1: 'BOOT', 2: 'KERNEL', 3: 'POLICY', 4: 'UPDATE',
              5: 'RECOVERY', 6: 'AUDIT'}


def dev_role_secret(role):
    return _sha512(b'Grit-DEV-ed25519-cosigner-role-%d' % role)[:32]


def dev_role_public(role):
    return public_key(dev_role_secret(role))


if __name__ == '__main__':
    # self-test against RFC 8032 TEST 1 + TEST 2, then print the dev pubkeys
    sk1 = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc4'
                        '4449c5697b326919703bac031cae7f60')
    assert public_key(sk1).hex() == ('d75a980182b10ab7d54bfed3c964073a'
                                     '0ee172f3daa62325af021a68f707511a')
    assert sign(sk1, b'').hex() == (
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
    assert verify(public_key(sk1), b'', sign(sk1, b''))
    sk2 = bytes.fromhex('4ccd089b28ff96da9db6c346ec114e0f'
                        '5b8a319f35aba624da8cf6ed4fb8a6fb')
    assert sign(sk2, b'\x72').hex() == (
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00')
    print('[ed25519-host] RFC 8032 self-test OK')
    for r in range(1, 7):
        print('role %d %-8s pub %s' % (r, ROLE_NAMES[r], dev_role_public(r).hex()))
