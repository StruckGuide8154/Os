#!/usr/bin/env python3
import copy
import json
import os
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "build"))
import ed25519_host
from enclave_bitstream_manifest import (ABUpdateController, admit_update, canonical,
    make_manifest, parse_record_bytes, sign_manifest, sign_self_test,
    validate_manifest, verify_record)

failures = []
def check(label, condition):
    print("[encsupply] %-54s [%s]" % (label, "ok" if condition else "FAIL"))
    if not condition: failures.append(label)

def main():
    with tempfile.TemporaryDirectory() as temp:
        with open(os.path.join(temp, "top.v"), "wb") as f: f.write(b"module top; endmodule\n")
        bitstream = os.path.join(temp, "top.bit")
        with open(bitstream, "wb") as f: f.write(b"deterministic-bitstream")
        kwargs = dict(bitstream=bitstream, source_root=temp, sources=["top.v"],
            toolchain={"yosys":"0.50", "nextpnr":"0.8"}, version=3,
            rollback=7, slot="B", board_class="hardened-auth-usb-v1")
        record1 = sign_manifest(make_manifest(**kwargs)); record2 = sign_manifest(make_manifest(**kwargs))
        check("identical inputs produce byte-identical record", canonical(record1) == canonical(record2))
        check("signed manifest and bitstream digest verify", verify_record(record1, bitstream))
        check("canonical record parser accepts canonical bytes", parse_record_bytes(canonical(record1)) == record1)
        try:
            parse_record_bytes(b'{"manifest":{},"manifest":{},"signature":"x","signer_role":"UPDATE"}')
            duplicate_rejected = False
        except ValueError:
            duplicate_rejected = True
        check("duplicate JSON keys rejected", duplicate_rejected)
        try:
            parse_record_bytes(json.dumps(record1, indent=2).encode("ascii"))
            noncanonical_rejected = False
        except ValueError:
            noncanonical_rejected = True
        check("non-canonical JSON encoding rejected", noncanonical_rejected)
        check("source tree digest verifies independently", verify_record(record1, bitstream, temp))
        malformed = copy.deepcopy(record1["manifest"]); malformed["unknown"] = 1
        check("unknown manifest field rejected", not validate_manifest(malformed)[0])
        malformed = copy.deepcopy(record1["manifest"]); malformed["rollback_counter"] = True
        check("boolean counter rejected", not validate_manifest(malformed)[0])
        malformed = copy.deepcopy(record1["manifest"]); malformed["sources"] = ["../top.v"]
        check("source path traversal rejected", not validate_manifest(malformed)[0])
        malformed = copy.deepcopy(record1["manifest"]); malformed["toolchain"] = {}
        check("empty toolchain rejected", not validate_manifest(malformed)[0])
        changed = copy.deepcopy(record1); changed["manifest"]["version"] = 4
        check("manifest mutation invalidates signature", not verify_record(changed, bitstream))
        with open(bitstream, "ab") as f: f.write(b"tamper")
        check("bitstream mutation invalidates digest binding", not verify_record(record1, bitstream))
        with open(bitstream, "wb") as f: f.write(b"deterministic-bitstream")
        with open(os.path.join(temp, "top.v"), "ab") as f: f.write(b"// drift")
        check("source-tree mutation invalidates provenance", not verify_record(record1, bitstream, temp))
        with open(os.path.join(temp, "top.v"), "wb") as f: f.write(b"module top; endmodule\n")
        ok, reason = admit_update(record1, 6, "A", bitstream)
        check("new signed image stages only to inactive slot", ok and reason == "stage-inactive-slot")
        ok, reason = admit_update(record1, 7, "A", bitstream)
        check("equal rollback counter is rejected", not ok and reason == "rollback")
        ok, reason = admit_update(record1, 6, "B", bitstream)
        check("overwriting active slot is rejected", not ok and reason == "active-slot")

        device_secret = bytes.fromhex("11" * 32)
        ctl = ABUpdateController("A", 6, ed25519_host.public_key(device_secret))
        ok, reason = ctl.stage(record1, bitstream)
        check("controller stages authenticated inactive image", ok and ctl.state == "staged")
        check("floor is not committed at staging", ctl.floor == 6)
        ok, reason = ctl.begin_trial()
        check("staged image enters one-boot trial", ok and ctl.state == "trial" and ctl.active_slot == "B")
        ok, reason = ctl.confirm(bytes(64))
        check("forged self-test cannot commit", not ok and reason == "bad-self-test" and ctl.floor == 6)
        ok, reason = ctl.power_loss()
        check("power loss during trial returns previous slot", ok and ctl.active_slot == "A" and ctl.floor == 6)
        ctl.stage(record1, bitstream); ctl.begin_trial()
        ok, reason = ctl.confirm(sign_self_test(record1, device_secret))
        check("device-signed self-test commits slot and floor", ok and ctl.active_slot == "B" and ctl.floor == 7)
        ok, reason = ctl.stage(record1, bitstream)
        check("committed image cannot be replayed", not ok and reason == "rollback")
    if failures: return 1
    print("[encsupply] strict manifest, reproducible provenance, and full A/B lifecycle enforced")
    return 0

if __name__ == "__main__": sys.exit(main())
