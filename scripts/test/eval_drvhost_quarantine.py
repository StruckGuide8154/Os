#!/usr/bin/env python3
"""Executable Track-8 G3/G4 negative and quarantine/restart proof."""
import argparse
import os
import sys

from eval_drvhost_dma_mint import Program, Unit, install_driver, C, Violation

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
MODULE = os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'driver_host.ghl')


def prove(src):
    p = Program(src)
    u = Unit(p)
    mmio = C(p, 'DRV_CAP_MMIO')
    ok = C(p, 'DRV_OK')
    grant_err = C(p, 'DRV_ERR_GRANT')
    running = C(p, 'DRV_ST_RUNNING')
    quarantined = C(p, 'DRV_ST_QUARANTINE')
    budget = C(p, 'FAULT_BUDGET')
    driver = install_driver(u, 0, mmio, 0)
    if u.call('drvhost_grant_mmio', [driver, 0x1000, 0x100]) != ok:
        raise Violation('control-plane MMIO grant failed')

    # Compromised process forges an address immediately outside its window.
    # The raw hardware boundary must never execute.
    rc = u.call('drvhost_mmio_write32', [driver, 0x1100, 0xDEADBEEF])
    if rc != grant_err:
        raise Violation('out-of-grant MMIO write was not refused')
    if u.raw_log:
        raise Violation('forged request reached the raw MMIO boundary')

    # The real syscall-boundary accounting path charges each refusal. At the
    # exact budget it must quarantine and revoke the previously valid grant.
    for _ in range(budget):
        u.call('drvhost_charge_result', [driver, grant_err])
    if u.call('drvhost_state', [driver]) != quarantined:
        raise Violation('fault budget did not quarantine the driver')
    if u.peek('mg_count', 0, 4) != 0:
        raise Violation('quarantine left an MMIO grant live')
    before = len(u.raw_log)
    if u.call('drvhost_mmio_write32', [driver, 0x1000, 1]) == ok:
        raise Violation('quarantined driver retained hardware authority')
    if len(u.raw_log) != before:
        raise Violation('quarantined request reached hardware')

    # Recovery is a separate broker path. It returns RUNNING but deliberately
    # restores no grants, proving stale authority is not inherited.
    if u.call('drvhost_restart', [driver]) != ok:
        raise Violation('recovery path refused quarantined driver')
    if u.call('drvhost_state', [driver]) != running:
        raise Violation('restart did not return driver to RUNNING')
    if u.call('drvhost_mmio_write32', [driver, 0x1000, 1]) == ok:
        raise Violation('restart silently restored stale MMIO authority')
    return budget + 7


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    args = ap.parse_args()
    with open(MODULE, encoding='utf-8') as fh:
        src = fh.read()
    if args.selftest:
        anchor = 'if rc != DRV_OK { drvhost_fault(id); }'
        if anchor not in src:
            print('[drvhost-g4] selftest anchor drifted', file=sys.stderr)
            return 1
        try:
            prove(src.replace(anchor, 'if 0 { drvhost_fault(id); }'))
        except Exception as exc:
            print('[drvhost-g4] selftest PASS: disabled accounting caught (%s)' % exc)
            return 0
        print('[drvhost-g4] selftest FAIL: broken accounting escaped', file=sys.stderr)
        return 1
    try:
        checks = prove(src)
    except Exception as exc:
        print('[drvhost-g4] FAIL: %s' % exc, file=sys.stderr)
        return 1
    print('[drvhost-g4] PASS: forged request refused; %d-fault quarantine, revocation, and grantless restart proven (%d checks)'
          % (C(Program(src), 'FAULT_BUDGET'), checks))
    return 0


if __name__ == '__main__':
    sys.exit(main())
