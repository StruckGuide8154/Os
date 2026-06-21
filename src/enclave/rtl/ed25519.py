# ============================================================================
# ed25519.py - Track 10 enclave gateware A3: REAL, synthesizable Ed25519
# sign + verify (Amaranth HDL), built on A1 field arithmetic (field25519) and
# A0 SHA-512 (sha512.py). Edwards point add/double in extended coordinates,
# a fixed-iteration double-and-add scalar multiply (constant-time conditional
# add by Mux), and a shift/subtract reduction mod the group order L.
#
# Constant-time by construction: every scalar-mult iteration does identical
# work; the per-bit add is selected with a Mux, never a branch; reduction runs
# a fixed bit count. Secret-dependent control never reaches a timing output.
#
# Bounded model: the prehash inputs (sk, prefix||M, R||A||M) are hashed as a
# SINGLE padded SHA-512 block, which holds for messages up to ~40 bytes -- the
# RFC 8032 section 7.1 empty/1-byte/2-byte cases this core is verified against.
#
# Interface (one operation per `start` pulse):
#   mode=MODE_SIGN  : in sk[256], msg[MSG_BITS], mlen(bytes)
#                     out: sig_r[256], sig_s[256] (encoded little-endian ints)
#   mode=MODE_VERIFY: in pub[256], sig_r[256], sig_s[256], msg, mlen
#                     out: valid (1 = signature good)
#   common: start, busy, done(strobe)
# ============================================================================

from amaranth import Module, Signal, Elaboratable, Mux, Cat, Const

from .sha512 import SHA512Block, IV
from .field25519 import Field25519, OP_INV

P = (1 << 255) - 19
L = (1 << 252) + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, P - 2, P)) % P
D2 = (2 * D) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)
BX = 15112221349535400772501151409588531511454012693041857206046113283949847762202
BY = 46316835694926478169428394003475163141307993866256225615783033603165251855960
BT = (BX * BY) % P

MODE_SIGN = 0
MODE_VERIFY = 1

MSG_BITS = 64 * 8          # up to 64 message bytes (single-block prehash bound)


# ---- combinational field reduction (carry-fold, A1 strategy) -------------
def _freeze(m, value_expr, prefix):
    x = Signal(512, name=prefix + '_x'); m.d.comb += x.eq(value_expr)
    r1 = Signal(262, name=prefix + '_r1'); m.d.comb += r1.eq(x[0:255] + 19 * x[255:512])
    r2 = Signal(256, name=prefix + '_r2'); m.d.comb += r2.eq(r1[0:255] + 19 * r1[255:262])
    r3 = Signal(256, name=prefix + '_r3'); m.d.comb += r3.eq(r2[0:255] + 19 * r2[255])
    tmp = Signal(256, name=prefix + '_tmp'); m.d.comb += tmp.eq(r3 + 19)
    out = Signal(256, name=prefix + '_out')
    m.d.comb += out.eq(Mux(tmp[255], tmp[0:255], r3[0:255]))
    return out


def fmul(m, a, b, p):
    return _freeze(m, a * b, p)


def fadd(m, a, b, p):
    return _freeze(m, a + b, p)


def fsub(m, a, b, p):
    return _freeze(m, a + (2 * P) - b, p)


def point_add(m, X1, Y1, Z1, T1, X2, Y2, Z2, T2, p):
    """Unified twisted-Edwards (a=-1) extended-coordinate addition."""
    A = fmul(m, fsub(m, Y1, X1, p + 'a0'), fsub(m, Y2, X2, p + 'a1'), p + 'A')
    B = fmul(m, fadd(m, Y1, X1, p + 'b0'), fadd(m, Y2, X2, p + 'b1'), p + 'B')
    C = fmul(m, fmul(m, T1, D2, p + 'c0'), T2, p + 'C')
    Dd = fmul(m, fmul(m, Z1, 2, p + 'd0'), Z2, p + 'Dd')
    E = fsub(m, B, A, p + 'E')
    F = fsub(m, Dd, C, p + 'F')
    G = fadd(m, Dd, C, p + 'G')
    H = fadd(m, B, A, p + 'H')
    X3 = fmul(m, E, F, p + 'X3')
    Y3 = fmul(m, G, H, p + 'Y3')
    T3 = fmul(m, E, H, p + 'T3')
    Z3 = fmul(m, F, G, p + 'Z3')
    return X3, Y3, Z3, T3


class FieldExp(Elaboratable):
    """Raise a to a fixed public exponent E (mod p), constant 255-bit ladder."""

    def __init__(self, exponent, width=255):
        self.E = exponent
        self.W = width
        self.bits = [(exponent >> i) & 1 for i in range(width)]
        self.start = Signal()
        self.a = Signal(256)
        self.busy = Signal()
        self.done = Signal()
        self.result = Signal(256)

    def elaborate(self, platform):
        m = Module()
        acc = Signal(256)
        base = Signal(256)
        idx = Signal(range(self.W + 1))
        sq = Signal(256)
        ebit = Signal()
        with m.Switch(idx):
            for i in range(self.W):
                with m.Case(i):
                    m.d.comb += ebit.eq(self.bits[i])
        mul_a = Signal(256)
        mul_b = Signal(256)
        mout = fmul(m, mul_a, mul_b, 'fe')
        m.d.sync += self.done.eq(0)
        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    m.d.sync += [acc.eq(1), base.eq(self.a),
                                 idx.eq(self.W - 1), self.busy.eq(1)]
                    m.next = 'SQ'
            with m.State('SQ'):
                m.d.comb += [mul_a.eq(acc), mul_b.eq(acc)]
                m.d.sync += sq.eq(mout)
                m.next = 'MUL'
            with m.State('MUL'):
                m.d.comb += [mul_a.eq(sq), mul_b.eq(base)]
                m.d.sync += acc.eq(Mux(ebit, mout, sq))
                with m.If(idx == 0):
                    m.next = 'FIN'
                with m.Else():
                    m.d.sync += idx.eq(idx - 1)
                    m.next = 'SQ'
            with m.State('FIN'):
                m.d.sync += [self.result.eq(acc), self.done.eq(1),
                             self.busy.eq(0)]
                m.next = 'IDLE'
        return m


class ScalarMul(Elaboratable):
    """[s]P on the Edwards curve: fixed 253-iteration double-and-add.

    P is supplied as extended coords; result returned in extended coords.
    Constant-time: every step doubles and conditionally adds (via Mux)."""

    NBITS = 255

    def __init__(self):
        self.start = Signal()
        self.s = Signal(256)
        self.PX = Signal(256)
        self.PY = Signal(256)
        self.PZ = Signal(256)
        self.PT = Signal(256)
        self.busy = Signal()
        self.done = Signal()
        self.RX = Signal(256)
        self.RY = Signal(256)
        self.RZ = Signal(256)
        self.RT = Signal(256)

    def elaborate(self, platform):
        m = Module()
        QX = Signal(256); QY = Signal(256); QZ = Signal(256); QT = Signal(256)
        bx = Signal(256); by = Signal(256); bz = Signal(256); bt = Signal(256)
        s_r = Signal(256)
        idx = Signal(range(self.NBITS + 1))
        sbit = Signal()
        m.d.comb += sbit.eq(s_r.bit_select(idx, 1))

        # double then conditional add, combinationally per cycle.
        dX, dY, dZ, dT = point_add(m, QX, QY, QZ, QT, QX, QY, QZ, QT, 'dbl')
        aX, aY, aZ, aT = point_add(m, dX, dY, dZ, dT, bx, by, bz, bt, 'add')

        m.d.sync += self.done.eq(0)
        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    # Q = identity (0,1,1,0); base = P.
                    m.d.sync += [QX.eq(0), QY.eq(1), QZ.eq(1), QT.eq(0),
                                 bx.eq(self.PX), by.eq(self.PY),
                                 bz.eq(self.PZ), bt.eq(self.PT),
                                 s_r.eq(self.s), idx.eq(self.NBITS - 1),
                                 self.busy.eq(1)]
                    m.next = 'STEP'
            with m.State('STEP'):
                m.d.sync += [
                    QX.eq(Mux(sbit, aX, dX)), QY.eq(Mux(sbit, aY, dY)),
                    QZ.eq(Mux(sbit, aZ, dZ)), QT.eq(Mux(sbit, aT, dT)),
                ]
                with m.If(idx == 0):
                    m.next = 'FIN'
                with m.Else():
                    m.d.sync += idx.eq(idx - 1)
            with m.State('FIN'):
                m.d.sync += [self.RX.eq(QX), self.RY.eq(QY), self.RZ.eq(QZ),
                             self.RT.eq(QT), self.done.eq(1), self.busy.eq(0)]
                m.next = 'IDLE'
        return m


def byterev256(m, v, prefix):
    """Reverse the 32-byte order of a 256-bit value (LE<->BE serialization)."""
    out = Signal(256, name=prefix + '_rev')
    m.d.comb += out.eq(Cat(*[v[8 * i:8 * (i + 1)]
                             for i in reversed(range(32))]))
    return out


class Sha512Msg(Elaboratable):
    """SHA-512 of a single padded block: data is byte0-in-MSB, left-aligned in
    1024 bits; nbytes <= 111 so padding (0x80, zeros, 128-bit length) fits one
    block. Wraps the A0 SHA512Block compressor."""

    def __init__(self):
        self.start = Signal()
        self.data = Signal(1024)        # left-aligned, byte0 in the MSBs
        self.nbytes = Signal(7)         # 0..111
        self.busy = Signal()
        self.done = Signal()
        self.digest = Signal(512)

    def elaborate(self, platform):
        m = Module()
        m.submodules.core = core = SHA512Block()
        iv_int = 0
        for w in IV:
            iv_int = (iv_int << 64) | w

        block = Signal(1024)
        # 0x80 byte at position nbytes; 128-bit length (in bits) in the low 128.
        shift = Signal(11)
        m.d.comb += shift.eq(1024 - 8 - (self.nbytes << 3))
        padbyte = Signal(1024)
        m.d.comb += padbyte.eq(Const(0x80, 1024) << shift)
        lenfield = Signal(1024)
        m.d.comb += lenfield.eq((self.nbytes << 3))    # message length in bits

        m.d.sync += [self.done.eq(0), core.start.eq(0)]
        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    m.d.sync += [block.eq(self.data | padbyte | lenfield),
                                 core.h_in.eq(iv_int), self.busy.eq(1)]
                    m.next = 'RUN'
            with m.State('RUN'):
                m.d.sync += [core.block.eq(block), core.start.eq(1)]
                m.next = 'WAIT'
            with m.State('WAIT'):
                with m.If(core.done):
                    m.d.sync += [self.digest.eq(core.h_out), self.done.eq(1),
                                 self.busy.eq(0)]
                    m.next = 'IDLE'
        return m


class ReduceL(Elaboratable):
    """val mod L via a fixed 512-iteration shift/subtract (constant-time)."""

    NB = 512

    def __init__(self):
        self.start = Signal()
        self.val = Signal(self.NB)
        self.busy = Signal()
        self.done = Signal()
        self.result = Signal(253)

    def elaborate(self, platform):
        m = Module()
        rem = Signal(254)
        v = Signal(self.NB)
        idx = Signal(range(self.NB + 1))
        bit = Signal()
        m.d.comb += bit.eq(v.bit_select(idx, 1))
        shifted = Signal(255)
        m.d.comb += shifted.eq((rem << 1) | bit)
        nxt = Signal(254)
        m.d.comb += nxt.eq(Mux(shifted >= L, shifted - L, shifted))
        m.d.sync += self.done.eq(0)
        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    m.d.sync += [rem.eq(0), v.eq(self.val),
                                 idx.eq(self.NB - 1), self.busy.eq(1)]
                    m.next = 'STEP'
            with m.State('STEP'):
                m.d.sync += rem.eq(nxt)
                with m.If(idx == 0):
                    m.next = 'FIN'
                with m.Else():
                    m.d.sync += idx.eq(idx - 1)
            with m.State('FIN'):
                m.d.sync += [self.result.eq(rem), self.done.eq(1),
                             self.busy.eq(0)]
                m.next = 'IDLE'
        return m


def byterevN(m, v, nbytes, prefix):
    out = Signal(nbytes * 8, name=prefix + '_revN')
    m.d.comb += out.eq(Cat(*[v[8 * i:8 * (i + 1)]
                             for i in reversed(range(nbytes))]))
    return out


class Ed25519(Elaboratable):
    """Full Ed25519 sign + verify over the A0/A1 cores. Single-block prehash
    bound (message <= ~40 bytes); RFC 8032 section 7.1 verified."""

    def __init__(self):
        self.start = Signal()
        self.mode = Signal()                 # MODE_SIGN / MODE_VERIFY
        self.sk = Signal(256)                # sign: secret seed, byte0 in MSB
        self.pub = Signal(256)               # verify: public key (LE enc int)
        self.in_sigr = Signal(256)           # verify: signature R (LE enc int)
        self.in_sigs = Signal(256)           # verify: signature S (LE int)
        self.msg = Signal(MSG_BITS)          # message, big-endian, right-aligned
        self.mlen = Signal(7)
        self.busy = Signal()
        self.done = Signal()
        self.sig_r = Signal(256)             # sign output: R (LE enc int)
        self.sig_s = Signal(256)             # sign output: S (LE int)
        self.valid = Signal()                # verify output

    def elaborate(self, platform):
        m = Module()
        m.submodules.sha = sha = Sha512Msg()
        m.submodules.sm = sm = ScalarMul()
        m.submodules.inv = inv = Field25519()
        m.submodules.rl = rl = ReduceL()
        m.submodules.fed = fed = FieldExp((P - 5) // 8, width=253)

        dg = Signal(512)
        a_s = Signal(256)
        pfx = Signal(256)
        r_s = Signal(253)
        k_s = Signal(253)
        S_s = Signal(253)
        Aenc = Signal(256)
        Renc = Signal(256)
        px = Signal(256); py = Signal(256); pz = Signal(256); pt = Signal(256)
        Apx = Signal(256); Apy = Signal(256)
        Rpx = Signal(256); Rpy = Signal(256)
        kax = Signal(256); kay = Signal(256); kaz = Signal(256); kat = Signal(256)
        sbx = Signal(256); sby = Signal(256); sbz = Signal(256)
        dec_in = Signal(256)
        dec_u = Signal(256); dec_v = Signal(256)
        dec_y = Signal(256); dec_sign = Signal()
        vfail = Signal()

        sm_s = Signal(256)
        sm_bx = Signal(256); sm_by = Signal(256)
        sm_bz = Signal(256); sm_bt = Signal(256)
        m.d.comb += [sm.s.eq(sm_s), sm.PX.eq(sm_bx), sm.PY.eq(sm_by),
                     sm.PZ.eq(sm_bz), sm.PT.eq(sm_bt)]

        # registered SHA inputs: set in a launch state together with start, so
        # the (registered) start strobe and the data are stable on the same cycle.
        sha_data = Signal(1024)
        sha_nbytes = Signal(7)
        m.d.comb += [sha.data.eq(sha_data), sha.nbytes.eq(sha_nbytes)]

        # combinational clamp of digest top-256 -> little-endian scalar
        hb = dg[256:512]
        hb_c = Cat((hb[0:8] & 0x7f) | 0x40, hb[8:248], hb[248:256] & 0xf8)
        a_clamped = byterevN(m, hb_c, 32, 'clamp')

        # combinational point encode of working point (px,py,pz,pt)
        zinv = inv.result
        enc_x = fmul(m, px, zinv, 'encx')
        enc_y = fmul(m, py, zinv, 'ency')
        enc_val = Signal(256)
        m.d.comb += enc_val.eq(Cat(enc_y[0:255], enc_x[0]))

        rev_msg_len = Signal(11)
        m.d.comb += rev_msg_len.eq(self.mlen << 3)

        m.d.sync += [self.done.eq(0), sha.start.eq(0), sm.start.eq(0),
                     inv.start.eq(0), rl.start.eq(0), fed.start.eq(0)]

        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    m.d.sync += [self.busy.eq(1), vfail.eq(0)]
                    with m.If(self.mode == MODE_SIGN):
                        m.next = 'S_HSK'
                    with m.Else():
                        m.next = 'V_DECA0'

            # ===================== SIGN =================================
            with m.State('S_HSK'):
                m.d.sync += [sha_data.eq(self.sk << 768), sha_nbytes.eq(32),
                             sha.start.eq(1)]
                m.next = 'S_HSK_W'
            with m.State('S_HSK_W'):
                with m.If(sha.done):
                    m.d.sync += dg.eq(sha.digest)
                    m.next = 'S_CLAMP'
            with m.State('S_CLAMP'):
                m.d.sync += [a_s.eq(a_clamped), pfx.eq(dg[0:256]),
                             sm_s.eq(a_clamped), sm_bx.eq(BX), sm_by.eq(BY),
                             sm_bz.eq(1), sm_bt.eq(BT), sm.start.eq(1)]
                m.next = 'S_AB_W'
            with m.State('S_AB_W'):
                with m.If(sm.done):
                    m.d.sync += [px.eq(sm.RX), py.eq(sm.RY), pz.eq(sm.RZ),
                                 pt.eq(sm.RT)]
                    m.next = 'S_ENCA'
            with m.State('S_ENCA'):
                m.d.sync += [inv.a.eq(pz), inv.op.eq(OP_INV), inv.start.eq(1)]
                m.next = 'S_ENCA_W'
            with m.State('S_ENCA_W'):
                with m.If(inv.done):
                    m.d.sync += Aenc.eq(enc_val)
                    m.next = 'S_HR'
            with m.State('S_HR'):
                m.d.sync += [sha_data.eq((pfx << 768)
                                         | ((self.msg << 768) >> rev_msg_len)),
                             sha_nbytes.eq(32 + self.mlen), sha.start.eq(1)]
                m.next = 'S_HR_W'
            with m.State('S_HR_W'):
                with m.If(sha.done):
                    m.d.sync += dg.eq(sha.digest)
                    m.next = 'S_REDR'
            with m.State('S_REDR'):
                m.d.sync += [rl.val.eq(byterevN(m, dg, 64, 'rr')),
                             rl.start.eq(1)]
                m.next = 'S_REDR_W'
            with m.State('S_REDR_W'):
                with m.If(rl.done):
                    m.d.sync += [r_s.eq(rl.result),
                                 sm_s.eq(rl.result), sm_bx.eq(BX), sm_by.eq(BY),
                                 sm_bz.eq(1), sm_bt.eq(BT), sm.start.eq(1)]
                    m.next = 'S_RB_W'
            with m.State('S_RB_W'):
                with m.If(sm.done):
                    m.d.sync += [px.eq(sm.RX), py.eq(sm.RY), pz.eq(sm.RZ),
                                 pt.eq(sm.RT)]
                    m.next = 'S_ENCR'
            with m.State('S_ENCR'):
                m.d.sync += [inv.a.eq(pz), inv.op.eq(OP_INV), inv.start.eq(1)]
                m.next = 'S_ENCR_W'
            with m.State('S_ENCR_W'):
                with m.If(inv.done):
                    m.d.sync += Renc.eq(enc_val)
                    m.next = 'S_HK'
            with m.State('S_HK'):
                Rbe = byterevN(m, Renc, 32, 'hkr')
                Abe = byterevN(m, Aenc, 32, 'hka')
                m.d.sync += [sha_data.eq((Rbe << 768) | (Abe << 512)
                                         | ((self.msg << 512) >> rev_msg_len)),
                             sha_nbytes.eq(64 + self.mlen), sha.start.eq(1)]
                m.next = 'S_HK_W'
            with m.State('S_HK_W'):
                with m.If(sha.done):
                    m.d.sync += dg.eq(sha.digest)
                    m.next = 'S_REDK'
            with m.State('S_REDK'):
                m.d.sync += [rl.val.eq(byterevN(m, dg, 64, 'rk')),
                             rl.start.eq(1)]
                m.next = 'S_REDK_W'
            with m.State('S_REDK_W'):
                with m.If(rl.done):
                    m.d.sync += k_s.eq(rl.result)
                    m.next = 'S_BIGS'
            with m.State('S_BIGS'):
                prod = Signal(512)
                m.d.comb += prod.eq(k_s * a_s + r_s)
                m.d.sync += [rl.val.eq(prod), rl.start.eq(1)]
                m.next = 'S_BIGS_W'
            with m.State('S_BIGS_W'):
                with m.If(rl.done):
                    m.d.sync += [S_s.eq(rl.result), self.sig_r.eq(Renc),
                                 self.sig_s.eq(rl.result)]
                    m.next = 'FINISH'

            # ===================== VERIFY ==============================
            with m.State('V_DECA0'):
                m.d.sync += dec_in.eq(self.pub)
                m.next = 'V_DEC0'
            with m.State('V_DEC0'):
                y = dec_in[0:255]
                y2 = fmul(m, y, y, 'dy2')
                u = fsub(m, y2, 1, 'du')
                v = fadd(m, fmul(m, D, y2, 'ddy2'), 1, 'dv')
                v2 = fmul(m, v, v, 'dv2')
                v3 = fmul(m, v2, v, 'dv3')
                v4 = fmul(m, v2, v2, 'dv4')
                v7 = fmul(m, v4, v3, 'dv7')
                uv7 = fmul(m, u, v7, 'duv7')
                m.d.sync += [dec_u.eq(u), dec_v.eq(v), dec_y.eq(y),
                             dec_sign.eq(dec_in[255]),
                             fed.a.eq(uv7), fed.start.eq(1)]
                with m.If(dec_in[0:255] >= P):
                    m.d.sync += vfail.eq(1)
                m.next = 'V_DEC1'
            with m.State('V_DEC1'):
                with m.If(fed.done):
                    w = fed.result
                    v3 = fmul(m, fmul(m, dec_v, dec_v, 'e3a'), dec_v, 'e3b')
                    xc = fmul(m, fmul(m, dec_u, v3, 'exa'), w, 'exb')
                    m.d.sync += px.eq(xc)
                    m.next = 'V_DEC2'
            with m.State('V_DEC2'):
                x = px
                vxx = fmul(m, dec_v, fmul(m, x, x, 'vx2a'), 'vxx')
                negu = fsub(m, 0, dec_u, 'negu')
                xi = fmul(m, x, SQRT_M1, 'xi')
                xgood = Signal(256); ok = Signal()
                with m.If(vxx == dec_u):
                    m.d.comb += [xgood.eq(x), ok.eq(1)]
                with m.Elif(vxx == negu):
                    m.d.comb += [xgood.eq(xi), ok.eq(1)]
                with m.Else():
                    m.d.comb += [xgood.eq(x), ok.eq(0)]
                xfinal = Signal(256)
                m.d.comb += xfinal.eq(Mux(xgood[0] != dec_sign, P - xgood, xgood))
                with m.If((~ok) | ((xfinal == 0) & dec_sign)):
                    m.d.sync += vfail.eq(1)
                m.d.sync += [Apx.eq(xfinal), Apy.eq(dec_y)]
                m.next = 'V_DECR0'

            with m.State('V_DECR0'):
                m.d.sync += dec_in.eq(self.in_sigr)
                m.next = 'V_DECR1'
            with m.State('V_DECR1'):
                y = dec_in[0:255]
                y2 = fmul(m, y, y, 'ry2')
                u = fsub(m, y2, 1, 'ru')
                v = fadd(m, fmul(m, D, y2, 'rdy2'), 1, 'rv')
                v2 = fmul(m, v, v, 'rv2')
                v3 = fmul(m, v2, v, 'rv3')
                v4 = fmul(m, v2, v2, 'rv4')
                v7 = fmul(m, v4, v3, 'rv7')
                uv7 = fmul(m, u, v7, 'ruv7')
                m.d.sync += [dec_u.eq(u), dec_v.eq(v), dec_y.eq(y),
                             dec_sign.eq(dec_in[255]),
                             fed.a.eq(uv7), fed.start.eq(1)]
                with m.If(dec_in[0:255] >= P):
                    m.d.sync += vfail.eq(1)
                m.next = 'V_DECR2'
            with m.State('V_DECR2'):
                with m.If(fed.done):
                    w = fed.result
                    v3 = fmul(m, fmul(m, dec_v, dec_v, 'r3a'), dec_v, 'r3b')
                    xc = fmul(m, fmul(m, dec_u, v3, 'rxa'), w, 'rxb')
                    m.d.sync += px.eq(xc)
                    m.next = 'V_DECR3'
            with m.State('V_DECR3'):
                x = px
                vxx = fmul(m, dec_v, fmul(m, x, x, 'rvx2a'), 'rvxx')
                negu = fsub(m, 0, dec_u, 'rnegu')
                xi = fmul(m, x, SQRT_M1, 'rxi')
                xgood = Signal(256); ok = Signal()
                with m.If(vxx == dec_u):
                    m.d.comb += [xgood.eq(x), ok.eq(1)]
                with m.Elif(vxx == negu):
                    m.d.comb += [xgood.eq(xi), ok.eq(1)]
                with m.Else():
                    m.d.comb += [xgood.eq(x), ok.eq(0)]
                xfinal = Signal(256)
                m.d.comb += xfinal.eq(Mux(xgood[0] != dec_sign, P - xgood, xgood))
                with m.If((~ok) | ((xfinal == 0) & dec_sign)):
                    m.d.sync += vfail.eq(1)
                m.d.sync += [Rpx.eq(xfinal), Rpy.eq(dec_y)]
                m.next = 'V_HK'

            with m.State('V_HK'):
                Rbe = byterevN(m, self.in_sigr, 32, 'vhr')
                Abe = byterevN(m, self.pub, 32, 'vha')
                m.d.sync += [sha_data.eq((Rbe << 768) | (Abe << 512)
                                         | ((self.msg << 512) >> rev_msg_len)),
                             sha_nbytes.eq(64 + self.mlen), sha.start.eq(1)]
                m.next = 'V_HK_W'
            with m.State('V_HK_W'):
                with m.If(sha.done):
                    m.d.sync += dg.eq(sha.digest)
                    m.next = 'V_REDK'
            with m.State('V_REDK'):
                m.d.sync += [rl.val.eq(byterevN(m, dg, 64, 'vrk')),
                             rl.start.eq(1)]
                m.next = 'V_REDK_W'
            with m.State('V_REDK_W'):
                with m.If(rl.done):
                    m.d.sync += k_s.eq(rl.result)
                    with m.If(self.in_sigs >= L):
                        m.d.sync += vfail.eq(1)
                    m.d.sync += [sm_s.eq(self.in_sigs), sm_bx.eq(BX),
                                 sm_by.eq(BY), sm_bz.eq(1), sm_bt.eq(BT),
                                 sm.start.eq(1)]
                    m.next = 'V_SB_W'
            with m.State('V_SB_W'):
                with m.If(sm.done):
                    m.d.sync += [sbx.eq(sm.RX), sby.eq(sm.RY), sbz.eq(sm.RZ)]
                    kat_v = fmul(m, Apx, Apy, 'katv')
                    m.d.sync += [sm_s.eq(k_s), sm_bx.eq(Apx), sm_by.eq(Apy),
                                 sm_bz.eq(1), sm_bt.eq(kat_v), sm.start.eq(1)]
                    m.next = 'V_KA_W'
            with m.State('V_KA_W'):
                with m.If(sm.done):
                    m.d.sync += [kax.eq(sm.RX), kay.eq(sm.RY),
                                 kaz.eq(sm.RZ), kat.eq(sm.RT)]
                    m.next = 'V_ADD'
            with m.State('V_ADD'):
                Rt = fmul(m, Rpx, Rpy, 'rt')
                X2, Y2, Z2, T2 = point_add(m, Rpx, Rpy, 1, Rt,
                                           kax, kay, kaz, kat, 'vadd')
                m.d.sync += [kax.eq(X2), kay.eq(Y2), kaz.eq(Z2)]
                m.next = 'V_CMP'
            with m.State('V_CMP'):
                lhsX = fmul(m, sbx, kaz, 'cx1')
                rhsX = fmul(m, kax, sbz, 'cx2')
                lhsY = fmul(m, sby, kaz, 'cy1')
                rhsY = fmul(m, kay, sbz, 'cy2')
                eqp = Signal()
                m.d.comb += eqp.eq((lhsX == rhsX) & (lhsY == rhsY))
                m.d.sync += self.valid.eq(eqp & ~vfail)
                m.next = 'FINISH'

            with m.State('FINISH'):
                m.d.sync += [self.done.eq(1), self.busy.eq(0)]
                m.next = 'IDLE'

        return m
