; ============================================================================
; syscall_data.inc
; syscall .data/.bss: the RESIDUAL symbols that could not migrate to GritHLK.
;
; Stage 1 of docs/ghlk-syscall-rearchitecture.md migrated the UNCONDITIONAL,
; const-sized data symbols (syscall_count, kernel_canary, sc_net_*_busy,
; szHelloUser, slot_cap_mask, slot_cap_hmac, cap_audit_head/ring, slot_sc_budget,
; slot_gui_budget, slot_sc_strikes, sc_trace_ring/head/hist) to
;   src/kernel/grithlk/syscall_data.ghl
; -> build/ghl/syscall_data.asm (zero-asm `data`/`global` decls), %include'd by
; kernel_build.asm under `section .data`.
;
; WHAT REMAINS HERE (the GritHLK `data` decl cannot express either property):
;   * %ifdef-gated blocks - GHLK has no conditional-compilation construct, so
;     every ENABLE_DEBUG_SERIAL / ENABLE_SHADOW_STACK_POC / ENABLE_SYSCALL_PERM
;     symbol stays in asm.
;   * slot_syscall_allow + the SC_ALLOW_BYTES equ - sized by syscall_table_count,
;     a NASM assembly-time equ; the compiler resolves a `data` count to a literal
;     at compile time and cannot track the live table size.
; ============================================================================
section .data

%ifdef ENABLE_DEBUG_SERIAL
; DEBUG (blank-app diagnosis): caps the XCAP cap-reject serial spew so a window
; redraw that issues thousands of (denied) draw calls doesn't flood the log.
xcap_log_count: dd 0
; DEBUG (blank-app diagnosis): one bit per syscall number, set the first time an
; app slot (>=2) successfully dispatches it. Lets us print the *set* of syscalls
; an app issues (XDSP) once each, instead of flooding on every redraw frame.
xdsp_seen_bitmap: times 32 db 0
%endif
%ifdef ENABLE_SHADOW_STACK_POC
shadow_poc_saved_rsp: dq 0
%endif

; Per-slot syscall allowlist bitmap (security_todo.md §2, "Manifest declares
; syscall set, not just cap bits"). One bit per syscall number, SC_ALLOW_BYTES
; bytes per slot; bit i set == slot may invoke syscall i. The dispatcher tests
; this bit right after the coarse cap gate, so an app is confined to the exact
; syscall set its manifest implies - finer than the CAP_* mask alone (Notepad
; keeps CAP_FS but is denied SYS_FS_DELETE).
;
; Default is every bit set (0xFF fill): legacy/undeclared slots are
; unrestricted at the bitmap layer, exactly as before this gate existed, so the
; cap mask stays the only constraint until a manifest is applied.
; sc_build_allow_bitmap rewrites a slot's bitmap from {cap mask, app deny list}
; at every cap-mask transition (declare_manifest, kernel_apply_app_manifest,
; recycle). syscall_table_count is the assembly-time equ resolved at the table.
SC_ALLOW_BYTES equ ((syscall_table_count + 7) / 8)
align 16
slot_syscall_allow: times (MAX_WINDOWS * SC_ALLOW_BYTES) db 0xFF

%ifdef ENABLE_SYSCALL_PERM
; --- Heterogeneous syscall numbering per slot (security_todo.md §12) ---------
; Per-slot INVERSE permutation of the syscall table, in KERNEL BSS OUTSIDE the
; ring-3 arena (parallel to slot_cap_mask[]/slot_syscall_allow[]/l3_slot_key[]),
; so a slot's own memory-write bug can't rewrite its mapping. One word per
; syscall number per slot (the table now exceeds 256 rows):
;   sc_slot_perm_inv[slot*syscall_table_count + app_visible] = real_table_row
; The dispatcher applies this on entry to recover the real row from the number
; the app issued. The matching FORWARD permutation (real_row -> app_visible) is
; what a future loader-side rewrite stamps into the app's SYS_* constants; it is
; built transiently in sc_slot_perm_generate and discarded - only the inverse
; the kernel needs is persisted.
;
; sc_slot_perm_ready[slot] is the generation sentinel: BSS-zero (0) = "not
; generated yet" -> the lazy ensure path treats the slot as IDENTITY until it is
; generated. After generation it is 1. This makes a never-dispatched slot, and
; the whole default (non-ENABLE_SYSCALL_PERM) build, behave exactly as today.
align 16
sc_slot_perm_inv:   times (MAX_WINDOWS * syscall_table_count) dw 0
; The FORWARD permutation (real_row -> app_visible), persisted alongside the
; inverse so the loader (l3_copy_app_blob_to_slot -> sc_slot_perm_apply_blob)
; can rewrite each app's compiled SYS_* immediates from the raw row to this
; slot's app-visible number. The dispatcher uses only the inverse; this row is
; the loader's lookup. Slot 0 is identity (see sc_slot_perm_generate).
align 16
sc_slot_perm_fwd:   times (MAX_WINDOWS * syscall_table_count) dw 0
align 16
sc_slot_perm_ready: times MAX_WINDOWS db 0
; Per-slot COMMIT flag (security_todo.md §12). Set ONLY by sc_slot_perm_apply_blob
; once every syscall-number immediate in the slot's copied blob has been rewritten
; to this slot's forward-permuted numbers. The dispatcher applies the inverse map
; iff committed[slot]==1; a 0 means the blob still carries RAW numbers (loader not
; finished, or the lazy dispatch-path generate ran with no bake), for which the
; only correct mapping is identity. Separating "tables built" (ready) from "blob
; rewritten" (committed) removes the window where the inverse is live but the blob
; is not yet permuted. BSS-zero default keeps the OFF build identical.
align 16
sc_slot_perm_committed: times MAX_WINDOWS db 0
%endif

%ifdef ENABLE_DEBUG_SERIAL
; Validator post-condition snapshot storage (security_todo.md §2, debug build
; only). For each slot, sc_postcond_args holds the 6 saved arg qwords captured
; right after sc_validate_from_table passes; sc_postcond_valid[slot] is set then
; and cleared/consumed at the return-path recheck. Debug-only - release builds
; allocate none of this and pay nothing (see the ENABLE_DEBUG_SERIAL gates on
; the dispatch/snapshot/recheck sites).
align 8
sc_postcond_args:  times (MAX_WINDOWS * 6) dq 0
align 8
sc_postcond_valid: times MAX_WINDOWS db 0
%endif
