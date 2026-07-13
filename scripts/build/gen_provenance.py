#!/usr/bin/env python3
# =============================================================================
# gen_provenance.py - signed CI provenance (SLSA-style) (Track 1, sec->10).
#
# Beyond-zero-trust Track 1 (docs/track1-repo-enforcement-todo.md, "Path to
# 10/10"): "every artifact carries a signed builder identity + source revision,
# verified by the Track 2/7 root."
#
# This emits a SLSA-style provenance statement for a build and SIGNS it with the
# SAME Track-2/7 Ed25519 machinery used for SYSSIG.ENV / KERNEL.ENV - no new
# crypto. The provenance statement is the envelope PAYLOAD; the envelope is a
# real quorum-signed Track-2 v1 envelope (write_envelope.py), so it is verified
# by the existing in-kernel/host Ed25519 root (ed25519_host.py + the GHL
# envelope_verify_signed reader).
#
# Provenance statement (canonical JSON, sorted keys) records:
#   - builder.id        : the builder identity (e.g. github actions workflow ref,
#                         or a local builder tag); from --builder or env.
#   - builder.toolchain : sha256 of the pinned gritc.py + ed25519_host.py and the
#                         nasm version token (binds the artifact to the pinned
#                         toolchain - ties this to check_toolchain_pins.ps1).
#   - source.revision   : the exact git commit (40-hex) the build was cut from.
#   - source.uri        : the repo URI (best-effort from git remote).
#   - artifacts[]       : {name, sha256} for every named build artifact.
#   - schema            : 'grit-provenance-v1'.
#
# Usage:
#   python gen_provenance.py --out build/PROVENANCE.ENV \
#       --builder "github:StruckGuide8154/grit@dev" \
#       --artifact KERNEL.BIN=build/esp/EFI/BOOT/KERNEL.BIN \
#       --artifact APPS.BIN=build/esp/EFI/BOOT/APPS.BIN
#
# Verify the result with verify_provenance.py.
# =============================================================================

import argparse
import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
GRITC = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler', 'gritc.py')
ED25519_HOST = os.path.join(ROOT, 'scripts', 'build', 'ed25519_host.py')
PIN_MANIFEST = os.path.join(ROOT, 'tools', 'security', 'toolchain_pins.txt')

SCHEMA = 'grit-provenance-v1'


def sha256_file(path):
    with open(path, 'rb') as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def git(*args):
    try:
        out = subprocess.run(['git', '-C', ROOT] + list(args),
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if out.returncode == 0:
            return out.stdout.decode('utf-8', 'replace').strip()
    except Exception:
        pass
    return ''


def nasm_version_pin():
    """Read the frozen nasm version token from the pin manifest (the build does
    not require nasm to be present to STAMP provenance)."""
    if not os.path.exists(PIN_MANIFEST):
        return ''
    with open(PIN_MANIFEST, 'r') as fh:
        for line in fh:
            cols = [c.strip() for c in line.strip().split('|')]
            if len(cols) == 5 and cols[0] == 'tool-version' and cols[1] == 'nasm':
                return cols[3]
    return ''


def build_statement(builder_id, artifacts):
    rev = git('rev-parse', 'HEAD')
    uri = git('config', '--get', 'remote.origin.url')
    stmt = {
        'schema': SCHEMA,
        'builder': {
            'id': builder_id,
            'toolchain': {
                'gritc_sha256': sha256_file(GRITC),
                'ed25519_host_sha256': sha256_file(ED25519_HOST),
                'nasm_version': nasm_version_pin(),
            },
        },
        'source': {
            'uri': uri,
            'revision': rev,
        },
        'artifacts': sorted(
            [{'name': n, 'sha256': sha256_file(p)} for n, p in artifacts],
            key=lambda a: a['name']),
    }
    return stmt


def canonical_bytes(stmt):
    # Deterministic canonical JSON: sorted keys, compact separators, UTF-8.
    return json.dumps(stmt, sort_keys=True, separators=(',', ':')).encode('utf-8')


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--out', required=True, metavar='FILE',
                   help='output signed provenance envelope')
    p.add_argument('--builder', default=None, metavar='ID',
                   help='builder identity (default: $GRIT_BUILDER_ID or '
                        'github:$GITHUB_WORKFLOW_REF or local:<host>)')
    p.add_argument('--artifact', action='append', default=[], metavar='NAME=PATH',
                   help='named artifact to record (repeatable)')
    p.add_argument('--statement-out', default=None, metavar='FILE',
                   help='also write the raw canonical statement JSON here')
    args = p.parse_args()

    # write_envelope runs with scripts/build as its cwd so its local imports and
    # key paths are stable. Resolve caller-supplied outputs first; otherwise a
    # relative `--out PROVENANCE.ENV` is silently written under scripts/build
    # while the caller verifies/uploads it from the repository root.
    out_path = os.path.abspath(args.out)
    statement_out_path = (os.path.abspath(args.statement_out)
                          if args.statement_out else None)

    if args.builder:
        builder_id = args.builder
    elif os.environ.get('GRIT_BUILDER_ID'):
        builder_id = os.environ['GRIT_BUILDER_ID']
    elif os.environ.get('GITHUB_WORKFLOW_REF'):
        builder_id = 'github:' + os.environ['GITHUB_WORKFLOW_REF']
    else:
        import socket
        builder_id = 'local:' + socket.gethostname()

    artifacts = []
    for a in args.artifact:
        if '=' not in a:
            sys.exit("--artifact must be NAME=PATH, got %r" % a)
        name, path = a.split('=', 1)
        if not os.path.exists(path):
            sys.exit("artifact path does not exist: %s" % path)
        artifacts.append((name, path))

    stmt = build_statement(builder_id, artifacts)
    payload = canonical_bytes(stmt)

    # Write the canonical statement to a temp payload file, then wrap+sign it as
    # a Track-2 'policy'-class envelope via write_envelope.py (real Ed25519
    # quorum signatures over the canonical envelope bytes).
    import tempfile
    fd, payload_path = tempfile.mkstemp(prefix='provenance-', suffix='.json')
    os.close(fd)
    try:
        with open(payload_path, 'wb') as fh:
            fh.write(payload)
        if statement_out_path:
            with open(statement_out_path, 'wb') as fh:
                fh.write(payload)
        write_env = os.path.join(ROOT, 'scripts', 'build', 'write_envelope.py')
        cmd = [sys.executable, write_env,
               '--payload', payload_path, '--out', out_path,
               '--type', 'policy', '--device-id', '1']
        proc = subprocess.run(cmd, cwd=os.path.join(ROOT, 'scripts', 'build'))
        if proc.returncode != 0:
            sys.exit("write_envelope failed")
    finally:
        if os.path.exists(payload_path):
            os.remove(payload_path)

    print("[provenance] builder=%s rev=%s artifacts=%d -> %s"
          % (builder_id, stmt['source']['revision'][:12],
             len(artifacts), out_path))
    return 0


if __name__ == '__main__':
    sys.exit(main())
