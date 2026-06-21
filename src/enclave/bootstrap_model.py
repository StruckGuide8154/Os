"""Executable Tier-B first-instruction bootstrap model for Track 10."""

import hashlib
import hmac


class BootstrapError(ValueError):
    pass


class TierBBoard:
    """Board challenge + append-only PCR model; firmware/stub remain trusted."""

    def __init__(self, key, expected_loader_digest):
        self.key = key
        self.expected = expected_loader_digest
        self.counter = 0
        self.pending = None
        self.pcr = bytes(32)

    def challenge(self):
        self.counter += 1
        self.pending = hmac.new(self.key, b"bootstrap" + self.counter.to_bytes(8, "little"), hashlib.sha256).digest()
        return self.pending

    def extend_loader(self, nonce, loader_bytes):
        if self.pending is None or not hmac.compare_digest(nonce, self.pending):
            raise BootstrapError("missing or stale board challenge")
        self.pending = None
        digest = hashlib.sha256(loader_bytes).digest()
        self.pcr = hashlib.sha256(self.pcr + nonce + digest).digest()
        return digest == self.expected

