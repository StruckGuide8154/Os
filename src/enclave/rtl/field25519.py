# ============================================================================
# field25519.py - Track 10 enclave gateware: REAL, synthesizable arithmetic in
# the prime field GF(p), p = 2^255 - 19 (Amaranth HDL). This is A1 of Bucket A
# and the foundation X25519 (A2) and Ed25519 (A3) are built on.
#
# Properties relied on by the enclave threat model:
#   * Constant-time by construction. add/sub/mul/sqr resolve combinationally
#     (a fixed gate network, no data-dependent control). invert runs a FIXED
#     255-iteration Fermat ladder (a^(p-2)); the exponent is the PUBLIC modulus
#     constant, so the per-iteration multiply decision is not secret-dependent.
#     The USB-reachable command port is therefore not a timing oracle.
#   * On-die only: every operand and intermediate lives in fabric registers.
#
# Reduction strategy (carry-save fold): since 2^255 == 19 (mod p), a value
# x = lo + 2^255*hi reduces to lo + 19*hi. Three folds collapse a 512-bit
# product to < 2^255 + 19, and a single constant-time conditional subtract of p
# freezes it to the canonical range [0, p).
#
# Interface (one operation per `start` pulse):
#   inputs : start, op[3] (OP_ADD/SUB/MUL/SQR/INV), a[256], b[256]
#   outputs: busy, done (1-cycle strobe), result[256]  (canonical, < p)
# ============================================================================

from amaranth import Module, Signal, Elaboratable, Mux, Cat

P = (1 << 255) - 19

OP_ADD = 0
OP_SUB = 1
OP_MUL = 2
OP_SQR = 3
OP_INV = 4

# Exponent for inversion: a^(p-2) = a^-1 (mod p). p-2 is public.
_INV_EXP = P - 2
_EXP_BITS = [(_INV_EXP >> i) & 1 for i in range(255)]  # bit 0 .. bit 254


def _freeze(m, value_expr, prefix):
    """Combinationally reduce a value < 2^512 to the canonical range [0, p).

    Returns a 256-bit Signal congruent to value_expr mod p and < p.
    """
    x = Signal(512, name=prefix + '_x')
    m.d.comb += x.eq(value_expr)
    # Fold 1: x < 2^512 -> r1 < 2^262.
    r1 = Signal(262, name=prefix + '_r1')
    m.d.comb += r1.eq(x[0:255] + 19 * x[255:512])
    # Fold 2: r1 < 2^262 -> r2 < 2^255 + 2^12 (fits 256).
    r2 = Signal(256, name=prefix + '_r2')
    m.d.comb += r2.eq(r1[0:255] + 19 * r1[255:262])
    # Fold 3: r2 < 2^256 -> r3 < 2^255 + 19 (< 2p).
    r3 = Signal(256, name=prefix + '_r3')
    m.d.comb += r3.eq(r2[0:255] + 19 * r2[255])
    # Constant-time conditional subtract of p: if r3 >= p, bit 255 of (r3+19)
    # is set and (r3+19) mod 2^255 = r3 - p; otherwise keep r3.
    tmp = Signal(256, name=prefix + '_tmp')
    m.d.comb += tmp.eq(r3 + 19)
    out = Signal(256, name=prefix + '_out')
    m.d.comb += out.eq(Mux(tmp[255], tmp[0:255], r3[0:255]))
    return out


class Field25519(Elaboratable):
    """GF(2^255-19) arithmetic unit. add/sub/mul/sqr: 2 cycles (latch+strobe);
    invert: 255-iteration Fermat ladder."""

    def __init__(self):
        self.start = Signal()
        self.op = Signal(3)
        self.a = Signal(256)
        self.b = Signal(256)
        self.busy = Signal()
        self.done = Signal()
        self.result = Signal(256)

    def elaborate(self, platform):
        m = Module()

        a_r = Signal(256)
        b_r = Signal(256)
        op_r = Signal(3)

        # Generic combinational field multiply of two registered operands, used
        # both for OP_MUL/OP_SQR and inside the inversion ladder.
        mul_a = Signal(256)
        mul_b = Signal(256)
        mul_out = _freeze(m, mul_a * mul_b, 'mul')

        # add / sub combinational results over the registered operands.
        add_out = _freeze(m, a_r + b_r, 'add')
        sub_out = _freeze(m, a_r + (2 * P) - b_r, 'sub')

        # --- inversion ladder state -----------------------------------------
        acc = Signal(256)            # running accumulator (a^k)
        base = Signal(256)           # the operand being inverted
        idx = Signal(range(256))     # current exponent bit index (254..0)
        sq = Signal(256)             # acc^2
        muled = Signal(256)          # acc^2 * base
        exp_bit = Signal()
        # Index the public exponent bit table.
        with m.Switch(idx):
            for i in range(255):
                with m.Case(i):
                    m.d.comb += exp_bit.eq(_EXP_BITS[i])

        m.d.sync += self.done.eq(0)

        with m.FSM():
            with m.State('IDLE'):
                with m.If(self.start):
                    m.d.sync += [a_r.eq(self.a), b_r.eq(self.b),
                                 op_r.eq(self.op), self.busy.eq(1)]
                    with m.Switch(self.op):
                        with m.Case(OP_INV):
                            # acc = 1, base = a; walk bits 254..0.
                            m.d.sync += [acc.eq(1), base.eq(self.a),
                                         idx.eq(254)]
                            m.next = 'INV'
                        with m.Default():
                            m.next = 'COMB'
            with m.State('COMB'):
                with m.Switch(op_r):
                    with m.Case(OP_ADD):
                        m.d.sync += self.result.eq(add_out)
                    with m.Case(OP_SUB):
                        m.d.sync += self.result.eq(sub_out)
                    with m.Case(OP_SQR):
                        m.d.comb += [mul_a.eq(a_r), mul_b.eq(a_r)]
                        m.d.sync += self.result.eq(mul_out)
                    with m.Default():        # OP_MUL
                        m.d.comb += [mul_a.eq(a_r), mul_b.eq(b_r)]
                        m.d.sync += self.result.eq(mul_out)
                m.d.sync += [self.done.eq(1), self.busy.eq(0)]
                m.next = 'IDLE'
            with m.State('INV'):
                # square then conditional multiply, both off the same combinational
                # multiplier instance evaluated in two sub-cycles.
                m.d.comb += [mul_a.eq(acc), mul_b.eq(acc)]
                m.d.sync += sq.eq(mul_out)
                m.next = 'INV_MUL'
            with m.State('INV_MUL'):
                m.d.comb += [mul_a.eq(sq), mul_b.eq(base)]
                m.d.sync += acc.eq(Mux(exp_bit, mul_out, sq))
                with m.If(idx == 0):
                    m.next = 'INV_DONE'
                with m.Else():
                    m.d.sync += idx.eq(idx - 1)
                    m.next = 'INV'
            with m.State('INV_DONE'):
                m.d.sync += [self.result.eq(acc), self.done.eq(1),
                             self.busy.eq(0)]
                m.next = 'IDLE'

        return m
