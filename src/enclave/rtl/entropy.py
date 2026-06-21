from amaranth import Elaboratable, Module, Signal


class EntropyHealthMonitor(Elaboratable):
    """Online RCT/APT health tests and environmental fail-stop gating.

    Raw entropy must come from a device-specific RO/metastability primitive.
    This module implements the synthesizable health-test/control boundary.
    """

    def __init__(self, rct_limit=16, apt_window=32, apt_min=8, apt_max=24):
        self.rct_limit = rct_limit
        self.apt_window = apt_window
        self.apt_min = apt_min
        self.apt_max = apt_max
        self.raw_bit = Signal()
        self.raw_valid = Signal()
        self.env_voltage_ok = Signal()
        self.env_temp_ok = Signal()
        self.env_clock_ok = Signal()
        self.power_on = Signal()
        self.random_word = Signal(64)
        self.random_valid = Signal()
        self.health_fault = Signal()
        self.env_fault = Signal()

    def elaborate(self, platform):
        m = Module()
        last = Signal()
        have_last = Signal()
        run = Signal(range(self.rct_limit + 1))
        apt_count = Signal(range(self.apt_window + 1))
        apt_ones = Signal(range(self.apt_window + 1))
        collect = Signal(7)
        state = Signal(64, reset=0xD1B54A32D192ED03)
        env_bad = Signal()
        m.d.comb += env_bad.eq(~(self.env_voltage_ok & self.env_temp_ok
                                & self.env_clock_ok))
        m.d.sync += self.random_valid.eq(0)
        with m.If(self.power_on):
            m.d.sync += [
                have_last.eq(0), run.eq(0), apt_count.eq(0), apt_ones.eq(0),
                collect.eq(0), self.health_fault.eq(0), self.env_fault.eq(0),
            ]
        with m.Else():
            with m.If(env_bad):
                m.d.sync += self.env_fault.eq(1)
            with m.If(self.raw_valid & ~self.health_fault & ~self.env_fault & ~env_bad):
                # Repetition-count test.
                with m.If(have_last & (self.raw_bit == last)):
                    with m.If(run == self.rct_limit - 1):
                        m.d.sync += self.health_fault.eq(1)
                    with m.Else():
                        m.d.sync += run.eq(run + 1)
                with m.Else():
                    m.d.sync += [last.eq(self.raw_bit), have_last.eq(1), run.eq(1)]

                # Adaptive-proportion test over non-overlapping windows.
                with m.If(apt_count == self.apt_window - 1):
                    window_ones = Signal(range(self.apt_window + 2))
                    m.d.comb += window_ones.eq(apt_ones + self.raw_bit)
                    with m.If((window_ones < self.apt_min)
                              | (window_ones > self.apt_max)):
                        m.d.sync += self.health_fault.eq(1)
                    m.d.sync += [apt_count.eq(0), apt_ones.eq(0)]
                with m.Else():
                    m.d.sync += [apt_count.eq(apt_count + 1),
                                 apt_ones.eq(apt_ones + self.raw_bit)]

                # Fixed-work conditioner/DRBG-shaped state update. This is not
                # a substitute for a reviewed cryptographic DRBG primitive.
                feedback = Signal()
                m.d.comb += feedback.eq(state[63] ^ state[62] ^ state[60]
                                        ^ state[59] ^ self.raw_bit)
                m.d.sync += state.eq((state << 1) | feedback)
                with m.If(collect == 63):
                    m.d.sync += [self.random_word.eq(state),
                                 self.random_valid.eq(1), collect.eq(0)]
                with m.Else():
                    m.d.sync += collect.eq(collect + 1)
        return m
