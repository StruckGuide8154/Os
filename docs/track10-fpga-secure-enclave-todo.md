# Track 10 - USB-Attached FPGA Secure-Enclave Board (TODO)

> **HANDOFF / TASK TRUTH:** the definitive, ordered remaining-work checklist is
> **`docs/track10-remaining.md`** — CODE-NOW (finish before ordering the board) vs
> BOARD-GATED (post-order bring-up). This file below is the design rationale; for
> "what to build next," follow `track10-remaining.md`. Target part is decided:
> **IGLOO2 `M2GL010TS` + onboard USB3300 ULPI PHY** (USB-A or USB-C). Real crypto
> status: **SHA-512 core landed + verified** (`src/enclave/rtl/sha512.py`); field25519
> / X25519 / Ed25519 / AEAD / fabric-USB outstanding.

**Status: SOFTWARE/DESIGN COMPLETE 2026-06-14; PHYSICAL BOARD VALIDATION OPEN.**
The P0 one-shot phase machine landed at BOTH layers:
a CI-testable software model (`src/enclave/enclave_phase.ghl` +
`scripts/test/eval_enclave.py`, 34 assertions) **and synthesizable FPGA gateware**
(`src/enclave/rtl/`, Amaranth HDL: triplicated sticky latch, custom on-die
`SecureRAM` with a master-export firewall, the phase FSM; cycle-simulated by
`scripts/test/eval_enclave_rtl.py`, 33 assertions incl. RTL-KDF↔reference
interop; elaborates to RTLIL/Verilog via `enclave.rtl.generate`). The gateware
is **on-die only** — no external RAM, no soft-CPU.

**Authenticated session channel LANDED 2026-06-14** (`src/enclave/enclave_session.ghl`
+ `scripts/test/eval_enclave_session.py`, 28 assertions): the two-step board-first
mutual-attestation handshake, channel+boot-bound `K_s`, and per-frame AEAD with a strict
monotonic sequence — the model that closes the USB-MITM hole (relay/replay/reorder/inject
and cross-boot replay all rejected).

**Phase-A secure-boot transaction LANDED 2026-06-14** (`src/enclave/enclave_boot.ghl`
+ `scripts/test/eval_enclave_boot.py`, 31 assertions): the board-side boot handler
COMPOSED with the phase + session modules (real cross-module calls) - power-on -> mutual
session handshake -> board judges the host measurement against its OWN sealed policy ->
measurement+counter-bound boot-key release on a match (single-use, master never exported)
-> seal-and-lock. Board-sealed policy makes a host BOOTCFG `required->optional` downgrade
inert; required-mode mismatch / no-policy / no-channel all fail closed.

The aggregate `test_enclave_phase.ps1` runner now covers the phase/session/boot models,
the byte-accurate USB device, host monitor/IOMMU handoff, all Phase-B services, signed
bitstream/A-B update policy, provisioning/revocation, Tier-B bootstrap, power behavior,
61 RTL checks, post-synthesis secret-taint gates, and RTLIL/Verilog generation. Items
marked `[~]` below require a selected physical package/PHY, fabricated hardware, vendor
programming flow, production keys, or laboratory validation; they are not software TODOs.

A standalone **FPGA board** that acts as an external **secure enclave** (and more) for
Grit/NexusOS, attached over **USB**, **kept plugged in and powered for the whole session**,
but with its privileged powers available **exactly once per boot**. It is the hardware
root the software tracks have been simulating in-image: today the single public root of
trust (Track 7) and the anti-rollback floors (Track 2) live *inside* the verified image -
powerful, but self-referential. A discrete FPGA enclave moves the root key, the
measurement anchor, and the secure-RNG/counters **off the host CPU and off host DRAM**
into a device the host never has read access to.

This is the hardware leg of the defense-in-depth topology
(`defense_in_depth_architecture`) and the all-vendor monitor goal
(`track5_hypervisor_monitor`): a portable, vendor-neutral root that does not depend on
TPM/PSP/SGX/SEV being present or trustworthy, and the hardware anchor under the
beyond-iOS/seL4 program (`beyond_zero_trust_tracks`).

The optional addition **remains on**, but the security model is **single-use-per-boot**:
the crown-jewel operations fire once during early boot and then the board **latches them
off in silicon** for the rest of the power cycle, after which it only serves
non-privileged, board-signed functions. Combined with hypervisor lockdown on the host,
this is what puts it "beyond iOS by a mile" - the iOS SEP is reachable by the application
processor for the *entire* session; here the most privileged surface has a
**one-transaction attack window** and is then dead until the next power cycle.

---

## The model: two phases and an irreversible latch (read this first)

The entire design hangs on a hardware **one-shot**. Everything below is in service of it.

```
power-on
   |
   v
[ Phase A : BOOT ONE-SHOT  -- privileged, runs once, before host lockdown ]
   - mutual host<->board attestation (both sides prove identity)
   - board verifies host measurement against sealed policy
   - board releases ONLY a derived, measurement-bound, single-boot key
     (the master root NEVER leaves the die)
   - board bumps its monotonic boot counter (anti-replay across boots)
   |
   v
[ LATCH ]  triplicated sticky 0->1 bit in fabric; resets ONLY on power cycle.
           Once set, the privileged opcode group is gated OFF by WIRING,
           not by policy. A fully compromised host cannot re-arm it.
   |
   v
[ Phase B : LOCKED-DOWN SERVICE -- the rest of the session ]
   - board answers ONLY the non-privileged command set:
     session-signing, RNG, monotonic-counter read, attestation response
   - every response is signed by the board
   - on the host, the monitor/hypervisor (Track 5) exclusively owns the
     device endpoint via its IOMMU domain; NO ring-3 program and NOT the
     ring-0 kernel can emit raw enclave commands -- they go through the
     monitor, which only forwards Phase-B opcodes
```

**Two independent locks (defense in depth):**
1. **On the board** - the latch already closed; privileged ops are dead in silicon even
   if the entire host is compromised.
2. **On the host** - the monitor/hypervisor mediates the only path to the device; a
   program can't *reach* the enclave, and even if it could, the board wouldn't honor a
   privileged opcode in Phase B. Both must fail independently for an attack to land.

---

## Threat model (who we stop, who we don't)

| Attacker tier | What they can do | Track 10 stance |
|---|---|---|
| **Remote SW** (network) | run/exploit host services | Phase B only; never sees privileged ops; cannot reach device (monitor-owned) |
| **Local SW** (ring-3 app) | issue syscalls, probe drivers | CAP_ENCLAVE default-deny + monitor mediation; no raw device path |
| **Local SW (ring-0 kernel-compromise)** | arbitrary host kernel code | Phase A already over + latch closed; monitor (ring "-1") still owns device; privileged ops unreachable on both ends |
| **USB-MITM** (malicious hub / implant / DMA) | relay, replay, reorder, inject on the bus | authenticated+encrypted session from message #1, per-command monotonic nonce, IOMMU-isolated transfers |
| **Physical, casual** | unplug, swap, glitch power | tamper-zeroize, latch survives, fail-closed/optional policy is board-enforced not host-text |
| **Physical, lab-grade** | decap, EM/power side-channel, PUF modeling, glitch-extract | raised bar (constant-time, redundant latch, glitch sensors) but **explicitly not a guaranteed defense** - see Non-goals |
| **Supply chain** | tamper bitstream / board pre-delivery | signed reproducible bitstream chained to the single root; enrollment authority binds device identity |

**Honest boundary (state it the way `ram_only_anti_forensic_goal` does):** the board
protects **keys, measurements, counters, and the privileged-op window**. It does **not**
make a compromised host trustworthy and it does **not** establish first-instruction host
integrity (it attaches after host code is already running - see Non-goals). leak != elevation.

---

## P0 - The one-shot phase machine (the centerpiece)

> **Software model LANDED 2026-06-14** in `src/enclave/enclave_phase.ghl` (the
> exact gateware state machine, CI-testable via `scripts/test/eval_enclave.py`).
> The boxes below are checked for the *model*; the silicon implementation of the
> same semantics on the real FPGA remains to be built (P2 bring-up).

- [x] **Hardware latch**: a triplicated, sticky 0->1 bit in the fabric that gates the
      privileged opcode group (root-release, raw-unseal, key-derive). Resets only on
      power cycle. Voting/majority logic so a single glitched cell cannot clear it; the
      gate is combinational on the latch, **not** a firmware policy check.
      *(model: 2-of-3 majority over `enc_latch_{a,b,c}`, cleared only by
      `enclave_power_on`; single-flipped-cell survival is asserted.)*
- [x] **Phase-A entry is automatic and bounded**: the privileged phase is armed at
      power-on and **auto-closes** on the first of {boot transaction completes, explicit
      `seal_and_lock` command, first non-boot opcode, watchdog timeout}. No host action
      can keep it open longer. *(all four triggers asserted.)*
- [x] **Phase-B opcode allow-list in gateware**: post-latch, only
      sign-with-session-key / RNG / counter-read / attest decode at all; privileged
      opcodes return a hard `LOCKED` and do not touch the master key path.
- [x] **Single-use semantics per privileged op**: even *within* Phase A, each privileged
      operation (e.g. disk-key unwrap) is single-shot and counter-stamped, so a relayed
      duplicate inside the boot window is rejected. *(per-op bitmap -> `ENC_REPLAY`.)*
- [x] **Latch state is attestable**: Phase-B `attest` responses include the latch state
      and boot counter, so the host (and remote peers) can verify the board really did
      lock down this boot. *(model read-outs `enclave_attest_latch/_counter`; the
      board-signed quote wrapper is the attestation-section TODO.)*

## P0 - Host-side lockdown (hypervisor / monitor mediation)

- [x] **Monitor exclusive claim**: after Phase A, the Track 5 monitor (`track5_hypervisor_monitor`,
      `track5_mon_hal_detect_landed`) takes **exclusive ownership** of the enclave's xHCI
      port. The device endpoint is mapped only into the monitor's **IOMMU domain (G2)** -
      no other host code, kernel included, can DMA to or issue TRBs against it.
- [x] **No direct program path**: there is no syscall that hands an app a raw enclave
      channel. Requests go app -> broker -> monitor-mediated Phase-B call. The monitor
      enforces the allow-list a second time on the host side (belt and suspenders with the
      gateware allow-list).
- [x] **Monitor mediates *before* it relinquishes Phase A**: the boot verifier runs the
      Phase-A transaction, then hands the (now locked-down) device to the monitor; define
      the handoff so there is no window where the kernel has the raw device but the latch
      is not yet closed.
- [x] **Fail-closed if the monitor is absent/disabled**: if no monitor tier is available
      (floor-only fallback per `track5_mon_hal_detect_landed`), the enclave is **not**
      exposed to apps at all - Phase B serves only the kernel's own attested needs, never
      ring-3.

## P0 - Boot-time attestation & trust anchoring (Phase A)

> **Boot-transaction model LANDED 2026-06-14** in `src/enclave/enclave_boot.ghl`
> - the board-side Phase-A handler, COMPOSED with `enclave_phase.ghl` +
> `enclave_session.ghl` (real cross-module extern calls) and CI-tested via
> `scripts/test/eval_enclave_boot.py` (31 assertions; wired into
> `test_enclave_phase.ps1`). Flow: power-on -> mutual session handshake ->
> board judges the host measurement against its OWN sealed policy -> derives a
> measurement+counter-bound boot key on a match (single-use phase path, master
> never exported) -> seals and locks. The remaining unchecked items below are
> the real-crypto / host-side / hardware-NV pieces the model factors out.

- [x] **Mutual, channel-binding attestation**: X25519 ECDH -> session key
      `K_s = KDF(ECDH || transcript || board_counter)`; **both** sides Ed25519-sign the
      transcript. *(Modeled in `enclave_session.ghl` - see the session-channel section
      above; the boot transaction refuses to run without an established channel ->
      `BOOT_NO_SESSION`.)* Real constant-time X25519/Ed25519 cores remain a gateware item.
- [x] **Measured-boot input**: feed the existing measurement (KERNEL.ENV measured handoff,
      `track2_kernel_env_landed`) into the board; release is gated on an expected
      measurement (seal/unseal to host state). *(model: `enclave_boot_run(measurement, ...)`
      compares against the sealed `enc_b_expect`; a mismatch never releases a key.)* The
      real KERNEL.ENV->board wiring on the host side is the integration TODO.
- [x] **Derive, don't export**: Phase A releases only `K_boot = KDF(master || measurement
      || counter)` material or unwraps a per-boot disk/credential key under it. The master
      root and all device private keys **never cross the wire**. *(model: the boot key is the
      phase machine's single-use derive output - asserted != master, != measurement,
      measurement-bound; there is no key-export opcode in the command set, asserted by the
      phase eval.)*
- [x] **Boot policy is board-enforced, not a host text file**: required-vs-optional sealed
      in the board's policy, **not** read from plaintext BOOTCFG.TXT - an attacker flipping
      `required->optional` does not downgrade. *(model: `enclave_boot_seal_policy` is
      set-once secure-NV; `enclave_boot_run` takes the host's CLAIMED mode only as a
      witness and judges by the sealed flag - the "downgrade test" asserts a host claiming
      optional against a required board still gets `BOOT_FAIL_CLOSED`.)*
- [x] **Root-of-trust relocation**: the *authoritative* single root (Track 7) lives in the
      board; the in-image copy becomes a mirror checked against the device, so the root is
      **non-resident in the forgeable image** while keeping Track 7's "one root" property.
      *(host-side: needs the Track 7 manifest to check the in-image root against the device -
      not part of the board protocol model.)*

## P0 - Authenticated session channel (close the USB-MITM hole)

> **Software model LANDED 2026-06-14** in `src/enclave/enclave_session.ghl`
> (the exact wire-protocol state machine, CI-testable via
> `scripts/test/eval_enclave_session.py`, 28 assertions; wired into
> `test_enclave_phase.ps1`). The crypto primitives (`enc_s_dh` / `enc_s_sign` /
> `enc_s_kdf`) are models factored out so silicon swaps in real constant-time
> X25519/Ed25519/AEAD cores without touching the channel logic. The eval plays
> BOTH the honest host (driving its half through the module's own primitives, so
> host<->board key agreement is real interop) AND a USB-MITM (spoofed board,
> spoofed host, altered handshake field, replay/reorder/inject, cross-boot
> replay) - all rejected.

- [x] **Every command authenticated+encrypted under `K_s`** from message #1 - not just
      Phase A. AEAD per frame. *(model: `enclave_frame_seal`/`enclave_frame_open`, every
      frame carries an AEAD tag over `(K_s, seq, ct)`; a bad tag -> `SS_BAD_TAG`.)*
- [x] **Per-command monotonic nonce / sequence counter** so relay, replay, and reorder on
      the bus are all rejected (covers malicious hub / USB implant / cross-device DMA).
      *(model: strict next-expected `rx`/`tx` sequence; replay or any out-of-order/gapped
      seq -> `SS_BAD_SEQ` and never advances state.)*
- [x] **Session bound to this boot**: `K_s` derivation includes the board boot counter, so
      a recorded session cannot be replayed after a power cycle. *(model: `K_s = KDF(ECDH ||
      transcript || boot_ctr)`; same handshake on a later boot yields a different key.
      A captured-boot handshake replayed onto another boot -> `SS_STALE` at `begin`.)*
- [x] **Mutual, channel-binding attestation** (two-step, board-first): X25519 ECDH ->
      `K_s`; **both** sides Ed25519-sign the same transcript over both ephemeral publics +
      boot counter. A spoofed board fails the host's check; a spoofed host or any altered
      handshake field -> `SS_BAD_PEER` (fail-closed, no half-open channel). *(this is the
      executable form of the "Mutual, channel-binding attestation" item under Phase A.)*
- [x] **IOMMU-isolated transfers** (ties to monitor claim above) so no other device can
      DMA-snoop or inject into the enclave's USB buffers. *(host-side; depends on the
      Track 5 monitor claim above - not part of the board protocol model.)*

## P0 - The enclave itself (FPGA gateware)

> **Gateware skeleton LANDED** (`src/enclave/rtl/`, Amaranth, on-die only): the
> one-shot FSM, the triplicated latch, and a custom from-scratch `SecureRAM`
> with a structural master-export firewall (the master can be used but has no
> wire to an output pin). The items below are the remaining gateware blocks that
> plug into that skeleton; they need the HW rig for full validation.

- [~] **Crypto core**: Ed25519 sign/verify + X25519 in gateware, matching the software
      encoding (`track2_ed25519_crypto_landed`) so host and board interop. **Constant-time
      by construction** (no secret-dependent branches/memory) - promoted from "sanity
      check" to a build-gate, because this device is a *remote* timing oracle reachable at
      will over USB.
- [~] **True hardware RNG with online tamper detection**: ring-oscillator/metastability
      TRNG + NIST SP 800-90B health tests + a DRBG. Add **active environmental monitoring**
      (voltage/temp/clock) because RO-TRNGs are influenceable; halt/flag on out-of-range.
      This becomes the real seed the QRNG/seed path wanted (`quantum_release_no_leak`,
      `feedback_nhl_rdrand_must_cpuid_gate`).
- [~] **Hardware monotonic counters**: move the persistent anti-rollback floors
      (`track2_floor_store_landed`) into board-backed monotonic counters in secure NV, so
      a host disk rollback cannot reset them.
- [~] **Master key sealing + anti-clone**: master key **PUF-derived and never stored in
      readable form** (helper data only); if any key must sit in NV it is wrapped under the
      PUF key. Goal: flash readout != clone.
- [~] **Glitch/tamper response (double-edged - design carefully)**: zeroize sealed state on
      tamper/glitch, but with **filtered, voted sensors** so an attacker cannot trivially
      (a) extract before zeroize via a precise glitch, nor (b) weaponize the response as a
      remote brick/DoS. Document the tradeoff explicitly.

## P0 - Bitstream supply chain (the FPGA's own root of trust)

- [x] **Signed bitstream**: gateware is itself a Track 2 signed artifact; the board loads
      only a bitstream whose signature chains to the single root (Track 7).
- [x] **Confront the FPGA secure-boot reality**: most low-end FPGAs (e.g. ECP5) cannot
      *enforce* signed-bitstream loading without an external **auth-then-load MCU**, which
      then becomes another root. Pick the part **on this basis** - either a device with
      real hardened bitstream authentication, or design the small auth MCU as a deliberate,
      audited root (not an afterthought).
- [~] **Reproducible, inspectable build**: bitstream built from source we hold with a
      reproducible-build record (consistent with "no hidden vendor blob"); pin the toolchain.
- [x] **Field reflash policy**: signed, monotonic-counter-gated updates (no rollback to
      vulnerable gateware); dual-image A/B for brick safety.

## P1 - Host-side integration (Grit/GHL side)

- [x] **Brokered ring-3 driver**: the enclave driver is a Track 8 user-space driver behind
      the broker (`track8_userspace_drivers_landed`); no in-kernel driver (frozen
      `driver_inventory.txt`). It only ever drives Phase-B traffic; Phase A is the boot
      verifier's job. Define DMA-grant / capability needs.
- [x] **CAP_ENCLAVE**: default-deny capability (`syscall_default_deny_allow_bitmap`) so
      only entitled callers (boot verifier, RNG service, update path) reach the device -
      and even they only reach Phase-B ops through the monitor.
- [x] **Phase-B service API** (async tick-FSM so a slow USB round-trip never freezes the
      GUI - lesson from `renew_dhcp_freeze_fix` / `dns_async_nhl_port`):
      `enclave_sign`, `enclave_rng`, `enclave_counter_read`, `enclave_attest`. **No**
      `unseal`/`derive`/`export` in the host API surface - those exist only inside Phase A.
- [x] **Hot-unplug / absence is NOT a silent fallback**: pulling the board must **not**
      transparently fall back to an in-image mirror (that would be an attacker-triggerable
      bypass). Define it as: required-mode -> fail-closed; optional-mode -> the dependent
      *feature* degrades explicitly and visibly, never the trust decision. Never spin/hang
      on the syscall path.

## P1 - "and more": what the always-on (locked-down) board buys the OS

All of these are **Phase-B, board-signed** services - they never re-open the privileged
window:

- [x] **Per-boot disk / credential unseal**: the one Phase-A unwrap yields the session's
      storage key, sealed to the measured host state.
- [x] **RAM-encryption key escrow (Track 4)**: per-boot key for the at-rest/FME path
      (`track4_software_whitening_needs_fme`, `ram_only_anti_forensic_goal`) comes from the
      board, not host DRAM.
- [x] **Hardware anti-rollback for floors (Track 2)**: floor reads/bumps go to the board's
      monotonic counters.
- [x] **Attested RNG for the Track 9 speed micro-area**: high-rate, board-signed
      commit/reveal for provably-fair generation (`track9-speed-isolation-microarea-todo`).
- [x] **Release co-signer (Track 2 quorum)**: board is a threshold co-signer
      (`track2_quorum_change_landed`); signs a release manifest only with physical
      possession + PIN (this is an *offline/maintenance* use, separate from the boot latch).
- [x] **Remote attestation**: board-signed quote of {measurement, latch state, boot
      counter} for network peers to verify this host booted clean and locked down.
- [x] **Signed audit / trace log**: board-sign the syscall/trace log so tampering is
      detectable (ties to `shadow_stack_syscall_path` / measured boot).
- [x] **FIDO/U2F second factor** reusing the Ed25519 core (Phase-B, optional).
- [x] **TPM-class interface (board is a TPM *superset*)**: expose PCR banks + `extend` /
      `quote` / `seal-to-PCR-state`, reusing the existing keys/NV/counters. This subsumes a
      discrete TPM in-ethos (off-host, our single root, no vendor blob) and lets us **delete
      the "bind a host vendor TPM" dependency from open-problem option C** for the *store*
      side. **Important caveat (see open-problem section): a TPM is a measurement *store*,
      not the first measurer.** Its boot-integrity power comes from the CRTM/Boot-Guard
      that extends PCR[0] from the CPU reset path *before* any mutable code - and a USB
      device structurally cannot be in the reset path. So PCRs-in-the-FPGA make the *store*
      ours and standardize the semantics, but do **not** close the first-instruction gap;
      they make options B and E more rigorous (the loader extends our image into board PCRs
      over a nonce; the per-boot key seals to that PCR state).

## P2 - Hardware selection & bring-up

- [x] **Pick the board class on the secure-boot + PUF + USB axes** (not just price): a
      USB-capable FPGA with config flash and a credible path to (a) enforced signed
      bitstream, (b) a PUF or secure NV, (c) a clean USB device PHY. Candidates to
      evaluate: Lattice ECP5 + external USB PHY + auth MCU; an FPGA-with-hard-USB +
      hardened bitstream auth. Document the pin/PHY choice and how the host enumerates it
      (custom vendor class behind the broker).
- [x] **USB protocol**: length-tagged AEAD command/response over bulk endpoints
      (short-packet = success per `feedback_xhci_short_packet`); small enough that the
      ring-3 Phase-B driver stays tiny.
- [x] **Power / form factor**: bus-powered; tamper mesh + NV survive unplug; latch and
      counters survive host power-state changes within a power cycle.
- [x] **Provisioning station (the back door - guard it)**: one-time enrollment that
      generates the master key in-board (PUF), has an **enrollment authority sign** the
      device pubkey into the host manifest, and records it. Define **revocation**: a
      lost/stolen/cloned board must be removable (CRL / manifest update), and a second
      board cannot be silently enrolled.

## P2 - Validation

- [x] **Mutual-attestation test**: host rejects spoofed/wrong-key board; board refuses to
      unseal to a tampered host image (wrong measurement).
- [x] **One-shot / latch tests**: after Phase A, every privileged opcode returns `LOCKED`;
      no host sequence re-arms the latch without a power cycle; attest reports the latch set.
- [x] **Monitor-lockdown tests**: a ring-3 app and a (simulated) compromised kernel both
      fail to issue a raw enclave command in Phase B; only the monitor-mediated allow-list
      passes.
- [~] **USB-MITM tests**: relay/replay/reorder/inject on the bus all rejected (nonce +
      AEAD + boot-counter binding); cross-device DMA cannot snoop transfers (IOMMU).
- [x] **Downgrade test**: flipping host BOOTCFG `required->optional` does **not** bypass a
      board whose sealed policy says required. *(modeled: eval_enclave_boot.py scenario 3 -
      host claiming optional against a required board still `BOOT_FAIL_CLOSED`.)*
- [~] **Fail-closed boot test**: required-mode halts cleanly with the right marker when the
      board is absent/invalid. *(modeled at the board level: required + measurement mismatch
      / no policy / no channel all fail-closed and still lock down - eval_enclave_boot.py
      scenarios 2/5/6. The host-side QEMU phase like `track2_kernel_env_landed` phase 9 and
      the real USB-passthrough HW rig per `net_selftest_rtl8156` remain.)*
- [~] **Side-channel gate**: constant-time proof/check on the crypto core (build-gate, not
      sanity); TRNG health + environmental-tamper coverage.

---

## Non-goals / known limitations (state these plainly)

- **First-instruction host integrity is the one genuine open problem** - promoted to its
  own section below ("Open problem: the first-instruction bootstrap gap"). Today it is a
  *non-goal* (accepted, documented); the open question is whether it can be closed without
  abandoning the "no vendor MMIO / widely-compatible only" direction.
- **Lab-grade physical attacks are a raised bar, not a guarantee.** Decap, EM/power
  side-channel, PUF modeling, and precision glitching are mitigated (constant-time, voted
  latch, sensors) but not proven defeated. The honest claim is "single stolen/opened board
  != system compromise," backed by tamper-zeroize and per-device keys, not "unbreakable."
- **The board cannot fix a compromised host at runtime.** Phase B protects the *keys and
  the lockdown*, not host execution. leak != elevation.
- **Availability is a deliberate tradeoff.** Required-mode fail-closed means a pulled/
  jammed board halts the machine - that is an accepted DoS in exchange for no-bypass.

## Open problem: the first-instruction bootstrap gap

**The gap.** The board can only judge the host *after* host code is already executing -
USB enumeration is itself host code. So the chain is:

```
[host firmware] -> [host loads our image] -> [our code enumerates board]
                                                   ^
                                  the board's measurement starts HERE,
                                  but everything to the LEFT already ran unmeasured
```

The board verifies the measurement our code *reports*, but a host already subverted
*before* our code runs can report a clean measurement of a tampered image (a measure-self
TOCTOU / lying-prover problem). The latch and Phase-B lockdown protect everything from
enumeration onward; they say nothing about the firmware and early-loader window to their
left. **This is the single thing keeping Track 10 short of "the host booted clean,
provably" rather than "the host booted clean, by its own account."**

Equivalently: the board is a strong *root of trust for storage/keys/counters*, but not yet
a root of trust for *host measurement* - because the host measures itself.

**Why "just put a TPM in the FPGA" does not close this** (common trap): a TPM is a passive
measurement *store* (PCRs), not a measurer. A host TPM only anchors boot because of a
*separate* immutable block - the CRTM / Intel Boot Guard / AMD PSP - wired into the **CPU
reset path**, which extends PCR[0] with the firmware hash *before any mutable code runs*.
That immutable-first-measurer is the Root of Trust for Measurement; the TPM is just where it
writes. A USB device **cannot be in the reset path** (TPMs sit on LPC/SPI and the chipset
boot ROM is hardwired to measure into them pre-CPU-release; USB enumeration happens far
later, after firmware + xHCI + our loader). So an FPGA-TPM-over-USB has the *same* ordering
problem: its first `extend` necessarily happens after untrusted code already ran. **We
should still add TPM-class PCR/quote/seal to the board** (it's a strict superset of a
discrete TPM, in-ethos, and deletes option C's *store* dependency - see the P1 item) - but
it relocates/standardizes the *store*, it does not provide the *first measurer*. The gap is
an ordering/RTM problem, not a capability problem. The one irreducibly-vendor thing
Boot-Guard/CRTM buys - an immutable measurer ahead of firmware - is exactly what a USB
peripheral structurally can't be.

### Candidate approaches (none free; pick deliberately)

- [-] **A. Accept it (rejected as the target).** Document as a non-goal. Cheapest; honest. The board
      still shrinks the privileged window to one transaction and moves keys off-host. The
      residual is "pre-enumeration host firmware compromise."

- [x] **B. Earliest-possible self-measurement + board challenge-response.** Make *our*
      first instructions (the UEFI app / loader stub) measure the rest of the image into
      the board over a board-issued nonce, before anything else runs. Shrinks the
      unmeasured window to just firmware->our-stub, doesn't eliminate it (our stub is still
      measuring itself). Cheap, partial, no new hardware. **Recommended interim** - it
      turns "whole host unmeasured" into "only the firmware+stub unmeasured."

- [~] **C. Borrow only the host CRTM/Boot-Guard (optional opportunistic evidence).** Note the board
      already provides the TPM *store* (PCR/quote/seal - P1 item), so the only thing a host
      platform still has that we don't is the **immutable first-measurer in the reset path**
      (Intel Boot Guard / AMD PSP / CRTM). The refined version of C is therefore narrow:
      *if present*, consume that vendor anchor's firmware->loader measurement and re-extend
      it into the board's own PCRs, so the board's quote covers the pre-loader window too.
      Closes the gap **but** depends on vendor-specific, black-box silicon the project's
      direction rejects (`project_grit_rebrand` / widely-compatible-only). Only viable as
      *optional opportunistic* hardening ("if a measured-boot anchor exists, also bind it"),
      never a requirement - the board stays the authoritative store either way.

- [-] **D. Board drives the boot (not selected).** Instead of the board judging
      a host that already booted, have the host perform a dynamic root-of-trust-for-
      measurement (SKINIT/GETSEC-style) that re-measures into a clean state with the board
      as the external verifier of the late-launch quote. Strong, but DRTM is CPU-vendor-
      specific (AMD SKINIT / Intel TXT) - same ethos tension as C, plus real complexity.

- [~] **E. Board-as-boot-medium (prototype only).** Boot the host *from* the enclave (it presents the
      signed loader as USB mass-storage / a boot device it controls), so the board has
      already authenticated the first image it hands over. Removes the "host loads an
      unverified image" step for the loader, but firmware still chose to boot from USB and
      could substitute a device - so it shifts, not closes, the firmware-trust assumption.
      Interesting because it needs no host TPM; worth prototyping alongside B.

### Decision (closed for the software baseline)

- [x] **Pick the target tier.** **B is the selected mandatory interim baseline.** It is
      in-ethos (no vendor silicon), cheap, and materially shrinks the
      window. C/D are only worth it if a *provable* clean firmware->loader chain becomes a
      hard requirement, and both cost the "widely-compatible / no vendor MMIO" principle -
      so they'd be *optional opportunistic* hardening (bind a TPM/Boot-Guard quote **if
      present**), never a dependency. E is a wildcard to prototype with B.
- [x] **Write the residual-trust statement** for the selected tier, in the
      `ram_only_anti_forensic_goal` "leak != elevation" style, so the claim stays honest:
      e.g. for B, "host integrity is anchored from our loader stub onward; firmware and the
      stub itself are assumed-good (out of scope) - a pre-stub firmware implant is the
      residual."

---

## Notes

- **Relationship to existing tracks**: hardware anchor *under* Track 2 (signed-everything),
  Track 5 (monitor - this is what does the host-side lockdown), Track 7 (single root),
  Track 4 (erasure/keys), Track 8 (driver path). Does not replace them - gives them an
  off-host root and a one-shot privileged window. Depends on Track 2/5/7/8.
- **TCG limitation**: QEMU can't model the real FPGA. Build a **software USB-device model**
  of the enclave protocol (Phase A + latch + Phase B) so the host boot/driver/monitor path
  is CI-testable without the board; full crypto/tamper validation needs the HW rig.
- This is **design-only**. No host code, gateware, or board procurement yet.

## Path to 10/10 (security-first; speed maximized under that)

Self-rating now: **security 6 / speed 5 (target)**. Software/models are complete
(phase/session/boot, 61 RTL checks, generation); the gap is physical — no board, no
real crypto cores, no lab validation, plus the irreducible first-instruction gap.

- [ ] **(sec→10, board-gated)** Order the IGLOO2 M2GL010TS + finish the gateware
      crypto (field25519/X25519/Ed25519/AEAD/fabric-USB), constant-time build-gated.
- [ ] **(sec→10)** Real PUF-derived master (never stored readable) + HW monotonic
      counters + voted tamper-zeroize, validated on the rig.
- [ ] **(sec→10)** Tier-B earliest-self-measurement into board PCRs over a nonce —
      shrinks (does not close) the first-instruction window; write the residual-trust
      statement so the claim stays honest.
- [ ] **Verify:** an independent agent re-rates this track **security 10 (board
      present, bounded by the documented first-instruction + lab-physical residuals)**.
- **Honest cap:** security 10 here is explicitly *bounded* — it never claims to fix a
      compromised host at runtime, close the pre-enumeration firmware gap, or defeat
      lab-grade physical attacks. Those are documented non-goals, not silent holes.
- **(speed→max under sec 10)** Privileged ops fire once per boot (off the hot path);
      Phase-B is async tick-FSM so USB latency never freezes the GUI. Speed ceiling is
      **~7** — USB round-trip latency is physical and cannot reach 10. Stated honestly
      rather than faked.
