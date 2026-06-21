#!/usr/bin/env python3
# Track-5 monitor-HAL evaluation: executes the REAL Track-5 GHL sources
# (src/tools/security/mon_hal_detect.ghl + mon_hal.ghl) through the production
# GHL compiler's own lexer/parser/transpiler - the same Unit used by
# eval_ed25519.py / eval_enclave.py, so the logic under test is exactly what the
# .ghl declares and nothing is silently skipped.
#
# This is the `tested-tcg` verification leg called out in the Track 5 doc's
# "QEMU vs real-HW test boundary": logic ONLY - DETECT predicates, back-end
# SELECT + FALLBACK, the vendor-neutral second-stage (EPT/NPT/stage-2/G-stage)
# identity-map + W^X + monitor-carve-out MATH, and the IOMMU DMA-confinement
# MATH. It proves NONE of the hardware enforces anything (TCG runs no root mode
# and no IOMMU); a real second-stage violation exit is `tested-accel` and a real
# DMA fault is `tested-hw`. Those are explicitly out of scope here, by design.
#
# Suite mirrors the track doc:
#   1. const-drift guard (tier/arch ids match across both modules + this harness)
#   2. per-vendor DETECT incl. firmware-fused-off edge cases
#   3. back-end SELECT + FALLBACK (floor-only is the only TCG-reachable leg)
#   4. enter_root dispatch (floor vs modeled vs bad-tier; fail-closed)
#   5. G1 second-stage: identity perms, monitor carve-out (NOT-PRESENT) negative
#      test, W^X enforced independently of the guest (write .text / exec data)
#   6. G2 IOMMU: in-grant ok, out-of-range fault, perm fault, default-deny

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.dirname(__file__))
from eval_ed25519 import Unit  # noqa: E402  reuse the production transpiler

DETECT = os.path.join(ROOT, 'src', 'tools', 'security', 'mon_hal_detect.ghl')
HAL = os.path.join(ROOT, 'src', 'tools', 'security', 'mon_hal.ghl')

FAILURES = []


def check(label, ok, detail=''):
    print('[mon_hal] %-56s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                      (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def main():
    u = Unit([DETECT, HAL])
    print('[mon_hal] transpiled %d fns, %d consts (production gritc frontend)'
          % (len(u.fns), len(u.consts)))
    c = u.consts

    # -- 0. const-drift guard: tier/arch ids must agree across both modules ----
    ARCH_X86, ARCH_ARM, ARCH_RISCV = 0, 1, 2
    FLOOR, VTX, SVM, EL2, RVH = 0, 1, 2, 3, 4
    check('arch/tier ids match the modules', all([
        c['MONHAL_ARCH_X86'] == ARCH_X86, c['MONHAL_ARCH_ARM'] == ARCH_ARM,
        c['MONHAL_ARCH_RISCV'] == ARCH_RISCV,
        c['MONHAL_TIER_FLOOR_ONLY'] == FLOOR, c['MONHAL_TIER_INTEL_VTX'] == VTX,
        c['MONHAL_TIER_AMD_SVM'] == SVM, c['MONHAL_TIER_ARM_EL2'] == EL2,
        c['MONHAL_TIER_RISCV_H'] == RVH,
    ]))
    check('mon_hal ABI version pinned', u.call('mon_hal_abi_version') == 1)

    # -- 1. Intel VT-x detect, incl. firmware-fused-off -----------------------
    VMX = c['CPUID1_ECX_VMX']
    LOCK = c['FEATCTL_LOCK']
    OSMX = c['FEATCTL_VMXON_OUTSIDE_SMX']
    check('VMX absent -> not usable', u.call('mon_hal_vmx_usable', 0, 0) == 0)
    check('VMX present + MSR unlocked -> usable (OS owns it)',
          u.call('mon_hal_vmx_usable', VMX, 0) == 1)
    check('VMX present + locked WITH outside-SMX -> usable',
          u.call('mon_hal_vmx_usable', VMX, LOCK | OSMX) == 1)
    check('VMX present + locked WITHOUT enable -> firmware fused off',
          u.call('mon_hal_vmx_usable', VMX, LOCK) == 0)
    # EPT / unrestricted-guest from the PROCBASED_CTLS2 high dword.
    EPT = c['VMX_PROCBASED2_HI_EPT']
    URG = c['VMX_PROCBASED2_HI_UNRESTRICTED']
    check('EPT advertised in CTLS2 hi', u.call('mon_hal_vmx_ept_supported', EPT) == 1)
    check('no EPT bit -> unsupported', u.call('mon_hal_vmx_ept_supported', 0) == 0)
    check('unrestricted-guest advertised',
          u.call('mon_hal_vmx_unrestricted_guest', URG) == 1)

    # -- 2. AMD SVM detect ----------------------------------------------------
    SVMB = c['CPUID_AMD_EXT1_ECX_SVM']
    SVMDIS = c['VM_CR_SVMDIS']
    check('SVM absent -> not usable', u.call('mon_hal_svm_usable', 0, 0) == 0)
    check('SVM present + not disabled -> usable',
          u.call('mon_hal_svm_usable', SVMB, 0) == 1)
    check('SVM present + VM_CR.SVMDIS -> fused off',
          u.call('mon_hal_svm_usable', SVMB, SVMDIS) == 0)

    # -- 3. ARM EL2 / VHE + RISC-V H ------------------------------------------
    # ID_AA64PFR0_EL1.EL2 is bits 11:8; a nonzero field means EL2 implemented.
    check('ARM EL2 implemented (field=1)',
          u.call('mon_hal_arm_el2_usable', 1 << 8) == 1)
    check('ARM EL2 absent (field=0)', u.call('mon_hal_arm_el2_usable', 0) == 0)
    check('ARM VHE present (MMFR1.VH=1)',
          u.call('mon_hal_arm_vhe_present', 1 << 8) == 1)
    check('RISC-V H-ext present (misa bit 7)',
          u.call('mon_hal_riscv_h_usable', c['MISA_H_BIT']) == 1)
    check('RISC-V H-ext absent', u.call('mon_hal_riscv_h_usable', 0) == 0)

    # -- 4. back-end SELECT + FALLBACK ----------------------------------------
    sel = lambda *a: u.call('mon_hal_select_backend', *a)
    check('x86 + VMX -> Intel VT-x', sel(ARCH_X86, 1, 0, 0, 0) == VTX)
    check('x86 + SVM only -> AMD SVM', sel(ARCH_X86, 0, 1, 0, 0) == SVM)
    check('x86 + neither -> floor-only', sel(ARCH_X86, 0, 0, 0, 0) == FLOOR)
    check('x86 prefers VT-x when both advertise', sel(ARCH_X86, 1, 1, 0, 0) == VTX)
    check('ARM + EL2 -> ARM EL2 tier', sel(ARCH_ARM, 0, 0, 1, 0) == EL2)
    check('ARM, no EL2 -> floor-only', sel(ARCH_ARM, 0, 0, 0, 0) == FLOOR)
    check('RISC-V + H -> RISC-V H tier', sel(ARCH_RISCV, 0, 0, 0, 1) == RVH)
    check('RISC-V, no H -> floor-only', sel(ARCH_RISCV, 0, 0, 0, 0) == FLOOR)
    check('unknown arch -> floor-only (fail closed)', sel(99, 1, 1, 1, 1) == FLOOR)
    # status mapping: floor is reported as a distinct "software floor", never OFF.
    ST_ACTIVE = c['MONHAL_ST_ACTIVE']
    ST_FLOOR = c['MONHAL_ST_FLOOR_ONLY']
    check('floor tier -> FLOOR_ONLY status (not an error)',
          u.call('mon_hal_status', FLOOR) == ST_FLOOR)
    check('virt tier -> ACTIVE status', u.call('mon_hal_status', VTX) == ST_ACTIVE)

    # -- 5. enter_root dispatch (fail closed on a bad tier) -------------------
    E_FLOOR = c['MONHAL_ENTER_FLOOR']
    E_MOD = c['MONHAL_ENTER_MODELED']
    E_BAD = c['MONHAL_ENTER_BADTIER']
    check('enter_root(floor) -> software floor stands',
          u.call('mon_hal_enter_root', FLOOR) == E_FLOOR)
    for t in (VTX, SVM, EL2, RVH):
        check('enter_root(virt tier %d) -> modeled' % t,
              u.call('mon_hal_enter_root', t) == E_MOD)
    check('enter_root(unknown tier) -> bad-tier (fail closed)',
          u.call('mon_hal_enter_root', 99) == E_BAD)

    # -- 6. G2 IOMMU detect (DMAR/IVRS/IORT/RV node) --------------------------
    io = lambda *a: u.call('mon_hal_iommu_usable', *a)
    check('x86 + DMAR (VT-d) -> IOMMU usable', io(ARCH_X86, 1, 0, 0, 0) == 1)
    check('x86 + IVRS (AMD-Vi) -> IOMMU usable', io(ARCH_X86, 0, 1, 0, 0) == 1)
    check('x86 + no table -> no IOMMU (residual undefended)',
          io(ARCH_X86, 0, 0, 0, 0) == 0)
    check('ARM + IORT SMMUv3 -> IOMMU usable', io(ARCH_ARM, 0, 0, 1, 0) == 1)
    check('RISC-V + IOMMU node -> usable', io(ARCH_RISCV, 0, 0, 0, 1) == 1)
    check('RISC-V, no node -> no IOMMU', io(ARCH_RISCV, 0, 0, 0, 0) == 0)

    # -- 7. G1 second-stage identity map + W^X + carve-out --------------------
    PRES, R, W, X = c['S2_PRESENT'], c['S2_R'], c['S2_W'], c['S2_X']
    ACC_R, ACC_W, ACC_X = c['ACC_R'], c['ACC_W'], c['ACC_X']
    OK, VIO = c['MONHAL_S2_OK'], c['MONHAL_S2_VIOLATION']
    # Layout: monitor carve-out [0x1000,0x2000); guest .text [0x10000,0x11000).
    MON_B, MON_L = 0x1000, 0x1000
    TXT_B, TXT_L = 0x10000, 0x1000
    perms = lambda gpa: u.call('mon_hal_s2_map_perms', gpa, MON_B, MON_L, TXT_B, TXT_L)
    s2 = lambda p, acc: u.call('mon_hal_s2_check', p, acc)

    # (a) monitor / compartment carve-out: NOT-PRESENT in the guest map.
    check('monitor page perms == 0 (carved out, not RO)', perms(0x1000) == 0)
    check('guest READ of a monitor page -> second-stage violation',
          s2(perms(0x1500), ACC_R) == VIO)
    check('guest WRITE of a monitor page -> violation',
          s2(perms(0x1500), ACC_W) == VIO)
    check('guest region predicate flags the carve-out',
          u.call('mon_hal_region_is_monitor', 0x1800, MON_B, MON_L) == 1)
    check('predicate excludes the byte past the carve-out',
          u.call('mon_hal_region_is_monitor', 0x2000, MON_B, MON_L) == 0)

    # (b) guest .text: R|X, never W -> W^X enforced at the 2nd stage even if the
    #     guest cleared CR0.WP (the floor-disable attack).
    tperm = perms(0x10000)
    check('.text second-stage perms = PRESENT|R|X (no W)',
          tperm == (PRES + R + X))
    check('.text execute allowed', s2(tperm, ACC_X) == OK)
    check('.text read allowed', s2(tperm, ACC_R) == OK)
    check('WRITE to .text -> violation regardless of guest WP (W^X)',
          s2(tperm, ACC_W) == VIO)

    # (c) data page: R|W, never X -> no W->X escalation.
    dperm = perms(0x20000)
    check('data second-stage perms = PRESENT|R|W (no X)',
          dperm == (PRES + R + W))
    check('data write allowed', s2(dperm, ACC_W) == OK)
    check('EXECUTE from a data page -> violation (no W->X)',
          s2(dperm, ACC_X) == VIO)
    check('not-present entry faults every access',
          s2(0, ACC_R) == VIO and s2(0, ACC_W) == VIO and s2(0, ACC_X) == VIO)

    # -- 8. G2 IOMMU DMA-confinement math -------------------------------------
    DMA_R, DMA_W = c['DMA_R'], c['DMA_W']
    D_OK = c['MONHAL_DMA_OK']
    D_NG = c['MONHAL_DMA_FAULT_NOGRANT']
    D_RG = c['MONHAL_DMA_FAULT_RANGE']
    D_PM = c['MONHAL_DMA_FAULT_PERM']
    GB, GL = 0x40000, 0x1000   # device grant: one 4 KiB buffer
    tr = lambda iova, ln, perms_, acc: u.call(
        'mon_hal_iommu_translate', iova, ln, GB, GL, perms_, acc)
    check('in-grant read DMA -> ok', tr(0x40000, 0x100, DMA_R | DMA_W, ACC_R) == D_OK)
    check('in-grant write DMA -> ok', tr(0x40800, 0x100, DMA_R | DMA_W, ACC_W) == D_OK)
    check('DMA starting below the grant -> range fault',
          tr(0x3FF00, 0x100, DMA_R | DMA_W, ACC_R) == D_RG)
    check('DMA spilling past the grant end -> range fault',
          tr(0x40F00, 0x400, DMA_R | DMA_W, ACC_W) == D_RG)
    check('write DMA to a read-only grant -> perm fault',
          tr(0x40000, 0x100, DMA_R, ACC_W) == D_PM)
    check('read DMA from a write-only grant -> perm fault',
          tr(0x40000, 0x100, DMA_W, ACC_R) == D_PM)
    check('device with NO grant (len 0) -> default-deny no-grant fault',
          u.call('mon_hal_iommu_translate', 0x40000, 0x100, 0, 0,
                 DMA_R | DMA_W, ACC_R) == D_NG)

    if FAILURES:
        sys.stderr.write('[mon_hal] FAIL - %d problem(s):\n' % len(FAILURES))
        for f in FAILURES:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[mon_hal] Track-5 monitor-HAL: detect, select+fallback, enter_root '
          'dispatch, second-stage W^X+carve-out, and IOMMU DMA-confinement math '
          'all enforced (modeled / tested-tcg; no HW enforcement claimed)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
