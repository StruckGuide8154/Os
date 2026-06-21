#!/usr/bin/env python3
# Track-10 enclave SECURE-BOOT transaction evaluation: executes the REAL
# gateware MODEL sources (enclave_phase.ghl + enclave_session.ghl +
# enclave_boot.ghl) COMPOSED in one production-GHL Unit, so the cross-module
# integration under test is exactly what the .ghl files declare (the boot module
# really calls the phase + session modules; extern resolution is the compiler's,
# not the harness's).
#
# This is the CI stand-in for the FPGA's Phase-A boot handler
# (docs/track10-...-todo.md "P0 - Boot-time attestation & trust anchoring"):
# power-on -> mutual session handshake -> the board judges the host measurement
# against its OWN SEALED POLICY -> releases a derived, measurement+counter-bound
# boot key on a match -> seals and locks. No real hardware.
#
# Suite mirrors the track doc "P2 - Validation":
#   1. happy path: matching measurement releases a boot key (never the master,
#      measurement-bound) and locks the privileged window.
#   2. fail-closed boot: required-mode + measurement mismatch -> HALT, no key,
#      latch still closes.
#   3. DOWNGRADE test: board policy required + host CLAIMS optional + mismatch
#      -> still fail-closed (the board ignores the host's claimed mode).
#   4. optional-mode mismatch degrades (no key) without halting; trust intact.
#   5. no authenticated channel -> refuse to boot.
#   6. no sealed policy -> refuse (fail-closed), still lock down.
#   7. one-shot: the boot transaction runs once per power cycle; post-boot the
#      privileged path is LOCKED and a re-run is rejected.
#   8. sealed policy is set-once (a host re-seal at boot is refused).

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.dirname(__file__))
from eval_ed25519 import Unit          # noqa: E402  production transpiler
from eval_enclave_session import Host  # noqa: E402  honest-host handshake driver

PHASE = os.path.join(ROOT, 'src', 'enclave', 'enclave_phase.ghl')
SESSION = os.path.join(ROOT, 'src', 'enclave', 'enclave_session.ghl')
BOOT = os.path.join(ROOT, 'src', 'enclave', 'enclave_boot.ghl')

BOOT_OK, BOOT_NO_POLICY, BOOT_NO_SESSION = 0, 1, 2
BOOT_FAIL_CLOSED, BOOT_DEGRADED, BOOT_REPLAY = 3, 4, 5
POLICY_OPTIONAL, POLICY_REQUIRED = 0, 1
ENC_LOCKED = 1
M64 = 0xFFFFFFFFFFFFFFFF

MEAS_GOOD = 0xC1EA17C0DEC1EAAC  # the sealed/expected host measurement
MEAS_BAD = 0xBADBADBADBADBAD0   # a tampered host image's measurement

FAILURES = []


def check(label, ok, detail=''):
    print('[encboot] %-56s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                      (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def new_board():
    """A fresh composed board: power-on (arms Phase A, bumps boot counter)."""
    u = Unit([PHASE, SESSION, BOOT])
    u.call('enclave_power_on')
    return u


def do_handshake(u, priv=0x1111222233334444, seed=0xCAFEF00D):
    """Establish the authenticated channel; return the boot counter bound in."""
    boot = u.call('enclave_boot_counter')
    h = Host(u, priv=priv, seed=seed)
    h._boot = boot
    rc_b, rc_f = h.handshake(boot)
    return rc_b, rc_f


def main():
    # const-drift guard against the composed modules.
    u0 = Unit([PHASE, SESSION, BOOT])
    print('[encboot] transpiled %d fns, %d data symbols, %d consts '
          '(composed phase+session+boot)' % (len(u0.fns), len(u0.data),
                                             len(u0.consts)))
    cd = u0.consts
    check('boot status / policy constants match the module', all([
        cd['BOOT_OK'] == BOOT_OK, cd['BOOT_NO_POLICY'] == BOOT_NO_POLICY,
        cd['BOOT_NO_SESSION'] == BOOT_NO_SESSION,
        cd['BOOT_FAIL_CLOSED'] == BOOT_FAIL_CLOSED,
        cd['BOOT_DEGRADED'] == BOOT_DEGRADED, cd['BOOT_REPLAY'] == BOOT_REPLAY,
        cd['POLICY_REQUIRED'] == POLICY_REQUIRED,
    ]))
    check("boot module's derive opcode tracks the phase module's",
          cd['BOP_DERIVE_KEY'] == cd['OP_DERIVE_KEY'])

    # 1. happy path: matching measurement -> boot key released + locked down.
    u = new_board()
    check('seal required policy', u.call('enclave_boot_seal_policy',
          MEAS_GOOD, POLICY_REQUIRED) == BOOT_OK)
    check('policy reports sealed', u.call('enclave_boot_policy_sealed') == 1)
    _, rc_f = do_handshake(u)
    check('authenticated channel established before boot', rc_f == BOOT_OK)
    rc = u.call('enclave_boot_run', MEAS_GOOD, POLICY_REQUIRED)
    check('matching measurement -> BOOT_OK', rc == BOOT_OK, 'rc=%s' % rc)
    key = u.call('enclave_boot_key') & M64
    check('a boot key was released', key != 0)
    check('boot key is NOT the raw master', key != (cd['ENC_MASTER_MODEL'] & M64))
    check('boot key is NOT the measurement itself', key != MEAS_GOOD)
    check('boot key == the phase-machine derive output (real integration)',
          key == (u.call('enclave_derive_out') & M64))
    check('privileged window is locked after boot', u.call('enclave_boot_locked') == 1)
    check('quote reports latch=1 (locked-down this boot)',
          u.call('enclave_boot_quote_latch') == 1)
    check('quote reports the live boot counter',
          u.call('enclave_boot_quote_counter') == u.call('enclave_boot_counter'))
    # post-boot one-shot: privileged path dead, re-run rejected.
    check('post-boot raw derive -> ENC_LOCKED',
          u.call('enclave_command', cd['OP_DERIVE_KEY'], MEAS_GOOD) == ENC_LOCKED)
    check('re-running the boot transaction -> BOOT_REPLAY',
          u.call('enclave_boot_run', MEAS_GOOD, POLICY_REQUIRED) == BOOT_REPLAY)

    # boot key is measurement-bound: a different measured image -> different key.
    u2 = new_board()
    u2.call('enclave_boot_seal_policy', MEAS_BAD, POLICY_REQUIRED)
    do_handshake(u2)
    u2.call('enclave_boot_run', MEAS_BAD, POLICY_REQUIRED)
    key2 = u2.call('enclave_boot_key') & M64
    check('a different measured image yields a different boot key',
          key2 != 0 and key2 != key, 'k1=%#x k2=%#x' % (key, key2))

    # 2. required + measurement mismatch -> FAIL_CLOSED (HALT), no key, locked.
    u = new_board()
    u.call('enclave_boot_seal_policy', MEAS_GOOD, POLICY_REQUIRED)
    do_handshake(u)
    rc = u.call('enclave_boot_run', MEAS_BAD, POLICY_REQUIRED)
    check('required + mismatch -> BOOT_FAIL_CLOSED', rc == BOOT_FAIL_CLOSED,
          'rc=%s' % rc)
    check('fail-closed released no boot key', (u.call('enclave_boot_key') & M64) == 0)
    check('fail-closed still locked the privileged window',
          u.call('enclave_boot_locked') == 1)

    # 3. DOWNGRADE test: board=required, host CLAIMS optional, mismatch.
    u = new_board()
    u.call('enclave_boot_seal_policy', MEAS_GOOD, POLICY_REQUIRED)
    do_handshake(u)
    rc = u.call('enclave_boot_run', MEAS_BAD, POLICY_OPTIONAL)  # host lies
    check('host claiming optional does NOT downgrade a required board '
          '(still FAIL_CLOSED)', rc == BOOT_FAIL_CLOSED, 'rc=%s' % rc)
    check('downgrade attempt released no key', (u.call('enclave_boot_key') & M64) == 0)

    # 4. optional + mismatch -> DEGRADED (no key, boot continues), trust intact.
    u = new_board()
    u.call('enclave_boot_seal_policy', MEAS_GOOD, POLICY_OPTIONAL)
    do_handshake(u)
    rc = u.call('enclave_boot_run', MEAS_BAD, POLICY_OPTIONAL)
    check('optional + mismatch -> BOOT_DEGRADED', rc == BOOT_DEGRADED, 'rc=%s' % rc)
    check('degraded released no key', (u.call('enclave_boot_key') & M64) == 0)
    check('degraded still closed the one-shot window',
          u.call('enclave_boot_locked') == 1)

    # 5. no authenticated channel -> refuse to boot (no handshake run).
    u = new_board()
    u.call('enclave_boot_seal_policy', MEAS_GOOD, POLICY_REQUIRED)
    rc = u.call('enclave_boot_run', MEAS_GOOD, POLICY_REQUIRED)
    check('boot without an authenticated channel -> BOOT_NO_SESSION',
          rc == BOOT_NO_SESSION, 'rc=%s' % rc)
    check('refused boot released no key', (u.call('enclave_boot_key') & M64) == 0)

    # 6. no sealed policy -> refuse (fail-closed), but still lock down.
    u = new_board()
    do_handshake(u)
    rc = u.call('enclave_boot_run', MEAS_GOOD, POLICY_REQUIRED)
    check('unprovisioned board (no policy) -> BOOT_NO_POLICY', rc == BOOT_NO_POLICY,
          'rc=%s' % rc)
    check('unprovisioned board still locked the privileged window',
          u.call('enclave_boot_locked') == 1)

    # 7/8. sealed policy is set-once (a host re-seal at boot is refused).
    u = new_board()
    check('first policy seal accepted', u.call('enclave_boot_seal_policy',
          MEAS_GOOD, POLICY_REQUIRED) == BOOT_OK)
    check('a second seal (host trying to rewrite policy) -> BOOT_REPLAY',
          u.call('enclave_boot_seal_policy', MEAS_BAD, POLICY_OPTIONAL) == BOOT_REPLAY)
    do_handshake(u)
    # the original (required, MEAS_GOOD) policy must still be in force.
    check('a re-seal attempt did NOT change the in-force policy',
          u.call('enclave_boot_run', MEAS_BAD, POLICY_OPTIONAL) == BOOT_FAIL_CLOSED)

    if FAILURES:
        sys.stderr.write('[encboot] FAIL - %d problem(s):\n' % len(FAILURES))
        for f in FAILURES:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[encboot] secure-boot transaction: sealed-policy judgement, '
          'measurement-bound key release, downgrade resistance, fail-closed '
          'halt, and one-shot lockdown all enforced (Track 10 P0 model)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
