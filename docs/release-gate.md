# Release Gate - making a whole class of audit findings unshippable

The 2026-06-13 static-analysis audit (and the earlier 2026-06-11 one) keep
producing findings because, historically, the build trusted the developer. The
structural answer is not to fix six findings - it is to make the **only way to
produce a release artifact** be to pass an adversarial, fail-closed gate that
re-runs the auditor's own analysis on every build. New defects in that class then
cannot leave the door.

This is the offline-static-analysis half of [Track 7](track7-public-root-of-trust-todo.md)
(Kerckhoffs: the released image is assumed fully public; security rests only on a
private key that never ships and on per-machine/runtime-derived secrets). The
runtime-compromise half (a privileged component reading DRAM / rewriting a `.bin`)
is Tracks 4/5/6 - see Track 7 §P3.

## The gate

`scripts\build\build_uefi.ps1 -Release` runs, after assembling and signing the
ESP, a mandatory chain that exits non-zero (failing the build) on any violation:

| Check | Tool | Finding class closed |
|---|---|---|
| Each payload hash is pinned into the signed loader | `check_release_artifacts.py` (`digest in loader`) | 1 - loader can't be swapped to a generic one |
| Per-app manifest covers the **exact** released APPS.BIN (recomputed) | `gen_app_manifest.py --verify-blob` | 1 - no stale/partial manifest |
| No symmetric **trust key** ships (`ISBOLBRG`, `GRMANIK!`) | `check_release_artifacts.py` (`FORBIDDEN_TRUST_KEYS`) | 5 / the disease |
| No debug/security serial strings ship | `check_release_artifacts.py` (`FORBIDDEN`) | 4 |
| Not signed under the dev test-DB cert (production) | `check_release_artifacts.py` (`--allow-test-cert`) | 5 |
| Envelopes carry a nonzero policy-dependency commitment | `check_release_artifacts.py` | - |
| Private QRNG seed never appears in the image | `check_no_shipped_secrets.ps1` | 4 (seed) |

## The proof the disease is cured

`scripts\test\test_forge_resist.ps1` is the regression that proves it, not asserts
it: it flips one byte of the released `APPS.BIN`, then - doing everything an
attacker can recompute from the public image alone - confirms the **Ed25519-signed
manifest rejects the forgery**, while the honest blob passes. Because the 32-byte
manifest trailer is now a *keyless* SHA-256, the attacker can freely recompute the
checksum and still cannot produce a valid signature over the changed payload. The
signature, not any shipped secret, is what stops them.

## Why a targeted scan, not a blind entropy scan

A released image legitimately contains high-entropy data: Ed25519 public keys and
quorum signatures, and the public `SHA-256(seed)` QRNG commitment. A blind entropy
scan would false-trip on all of these. The gate instead matches **precise byte
patterns** for known-secret material - zero false positives, and it is the exact
thing that must be absent.

## What it does NOT cover (by design)

- **Obscurity is not a control** (findings 2, 3). Relocation tables and syscall
  stubs are public in any released binary; the gate does not try to hide them.
  Track 7 §P2 instead removes the reliance on their secrecy (high-half virtual
  KASLR; capability-enforced syscall handlers).
- **Runtime compromise** is Tracks 4/5/6 (Track 7 §P3), not this gate.

## Extending the gate

When the next audit finds a new shippable defect, the fix is two-fold: remove the
defect, **and** add the invariant to `check_release_artifacts.py` (or a sibling
guard) so it can never ship again. The gate is the living encoding of every audit
we have already answered.
