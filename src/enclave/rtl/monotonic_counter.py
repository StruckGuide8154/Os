from amaranth import Elaboratable, Module, Signal


class MonotonicCounter(Elaboratable):
    """Redundant monotonic counter front-end for a secure-NV primitive.

    ``value`` and its complement are kept independently.  A disagreement is
    sticky and prevents further increments.  The registers model the logic
    surrounding a vendor eFuse/secure-NV macro; persistence across loss of
    board power still depends on that selected macro.
    """

    def __init__(self, width=64):
        self.width = width
        self.increment = Signal()
        self.clear_fault = Signal()
        self.value = Signal(width)
        self.integrity_fault = Signal()

        # Exposed for fault-injection simulation and physical constraints.
        self.primary = Signal(width)
        self.inverse = Signal(width, reset=(1 << width) - 1)

    def elaborate(self, platform):
        m = Module()
        mismatch = Signal()
        at_max = Signal()
        m.d.comb += [
            mismatch.eq(self.primary != ~self.inverse),
            at_max.eq(self.primary.all()),
            self.value.eq(self.primary),
        ]

        with m.If(self.clear_fault):
            m.d.sync += self.integrity_fault.eq(0)
        with m.Elif(mismatch | (self.increment & at_max)):
            m.d.sync += self.integrity_fault.eq(1)

        with m.If(self.increment & ~at_max & ~mismatch & ~self.integrity_fault):
            m.d.sync += [
                self.primary.eq(self.primary + 1),
                self.inverse.eq(~(self.primary + 1)),
            ]
        return m
