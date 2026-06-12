#!/usr/bin/env python3
# Track-3 P3 mapping: derive domain authority bitmasks from the REAL signed
# policy sources and prove the Track-3 invariants against them - the bitmasks
# are GENERATED, never hand-asserted.
#
# Real sources (none of these are test fixtures):
#   S1  src/include/syscall_caps.inc          - per-app MANIFEST_* capability
#       masks. These live inside KERNEL.BIN, which is admitted only under the
#       KERNEL.ENV 3-of threshold envelope, so they ARE signed policy.
#   S2  src/tools/security/policy_graph_check.ghl - the actual capability/
#       policy schema (8 domains x 8 capabilities) and the edge-validity +
#       threshold predicates, interpreted from the production GHL source.
#   S3  scripts/build/build_uefi.ps1 $KernelModules + each module's
#       `unsafe <cap>;` declarations + nk_pt_window bracketing - the compiler-
#       enforced authority a kernel GHL module can actually exercise.
#   S4  src/tools/security/threshold_check.ghl - the per-artifact-class quorum
#       policy: which signatures can change the TCB, and how many are needed.
#
# Mapping (documented in docs/track3-invariant-proofs.md):
#   policy-graph caps:  CAP_MEMORY -> AUTH_MEMORY_GRANT, CAP_DMA -> AUTH_DMA_MAP,
#                       CAP_POLICY_WRITE -> AUTH_INSTALL_POLICY,
#                       CAP_UPDATE / CAP_STORAGE -> AUTH_PERSIST,
#                       CAP_IPC / CAP_DEVICE / CAP_DIAGNOSTIC -> (none)
#   syscall caps:       CAP_FS_WRITE / CAP_FS_DELETE -> AUTH_PERSIST, rest none
#                       (no syscall cap grants identity-mint / policy-install /
#                       measurement-sign / DMA / memory-grant / global)
#   compiler caps:      kernel_io -> AUTH_DMA_MAP (port I/O can program device
#                       bus mastering); nk_pt_window bracketing ->
#                       AUTH_MEMORY_GRANT (a PTE writer); everything else
#                       (raw_mem / kernel_priv / kernel_int / implicit_extern)
#                       mints no cross-domain authority
#   artifact classes:   BOOT/KERNEL/HYPERVISOR/UPDATE/RECOVERY -> AUTH_GLOBAL,
#                       POLICY/CONFIG -> AUTH_INSTALL_POLICY,
#                       DRIVER -> AUTH_DMA_MAP, APP -> derived app-domain max
#
# Every check below evaluates the REAL invariant predicates from
# invariant_check.ghl (via the eval_invariants interpreter over the production
# compiler's parse) against the DERIVED masks. Any violation exits 1.

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_invariants  # noqa: E402  (reuses the production-compiler-backed interpreter)

ROOT = eval_invariants.ROOT
SYSCALL_CAPS = os.path.join(ROOT, 'src', 'include', 'syscall_caps.inc')
POLICY_GRAPH = os.path.join(ROOT, 'src', 'tools', 'security', 'policy_graph_check.ghl')
THRESHOLD = os.path.join(ROOT, 'src', 'tools', 'security', 'threshold_check.ghl')
BUILD_SCRIPT = os.path.join(ROOT, 'scripts', 'build', 'build_uefi.ps1')
POLICY_MODULE_DIR = os.path.join(ROOT, 'src', 'tools', 'security')

failures = []
checks = 0


def check(name, ok, detail=''):
    global checks
    checks += 1
    print("[derive]   %-58s [%s]%s" % (name, 'ok' if ok else 'FAIL',
                                       (' ' + detail if detail else '')))
    if not ok:
        failures.append(name + (': ' + detail if detail else ''))


# --- S1: per-app manifests from syscall_caps.inc -----------------------------

def parse_nasm_equs(path):
    """Parse `NAME equ EXPR` lines. %ifdef branches are UNIONED for duplicate
    names (the wider grant is the conservative input to a denial proof)."""
    names = {}
    equ_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+(.+)$')
    pending = []
    with open(path, 'r', encoding='utf-8') as fh:
        for raw in fh:
            line = raw.split(';', 1)[0].strip()
            m = equ_re.match(line)
            if m:
                pending.append((m.group(1), m.group(2).strip()))
    # iterate until fixpoint so forward refs resolve regardless of order
    progress = True
    while pending and progress:
        progress = False
        rest = []
        for name, expr in pending:
            try:
                val = eval(expr, {'__builtins__': {}}, dict(names))  # noqa: S307
            except Exception:
                rest.append((name, expr))
                continue
            if name in names:
                names[name] = names[name] | val  # union duplicate (%ifdef) defs
            else:
                names[name] = val
            progress = True
        pending = rest
    if pending:
        raise SystemExit("[derive] unresolvable equ expressions in %s: %s"
                         % (path, ', '.join(n for n, _ in pending)))
    return names


# --- S3: kernel module list + unsafe declarations ----------------------------

def kernel_module_list():
    mods = []
    pat = re.compile(r"@\{ src = 'src\\kernel\\grithlk\\([A-Za-z0-9_]+\.ghl)'")
    with open(BUILD_SCRIPT, 'r', encoding='utf-8') as fh:
        for line in fh:
            m = pat.search(line)
            if m:
                mods.append(m.group(1))
    if not mods:
        raise SystemExit("[derive] no $KernelModules entries found in build_uefi.ps1")
    return mods


def module_signals(path):
    caps = set()
    pte_writer = False
    cap_re = re.compile(r'^\s*unsafe\s+([a-z_]+)\s*;')
    with open(path, 'r', encoding='utf-8') as fh:
        for raw in fh:
            line = raw.split('#', 1)[0]
            m = cap_re.match(line)
            if m:
                caps.add(m.group(1))
            if 'nk_pt_window' in line or 'nk_window_open' in line:
                pte_writer = True
    return caps, pte_writer


def main():
    inv = eval_invariants.Module(eval_invariants.MODULE)
    graph = eval_invariants.Module(POLICY_GRAPH)
    thr = eval_invariants.Module(THRESHOLD)

    A = inv.consts  # AUTH_* bits from the real invariant kernel
    AUTH_ALL_SENSITIVE = (A['AUTH_MEMORY_GRANT'] | A['AUTH_MINT_IDENTITY'] |
                          A['AUTH_DMA_MAP'] | A['AUTH_PERSIST'] |
                          A['AUTH_SIGN_MEASUREMENT'] | A['AUTH_INSTALL_POLICY'] |
                          A['AUTH_GLOBAL'])

    # ----- S2: derive per-domain authority from the real policy graph -------
    G = graph.consts
    graph_cap_auth = {
        G['CAP_IPC']: 0,
        G['CAP_MEMORY']: A['AUTH_MEMORY_GRANT'],
        G['CAP_DMA']: A['AUTH_DMA_MAP'],
        G['CAP_DEVICE']: 0,
        G['CAP_UPDATE']: A['AUTH_PERSIST'],
        G['CAP_STORAGE']: A['AUTH_PERSIST'],
        G['CAP_DIAGNOSTIC']: 0,
        G['CAP_POLICY_WRITE']: A['AUTH_INSTALL_POLICY'],
    }
    domains = {name: val for name, val in G.items() if name.startswith('DOMAIN_')}
    caps = sorted(graph_cap_auth)

    print("[derive] S2 policy-graph domain authority (derived via "
          "security_policy_graph_edge_is_valid):")
    domain_mask = {}
    domain_caps_nothresh = {}
    for dname in sorted(domains, key=domains.get):
        d = domains[dname]
        mask = 0
        caps_nt = set()
        for c in caps:
            holds = False
            for dst in domains.values():
                for t in (0, 1):
                    if graph.call('security_policy_graph_edge_is_valid',
                                  [d, dst, c, 1, 1, t, 0, 1]) == 1:
                        holds = True
                        if t == 0:
                            caps_nt.add(c)
            if holds:
                mask |= graph_cap_auth[c]
        domain_mask[dname] = mask
        domain_caps_nothresh[dname] = caps_nt
        print("[derive]     %-16s auth=0x%02x  caps_without_threshold={%s}"
              % (dname, mask, ','.join(str(c) for c in sorted(caps_nt))))

    # No graph capability maps to identity-mint, measurement-sign, or global:
    # those authorities are not mintable through ANY policy edge.
    for dname, mask in domain_mask.items():
        for bit_name in ('AUTH_MINT_IDENTITY', 'AUTH_SIGN_MEASUREMENT', 'AUTH_GLOBAL'):
            check("graph %s lacks %s (inv_lacks_authority)" % (dname, bit_name),
                  inv.call('inv_lacks_authority', [mask, A[bit_name]]) == 1)

    # Threshold-gated capabilities (per the REAL requires_threshold predicate)
    # must be unobtainable through any edge when threshold approval is absent.
    # Checked per capability - two capabilities may map to the same authority
    # bit (CAP_UPDATE vs CAP_STORAGE -> AUTH_PERSIST) with different gating.
    for c in caps:
        if graph.call('security_policy_graph_requires_threshold', [c]) == 1:
            for dname, caps_nt in domain_caps_nothresh.items():
                check("threshold-gated cap %d unobtainable by %s w/o threshold"
                      % (c, dname), c not in caps_nt)

    # The app domain can never obtain policy-install or DMA authority at all.
    check("graph DOMAIN_APP lacks AUTH_INSTALL_POLICY",
          inv.call('inv_lacks_authority',
                   [domain_mask['DOMAIN_APP'], A['AUTH_INSTALL_POLICY']]) == 1)
    check("graph DOMAIN_APP lacks AUTH_DMA_MAP",
          inv.call('inv_lacks_authority',
                   [domain_mask['DOMAIN_APP'], A['AUTH_DMA_MAP']]) == 1)

    # Unsigned endpoints can never form a valid edge (binds
    # INV-POLICY-SIGNED-ONLY to the real schema): exhaustive over the schema.
    unsigned_ok = True
    for src in domains.values():
        for dst in domains.values():
            for c in caps:
                for t in (0, 1):
                    for ss, ds in ((0, 1), (1, 0), (0, 0)):
                        if graph.call('security_policy_graph_edge_is_valid',
                                      [src, dst, c, ss, ds, t, 0, 1]) != 0:
                            unsigned_ok = False
    check("no unsigned endpoint forms a valid edge (policy is signed-only)",
          unsigned_ok)
    check("inv_policy_loader_signed_only rejects unsigned install",
          inv.call('inv_policy_loader_signed_only', [0]) == 0)

    # ----- S1: derive per-app authority from the signed manifest table ------
    equs = parse_nasm_equs(SYSCALL_CAPS)
    cap_fs_write = equs['CAP_FS_WRITE']
    cap_fs_delete = equs['CAP_FS_DELETE']
    manifests = {n: v for n, v in equs.items() if n.startswith('MANIFEST_')}
    if not manifests:
        raise SystemExit("[derive] no MANIFEST_* rows parsed from syscall_caps.inc")

    print("[derive] S1 app manifest authority (derived from %d signed manifests):"
          % len(manifests))
    denied_for_apps = ('AUTH_GLOBAL', 'AUTH_INSTALL_POLICY', 'AUTH_SIGN_MEASUREMENT',
                       'AUTH_MINT_IDENTITY', 'AUTH_DMA_MAP', 'AUTH_MEMORY_GRANT')
    for name in sorted(manifests):
        m = manifests[name]
        auth = 0
        if m & (cap_fs_write | cap_fs_delete):
            auth |= A['AUTH_PERSIST']
        print("[derive]     %-26s caps=0x%04x -> auth=0x%02x" % (name, m, auth))
        for bit_name in denied_for_apps:
            check("%s lacks %s" % (name, bit_name),
                  inv.call('inv_lacks_authority', [auth, A[bit_name]]) == 1)
        check("%s authority within derived DOMAIN_APP bound (inv_subset)" % name,
              inv.call('inv_subset', [auth, domain_mask['DOMAIN_APP']]) == 1)

    # ----- S3: derive kernel-module authority from compiler capabilities ----
    mods = kernel_module_list()
    print("[derive] S3 kernel GHL modules (%d in the signed image):" % len(mods))
    mod_auth = {}
    for mod in mods:
        path = os.path.join(ROOT, 'src', 'kernel', 'grithlk', mod)
        if not os.path.isfile(path):
            failures.append("build-list module missing on disk: %s" % mod)
            continue
        ucaps, pte_writer = module_signals(path)
        auth = 0
        if 'kernel_io' in ucaps:
            auth |= A['AUTH_DMA_MAP']
        if pte_writer:
            auth |= A['AUTH_MEMORY_GRANT']
        mod_auth[mod] = auth
        if auth:
            print("[derive]     %-28s unsafe={%s}%s -> auth=0x%02x"
                  % (mod, ','.join(sorted(ucaps)),
                     ' +nk_pt_window' if pte_writer else '', auth))

    # Component bindings: each named invariant's compromised component bound to
    # its real module(s). A binding naming a module absent from the signed
    # build list is itself a failure (bindings cannot go stale).
    bindings = {
        'scheduler (INV-SCHED-NO-MEMORY)':
            (('frame_pacing.ghl', 'cpu_acct.ghl'),
             lambda a: inv.call('inv_scheduler_no_memory_grant', [a]) == 1),
        'ipc/dispatch (INV-IPC-NO-FORGE)':
            (('input_dispatch.ghl', 'net_dhcp_dispatch.ghl'),
             lambda a: inv.call('inv_ipc_no_identity_forge', [a]) == 1),
    }
    for label, (members, pred) in bindings.items():
        for mod in members:
            check("binding %s: %s is in the signed build list" % (label, mod),
                  mod in mod_auth)
        union = 0
        for mod in members:
            union |= mod_auth.get(mod, AUTH_ALL_SENSITIVE)  # missing = fail closed
        check("derived %s authority satisfies its invariant" % label, pred(union),
              "auth=0x%02x" % union)

    # Modules holding derived AUTH_DMA_MAP are admissible only because the
    # image they ship in is threshold-admitted (S4 below): the real predicate
    # must accept with the grant present and reject without it.
    for mod, auth in sorted(mod_auth.items()):
        if auth & A['AUTH_DMA_MAP']:
            check("%s DMA authority requires a grant (accept w/ grant)" % mod,
                  inv.call('inv_driver_no_dma_mint', [auth, 1]) == 1)
            check("%s DMA authority requires a grant (reject w/o grant)" % mod,
                  inv.call('inv_driver_no_dma_mint', [auth, 0]) == 0)
    # PTE writers (AUTH_MEMORY_GRANT) likewise ride the threshold-admitted
    # image; the persistence invariant must reject them without threshold.
    for mod, auth in sorted(mod_auth.items()):
        if auth & A['AUTH_MEMORY_GRANT']:
            check("%s PTE-writer persists only under threshold" % mod,
                  inv.call('inv_pt_no_persist_without_threshold',
                           [auth | A['AUTH_PERSIST'], 0]) == 0)

    # The Track-3 enforcement modules themselves must hold ZERO compiler
    # authority (they compile --deny-unsafe; verify at the source level too).
    for fname in sorted(os.listdir(POLICY_MODULE_DIR)):
        if not fname.endswith('.ghl'):
            continue
        ucaps, pte = module_signals(os.path.join(POLICY_MODULE_DIR, fname))
        check("policy module %s holds no unsafe capability" % fname,
              not ucaps and not pte)

    # ----- S4: signed artifacts -> TCB authority, threshold-gated -----------
    app_max = 0
    for name in sorted(manifests):
        m = manifests[name]
        if m & (cap_fs_write | cap_fs_delete):
            app_max |= A['AUTH_PERSIST']
    class_auth = {
        1: ('ART_BOOT', A['AUTH_GLOBAL']),
        2: ('ART_KERNEL', A['AUTH_GLOBAL']),
        3: ('ART_HYPERVISOR', A['AUTH_GLOBAL']),
        4: ('ART_DRIVER', A['AUTH_DMA_MAP']),
        5: ('ART_APP', app_max),
        6: ('ART_POLICY', A['AUTH_INSTALL_POLICY']),
        7: ('ART_CONFIG', A['AUTH_INSTALL_POLICY']),
        8: ('ART_UPDATE', A['AUTH_GLOBAL']),
        9: ('ART_RECOVERY', A['AUTH_GLOBAL']),
    }
    print("[derive] S4 artifact-class TCB authority vs the real quorum table:")
    all_roles = thr.consts['THRESHOLD_ALL_ROLES']
    for kind in sorted(class_auth):
        cname, auth = class_auth[kind]
        min_count = thr.call('security_threshold_class_min_count', [kind])
        req = thr.call('security_threshold_class_required_mask', [kind])
        print("[derive]     %-14s auth=0x%02x min_count=%d required_mask=0x%02x"
              % (cname, auth, min_count, req))
        # No artifact class admits a single signature: every TCB change is
        # multi-party. threshold_met derives from the REAL class table.
        check("%s requires a multi-party quorum (min_count >= 2)" % cname,
              min_count >= 2, "min_count=%d" % min_count)
        check("%s class rule is self-consistent (quorum_ok)" % cname,
              thr.call('security_threshold_class_quorum_ok',
                       [kind, min_count, all_roles, req]) == 1)
        threshold_met = 1 if min_count >= 2 else 0
        for bit_name in ('AUTH_GLOBAL', 'AUTH_INSTALL_POLICY'):
            bit = A[bit_name]
            if auth & bit:
                check("%s %s only under threshold (accept)" % (cname, bit_name),
                      inv.call('inv_requires_threshold', [auth, bit, threshold_met]) == 1)
                check("%s %s only under threshold (reject single-key)" % (cname, bit_name),
                      inv.call('inv_requires_threshold', [auth, bit, 0]) == 0)

    # ----- verdict -----------------------------------------------------------
    if failures:
        sys.stderr.write("[derive] FAIL - %d problem(s) of %d checks:\n"
                         % (len(failures), checks))
        for f in failures:
            sys.stderr.write("  - %s\n" % f)
        return 1
    print("[derive] all %d policy-derived authority checks passed "
          "(masks generated from real signed policy, evaluated against the "
          "real GHL invariant predicates)" % checks)
    return 0


if __name__ == '__main__':
    sys.exit(main())
