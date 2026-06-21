from amaranth import Elaboratable, Module, Mux, Signal


class PUFKeySeal(Elaboratable):
    """PUF/helper-data plumbing with no reconstructed-key export port.

    ``puf_sample`` is supplied by a selected device's PUF primitive.  The
    simple XOR reconstruction is an interface model, not an error-correcting
    fuzzy extractor.  The key is only usable through fixed-work seal/unseal.
    """

    def __init__(self, width=64):
        self.width = width
        self.puf_sample = Signal(width)
        self.helper_data = Signal(width)
        self.ciphertext_in = Signal(width)
        self.data_in = Signal(width)
        self.start_seal = Signal()
        self.start_unseal = Signal()
        self.zeroize = Signal()
        self.busy = Signal()
        self.done = Signal()
        self.data_out = Signal(width)

    def elaborate(self, platform):
        m = Module()
        key = Signal(self.width)
        pending = Signal(self.width)
        countdown = Signal(3)
        m.d.sync += self.done.eq(0)
        with m.If(self.zeroize):
            m.d.sync += [key.eq(0), pending.eq(0), countdown.eq(0),
                         self.busy.eq(0), self.data_out.eq(0)]
        with m.Elif(~self.busy & (self.start_seal | self.start_unseal)):
            m.d.sync += [
                key.eq(self.puf_sample ^ self.helper_data),
                pending.eq(Mux(self.start_seal, self.data_in,
                               self.ciphertext_in)),
                countdown.eq(4), self.busy.eq(1),
            ]
        with m.Elif(self.busy):
            with m.If(countdown == 1):
                m.d.sync += [self.data_out.eq(pending ^ key), self.done.eq(1),
                             self.busy.eq(0), countdown.eq(0)]
            with m.Else():
                m.d.sync += countdown.eq(countdown - 1)
        return m
