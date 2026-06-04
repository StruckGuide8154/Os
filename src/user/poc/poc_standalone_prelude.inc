; ============================================================================
; poc_standalone_prelude.inc — minimal scaffold so a security PoC harness in
; this directory assembles as a STANDALONE flat binary, outside the monolithic
; app blob (src/user/apps.asm).
;
; WHY THIS EXISTS (spec ref: security_todo.md §13 — always-buildable security regression suite)
;   The ring-3 PoC harnesses (wx_poc_*, wx_jit_alias_*, stack_overflow_poc)
;   exercise landed mitigations through the syscall ABI: SYS_WX_INSTALL_MANIFEST,
;   SYS_MPROTECT_WX / MPROT_WX_MODE_XRO, SYS_WX_JIT_ALIAS, SYS_PRINT, SYS_EXIT.
;   Assembling each one on every build is a compile-gate: if a future change
;   renames or drops any of those constants/macros (i.e. regresses the ABI a
;   mitigation depends on), the PoC stops assembling and the build fails HERE,
;   instead of the regression hiding until a manual audit. Future-proofing *is*
;   tests that fail closed — and "fails to build" is the earliest possible
;   closed failure.
;
;   The harnesses anchor offsets against `app_blob_start` (the blob base symbol
;   defined only inside apps.asm). When built standalone there is no blob, so we
;   provide the symbol here at the image origin. The emitted bytes are never
;   run in this mode — only assembled — so the absolute value is irrelevant;
;   the manifest-offset math (`label - app_blob_start`) just has to resolve.
;
; USAGE (see scripts/build/build_uefi.ps1 -SecurityRegression)
;   nasm -f bin -I src/user/lib/ -I src/include/ -I src/user/poc/ \
;        -o <out>.bin /path/to/<this-wrapper>.asm
;   where <wrapper>.asm is:
;       bits 64
;       %include "poc_standalone_prelude.inc"
;       %include "<poc>.asm"
; ============================================================================

%ifndef POC_STANDALONE_PRELUDE_INC
%define POC_STANDALONE_PRELUDE_INC

bits 64

; Blob base anchor. In the monolithic build apps.asm defines this as a global
; label at the start of the copied-into-slot image; standalone we just need the
; symbol to exist so `label - app_blob_start` displacements resolve.
global app_blob_start
app_blob_start:

%endif
