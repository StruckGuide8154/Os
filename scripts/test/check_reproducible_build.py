#!/usr/bin/env python3
# =============================================================================
# check_reproducible_build.py - reproducible-build attestation (Track 1, sec->10).
#
# Beyond-zero-trust Track 1 (docs/track1-repo-enforcement-todo.md, "Path to
# 10/10"): "byte-identical rebuild from a pinned toolchain, gated in CI; a
# non-reproducible build fails the gate."
#
# The trusted path is the GHL/GritHLK source compiled by the pinned gritc.py
# (see tools/security/toolchain_pins.txt). This evaluator proves the
# compiler output is REPRODUCIBLE in two independent senses, both fast enough
# to run on every PR (no full nasm image link required):
#
#   1. SELF-CONSISTENCY (double-compile): every pinned trusted-path module is
#      compiled TWICE into separate temp files; the two outputs must be
#      byte-identical. A compiler with embedded timestamps / dict-ordering /
#      address nondeterminism fails here.
#
#   2. DRIFT-VS-RECORDED (frozen digest): each module's output sha256 is
#      compared against a frozen digest recorded in
#      tools/security/reproducible_digests.txt. A change to gritc.py (or a
#      pinned module) that changes emitted bytes WITHOUT a reviewed re-bake of
#      the digest manifest fails here. This is what makes a non-reproducible /
#      unexpected build fail the gate rather than silently shipping.
#
# The digest manifest is content-addressed to the pinned compiler: it also
# records the gritc.py sha256, so a recorded digest set produced by a different
# compiler is rejected up front (you cannot mix a re-baked digest list with an
# unpinned compiler).
#
# Re-bake after an intentional, reviewed compiler/module change:
#     python scripts/test/check_reproducible_build.py --update
# then review + commit tools/security/reproducible_digests.txt.
#
# Exit 0 = reproducible; exit 1 = a divergence (fails CI).
# =============================================================================

import hashlib
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
GRITC = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler', 'gritc.py')
LIBDIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'lib')
DIGEST_MANIFEST = os.path.join(ROOT, 'tools', 'security', 'reproducible_digests.txt')

# Pinned trusted-path modules whose compiler output must be reproducible.
# Kept small + representative (security policy kernels + a couple of GritHLK
# kernel modules) so the gate runs in seconds on every PR while still exercising
# the real codegen paths that ship. Each entry: (repo-relative source, extra
# gritc args beyond the common set).
COMMON_ARGS = ['-L', LIBDIR, '--embed', '--target', 'kernel', '--forbid-asm']
PINNED_MODULES = [
    ('src/tools/security/signed_envelope.ghl', ['--deny-unsafe']),
    ('src/tools/security/signed_artifact_check.ghl', ['--deny-unsafe']),
    ('src/tools/security/threshold_check.ghl', ['--deny-unsafe']),
    ('src/kernel/grithlk/envelope_reader.ghl', []),
    ('src/kernel/grithlk/ed25519_check.ghl', []),
    ('src/kernel/grithlk/crypto.ghl', []),
]


def gritc_sha256():
    with open(GRITC, 'rb') as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def compile_module(src_rel, extra_args, out_path):
    src = os.path.join(ROOT, src_rel.replace('/', os.sep))
    cmd = [sys.executable, GRITC, src, '-o', out_path] + COMMON_ARGS + extra_args
    proc = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        sys.stdout.write(proc.stdout.decode('utf-8', 'replace'))
        raise SystemExit("[repro] FAIL: compile error for %s" % src_rel)
    with open(out_path, 'rb') as fh:
        data = fh.read()
    return hashlib.sha256(data).hexdigest()


def build_digests():
    """Double-compile every pinned module; assert self-consistency; return the
    {src_rel: sha256} map."""
    digests = {}
    tmp = tempfile.mkdtemp(prefix='repro-')
    try:
        for src_rel, extra in PINNED_MODULES:
            a = os.path.join(tmp, 'a.asm')
            b = os.path.join(tmp, 'b.asm')
            ha = compile_module(src_rel, extra, a)
            hb = compile_module(src_rel, extra, b)
            if ha != hb:
                raise SystemExit(
                    "[repro] FAIL: %s is NON-REPRODUCIBLE across two compiles "
                    "(%s != %s)" % (src_rel, ha, hb))
            digests[src_rel] = ha
            print("[repro] reproducible  %s  %s" % (ha[:16], src_rel))
    finally:
        for f in ('a.asm', 'b.asm'):
            p = os.path.join(tmp, f)
            if os.path.exists(p):
                os.remove(p)
        os.rmdir(tmp)
    return digests


def load_manifest():
    """Returns (gritc_pin, {src_rel: sha256}). Missing -> (None, {})."""
    if not os.path.exists(DIGEST_MANIFEST):
        return None, {}
    gritc_pin = None
    recorded = {}
    with open(DIGEST_MANIFEST, 'r') as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            cols = [c.strip() for c in s.split('|')]
            if len(cols) != 3:
                raise SystemExit("[repro] FAIL: malformed digest line: %s" % s)
            kind, key, val = cols
            if kind == 'compiler':
                gritc_pin = val
            elif kind == 'module':
                recorded[key] = val
            else:
                raise SystemExit("[repro] FAIL: unknown digest kind '%s'" % kind)
    return gritc_pin, recorded


def write_manifest(gritc_pin, digests):
    lines = [
        '# =============================================================================',
        '# reproducible_digests.txt - frozen reproducible-build digest set (Track 1).',
        '#',
        '# Recorded sha256 of the pinned trusted-path GHL modules as emitted by the',
        '# pinned gritc.py. check_reproducible_build.py double-compiles each module',
        '# (self-consistency) AND compares its digest against the value frozen here',
        '# (drift-vs-recorded). Re-bake only via:',
        '#     python scripts/test/check_reproducible_build.py --update',
        '# Format: compiler | gritc.py | <sha256>   and   module | <path> | <sha256>',
        '# =============================================================================',
        'compiler | gritc.py | %s' % gritc_pin,
    ]
    for src_rel, _ in PINNED_MODULES:
        lines.append('module | %s | %s' % (src_rel, digests[src_rel]))
    with open(DIGEST_MANIFEST, 'w', newline='\n') as fh:
        fh.write('\n'.join(lines) + '\n')


def main():
    update = '--update' in sys.argv[1:]
    live_gritc = gritc_sha256()
    digests = build_digests()

    if update:
        write_manifest(live_gritc, digests)
        print("[repro] re-baked %s" % os.path.relpath(DIGEST_MANIFEST, ROOT))
        return 0

    gritc_pin, recorded = load_manifest()
    if not recorded:
        raise SystemExit(
            "[repro] FAIL: digest manifest missing/empty. Run with --update to "
            "record (after review).")

    failures = []
    if gritc_pin != live_gritc:
        failures.append(
            "compiler digest drift: recorded %s, live %s (re-bake required)"
            % (gritc_pin, live_gritc))

    for src_rel, _ in PINNED_MODULES:
        live = digests[src_rel]
        rec = recorded.get(src_rel)
        if rec is None:
            failures.append("%s has no recorded digest" % src_rel)
        elif rec != live:
            failures.append("%s digest drift: recorded %s, live %s"
                            % (src_rel, rec, live))

    for src_rel in recorded:
        if src_rel not in dict(PINNED_MODULES):
            failures.append("recorded module %s is no longer pinned (prune it)"
                            % src_rel)

    if failures:
        print("[repro] FAIL: reproducible-build attestation drift:")
        for f in failures:
            print("  - %s" % f)
        return 1

    print("[repro] PASS: %d pinned module(s) reproducible + match recorded digests"
          % len(PINNED_MODULES))
    return 0


if __name__ == '__main__':
    sys.exit(main())
