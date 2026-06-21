from amaranth import Elaboratable, Module, Signal


class FilteredTamperMonitor(Elaboratable):
    """Three-sensor vote followed by a consecutive-cycle debounce filter."""

    def __init__(self, filter_cycles=4):
        if filter_cycles < 2:
            raise ValueError("filter_cycles must be at least two")
        self.filter_cycles = filter_cycles
        self.sensor_a = Signal()
        self.sensor_b = Signal()
        self.sensor_c = Signal()
        self.power_on = Signal()
        self.tamper = Signal()
        self.zeroize = Signal()
        self.suspect = Signal()

    def elaborate(self, platform):
        m = Module()
        voted = Signal()
        count = Signal(range(self.filter_cycles + 1))
        m.d.comb += [
            voted.eq((self.sensor_a & self.sensor_b)
                     | (self.sensor_a & self.sensor_c)
                     | (self.sensor_b & self.sensor_c)),
            self.suspect.eq(voted),
            self.zeroize.eq(self.tamper),
        ]
        with m.If(self.power_on):
            m.d.sync += [count.eq(0), self.tamper.eq(0)]
        with m.Elif(~self.tamper):
            with m.If(voted):
                with m.If(count == self.filter_cycles - 1):
                    m.d.sync += [self.tamper.eq(1), count.eq(self.filter_cycles)]
                with m.Else():
                    m.d.sync += count.eq(count + 1)
            with m.Else():
                m.d.sync += count.eq(0)
        return m
