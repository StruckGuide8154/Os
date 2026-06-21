#!/usr/bin/env python3
import copy
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "build"))
from enclave_provisioning import (EnrollmentRegistry, ProvisioningBoard,
    issue_certificate, issue_revocation, verify_certificate, verify_revocation)

failures = []
def check(label, condition):
    print("[encprov] %-57s [%s]" % (label, "ok" if condition else "FAIL"))
    if not condition: failures.append(label)

def main():
    board = ProvisioningBoard("BOARD-0001", b"puf-sample-one")
    challenge = b"station-challenge-0001"
    cert = issue_certificate(board, challenge, board.prove(challenge),
                             "polarfire-fpga-external-ulpi", 1, 1)
    check("authority-signed device certificate verifies", verify_certificate(cert))
    check("certificate issuance locks one-time provisioning", board.locked)
    try:
        issue_certificate(board, challenge, board.prove(challenge), "polarfire-fpga-external-ulpi", 1, 1)
        check("second enrollment command is rejected", False)
    except ValueError:
        check("second enrollment command is rejected", True)
    forged = copy.deepcopy(cert); forged["certificate"]["device_id"] = "ATTACKER"
    check("certificate field mutation invalidates authority signature", not verify_certificate(forged))

    registry = EnrollmentRegistry(minimum_epoch=1)
    check("first explicit enrollment succeeds", registry.enroll(cert) == (True, "enrolled"))
    check("same device cannot silently re-enroll", registry.enroll(cert) == (False, "duplicate-device"))
    check("enrolled non-revoked board is admitted", registry.admits("BOARD-0001"))
    rev = issue_revocation("BOARD-0001", cert["certificate"]["public_key"], 2, "stolen", "BOARD-0002")
    check("authority-signed revocation verifies", verify_revocation(rev))
    bad_rev = copy.deepcopy(rev); bad_rev["revocation"]["effective_epoch"] = 3
    check("revocation mutation invalidates signature", not verify_revocation(bad_rev))
    stale = issue_revocation("BOARD-0001", cert["certificate"]["public_key"], 1, "stolen")
    check("non-forward revocation epoch rejected", registry.revoke(stale) == (False, "epoch-not-forward"))
    check("forward revocation removes board", registry.revoke(rev) == (True, "revoked") and not registry.admits("BOARD-0001"))
    replacement = ProvisioningBoard("BOARD-0002", b"puf-sample-two")
    challenge2 = b"station-challenge-0002"
    cert2 = issue_certificate(replacement, challenge2, replacement.prove(challenge2),
                              "polarfire-fpga-external-ulpi", 2, 2)
    check("explicit authority-signed replacement enrolls at new epoch",
          registry.enroll(cert2) == (True, "enrolled") and registry.admits("BOARD-0002"))
    if failures: return 1
    print("[encprov] one-time enrollment, authority binding, and monotonic revocation enforced")
    return 0

if __name__ == "__main__": sys.exit(main())
