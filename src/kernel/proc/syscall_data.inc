; ============================================================================
; syscall_data.inc
; syscall .data/.bss: counters, canary, cap masks, budget/strike, trace ring/hist, per-slot permutation, postcond, manifest tables
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
; --- Data/BSS Sections moved here ---
section .data
global syscall_count
syscall_count: dq 0
%ifdef ENABLE_DEBUG_SERIAL
; DEBUG (blank-app diagnosis): caps the XCAP cap-reject serial spew so a window
; redraw that issues thousands of (denied) draw calls doesn't flood the log.
xcap_log_count: dd 0
; DEBUG (blank-app diagnosis): one bit per syscall number, set the first time an
; app slot (>=2) successfully dispatches it. Lets us print the *set* of syscalls
; an app issues (XDSP) once each, instead of flooding on every redraw frame.
xdsp_seen_bitmap: times 32 db 0
%endif
align 8
global kernel_canary
kernel_canary: dq 0
%ifdef ENABLE_SHADOW_STACK_POC
shadow_poc_saved_rsp: dq 0
%endif
sc_net_ping_busy: db 0
sc_net_tcp_busy: db 0
sc_net_dns_busy: db 0
szHelloUser: db "-> Hello from RING 3 (via SYSCALL)!", 0

; Per-slot effective capability mask. Default-deny (security_todo.md §4): every
; slot boots at CAP_CORE only (print/exit/ticks/sysinfo/handles), NOT CAP_ALL —
; so a slot that runs a syscall before its manifest is applied can only touch
; the core surface, killing the old CAP_ALL race window. Each launch path
; re-stamps the slot's real, possibly-wider manifest via
; kernel_apply_app_manifest (APPLY_MANIFEST in launch.inc) right after
; wm_create_window_ex, so every legit app still gets the caps it declares.
; SYS_APP_DECLARE_MANIFEST narrows entries with AND; nothing widens them past
; the manifest. The dispatcher reads slot_cap_mask[r15] on every syscall.
;
; NOTE: because CAP_CORE is the floor, every launched app MUST have an
; APPLY_MANIFEST (kernel_apply_app_manifest) on its launch path or it will be
; restricted to CAP_CORE. All current launch paths in launch.inc do; a new
; launch path must add one or the app will lose GUI/FS/etc. access.
align 8
slot_cap_mask: times MAX_WINDOWS db CAP_CORE

; Per-slot authenticator paralleling slot_cap_mask[] (security_todo.md §4,
; "Time-of-check capability cache"). Each byte is
;   low8(kernel_canary ^ slot ^ mask ^ KDOM_CAP_MASK)
; recomputed by cap_mask_sign whenever the mask is legitimately written, and
; verified inline by the dispatcher's cap gate before the mask is trusted. The
; static CAP_ALL masks above can't have their HMAC assembled in (the canary key
; is runtime-only), so slot_cap_hmac_init seeds every entry at boot once
; kernel_canary holds its final value. The zeros here are just the pre-init
; placeholder; the dispatcher never runs before slot_cap_hmac_init.
align 8
slot_cap_hmac: times MAX_WINDOWS db 0

; Capability-transition audit ring (security_todo.md §4). Fixed-size,
; kernel-only forensic trail of every cap-mask write. cap_audit_head is the
; running event count; (head & CAP_AUDIT_IDX_MASK) is the next record index, so
; the ring overwrites oldest-first once it fills. See cap_audit_log (the single
; append point) and CAP_AUDIT_* layout/reason codes in syscall_caps.inc. No
; ring-3 read syscall yet — inspected from the kernel/debugger only.
align 8
cap_audit_head: dd 0                         ; monotonic event counter
align 16
cap_audit_ring: times (CAP_AUDIT_ENTRIES * CAP_AUDIT_ENT_SIZE) db 0

; Per-slot syscall rate-limiting token bucket (security_todo.md §2).
; One word budget per slot, decremented at dispatch entry and refilled to
; SC_BUDGET_PER_TICK by pit_handler on every timer tick. A slot that drains
; its budget within a single tick has further syscalls denied (-1) until the
; next refill. This caps the syscall rate to SC_BUDGET_PER_TICK * PIT rate,
; which is far below the millions-of-calls a fuzzer or side-channel oracle
; needs while leaving plenty of headroom for legitimate GUI apps.
; SC_BUDGET_PER_TICK lives in constants.inc so pit_handler shares the value.
; Exported so pit.asm's refill loop can reach it.
global slot_sc_budget
align 16
slot_sc_budget: times MAX_WINDOWS dw SC_BUDGET_PER_TICK

; Per-slot security-reject strike counter (security_todo.md §12, "Slot teardown
; on suspect syscall return"). One word per slot, incremented by sc_record_strike
; on every -1 return for a security reason (cap mismatch, validator reject, rate
; reject). When a slot reaches SC_STRIKE_LIMIT (constants.inc) the dispatcher
; auto-kills it (wm_close_window) and appends a CAP_AUDIT_STRIKE record to the
; cap audit ring, then resets the counter so a recycled slot starts clean.
; Turns previously-silent, cost-free rejections into a self-terminating probe.
align 16
slot_sc_strikes: times MAX_WINDOWS dw 0

; Per-slot syscall allowlist bitmap (security_todo.md §2, "Manifest declares
; syscall set, not just cap bits"). One bit per syscall number, SC_ALLOW_BYTES
; bytes per slot; bit i set == slot may invoke syscall i. The dispatcher tests
; this bit right after the coarse cap gate, so an app is confined to the exact
; syscall set its manifest implies — finer than the CAP_* mask alone (Notepad
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

; --- Always-on per-syscall trace ring + per-slot histogram (security_todo.md
; §11). Layout/sizing constants and the inline append live in
; syscall_trace.inc. All three arrays are kernel BSS, OUTSIDE the ring-3 slot
; arena, so an app can neither read its own forensic trail nor forge its
; histogram to dodge the anomaly detector.
;
; sc_trace_ring[]  — per slot, the last SC_TRACE_RING_ENTRIES syscall records
;                    (oldest-first). Shipped by sc_trace_dump for crash triage.
; sc_trace_head[]  — per slot, a running u16 event counter; low bits index the
;                    ring. BSS-zero starts each slot's ring empty.
; sc_trace_hist[]  — per slot, SC_TRACE_HIST_SLOTS saturating u16 counters keyed
;                    by syscall number. THE data source for sc_anomaly_scan_all.
align 16
sc_trace_ring:  times (MAX_WINDOWS * SC_TRACE_SLOT_BYTES) db 0
align 16
sc_trace_head:  times MAX_WINDOWS dw 0
align 16
sc_trace_hist:  times (MAX_WINDOWS * SC_TRACE_HIST_SLOTS) dw 0

%ifdef ENABLE_SYSCALL_PERM
; --- Heterogeneous syscall numbering per slot (security_todo.md §12) ---------
; Per-slot INVERSE permutation of the syscall table, in KERNEL BSS OUTSIDE the
; ring-3 arena (parallel to slot_cap_mask[]/slot_syscall_allow[]/l3_slot_key[]),
; so a slot's own memory-write bug can't rewrite its mapping. One byte per
; syscall number per slot:
;   sc_slot_perm_inv[slot*syscall_table_count + app_visible] = real_table_row
; The dispatcher applies this on entry to recover the real row from the number
; the app issued. The matching FORWARD permutation (real_row -> app_visible) is
; what a future loader-side rewrite stamps into the app's SYS_* constants; it is
; built transiently in sc_slot_perm_generate and discarded — only the inverse
; the kernel needs is persisted.
;
; sc_slot_perm_ready[slot] is the generation sentinel: BSS-zero (0) = "not
; generated yet" -> the lazy ensure path treats the slot as IDENTITY until it is
; generated. After generation it is 1. This makes a never-dispatched slot, and
; the whole default (non-ENABLE_SYSCALL_PERM) build, behave exactly as today.
align 16
sc_slot_perm_inv:   times (MAX_WINDOWS * syscall_table_count) db 0
; The FORWARD permutation (real_row -> app_visible), persisted alongside the
; inverse so the loader (l3_copy_app_blob_to_slot -> sc_slot_perm_apply_blob)
; can rewrite each app's compiled SYS_* immediates from the raw row to this
; slot's app-visible number. The dispatcher uses only the inverse; this row is
; the loader's lookup. Slot 0 is identity (see sc_slot_perm_generate).
align 16
sc_slot_perm_fwd:   times (MAX_WINDOWS * syscall_table_count) db 0
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
; and cleared/consumed at the return-path recheck. Debug-only — release builds
; allocate none of this and pay nothing (see the ENABLE_DEBUG_SERIAL gates on
; the dispatch/snapshot/recheck sites).
align 8
sc_postcond_args:  times (MAX_WINDOWS * 6) dq 0
align 8
sc_postcond_valid: times MAX_WINDOWS db 0
%endif

