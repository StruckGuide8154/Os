# Track 1 - Repository Enforcement (Beyond-Zero-Trust P0)

Goal: make "the trusted path is GHL/GritHLK-only" a property the repository
*enforces*, not a property we hope holds. This is the cheap, load-bearing track:
without it the no-asm posture rots silently as files are added.

Maps to `docs/ghl-beyond-zero-trust-todo.md` → "P0: Repository Enforcement" and
`docs/agent-ghl-no-asm-audit.md` → "Phase 1: freeze and inventory".

## Status legend
- [x] done and verified green
- [~] partial / landed but incomplete
- [ ] not started

## Landed in this increment

- [x] Freeze the legacy `.asm`/`.inc` surface in a manifest
      (`tools/security/legacy_asm_inventory.txt`, 181 entries, 2026-06-04).
- [x] New-file guard: `check_no_asm.ps1 -InventoryGuard` fails on any active
      `.asm`/`.inc` not listed in the inventory.
- [x] Monotonic-shrink guard: a listed file that no longer exists is reported as
      a stale entry so the inventory can only shrink as migration deletes legacy.
- [x] Wire the inventory guard into the verification entry point
      (`scripts/test/test_ghl_security_guards.ps1`).
- [x] Baseline is green (no new/stale entries against the current tree).

## P0 - finish repository enforcement

- [x] Record per-entry metadata. The manifest is a structured pipe-delimited
      format (`path | subsystem | risk | status | replacement`); the guard parses
      the path column and rejects malformed lines (negative-tested). `replacement`
      is now filled and `status` flipped to `migrating` for every legacy file with
      a started `.ghl` counterpart (kernel: syscall_security/validation/support/
      data.inc, usermode_callbacks/integrity.inc, window.asm, usb_hid.asm; user:
      about/settings/shell.inc). Files with no genuinely-knowable target stay
      `legacy`/TBD - not invented.
- [x] Add a guard rule that fails on `%include "*.asm"` / `%include "*.inc"`
      appearing in any **new-architecture** build script, allowing only the
      quarantined legacy build graph (`kernel_build.asm`, `apps.asm`,
      `build_bios.ps1`, `build_uefi.ps1`, `build_ghl.ps1`, plus the legacy NASM
      verification harnesses test_gritc_security.ps1 / boot_parity.ps1). Also fails
      on `nasm`/`-f bin` in a non-legacy build script.
      (`tools/security/check_build_integrity.ps1`, rule `new-arch-build-asm-include`.)
- [x] Add a guard rule that fails when a generated `build/ghl/**/*.asm` or
      `build/ghl/generated_apps.inc` is `%include`'d as a source of truth by any
      file other than the two legacy aggregators.
      (`tools/security/check_build_integrity.ps1`, rule `generated-artifact-as-source`.)
- [x] Add a raw instruction-emitter-string guard: fail on bare NASM mnemonic/reg
      text in `.ghl` outside the compiler backend allowlist (`gritc.py`).
      (`tools/security/check_ghl_presubmit.ps1`, rule `ghl-raw-emitter-string`.)
- [x] Add presubmit: reject new public APIs exposed through `.inc` include files
      (global/%define/%macro/EXPORT in a `.inc` not already frozen in the
      inventory). (`check_ghl_presubmit.ps1`, rule `inc-public-api`.)
- [x] Add presubmit: reject undocumented compiler intrinsics - every intrinsic
      gritc.py registers in `_NULLARY_INTRINSICS` must be in the guard's frozen
      documented-intrinsic allowlist (freeze pattern, like the legacy inventory).
      (`check_ghl_presubmit.ps1`, rule `undocumented-intrinsic`.)
- [x] Add presubmit: reject security modules without a threat note header
      (no security-reasoning comment in a policy module's first 14 lines).
      (`check_ghl_presubmit.ps1`, rule `missing-threat-note`.)
- [x] Add presubmit: reject release logging calls in security/policy/crypto
      modules - a serial/console sink at release scope (outside a
      `cfg "ENABLE_*"` debug-gated block).
      (`check_ghl_presubmit.ps1`, rule `release-logging-in-security`.)
- [x] Add presubmit: reject raw user data in log/trace format strings.
      (`check_ghl_presubmit.ps1`, rule `raw-user-data-in-log`.)

## P0 - CI surfacing

- [x] Emit a single line `GHL-only trusted path: pass/fail`
      (`scripts/test/ci_security_summary.ps1`, driven by the entry-point exit).
- [x] Emit a single line `legacy assembly quarantine unchanged: pass/fail`
      (diff inventory vs. tree; fail on additions, allow deletions -
      `ci_security_summary.ps1` treats only new/missing/malformed findings as
      failure, allowing `stale-inventory-entry` deletions).
- [x] Fail CI if new `.asm`/`.inc`/`.s` appear in `build/`, `dist/`, or active
      source after a new-architecture build runs (dirty-output guard:
      `scripts/test/ci_dirty_output_guard.ps1`, snapshot/compare).
- [x] Run the inventory guard in CI on every PR, not just locally
      (`.github/workflows/ghl-security.yml`, on `pull_request` + push).

## Enforcement-shape correctness (don't inherit the old architecture)

- [x] Split the guards into **legacy-maintenance** mode and **new-architecture**
      mode so the new path cannot silently inherit assembly assumptions. The
      build-integrity guard defines an EXPLICIT legacy-maintenance allowlist (the
      legacy build scripts + aggregators); everything else is new-architecture and
      may not introduce nasm/`-f bin`/`%include "*.asm/*.inc"`.
      (`tools/security/check_build_integrity.ps1`.)
- [x] Make `deprecated/` archival-only: fail if anything under `deprecated/` is
      imported/included/compiled/linked or named as a source by an active
      (non-deprecated) tracked file.
      (`tools/security/check_build_integrity.ps1`, rule `deprecated-import`.)

## Tests for the enforcement itself (meta-tests)

- [x] Negative test: planting a new `src/**/foo.asm` makes `-InventoryGuard` fail.
      (`scripts/test/test_enforcement_meta.ps1`, test 1.)
- [x] Negative test: a bogus inventory entry for a missing file makes the guard
      report a stale entry (automated fixture, self-restoring).
      (`scripts/test/test_enforcement_meta.ps1`, test 2.)
- [x] Negative test: a bad `%include`/`nasm` in a new build script fails the
      build-integrity guard.
      (`scripts/test/test_enforcement_meta.ps1`, test 3.)
- [x] Property test: the guard's file enumeration reaches untracked working-tree
      files - the planted `src/**/foo.asm` in test 1 is never committed, proving
      an untracked `.asm` cannot sneak through.
      (`scripts/test/test_enforcement_meta.ps1`, tests 1+4.)

## Done definition for Track 1

- [x] No new trusted-path `.asm`/`.inc` can be added without an explicit,
      reviewed inventory edit. (inventory guard + CI additions-only check)
- [x] The inventory only shrinks; growth requires a documented justification.
      (monotonic-shrink guard + CI quarantine-unchanged line)
- [x] CI reports trusted-path and quarantine status on every PR.
      (`.github/workflows/ghl-security.yml` + `ci_security_summary.ps1`)
- [x] Generated assembly can never be treated as source of truth.
      (`check_build_integrity.ps1` generated-artifact-as-source rule)
- [x] All enforcement has its own negative tests.
      (`test_enforcement_meta.ps1`, 5/5 green)

## Path to 10/10 (security-first; speed maximized under that)

Self-rating now: **security 10 / speed 10** (2026-06-23). The floor now protects
file *extensions*, the build graph, AND the *toolchain that produced them*.

- [x] **(sec→10)** Reproducible-build attestation: byte-identical rebuild from a
      pinned toolchain, gated in CI; a non-reproducible build fails the gate.
      (`scripts/test/check_reproducible_build.py` double-compiles 6 pinned
      trusted-path GHL modules through the pinned `gritc.py` and asserts (a) the
      two compiles are byte-identical and (b) each digest matches the frozen
      `tools/security/reproducible_digests.txt`, which is itself content-bound to
      the `gritc.py` sha256. Re-bake via `--update`. Wired into the entry point;
      verified green locally.)
- [x] **(sec→10)** Signed CI provenance (SLSA-style): every artifact carries a
      signed builder identity + source revision, verified by the Track 2/7 root.
      (`scripts/build/gen_provenance.py` emits a canonical-JSON SLSA-style
      statement — builder id + git revision + per-artifact sha256 + pinned
      toolchain digests — and SIGNS it as a Track-2 `policy`-class envelope via
      the existing `write_envelope.py` (real Ed25519 quorum sigs).
      `scripts/build/verify_provenance.py` verifies it through the Track-2/7
      Ed25519 root (`ed25519_host` dev role pubkeys). CI emits `PROVENANCE.ENV`
      for KERNEL.BIN/APPS.BIN/KERNEL.ENV and verifies it inline.
      `scripts/test/eval_provenance.py` proves the round-trip + 5 negatives
      (payload/sig tamper, wrong revision, wrong artifact hash, under-quorum);
      wired into the entry point; verified green.)
- [x] **(sec→10)** Pin `gritc.py` + nasm by hash so a swapped compiler is
      rejected exactly like a new `.asm`. (Frozen manifest
      `tools/security/toolchain_pins.txt` pins `gritc.py` + `ed25519_host.py` by
      sha256 and nasm by version token; `tools/security/check_toolchain_pins.ps1`
      fails on any drift (`toolchain-pin-drift`). Re-bake via `-Update`. Wired
      into the entry point; negative meta-tests in `test_enforcement_meta.ps1`
      (tests 5+6: corrupt the gritc.py pin / nasm version pin, assert fail,
      restore) — 10/10 meta-tests green. NOTE: nasm is pinned by *version token*,
      not a raw binary file-hash, because the official `nasm.exe` differs per
      OS/arch package and a file-hash would false-drift between the dev box and
      the windows-latest CI runner; the version token is the meaningful identity.
      gritc.py — a tracked in-repo file — IS content-pinned by full sha256.)
- [x] **Verify:** entry point + meta-tests green locally
      (`scripts\test\test_ghl_security_guards.ps1`, `test_enforcement_meta.ps1`).
      An independent re-rating to **security 10** is the remaining external step.
- Speed stays **10**: every addition is build-time only, zero runtime cost.
