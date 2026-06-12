; ============================================================================
; GritOS - User-blob signature (security_todo.md §9 "Sign the user blob")
; ----------------------------------------------------------------------------
; Shared constants for the kernel-verified HMAC-SHA256 over the built-in user
; blob [app_blob_start, app_blob_end). See src/kernel/grithlk/crypto.ghl
; (app_blob_verify_signature) for the runtime check and
; tools/build/patch_blob_sig.py for the build-time MAC computation.
;
; THREAT MODEL (docs/STATUS.md "Security threat model & hardware-anchoring
; scope"): the root of trust is measured boot + a kernel-held key, NOT silicon,
; and a physical attacker with the boot medium is explicitly out of scope. So a
; symmetric, kernel-held-key MAC is the right primitive here - there is no third
; party to convince and no offline-forgery requirement. We do NOT use Ed25519:
; a public-key signature buys nothing the threat model requires while adding a
; hard-to-audit NASM bignum.
;
; KEY CONSISTENCY (build-time vs runtime): the MAC key is a single fixed 64-bit
; constant, APP_BLOB_SIG_KEY, defined HERE and used by BOTH the kernel verifier
; (which assembles it in) AND patch_blob_sig.py (which hard-codes the identical
; value). Because the key is compiled into the kernel rather than derived at
; boot, the build-time MAC and the runtime MAC are computed under the same key
; by construction - they match iff the covered blob bytes match. This is
; acceptable under the stated threat model precisely because a physical attacker
; who could read the key out of KERNEL.BIN is already out of scope. After
; kernel_lockdown_ro, the .text holding the key + expected MAC is read-only.
;
; KASLR CANONICALIZATION: the default build is KASLR-on, so the embedded blob
; the kernel runs is RELOCATED by the loader - 43-ish absolute qwords inside it
; slide by the kernel slide and therefore differ from the build-time image. To
; keep the MAC slide-independent, both sides EXCLUDE those sliding qwords: they
; fold 0x00 for the 8 bytes at each sliding offset instead of the real bytes.
; The sliding offsets are blob-relative (slide-independent positions); the build
; tool derives them by diffing the two ORG passes (exactly as
; extract_kaslr_fixups does) and bakes the list into the kernel so the runtime
; verifier can skip the same windows. Net coverage: every NON-relocated byte of
; the blob (the code + data that actually matters for tamper detection); the
; relocated address words (~344 bytes) are excluded by design - tampering them
; would corrupt a relocation and is out of scope for casual/accidental tamper
; detection (and would be caught downstream by a fault).
;
; HASH PRIMITIVE: HMAC-SHA256 over the canonicalized blob. The runtime verifier
; and build-time patcher share the same key bytes and the same KASLR exclusion
; table, so the image fails closed if any covered byte differs.
; ============================================================================
%ifndef APP_BLOB_SIG_INC
%define APP_BLOB_SIG_INC

; Fixed build-time/runtime MAC key. Compiled into the kernel; patch_blob_sig.py
; hard-codes the identical value. Changing it requires changing BOTH places.
APP_BLOB_SIG_KEY equ 0x4752424C4F425349   ; "GRBLOBSI"

; Capacity of the embedded sliding-offset exclusion table. Today the blob has
; ~43 sliding qwords; 128 leaves generous headroom. patch_blob_sig.py fails the
; build (fail closed) if the real count ever exceeds this, prompting a bump.
APP_BLOB_SIG_MAX_FIXUPS equ 128

; 16-byte locator the build tool scans for in KERNEL.A.RAW to find the MAC +
; exclusion table. Immediately after the marker:
;     +0x00  byte[32] expected HMAC-SHA256 (mb_blob_sig_expected)
;     +0x20  dword    sliding-offset count (mb_blob_sig_fixup_count)
;     +0x24  dword[APP_BLOB_SIG_MAX_FIXUPS] blob-relative offsets, LE
; Same marker-scan idiom used by the app-blob sentinels (apps.asm).
%macro APP_BLOB_SIG_MARKER 0
    db 0x4E, 0x58, 0x42, 0x4C, 0x4F, 0x42, 0x53, 0x49   ; "GRBLOBSI"
    db 0x47, 0x4D, 0x41, 0x43, 0x21, 0xDE, 0xC0, 0xDE   ; "GMAC!" + 0xDEC0DE
%endmacro

%endif ; APP_BLOB_SIG_INC
