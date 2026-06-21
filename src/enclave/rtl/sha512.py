# ============================================================================
# sha512.py - Track 10 enclave gateware: a REAL, synthesizable SHA-512 block
# compressor (Amaranth HDL). This replaces the non-cryptographic placeholder
# mix in crypto_session.py for the hashing path, and is the foundation the
# Ed25519 signer is built on (Ed25519 = SHA-512 over R || A || M).
#
# Properties relied on by the enclave threat model:
#   * Constant-time by construction: a fixed 81-cycle schedule per 1024-bit
#     block, no secret-dependent branches or memory indexing. The USB-reachable
#     command port is therefore not a timing oracle for the hash path.
#   * On-die only: message schedule is a 16x64 sliding window in fabric
#     registers; no external memory.
#
# Interface (one 1024-bit block per invocation; padding + multi-block chaining
# done by the caller, exactly like a standard HW SHA core):
#   inputs : start, h_in[512]  (current chaining value, word0 in the MSBs),
#            block[1024] (word0 in the MSBs, big-endian per FIPS 180-4)
#   outputs: busy, done (1-cycle strobe), h_out[512]
# ============================================================================

from amaranth import Module, Signal, Elaboratable, Array, Cat, Const

# FIPS 180-4 SHA-512 round constants K[0..79].
K = [
    0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
    0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
    0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
    0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
    0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
    0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
    0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
    0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
    0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
    0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
    0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
    0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
    0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
    0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
    0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
    0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
    0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
    0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
]

# FIPS 180-4 SHA-512 initial hash value (for the convenience IV port).
IV = [
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
]

MASK64 = (1 << 64) - 1


def _rotr(x, n):
    # 64-bit rotate-right: low bits become x[n:], high bits wrap x[:n].
    return Cat(x[n:], x[:n])


class SHA512Block(Elaboratable):
    """One SHA-512 compression over a single 1024-bit block.

    81 cycles: 1 load + 80 rounds (the final add folds into the last cycle via
    a one-cycle FINAL tail, so total visible latency is 82 from start to done).
    """

    def __init__(self):
        self.start = Signal()
        self.h_in = Signal(512)
        self.block = Signal(1024)
        self.busy = Signal()
        self.done = Signal()
        self.h_out = Signal(512)

    def elaborate(self, platform):
        m = Module()

        a, b, c, d, e, f, g, h = (Signal(64, name=n) for n in "abcdefgh")
        hin = [Signal(64, name=f"hin{i}") for i in range(8)]
        w = Array([Signal(64, name=f"w{i}") for i in range(16)])
        t = Signal(range(82))
        karr = Array([Const(k, 64) for k in K])

        # word i (big-endian) of the 1024-bit block: word0 in the MSBs.
        def blkword(i):
            return self.block[(15 - i) * 64:(16 - i) * 64]

        def hinword(i):
            return self.h_in[(7 - i) * 64:(8 - i) * 64]

        m.d.sync += self.done.eq(0)

        # ---- schedule word for the current round -------------------------
        idx = Signal(4)
        im2 = Signal(4)
        im7 = Signal(4)
        im15 = Signal(4)
        m.d.comb += [idx.eq(t), im2.eq(t - 2), im7.eq(t - 7), im15.eq(t - 15)]

        wt = Signal(64)
        s0w = Signal(64)
        s1w = Signal(64)
        m.d.comb += [
            s0w.eq(_rotr(w[im15], 1) ^ _rotr(w[im15], 8) ^ (w[im15] >> 7)),
            s1w.eq(_rotr(w[im2], 19) ^ _rotr(w[im2], 61) ^ (w[im2] >> 6)),
        ]
        with m.If(t < 16):
            m.d.comb += wt.eq(w[idx])
        with m.Else():
            m.d.comb += wt.eq(w[idx] + s1w + w[im7] + s0w)

        # ---- round function ----------------------------------------------
        big0 = Signal(64)
        big1 = Signal(64)
        ch = Signal(64)
        maj = Signal(64)
        t1 = Signal(64)
        t2 = Signal(64)
        m.d.comb += [
            big1.eq(_rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41)),
            big0.eq(_rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39)),
            ch.eq((e & f) ^ (~e & g)),
            maj.eq((a & b) ^ (a & c) ^ (b & c)),
            t1.eq(h + big1 + ch + karr[t] + wt),
            t2.eq(big0 + maj),
        ]

        with m.If(self.start & ~self.busy):
            m.d.sync += [self.busy.eq(1), t.eq(0)]
            for i in range(16):
                m.d.sync += w[i].eq(blkword(i))
            for i, reg in enumerate([a, b, c, d, e, f, g, h]):
                m.d.sync += reg.eq(hinword(i))
            for i in range(8):
                m.d.sync += hin[i].eq(hinword(i))
        with m.Elif(self.busy):
            with m.If(t < 80):
                m.d.sync += [
                    h.eq(g), g.eq(f), f.eq(e), e.eq(d + t1),
                    d.eq(c), c.eq(b), b.eq(a), a.eq(t1 + t2),
                    t.eq(t + 1),
                ]
                with m.If(t >= 16):
                    m.d.sync += w[idx].eq(wt)
            with m.Else():
                outs = [a, b, c, d, e, f, g, h]
                words = [Signal(64, name=f"ho{i}") for i in range(8)]
                for i in range(8):
                    m.d.comb += words[i].eq(hin[i] + outs[i])
                m.d.sync += [self.h_out.eq(Cat(*reversed(words))),
                             self.done.eq(1), self.busy.eq(0)]

        return m
