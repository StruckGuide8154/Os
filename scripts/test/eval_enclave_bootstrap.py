#!/usr/bin/env python3
import hashlib
import os
import sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")); sys.path.insert(0, ROOT)
from src.enclave.bootstrap_model import BootstrapError, TierBBoard
LOADER = b"signed earliest loader stub"
def main():
    board = TierBBoard(b"board-model-key", hashlib.sha256(LOADER).digest())
    nonce = board.challenge(); assert board.extend_loader(nonce, LOADER)
    try: board.extend_loader(nonce, LOADER); return 1
    except BootstrapError: pass
    nonce2 = board.challenge(); assert not board.extend_loader(nonce2, LOADER + b" tampered")
    assert nonce != nonce2
    print("[encbootstr] Tier-B nonce freshness, single-use extend, and mismatch enforced")
    return 0
if __name__ == "__main__": sys.exit(main())

