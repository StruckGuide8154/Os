; ============================================================================
; GritOS - Per-app integrity manifest (FORMAT CONTRACT)
; docs/per-app-integrity-manifest.md
; ----------------------------------------------------------------------------
; This file is the SHARED format contract between the build side
; (tools/build/gen_app_manifest.py, emitted into the kernel image via
; src/user/apps.asm) and the kernel side (src/kernel/grithlk/crypto.ghl runtime
; verifier). BOTH agents reference these constants; do not change one side
; without the other.
;
; The manifest is a small signed table of per-app SHA-256 digests. It replaces
; the single whole-blob HMAC for boot verification (sub-ms) and enables per-app
; verification at launch (fail-closed). See the design doc for phasing.
;
; THREAT MODEL: identical to app_blob_sig.inc - root of trust is measured boot +
; a kernel-held key, NOT silicon. A symmetric kernel-held-key MAC (HMAC-SHA256)
; over the table is the right primitive; the build tool and kernel share the same
; key constant by construction.
;
; KASLR CANONICALIZATION: each per-app SHA-256 is computed over the segment's
; blob bytes with the same KASLR sliding qwords zeroed that patch_blob_sig.py
; excludes, PARTITIONED per segment (a sliding offset belongs to whichever
; segment's [offset,offset+size) range contains it). Offsets are blob-relative
; (= label - app_blob_start), hence slide-independent.
; ============================================================================
%ifndef APP_MANIFEST_INC
%define APP_MANIFEST_INC

; --- Capacity -------------------------------------------------------------
; Max number of manifest entries (segments). The build tool fails closed if the
; real count exceeds this.
APP_MANIFEST_MAX equ 32

; --- HMAC key -------------------------------------------------------------
; Fixed 8-byte build-time/runtime MAC key for the manifest table. Distinct from
; APP_BLOB_SIG_KEY. gen_app_manifest.py hard-codes the IDENTICAL value.
; Bytes "GRMANIK!" little-endian.
APP_MANIFEST_KEY equ 0x214B494E414D5247   ; "GRMANIK!" (LE)

; --- Locator marker -------------------------------------------------------
; 16-byte sentinel the build tool scans for to find the table in the kernel
; image. MUST be distinct from SIG_MARKER ("GRBLOBSIGMAC!..") and the app-blob
; start/end sentinels ("GRAPPBLO..").
; Bytes: "GRMANIFEST" + "TBL" + 0xC0 0xDE 0x01.
%macro APP_MANIFEST_MARKER 0
    db 0x47, 0x52, 0x4D, 0x41, 0x4E, 0x49, 0x46, 0x45   ; "GRMANIFE"
    db 0x53, 0x54, 0x54, 0x42, 0x4C, 0xC0, 0xDE, 0x01   ; "STTBL" + 0xC0DE01
%endmacro

; --- Table layout ---------------------------------------------------------
; Immediately after APP_MANIFEST_MARKER, in kernel .data:
;     +0x00  dword  count                (number of valid entries, <= APP_MANIFEST_MAX)
;     +0x04  entry[APP_MANIFEST_MAX]     each entry is 44 bytes:
;                +0x00  dword  app_id
;                +0x04  dword  offset    (= seg_start - app_blob_start, blob-relative)
;                +0x08  dword  size      (= seg_end - seg_start)
;                +0x0C  byte[32] sha256  (build-tool filled; zero at assemble time)
;     +0x04 + 44*APP_MANIFEST_MAX  byte[32] mac
;                = HMAC-SHA256(APP_MANIFEST_KEY, count_dword || all entry bytes)
;
; The build tool fills sha256[] and mac[]; app_id/offset/size are filled at
; assemble time by apps.asm. count is filled at assemble time too.
APP_MANIFEST_ENTRY_SIZE  equ 44
APP_MANIFEST_TABLE_BYTES equ 4 + (APP_MANIFEST_ENTRY_SIZE * APP_MANIFEST_MAX) + 32

; --- Assemble-time entry emitter -----------------------------------------
; Emits one 44-byte entry. %1=app_id, %2=segment start label, %3=segment end
; label. Offsets are computed relative to app_blob_start (which must be in scope).
; sha256 left zero for the build tool to fill.
%macro APP_MANIFEST_ENTRY 3
    dd %1                                ; app_id
    dd (%2 - app_blob_start)             ; offset (blob-relative)
    dd (%3 - %2)                         ; size
    times 32 db 0                        ; sha256 (build-tool filled)
%endmacro

; --- Canonical app_id assignment -----------------------------------------
; Glue + synthetic ids (real app ids 2..11 come from grit_window.inc).
APP_SEG_COMMON  equ 0                     ; boot trampoline + common/state/launch glue
APP_SEG_HELLO   equ 100
APP_SEG_WALLPAPER equ 101
APP_SEG_SHELL   equ 102
APP_SEG_MEDIA_VIEWER equ 103

%endif ; APP_MANIFEST_INC
