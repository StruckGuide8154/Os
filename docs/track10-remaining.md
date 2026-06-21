# Track 10 — Definitive Remaining-Work List (HANDOFF)

**Purpose:** this is the single authoritative checklist for finishing Track 10.
It exists so work can be handed to another agent and driven to "code-ready for
the board" **before any hardware is ordered**. The rich design rationale stays in
`track10-fpga-secure-enclave-todo.md`; **this file is the task truth.**

## Ground rules for the implementing agent

1. **Two buckets only.** Every item is either **CODE-NOW** (completable + verifiable
   with no board, in this repo) or **BOARD-GATED** (cannot be completed until the
   physical `M2GL010TS` is on a bench). Do **all** CODE-NOW items. Do **not** mark
   any BOARD-GATED item done — leave it for post-order bring-up.
2. **"Done" = vectors pass.** For every crypto unit, done means a CI eval asserts it
   against published test vectors (RFC/FIPS) **and** differentially against a Python
   reference. No "shaped like" placeholders counted as done. Follow the pattern
   already set by `src/enclave/rtl/sha512.py` + `scripts/test/eval_enclave_sha512.py`.
3. **Constant-time by construction.** No secret-dependent branches, no secret-indexed
   memory, fixed cycle latency. This device is a remote (USB) timing oracle.
4. **Wire each new eval into** `scripts/test/test_enclave_phase.ps1` (gateware block),
   and keep `eval_enclave_rtl_structure.py` (secret-taint gate) green.
5. **On-die only.** Fabric registers + the custom `SecureRAM`. No external RAM, no
   soft-CPU, no off-die secret store.

## Target part (decided — do not re-litigate)

- FPGA: **Microchip IGLOO2 `M2GL010TS`** (TS = the security grade: PUF + ECC + DPA
  + AES256/SHA256/RNG + 256 KB eNVM; FPGA-only, no CPU). Confirm TQG144 vs VF256
  package stock at order time.
- USB PHY: **USB3300 ULPI** (onboard), USB-A male **or** USB-C connector (CC 5.1k
  pulldowns if C).
- Toolchain: **Microchip Libero SoC** (free Silver license covers this part).
  Amaranth → Verilog via `python -m enclave.rtl.generate` feeds Libero.

---

## BUCKET A — CODE-NOW (finish all of these before ordering)

Order matters: A1→A2→A3 is a dependency chain; A4 and A5 are independent and may run
in parallel. Each lands with a passing `scripts/test/eval_enclave_*.py`.

- [x] **A0. SHA-512 core** — `src/enclave/rtl/sha512.py`, verified by
  `scripts/test/eval_enclave_sha512.py` (FIPS 180-4 KAT + hashlib differential).
  **DONE — reference pattern for everything below.**

- [ ] **A1. Field arithmetic mod p = 2²⁵⁵−19.**
  - File: `src/enclave/rtl/field25519.py`. Ops: add, sub, mul, square, invert
    (Fermat: a^(p−2)), reduce/freeze to canonical form. Constant-time.
  - Verify: `eval_enclave_field25519.py` — differential vs a Python `pow`/`%`
    reference over randomized operands; KAT for known products.
  - Done when: all field ops match the Python reference over ≥1000 random vectors.

- [ ] **A2. X25519 (Montgomery ladder).**
  - File: `src/enclave/rtl/x25519.py`, built on A1. Fixed-iteration ladder, swap via
    constant-time conditional, clamp the scalar per RFC 7748.
  - Verify: `eval_enclave_x25519.py` — **RFC 7748 §5.2 test vectors** (the two scalar/
    u KATs + the 1× and 1000× iterated vectors) + differential vs a Python X25519.
  - Done when: RFC 7748 vectors pass.

- [ ] **A3. Ed25519 sign/verify.**
  - File: `src/enclave/rtl/ed25519.py`, using A1 (field) + A0 (SHA-512) + Edwards
    point add/double + fixed-window scalar mult. Verify path checks the cofactored eq.
  - Verify: `eval_enclave_ed25519.py` — **RFC 8032 §7.1 test vectors** (sign + verify,
    incl. the empty-message and multi-byte cases) + differential vs a Python Ed25519.
  - Done when: RFC 8032 vectors pass for both sign and verify.

- [ ] **A4. AEAD — ChaCha20-Poly1305.** *(independent of A1–A3)*
  - File: `src/enclave/rtl/aead_chacha.py`. ChaCha20 block + Poly1305 MAC, constant-time.
  - Verify: `eval_enclave_aead.py` — **RFC 8439 §2.8.2 / Appendix A vectors** + a
    seal→open round-trip + a tamper-bit-flip negative (must fail auth).
  - Replaces the placeholder datapath in `src/enclave/rtl/crypto_session.py`; preserve
    its `start/busy/done` cycle contract so `enclave_top.py` is untouched.

- [ ] **A5. Fabric USB-2 ULPI device core.** *(independent)*
  - File: `src/enclave/rtl/usb_ulpi_device.py`. Synthesizable USB 2.0 device over the
    ULPI 8-bit interface (the USB3300 link): SIE, endpoint 0 control, bulk IN/OUT
    endpoints for the length-tagged AEAD command/response framing.
  - Replaces the byte-level model in `src/enclave/usb_protocol.py` (keep that as the
    protocol spec the core must satisfy).
  - Verify: `eval_enclave_usb_ulpi.py` — ULPI-transaction-level sim: enumeration
    (GET_DESCRIPTOR/SET_ADDRESS/SET_CONFIG), a bulk OUT→IN command round-trip, and
    short-packet = success (per `feedback_xhci_short_packet`).

- [ ] **A6. Integrate crypto into the session/boot FSMs.**
  - Swap `enclave_session.ghl` / `enclave_boot.ghl` crypto placeholders
    (`enc_s_dh/_sign/_kdf`, KDF mix in `enclave_top.py`) to call A1–A4 cores.
  - Verify: existing `eval_enclave_session.py` / `eval_enclave_boot.py` still pass with
    real crypto substituted (honest interop, MITM/replay/downgrade negatives intact).

- [ ] **A7. Host-side integration (Grit/GHL).** *(no board needed — host code is CI-testable)*
  - KERNEL.ENV measured-boot value → board handshake input (wire `track2_kernel_env`).
  - Monitor (Track 5) exclusive IOMMU claim of the enclave xHCI endpoint; broker-only
    Phase-B path; CAP_ENCLAVE default-deny.
  - Track 7 manifest checks the in-image root against the device pubkey.
  - Verify: extend `eval_enclave_host.py` with these handoff assertions.

- [ ] **A8. Full netlist build is clean.**
  - `python -m enclave.rtl.generate` emits RTLIL + Verilog for the **whole** design
    (top + A1–A5) with no elaboration errors; `eval_enclave_rtl_structure.py`
    secret-taint gate stays green over the real crypto.

**Exit criterion for "code-ready, order the board":** every A-item checked, the full
`scripts/test/test_enclave_phase.ps1` green, and A8 produces a complete netlist.

---

## BUCKET B — BOARD-GATED (do NOT attempt until the part is in hand)

These need Libero against real silicon and/or a bench. Leave unchecked; they are the
post-order bring-up plan, not handoff work.

- [ ] **B1. Libero security-IP binding** — map A-cores + state to hard IP: SRAM-PUF
  (master root / `puf_seal`), eNVM (secure NV / monotonic floors), system-controller
  TRNG (entropy source under the A-side health tests), authenticated/encrypted
  bitstream config.
- [ ] **B2. Pin/PHY bring-up** — FPGA↔USB3300 ULPI pin map, signal integrity, clocking.
- [ ] **B3. Timing closure** on `M2GL010TS`; resource fit report.
- [ ] **B4. USB enumeration / compliance** on real host hardware.
- [ ] **B5. Security fuses + debug-lock** verified; A/B reflash recovery under interrupted
  programming.
- [ ] **B6. Tamper-sensor calibration**, TRNG SP 800-90B health on real entropy.
- [ ] **B7. Constant-time / side-channel build-gate** measured on real crypto + silicon.

---

## Status snapshot

- **Models / protocol FSMs:** complete + CI-verified (phase, session, boot; ~92 asserts
  + 61 RTL checks).
- **Real crypto:** SHA-512 done (A0). A1–A4 outstanding.
- **USB:** byte-model only; fabric core A5 outstanding.
- **Host stitching:** A7 outstanding.
- **Hardware:** all of Bucket B, blocked on the board (intentionally, per the order-last
  plan).
