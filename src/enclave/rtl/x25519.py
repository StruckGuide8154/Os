# ============================================================================
# x25519.py - Track 10 enclave gateware A2: REAL, synthesizable X25519
# (Curve25519 Diffie-Hellman) via the Montgomery ladder, built on the A1 field
# core (field25519.py). Amaranth HDL.
#
# Constant-time by construction:
#   * Fixed 255-iteration ladder; every iteration does the SAME work.
#   * The per-bit conditional swap is a data-flow Mux (cswap), never a branch,
#     so the scalar bit pattern is invisible to the control path / cycle count.
#   * The scalar is clamped per RFC 7748 (clear low 3 bits, force bit 254,
#     clear bit 255). The final z-inversion reuses the A1 Fermat ladder.
#
# Interface (one scalarmult per `start` pulse):
#   inputs : start, k[256] (scalar, little-endian integer), u[256] (u-coord)
#   outputs: busy, done (1-cycle strobe), result[256] (resulting u-coord)
# ============================================================================

from amaranth import Module, Signal, Elaboratable, Mux

from .field25519 import Field25519, P, OP_INV

A24 = 121665   # (486662 - 2) / 4


def _freeze(m, value_expr, prefix):
    # Local copy of the A1 carry-fold reduction (value < 2^512 -> [0, p)).
    from amaranth import Signal as S
    x = S(512, name=prefix + '_x'); m.d.comb += x.eq(value_expr)
    r1 = S(262, name=prefix + '_r1'); m.d.comb += r1.eq(x[0:255] + 19 * x[255:512])
    r2 = S(256, name=prefix + '_r2'); m.d.comb += r2.eq(r1[0:255] + 19 * r1[255:262])
    r3 = S(256, name=prefix + '_r3'); m.d.comb += r3.eq(r2[0:255] + 19 * r2[255])
    tmp = S(256, name=prefix + '_tmp'); m.d.comb += tmp.eq(r3 + 19)
    out = S(256, name=prefix + '_out')
    m.d.comb += out.eq(Mux(tmp[255], tmp[0:255], r3[0:255]))
    return out


def _mul(m, x, y, p):
    return _freeze(m, x * y, p)


def _add(m, x, y, p):
    return _freeze(m, x + y, p)


def _sub(m, x, y, p):
    return _freeze(m, x + (2 * P) - y, p)


class X25519(Elaboratable):
    """RFC 7748 X25519 scalar multiplication."""

    def __init__(self):
        self.start = Signal()
        self.k = Signal(256)
        self.u = Signal(256)
        self.busy = Signal()
        self.done = Signal()
        self.result = Signal(256)

    def elaborate(self, platform):
        m = Module()
        m.submodules.inv = inv = Field25519()

        ks = Signal(256)          # clamped scalar
        x1 = Signal(256)          # base u-coordinate (mod p)
        x2 = Signal(256)
        z2 = Signal(256)
        x3 = Signal(256)
        z3 = Signal(256)
        swap = Signal()
        idx = Signal(range(256))

        kbit = Signal()
        m.d.comb += kbit.eq(ks.bit_select(idx, 1))

        # one combinational Montgomery ladder step over the registered state.
        do_swap = Signal()
        m.d.comb += do_swap.eq(swap ^ kbit)
        xa = Mux(do_swap, x3, x2)
        za = Mux(do_swap, z3, z2)
        xb = Mux(do_swap, x2, x3)
        zb = Mux(do_swap, z2, z3)

        A = _add(m, xa, za, 'A')
        B = _sub(m, xa, za, 'B')
        C = _add(m, xb, zb, 'C')
        D = _sub(m, xb, zb, 'D')
        AA = _mul(m, A, A, 'AA')
        BB = _mul(m, B, B, 'BB')
        E = _sub(m, AA, BB, 'E')
        DA = _mul(m, D, A, 'DA')
        CB = _mul(m, C, B, 'CB')
        t_x3 = _add(m, DA, CB, 'tx3')
        x3n = _mul(m, t_x3, t_x3, 'x3n')
        t_z3 = _sub(m, DA, CB, 'tz3')
        t_z3s = _mul(m, t_z3, t_z3, 'tz3s')
        z3n = _mul(m, x1, t_z3s, 'z3n')
        x2n = _mul(m, AA, BB, 'x2n')
        a24E = _mul(m, E, A24, 'a24E')
        za24 = _add(m, AA, a24E, 'za24')
        z2n = _mul(m, E, za24, 'z2n')

        m.d.sync += [self.done.eq(0), inv.start.eq(0)]

        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    # clamp per RFC 7748: clear low 3 bits and bit 255, set bit 254.
                    # decodeUCoordinate: mask the unused MSB (bit 255) per RFC 7748.
                    um = Signal(256)
                    m.d.comb += um.eq(self.u & ((1 << 255) - 1))
                    m.d.sync += [
                        ks.eq((self.k & ~((1 << 255) | 0x07)) | (1 << 254)),
                        x1.eq(_freeze(m, um, 'u1')),
                        x2.eq(1), z2.eq(0),
                        x3.eq(_freeze(m, um, 'u3')), z3.eq(1),
                        swap.eq(0), idx.eq(254),
                        self.busy.eq(1),
                    ]
                    m.next = 'LADDER'
            with m.State('LADDER'):
                m.d.sync += [
                    x2.eq(x2n), z2.eq(z2n), x3.eq(x3n), z3.eq(z3n),
                    swap.eq(kbit),
                ]
                with m.If(idx == 0):
                    # final unswap, then invert z2.
                    m.next = 'UNSWAP'
                with m.Else():
                    m.d.sync += idx.eq(idx - 1)
            with m.State('UNSWAP'):
                # after the loop swap==kbit(0); fold the residual swap once more.
                fx2 = Mux(swap, x3, x2)
                fz2 = Mux(swap, z3, z2)
                m.d.sync += [x2.eq(fx2), z2.eq(fz2),
                             inv.a.eq(fz2), inv.op.eq(OP_INV), inv.start.eq(1)]
                m.next = 'INV_WAIT'
            with m.State('INV_WAIT'):
                with m.If(inv.done):
                    m.next = 'FINISH'
            with m.State('FINISH'):
                m.d.sync += [self.result.eq(_mul(m, x2, inv.result, 'fin')),
                             self.done.eq(1), self.busy.eq(0)]
                m.next = 'IDLE'

        return m
