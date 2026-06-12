# Signed Artifact Envelope - Canonical Specification (v1)

This is the keystone of the beyond-zero-trust architecture: a single signed
container shared by **boot, kernel, hypervisor, drivers, apps, policies, configs,
updates, recovery bundles, and tests**. Threshold signing, revocation,
anti-rollback, and policy binding all hang off this one envelope. Everything that
the system trusts must arrive inside it.

Policy kernels:
- `src/tools/security/signed_envelope.ghl` - structural contract (this doc).
- `src/tools/security/signed_artifact_check.ghl` - semantic field validity
  (role-for-type, signature window, anti-rollback).
- `src/tools/security/schema_canonical_check.ghl` - canonical scalar encoding and
  bounded nesting.

The envelope is **detached-signature** style: a header + canonical TLV field
region + payload, with the signature block computed over the canonical bytes.

## Byte layout (v1)

| Offset | Size | Field          | Notes                                  |
|--------|------|----------------|----------------------------------------|
| 0      | 4    | magic          | `'N','X','S','E'` (78,88,83,69)        |
| 4      | 2    | schema_version | u16, must be `1`                       |
| 6      | 2    | artifact_type  | u16, `ART_*` (1..9)                    |
| 8      | 2    | target_domain  | u16, `DOMAIN_*` (1..7)                 |
| 10     | 2    | field_count    | u16, `12..64`                          |
| 12     | 2    | header_len     | u16, offset where the TLV region ends and payload begins |
| 14     | 4    | payload_len    | u32; signature block length is derived as `total_len - header_len - payload_len` and must be a positive multiple of 64 |
| 18     | ...  | TLV fields     | `field_count` records, ids strictly ascending, ending exactly at `header_len` |
| ...    | ...  | payload        | artifact bytes `[header_len, header_len+payload_len)` |
| ...    | ...  | signature block| detached threshold signatures (Ed25519, 64 bytes each) |

### TLV wire encoding (v1, canonical)

Each TLV record is `[id_width:1][field_id LE:id_width][len_width:1][field_len LE:len_width][value:field_len]`
with widths in {1,2,4} and minimal for the value
(`security_envelope_canonical_u32_ok`). Field ids are 1-based (`FIELD_ID_* = bit+1`,
presence bit = `1 << (id-1)`), strictly ascending; unknown ids and wrong value
lengths fail closed. Per-id value layouts (all scalars LE):
TYPE u16; DOMAIN u16; TARGET_DEVICE u16 kind + u32 value; HASH 32 bytes;
SCHEMA_VERSION u16; SIGNER_ROLE u16; VALIDITY u32 not_before + u32 not_after;
MONOTONIC_VERSION u32; ROLLBACK_COUNTER u32; COSIGNER_ROLES u16 min_count +
u16 allowed_mask + u16 required_mask; REVOCATION_EPOCH u32; BUILD_PROVENANCE
32 bytes; POLICY_DEPENDENCY 32 bytes.

The in-kernel reader is `src/kernel/grithlk/envelope_reader.ghl`
(`envelope_verify`): it walks this encoding with bounds-checked byte loads,
calls the policy-kernel predicates, and returns a distinct `ENVR_ERR_*` reason
code per reject-matrix row (0 = accept). The reader binds the signed HASH
field to a caller-computed payload SHA-256 with a constant-control-flow
compare.

Signature *crypto* is `src/kernel/grithlk/ed25519_check.ghl`
(`envelope_verify_signed` - the entry point real call sites bind to): after
`envelope_verify` accepts, every 64-byte Ed25519 signature in the detached
block is verified (RFC 8032) over the canonical bytes
`[0, header_len + payload_len)` against the threshold-role public-key table
(`ed_role_pubs`, roles 1..6 = BOOT/KERNEL/POLICY/UPDATE/RECOVERY/AUDIT).
A signature may satisfy at most one role and a role counts at most once;
accept iff at least `min_count` distinct roles from `allowed_mask` verified
AND every `required_mask` role verified - otherwise `ENVR_ERR_SIGCRYPTO`
(22). The signature block carries no key ids (keeping the multiple-of-64
tiling); role attribution is by trial verification against the <=6 role keys.
Host signing: `scripts/build/write_envelope.py` (`--sign-roles`, DEV keys
derived in `scripts/build/ed25519_host.py`; production replaces them with
HSM-held keys and re-bakes the table).

All multi-byte scalars are canonical per `schema_canonical_check` (minimal
width). Non-canonical, duplicate, descending, or out-of-bounds encodings fail
closed.

## Mandatory signed fields

Every field below is a TLV record inside the canonical region and is covered by
the signature. The presence bitmask (`FIELDBIT_*` in `signed_envelope.ghl`)
reports which were seen.

Bit | Field              | Why it must be signed
----|--------------------|-----------------------------------------------
0   | TYPE               | A signature for an app must not validate a kernel.
1   | DOMAIN             | Binds the artifact to its security domain.
2   | TARGET_DEVICE      | A device/class binding stops cross-device replay.
3   | HASH               | SHA-256 of the payload.
4   | SCHEMA_VERSION     | Verifier selects the right rules.
5   | SIGNER_ROLE        | A role not authorized for the type is rejected.
6   | VALIDITY           | not-before / not-after window.
7   | MONOTONIC_VERSION  | Downgrade protection.
8   | ROLLBACK_COUNTER   | Anti-rollback counter.
9   | COSIGNER_ROLES     | Required co-signer roles (threshold).
10  | REVOCATION_EPOCH   | Stale-epoch rejection.
11  | BUILD_PROVENANCE   | Reproducible-build provenance hash (release).
12  | POLICY_DEPENDENCY  | Policy hash the artifact was built against (runnable only).

- `REQUIRED_BASE` = bits 0..11 (4095): required for **every** shipped artifact.
- `REQUIRED_RUNNABLE` = bits 0..12 (8191): runnable artifacts
  (BOOT/KERNEL/HYPERVISOR/DRIVER/APP) must additionally bind a policy dependency.

## Verification order (fail closed at each step)

1. `security_envelope_magic_ok` - magic matches.
2. schema_version == 1, artifact_type in range, target_domain in range.
3. `field_count` within `[12,64]`.
4. For each TLV: `security_envelope_field_order_ok` (strictly ascending id ⇒
   canonical + no duplicates) and `security_envelope_offset_ok` (in-bounds, no
   overflow).
5. `security_envelope_required_present` - all required bits for the class present.
6. `security_envelope_accept` - composes 1-5 into one decision.
7. Hand decoded fields to `signed_artifact_check` for semantic validity
   (role-for-type, signature window, anti-rollback).
8. Verify threshold signatures over the canonical bytes (see threshold_check).

Any failure ⇒ reject. There is no "warn and continue" path.

For real readers, `security_envelope_accept_checked` is the stricter composed
entry point: it keeps the original structural acceptance gate and additionally
requires canonical TLV scalar predicates, exact payload/signature tiling, and
streaming allocation bounds. Semantic verification also includes
`security_artifact_target_device_ok`, so a present TARGET_DEVICE field must match
the current device id or device class.

## Non-goals for v1

- Field encryption (the envelope is integrity/authenticity, not confidentiality).
- In-place mutation. Envelopes are immutable; updates ship new envelopes.
- Backward-compatible parsing of unknown critical fields - unknown critical
  fields fail closed by design (`schema_canonical_check`).
