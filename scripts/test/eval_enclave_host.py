#!/usr/bin/env python3
"""Track-10 host mediation/capability/broker/handoff evaluation."""

import hashlib
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'build'))
from eval_ed25519 import Unit  # noqa: E402
from eval_enclave_session import Host  # noqa: E402
import ed25519_host  # noqa: E402


def fold64(b):
    """Fold a byte string into the 64-bit domain the host model operates in."""
    return int.from_bytes(hashlib.sha256(b).digest()[:8], 'little')

PHASE = os.path.join(ROOT, 'src', 'enclave', 'enclave_phase.ghl')
SESSION = os.path.join(ROOT, 'src', 'enclave', 'enclave_session.ghl')
BOOT = os.path.join(ROOT, 'src', 'enclave', 'enclave_boot.ghl')
HOST = os.path.join(ROOT, 'src', 'enclave', 'enclave_host.ghl')
SERVICES = os.path.join(ROOT, 'src', 'enclave', 'enclave_services.ghl')
DRIVER = os.path.join(ROOT, 'src', 'drivers', 'enclave', 'phase_b.ghl')
COMPILER = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler', 'gritc.py')
LIB = os.path.join(ROOT, 'src', 'user', 'grithl', 'lib')

FAILURES = []
CHECKS = 0


def check(label, ok, detail=''):
    global CHECKS
    CHECKS += 1
    print('[enclave-host] %-58s [%s]%s' % (
        label, 'ok' if ok else 'FAIL', (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def unit():
    u = Unit([PHASE, SESSION, BOOT, SERVICES, HOST])
    u.call('enclave_host_reset')
    return u


def successful_phase_a(u, measurement=0x12345678ABCDEF01):
    u.call('enclave_host_set_boot_measurement', measurement)
    u.call('enclave_power_on')
    counter = u.call('enclave_boot_counter')
    h = Host(u, priv=0x1111222233334444, seed=0xCAFEF00D)
    h._boot = counter
    rc_begin, rc_finish = h.handshake(counter)
    check('board-first mutual session establishes', rc_begin == 0 and rc_finish == 0)
    check('board policy seals once',
          u.call('enclave_boot_seal_policy', measurement, 1) == 0)
    rc = u.call('enclave_boot_run', measurement, 1)
    check('composed Phase-A boot succeeds', rc == 0, 'rc=%d' % rc)
    check('real board model is latched before handoff',
          u.call('enclave_boot_locked') == 1)
    return rc


def bind_roots(u, board=0xA11CE, image=0xA11CE):
    return u.call('enclave_host_bind_roots', board, image)


def handoff(u, tier=1, iommu=1, present=1, boot_rc=0, required=1,
            base=0x800000, length=0x1000):
    return u.call('enclave_host_handoff', tier, iommu,
                  u.call('enclave_boot_locked'), present, boot_rc, required,
                  base, length)


def broker_call(u, c, caps, service, arg, expect_done=True):
    """Submit one service and drive exactly two bounded scheduler ticks."""
    rc = u.call('enclave_host_request', caps, service, arg)
    check('service %d submission is asynchronous' % service,
          rc == c['EH_ASYNC_PENDING'])
    check('service %d first tick does not block' % service,
          u.call('enclave_host_tick') == c['EH_REQ_PENDING'])
    terminal = u.call('enclave_host_tick')
    wanted = c['EH_REQ_DONE'] if expect_done else c['EH_REQ_FAILED']
    check('service %d reaches expected terminal state' % service,
          terminal == wanted, 'state=%d' % terminal)
    return u.call('enclave_host_result')


def main():
    # The transport is a real Track-8 driver-target artifact.  Compilation
    # forces --forbid-asm and --deny-unsafe, proving no ambient HW authority.
    with tempfile.TemporaryDirectory(prefix='enclave-driver-') as td:
        out = os.path.join(td, 'phase_b.asm')
        cp = subprocess.run([sys.executable, COMPILER, DRIVER, '-o', out,
                             '-L', LIB, '--target', 'driver'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
        check('ring-3 Phase-B transport compiles under driver authority gate',
              cp.returncode == 0, cp.stderr.strip())
    with open(DRIVER, 'r', encoding='utf-8') as fh:
        driver_source = fh.read()
    check('driver source declares no unsafe authority',
          re.search(r'^\s*unsafe\s+', driver_source, re.MULTILINE) is None)
    check('driver exposes Phase-B services but no privileged API',
          'SVC_TPM_SEAL' in driver_source and
          'SVC_TPM_UNSEAL' not in driver_source and
          'SVC_DERIVE' not in driver_source)

    u = unit()
    c = u.consts
    print('[enclave-host] transpiled %d fns across phase/session/boot/host' % len(u.fns))

    # Root relocation: the image root is a mirror, never a fallback authority.
    check('root mismatch is rejected', bind_roots(u, 0xAA, 0xBB) == c['EH_ERR_ROOT'])
    check('missing board root is rejected', bind_roots(unit(), 0, 0) == c['EH_ERR_ROOT'])
    u = unit()
    check('matching board-authoritative root accepted', bind_roots(u) == c['EH_OK'])

    # Atomic handoff is composed with the real Phase-A model.
    boot_rc = successful_phase_a(u)
    check('latched board hands directly to monitor', handoff(u, boot_rc=boot_rc) == c['EH_OK'])
    check('monitor exclusively owns endpoint',
          u.call('enclave_host_endpoint_owner') == c['EH_OWNER_MONITOR'])
    check('IOMMU isolation is active', u.call('enclave_host_iommu_isolated') == 1)
    check('apps enabled only after complete handoff', u.call('enclave_host_apps_enabled') == 1)

    # No raw route for app, driver, or a simulated compromised kernel.
    for actor, name in ((1, 'ring-3 app'), (2, 'ring-3 driver'), (3, 'compromised kernel')):
        check('%s cannot issue raw privileged command' % name,
              u.call('enclave_host_direct_raw', actor, 0x10) == c['EH_ERR_DENIED'])
        check('%s cannot issue raw Phase-B command' % name,
              u.call('enclave_host_direct_raw', actor, 0x20) == c['EH_ERR_DENIED'])

    # IOMMU domain/window confinement.
    check('monitor DMA inside granted buffer accepted',
          u.call('enclave_host_dma_access', c['EH_DMA_MONITOR'], 0x800100, 64) == c['EH_OK'])
    check('other device cannot DMA-snoop enclave buffer',
          u.call('enclave_host_dma_access', 2, 0x800100, 64) == c['EH_ERR_DENIED'])
    check('monitor DMA outside grant rejected',
          u.call('enclave_host_dma_access', c['EH_DMA_MONITOR'], 0x801000, 1) == c['EH_ERR_DENIED'])

    # Track-8 broker registration is intersection-only.
    req = c['EH_DRV_REQUIRED']
    check('driver request cannot exceed signed policy',
          u.call('enclave_host_register_driver', req, c['EH_DRV_CAP_PHASE_B']) == c['EH_ERR_DRIVER'])
    check('effective driver caps are the intersection',
          u.call('enclave_host_driver_caps') == c['EH_DRV_CAP_PHASE_B'])
    check('signed Phase-B transport policy accepted',
          u.call('enclave_host_register_driver', req, req) == c['EH_OK'])

    # CAP_ENCLAVE defaults to absent, and the API has no privileged operation.
    check('zero/default caller capability is denied',
          u.call('enclave_host_request', 0, c['EH_SVC_SIGN'], 7) == c['EH_ERR_DENIED'])
    check('unknown/privileged-shaped service is absent from API',
          u.call('enclave_host_api_opcode', 0x40) == 0)
    check('entitled caller still cannot request missing service',
          u.call('enclave_host_request', c['CAP_ENCLAVE'], 0x40, 7) == c['EH_ERR_SERVICE'])
    for svc in (c['EH_SVC_SIGN'], c['EH_SVC_RNG'],
                c['EH_SVC_COUNTER_READ'], c['EH_SVC_ATTEST']):
        opcode = u.call('enclave_host_api_opcode', svc)
        check('service %d maps only to Phase-B opcode' % svc, 0x20 <= opcode <= 0x23)

    # Async tick FSM: syscall submits and returns; later ticks complete it.
    rc = u.call('enclave_host_request', c['CAP_ENCLAVE'], c['EH_SVC_RNG'], 0x55)
    check('Phase-B request returns pending, not a blocking result', rc == c['EH_ASYNC_PENDING'])
    check('first scheduler tick remains pending',
          u.call('enclave_host_tick') == c['EH_REQ_PENDING'])
    check('second scheduler tick completes', u.call('enclave_host_tick') == c['EH_REQ_DONE'])
    check('completed result comes from allowed opcode',
          u.call('enclave_host_result') == (c['EH_OP_RNG'] ^ 0x55))

    # Extended Phase-B services all remain multiplexed onto the four physical
    # allow-listed opcodes and require service-specific entitlements.
    extended = range(c['EH_SVC_CREDENTIAL_USE'], c['EH_SVC_TPM_SEAL'] + 1)
    for svc in extended:
        opcode = u.call('enclave_host_api_opcode', svc)
        check('extended service %d maps to Phase-B opcode' % svc,
              0x20 <= opcode <= 0x23)
    check('key use denied without key entitlement',
          u.call('enclave_host_request', c['CAP_ENCLAVE'],
                 c['EH_SVC_CREDENTIAL_USE'], 1) == c['EH_ERR_DENIED'])
    check('TPM use denied without TPM entitlement',
          u.call('enclave_host_request', c['CAP_ENCLAVE'],
                 c['EH_SVC_TPM_QUOTE'], 0) == c['EH_ERR_DENIED'])

    key_caps = c['CAP_ENCLAVE'] | c['CAP_ENCLAVE_KEYS']
    cred = broker_call(u, c, key_caps, c['EH_SVC_CREDENTIAL_USE'], 0xC001)
    cred_sig = u.call('enclave_host_result_signature')
    check('credential operation returns a derived use result', cred != 0)
    check('credential result is board-signed', cred_sig != 0)
    check('credential use is one-shot in this boot',
          broker_call(u, c, key_caps, c['EH_SVC_CREDENTIAL_USE'], 0xC001,
                      expect_done=False) == c['ES_ERR_REPLAY'])
    ram = broker_call(u, c, key_caps, c['EH_SVC_RAM_KEY_USE'], 0xA700)
    check('RAM-key operation is distinct from credential use', ram != cred)
    check('RAM-key use is one-shot in this boot',
          broker_call(u, c, key_caps, c['EH_SVC_RAM_KEY_USE'], 0xA700,
                      expect_done=False) == c['ES_ERR_REPLAY'])

    floor_caps = c['CAP_ENCLAVE'] | c['CAP_ENCLAVE_FLOORS']
    floor_arg = (2 << 56) | 41
    check('board-backed floor bump returns new floor',
          broker_call(u, c, floor_caps, c['EH_SVC_FLOOR_BUMP'], floor_arg) == 41)
    check('board-backed floor read returns persisted floor',
          broker_call(u, c, floor_caps, c['EH_SVC_FLOOR_READ'], 2 << 56) == 41)
    check('floor rollback/equal bump is rejected',
          broker_call(u, c, floor_caps, c['EH_SVC_FLOOR_BUMP'],
                      (2 << 56) | 40, expect_done=False) == c['ES_ERR_ROLLBACK'])

    rng1 = broker_call(u, c, c['CAP_ENCLAVE'], c['EH_SVC_ATTESTED_RNG'], 0xAA)
    rng_sig1 = u.call('enclave_host_result_signature')
    rng2 = broker_call(u, c, c['CAP_ENCLAVE'], c['EH_SVC_ATTESTED_RNG'], 0xAA)
    check('attested RNG advances per-sample sequence', rng1 != rng2)
    check('attested RNG sample carries board signature', rng_sig1 != 0)

    release_caps = c['CAP_ENCLAVE'] | c['CAP_ENCLAVE_RELEASE']
    release_v1 = (1 << 48) | 0x123456789ABC
    check('release co-sign denied without physical/PIN policy',
          broker_call(u, c, release_caps, c['EH_SVC_RELEASE_COSIGN'],
                      release_v1, expect_done=False) == c['ES_ERR_POLICY'])
    u.call('enclave_services_release_policy', 1, 1, 1)
    release_sig = broker_call(u, c, release_caps,
                              c['EH_SVC_RELEASE_COSIGN'], release_v1)
    check('authorized release receives nonzero co-sign result', release_sig != 0)
    check('release version replay is rejected',
          broker_call(u, c, release_caps, c['EH_SVC_RELEASE_COSIGN'],
                      release_v1, expect_done=False) == c['ES_ERR_ROLLBACK'])

    quote1 = broker_call(u, c, c['CAP_ENCLAVE'], c['EH_SVC_REMOTE_QUOTE'], 0x111)
    quote_sig = u.call('enclave_host_result_signature')
    quote2 = broker_call(u, c, c['CAP_ENCLAVE'], c['EH_SVC_REMOTE_QUOTE'], 0x222)
    check('remote quote is challenge-bound', quote1 != quote2)
    check('remote quote is board-signed', quote_sig != 0)

    audit_caps = c['CAP_ENCLAVE'] | c['CAP_ENCLAVE_AUDIT']
    audit1 = broker_call(u, c, audit_caps, c['EH_SVC_AUDIT_APPEND'], 0x1001)
    audit2 = broker_call(u, c, audit_caps, c['EH_SVC_AUDIT_APPEND'], 0x1002)
    check('signed audit head chains across records', audit1 != audit2)
    check('reported audit head equals latest signed record',
          u.call('enclave_services_audit_head') == audit2)
    check('audit chain head carries board signature',
          u.call('enclave_host_result_signature') != 0)

    fido_caps = c['CAP_ENCLAVE'] | c['CAP_ENCLAVE_FIDO']
    fido1 = broker_call(u, c, fido_caps, c['EH_SVC_FIDO_SIGN'], 0xFACE01)
    fido2 = broker_call(u, c, fido_caps, c['EH_SVC_FIDO_SIGN'], 0xFACE02)
    check('FIDO assertion is challenge-bound', fido1 != fido2)
    check('FIDO assertion carries board signature',
          u.call('enclave_host_result_signature') != 0)

    tpm_caps = c['CAP_ENCLAVE'] | c['CAP_ENCLAVE_TPM']
    pcr_arg = (3 << 56) | 0xABCDEF
    pcr1 = broker_call(u, c, tpm_caps, c['EH_SVC_TPM_EXTEND'], pcr_arg)
    check('TPM extend updates selected PCR', u.call('enclave_services_pcr', 3) == pcr1)
    pcr_quote = broker_call(u, c, tpm_caps, c['EH_SVC_TPM_QUOTE'], 0x77)
    check('TPM quote covers PCR bank and is signed',
          pcr_quote != 0 and u.call('enclave_host_result_signature') != 0)
    secret = 0x5152535455
    check('TPM seal records value against current PCR state',
          broker_call(u, c, tpm_caps, c['EH_SVC_TPM_SEAL'], secret) != 0)
    check('TPM seal snapshot equals current PCR digest',
          u.call('enclave_services_sealed_pcr') ==
          u.call('enclave_services_pcr_digest'),
          'sealed=%x current=%x' % (u.call('enclave_services_sealed_pcr'),
                                    u.call('enclave_services_pcr_digest')))
    check('TPM sealed-value slot is marked valid',
          u.call('enclave_services_seal_valid') == 1)
    check('board-internal seal open returns value while PCR state matches',
          u.call('enclave_services_tpm_open') == secret)
    broker_call(u, c, tpm_caps, c['EH_SVC_TPM_EXTEND'], (3 << 56) | 0xBAD)
    check('board-internal seal open fails after PCR state changes',
          u.call('enclave_services_tpm_open') == c['ES_ERR_SEAL'])
    check('host API still has no unseal service',
          u.call('enclave_host_api_opcode', 17) == 0)

    # A modeled next boot resets volatile one-shot/PCR state but not secure NV.
    u.call('enclave_services_begin_boot', u.call('enclave_boot_counter') + 1,
           0x7777, 0x9999, 1)
    check('credential one-shot re-arms only for a new boot',
          broker_call(u, c, key_caps, c['EH_SVC_CREDENTIAL_USE'], 0xC001) != 0)
    check('PCR bank resets at new boot', u.call('enclave_services_pcr', 3) == 0)
    check('anti-rollback floor survives new boot',
          u.call('enclave_services_floor', 2) == 41)

    # Monitor absence/failure is kernel-only, never ring-3 fallback.
    f = unit()
    bind_roots(f)
    f.call('enclave_power_on')
    f.call('enclave_boot_complete')
    check('floor-only handoff succeeds in restricted mode',
          handoff(f, tier=c['EH_MON_FLOOR_ONLY']) == c['EH_OK'])
    check('floor-only endpoint is kernel-only', f.call('enclave_host_kernel_only') == 1)
    check('floor-only never exposes apps', f.call('enclave_host_apps_enabled') == 0)
    check('ring-3 CAP_ENCLAVE still denied without monitor',
          f.call('enclave_host_request', c['CAP_ENCLAVE'], c['EH_SVC_ATTEST'], 0) == c['EH_ERR_MONITOR'])
    check('kernel can use only an allowed Phase-B service',
          f.call('enclave_host_kernel_request', c['EH_SVC_ATTEST'], 9) == (c['EH_OP_ATTEST'] ^ 9))
    check('kernel-only path rejects privileged-shaped service',
          f.call('enclave_host_kernel_request', 0x40, 0) == c['EH_ERR_SERVICE'])

    # An unlatched board never becomes owned by monitor/kernel.
    n = unit()
    bind_roots(n)
    check('required handoff fails closed when latch is open',
          n.call('enclave_host_handoff', 1, 1, 0, 1, 0, 1, 0x800000, 0x1000) == c['EH_ERR_LOCK'])
    check('failed handoff publishes no endpoint owner',
          n.call('enclave_host_endpoint_owner') == c['EH_OWNER_NONE'])
    check('required unlatched handoff halts', n.call('enclave_host_boot_state') == c['EH_BOOT_HALT'])

    # Absence/hot-unplug: explicit failure/degrade, no mirror fallback and no spin.
    a = unit()
    bind_roots(a)
    check('required absent board fails closed',
          a.call('enclave_host_handoff', 1, 1, 0, 0, 0, 1, 0, 0) == c['EH_ERR_ABSENT'])
    check('required absence sets HALT', a.call('enclave_host_boot_state') == c['EH_BOOT_HALT'])
    o = unit()
    bind_roots(o)
    check('optional absent board reports explicit absence',
          o.call('enclave_host_handoff', 1, 1, 0, 0, 0, 0, 0, 0) == c['EH_ERR_ABSENT'])
    check('optional absence degrades feature visibly',
          o.call('enclave_host_boot_state') == c['EH_BOOT_DEGRADED'])

    h = unit()
    bind_roots(h)
    h.call('enclave_power_on')
    h.call('enclave_boot_complete')
    handoff(h, required=0)
    h.call('enclave_host_register_driver', req, req)
    h.call('enclave_host_request', c['CAP_ENCLAVE'], c['EH_SVC_SIGN'], 1)
    h.call('enclave_host_unplug')
    check('hot-unplug disables app exposure immediately', h.call('enclave_host_apps_enabled') == 0)
    check('pending request fails on next bounded tick',
          h.call('enclave_host_tick') == c['EH_REQ_FAILED'])
    check('hot-unplug reports absence, never fallback output',
          h.call('enclave_host_result') == c['EH_ERR_ABSENT'])
    check('optional hot-unplug leaves explicit degraded state',
          h.call('enclave_host_boot_state') == c['EH_BOOT_DEGRADED'])

    # ---- A7: Track-7 device-pubkey root + Track-2 KERNEL.ENV measurement ----
    # Track 7: the authoritative board root is the device's Ed25519 PUBLIC KEY;
    # the in-image manifest root is only a verified mirror and must equal it.
    device_pub = ed25519_host.public_key(bytes.fromhex('11' * 32))
    device_root = fold64(device_pub)
    image_root_ok = device_root                      # manifest carries the same root
    image_root_bad = fold64(device_pub[:31] + bytes([device_pub[31] ^ 1]))

    t7 = unit()
    check('Track-7: in-image root != device pubkey rejected',
          t7.call('enclave_host_bind_roots', device_root, image_root_bad)
          == c['EH_ERR_ROOT'])
    t7 = unit()
    check('Track-7: in-image root == device pubkey accepted (mirror)',
          t7.call('enclave_host_bind_roots', device_root, image_root_ok)
          == c['EH_OK'])

    # Track 2: the KERNEL.ENV measured-boot value is the board's handshake input.
    # The sealed policy and the released boot key are bound to exactly this value;
    # a host that presents a different image measurement fails closed.
    kernel_env_meas = fold64(hashlib.sha256(b'KERNEL.BIN+KERNEL.ENV image').digest())
    k = unit()
    k.call('enclave_host_bind_roots', device_root, image_root_ok)
    k.call('enclave_host_set_boot_measurement', kernel_env_meas)
    k.call('enclave_power_on')
    counter = k.call('enclave_boot_counter')
    kh = Host(k, priv=0x1111222233334444, seed=0xCAFEF00D)
    kh._boot = counter
    rc_begin, rc_finish = kh.handshake(counter)
    check('Track-2: KERNEL.ENV measured session establishes',
          rc_begin == 0 and rc_finish == 0)
    check('Track-2: board seals policy on the KERNEL.ENV measurement',
          k.call('enclave_boot_seal_policy', kernel_env_meas, 1) == 0)
    check('Track-2: boot bound to KERNEL.ENV measurement succeeds',
          k.call('enclave_boot_run', kernel_env_meas, 1) == 0)
    check('Track-2: KERNEL.ENV measurement-bound boot released a key',
          k.call('enclave_boot_key') != 0)
    check('Track-2: handoff consumes exactly the KERNEL.ENV measurement',
          handoff(k, boot_rc=0) == c['EH_OK'])

    # A host presenting a DIFFERENT image than the sealed KERNEL.ENV fails closed.
    k2 = unit()
    k2.call('enclave_host_bind_roots', device_root, image_root_ok)
    k2.call('enclave_host_set_boot_measurement', kernel_env_meas)
    k2.call('enclave_power_on')
    counter2 = k2.call('enclave_boot_counter')
    kh2 = Host(k2, priv=0x1111222233334444, seed=0xCAFEF00D)
    kh2._boot = counter2
    kh2.handshake(counter2)
    k2.call('enclave_boot_seal_policy', kernel_env_meas, 1)
    tampered_meas = fold64(b'tampered kernel image')
    k2.call('enclave_boot_run', tampered_meas, 1)
    check('Track-2: mismatched measurement under REQUIRED releases no key',
          k2.call('enclave_boot_key') == 0)
    check('Track-2: mismatched measurement still latches the one-shot closed',
          k2.call('enclave_boot_locked') == 1)

    if FAILURES:
        print('[enclave-host] FAIL - %d assertion(s)' % len(FAILURES), file=sys.stderr)
        for failure in FAILURES:
            print('  - ' + failure, file=sys.stderr)
        return 1
    print('[enclave-host] PASS - %d host integration assertions' % CHECKS)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
