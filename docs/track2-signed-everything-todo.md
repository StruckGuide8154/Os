# Track 2 - Signed Everything (Beyond-Zero-Trust P0 keystone)

Goal: every artifact the system trusts arrives inside one canonical **signed
envelope**, and nothing unsigned, malformed, mis-targeted, expired, downgraded,
replayed, or wrong-role is ever accepted. This is what lets GritOS exceed iOS on
the axis iOS does not cover: *no single key and no single component can mint
trusted state.*

Maps to `docs/ghl-beyond-zero-trust-todo.md` → "P0: Signed Everything",
"P0: Threshold Signing", and parts of "P1: Crypto / Parser / Schema Safety".
Spec: `docs/signed-artifact-envelope.md`.

## Status legend
- [x] done and verified green
- [~] partial / landed but incomplete
- [ ] not started

## Landed in this increment

- [x] Canonical envelope spec (`docs/signed-artifact-envelope.md`, v1).
- [x] Structural policy kernel `src/tools/security/signed_envelope.ghl`:
      magic, schema-version, type/domain range, strict-ascending (canonical +
      dedup) field ordering, in-bounds/no-overflow offsets, required-field
      bitmask per artifact class, composed `security_envelope_accept`.
- [x] Compiles `--target kernel --forbid-asm --deny-unsafe`.
- [x] Pass/fail fixtures + wired into `test_ghl_security_fixtures.ps1`,
      `test_ghl_security_guards.ps1`, and the no-asm module manifest.

## P0 - complete the envelope

- [x] The presence bitmask currently encodes the *mandatory* fields; add the
      `TARGET_DEVICE` semantics to `signed_artifact_check` (device / device-class
      match) so cross-device replay is rejected, not just structurally required.
- [x] Add a canonical-serialization predicate set so the *signed bytes* are
      unambiguous (tie envelope ↔ `schema_canonical_check`): reject non-minimal
      widths, duplicate TLV ids (already via ordering), and trailing garbage.
- [x] Add `security_envelope_payload_region_ok` to assert payload + signature
      block exactly tile `[header_len, total_len]` with no gaps/overlap.
- [x] Add a streaming/bounded verification contract: max envelope size, max
      field_count (have 64), max payload - all checked before allocation.
- [x] Constant-time comparison helper for hash/MAC equality (P1 crypto rule).

## P0 - threshold signing on top of the envelope

- [x] Define threshold policy per artifact class (boot accept, kernel/hypervisor
      activation, driver, app, policy, config, firmware, recovery, key rotation,
      key revocation) - `security_threshold_class_min_count` +
      `security_threshold_class_required_mask` + `security_threshold_class_quorum_ok`
      added to `src/tools/security/threshold_check.ghl` (2026-06-09).
- [x] `COSIGNER_ROLES` field must be cross-checked against the class threshold:
      reject if quorum/required roles unmet. DONE (2026-06-09):
      `envelope_reader.ghl` captures min_count/allowed_mask/required_mask from
      the COSIGNER_ROLES TLV and calls `security_threshold_class_quorum_ok`
      returning `ENVR_ERR_QUORUM = 21` on failure. Three new executable negative
      tests: `quorum_count_below_class_floor`, `quorum_missing_required_role`,
      `quorum_allowed_mask_too_narrow`.
- [x] Reject duplicate signers, wrong-role signers, threshold downgrade.
      `security_threshold_rule_valid` + `security_threshold_has_duplicate3` +
      `security_threshold_approves3` already in `threshold_check.ghl`.
      `quorum_allowed_mask_too_narrow` covers the downgrade case.
- [x] Quorum change requires BOTH old and new quorum approval.
      DONE (2026-06-10): `quorum_change_admit` + `boot_quorum_check` in
      `envelope_gate.ghl` - the gate keeps the ACTIVE per-class quorum table
      (init from the build-time class policy); a change arrives as a staged
      `\EFI\BOOT\KQUORUM.ENV` policy-class envelope (loader publishes at
      VBE_INFO+0xA0/0xA8) carrying an 18-byte `QCH1` payload (kind + old rule
      + new rule). Admission requires: fresh full Ed25519 verify (never the
      hash cache), declared old rule == active rule (stale/replayed change
      rejected, GATE_ERR_QCH_STATE=25), `security_threshold_rule_valid` +
      `security_threshold_change_valid` non-downgrade (required roles can only
      be added; GATE_ERR_QCH_RULE=26), and the verified signer-role set
      (`ed25519_last_verified_roles`) satisfying BOTH the old AND new quorum
      (GATE_ERR_QCH_APPROVAL=27). An accepted change RATCHETS: every later
      `artifact_gate_admit` checks the envelope's declared (signed,
      cache-keyed) quorum rule against the active table
      (GATE_ERR_QUORUM_RATCHET=28) - binding even on hash-cache hits.
      Verified: 11 host checks in `eval_ed25519.py` §8 + QEMU phases 5/6 of
      `test_track2_envelope_callsites.ps1` ("[QUORUM] accepted" /
      tampered -> "[QUORUM] rejected rc=" non-fatal / absent -> "[QUORUM]
      none").
- [x] Negative tests: one stolen key cannot authorize; one build server cannot
      release; one update server cannot ship; one recovery key cannot reset
      trust anchors. DONE (2026-06-10): `eval_ed25519.py` §7 - all four named
      scenarios as executable negatives through the real GHL
      `envelope_verify_signed` (single KERNEL key on a kernel artifact; one
      key's signature repeated 3x counts as one role; single build-server key
      on an app; single UPDATE key on an update; single RECOVERY key on a
      recovery artifact - all ENVR_ERR_SIGCRYPTO), plus the declared-rule
      forgery (min_count=1 below the class floor -> ENVR_ERR_QUORUM).

## P0 - reject matrix (every one needs a fail fixture)

DONE (2026-06-09): every row below is an **executable negative test**, not just
a declared fixture. `scripts/test/eval_envelope.py` builds each case as real
envelope bytes and interprets the actual in-kernel reader source
(`envelope_reader.ghl`, via the production compiler's parser with lb/lw/lq
mapped onto the blob), asserting the exact `ENVR_ERR_*` reason code. Wired into
`test_ghl_security_guards.ps1`; per-row `.fixture` files live in
`tests/security/fixtures/signed_envelope/` and are cross-checked against the
evaluator's case table so they cannot drift.

- [x] unsigned artifact
- [x] malformed envelope (bad magic / short / overflow offsets)
- [x] mismatched artifact type (app signature presented for kernel)
- [x] wrong target domain
- [x] wrong target device / device class
- [x] expired signature window (+ not-yet-valid)
- [x] stale revocation epoch
- [x] replayed artifact (rollback counter below required)
- [x] downgraded artifact (monotonic version below required)
- [x] valid signature from a role not authorized for the type
- [x] manifest/payload disagreement (hash mismatch, constant-control-flow compare)
- [x] missing required field per class (runnable-missing-policy-dep)
- [x] non-canonical / duplicate / descending field encoding
- [x] (extra) trailing garbage in TLV region; unknown critical field;
      partial / oversized signature block; bad field_count range

## P1 - host integration (the real producers/consumers)

- [x] Write a memory-safe host *envelope writer* (build-time) that emits v1
      envelopes for build outputs; keep it out of the running OS image.
      DONE (2026-06-09): `scripts/build/write_envelope.py` - CLI tool, produces
      canonical v1 envelopes with correct TLV ordering, per-class quorum defaults,
      and placeholder sig slots; output accepted by `envelope_verify` in the
      evaluator. Signature slots are 0x5A placeholders pending Ed25519 crypto.
- [x] Write the kernel/boot *envelope reader* that decodes TLVs and calls the
      GHL predicates - this is what turns "checker exists" into "system enforces".
      DONE (2026-06-09): `src/kernel/grithlk/envelope_reader.ghl`
      (`envelope_verify`) - zero-asm, bounds-checked byte walk, distinct
      `ENVR_ERR_*` reason code per reject-matrix row; pinned the v1 TLV wire
      encoding + `payload_len` header field in `docs/signed-artifact-envelope.md`;
      compiled into the kernel image alongside `signed_envelope.ghl` +
      `signed_artifact_check.ghl` (same sources the host fixture gate compiles,
      so contract and enforcement cannot drift). NOT yet bound to a boot/update
      call site, and signature *crypto* (threshold Ed25519 over the canonical
      bytes) is still open - the reader binds the signed HASH field to a
      caller-computed payload SHA-256.
- [x] Bind envelope verification into the boot chain (P1 Boot Chain track).
      DONE (2026-06-10): `src/kernel/grithlk/envelope_gate.ghl` -
      `artifact_gate_admit` (the single admission entry point; computes the
      payload SHA-256 itself via crypto.ghl and calls `envelope_verify_signed`)
      + `syssig_verify_boot`, called from kmain at K5. The UEFI loader reads
      `\EFI\BOOT\SYSSIG.ENV` (built + DEV-quorum-signed every build by
      build_uefi.ps1 step 2a3 via write_envelope.py) and publishes (base,size)
      at VBE_INFO+0x80/0x88; the kernel FAIL-CLOSED panics ('SSG0'..'SSG3') if
      the envelope is missing, rejected, or its payload is not byte-identical
      to the in-image per-app integrity table - which transitively covers
      every app segment hash, so no app code runs without threshold
      signatures. The gate also pins the call site's artifact class
      (GATE_ERR_CALLER_TYPE = 23: a validly signed envelope of the wrong
      class is inadmissible).
- [x] Bind envelope verification into the update path (P1 Update System track).
      DONE (2026-06-10): `boot_update_check` (same module, kmain K5) - the
      loader reads OPTIONAL `\EFI\BOOT\KUPDATE.ENV` (VBE_INFO+0x90/0x98); the
      verdict comes ONLY from `artifact_gate_admit` (type=update, class
      quorum 3-of roles BOOT+KERNEL+UPDATE) and is latched + logged
      "[UPDATE] accepted|rejected rc=N|none". Staging/commit of an accepted
      artifact is the next Update System increment; until then no other path
      accepts update input, so unsigned update input is unreachable.
- [x] Cache verified immutable artifacts by hash (perf gate).
      DONE (2026-06-10): 8-entry round-robin cache in envelope_gate.ghl keyed
      by the SHA-256 of the ENTIRE envelope byte range (header+payload+sigs);
      a hit skips only the Ed25519 crypto - structure + context-dependent
      semantics (window/device/anti-rollback) are re-checked on every admit;
      only accepted envelopes are inserted. Proven on host (eval_ed25519
      gate suite: hit/miss counters) and in-kernel (QEMU "[SYSSIG] ok c=1").
- [x] RTC/now binding (2026-06-10): the gate's verifier wallclock is REAL.
      `src/kernel/grithlk/rtc_time.ghl` (zero-asm, `--forbid-asm`) reads the
      CMOS RTC (UIP-settled, double-read-until-stable, BCD/12h/century
      handling, plausibility-gated, days-from-civil -> unix seconds); kmain
      K5 binds it via `gate_time_set` BEFORE any admission. The clock is
      clamped to a build-time floor `GATE_TIME_FLOOR` (2026-01-01: a dead
      CMOS battery or rolled-back RTC can never move the verifier into the
      past) and ratchets forward-only within a boot; validity windows are
      re-judged against the live clock on EVERY admit - including hash-cache
      hits, so a cached artifact still expires. Verified: 8 host checks in
      `eval_ed25519.py` §9 (floor default, dead-RTC clamp, backward-ratchet,
      expired/postdated/in-window envelopes, cached-artifact expiry) + QEMU
      phase 7 of `test_track2_envelope_callsites.ps1` ("[RTCNOW] now=" logged
      with the real wallclock; a validly quorum-signed KUPDATE whose window
      ended in 2001 -> "[UPDATE] rejected rc=E" ENVR_ERR_WINDOW, non-fatal).
- [x] Persistent anti-rollback floors (2026-06-10): the gate's per-class
      required version/counter/epoch are PERSISTENT monotonic minimums.
      `src/kernel/grithlk/floor_store.ghl` (zero-asm, `--forbid-asm`) keeps
      them in one checksummed record in a reserved data.img sector
      (FLOOR_LBA=2, below FAT16_PART_LBA: outside the FAT partition, the
      ramdisk window, and the FAT image writer) via raw ATA PIO; fails SOFT
      to the build-time floors on media-less hardware (NVMe/USB boot -
      persistent floors there arrive with the Phase-4 block write-back,
      issue #21). kmain K5 loads the record before any admission (a valid
      record can only RAISE floors), seeds the gate clock with the persisted
      high-water mark BEFORE the RTC sample (cross-boot RTC rollback can't
      rewind the verifier), and persists after the admission call sites;
      every ACCEPTED envelope's signed monotonic fields ratchet the floors
      (floor_observe). Verified: 16 host checks in `eval_ed25519.py` §10
      (defaults, ratchet, per-class isolation, DOWNGRADE/REPLAY/EPOCH
      negatives, persist->load round-trip, corrupt-record-never-trusted) +
      QEMU phase 8 of `test_track2_envelope_callsites.ps1` (a validly signed
      v3 update admitted in boot A makes a validly signed v2 update of the
      same class inadmissible in boot B, across a real power cycle).
      **Formally proven (2026-06-10):** the anti-rollback property is now a
      machine-checked Track-3 invariant pair - `INV-NO-ROLLBACK` (an admitted
      artifact must have version >= the persisted floor) and
      `INV-FLOOR-RATCHET-MONOTONIC` (the floor only moves forward), exhaustive
      over their bounded spaces in `scripts/test/eval_invariants.py
      --exhaustive` (49,152 evaluations), complementing the empirical QEMU
      power-cycle test above.
      Fixed en route: `ata_bus_present` clobbered dx, turning every
      non-ramdisk PIO request into a 0x1F7-sector transfer that sprayed
      disk bytes over the kernel image (latent - the FAT16 path is always
      ramdisk-intercepted, so floor_store was the first caller to hit it).
- [x] Loader-side KERNEL.BIN envelope LANDED (2026-06-10, measured-handoff
      form): the build signs the SHA-256 of the final KERNEL.BIN container
      as a kernel-class envelope (`\EFI\BOOT\KERNEL.ENV`, 3-of quorum:
      BOOT+KERNEL+POLICY); the loader loads it and publishes BOTH it and the
      PRISTINE container bytes it read from disk (the trampoline copies the
      runnable payload OUT of the firmware read buffer, so those bytes stay
      byte-identical to the at-rest file) via VBE_INFO 0xB0..0xC8;
      `kernel_env_verify_boot` (envelope_gate.ghl, kmain K5) re-hashes the
      pristine bytes and FAIL-CLOSED requires the signed 32-byte payload to
      equal the digest ('KSG0'..'KSG3' panics). The envelope's monotonic
      fields ratchet the KERNEL-class persistent floor, so a signed-but-
      superseded kernel is also inadmissible. Verified: QEMU phase 9 of
      `test_track2_envelope_callsites.ps1` (positive "[KERNSIG] ok n="
      marker in phase 1; wrong-digest and missing KERNEL.ENV both panic,
      no [/BOOTTIME]). NOTE: this is the measured-handoff option - the
      verifier runs in the kernel over loader-published pristine bytes; a
      pre-kernel root of trust for the loader binary itself remains UEFI
      Secure Boot's job.
- [ ] Remaining residuals: the gate's verifier context still pins
      device_id=1; driver/config/policy artifact classes have no loaded
      artifacts yet; persistent floors on NVMe/USB-boot hardware need the
      Phase-4 block write-back (#21).

### Verification (call-site binding)

- Host: `scripts/test/eval_ed25519.py` sections 5-6 (run by
  `test_ghl_security_guards.ps1`) - transpiles crypto.ghl + envelope_gate.ghl
  with the production frontend and exercises admit/cache/wrong-class/
  fail-closed-panic/update-latch paths (15 checks).
- QEMU end-to-end: `scripts/test/test_track2_envelope_callsites.ps1` - 4
  boots: signed accept (+ in-kernel cache hit), tampered SYSSIG fail-closed
  (no [/BOOTTIME]), signed KUPDATE accepted, tampered KUPDATE rejected
  non-fatally. All 13 checks green 2026-06-10.

### Gotcha: stale `ram_amnesiac.asm` breaks sig-coverage

If `ram_amnesiac.asm` (or any other stale raw-asm shim that was not migrated
to zero-asm GHLK) is still present in the build, it will be included in the
kernel image outside the envelope's signed coverage. The envelope's HASH field
covers only the canonically-assembled payload bytes; any unsigned bytes that
execute at ring-0 break the "signed everything" invariant. **Audit the build
manifest after any new raw-asm file appears; the `--forbid-asm` gate catches
new violations at compile time but does not retroactively flag stale files that
were already excluded from the GHLK build.**

## P1 - fuzzing & parser safety

- [x] Fuzz the envelope decoder (malformed TLV, length overflow, deep nesting,
      duplicate/critical-unknown fields, path traversal in bundle names).
      DONE (2026-06-10): `scripts/test/fuzz_envelope.py` - structure-aware
      mutators (15 classes: byte flips, truncation, header/length extremes,
      duplicate/dropped/shuffled fields, unknown critical ids incl.
      path-traversal value blobs, non-minimal widths, wrong value lengths,
      sig-block games, field_count lies, splices) + raw random blobs, run
      against the REAL interpreted `envelope_verify` (same eval_envelope.py
      interpreter over production GHL source). Safety invariants per input:
      the blob is placed at the END of interpreter memory so ANY
      out-of-bounds load raises (verified to fire on a planted mid-TLV
      truncation with a lying total_len); bounded-loop cap; result must be a
      defined ENVR_* code. Deterministic seed; `--seed/--iters` to explore.
      Wired into `test_ghl_security_guards.ps1`.
- [x] Differential test: two independent decoders agree on accept/reject.
      DONE (2026-06-10): clean-room Python `ref_verify` in fuzz_envelope.py
      (written from docs/signed-artifact-envelope.md + the policy tables, not
      the reader's control flow) compared against the kernel reader on every
      corpus + fuzz input (54 valid envelopes across all 9 artifact classes ×
      domains × target kinds, plus all fuzz inputs). No splits across 3 seeds
      / ~9.5k inputs; detection plumbing meta-tested with a planted
      always-accept ref.
- [x] Property test: canonicalize(decode(x)) == x for all accepted envelopes.
      DONE (2026-06-10): every accepted envelope is decoded to fields and
      re-emitted through the canonical writer; byte-identical or the suite
      fails (meta-tested with a planted non-minimal-width encoding).

## Done definition for Track 2

- [x] Every trusted artifact is a signed v1 envelope; unsigned input is impossible
      to accept anywhere in boot/kernel/update. (2026-06-10: boot-chain +
      update-path call sites are BOUND to `envelope_verify_signed` via
      envelope_gate.ghl - app code is covered transitively through the signed
      integrity table, and update input has no non-gate path. RTC/now binding
      landed 2026-06-10: validity windows are enforced against the real CMOS
      wallclock, floor-clamped + forward-ratcheting. Persistent anti-rollback
      floors landed 2026-06-10: per-class monotonic minimums survive reboots
      via the data.img floor sector. CLOSED 2026-06-10: the last gap - loader-side
      KERNEL.BIN envelope verification - landed (build_uefi.ps1 signs
      `\EFI\BOOT\KERNEL.ENV`; the kernel K5 call site `kernel_env_verify_boot`
      re-hashes the pristine loader-published bytes, fail-closed on KSG*). The
      line-230 residuals (device_id pin, not-yet-loaded driver/config/policy
      classes, NVMe/USB floor write-back) are separate open items, not this
      coverage claim.)
- [x] Every entry in the reject matrix has a passing negative test.
      (28 cases including 3 new quorum cases; all green 2026-06-09.)
- [x] Threshold quorum is enforced from the `COSIGNER_ROLES` field per class.
      (Structural quorum policy enforced at parse time via
      `security_threshold_class_quorum_ok`; actual Ed25519 multi-sig crypto
      LANDED 2026-06-10 - see below.)
- [x] **Real Ed25519 threshold-signature verification** (2026-06-10):
      `src/kernel/grithlk/ed25519_check.ghl` - zero-asm RFC 8032 verify
      (SHA-512, mod-2^255-19 field arithmetic over 32-bit digits, point
      decompression, [S]B == R + [h]A) compiled into the kernel image
      (`--forbid-asm`, build green, QEMU boot healthy).
      `envelope_verify_signed` = `envelope_verify` (structure+semantics) AND
      `ed25519_envelope_sigs_ok`: every 64-byte signature in the detached
      block is checked against the allowed threshold-role public keys over
      the canonical bytes [0, header_len+payload_len); a role counts at most
      once; accept iff >= min_count distinct allowed roles verified AND all
      required roles verified, else `ENVR_ERR_SIGCRYPTO` (22).
      Host side: `scripts/build/ed25519_host.py` (pure-Python RFC 8032) +
      `write_envelope.py --sign-roles` emits REAL quorum signatures (DEV keys
      from fixed seeds; production re-bakes `ed_role_pubs` from HSM keys).
      Tested by `scripts/test/eval_ed25519.py` (real GHL source through the
      production gritc frontend, transpiled): RFC 8032 TEST 1-3 + tamper/
      malleability negatives, SHA-512 vs hashlib differential, pubkey-drift
      guard, and envelope accept / tampered-sig / placeholder / under-quorum /
      missing-required-role rejects. Wired into test_ghl_security_guards.ps1.
- [x] A memory-safe writer produces, and an in-OS reader verifies, real envelopes.
      (`scripts/build/write_envelope.py` writer + `envelope_reader.ghl` reader;
      round-trip verified via `eval_envelope.py`.)
- [x] No single stolen key authorizes any critical action *at the envelope
      layer* (2026-06-10): `envelope_verify_signed` requires >= class-floor
      distinct role keys (real Ed25519) with all class-required roles present;
      one key can contribute at most one role. Verified negatively
      (under-quorum and missing-required-role envelopes reject with
      ENVR_ERR_SIGCRYPTO). System-wide closure still needs the boot/update
      call sites to be bound to `envelope_verify_signed` (P1 above) so no
      unsigned path remains.
