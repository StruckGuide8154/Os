%ifndef APP_SYSNO_INC
%define APP_SYSNO_INC
; ============================================================================
; APP_SYSNO — syscall-number emission + per-app syscall-immediate fixup table
; (security_todo.md §12, heterogeneous syscall numbering per slot).
;
; Every syscall site in the built-in app blob loads the syscall number into
; eax/rax immediately before the `syscall` instruction. To make the kernel's
; per-slot syscall-number PERMUTATION live, the loader must rewrite each of
; those immediates in the per-slot copy of the blob from the raw (compiled)
; number to that slot's FORWARD-permuted number; the dispatcher's inverse map
; then recovers the real table row.
;
; To rewrite the immediates SAFELY (no blind byte-pattern scanning of the
; blob), every syscall site goes through APP_SYSNO N, which:
;   (1) emits a hand-encoded `mov eax, imm32` (opcode 0xB8) so the 4-byte
;       immediate sits at a byte offset we control exactly (zero-extends into
;       rax, identical effect to the historical `mov rax, N` for N < 2^32 —
;       and every syscall number is small), and
;   (2) records a fixup record {u32 offset-within-blob, u8 raw-sysno} into the
;       kernel-resident table [app_syscall_fixups_start, app_syscall_fixups_end).
;
; The offset is `imm - app_blob_start`, a build-time constant (slide-
; independent under KASLR, so the records are NOT KASLR fixups). The loader
; (l3_copy_app_blob_to_slot, usermode.asm) walks this table, looks up the
; slot's forward permutation for each raw sysno, and patches the 4 immediate
; bytes in the slot copy. A slot with no permutation generated (identity) or
; the default (ENABLE_SYSCALL_PERM off) leaves the immediates as the raw
; numbers — fail-safe identity.
;
; STANDALONE BUILDS (APPS.BIN extract, PoC harnesses): app_blob_start is the
; blob anchor in every context that includes app code. The fixup table is
; kernel .data; in a standalone flat-binary build it is simply unused data and
; the immediates assemble exactly as a plain `mov eax, N` would.
; ============================================================================

; Each fixup record is a packed 5 bytes: u32 blob-relative offset + u8 raw
; sysno. The records live in a dedicated section (.scfix) so NASM aggregates
; them contiguously between app_syscall_fixups_start/_end regardless of where
; the macro is expanded; nothing else emits to .scfix.
%macro APP_SYSNO 1
    db 0xB8                          ; mov eax, imm32
%%sysno_imm:
    dd %1
    [section .scfix align=1]
    dd (%%sysno_imm - app_blob_start)
    db %1
    __SECT__
%endmacro

%endif ; APP_SYSNO_INC
