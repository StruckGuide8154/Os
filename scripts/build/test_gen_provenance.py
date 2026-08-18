#!/usr/bin/env python3
"""Regression tests for provenance generator artifact identity validation."""

import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("gen_provenance.py")


def run_generator(*artifact_args):
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        artifact = td / "artifact.bin"
        output = td / "PROVENANCE.ENV"
        artifact.write_bytes(b"artifact identity regression payload")

        cmd = [
            sys.executable,
            str(SCRIPT),
            "--out", str(output),
            "--builder", "test:artifact-identity",
        ]
        for name in artifact_args:
            cmd.extend(["--artifact", "%s=%s" % (name, artifact)])

        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return proc, output.exists()


def test_duplicate_artifact_names_fail_closed():
    proc, output_exists = run_generator("KERNEL.BIN", "KERNEL.BIN")
    assert proc.returncode != 0, "duplicate artifact names unexpectedly succeeded"
    assert "duplicate --artifact name" in (proc.stdout + proc.stderr)
    assert not output_exists, "generator wrote an envelope after duplicate-name rejection"


def test_empty_artifact_name_fails_closed():
    proc, output_exists = run_generator("")
    assert proc.returncode != 0, "empty artifact name unexpectedly succeeded"
    assert "artifact name must be non-empty" in (proc.stdout + proc.stderr)
    assert not output_exists, "generator wrote an envelope after empty-name rejection"


def main():
    test_duplicate_artifact_names_fail_closed()
    test_empty_artifact_name_fails_closed()
    print("gen_provenance regression tests: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
