#!/usr/bin/env python3
# Track-10 enclave GATEWARE evaluation: simulates the synthesizable Amaranth RTL
# (src/enclave/rtl/*) in pure Python and asserts it implements the SAME one-shot
# phase-machine semantics already proven for the software model
# (scripts/test/eval_enclave.py against src/enclave/enclave_phase.ghl).
#
# This is the silicon-side CI guard: the FPGA cannot be modeled in QEMU/TCG, but
# the RTL can be cycle-simulated here, so the gateware's latch / single-use /
# auto-close / export-firewall behavior is verified without the board. Full
# timing-side-channel + tamper validation still needs the HW rig.
#
# Suite mirrors eval_enclave.py plus gateware-specific structural checks:
#   - the SecureRAM export firewall (master key has no wire to the export port);
#   - the RTL derive output matches an independent Python recomputation of the
#     KDF mix (HW/model interop), and is boot-counter bound (no cross-boot replay).

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))

from amaranth.sim import Simulator                              # noqa: E402
from enclave.rtl.secure_ram import SecureRAM                    # noqa: E402
from enclave.rtl import enclave_top as E                        # noqa: E402
from enclave.rtl.crypto_session import FixedLatencyCryptoCore    # noqa: E402
from enclave.rtl.entropy import EntropyHealthMonitor             # noqa: E402
from enclave.rtl.monotonic_counter import MonotonicCounter       # noqa: E402
from enclave.rtl.puf_seal import PUFKeySeal                      # noqa: E402
from enclave.rtl.tamper import FilteredTamperMonitor             # noqa: E402

MASK64 = (1 << 64) - 1
MASTER = 0xA5A5C3C35A5A3C3C   # == enclave_phase.ghl ENC_MASTER_MODEL

FAILURES = []


def check(label, ok, detail=''):
    print('[rtl] %-54s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                  (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def kdf(master, arg, boot_ctr, op=E.OP_DERIVE_KEY):
    """Independent reference for the gateware one-way derive.

    Mirrors EnclaveTop: derive_out = SHA-512(master||in||boot_ctr||tag)[:8],
    big-endian, where tag = "DERV\\0\\0\\0" with cmd_op in the low byte and
    in = arg (XOR UNSEAL_TWEAK for OP_UNSEAL). Preimage resistance is what
    makes the export firewall hold even though the host picks arg and observes
    boot_ctr: master is not recoverable from the released value.
    """
    import hashlib
    unseal = (op == E.OP_UNSEAL)
    in_sel = (arg ^ E.UNSEAL_TWEAK) if unseal else arg
    tag = (E.DERIVE_TAG_HI | (op & 0xFF))
    msg = b''.join(x.to_bytes(8, 'big') for x in (master, in_sel, boot_ctr, tag))
    return int.from_bytes(hashlib.sha512(msg).digest()[:8], 'big')


# --------------------------------------------------------------------------
# Driver helpers over the command port. Each returns after a single clock so
# the registered resp_status reflects the just-issued command.
# --------------------------------------------------------------------------
class Bench:
    def __init__(self, ctx, dut):
        self.ctx, self.dut = ctx, dut

    async def power_on(self):
        self.ctx.set(self.dut.power_on, 1)
        await self.ctx.tick()
        self.ctx.set(self.dut.power_on, 0)
        await self.ctx.tick()
        return self.ctx.get(self.dut.boot_counter)

    async def provision(self, master):
        self.ctx.set(self.dut.prov_we, 1)
        self.ctx.set(self.dut.prov_master, master)
        await self.ctx.tick()
        self.ctx.set(self.dut.prov_we, 0)
        await self.ctx.tick()

    async def cmd(self, op, arg=0):
        self.ctx.set(self.dut.cmd_op, op)
        self.ctx.set(self.dut.cmd_arg, arg)
        self.ctx.set(self.dut.cmd_valid, 1)
        await self.ctx.tick()
        self.ctx.set(self.dut.cmd_valid, 0)
        status = self.ctx.get(self.dut.resp_status)
        await self.ctx.tick()
        return status

    async def boot_complete(self):
        self.ctx.set(self.dut.boot_complete, 1)
        await self.ctx.tick()
        self.ctx.set(self.dut.boot_complete, 0)
        await self.ctx.tick()

    async def tick(self):
        self.ctx.set(self.dut.tick, 1)
        await self.ctx.tick()
        self.ctx.set(self.dut.tick, 0)
        ret = self.ctx.get(self.dut.latched)
        await self.ctx.tick()
        return ret

    def latched(self):
        return self.ctx.get(self.dut.latched)

    def derive_out(self):
        return self.ctx.get(self.dut.derive_out)

    async def await_derive(self, limit=200):
        # The derive is a multi-cycle SHA-512 on a one-in-flight core. Wait for
        # the core to pick the request up (busy), then drain to completion, then
        # return the freshly-landed export value.
        for _ in range(limit):
            if self.ctx.get(self.dut.derive_busy):
                break
            await self.ctx.tick()
        for _ in range(limit):
            if not self.ctx.get(self.dut.derive_busy):
                await self.ctx.tick()      # let the done-cycle RAM write land
                await self.ctx.tick()
                return self.derive_out()
            await self.ctx.tick()
        return None


def run_main_suite():
    dut = E.EnclaveTop()
    sim = Simulator(dut)
    sim.add_clock(1e-6)

    async def tb(ctx):
        b = Bench(ctx, dut)

        # 1. before power-on: nothing answers.
        check('no command before power-on (ENC_PHASE)',
              await b.cmd(E.OP_ATTEST) == E.ENC_PHASE)

        # 2. power-on arms Phase A, bumps the monotonic boot counter.
        await b.provision(MASTER)
        c0 = await b.power_on()
        check('power-on enters Phase A', ctx.get(dut.phase) == 0)
        check('power-on clears the latch', b.latched() == 0)
        c1 = await b.power_on()
        check('boot counter is monotonic across power cycles', c1 == c0 + 1,
              'c0=%d c1=%d' % (c0, c1))

        # 3. privileged ops single-use within Phase A. The hash core is
        #    one-in-flight, so await each derived value before the next op
        #    (the real USB session serializes requests the same way).
        await b.power_on()
        check('derive accepted in Phase A',
              await b.cmd(E.OP_DERIVE_KEY, 0xDEADBEEF) == E.ENC_OK)
        await b.await_derive()
        check('relayed/duplicate derive rejected (ENC_REPLAY)',
              await b.cmd(E.OP_DERIVE_KEY, 0xDEADBEEF) == E.ENC_REPLAY)
        check('independent unseal still available once',
              await b.cmd(E.OP_UNSEAL, 0x1234) == E.ENC_OK)
        await b.await_derive()
        check('duplicate unseal rejected (ENC_REPLAY)',
              await b.cmd(E.OP_UNSEAL, 0x1234) == E.ENC_REPLAY)
        check('used-op bitmap records both consumptions',
              ctx.get(dut.used_mask) == 0b011)

        # 4. derive matches the independent KDF reference + boot-counter bound.
        bc = await b.power_on()
        await b.cmd(E.OP_DERIVE_KEY, 0x1111)
        out_a = await b.await_derive()
        check('RTL derive output matches the independent KDF reference',
              out_a == kdf(MASTER, 0x1111, bc),
              'got=%#x exp=%#x' % (out_a, kdf(MASTER, 0x1111, bc)))
        check('derive output is not the raw master', out_a != MASTER)
        bc2 = await b.power_on()
        await b.cmd(E.OP_DERIVE_KEY, 0x1111)
        out_b = await b.await_derive()
        check('same request on a later boot yields a different output',
              out_a != out_b, 'a=%#x b=%#x' % (out_a, out_b))

        # 5. latch closes on each documented trigger; sticky.
        await b.power_on()
        check('seal_and_lock closes the latch',
              await b.cmd(E.OP_SEAL_LOCK) == E.ENC_OK and b.latched() == 1)
        await b.power_on()
        check('fresh boot back in Phase A', b.latched() == 0)
        check('first Phase-B opcode auto-closes the latch',
              await b.cmd(E.OP_SIGN) == E.ENC_OK and b.latched() == 1)
        await b.power_on()
        await b.boot_complete()
        check('boot_complete closes the latch', b.latched() == 1)
        await b.power_on()
        closed_at = -1
        for i in range(200):
            if await b.tick() == 1:
                closed_at = i
                break
        check('watchdog auto-closes Phase A within budget',
              b.latched() == 1 and 0 <= closed_at <= 64, 'closed_at=%d' % closed_at)

        # 6. post-latch: every privileged op LOCKED; nothing re-arms it.
        await b.power_on()
        await b.boot_complete()
        for op, nm in ((E.OP_DERIVE_KEY, 'derive'), (E.OP_UNSEAL, 'unseal'),
                       (E.OP_SEAL_LOCK, 'seal_lock')):
            check('post-latch %s -> ENC_LOCKED' % nm,
                  await b.cmd(op) == E.ENC_LOCKED)
        rearmed = False
        for s in range(30):
            await b.cmd(E.OP_SIGN, s)
            await b.cmd(E.OP_ATTEST, s)
            await b.boot_complete()
            await b.tick()
            if b.latched() == 0:
                rearmed = True
                break
        check('no host sequence re-arms the latch without power-on', not rearmed)

        # 7. attest reports real latch + counter.
        bc = await b.power_on()
        check('attest reports Phase-A latch=0', ctx.get(dut.attest_latch) == 0)
        check('attest reports the live boot counter',
              ctx.get(dut.attest_counter) == bc)
        await b.boot_complete()
        check('attest reports latch=1 after lockdown',
              ctx.get(dut.attest_latch) == 1)

        # 8. hard rejects.
        await b.power_on()
        check('unknown opcode rejected (ENC_BADOP)',
              await b.cmd(0x99) == E.ENC_BADOP)
        check('inter-group gap rejected (ENC_BADOP)',
              await b.cmd(0x1F) == E.ENC_BADOP)

    sim.add_testbench(tb)
    sim.run()


def run_glitch_suite():
    """A single flipped latch cell must not re-open the window; two does.
    Tests StickyMajorityLatch directly so the three cells can be forced."""
    from enclave.rtl.latch import StickyMajorityLatch
    lat = StickyMajorityLatch()
    sim = Simulator(lat)
    sim.add_clock(1e-6)

    async def tb(ctx):
        # set the latch (a close trigger), then clear the strobe.
        ctx.set(lat.set_i, 1)
        await ctx.tick()
        ctx.set(lat.set_i, 0)
        await ctx.tick()
        check('latch reports closed after a set', ctx.get(lat.vote) == 1)
        # Glitch ONE cell low (comb read, no tick -> design can't overwrite).
        ctx.set(lat.cell_a, 0)
        check('vote survives a single flipped cell (2-of-3 majority)',
              ctx.get(lat.vote) == 1)
        # Glitch a SECOND cell low -> majority lost (honest about 2-fault).
        ctx.set(lat.cell_b, 0)
        check('vote clears only when two cells are flipped', ctx.get(lat.vote) == 0)
        # Only clear_i (power-on) drives the cells back to 0 through logic.
        ctx.set(lat.cell_a, 1)
        ctx.set(lat.cell_b, 1)
        ctx.set(lat.clear_i, 1)
        await ctx.tick()
        ctx.set(lat.clear_i, 0)
        await ctx.tick()
        check('clear_i (power-on) is the path back to 0', ctx.get(lat.vote) == 0)

    sim.add_testbench(tb)
    sim.run()


def run_firewall_suite():
    """SecureRAM structural export firewall: a secret slot can be written and
    read INTERNALLY (port A) but reads as 0 on the EXPORT port (port B)."""
    ram = SecureRAM(depth=4, width=64, secret_slots=(0,))
    sim = Simulator(ram)
    sim.add_clock(1e-6)

    async def tb(ctx):
        SECRET = 0xCAFEF00DD00DFEED
        ctx.set(ram.w_en, 1)
        ctx.set(ram.w_addr, 0)         # secret slot
        ctx.set(ram.w_data, SECRET)
        await ctx.tick()
        ctx.set(ram.w_en, 0)
        # also write a non-secret slot
        ctx.set(ram.w_en, 1)
        ctx.set(ram.w_addr, 1)
        ctx.set(ram.w_data, 0x1234)
        await ctx.tick()
        ctx.set(ram.w_en, 0)
        await ctx.tick()

        ctx.set(ram.ra_addr, 0)
        ctx.set(ram.rb_addr, 0)
        await ctx.tick()
        check('secret slot READABLE on the internal port A',
              ctx.get(ram.ra_data) == SECRET)
        check('secret slot FIREWALLED to 0 on the export port B',
              ctx.get(ram.rb_data) == 0)
        ctx.set(ram.rb_addr, 1)
        await ctx.tick()
        check('non-secret slot passes through the export port B',
              ctx.get(ram.rb_data) == 0x1234)
        ctx.set(ram.zeroize, 1)
        await ctx.tick()
        ctx.set(ram.zeroize, 0)
        ctx.set(ram.ra_addr, 0)
        ctx.set(ram.rb_addr, 1)
        await ctx.tick()
        check('zeroize clears secret and exportable RAM slots',
              ctx.get(ram.ra_data) == 0 and ctx.get(ram.rb_data) == 0)

    sim.add_testbench(tb)
    sim.run()


def run_counter_suite():
    counter = MonotonicCounter(width=16)
    sim = Simulator(counter)
    sim.add_clock(1e-6)

    async def tb(ctx):
        for _ in range(3):
            ctx.set(counter.increment, 1)
            await ctx.tick()
            ctx.set(counter.increment, 0)
            await ctx.tick()
        check('redundant monotonic counter increments only upward',
              ctx.get(counter.value) == 3)
        ctx.set(counter.inverse, 0)  # injected corruption of one replica
        await ctx.tick()
        check('counter complement mismatch raises sticky integrity fault',
              ctx.get(counter.integrity_fault) == 1)
        before = ctx.get(counter.value)
        ctx.set(counter.increment, 1)
        await ctx.tick()
        check('counter freezes rather than advancing after corruption',
              ctx.get(counter.value) == before)

        # A separate small instance below checks that exhaustion fails closed
        # rather than wrapping an anti-rollback floor to zero.

    sim.add_testbench(tb)
    sim.run()

    tiny = MonotonicCounter(width=2)
    sim = Simulator(tiny)
    sim.add_clock(1e-6)

    async def overflow_tb(ctx):
        for _ in range(3):
            ctx.set(tiny.increment, 1)
            await ctx.tick()
            ctx.set(tiny.increment, 0)
            await ctx.tick()
        ctx.set(tiny.increment, 1)
        await ctx.tick()
        check('counter exhaustion fails closed without wrapping',
              ctx.get(tiny.value) == 3 and ctx.get(tiny.integrity_fault) == 1)

    sim.add_testbench(overflow_tb)
    sim.run()


def run_tamper_suite():
    tamper = FilteredTamperMonitor(filter_cycles=4)
    sim = Simulator(tamper)
    sim.add_clock(1e-6)

    async def tb(ctx):
        ctx.set(tamper.power_on, 1)
        await ctx.tick()
        ctx.set(tamper.power_on, 0)
        ctx.set(tamper.sensor_a, 1)
        await ctx.tick()
        check('single tamper sensor cannot trigger response',
              ctx.get(tamper.tamper) == 0)
        ctx.set(tamper.sensor_b, 1)
        await ctx.tick()
        ctx.set(tamper.sensor_b, 0)
        await ctx.tick()
        check('one-cycle voted tamper pulse is filtered',
              ctx.get(tamper.tamper) == 0)
        ctx.set(tamper.sensor_b, 1)
        for _ in range(4):
            await ctx.tick()
        check('sustained 2-of-3 tamper vote becomes sticky',
              ctx.get(tamper.tamper) == 1 and ctx.get(tamper.zeroize) == 1)
        ctx.set(tamper.sensor_a, 0)
        ctx.set(tamper.sensor_b, 0)
        for _ in range(8):
            await ctx.tick()
        check('tamper response cannot self-clear after sensors recover',
              ctx.get(tamper.tamper) == 1)

    sim.add_testbench(tb)
    sim.run()


def run_entropy_suite():
    ent = EntropyHealthMonitor(rct_limit=8, apt_window=16,
                               apt_min=4, apt_max=12)
    sim = Simulator(ent)
    sim.add_clock(1e-6)

    async def reset_ok(ctx):
        ctx.set(ent.env_voltage_ok, 1)
        ctx.set(ent.env_temp_ok, 1)
        ctx.set(ent.env_clock_ok, 1)
        ctx.set(ent.power_on, 1)
        await ctx.tick()
        ctx.set(ent.power_on, 0)

    async def bit(ctx, value):
        ctx.set(ent.raw_bit, value)
        ctx.set(ent.raw_valid, 1)
        await ctx.tick()
        ctx.set(ent.raw_valid, 0)

    async def tb(ctx):
        await reset_ok(ctx)
        for i in range(32):
            await bit(ctx, i & 1)
        check('balanced entropy stream passes RCT/APT tests',
              ctx.get(ent.health_fault) == 0)
        for _ in range(8):
            await bit(ctx, 1)
        check('stuck entropy source trips repetition-count test',
              ctx.get(ent.health_fault) == 1)
        await reset_ok(ctx)
        ctx.set(ent.env_clock_ok, 0)
        await ctx.tick()
        check('out-of-range clock monitor fail-stops entropy',
              ctx.get(ent.env_fault) == 1)

        for signal, label in ((ent.env_voltage_ok, 'voltage'),
                              (ent.env_temp_ok, 'temperature')):
            await reset_ok(ctx)
            ctx.set(signal, 0)
            await ctx.tick()
            check('out-of-range %s monitor fail-stops entropy' % label,
                  ctx.get(ent.env_fault) == 1)
            for i in range(70):
                await bit(ctx, i & 1)
            check('%s fault suppresses random_valid output' % label,
                  ctx.get(ent.random_valid) == 0)

        await reset_ok(ctx)
        for i in range(16):
            await bit(ctx, 1 if i in (4, 9, 14) else 0)
        check('low-tail adaptive-proportion failure is detected',
              ctx.get(ent.health_fault) == 1)
        await reset_ok(ctx)
        for i in range(16):
            await bit(ctx, 0 if i in (4, 9, 14) else 1)
        check('high-tail adaptive-proportion failure is detected',
              ctx.get(ent.health_fault) == 1)

    sim.add_testbench(tb)
    sim.run()


def run_puf_suite():
    puf = PUFKeySeal(width=64)
    sim = Simulator(puf)
    sim.add_clock(1e-6)

    async def operate(ctx, seal, value):
        if seal:
            ctx.set(puf.data_in, value)
            ctx.set(puf.start_seal, 1)
        else:
            ctx.set(puf.ciphertext_in, value)
            ctx.set(puf.start_unseal, 1)
        await ctx.tick()
        ctx.set(puf.start_seal, 0)
        ctx.set(puf.start_unseal, 0)
        cycles = 0
        while not ctx.get(puf.done) and cycles < 10:
            await ctx.tick()
            cycles += 1
        return ctx.get(puf.data_out), cycles

    async def tb(ctx):
        ctx.set(puf.puf_sample, 0x13579BDF2468ACE0)
        ctx.set(puf.helper_data, 0x0102030405060708)
        plain = 0xDEADBEEFCAFEBABE
        sealed, seal_cycles = await operate(ctx, True, plain)
        opened, open_cycles = await operate(ctx, False, sealed)
        check('PUF helper-data model seals and unseals without key port',
              opened == plain)
        check('PUF seal/unseal operations have equal fixed latency',
              seal_cycles == open_cycles == 4,
              'seal=%d open=%d' % (seal_cycles, open_cycles))
        ctx.set(puf.puf_sample, 0xFFFFFFFFFFFFFFFF)
        wrong, wrong_cycles = await operate(ctx, False, sealed)
        check('different PUF sample cannot reproduce sealed plaintext',
              wrong != plain)
        check('wrong-device unseal retains fixed latency', wrong_cycles == 4)
        ctx.set(puf.zeroize, 1)
        await ctx.tick()
        check('PUF datapath zeroize clears released material',
              ctx.get(puf.data_out) == 0)

    sim.add_testbench(tb)
    sim.run()


def run_crypto_cycle_gate():
    core = FixedLatencyCryptoCore()
    sim = Simulator(core)
    sim.add_clock(1e-6)

    async def request(ctx, op, key, msg, inject_start=False):
        ctx.set(core.op, op)
        ctx.set(core.key, key)
        ctx.set(core.message, msg)
        ctx.set(core.start, 1)
        await ctx.tick()
        ctx.set(core.start, 0)
        trace = []
        while not ctx.get(core.done) and len(trace) <= core.LATENCY + 2:
            cycles = len(trace)
            if inject_start and cycles == 7:
                ctx.set(core.start, 1)
                ctx.set(core.key, key ^ 1)
            elif inject_start and cycles == 8:
                ctx.set(core.start, 0)
            await ctx.tick()
            trace.append((ctx.get(core.busy), ctx.get(core.done)))
        return trace, ctx.get(core.result)

    async def tb(ctx):
        traces = []
        results = []
        vectors = ((0, 0), (1, 0), ((1 << 256) - 1, 7),
                   (0x1234, (1 << 255) | 1),
                   (0xAAAAAAAAAAAAAAAA, 0x5555555555555555))
        for op in range(4):
            for key, msg in vectors:
                trace, result = await request(ctx, op, key, msg)
                traces.append(trace)
                results.append(result)
                await ctx.tick()
        check('crypto busy/done trace is identical across ops and secrets',
              all(trace == traces[0] for trace in traces), str(traces))
        check('crypto completion occurs at the exact fixed cycle',
              len(traces[0]) == core.LATENCY
              and traces[0][-1] == (0, 1)
              and all(item == (1, 0) for item in traces[0][:-1]))
        check('crypto datapath still depends on supplied inputs',
              len(set(results)) > 4)

        baseline_trace, baseline_result = await request(ctx, 2, 0x1234, 0x5678)
        await ctx.tick()
        retry_trace, retry_result = await request(ctx, 2, 0x1234, 0x5678,
                                                  inject_start=True)
        check('in-flight start cannot alter crypto timing trace',
              retry_trace == baseline_trace)
        check('in-flight start cannot replace accepted crypto request',
              retry_result == baseline_result)

    sim.add_testbench(tb)
    sim.run()


def run_integrated_tamper_suite():
    dut = E.EnclaveTop()
    sim = Simulator(dut)
    sim.add_clock(1e-6)

    async def tb(ctx):
        b = Bench(ctx, dut)
        await b.provision(MASTER)
        await b.power_on()
        await b.cmd(E.OP_DERIVE_KEY, 0x55AA)
        check('pre-tamper released slot contains derived material',
              await b.await_derive() != 0)
        ctx.set(dut.tamper_a, 1)
        ctx.set(dut.tamper_b, 1)
        for _ in range(6):
            await ctx.tick()
        check('filtered tamper closes integrated privilege latch',
              ctx.get(dut.tamper_latched) == 1 and b.latched() == 1)
        check('tamper zeroizes exported secure-RAM material',
              b.derive_out() == 0)

    sim.add_testbench(tb)
    sim.run()


def run_derive_noninvertible_suite():
    """Regression for the master-key extraction break: a derive used to return
    out = (master ^ arg) ^ (boot_ctr*GOLDEN), out ^= out>>29 - an algebraic
    BIJECTION in master with arg attacker-chosen and boot_ctr a public output,
    so master fell out of ONE derive. This drives that exact attack against the
    live gateware and asserts the inversion no longer recovers the master."""
    MASK64 = (1 << 64) - 1

    def unfold(y):                       # invert y = x ^ (x>>29)
        x = y
        x = y ^ (x >> 29)
        x = y ^ (x >> 29)
        return x & MASK64

    dut = E.EnclaveTop()
    sim = Simulator(dut)
    sim.add_clock(1e-6)

    async def tb(ctx):
        b = Bench(ctx, dut)
        await b.provision(MASTER)
        boot = await b.power_on()
        # The old attack: arg=0 so the released value was master ^ prod, folded.
        await b.cmd(E.OP_DERIVE_KEY, 0)
        out = await b.await_derive()
        prod = (boot * E.GOLDEN) & MASK64
        recovered_legacy = (unfold(out) ^ 0 ^ prod) & MASK64
        check('legacy XOR-mix inversion no longer recovers the master',
              recovered_legacy != MASTER,
              'recovered=%#x master=%#x' % (recovered_legacy, MASTER))
        # And the released value really is the one-way SHA reference (so the
        # firewall protects a preimage, not an invertible transform).
        check('derive output is the one-way SHA-512 reference',
              out == kdf(MASTER, 0, boot))
        check('released derive value is not the raw master', out != MASTER)

    sim.add_testbench(tb)
    sim.run()


def main():
    run_firewall_suite()
    run_derive_noninvertible_suite()
    run_counter_suite()
    run_tamper_suite()
    run_entropy_suite()
    run_puf_suite()
    run_crypto_cycle_gate()
    run_main_suite()
    run_integrated_tamper_suite()
    run_glitch_suite()

    if FAILURES:
        sys.stderr.write('[rtl] FAIL - %d problem(s):\n' % len(FAILURES))
        for f in FAILURES:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[rtl] enclave gateware cycle/build gates passed; physical TRNG, PUF, '
          'secure-NV persistence, real crypto, and sensor thresholds remain '
          'device/lab validation items')
    return 0


if __name__ == '__main__':
    sys.exit(main())
