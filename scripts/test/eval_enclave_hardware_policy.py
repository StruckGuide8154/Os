#!/usr/bin/env python3
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from src.enclave.power_model import BoardPowerModel

failures = []
def check(label, condition):
    print("[enchw] %-59s [%s]" % (label, "ok" if condition else "FAIL"))
    if not condition: failures.append(label)

def main():
    with open(os.path.join(ROOT, "docs", "track10-board-selection.json"), encoding="utf-8") as f:
        decision = json.load(f)
    required = {"authenticated_configuration_before_fabric", "puf_protected_key_service",
        "secure_nonvolatile_storage", "tamper_signals", "configuration_integrity_digest",
        "locked_debug_in_deployment", "dual_image_policy_in_project_logic"}
    check("board decision schema is fixed", decision.get("schema") == "grit.track10-board-selection.v1")
    check("selected class has no external authentication MCU", decision.get("external_auth_mcu") is False)
    check("all mandatory security capabilities are asserted", set(decision.get("required_capabilities", {})) == required and all(decision["required_capabilities"].values()))
    check("normal enumeration exposes vendor bulk only", decision.get("normal_usb_classes") == ["vendor-specific-bulk"])
    check("physical qualification residuals remain explicit", len(decision.get("physical_qualification_pending", [])) >= 7)

    board = BoardPowerModel(); check("cold power-on arms latch and bumps counter", board.power_on() and not board.latch and board.boot_counter == 1)
    board.lock(); floor_before = board.rollback_floor; board.ratchet_floor(4)
    check("suspend with retained VBUS preserves latch and NV", board.suspend(True) == "retained" and board.latch and board.rollback_floor == 4)
    check("resume without power cycle preserves boot counter", board.resume() == "resumed" and board.boot_counter == 1)
    check("suspend power loss is explicit device loss", board.suspend(False) == "device-loss" and not board.vbus)
    check("power loss preserves NV but next power-on resets latch", board.rollback_floor == 4 and board.power_on() and not board.latch and board.boot_counter == 2)
    check("rollback floor cannot decrease", not board.ratchet_floor(floor_before))
    if failures: return 1
    print("[enchw] board-selection and power/persistence design contracts enforced")
    return 0

if __name__ == "__main__": sys.exit(main())

