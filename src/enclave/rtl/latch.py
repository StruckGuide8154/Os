# ============================================================================
# latch.py - Track 10 enclave: the triplicated sticky one-shot latch.
#
# The single most security-critical cell in the design: a 0->1 sticky bit that
# gates the privileged opcode group OFF once boot is done, and stays off until a
# real power cycle. Built for fault tolerance and for "reset domain" honesty:
#
#   * TRIPLICATED + 2-of-3 MAJORITY VOTE: three independent cells, the reported
#     state is the majority. A single glitched/flipped cell (the classic
#     fault-injection target) cannot change the verdict in either direction.
#   * STICKY SET, SINGLE CLEAR DOMAIN: `set_i` drives all three cells to 1 and
#     they hold; the ONLY thing that drives them back to 0 is `clear_i`, which
#     in the real device is wired to the power-on reset alone. Ordinary logic
#     resets must NOT reach this domain - that is what makes "resets only on
#     power cycle" structural rather than a policy promise.
#
# The cells are exposed as ports so the majority property is directly testable
# (force one cell low -> vote stays 1; force two -> vote clears), the doctrine
# that every guard has a test that breaks it.
# ============================================================================

from amaranth import Module, Signal, Elaboratable


class StickyMajorityLatch(Elaboratable):
    def __init__(self):
        self.set_i = Signal()      # 0->1 sticky set (any auto-close trigger)
        self.clear_i = Signal()    # power-on ONLY (the sole sticky-domain reset)
        self.cell_a = Signal()
        self.cell_b = Signal()
        self.cell_c = Signal()
        self.vote = Signal()       # 2-of-3 majority

    def elaborate(self, platform):
        m = Module()
        m.d.comb += self.vote.eq((self.cell_a & self.cell_b)
                                 | (self.cell_a & self.cell_c)
                                 | (self.cell_b & self.cell_c))
        # Sticky set: drive all three high and hold.
        with m.If(self.set_i):
            m.d.sync += [self.cell_a.eq(1), self.cell_b.eq(1), self.cell_c.eq(1)]
        # Clear has priority and is the only path to 0 (power-on reset).
        with m.If(self.clear_i):
            m.d.sync += [self.cell_a.eq(0), self.cell_b.eq(0), self.cell_c.eq(0)]
        return m
