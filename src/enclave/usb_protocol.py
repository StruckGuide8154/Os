"""Track 10 USB bulk framing and software-device model.

The framing is byte-accurate.  The AEAD primitive is deliberately a CI model,
not production crypto; gateware must replace it without changing the framing,
nonce, direction, or associated-data contract.
"""

from dataclasses import dataclass
import hashlib
import hmac
import struct

MAGIC = b"GE10"
VERSION = 1
KIND_COMMAND = 1
KIND_RESPONSE = 2
HEADER = struct.Struct("<4sBBBBQI")
TAG_LEN = 16
MAX_PAYLOAD = 4096

OP_DERIVE = 0x10
OP_SIGN = 0x20
OP_RNG = 0x21
OP_COUNTER_READ = 0x22
OP_ATTEST = 0x23

STATUS_OK = 0
STATUS_LOCKED = 1
STATUS_BAD_OPCODE = 2


class ProtocolError(ValueError):
    pass


def _stream(key, seq, kind, length):
    out = bytearray()
    block = 0
    while len(out) < length:
        out.extend(hashlib.sha256(key + struct.pack("<QBI", seq, kind, block)).digest())
        block += 1
    return bytes(out[:length])


def seal(key, kind, seq, payload):
    if kind not in (KIND_COMMAND, KIND_RESPONSE):
        raise ProtocolError("invalid frame kind")
    if not 0 <= len(payload) <= MAX_PAYLOAD:
        raise ProtocolError("payload length out of range")
    header = HEADER.pack(MAGIC, VERSION, kind, 0, HEADER.size, seq, len(payload))
    ciphertext = bytes(a ^ b for a, b in zip(payload, _stream(key, seq, kind, len(payload))))
    tag = hmac.new(key, header + ciphertext, hashlib.sha256).digest()[:TAG_LEN]
    return header + ciphertext + tag


def open_frame(key, expected_kind, expected_seq, frame):
    if len(frame) < HEADER.size + TAG_LEN:
        raise ProtocolError("truncated frame")
    magic, version, kind, flags, header_len, seq, payload_len = HEADER.unpack_from(frame)
    if magic != MAGIC or version != VERSION or flags != 0 or header_len != HEADER.size:
        raise ProtocolError("invalid header")
    if kind != expected_kind:
        raise ProtocolError("wrong direction")
    if seq != expected_seq:
        raise ProtocolError("unexpected sequence")
    if payload_len > MAX_PAYLOAD:
        raise ProtocolError("payload too large")
    exact_len = HEADER.size + payload_len + TAG_LEN
    if len(frame) != exact_len:
        raise ProtocolError("length tag mismatch")
    ciphertext = frame[HEADER.size:-TAG_LEN]
    tag = frame[-TAG_LEN:]
    expected = hmac.new(key, frame[:HEADER.size] + ciphertext, hashlib.sha256).digest()[:TAG_LEN]
    if not hmac.compare_digest(tag, expected):
        raise ProtocolError("authentication failed")
    stream = _stream(key, seq, kind, payload_len)
    return bytes(a ^ b for a, b in zip(ciphertext, stream))


@dataclass
class BulkTransfer:
    """Collect one USB bulk transfer; a short packet terminates successfully."""

    max_packet: int = 64

    def __post_init__(self):
        self.data = bytearray()
        self.complete = False

    def packet(self, chunk):
        if self.complete:
            raise ProtocolError("transfer already complete")
        if len(chunk) > self.max_packet:
            raise ProtocolError("packet exceeds endpoint maximum")
        self.data.extend(chunk)
        if len(chunk) < self.max_packet:
            self.complete = True
        return self.complete


class EnclaveUSBDevice:
    """Protocol-level board model. Session establishment is modeled elsewhere."""

    def __init__(self, session_key, boot_counter=1):
        self.key = session_key
        self.boot_counter = boot_counter
        self.rx_seq = 1
        self.tx_seq = 1
        self.locked = False

    def lock(self):
        self.locked = True

    def exchange(self, command_frame):
        command = open_frame(self.key, KIND_COMMAND, self.rx_seq, command_frame)
        self.rx_seq += 1
        if not command:
            status, body = STATUS_BAD_OPCODE, b""
        else:
            opcode, arg = command[0], command[1:]
            if opcode == OP_DERIVE:
                if self.locked:
                    status, body = STATUS_LOCKED, b""
                else:
                    self.locked = True
                    body = hashlib.sha256(self.key + b"derive" + arg).digest()
                    status = STATUS_OK
            elif opcode == OP_COUNTER_READ:
                status, body = STATUS_OK, struct.pack("<Q", self.boot_counter)
            elif opcode == OP_ATTEST:
                status, body = STATUS_OK, struct.pack("<BQ", int(self.locked), self.boot_counter)
            elif opcode in (OP_SIGN, OP_RNG):
                status = STATUS_OK
                body = hmac.new(self.key, bytes([opcode]) + arg, hashlib.sha256).digest()
            else:
                status, body = STATUS_BAD_OPCODE, b""
        response = seal(self.key, KIND_RESPONSE, self.tx_seq, bytes([status]) + body)
        self.tx_seq += 1
        return response

