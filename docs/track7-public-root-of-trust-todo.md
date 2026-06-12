# Track 7 — Public-Key Root of Trust / No Shipped Secrets

Goal: the released build must be secure **even when the entire image is public and
fully reverse-engineered**. A malicious driver that reads every `.bin`/`.img`/`.efi`
byte off the disk and does static analysis must gain **nothing that lets it forge a
build, decrypt protected data, or elevate**. Kerckhoffs's principle, hard: security
rests only on (a) a private key that never touches the image and (b) per-machine /
runtime-derived secrets — never on the confidentiality of anything shipped.

This is the structural answer to the 2026-06-11 static-analysis audit (11 findings).
The audit's individual findings are symptoms; the disease is **two trust chains** —
a legacy *symmetric* HMAC chain whose key ships inside the artifact it verifies,
running in parallel with the Track-2 *public-key* Ed25519 envelope chain. While both
are accepted, the system is exactly as strong as the forgeable HMAC chain.

## The thesis (read before doing anything)

- **Verifier ≠ forger.** Any check whose secret is in the image gives the attacker
  the same power as the verifier. Replace every symmetric *trust* check (manifest
  HMAC, blob-sig HMAC) with the Ed25519 public-key chain. Public key in image = fine;
  private key in image = the whole vulnerability.
- **Assume the image is public.** Do not "conceal" the QRNG seed, keys, or sentinels.
  Either remove them, or make the shipped value a *public* derivative and mix the
  private/entropy part on the target machine at boot (rdseed/rdrand/TPM/per-machine).
- **Confidentiality of data at rest comes from a key NOT in the image** — derive the
  at-rest key from a per-machine root (TPM-sealed / hardware-bound / user passphrase),
  so even a full DIMM dump + full image disclosure yields ciphertext. ("one-up
  BitLocker" = the key is sealed to platform state, never a constant in the binary.)
- **External enforcement of the first link.** Internal checks are moot if `BOOTX64.EFI`
  can be swapped. The first link (`BOOTX64.EFI`) must be verified by something the
  attacker can't also patch — real UEFI Secure Boot (our cert in db), or a measured
  TPM-sealed chain. Everything after that is verified by the Ed25519 chain.
- **Every shipped input the loader/kernel parses is hostile** until covered by a
  signature in the Ed25519 chain (BOOTCFG.TXT, DATA.IMG and all its media, BOOTANIM).

## Status legend
- [x] done & verified  [~] partial / scaffold  [ ] not started

---

## P0 — Collapse to a single public-key root of trust (the disease)

- [ ] **Make the Ed25519 envelope chain the SOLE acceptance gate.** Audit every code
      path that currently accepts an artifact (app blob, kernel blob, manifest) and
      confirm it routes through `envelope_gate.nxh` / `envelope_verify_signed`. Any
      path that accepts on HMAC-match alone is a forge path — list them all first.
- [ ] **Delete the legacy manifest HMAC trust key.** Remove `hmac_manifest_key`
      (`NXMANIK!`, `crypto.nxh:58`) as a *trust* decision. Either drop the manifest
      MAC entirely (envelope covers it) or downgrade it to a non-security checksum
      and document it as integrity-only, NOT authenticity.
- [ ] **Delete the legacy blob-sig HMAC trust key.** Remove `hmac_boot_key`
      (`ISBOLBXN`, `crypto.nxh:54`) + the `APP_BLOB_SIG_KEY` path
      (`src/include/app_blob_sig.inc`, `tools/build/patch_blob_sig.py`). The app blob
      authenticity must come from the Ed25519 manifest, not a shipped symmetric key.
- [ ] **Reconcile `gen_app_manifest.py` + `app_manifest.inc`** to stop emitting/
      checking the HMAC as a trust boundary. The per-app manifest hash should be
      *signed*, not MAC'd with a shipped key.
- [ ] **Negative test = the audit, automated.** Add `scripts/test/test_forge_resist.ps1`:
      patch one byte of APPS.BIN, recompute everything an attacker can recompute from
      the image alone (manifest SHA, HMAC, SYSSIG header SHA), and assert the build is
      **rejected** at boot. This is the regression that proves the disease is cured —
      it should FAIL today and PASS when P0 lands.

## P0 — Remove private/secret material from the image

- [ ] **Stop embedding the raw private QRNG seed** (audit finding 4, `~0x18c07`,
      0x400 bytes). Options, in order of preference: (a) at build time derive a
      *public* commitment from the seed and ship only that; (b) mix the private seed
      only on the target (never serialized into KERNEL.BIN); (c) if a per-boot canary
      truly needs build entropy, fold it into the *signature*, not a shipped blob.
      Verify with a grep test that the known seed bytes are absent from the release.
- [ ] **Remove the second embedded key-like value** (finding 5, `ISBOLBXN`) — same as
      the blob-sig key removal above; confirm no remaining 8-byte "hidden trust value"
      ships. Add a build-time scanner that greps the release for known-secret byte
      patterns and fails the build if any appear.
- [ ] **Disable `KLOG.TXT` writes in release builds** (finding 10). Gate the loader's
      `\KLOG.TXT` write (`src/boot/uefi_loader_klog.inc`) behind a signed debug policy;
      default release = no kernel log to disk (no pointers/addresses/seed/state leak).

## P0 — External enforcement of the first link

- [ ] **Real UEFI Secure Boot for `BOOTX64.EFI`** (findings 9, end-state). Sign the
      loader PE (cert table is currently 0x0/0x0) and document enrolling our cert in
      `db`; without SB, the chain is replace-the-loader-and-win. If SB can't be assumed
      on target, define the measured-boot/TPM-sealed fallback that makes loader
      replacement detectable before the kernel trusts anything.
- [ ] **Restore CR0.WP/SMEP/SMAP/PKE as early as possible** (finding 11): shrink the
      early-boot window where protections are off; verify no attacker-controlled input
      (DATA.IMG media, BOOTCFG) is parsed while they're down.

## P1 — Bring every shipped input under the signed chain

- [ ] **Sign/cover `BOOTCFG.TXT`** (finding 6). Boot/runtime feature toggles must be
      inside the Ed25519-signed set, or the loader must reject an unsigned/modified
      BOOTCFG. Right now boot-partition write access reconfigures the kernel without
      breaking any check.
- [ ] **Cover `DATA.IMG` (and every file in it) with a verified whole-image hash**
      (finding 7) bound into the manifest/envelope. README/HELLO/NOTES/SYSTEM/LOGO.BMP/
      RIBBONS.SVG/BOOTANIM.NBA are currently unsigned parser input.
- [ ] **Harden every DATA.IMG parser as hostile input** (findings 7,8). Audit the BMP,
      SVG, and `BOOTANIM.NBA` parsers for integer overflow (`width*height*4`, finding
      8), undersized allocation, and OOB. Add fuzz/bounds tests. Even once signed, a
      parser bug is a boot-time attack surface; signing reduces *who* can reach it, not
      whether the bug exists.

## P1 — "Safe even when decrypted" (data-at-rest key off-image)

- [ ] **Derive the at-rest / volatile-memory key from a per-machine root**, not a
      build constant: TPM-seal to PCRs (measured boot state) or a user passphrase KDF,
      so the key exists only on the intended machine in the intended boot state. This
      is what makes "even if the image + a DIMM dump leak, data stays safe" true —
      and is the structural upgrade over BitLocker-style whole-volume keys. Ties into
      Track 4 Part B (the at-rest cipher exists; it just needs a non-shipped key) and
      Part C (TME/SME for the executing residual).

## Done definition for Track 7

- [ ] No symmetric *trust* key ships in any release artifact (build-time scanner green).
- [ ] Every accepted artifact is verified by the Ed25519 public-key chain; the legacy
      HMAC chain is gone or demoted to non-security integrity only.
- [ ] `test_forge_resist.ps1` proves a one-byte patch + full attacker recompute is
      rejected at boot.
- [ ] `BOOTX64.EFI` is externally verified (Secure Boot or measured/sealed fallback).
- [ ] `BOOTCFG.TXT` and `DATA.IMG` (+ all media) are inside the signed set; their
      parsers pass bounds/fuzz tests.
- [ ] The at-rest/volatile key is derived from a per-machine root, never a shipped
      constant; the private QRNG seed and all hidden trust values are absent from the
      image.
