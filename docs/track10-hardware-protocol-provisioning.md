# Track 10 Hardware, Protocol, and Provisioning Decisions

Status: design and CI models only. No board has been purchased, electrically
validated, provisioned, or certified.

## Board-Class Decision

The reference family is **Microchip PolarFire FPGA** (non-SoC preferred; exact
part/package remains a schematic qualification decision), with hardened on-die
authenticated configuration, PUF-protected key services, secure nonvolatile
state, and an external USB 2.0 high-speed ULPI device PHY. ECP5 plus an auth MCU
is rejected as the baseline because it adds a second mutable root and ECP5 does
not itself enforce the required authenticated configuration policy.

The machine-readable decision is `docs/track10-board-selection.json`. PolarFire
is the reference because Microchip documents authenticated/encrypted programming,
an SRAM-PUF root, sNVM, tamper signaling, and configuration digests. Marketing
claims are not validation: the exact part's guides, errata, fuse policy, and
physical samples remain release evidence.

Primary references reviewed 2026-06-14:

- [PolarFire Security User Guide](https://www.microchip.com/content/dam/mchp/documents/FPGA/ProductDocuments/UserGuides/Microchip_PolarFire_FPGA_and_PolarFire_SoC_FPGA_Security_User_Guide_VA%20%282%29.pdf)
- [PolarFire Programming User Guide](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/UserGuides/PolarFire_FPGA_and_PolarFire_SoC_FPGA_Programming_User_Guide_VB.pdf)
- [PolarFire System Services User Guide](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/UserGuides/PolarFire_FPGA_and_PolarFire_SoC_FPGA_System_Services_User_Guide_VC.pdf)
- [PolarFire configuration digests](https://onlinedocs.microchip.com/oxy/GUID-DF33D7C4-5604-4C6B-92AF-8C864323C016-en-US-14/GUID-50C3898F-EDDC-43BC-88FA-4711A30B31B6.html)

D+/D- protection, VBUS sensing, clock, PHY reset, and power sequencing are fixed
in the future schematic. Normal operation enumerates one vendor-specific
interface with bulk OUT endpoint 1 and bulk IN endpoint 1. It exposes no HID,
CDC, DFU, mass-storage, or normal-operation control-transfer tunnel.

## USB Wire Contract

`src/enclave/usb_protocol.py` is the executable model. One transfer is one frame:

```
magic[4] version:u8 kind:u8 flags:u8 header_len:u8
sequence:u64-le payload_len:u32-le ciphertext[payload_len] tag[16]
```

The header is AEAD associated data. Direction, sequence, boot-bound key, and
exact length are authenticated. Plaintext is capped at 4096 bytes. A short USB
packet ends a transfer but never overrides the signed length; an exact packet
multiple needs a terminating ZLP. Truncation, extension, oversized lengths,
wrong direction, bad tags, replay, and gaps fail before dispatch without state
advance. The Python AEAD is a protocol test primitive, not production crypto.

## Power and Form Factor

The target is an enclosed bus-powered USB device, within one USB 2.0 unit load
until configured and within negotiated current afterward. Brownout supervisors
hold FPGA and PHY reset until rails and configuration authentication are valid.
Host suspend must retain port power; VBUS loss in required mode is device loss,
not a silent trust downgrade.

The latch resets only on actual board power-on. Counters, revocation epoch, A/B
metadata, and PUF helper data are nonvolatile. Session/derived keys and latch
replicas are volatile and zeroized on reset/tamper. Sensors are filtered and
voted so one untrusted sample cannot erase identity. `src/enclave/power_model.py`
models retained-VBUS suspend versus real power loss. These remain schematic
requirements, not electrical claims.

## Signed Build Manifest

`scripts/build/enclave_bitstream_manifest.py` emits canonical JSON signed by the
Track 2 UPDATE role. DEV keys are public CI keys; production uses the HSM quorum.

| Field | Contract |
|---|---|
| `schema` / `artifact` | Fixed `grit.enclave-bitstream.v1` / `fpga-bitstream` |
| `board_class` | Restricted identifier matching the provisioned board class |
| `slot` | `A` or `B` |
| `version` | Unsigned 64-bit, at least 1 |
| `rollback_counter` | Unsigned 64-bit, at least 1; strictly above floor to stage |
| `bitstream_sha256` | Lowercase SHA-256 of exact programming bytes |
| `source_sha256` | Digest over normalized sorted path/content tuples |
| `sources` | Nonempty sorted unique relative paths; no traversal/backslashes |
| `toolchain` | Nonempty sorted exact tool/version map |
| `build_epoch` | Exactly 0, removing wall-clock nondeterminism |
| `root_key_id` | SHA-256 identifier of trusted UPDATE verification key |

The outer record contains exactly `manifest`, `signature`, and `signer_role`.
Duplicate JSON keys, noncanonical encoding, malformed types, boolean integers,
unknown fields, path escape, source drift, payload drift, and wrong root key fail
closed. The native PolarFire package must also use hardened authentication: the
Track 2 signature authorizes release, while native authentication enforces what
the device programs. Neither substitutes for the other.

## A/B Update Policy

Only a newer authenticated image may stage into the inactive slot. The executable
controller transitions as follows:

| Current | Event | Next | Security effect |
|---|---|---|---|
| `stable` | valid newer inactive image | `staged` | Floor unchanged |
| `staged` | begin trial | `trial` | Boot pending slot once; retain previous slot |
| `staged` | power loss | `stable` | Discard unconfirmed stage |
| `trial` | valid device-signed self-test | `stable` | Commit slot and ratchet floor |
| `trial` | failure/watchdog/power loss | `stable` | Restore previous slot; floor unchanged |
| any | invalid schema/signature/digest, stale counter, active overwrite | unchanged | Reject |

On hardware, confirmation is emitted only after configuration-digest, crypto,
TRNG, secure-NV, USB enumeration, and latch self-tests. Recovery may select an
older physical slot only if its counter remains at or above the floor. Deployed
units have no downgrade strap.

## Provisioning and Revocation

Provisioning is a one-time, two-operator isolated ceremony:

1. Verify serial, lot, factory image, and station software digest.
2. Generate the PUF-bound identity key in-board; raw PUF/private material stays in-board.
3. Verify a fresh challenge proof-of-possession.
4. Authority-sign `{device_id, public_key, board_class, minimum_bitstream_counter, enrollment_epoch}`.
5. Append certificate/inventory, lock provisioning, and prove a second command fails.

`scripts/build/enclave_provisioning.py` implements exact device-certificate and
revocation schemas with real Ed25519 CI signatures. Revocations bind device ID,
public-key digest, enumerated reason, strictly forward epoch, and optional
replacement ID. Tests reject forgery, duplicate ID/key, stale epochs, and silent
replacement. Replacement requires a new authority-signed certificate at the
current epoch. Board-backed epochs prevent CRL deletion or old-manifest replay
from resurrecting a device.

## Bootstrap Tier Decision

Tier B is mandatory interim policy. The earliest project loader gets a fresh
board nonce, hashes the remaining loader/image before launch, and extends
`PCR = SHA256(old_PCR || nonce || image_digest)`. The executable model is
`src/enclave/bootstrap_model.py`. Tier C evidence may be bound opportunistically;
Tier E remains a prototype.

Residual trust: integrity starts at the measured-loader handoff. Firmware and
the first stub are assumed good; a pre-stub implant may lie or redirect control.
The board still protects key release and rollback state. Leak is not elevation,
and Tier B is not first-instruction proof.

## Design/CI Validation Coverage

`scripts/test/test_enclave_phase.ps1` aggregates protocol, supply-chain,
provisioning, power, bootstrap, session, boot, host, and RTL suites. This ownership
covers:

- USB malformed lengths/tags/direction, replay/gaps, ZLP behavior, and post-lock denial.
- Exact manifest schema/canonical encoding, root/signature/digest/provenance checks.
- Full stage/trial/confirm/fail/power-loss A/B transitions and floor behavior.
- One-time enrollment, proof-of-possession, forgery, revocation, and replacement.
- Board-decision requirements and suspend/power/NV persistence policy.
- Tier-B nonce freshness, stale replay, altered measurement, and PCR extension.

## Physical-Only Residuals

1. Select exact FPGA/package, ULPI PHY, flash, supervisors, sensors, connector,
   enclosure, tamper mesh, and production components against errata/availability.
2. Complete schematic/layout, sequencing, USB SI/compliance/enumeration,
   suspend/resume, hot-unplug, current, thermal, EMC, and form-factor testing.
3. Prove configuration authentication precedes fabric, debug is locked, fuses are
   irreversible, and no recovery/programming mode bypass exists.
4. Build real programming files and prove reproducibility, or disclose and pin
   every unavoidable vendor transformation.
5. Implement/time-close real Ed25519/X25519/AEAD, TRNG/DRBG health logic,
   secure-NV counters, PUF derivation, environmental sensing, and zeroization.
6. Validate entropy, timing/power leakage, voltage/clock/temp glitch response,
   tamper filtering, zeroization latency, and anti-DoS behavior.
7. Interrupt real programming at every phase; verify A/B recovery, configuration
   digests, self-test confirmation, monotonic persistence, and endurance.
8. Run production provisioning; prove private/PUF non-export, provisioning lock,
   inventory audit, revocation distribution, stolen-board removal, and replacement.
9. Run real xHCI/IOMMU isolation and USB-MITM/DMA tests with the monitor. Models
   do not prove bus ownership or electrical isolation.
10. Validate earliest-loader integration on supported firmware. Tier B still
    cannot prove firmware or the first stub.
