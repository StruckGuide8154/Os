#!/usr/bin/env python3
import os
import struct
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from src.enclave.usb_protocol import (BulkTransfer, EnclaveUSBDevice, KIND_COMMAND,
    KIND_RESPONSE, OP_ATTEST, OP_COUNTER_READ, OP_DERIVE, ProtocolError,
    STATUS_LOCKED, STATUS_OK, MAX_PAYLOAD, open_frame, seal)

KEY = bytes(range(32))
failures = []

def check(label, condition):
    print("[encusb] %-57s [%s]" % (label, "ok" if condition else "FAIL"))
    if not condition: failures.append(label)

def rejects(label, fn):
    try: fn()
    except ProtocolError: check(label, True)
    else: check(label, False)

def main():
    device = EnclaveUSBDevice(KEY, boot_counter=9)
    command = seal(KEY, KIND_COMMAND, 1, bytes([OP_COUNTER_READ]))
    plain = open_frame(KEY, KIND_RESPONSE, 1, device.exchange(command))
    check("honest command/response round trip", plain[0] == STATUS_OK and struct.unpack("<Q", plain[1:])[0] == 9)
    transfer = BulkTransfer(max_packet=16)
    for offset in range(0, len(command), 16): done = transfer.packet(command[offset:offset + 16])
    if len(command) % 16 == 0: done = transfer.packet(b"")
    check("USB short packet terminates successful transfer", done and bytes(transfer.data) == command)
    exact = seal(KEY, KIND_COMMAND, 99, b"x" * 12)
    zlp = BulkTransfer(max_packet=16)
    for offset in range(0, len(exact), 16): done = zlp.packet(exact[offset:offset + 16])
    check("max-packet multiple waits for terminating ZLP", not done)
    check("terminating ZLP completes exact-multiple transfer", zlp.packet(b""))
    rejects("oversized plaintext rejected", lambda: seal(KEY, KIND_COMMAND, 1, b"x" * (MAX_PAYLOAD + 1)))
    rejects("truncated frame rejected", lambda: open_frame(KEY, KIND_COMMAND, 1, command[:-1]))
    rejects("trailing bytes rejected", lambda: open_frame(KEY, KIND_COMMAND, 1, command + b"x"))
    tampered_len = bytearray(command); tampered_len[16:20] = struct.pack("<I", 200)
    rejects("forged payload length rejected", lambda: open_frame(KEY, KIND_COMMAND, 1, bytes(tampered_len)))
    tampered_tag = bytearray(command); tampered_tag[-1] ^= 1
    rejects("bad AEAD tag rejected", lambda: open_frame(KEY, KIND_COMMAND, 1, bytes(tampered_tag)))
    rejects("replayed sequence rejected", lambda: device.exchange(command))
    rejects("command cannot be reflected as response", lambda: open_frame(KEY, KIND_RESPONSE, 1, command))
    derive = seal(KEY, KIND_COMMAND, 2, bytes([OP_DERIVE]) + b"disk")
    rsp = open_frame(KEY, KIND_RESPONSE, 2, device.exchange(derive))
    check("derive succeeds once and closes privileged window", rsp[0] == STATUS_OK and device.locked)
    derive2 = seal(KEY, KIND_COMMAND, 3, bytes([OP_DERIVE]) + b"disk")
    rsp2 = open_frame(KEY, KIND_RESPONSE, 3, device.exchange(derive2))
    check("post-latch derive returns LOCKED", rsp2 == bytes([STATUS_LOCKED]))
    attest = seal(KEY, KIND_COMMAND, 4, bytes([OP_ATTEST]))
    attest_rsp = open_frame(KEY, KIND_RESPONSE, 4, device.exchange(attest))
    check("Phase-B attest remains available and reports locked", attest_rsp[0] == STATUS_OK and attest_rsp[1] == 1)
    if failures: return 1
    print("[encusb] length-tagged AEAD bulk protocol and negative paths enforced")
    return 0

if __name__ == "__main__": sys.exit(main())
