from amaranth import Elaboratable, Module, Signal, Cat

from .aead_chacha import _qr


class FixedLatencyCryptoCore(Elaboratable):
    """Fixed-cycle session-crypto integration boundary.

    The datapath is now the REAL ChaCha20 ARX permutation (a0.aead_chacha._qr
    quarter-rounds), not an ad-hoc mix: a constant 32-cycle schedule of ChaCha
    double-rounds over a 16-word state seeded from key/message/op. The point is
    the *contract*, not the mode -- every request takes exactly LATENCY cycles
    with an input-independent busy/done trace, so a reviewed constant-time core
    drops in without touching the command FSM. No secret-dependent control flow.
    """

    LATENCY = 32

    def __init__(self):
        self.start = Signal()
        self.op = Signal(2)
        self.key = Signal(256)
        self.message = Signal(256)
        self.busy = Signal()
        self.done = Signal()
        self.result = Signal(256)

    def elaborate(self, platform):
        m = Module()
        st = [Signal(32, name=f'cs{i}') for i in range(16)]
        count = Signal(range(self.LATENCY + 1))

        # one ChaCha double-round (column then diagonal) over the 16-word state.
        w = list(st)
        for (a, b, c, d) in [(0, 4, 8, 12), (1, 5, 9, 13),
                             (2, 6, 10, 14), (3, 7, 11, 15)]:
            w = _qr(w, a, b, c, d)
        for (a, b, c, d) in [(0, 5, 10, 15), (1, 6, 11, 12),
                             (2, 7, 8, 13), (3, 4, 9, 14)]:
            w = _qr(w, a, b, c, d)

        m.d.sync += self.done.eq(0)
        with m.If(self.start & ~self.busy):
            # seed: low 8 words = key^message, high 8 words = key plus op tweak.
            seed = self.key ^ self.message
            for i in range(8):
                m.d.sync += st[i].eq(seed[32 * i:32 * i + 32])
            for i in range(8):
                m.d.sync += st[8 + i].eq(self.key[32 * i:32 * i + 32]
                                         ^ (self.op + i))
            m.d.sync += [count.eq(self.LATENCY), self.busy.eq(1)]
        with m.Elif(self.busy):
            for i in range(16):
                m.d.sync += st[i].eq(w[i])
            with m.If(count == 1):
                m.d.sync += [self.result.eq(Cat(*w[0:8])),
                             self.done.eq(1), self.busy.eq(0), count.eq(0)]
            with m.Else():
                m.d.sync += count.eq(count - 1)
        return m
