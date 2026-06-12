# Per-app integrity manifest (boot-speed + stronger security)

Status: PHASE 1 IMPLEMENTING (2026-06-06). Goal: replace the single whole-blob boot HMAC with a
small signed **per-app digest manifest** verified at boot (sub-ms), plus **per-app
SHA-256 verification at launch** (fail-closed, before exec). Faster boot AND stronger
security (each app verified independently, right before it runs).

## Current state (what we're changing)
- Blob is monolithic: all apps assembled between `app_blob_start`/`app_blob_end`
  (`src/user/apps.asm`, %including common/state/launch glue + each app .inc).
- Hashed TWICE at boot: `measured_boot_init` (kernel_text+blob -> mb_digest) and
  `app_blob_verify_signature` (HMAC of blob, fail-closed). ~0.93s in QEMU TCG.
- Launch: `app_launch` (launch.inc) dispatches by app_id (APP_EXPLORER=2..);
  `l3_copy_app_blob_to_slot` copies the WHOLE blob into each slot; then
  `kernel_apply_app_manifest(slot, app_id)` narrows the syscall cap mask.
- Build signer: `tools/build/patch_blob_sig.py` computes the whole-blob HMAC and
  patches it into both kernel images; `mb_blob_sig_fixups` excludes ~31 sliding qwords.

## Target design
### Blob layout v2
- Add per-app segment labels in `src/user/apps.asm` around each app include:
  `app_seg_<id>_start: %include ".../<app>.inc" app_seg_<id>_end:`. Shared glue
  (common/state/launch) becomes segment id 0 ("common"), hashed once.
- Keep `app_blob_start/end` (measured-boot + KASLR still use them).

### Manifest table (kernel .data, build-patched)
- `APP_MANIFEST_MARKER` locates the table in the raw kernel image.
- `count : u32`
- per fixed-capacity entry: `{ u32 app_id, u32 offset (=start-app_blob_start), u32 size, u8[32] sha256 }`
- `mac : u8[32]` = HMAC-SHA256(manifest key, `count || entry[APP_MANIFEST_MAX]`).
- Build tool (`tools/build/gen_app_manifest.py`, run in `build_uefi.ps1` after
  assembly and after the legacy blob signer) reads the assembled table's
  app_id/offset/size fields, SHA-256s each segment's bytes in the assembled
  image, fills the digests, computes the MAC, and patches it into both raw kernel
  images before KASLR wrapping.
- NOTE re fixups: per-app digests must exclude the same sliding-qword fixups that
  fall within each segment (zero them before hashing, mirroring hmac_blob_canonical).

### Boot (crypto.ghl)
- Replace `app_blob_verify_signature` whole-blob HMAC with
  `app_manifest_verify()`: HMAC-verify the (tiny) manifest table only -> sub-ms.
  Fail-closed. Sets a "manifest trusted" flag.
- measured_boot_init: keep hashing kernel_text; fold the **manifest table** (not the
  1.26MB blob) into mb_digest. Removes MD's blob cost too. (Attestation now covers
  kernel + per-app digests, which is equivalent coverage.)

### Launch (per-app verify, fail-closed)
- In `l3_copy_app_blob_to_slot` (or kernel_apply_app_manifest, which already gets
  app_id), after the blob lands in the slot and BEFORE first exec:
  look up the manifest entry for app_id, SHA-256 the segment bytes in the slot copy
  (with per-segment fixups zeroed), compare to manifest digest; mismatch ->
  kernel_panic_canary. Also verify segment 0 (common glue) on first launch.
- Cache per-(slot,app_id) verified state to avoid re-hashing on benign re-init
  (but re-verify on slot recycle to a different tenant).

## Phasing (each phase independently buildable + boot-marker verifiable)
1. **Additive build side (non-breaking):** add segment labels + gen_app_manifest.py;
   emit the manifest table into kernel .data; DO NOT yet remove the old whole-blob
   HMAC or consume the manifest. Boot still uses the old path. Verify build + markers.
2. **Boot cutover:** add `app_manifest_verify()` and switch boot to it; keep the old
   whole-blob HMAC behind a flag for one release as rollback. Verify markers + that
   tampering a segment still fails closed (negative test).
3. **Launch per-app verify:** hook the per-app SHA check into the launch path.
   Negative test: corrupt one app's bytes -> only that app fails, others run.
4. **measured-boot fold switch + remove old whole-blob HMAC.** Verify attestation.

## Risks / gotchas
- Sliding-q「word fixups must be partitioned per-segment (a fixup belongs to whichever
  segment contains its offset). gen_app_manifest.py must replicate the zeroing.
- KASLR: offsets are blob-relative (slide-independent), like app_sysno fixups - safe.
- The whole blob is still copied per slot (unchanged); we only change WHAT is hashed
  and WHEN. No change to slot isolation / syscall permutation.
- security_probe stays raw asm (adversarial harness) - its segment is hashed like any
  other; do not migrate it.
- Verify entry points: scripts/test/boot_markers.ps1 (markers), plus new negative
  tamper tests; test_ghl_security_guards.ps1 for the beyond-zero-trust gate.
