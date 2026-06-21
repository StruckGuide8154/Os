#!/usr/bin/env python3
# Track-10 enclave phase-machine evaluation: executes the REAL gateware MODEL
# source (src/enclave/enclave_phase.ghl) through the production GHL compiler's
# own lexer/parser/transpiler - the same Unit used by eval_ed25519.py, so the
# logic under test is exactly what the .ghl declares and nothing is silently
# skipped (the transpiler hard-errors on anything outside its integer subset).
#
# This is the CI stand-in for the FPGA one-shot (docs/track10-...-todo.md
# "Notes / TCG limitation"): the host boot/driver/monitor path can be exercised
# against the exact phase/latch/single-use semantics the board must implement,
# with no real hardware. Crypto + TRNG + tamper are validated elsewhere.
#
# Suite mirrors the track doc's "P2 - Validation / One-shot / latch tests":
#   1. power-on arms Phase A and bumps the monotonic boot counter.
#   2. privileged ops run once in Phase A, then are single-use (relay rejected).
#   3. the latch closes on each documented trigger and is sticky.
#   4. after the latch, every privileged op is LOCKED; no sequence re-arms it.
#   5. a single glitched latch cell does not re-open the window (majority vote).
#   6. derive never returns the master and is boot-counter bound (no cross-boot
#      replay); there is no key-export opcode.
#   7. attest reports the real latch state + boot counter.

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.dirname(__file__))
from eval_ed25519 import Unit  # noqa: E402  reuse the production transpiler

MODULE = os.path.join(ROOT, 'src', 'enclave', 'enclave_phase.ghl')

# Opcodes / status (kept in lockstep with enclave_phase.ghl; the const-drift
# guard below asserts these against the compiled module so they can't rot).
OP_DERIVE_KEY, OP_UNSEAL, OP_SEAL_LOCK = 0x10, 0x11, 0x12
OP_SIGN, OP_RNG, OP_COUNTER_READ, OP_ATTEST = 0x20, 0x21, 0x22, 0x23
ENC_OK, ENC_LOCKED, ENC_REPLAY, ENC_BADOP, ENC_PHASE = 0, 1, 2, 3, 4

FAILURES = []


def check(label, ok, detail=''):
    print('[enclave] %-52s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                      (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def fresh(u):
    """Model a power cycle; returns the new boot counter."""
    return u.call('enclave_power_on')


def main():
    u = Unit([MODULE])
    print('[enclave] transpiled %d fns, %d data symbols, %d consts '
          '(production gritc frontend)' % (len(u.fns), len(u.data), len(u.consts)))

    # 0. const-drift guard: the opcodes/status this harness asserts against MUST
    #    equal the compiled module's, so the test can never silently diverge.
    cd = u.consts
    check('opcode/status constants match the module', all([
        cd['OP_DERIVE_KEY'] == OP_DERIVE_KEY, cd['OP_UNSEAL'] == OP_UNSEAL,
        cd['OP_SEAL_LOCK'] == OP_SEAL_LOCK, cd['OP_SIGN'] == OP_SIGN,
        cd['OP_ATTEST'] == OP_ATTEST, cd['ENC_OK'] == ENC_OK,
        cd['ENC_LOCKED'] == ENC_LOCKED, cd['ENC_REPLAY'] == ENC_REPLAY,
    ]))

    # 1. before power-on, the device answers nothing.
    check('no command before power-on (ENC_PHASE)',
          u.call('enclave_command', OP_ATTEST, 0) == ENC_PHASE)
    check('attest is also gated before power-on',
          u.call('enclave_boot_complete') == ENC_PHASE)

    # 2. power-on arms Phase A and bumps the monotonic boot counter.
    c0 = fresh(u)
    check('power-on enters Phase A', u.call('enclave_phase') == 0)
    check('power-on clears the latch', u.call('enclave_latched') == 0)
    c1 = fresh(u)
    check('boot counter is monotonic across power cycles', c1 == c0 + 1,
          'c0=%d c1=%d' % (c0, c1))

    # 3. privileged ops run ONCE in Phase A, then are single-use.
    fresh(u)
    rc = u.call('enclave_command', OP_DERIVE_KEY, 0xDEADBEEF)
    check('derive accepted in Phase A', rc == ENC_OK, 'rc=%d' % rc)
    rc = u.call('enclave_command', OP_DERIVE_KEY, 0xDEADBEEF)
    check('relayed/duplicate derive rejected (ENC_REPLAY)', rc == ENC_REPLAY,
          'rc=%d' % rc)
    # a DIFFERENT privileged op is still available exactly once.
    rc = u.call('enclave_command', OP_UNSEAL, 0x1234)
    check('unseal still available once (independent single-use)', rc == ENC_OK,
          'rc=%d' % rc)
    rc = u.call('enclave_command', OP_UNSEAL, 0x1234)
    check('duplicate unseal rejected (ENC_REPLAY)', rc == ENC_REPLAY,
          'rc=%d' % rc)
    check('used-op bitmap records both consumptions',
          u.call('enclave_priv_used_mask') == 0b011)

    # 4. derive never returns the master, and is boot-counter bound.
    MASTER = u.consts['ENC_MASTER_MODEL']
    fresh(u)
    u.call('enclave_command', OP_DERIVE_KEY, 0)
    out_a = u.call('enclave_derive_out') & 0xFFFFFFFFFFFFFFFF
    check('derive output is not the raw master', out_a != MASTER)
    fresh(u)  # next boot, same request
    u.call('enclave_command', OP_DERIVE_KEY, 0)
    out_b = u.call('enclave_derive_out') & 0xFFFFFFFFFFFFFFFF
    check('same request on a later boot yields a different output '
          '(no cross-boot replay)', out_a != out_b,
          'a=%#x b=%#x' % (out_a, out_b))
    check('no key-export opcode exists in the privileged range',
          not any(c.startswith('OP_') and ('EXPORT' in c or 'READKEY' in c)
                  for c in u.consts))

    # 5. the latch closes on EACH documented trigger, and is sticky.
    #    (a) explicit seal_and_lock
    fresh(u)
    rc = u.call('enclave_command', OP_SEAL_LOCK, 0)
    check('seal_and_lock accepted and closes the latch',
          rc == ENC_OK and u.call('enclave_latched') == 1, 'rc=%d' % rc)
    check('seal_and_lock moves to Phase B', u.call('enclave_phase') == 1)
    #    (b) first non-boot (Phase-B) opcode auto-closes Phase A
    fresh(u)
    check('fresh boot is back in Phase A (latch reset only by power-on)',
          u.call('enclave_phase') == 0)
    rc = u.call('enclave_command', OP_SIGN, 0)
    check('first Phase-B opcode auto-closes the latch',
          rc == ENC_OK and u.call('enclave_latched') == 1, 'rc=%d' % rc)
    #    (c) explicit boot_complete handoff
    fresh(u)
    u.call('enclave_boot_complete')
    check('boot_complete closes the latch', u.call('enclave_latched') == 1)
    #    (d) watchdog timeout
    fresh(u)
    closed_at = -1
    for i in range(200):
        if u.call('enclave_tick') == 1:
            closed_at = i
            break
    check('watchdog auto-closes Phase A within its budget',
          u.call('enclave_latched') == 1 and 0 <= closed_at <= 64,
          'closed_at=%d' % closed_at)

    # 6. after the latch: every privileged op is LOCKED; NO sequence re-arms it.
    fresh(u)
    u.call('enclave_boot_complete')  # latch closed
    for op, nm in ((OP_DERIVE_KEY, 'derive'), (OP_UNSEAL, 'unseal'),
                   (OP_SEAL_LOCK, 'seal_lock')):
        rc = u.call('enclave_command', op, 0)
        check('post-latch %s -> ENC_LOCKED' % nm, rc == ENC_LOCKED,
              'rc=%d' % rc)
    # hammer Phase-B + boot_complete in every order: latch must never clear.
    rearmed = False
    for seq in range(50):
        u.call('enclave_command', OP_SIGN, seq)
        u.call('enclave_command', OP_ATTEST, seq)
        u.call('enclave_boot_complete')
        u.call('enclave_tick')
        if u.call('enclave_latched') == 0:
            rearmed = True
            break
    check('no host command sequence re-arms the latch without power-on',
          not rearmed)
    check('only power-on clears the latch',
          (u.call('enclave_power_on') >= 1) and u.call('enclave_latched') == 0)

    # 7. a single glitched latch cell does NOT re-open the window (majority vote).
    fresh(u)
    u.call('enclave_boot_complete')
    u.mem[u.data_addr['enc_latch_a']] = 0   # glitch one of three cells to 0
    check('latch survives a single flipped cell (2-of-3 majority)',
          u.call('enclave_latched') == 1)
    check('glitched-cell board still refuses privileged ops',
          u.call('enclave_command', OP_DERIVE_KEY, 0) == ENC_LOCKED)
    u.mem[u.data_addr['enc_latch_b']] = 0   # now two cells down -> opens
    check('two downed cells DO clear (model is honest about 2-fault)',
          u.call('enclave_latched') == 0)

    # 8. attest reports the real latch state + boot counter.
    bc = fresh(u)
    check('attest reports Phase-A latch=0', u.call('enclave_attest_latch') == 0)
    check('attest reports the live boot counter',
          u.call('enclave_attest_counter') == bc)
    u.call('enclave_boot_complete')
    check('attest reports latch=1 after lockdown',
          u.call('enclave_attest_latch') == 1)

    # 9. hard rejects: unknown opcodes never touch the key path.
    fresh(u)
    check('unknown opcode rejected (ENC_BADOP)',
          u.call('enclave_command', 0x99, 0) == ENC_BADOP)
    check('gap between groups rejected (ENC_BADOP)',
          u.call('enclave_command', 0x1F, 0) == ENC_BADOP)

    if FAILURES:
        sys.stderr.write('[enclave] FAIL - %d problem(s):\n' % len(FAILURES))
        for f in FAILURES:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[enclave] one-shot phase machine: latch, single-use, lockdown, and '
          'attest semantics all enforced (Track 10 P0 model)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
