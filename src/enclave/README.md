# `src/enclave/` — Track 10 USB-FPGA secure-enclave (software model)

The host-side, CI-testable **software model** of the external FPGA secure-enclave
board (design: [`docs/track10-fpga-secure-enclave-todo.md`](../../docs/track10-fpga-secure-enclave-todo.md)).
The real device is gateware on a USB-attached FPGA; QEMU/TCG cannot model it, so
this folder holds the **exact state machine the gateware must implement** as GHL
modules that compile with the production `gritc` frontend and run in CI. It lets
the host boot / driver / monitor path be validated **without the board**.

## Design principles (kept deliberately)

- **One concern per module.** This folder owns *only* the phase/latch/single-use
  logic. Crypto (Ed25519/X25519) lives in `src/kernel/grithlk/ed25519_check.ghl`;
  TRNG / NV / tamper are real-gateware concerns. The decoupling keeps each piece
  small, constant-shape, and auditable.
- **Pure logic, no I/O coupling.** `enclave_phase.ghl` has no externs — it is a
  fast, deterministic, fully transpilable state machine. Fail-closed by default.
- **Every security claim is executable.** Each property in the track doc's
  "P2 — Validation / one-shot / latch tests" has a matching assertion in the
  eval harness; constants are drift-guarded against the compiled module.
- **The doctrine: every guard has a test that breaks it.** The eval includes the
  honest 2-fault case (two downed latch cells *do* clear) so the majority-vote
  claim is not overstated.

## Contents

| File | Role |
|---|---|
| `enclave_phase.ghl` | P0 centerpiece (software model): the one-shot phase machine — triplicated sticky latch (2-of-3 majority), Phase A privileged window (single-use derive / unseal / seal-lock), auto-close triggers (seal-lock, boot-complete, first Phase-B op, watchdog), Phase-B allow-list, attest read-outs, monotonic boot counter. |
| [`rtl/`](rtl/) | The same one-shot machine as **synthesizable FPGA gateware** (Amaranth HDL): `latch.py`, `secure_ram.py` (custom on-die RAM with a master-export firewall), `enclave_top.py`, `generate.py`. On-die only — no external RAM, no soft-CPU. See [`rtl/README.md`](rtl/README.md). |

Tests:
- [`scripts/test/eval_enclave.py`](../../scripts/test/eval_enclave.py) — 34 assertions against the GHL model.
- [`scripts/test/eval_enclave_rtl.py`](../../scripts/test/eval_enclave_rtl.py) — 33 assertions cycle-simulating the gateware (incl. the RTL KDF matching an independent reference, and the SecureRAM firewall).

Both run via [`scripts/test/test_enclave_phase.ps1`](../../scripts/test/test_enclave_phase.ps1)
(`-SkipGateware` to skip the Amaranth layer). Gateware deps: `pip install amaranth amaranth-yosys`.

## Status / roadmap

- **Landed (model + gateware):** the one-shot phase machine + triplicated latch
  + single-use semantics + attest, as both the GHL reference *and* synthesizable
  RTL proven to match it. The board's most-privileged surface has a
  one-transaction window, then is dead in silicon until power cycle — and the
  master key has no wire to any output pin (structural firewall).
- **Next (per the track doc, in order):** mutual host↔board attestation
  (X25519 ECDH → session key bound to the boot counter), the authenticated +
  nonce'd USB session frame (close the USB-MITM hole), then the host-side
  monitor mediation + brokered ring-3 driver (Track 8) and `CAP_ENCLAVE`.
  Real-silicon residuals (secure-NV boot counter, PUF master, tamper-zeroize,
  constant-time crypto core) need the HW rig.

## Honest boundary

This models the privileged **window** and key/counter **custody**. It does not
establish first-instruction host integrity — the board attaches after host code
runs (the documented open problem). **leak ≠ elevation.**
