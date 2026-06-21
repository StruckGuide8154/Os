# ============================================================================
# secure_ram.py - Track 10 enclave: custom on-die secure RAM, from scratch.
#
# WHY FROM SCRATCH / WHY INTERNAL: the enclave's whole value is that its secrets
# never sit anywhere an attacker can reach. So this RAM:
#   * is built from fabric storage only (an array of registers -> distributed
#     LUT-RAM / flip-flops on the FPGA). NO external DRAM/SRAM controller, no
#     off-die memory, no soft-CPU-with-external-memory. Nothing leaves the die.
#   * is NOT a generic vendor block-RAM macro with a single shared read port;
#     it is purpose-built with a structural EXPORT FIREWALL: "secret" slots are
#     physically unreachable through the export read port - the multiplexer for
#     those slots is hardwired to 0, so there is no routing path from a secret
#     cell to a device pin. The master key can be USED (internal read port) but
#     can never be READ OUT (export read port), enforced by wiring, not policy.
#
# Two read ports, one write port (single-cycle synchronous write):
#   - port A (internal/privileged): the FSM's working read; sees every slot,
#     including secret ones. Its consumers are all on-die (e.g. the KDF core).
#   - port B (export): the only port whose data can reach an output. Secret
#     slots read as 0 here - the firewall.
#
# This is the same shrink-only / fail-closed doctrine as the rest of the repo,
# expressed in silicon: a secret you cannot route out is a secret you cannot
# leak. leak != elevation.
# ============================================================================

from amaranth import Module, Signal, Array, Elaboratable


class SecureRAM(Elaboratable):
    """Internal register-array RAM with a structural secret-export firewall.

    Parameters
    ----------
    depth : int           number of slots.
    width : int           bits per slot.
    secret_slots : iter   slot indices that may NEVER reach the export port B.
    """

    def __init__(self, depth=4, width=64, secret_slots=(0,)):
        self.depth = depth
        self.width = width
        self.secret = frozenset(secret_slots)

        # one synchronous write port
        self.w_en = Signal()
        self.w_addr = Signal(range(depth))
        self.w_data = Signal(width)
        self.zeroize = Signal()

        # port A: internal/privileged read (sees everything)
        self.ra_addr = Signal(range(depth))
        self.ra_data = Signal(width)

        # port B: export read (secret slots firewalled to 0)
        self.rb_addr = Signal(range(depth))
        self.rb_data = Signal(width)

    def elaborate(self, platform):
        m = Module()

        # The storage itself: fabric registers, nothing external.
        cells = Array(Signal(self.width, name=f"cell{i}") for i in range(self.depth))

        # Single write port, synchronous (write-enable gated).
        with m.If(self.zeroize):
            for cell in cells:
                m.d.sync += cell.eq(0)
        with m.Elif(self.w_en):
            m.d.sync += cells[self.w_addr].eq(self.w_data)

        # Port A: unrestricted internal read.
        m.d.comb += self.ra_data.eq(cells[self.ra_addr])

        # Port B: export firewall. Built as an explicit per-slot mux so the
        # secret slots have NO data path to rb_data - they are wired to 0.
        m.d.comb += self.rb_data.eq(0)
        with m.Switch(self.rb_addr):
            for i in range(self.depth):
                with m.Case(i):
                    if i in self.secret:
                        m.d.comb += self.rb_data.eq(0)        # firewalled
                    else:
                        m.d.comb += self.rb_data.eq(cells[i])

        return m
