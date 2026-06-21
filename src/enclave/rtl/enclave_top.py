# ============================================================================
# enclave_top.py - Track 10 USB-FPGA secure-enclave: the one-shot phase machine
# in synthesizable gateware (Amaranth HDL).
#
# This is the SILICON of the state machine proven in src/enclave/enclave_phase.ghl
# (the software model) and validated in scripts/test/eval_enclave.py. Same
# opcodes, same status codes, same semantics - now as hardware that uses ONLY
# on-die resources:
#   * triplicated sticky latch with 2-of-3 majority vote (glitch tolerance),
#     cleared by NOTHING except the power-on strobe (the only reset of the
#     sticky domain - models "resets only on power cycle");
#   * single-use-per-op privileged window (a bitmap in fabric registers);
#   * four auto-close triggers: seal_and_lock / boot_complete / first Phase-B
#     opcode / watchdog timeout;
#   * a structural export firewall on the master key via SecureRAM (the master
#     can be USED to derive but has no wire to any output pin).
#
# Interface (a simple single-cycle command port; the host driver / monitor
# wraps this in the authenticated USB session - that AEAD layer is separate):
#   inputs : power_on, cmd_valid, cmd_op[8], cmd_arg[64], tick, boot_complete,
#            prov_we, prov_master[64]   (prov_* = one-time provisioning write)
#   outputs: resp_valid, resp_status[3], derive_out[64], latched, phase,
#            boot_counter[64], used_mask[8], attest_latch, attest_counter[64]
#
# NO external memory, NO soft-CPU, NO secret-dependent control flow that could
# leak via timing (the response latency is a fixed one cycle for every command).
# ============================================================================

from amaranth import Module, Signal, Elaboratable, Cat, Const

from .secure_ram import SecureRAM
from .latch import StickyMajorityLatch
from .monotonic_counter import MonotonicCounter
from .tamper import FilteredTamperMonitor
from .sha512 import SHA512Block, IV

# ---- opcode space (== enclave_phase.ghl) -----------------------------------
OP_DERIVE_KEY = 0x10
OP_UNSEAL     = 0x11
OP_SEAL_LOCK  = 0x12
OP_PRIV_LO    = 0x10
OP_PRIV_HI    = 0x18   # exclusive
OP_SIGN         = 0x20
OP_RNG          = 0x21
OP_COUNTER_READ = 0x22
OP_ATTEST       = 0x23
OP_PB_LO        = 0x20
OP_PB_HI        = 0x28   # exclusive

# ---- status codes (== enclave_phase.ghl) -----------------------------------
ENC_OK     = 0
ENC_LOCKED = 1
ENC_REPLAY = 2
ENC_BADOP  = 3
ENC_PHASE  = 4

WATCHDOG_TICKS = 64
GOLDEN = 0x9E3779B97F4A7C15      # legacy mix constant (no longer on the derive path)
UNSEAL_TWEAK = 0x5555555555555555

# Derive is now a ONE-WAY function of the master: the export port returns
# SHA-512(master || in || boot_ctr || tag)[:64] rather than an algebraically
# invertible XOR-mix. With arg attacker-chosen and boot_ctr a public output, an
# invertible map would let the host solve for `master` from one derive (a full
# break of the export firewall); a preimage-resistant hash does not. The 56-bit
# ASCII domain tag "DERV" separates the derive oracle from any other hash use.
DERIVE_TAG_HI = 0x44455256000000   # "DERV\0\0\0", low byte carries cmd_op
SHA_IV512 = sum(w << (64 * (7 - i)) for i, w in enumerate(IV))  # word0 in MSBs
MSG_BITLEN = 256                   # message = master|in|boot|tag = 4 x 64 bits

# RAM slot map (secret slot 0 is firewalled from the export port).
SLOT_MASTER = 0     # PUF/provisioned master; never exported
SLOT_DERIVE = 1     # last derive/unseal output; the export read port


class EnclaveTop(Elaboratable):
    def __init__(self):
        # control inputs
        self.power_on = Signal()       # strobe: the ONLY sticky-domain reset
        self.cmd_valid = Signal()
        self.cmd_op = Signal(8)
        self.cmd_arg = Signal(64)
        self.tick = Signal()           # watchdog strobe
        self.boot_complete = Signal()  # verifier->monitor handoff strobe
        self.prov_we = Signal()        # one-time master provisioning
        self.prov_master = Signal(64)
        self.tamper_a = Signal()
        self.tamper_b = Signal()
        self.tamper_c = Signal()

        # outputs
        self.resp_valid = Signal()
        self.resp_status = Signal(3)
        self.derive_out = Signal(64)
        self.latched = Signal()
        self.phase = Signal()          # 0 = Phase A, 1 = Phase B
        self.boot_counter = Signal(64)
        self.used_mask = Signal(8)
        self.attest_latch = Signal()
        self.attest_counter = Signal(64)
        self.tamper_latched = Signal()
        self.counter_fault = Signal()
        self.derive_ready = Signal()   # 1 once this boot's derive value has landed
        self.derive_busy = Signal()    # hash core in flight (one derive at a time)

    def elaborate(self, platform):
        m = Module()
        m.submodules.ram = ram = SecureRAM(depth=4, width=64,
                                           secret_slots=(SLOT_MASTER,))
        m.submodules.latch = latch = StickyMajorityLatch()
        m.submodules.counter = counter = MonotonicCounter(width=64)
        m.submodules.tamper = tamper = FilteredTamperMonitor(filter_cycles=4)
        m.submodules.kdf = kdf = SHA512Block()

        # ---- sticky session state (cleared ONLY by power_on) ----------------
        armed = Signal()
        used = Signal(8)
        wdog = Signal(range(WATCHDOG_TICKS + 1))
        powered = Signal()
        boot_ctr = counter.value
        m.d.comb += [
            counter.increment.eq(self.power_on),
            tamper.sensor_a.eq(self.tamper_a),
            tamper.sensor_b.eq(self.tamper_b),
            tamper.sensor_c.eq(self.tamper_c),
            tamper.power_on.eq(self.power_on),
            ram.zeroize.eq(tamper.zeroize),
            self.tamper_latched.eq(tamper.tamper),
            self.counter_fault.eq(counter.integrity_fault),
        ]

        # ---- combinational decode -------------------------------------------
        is_priv = Signal()
        is_pb = Signal()
        bit = Signal(8)
        already_used = Signal()
        latched = latch.vote            # 2-of-3 majority of the sticky cells

        m.d.comb += [
            is_priv.eq((self.cmd_op >= OP_PRIV_LO) & (self.cmd_op < OP_PRIV_HI)),
            is_pb.eq((self.cmd_op >= OP_PB_LO) & (self.cmd_op < OP_PB_HI)),
            bit.eq(1 << self.cmd_op[:3]),          # op in 0x10..0x17 -> bit0..7
            already_used.eq((used & bit).any()),
        ]
        m.d.comb += [
            self.latched.eq(latched),
            self.phase.eq(latched),
            self.boot_counter.eq(boot_ctr),
            self.used_mask.eq(used),
            self.attest_latch.eq(latched),
            self.attest_counter.eq(boot_ctr),
        ]

        # ---- a privileged op is fireable iff fully admitted -----------------
        # The hash core is multi-cycle and single-instance; a derive/unseal that
        # arrives while a prior one is still in flight is NOT admitted (it would
        # otherwise burn its single-use bit without ever launching the hash - a
        # silent drop / DoS). It returns ENC_REPLAY so the host (one-in-flight
        # USB session) simply retries after the response.
        priv_ok = Signal()
        is_derive_op = Signal()
        derive_fire = Signal()
        m.d.comb += [
            is_derive_op.eq((self.cmd_op == OP_DERIVE_KEY)
                            | (self.cmd_op == OP_UNSEAL)),
            priv_ok.eq(self.cmd_valid & powered & is_priv
                       & ~latched & armed & ~already_used),
            derive_fire.eq(priv_ok & is_derive_op & ~kdf.busy),
        ]

        # ---- KDF: a ONE-WAY SHA-512 over master||in||boot_ctr||tag ----------
        # The export firewall keeps `master` off every output pin, but a derive
        # that returned an *invertible* function of the master would be just as
        # good as a read: arg is attacker-chosen and boot_ctr is a public
        # output, so any bijection in master is solvable in one call. Hashing
        # makes the released value preimage-resistant, so the master is not
        # recoverable from derive_out. master comes from RAM port A (internal
        # read of the secret slot); it is never an input to any exportable mux.
        m.d.comb += ram.ra_addr.eq(SLOT_MASTER)
        master = ram.ra_data
        in_sel = Signal(64)
        with m.If(self.cmd_op == OP_UNSEAL):
            m.d.comb += in_sel.eq(self.cmd_arg ^ UNSEAL_TWEAK)
        with m.Else():
            m.d.comb += in_sel.eq(self.cmd_arg)

        # Assemble the padded single 1024-bit block (FIPS 180-4, word0 in MSBs):
        #   w0=master w1=in w2=boot_ctr w3=tag, then the 0x80 pad bit, zeros,
        #   and the 128-bit message length (256 bits).
        tag_word = Cat(self.cmd_op, Const(DERIVE_TAG_HI >> 8, 56))
        words = [master, in_sel, boot_ctr, tag_word,
                 Const(0x8000000000000000, 64)]
        words += [Const(0, 64)] * 10
        words += [Const(MSG_BITLEN, 64)]
        m.d.comb += [
            kdf.h_in.eq(Const(SHA_IV512, 512)),
            kdf.block.eq(Cat(*reversed(words))),
            # Launch on the cycle the derive op is admitted; inputs are stable
            # combinationally that cycle and SHA512Block latches them on start.
            kdf.start.eq(derive_fire & ~kdf.busy),
            self.derive_busy.eq(kdf.busy),
        ]
        derived_word = kdf.h_out[448:512]   # first SHA-512 output word (== digest[:8])

        # derive_out is the EXPORT read port (slot DERIVE); master is firewalled.
        m.d.comb += ram.rb_addr.eq(SLOT_DERIVE)
        m.d.comb += self.derive_out.eq(ram.rb_data)

        # ---- RAM write port arbitration (priority: power_on > prov > derive)-
        # The derived value lands when the SHA core finishes (multi-cycle),
        # NOT on the admit cycle; single-use + replay state below are stamped
        # immediately, so this delayed write cannot be re-triggered.
        with m.If(self.power_on):
            m.d.comb += [ram.w_en.eq(1), ram.w_addr.eq(SLOT_DERIVE),
                         ram.w_data.eq(0)]               # zero released key
        with m.Elif(self.prov_we):
            m.d.comb += [ram.w_en.eq(1), ram.w_addr.eq(SLOT_MASTER),
                         ram.w_data.eq(self.prov_master)]
        with m.Elif(kdf.done):
            m.d.comb += [ram.w_en.eq(1), ram.w_addr.eq(SLOT_DERIVE),
                         ram.w_data.eq(derived_word)]

        # derive_ready: sticky valid for this boot once the hash has landed.
        with m.If(self.power_on):
            m.d.sync += self.derive_ready.eq(0)
        with m.Elif(kdf.done):
            m.d.sync += self.derive_ready.eq(1)

        # ---- the four auto-close triggers, ORed into one set strobe ---------
        seal_lock_close = Signal()
        pb_close = Signal()
        bc_close = Signal()
        wd_close = Signal()
        do_close = Signal()
        m.d.comb += [
            seal_lock_close.eq(priv_ok & (self.cmd_op == OP_SEAL_LOCK)),
            pb_close.eq(self.cmd_valid & powered & is_pb & armed),
            bc_close.eq(self.boot_complete & powered),
            wd_close.eq(self.tick & powered & ~latched & (wdog <= 1)),
            do_close.eq(seal_lock_close | pb_close | bc_close | wd_close
                        | tamper.tamper | counter.integrity_fault),
        ]
        # Drive the sticky latch: set on any trigger, clear on power-on only.
        m.d.comb += [latch.set_i.eq(do_close), latch.clear_i.eq(self.power_on)]
        with m.If(do_close):
            m.d.sync += armed.eq(0)

        # ---- command processing (registered, fixed 1-cycle latency) ---------
        m.d.sync += self.resp_valid.eq(0)
        with m.If(self.cmd_valid):
            m.d.sync += self.resp_valid.eq(1)
            with m.If(~powered):
                m.d.sync += self.resp_status.eq(ENC_PHASE)
            with m.Elif(is_priv):
                with m.If(latched | ~armed):
                    m.d.sync += self.resp_status.eq(ENC_LOCKED)
                with m.Elif(already_used):
                    m.d.sync += self.resp_status.eq(ENC_REPLAY)
                with m.Elif(is_derive_op & kdf.busy):
                    # hash core in flight; retry (no single-use stamp burned)
                    m.d.sync += self.resp_status.eq(ENC_REPLAY)
                with m.Else():
                    m.d.sync += used.eq(used | bit)        # single-use stamp
                    with m.If(self.cmd_op == OP_SEAL_LOCK):
                        m.d.sync += self.resp_status.eq(ENC_OK)  # latch: do_close
                    with m.Elif((self.cmd_op == OP_DERIVE_KEY)
                                | (self.cmd_op == OP_UNSEAL)):
                        m.d.sync += self.resp_status.eq(ENC_OK)  # RAM write: comb
                    with m.Else():
                        m.d.sync += self.resp_status.eq(ENC_BADOP)
            with m.Elif(is_pb):
                m.d.sync += self.resp_status.eq(ENC_OK)   # auto-close: do_close
            with m.Else():
                m.d.sync += self.resp_status.eq(ENC_BADOP)

        # ---- watchdog countdown (the close itself is wd_close above) --------
        with m.If(self.tick & powered & ~latched & (wdog > 1)):
            m.d.sync += wdog.eq(wdog - 1)

        # ---- power-on: the ONLY clear of the sticky domain (priority last) --
        with m.If(self.power_on):
            m.d.sync += [
                armed.eq(1), used.eq(0), wdog.eq(WATCHDOG_TICKS),
                powered.eq(1),
            ]

        return m
