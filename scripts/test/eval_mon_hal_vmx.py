#!/usr/bin/env python3
# Track-5 G1 (Intel VT-x) kernel-as-guest VMXON/VMCS-capture evaluation.
# Executes the REAL Track-5 GHL source (src/tools/security/mon_hal_vmx_vmcs.ghl)
# through the production GHL compiler frontend (same Unit as eval_mon_hal.py /
# eval_ed25519.py), so the logic under test is exactly what the .ghl declares.
#
# This is the `tested-tcg` leg of Track 5 G1 item 2 (the track doc's "QEMU vs
# real-HW test boundary"): logic ONLY - VMXON-region/VMCS-header math, VMCS
# field ENCODING, CR0/CR4 fixed-bit legality, and the kernel-as-guest capture
# invariant (guest mirrors the live kernel; host state is rooted in the monitor
# and disjoint from the guest). It proves NOTHING about hardware: there is no
# VMXON/VMPTRLD/VMWRITE/VMLAUNCH on TCG. The real launch + transparent exit is
# `tested-accel` (Track 5 G1 item 3) and is out of scope here, by design.

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.dirname(__file__))
from eval_ed25519 import Unit  # noqa: E402  reuse the production transpiler

VMX = os.path.join(ROOT, 'src', 'tools', 'security', 'mon_hal_vmx_vmcs.ghl')

FAILURES = []


def check(label, ok, detail=''):
    print('[mon_hal_vmx] %-54s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                          (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def main():
    u = Unit([VMX])
    print('[mon_hal_vmx] transpiled %d fns, %d consts (production gritc frontend)'
          % (len(u.fns), len(u.consts)))
    c = u.consts
    call = u.call

    check('VMX model version pinned', call('mon_hal_vmx_model_version') == 1)

    # -- 1. IA32_VMX_BASIC revision + region size -----------------------------
    REV = 0x12  # an example revision id
    # size 4096 in bits 44:32, revision in low bits.
    basic = REV | (4096 << c['VMX_BASIC_SIZE_SHIFT'])
    check('basic revision extracts low 31 bits',
          call('mon_hal_vmx_basic_revision', basic) == REV)
    check('shadow bit is masked out of the revision',
          call('mon_hal_vmx_basic_revision', basic | c['VMX_REGION_SHADOW_BIT']) == REV)
    check('page-aligned region of legal size -> ok',
          call('mon_hal_vmx_region_size_ok', basic, 0x200000) == 1)
    check('mis-aligned region -> rejected',
          call('mon_hal_vmx_region_size_ok', basic, 0x200001) == 0)
    check('zero-size region -> rejected',
          call('mon_hal_vmx_region_size_ok', REV, 0x200000) == 0)
    over = REV | (8192 << c['VMX_BASIC_SIZE_SHIFT'])
    check('over-page region size -> rejected',
          call('mon_hal_vmx_region_size_ok', over, 0x200000) == 0)

    # -- 2. VMXON region header -----------------------------------------------
    check('well-formed VMXON region -> ok',
          call('mon_hal_vmx_vmxon_region_ok', basic, 0x200000, REV) == 1)
    check('VMXON with shadow bit set -> rejected (shadow is VMCS-only)',
          call('mon_hal_vmx_vmxon_region_ok', basic, 0x200000,
               REV | c['VMX_REGION_SHADOW_BIT']) == 0)
    check('VMXON with wrong revision -> rejected',
          call('mon_hal_vmx_vmxon_region_ok', basic, 0x200000, REV + 1) == 0)
    check('VMXON in a mis-aligned page -> rejected',
          call('mon_hal_vmx_vmxon_region_ok', basic, 0x200008, REV) == 0)

    # -- 3. VMCS header (active guest VMCS is non-shadow) ----------------------
    check('non-shadow VMCS header, want_shadow=0 -> ok',
          call('mon_hal_vmx_vmcs_header_ok', basic, 0x201000, REV, 0) == 1)
    check('shadow-bit-set header but want_shadow=0 -> rejected',
          call('mon_hal_vmx_vmcs_header_ok', basic, 0x201000,
               REV | c['VMX_REGION_SHADOW_BIT'], 0) == 0)
    check('shadow VMCS header, want_shadow=1 -> ok',
          call('mon_hal_vmx_vmcs_header_ok', basic, 0x201000,
               REV | c['VMX_REGION_SHADOW_BIT'], 1) == 1)
    check('want_shadow=1 but bit clear -> rejected',
          call('mon_hal_vmx_vmcs_header_ok', basic, 0x201000, REV, 1) == 0)
    check('VMCS wrong revision -> rejected',
          call('mon_hal_vmx_vmcs_header_ok', basic, 0x201000, REV + 7, 0) == 0)

    # -- 4. CR0/CR4 fixed-bit legality ----------------------------------------
    # Model: bit0 must be 1 (FIXED0), bit31 must be 0 (clear in FIXED1).
    F0 = 0x00000001          # bit0 required-1
    F1 = 0x7FFFFFFF          # bit31 required-0 (clear in FIXED1)
    legal = 0x00000021       # bit0 set, bit31 clear
    illegal_missing = 0x00000020   # bit0 missing
    illegal_extra = 0x80000001     # bit31 set
    check('fix_cr0 sets a required-1 bit', call('mon_hal_vmx_fix_cr0', 0, F0, F1) == 1)
    check('fix_cr0 clears a required-0 bit',
          call('mon_hal_vmx_fix_cr0', 0x80000001, F0, F1) == 1)
    check('legal CR0 reported legal', call('mon_hal_vmx_cr_is_legal', legal, F0, F1) == 1)
    check('CR0 missing a required-1 -> illegal',
          call('mon_hal_vmx_cr_is_legal', illegal_missing, F0, F1) == 0)
    check('CR0 setting a required-0 -> illegal',
          call('mon_hal_vmx_cr_is_legal', illegal_extra, F0, F1) == 0)
    check('fix_cr4 legalizes is idempotent on a legal value',
          call('mon_hal_vmx_fix_cr4', legal, F0, F1) == legal)

    # -- 5. VMCS field encoding (Intel SDM packing) ---------------------------
    enc = lambda a, i, t, w: call('mon_hal_vmcs_encode', a, i, t, w)
    GUEST = c['VMCS_TYPE_GUEST']
    HOST = c['VMCS_TYPE_HOST']
    # GUEST_RIP is encoding 0x681E in the SDM: index 0x00F, type guest(2),
    # width natural(3), access full(0). Reconstruct and round-trip it.
    rip_g = enc(0, 0x00F, GUEST, 3)
    check('guest RIP encoding matches SDM 0x681E', rip_g == 0x681E)
    check('field access round-trips', call('mon_hal_vmcs_field_access', rip_g) == 0)
    check('field index round-trips', call('mon_hal_vmcs_field_index', rip_g) == 0x00F)
    check('field type round-trips (guest)',
          call('mon_hal_vmcs_field_type', rip_g) == GUEST)
    check('field width round-trips (natural)',
          call('mon_hal_vmcs_field_width', rip_g) == 3)
    check('guest field flagged guest', call('mon_hal_vmcs_field_is_guest', rip_g) == 1)
    check('guest field NOT flagged host', call('mon_hal_vmcs_field_is_host', rip_g) == 0)
    # HOST_RIP is 0x6C16 in the SDM: index 0x00B, type host(3), width natural(3).
    rip_h = enc(0, 0x00B, HOST, 3)
    check('host RIP encoding matches SDM 0x6C16', rip_h == 0x6C16)
    check('host field flagged host', call('mon_hal_vmcs_field_is_host', rip_h) == 1)
    check('host field NOT flagged guest', call('mon_hal_vmcs_field_is_guest', rip_h) == 0)
    # The high-access half of a 64-bit field sets bit 0.
    check('high-access bit set for 64-bit field high half',
          call('mon_hal_vmcs_field_access', enc(1, 0x000, GUEST, 1)) == 1)

    # -- 6. kernel-as-guest capture invariant ---------------------------------
    mirror = lambda cap, live: call('mon_hal_vmx_guest_field_mirrors', cap, live)
    check('guest field that mirrors the kernel -> ok', mirror(0x1234, 0x1234) == 1)
    check('guest field that diverges from the kernel -> rejected',
          mirror(0x1234, 0x1235) == 0)

    MON_B, MON_L = 0xF000000, 0x10000   # monitor carve-out
    MON_CR3, GUEST_CR3 = 0xAA000, 0xBB000
    in_mon = lambda a: call('mon_hal_vmx_host_field_in_monitor', a, MON_B, MON_L)
    check('host addr inside the monitor -> ok', in_mon(0xF008000) == 1)
    check('host addr below the monitor -> rejected', in_mon(0xEFFFFFF) == 0)
    check('host addr past the monitor -> rejected', in_mon(0xF010000) == 0)

    rooted = lambda rip, rsp, hcr3, gcr3: call(
        'mon_hal_vmx_host_state_rooted_in_monitor', rip, rsp, hcr3, gcr3,
        MON_B, MON_L, MON_CR3)
    check('host RIP+RSP in monitor, host CR3 = monitor CR3 != guest -> ok',
          rooted(0xF001000, 0xF00F000, MON_CR3, GUEST_CR3) == 1)
    check('host RIP pointing back into the guest -> rejected (exit must hit floor)',
          rooted(0x100000, 0xF00F000, MON_CR3, GUEST_CR3) == 0)
    check('host RSP outside the monitor -> rejected',
          rooted(0xF001000, 0x200000, MON_CR3, GUEST_CR3) == 0)
    check('host CR3 != monitor CR3 -> rejected',
          rooted(0xF001000, 0xF00F000, 0xCC000, GUEST_CR3) == 0)
    check('host CR3 == guest CR3 (would share address space) -> rejected',
          rooted(0xF001000, 0xF00F000, GUEST_CR3, GUEST_CR3) == 0)

    # -- 7. capture completeness ----------------------------------------------
    REQ = c['VMXCAP_REQUIRED']
    check('all required fields present -> complete',
          call('mon_hal_vmx_capture_complete', REQ) == 1)
    check('missing RFLAGS -> incomplete',
          call('mon_hal_vmx_capture_complete', REQ & ~c['VMXCAP_RFLAGS']) == 0)
    check('missing CR3 -> incomplete',
          call('mon_hal_vmx_capture_complete', REQ & ~c['VMXCAP_CR3']) == 0)
    check('empty capture -> incomplete', call('mon_hal_vmx_capture_complete', 0) == 0)
    check('extra bits set but all required present -> still complete',
          call('mon_hal_vmx_capture_complete', REQ | 0xF0000000) == 1)

    # -- 8. the folded make_guest gate ----------------------------------------
    def make_guest(**kw):
        return call('mon_hal_vmx_make_guest_ok',
                    kw.get('basic', basic),
                    kw.get('vmxon_pa', 0x200000), kw.get('vmxon_word', REV),
                    kw.get('vmcs_pa', 0x201000), kw.get('vmcs_word', REV),
                    kw.get('gcr0', legal), F0, F1,
                    kw.get('gcr4', legal), F0, F1,
                    kw.get('gpresent', REQ), kw.get('hpresent', REQ),
                    kw.get('hrip', 0xF001000), kw.get('hrsp', 0xF00F000),
                    kw.get('hcr3', MON_CR3), kw.get('gcr3', GUEST_CR3),
                    MON_B, MON_L, MON_CR3)

    check('fully valid kernel-as-guest capture -> make_guest ok', make_guest() == 1)
    check('illegal guest CR0 -> make_guest fails closed',
          make_guest(gcr0=illegal_missing) == 0)
    check('bad VMXON revision -> make_guest fails closed',
          make_guest(vmxon_word=REV + 1) == 0)
    check('incomplete guest capture -> make_guest fails closed',
          make_guest(gpresent=REQ & ~c['VMXCAP_RIP']) == 0)
    check('incomplete host capture -> make_guest fails closed',
          make_guest(hpresent=0) == 0)
    check('host RIP in the guest -> make_guest fails closed (no exit escape)',
          make_guest(hrip=0x100000) == 0)
    check('host CR3 == guest CR3 -> make_guest fails closed',
          make_guest(hcr3=GUEST_CR3) == 0)

    if FAILURES:
        sys.stderr.write('[mon_hal_vmx] FAIL - %d problem(s):\n' % len(FAILURES))
        for f in FAILURES:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[mon_hal_vmx] Track-5 G1 Intel VT-x: VMXON-region/VMCS-header math, '
          'VMCS field encoding, CR0/CR4 fixed-bit legality, and the kernel-as-'
          'guest capture invariant (guest mirrors kernel; host rooted in monitor) '
          'all enforced (modeled / tested-tcg; no HW launch claimed)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
