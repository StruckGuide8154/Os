# ============================================================================
# aead_chacha.py - Track 10 enclave gateware A4: REAL, synthesizable
# ChaCha20-Poly1305 AEAD (RFC 8439), Amaranth HDL. Replaces the placeholder
# permutation datapath behind the session/USB channel with constant-time crypto.
#
# Constant-time by construction: ChaCha20 is a fixed 20-round ARX permutation
# (no data-dependent control); Poly1305 runs a fixed block count per call; the
# tag comparison on open is a data-flow reduction (OR of XOR diffs), never an
# early-out branch. No secret-dependent control reaches a timing output.
#
# Bounded model: plaintext <= MAX_PT bytes, AAD <= MAX_AAD bytes (covers the
# RFC 8439 section 2.8.2 vector: 114-byte plaintext, 12-byte AAD). Buffers are
# little-endian (byte i at bits [8i, 8i+8)), matching the cipher's byte order.
#
# Interface (one AEAD operation per `start` pulse):
#   inputs : start, op (OP_SEAL/OP_OPEN), key[256], nonce[96],
#            aad[MAX_AAD*8], aadlen, data[MAX_PT*8] (pt for seal / ct for open),
#            datalen, tag_in[128] (open only)
#   outputs: busy, done, out[MAX_PT*8] (ct for seal / pt for open),
#            tag_out[128] (seal), auth_ok (open: 1 = tag verified)
# ============================================================================

from amaranth import Module, Signal, Elaboratable, Cat, Const, Mux

MAX_PT = 128             # max plaintext/ciphertext bytes
MAX_AAD = 16             # max associated-data bytes
PT_BITS = MAX_PT * 8
AAD_BITS = MAX_AAD * 8
N_PT_BLK = (MAX_PT + 63) // 64       # ChaCha keystream blocks (64 B each)
P130 = (1 << 130) - 5

OP_SEAL = 0
OP_OPEN = 1

CHACHA_CONST = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]


def rotl32(x, n):
    return Cat(x[32 - n:32], x[0:32 - n])


def _qr(words, a, b, c, d):
    """ChaCha quarter-round on words[a],[b],[c],[d]; returns updated list."""
    w = list(words)
    wa, wb, wc, wd = w[a], w[b], w[c], w[d]
    wa = (wa + wb)[:32]; wd = rotl32(wd ^ wa, 16)
    wc = (wc + wd)[:32]; wb = rotl32(wb ^ wc, 12)
    wa = (wa + wb)[:32]; wd = rotl32(wd ^ wa, 8)
    wc = (wc + wd)[:32]; wb = rotl32(wb ^ wc, 7)
    w[a], w[b], w[c], w[d] = wa, wb, wc, wd
    return w


class ChaCha20Block(Elaboratable):
    """One ChaCha20 keystream block (RFC 8439 section 2.3). 20 rounds in 10
    double-round cycles; outputs the 512-bit block, byte0 in the LSBs."""

    def __init__(self):
        self.start = Signal()
        self.key = Signal(256)
        self.nonce = Signal(96)
        self.counter = Signal(32)
        self.busy = Signal()
        self.done = Signal()
        self.ks = Signal(512)

    def elaborate(self, platform):
        m = Module()
        st = [Signal(32, name=f'st{i}') for i in range(16)]
        init = [Signal(32, name=f'in{i}') for i in range(16)]
        rnd = Signal(range(12))

        # one double-round (column then diagonal) combinationally over st.
        w = list(st)
        for (a, b, c, d) in [(0, 4, 8, 12), (1, 5, 9, 13),
                             (2, 6, 10, 14), (3, 7, 11, 15)]:
            w = _qr(w, a, b, c, d)
        for (a, b, c, d) in [(0, 5, 10, 15), (1, 6, 11, 12),
                             (2, 7, 8, 13), (3, 4, 9, 14)]:
            w = _qr(w, a, b, c, d)

        m.d.sync += self.done.eq(0)
        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    words = (CHACHA_CONST
                             + [self.key[32 * i:32 * i + 32] for i in range(8)]
                             + [self.counter]
                             + [self.nonce[32 * i:32 * i + 32] for i in range(3)])
                    for i in range(16):
                        m.d.sync += [st[i].eq(words[i]), init[i].eq(words[i])]
                    m.d.sync += [rnd.eq(0), self.busy.eq(1)]
                    m.next = 'RUN'
            with m.State('RUN'):
                for i in range(16):
                    m.d.sync += st[i].eq(w[i])
                with m.If(rnd == 9):
                    m.next = 'FIN'
                with m.Else():
                    m.d.sync += rnd.eq(rnd + 1)
            with m.State('FIN'):
                outs = [(st[i] + init[i])[:32] for i in range(16)]
                m.d.sync += [self.ks.eq(Cat(*outs)), self.done.eq(1),
                             self.busy.eq(0)]
                m.next = 'IDLE'
        return m


def poly_step(m, acc, blockfull, r, prefix):
    """acc' = ((acc + blockfull) * r) mod (2^130 - 5), combinational.
    acc < 2^131, blockfull < 2^129, r < 2^124."""
    n = Signal(132, name=prefix + '_n')
    m.d.comb += n.eq(acc + blockfull)
    t = Signal(256, name=prefix + '_t')
    m.d.comb += t.eq(n * r)
    r1 = Signal(132, name=prefix + '_r1')
    m.d.comb += r1.eq(t[0:130] + 5 * t[130:256])
    r2 = Signal(131, name=prefix + '_r2')
    m.d.comb += r2.eq(r1[0:130] + 5 * r1[130:132])
    tmp = Signal(131, name=prefix + '_tmp')
    m.d.comb += tmp.eq(r2 + 5)
    out = Signal(131, name=prefix + '_o')
    m.d.comb += out.eq(Mux(tmp[130], tmp[0:130], r2[0:130]))
    return out


R_CLAMP = 0x0ffffffc0ffffffc0ffffffc0fffffff


class AEADChaCha20Poly1305(Elaboratable):
    """RFC 8439 ChaCha20-Poly1305 AEAD seal/open over bounded buffers."""

    def __init__(self):
        self.start = Signal()
        self.op = Signal()
        self.key = Signal(256)
        self.nonce = Signal(96)
        self.aad = Signal(AAD_BITS)
        self.aadlen = Signal(range(MAX_AAD + 1))
        self.data = Signal(PT_BITS)          # pt (seal) or ct (open)
        self.datalen = Signal(range(MAX_PT + 1))
        self.tag_in = Signal(128)
        self.busy = Signal()
        self.done = Signal()
        self.out = Signal(PT_BITS)           # ct (seal) or pt (open)
        self.tag_out = Signal(128)
        self.auth_ok = Signal()

    def elaborate(self, platform):
        m = Module()
        m.submodules.cc = cc = ChaCha20Block()

        r = Signal(128)
        s = Signal(128)
        ksbuf = Signal(PT_BITS)
        blk = Signal(range(N_PT_BLK + 1))
        acc = Signal(131)
        midx = Signal(range(2 * (MAX_PT // 16 + MAX_AAD // 16) + 4))
        naad = Signal(range(MAX_AAD // 16 + 2))
        nct = Signal(range(MAX_PT // 16 + 2))
        ntot = Signal(range(MAX_PT // 16 + MAX_AAD // 16 + 4))

        # xor of data with keystream (ct for seal, pt for open)
        xored = Signal(PT_BITS)
        m.d.comb += xored.eq(self.data ^ ksbuf)
        # ciphertext used by the MAC, masked to datalen bytes.
        ctmask = Signal(PT_BITS + 1)
        m.d.comb += ctmask.eq((Const(1, PT_BITS + 1) << (self.datalen << 3)) - 1)
        ct_mac = Signal(PT_BITS)
        m.d.comb += ct_mac.eq(Mux(self.op == OP_SEAL, xored, self.data) & ctmask)

        # cc input mux
        cc_ctr = Signal(32)
        m.d.comb += [cc.key.eq(self.key), cc.nonce.eq(self.nonce),
                     cc.counter.eq(cc_ctr)]

        # block selection for the MAC
        aad_blk = Signal(128)
        ct_blk = Signal(128)
        len_blk = Signal(128)
        ctlocal = Signal(8)
        m.d.comb += ctlocal.eq(Mux(midx >= naad, midx - naad, 0))
        m.d.comb += [
            aad_blk.eq(self.aad >> (midx << 7)),
            ct_blk.eq(ct_mac >> (ctlocal << 7)),
            len_blk.eq(self.aadlen | (self.datalen << 64)),
        ]
        cur_blk = Signal(128)
        with m.If(midx < naad):
            m.d.comb += cur_blk.eq(aad_blk)
        with m.Elif(midx < ntot - 1):
            m.d.comb += cur_blk.eq(ct_blk)
        with m.Else():
            m.d.comb += cur_blk.eq(len_blk)
        blockfull = Signal(129)
        m.d.comb += blockfull.eq(Cat(cur_blk, Const(1, 1)))
        acc_next = poly_step(m, acc, blockfull, r, 'ps')

        tagval = Signal(129)
        m.d.comb += tagval.eq(acc + s)
        # constant-time tag compare for open
        diff = Signal(128)
        m.d.comb += diff.eq(tagval[0:128] ^ self.tag_in)

        m.d.sync += [self.done.eq(0), cc.start.eq(0)]

        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    m.d.sync += [self.busy.eq(1), cc_ctr.eq(0),
                                 cc.start.eq(1)]
                    m.next = 'PKEY_W'
            with m.State('PKEY_W'):
                with m.If(cc.done):
                    m.d.sync += [r.eq(cc.ks[0:128] & R_CLAMP),
                                 s.eq(cc.ks[128:256]),
                                 blk.eq(0), cc_ctr.eq(1), cc.start.eq(1)]
                    m.next = 'KS_W'
            with m.State('KS_W'):
                with m.If(cc.done):
                    # place this keystream block at byte offset 64*blk.
                    m.d.sync += ksbuf.eq(ksbuf
                                         | (cc.ks << (blk * 512)))
                    with m.If(blk == N_PT_BLK - 1):
                        m.next = 'MAC0'
                    with m.Else():
                        m.d.sync += [blk.eq(blk + 1), cc_ctr.eq(2 + blk),
                                     cc.start.eq(1)]
            with m.State('MAC0'):
                # block counts (ceil to 16) and output.
                na = (self.aadlen + 15) >> 4
                nc = (self.datalen + 15) >> 4
                m.d.sync += [naad.eq(na), nct.eq(nc),
                             ntot.eq(na + nc + 1), midx.eq(0), acc.eq(0),
                             self.out.eq(xored)]
                m.next = 'MAC'
            with m.State('MAC'):
                m.d.sync += acc.eq(acc_next)
                with m.If(midx == ntot - 1):
                    m.next = 'FINAL'
                with m.Else():
                    m.d.sync += midx.eq(midx + 1)
            with m.State('FINAL'):
                m.d.sync += [self.tag_out.eq(tagval[0:128]),
                             self.auth_ok.eq((self.op == OP_OPEN)
                                             & (diff == 0)
                                             | (self.op == OP_SEAL)),
                             self.done.eq(1), self.busy.eq(0)]
                m.next = 'IDLE'
        return m
