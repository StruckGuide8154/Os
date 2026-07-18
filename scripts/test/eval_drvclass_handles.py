#!/usr/bin/env python3
"""Executable proof for versioned, generation-safe driver class handles."""
import argparse
import os
import sys

from eval_drvhost_dma_mint import Program, Unit, install_driver, C, Violation

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
MODULE = os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'driver_host.ghl')


def check(ok, message):
    if not ok:
        raise Violation(message)


def prove(src):
    p = Program(src)
    u = Unit(p)
    driver = install_driver(u, 0, C(p, 'DRV_CAP_DMA'), 4096)
    abi = C(p, 'DRVCLASS_ABI_V1')
    net = C(p, 'DRVCLASS_NET_L2')

    handle = u.call('drvclass_publish_net_l2', [driver, abi, abi, 1500, 0])
    check(handle != 0, 'healthy net.l2 endpoint was not published')
    check(handle < (1 << 63), 'opaque handle set the sign bit')
    check(u.call('drvclass_resolve', [handle, net, abi]) == driver,
          'published handle did not resolve to its owner')
    check(u.call('drvclass_net_l2_mtu', [handle]) == 1500,
          'net.l2 MTU metadata was not bound to the handle')
    check(u.call('drvclass_publish_net_l2', [driver, abi, abi, 1500, 0]) == 0,
          'duplicate live owner/class publication was accepted')

    # Every packed authority field is authenticated by the kernel-owned row.
    for bit, label in ((0, 'entry'), (8, 'kind'), (16, 'version'),
                       (24, 'owner'), (32, 'generation'), (63, 'sign')):
        forged = handle ^ (1 << bit)
        check(u.call('drvclass_resolve', [forged, net, abi]) == 0,
              'forged %s field resolved' % label)

    check(u.call('drvclass_publish_net_l2', [driver, abi, abi, 575, 0]) == 0,
          'undersized MTU was accepted')
    check(u.call('drvclass_publish_net_l2', [driver, abi, abi, 9220, 0]) == 0,
          'oversized MTU was accepted')
    check(u.call('drvclass_publish_net_l2', [driver, abi, abi, 1500, 8]) == 0,
          'unknown feature bit was accepted')

    # Quarantine revokes the registry row. Restart restores no endpoint and
    # advances the generation; only a fresh post-health-check publication works.
    check(u.call('drvhost_quarantine', [driver]) == C(p, 'DRV_OK'),
          'quarantine failed')
    check(u.call('drvclass_resolve', [handle, net, abi]) == 0,
          'quarantine left a class handle live')
    check(u.call('drvhost_restart', [driver]) == C(p, 'DRV_OK'), 'restart failed')
    check(u.call('drvclass_resolve', [handle, net, abi]) == 0,
          'stale pre-restart handle revalidated')
    fresh = u.call('drvclass_publish_net_l2', [driver, abi, abi, 1500, 0])
    check(fresh != 0 and fresh != handle, 'restart did not mint a fresh generation')
    check(u.call('drvclass_resolve', [fresh, net, abi]) == driver,
          'fresh post-restart handle did not resolve')

    # Generation exhaustion is an explicit offline state, never wraparound.
    u.call('drvhost_quarantine', [driver])
    u.poke('drv_restarts', driver, 4, C(p, 'DRVCLASS_GEN_MAX') - 1)
    check(u.call('drvhost_restart', [driver]) == C(p, 'DRV_ERR_STATE'),
          'generation exhaustion did not fail closed')
    return 19


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    args = ap.parse_args()
    with open(MODULE, encoding='utf-8') as fh:
        src = fh.read()
    if args.selftest:
        generation_anchor = 'if generation != lw(&drv_restarts + id * 4) + 1 { return 0; }'
        revoke_anchor = 'drvclass_revoke(id);'
        if generation_anchor not in src or revoke_anchor not in src:
            print('[drvclass] selftest anchor drifted', file=sys.stderr)
            return 1
        try:
            broken = src.replace(generation_anchor, 'if 0 { return 0; }')
            broken = broken.replace(revoke_anchor, 'drvclass_revoke(0);', 1)
            prove(broken)
        except Exception as exc:
            print('[drvclass] selftest PASS: stale-generation bug caught (%s)' % exc)
            return 0
        print('[drvclass] selftest FAIL: stale handle escaped', file=sys.stderr)
        return 1
    try:
        checks = prove(src)
    except Exception as exc:
        print('[drvclass] FAIL: %s' % exc, file=sys.stderr)
        return 1
    print('[drvclass] PASS: version/owner/generation/metadata containment proven (%d checks)'
          % checks)
    return 0


if __name__ == '__main__':
    sys.exit(main())
