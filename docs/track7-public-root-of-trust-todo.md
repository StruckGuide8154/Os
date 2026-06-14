# Track 7 - Public-Key Root of Trust / No Shipped Secrets

Goal: the released build must be secure **even when the entire image is public and
fully reverse-engineered**. A malicious driver that reads every `.bin`/`.img`/`.efi`
byte off the disk and does static analysis must gain **nothing that lets it forge a
build, decrypt protected data, or elevate**. Kerckhoffs's principle, hard: security
rests only on (a) a private key that never touches the image and (b) per-machine /
runtime-derived secrets - never on the confidentiality of anything shipped.

The offline-static-analysis half of this is enforced mechanically by the
**[release gate](release-gate.md)** - a fail-closed scan that is the only door to
a release build, so a whole class of audit findings becomes unshippable rather
than fixed one at a time.

This is the structural answer to the 2026-06-11 static-analysis audit (11 findings).
The audit's individual findings are symptoms; the disease is **two trust chains** -
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
- **Confidentiality of data at rest comes from a key NOT in the image** - derive the
  at-rest key from a per-machine root (TPM-sealed / hardware-bound / user passphrase),
  so even a full DIMM dump + full image disclosure yields ciphertext. ("one-up
  BitLocker" = the key is sealed to platform state, never a constant in the binary.)
- **External enforcement of the first link.** Internal checks are moot if `BOOTX64.EFI`
  can be swapped. The first link (`BOOTX64.EFI`) must be verified by something the
  attacker can't also patch - real UEFI Secure Boot (our cert in db), or a measured
  TPM-sealed chain. Everything after that is verified by the Ed25519 chain.
- **Every shipped input the loader/kernel parses is hostile** until covered by a
  signature in the Ed25519 chain (BOOTCFG.TXT, DATA.IMG and all its media, BOOTANIM).

## Status legend
- [x] done & verified  [~] partial / scaffold  [ ] not started

---

## P0 - Collapse to a single public-key root of trust (the disease)

- [~] **Make the Ed25519 envelope chain the SOLE acceptance gate.** _2026-06-13_:
      the two symmetric HMAC *trust* decisions are gone (below), so the app-blob
      acceptance path is now Ed25519-only (`syssig_verify_boot` binds
      `app_integrity_table` byte-for-byte; `app_segment_verify` SHA-256s each
      segment against that signed table). Remaining: a full written audit of every
      `*_verify`/admission site confirming none accept on a shipped-key match, and
      QEMU boot-verification of the edited boot chain (host compile + forge test
      green; not yet booted).
- [x] **Delete the legacy manifest HMAC trust key.** _2026-06-13_: `hmac_manifest_key`
      (`GRMANIK!`) removed from `crypto.ghl`; `app_manifest_verify` now computes a
      **keyless SHA-256** integrity checksum over the table (fast-fail only, NOT an
      authenticity gate). Authenticity is the Ed25519 envelope that signs the table.
- [x] **Delete the legacy blob-sig HMAC trust key.** _2026-06-13_: `hmac_boot_key`
      (`ISBOLBRG`), `hmac_boot_prepare`, and `app_blob_verify_signature` removed from
      `crypto.ghl`; the dead `LEGACY_BLOB_HMAC` call site removed from
      `kernel_lifecycle.ghl`. `patch_blob_sig.py` is retained (it still emits the
      load-bearing KASLR sliding-fixup table that `sha256_blob_segment_canonical`
      needs); it only embeds a non-secret MAC digest, never the key.
- [x] **Reconcile `gen_app_manifest.py`** to stop emitting the HMAC as a trust
      boundary. _2026-06-13_: the 32-byte table trailer is now a keyless SHA-256
      matching the kernel; `APP_MANIFEST_KEY` use removed.
- [x] **Negative test = the audit, automated.** _2026-06-13_:
      `scripts/test/test_forge_resist.ps1` flips one byte of the released APPS.BIN
      and asserts the signed manifest (== the Ed25519 SYSSIG.ENV payload) rejects it,
      while the positive control confirms the honest blob matches. PASSES. (Note: the
      audit's finding-1 "manifest mismatch" was a false alarm - the auditor hashed
      raw ranges without the KASLR sliding-qword canonicalization; the gate proves
      the manifest does bind APPS.BIN.)
- [ ] **Boot-verify the collapse in QEMU.** The above is host-verified (modules
      compile, forge test green) but the edited boot chain has NOT yet been booted.
      Run the standard QEMU phase and confirm a clean desktop + fail-closed on a
      tampered SYSSIG.ENV before treating P0 as closed.

## P0 - Remove private/secret material from the image

- [x] **Stop embedding the raw private QRNG seed** (audit finding 4, `~0x18c07`,
      0x400 bytes). Options, in order of preference: (a) at build time derive a
      *public* commitment from the seed and ship only that; (b) mix the private seed
      only on the target (never serialized into KERNEL.BIN); (c) if a per-boot canary
      truly needs build entropy, fold it into the *signature*, not a shipped blob.
      Verify with a grep test that the known seed bytes are absent from the release.
      _2026-06-13_: the build now embeds only `SHA-256(seed.bin)` as
      `qrng_commitment`, covered by the signed `KERNEL.ENV`. `kernel_canary`
      mixes that public domain salt with fresh RDRAND; release boot fails closed
      when the hardware draw is unavailable or exhausts retries. The pre-signing
      `check_no_shipped_secrets.ps1` guard rejects any image containing the raw
      1,024-byte seed, with a planted-leak negative test in the main guard suite.
- [x] **Remove the second embedded key-like value** (finding 5, `ISBOLBRG`) and add a
      build-time scanner. _2026-06-13_: removed with the blob-sig key. The release gate
      `tools/security/check_release_artifacts.py` now hard-fails if either legacy
      trust-key spelling (`ISBOLBRG`, `GRMANIK!`) appears in BOOTX64.EFI/KERNEL.BIN/
      APPS.BIN, using precise byte patterns (not a blind entropy scan, which would
      false-trip on the Ed25519 keys/signatures and the public QRNG commitment).
- [ ] **Disable `KLOG.TXT` writes in release builds** (finding 10). Gate the loader's
      `\KLOG.TXT` write (`src/boot/uefi_loader_klog.inc`) behind a signed debug policy;
      default release = no kernel log to disk (no pointers/addresses/seed/state leak).

## P0 - External enforcement of the first link

- [ ] **Real UEFI Secure Boot for `BOOTX64.EFI`** (findings 9, end-state). Sign the
      loader PE (cert table is currently 0x0/0x0) and document enrolling our cert in
      `db`; without SB, the chain is replace-the-loader-and-win. If SB can't be assumed
      on target, define the measured-boot/TPM-sealed fallback that makes loader
      replacement detectable before the kernel trusts anything.
- [ ] **Restore CR0.WP/SMEP/SMAP/PKE as early as possible** (finding 11): shrink the
      early-boot window where protections are off; verify no attacker-controlled input
      (DATA.IMG media, BOOTCFG) is parsed while they're down.

## P1 - Bring every shipped input under the signed chain

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

## P1 - "Safe even when decrypted" (data-at-rest key off-image)

- [ ] **Derive the at-rest / volatile-memory key from a per-machine root**, not a
      build constant: TPM-seal to PCRs (measured boot state) or a user passphrase KDF,
      so the key exists only on the intended machine in the intended boot state. This
      is what makes "even if the image + a DIMM dump leak, data stays safe" true -
      and is the structural upgrade over BitLocker-style whole-volume keys. Ties into
      Track 4 Part B (the at-rest cipher exists; it just needs a non-shipped key) and
      Part C (TME/SME for the executing residual).

## P2 - Stop paying for obscurity that a public build can't keep (findings 2, 3)

A released binary is public by definition: relocation tables and syscall stubs
**cannot** be hidden. So stop budgeting them as defense and make security hold
when they are fully disclosed.

- [ ] **KASLR redesign (finding 2).** Today the loader randomizes a low-memory
      *physical* base over ~2341 slots (~11.2 bits) and `KERNEL.BIN` exposes the
      whole `GRKASLR0` relocation model. Move to a wide **high-half virtual**
      randomization decoupled from physical load, so the leaked reloc table and the
      narrow physical range stop being the whole defense. Treat low-memory physical
      KASLR as at most a minor adjunct.
- [ ] **Syscall ABI is public (finding 3).** The app blob necessarily leaks the
      syscall stubs/IDs. The per-slot syscall-number *permutation* is a launch-time
      anti-confusion measure, not a secret - confirm no security claim rests on the
      ABI being hidden, and that every handler enforces the per-slot capability
      manifest (`syscall_caps.inc`) regardless of numbering.
- [ ] **Release debug-string strip (finding 4).** The release gate now hard-fails on
      the audit's debug markers (`[SYSSIG]`, `[KERNSIG]`, `[UPDATE]`, `[QUORUM]`,
      `RING 3`, `L3TEST`, `L3 key ok`). These should already be behind
      `ENABLE_DEBUG_SERIAL` (off in `-Release`). If a `-Release` build trips the
      gate, the fix is to **gate the offending string**, not to relax the check.

## P3 - Live-secret secrecy vs a runtime-compromised privileged component

Track 7 above defeats the *offline static-analysis* attacker. A driver/kernel
part compromised **at runtime** (reading DRAM or rewriting a `.bin`) is a
different model - the realistic guarantee is **leak != forge != persist**, and it
is delivered by other tracks. Tracked here only as the cross-link:

- [ ] **At-rest/volatile key from a per-machine root** (also P1 above): TPM-seal to
      PCRs or a passphrase KDF so image + DIMM-dump disclosure yields only
      ciphertext. (Track 4 Part B/C.)
- [ ] **Mediate live-secret access from a tier the compromised component can't
      reach**: keep the QRNG pool / live keys behind the nested-kernel PT monitor
      window and the Track 5/6 "-1" monitor, so even ring-0 driver code cannot read
      them without a mediated path, and one compromised compartment != total.
- [ ] **Anti-rewrite**: a malicious on-disk `.bin` rewrite fails the Ed25519 gate on
      next boot (persist denied); an in-memory code rewrite trips W^X + the
      nk-monitor PT window. Confirm these cover the QRNG/key residency pages.

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
