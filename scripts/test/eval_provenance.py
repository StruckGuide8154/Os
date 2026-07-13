#!/usr/bin/env python3
# =============================================================================
# eval_provenance.py - signed-CI-provenance self-test (Track 1, sec->10).
#
# Exercises the SLSA-style provenance path end to end through the Track-2/7
# Ed25519 root (gen_provenance.py -> write_envelope.py signing ->
# verify_provenance.py): a positive accept plus negatives proving the verifier
# actually rejects tampering / forgery / wrong-revision claims. A verifier that
# accepts everything is no verifier.
#
# Suite:
#   1. honest round-trip: a generated provenance envelope verifies, and the
#      embedded revision + artifact hash match.
#   2. payload tamper: flipping one statement byte breaks signature verification.
#   3. signature tamper: flipping one signature byte breaks verification.
#   4. wrong-revision claim: --expect-revision of a different commit fails.
#   5. wrong artifact hash: --expect-artifact with a wrong digest fails.
#   6. truncated quorum: dropping a signature drops below quorum and fails.
#
# Exit 0 = all assertions hold; exit 1 = a regression.
# =============================================================================

import hashlib
import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'build'))
import verify_provenance as vp   # noqa: E402

GEN = os.path.join(ROOT, 'scripts', 'build', 'gen_provenance.py')


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)


def git_head():
    out = subprocess.run(['git', '-C', ROOT, 'rev-parse', 'HEAD'],
                         stdout=subprocess.PIPE)
    return out.stdout.decode().strip()


def main():
    tmp = tempfile.mkdtemp(prefix='prov-eval-')
    art = os.path.join(tmp, 'ART.BIN')
    env = os.path.join(tmp, 'P.ENV')
    with open(art, 'wb') as fh:
        fh.write(b'grit-provenance-self-test-artifact\n')
    art_sha = hashlib.sha256(open(art, 'rb').read()).hexdigest()
    rev = git_head()

    failures = []

    def check(name, ok):
        if ok:
            print("[prov-eval] PASS  %s" % name)
        else:
            print("[prov-eval] FAIL  %s" % name)
            failures.append(name)

    # Generate an honest envelope.
    r = run([sys.executable, GEN, '--out', env, '--builder', 'local:eval',
             '--artifact', 'ART.BIN=' + art])
    if r.returncode != 0:
        sys.stdout.write(r.stdout.decode('utf-8', 'replace'))
        raise SystemExit('[prov-eval] FAIL: generation errored')

    blob = open(env, 'rb').read()

    # 1. honest round-trip.
    try:
        stmt, roles = vp.verify(blob)
        ok = (stmt['source']['revision'] == rev and
              any(a['name'] == 'ART.BIN' and a['sha256'] == art_sha
                  for a in stmt['artifacts']))
    except Exception:
        ok = False
    check('honest round-trip verifies + revision/artifact match', ok)

    # Locate payload window for tamper tests.
    header_len = struct.unpack('<H', blob[12:14])[0]
    payload_len = struct.unpack('<I', blob[14:18])[0]

    # 2. payload tamper.
    tampered = bytearray(blob)
    tampered[header_len + 5] ^= 0xFF
    try:
        vp.verify(bytes(tampered))
        ok = False
    except Exception:
        ok = True
    check('payload tamper rejected', ok)

    # 3. signature tamper (flip a byte in the signature block).
    sig_off = header_len + payload_len
    tampered = bytearray(blob)
    tampered[sig_off + 3] ^= 0xFF
    try:
        vp.verify(bytes(tampered))
        ok = False
    except Exception:
        ok = True
    check('signature tamper rejected', ok)

    # 4. wrong-revision claim via the CLI.
    r = run([sys.executable, os.path.join(ROOT, 'scripts', 'build', 'verify_provenance.py'),
             env, '--expect-revision', '0' * 40])
    check('wrong-revision claim rejected', r.returncode != 0)

    # 5. wrong artifact hash via the CLI.
    r = run([sys.executable, os.path.join(ROOT, 'scripts', 'build', 'verify_provenance.py'),
             env, '--expect-artifact', 'ART.BIN=' + ('0' * 64)])
    check('wrong artifact hash rejected', r.returncode != 0)

    # 6. truncated quorum (drop the last 64-byte signature).
    truncated = blob[:len(blob) - 64]
    try:
        vp.verify(truncated)
        ok = False
    except Exception:
        ok = True
    check('under-quorum (dropped signature) rejected', ok)

    # cleanup
    for f in (art, env):
        if os.path.exists(f):
            os.remove(f)
    os.rmdir(tmp)

    if failures:
        print("[prov-eval] FAIL: %d assertion(s) failed" % len(failures))
        return 1
    print("[prov-eval] PASS: signed CI provenance verified end-to-end (6 checks)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
