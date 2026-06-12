; ============================================================================
; Grit - Per-slot syscall capability bits ("app manifest")
;
; Each syscall is tagged with a CAP_* bit. Each slot has a current cap mask
; in slot_cap_mask[]. At dispatch, the kernel rejects calls whose tag is not
; covered by the slot's mask. Modelled on Android permissions / iOS
; entitlements - declarative, enforced once at the syscall gate, not
; sprinkled through handlers.
;
; Lifecycle:
;   - Every slot starts at CAP_ALL (no restriction) so legacy callers keep
;     working. The first time an app calls SYS_APP_DECLARE_MANIFEST(app_id)
;     its slot mask is *narrowed* (AND-only - can never be widened) to the
;     manifest declared for that app_id in app_manifest_table.
;   - Declaration is one-way: a sandboxed app can never escalate, even by
;     re-declaring a different app's manifest. This is the iOS-entitlement
;     property: capabilities are bounded by the static manifest.
;
; Maintenance:
;   - To add a new capability domain, define a new CAP_* bit here (2 bytes
;     wide). Tag the relevant SYSCALL_ENTRY rows with it. Add it to the
;     manifest of any app that needs it.
;   - To add a new app, append a row to app_manifest_table at index
;     (app_id - APP_MIN_ID). Keep the table dense; APP_MAX_ID bounds the
;     array.
; ============================================================================

%ifndef SYSCALL_CAPS_INC
%define SYSCALL_CAPS_INC

; --- Capability bits (2-byte mask) ------------------------------------------
; CAP_CORE is implicitly granted to every slot; tagging core syscalls with it
; is a no-op against CAP_ALL but makes the intent explicit and survives any
; future change to the default mask.
;
; The mask widened from 1 to 2 bytes so CAP_FS could split into read/write/
; delete and CAP_GUI could split into draw/display. Storage is a low byte
; (slot_cap_mask[]) plus a parallel high byte (slot_cap_mask_hi[]); the row tag
; in the syscall table is a full word (SYSCALL_ENTRY's `dw`). The tamper
; authenticator folds high^low so a flip in either byte is detected (see
; cap_mask_sign / the dispatcher gate).
CAP_CORE        equ 0x0001  ; print, exit, app_done, ticks, sysinfo, handles
CAP_NET         equ 0x0008  ; ping, dhcp, dns, tcp_connect
CAP_APP_CTRL    equ 0x0010  ; launch / open other apps
CAP_WX          equ 0x0020  ; mprotect_wx, wx_install_manifest, wx_jit_alias
CAP_MEDIA       equ 0x0040  ; media_blit_scaled, open_file_media
; low-byte bits 0x0002 (former coarse CAP_GUI), 0x0004 (former coarse CAP_FS),
; and 0x0080 are now free/reserved.

; --- Fine-grained capabilities (high byte) ----------------------------------
; The former single CAP_FS (0x04) split into three so a manifest can grant, e.g.
; read-only or read/write-without-delete. CAP_FS remains as the umbrella alias
; (all three) so existing CAP_FS-bearing manifests keep full FS access.
CAP_FS_READ     equ 0x0100  ; count/entry/chdir/read/format_name/entry_info/open
CAP_FS_WRITE    equ 0x0200  ; write/mkdir/rename/sync_root
CAP_FS_DELETE   equ 0x0400  ; delete
CAP_FS          equ (CAP_FS_READ | CAP_FS_WRITE | CAP_FS_DELETE)
CAP_GUI_DRAW    equ 0x0800  ; gui_rect/text, wm, draw/blend/xml, media_blit
CAP_GUI_DISPLAY equ 0x1000  ; display mode/flags, desktop background, cursor
CAP_GUI         equ (CAP_GUI_DRAW | CAP_GUI_DISPLAY)
; high-byte bits 0x2000.. reserved.

CAP_ALL         equ 0xFFFF

; --- Cap-mask authenticator (time-of-check capability cache) ----------------
; slot_cap_mask[] is plain kernel data, so any kernel-write bug could flip a
; cap bit and silently widen a slot's privileges between writes. To make that
; tamper detectable, slot_cap_hmac[slot] stores
;   low8(kernel_canary ^ slot ^ mask ^ KDOM_CAP_MASK)
; recomputed on every legitimate mask write and re-checked at dispatch before
; the mask is trusted (see cap_mask_sign / cap_mask_verify in syscall.asm).
; The domain byte separates this MAC from the WIN_OFF_USER_ARG / CPI tags that
; reuse the same kernel_canary key, so a tag forged for one can't be replayed
; into the other.
;
; The domain constant and the MAC arithmetic itself now live in ONE place,
; kdomain_hmac.inc (security_todo.md §13): KDOM_CAP_MASK is this user's row in
; the domain-separation table, and KHMAC_TAG is the shared primitive every
; site invokes. Its value (0x5C) is the former CAP_HMAC_DOMAIN, so existing
; stamped authenticators still verify.

; --- Capability-transition audit ring (security_todo.md §4) -----------------
; Every legitimate cap-mask write (declare_manifest narrowing, the loader's
; kernel_apply_app_manifest, slot recycle) is appended to a fixed-size,
; kernel-only ring so a bug that fails to narrow - or any unexpected widening -
; leaves a forensic trail instead of being silent. Kernel-only: there is no
; ring-3 read syscall yet. The ring lives in syscall.asm BSS; cap_audit_log
; (the writer) is the single append point, driven from cap_mask_store.
;
; Each entry is a fixed 16-byte record:
;   +0  dd  seq      monotonically increasing event counter (wraps at 2^32)
;   +4  db  slot     slot id whose mask changed
;   +5  db  old_mask cap mask before the write
;   +6  db  new_mask cap mask after the write
;   +7  db  reason   CAP_AUDIT_* reason code below
;   +8  dd  app_id   app_id involved (declare/manifest paths) or 0
;   +12 dd  pad      reserved / alignment
CAP_AUDIT_ENTRIES   equ 64                 ; ring depth (power of two for & mask)
CAP_AUDIT_ENT_SIZE  equ 16                 ; bytes per record
CAP_AUDIT_IDX_MASK  equ (CAP_AUDIT_ENTRIES - 1)

; Reason codes (entry +7) - why the mask was rewritten.
CAP_AUDIT_DECLARE   equ 0x01               ; SYS_APP_DECLARE_MANIFEST narrowing
CAP_AUDIT_APPLY     equ 0x02               ; kernel_apply_app_manifest (loader)
CAP_AUDIT_RECYCLE   equ 0x03               ; slot recycle reset
CAP_AUDIT_STRIKE    equ 0x04               ; slot auto-killed at SC_STRIKE_LIMIT (§12)
CAP_AUDIT_ANOMALY   equ 0x05               ; behavioral anomaly flagged a strike (§11)
CAP_AUDIT_OTHER     equ 0x00               ; unattributed write (e.g. boot seed)

; --- Per-app manifests ------------------------------------------------------
; Indexed by (app_id - APP_MIN_ID). One row per app, kernel-owned. Apps cannot
; rewrite their own row; SYS_APP_DECLARE_MANIFEST only reads from it.
;
; Stay conservative: grant only what the app actually uses. A grep against
; src/user/apps/*.inc and src/user/grithl/apps/*.ghl is the source of truth
; for what each app calls.

MANIFEST_EXPLORER       equ CAP_CORE | CAP_GUI | CAP_FS | CAP_APP_CTRL
MANIFEST_TERMINAL       equ CAP_CORE | CAP_GUI | CAP_FS | CAP_APP_CTRL | CAP_NET
; Notepad reads and writes files but must never delete one - now expressible
; directly in the manifest (CAP_FS minus CAP_FS_DELETE). The SYS_FS_DELETE deny
; in app_syscall_deny_table stays as defense-in-depth.
MANIFEST_NOTEPAD        equ CAP_CORE | CAP_GUI | CAP_FS_READ | CAP_FS_WRITE
MANIFEST_SETTINGS       equ CAP_CORE | CAP_GUI | CAP_FS
MANIFEST_PAINT          equ CAP_CORE | CAP_GUI | CAP_FS
MANIFEST_ABOUT          equ CAP_CORE | CAP_GUI
%ifdef RELEASE_BUILD
MANIFEST_SECURITY_PROBE equ 0
%else
MANIFEST_SECURITY_PROBE equ CAP_CORE | CAP_GUI | CAP_WX
%endif
MANIFEST_TASKMGR        equ CAP_CORE | CAP_GUI
MANIFEST_PING           equ CAP_CORE | CAP_GUI | CAP_NET
MANIFEST_MEDIA          equ CAP_CORE | CAP_GUI | CAP_FS | CAP_MEDIA

; --- Per-app syscall allowlist (security_todo.md §2) ------------------------
; The CAP_* mask above is coarse: a single CAP_FS bit grants every FS syscall
; (read, write, delete, rename, mkdir, ...). The per-syscall allowlist is the
; finer gate layered on top - an explicit bitmap over syscall_table_count,
; one bitmap per slot, checked at the dispatcher alongside the cap mask.
;
; The bitmap is built (sc_build_allow_bitmap, syscall.asm) from the slot's
; effective cap mask - bit i set iff syscall i's cap tag is covered by the
; mask - and THEN the per-app explicit deny list below clears specific bits.
; This keeps each app at "exactly the syscalls it uses" without authoring a
; full bitmap by hand: caps give the baseline, the deny list trims the rest.
;
; Each app's deny list is a run of syscall numbers terminated by
; SC_DENY_LIST_END (0xFF). Indexed by (app_id - APP_MIN_ID) via the
; app_syscall_deny_table pointer array in syscall.asm. The canonical example:
; Notepad has CAP_FS (it reads/writes files) but must never DELETE one, so its
; list denies syscall 19 (SYS_FS_DELETE). Apps with nothing to trim point at a
; shared empty list (just the terminator).
SC_DENY_LIST_END        equ 0xFF
SC_SYS_FS_DELETE        equ 19         ; must track SYS_FS_DELETE in syscall_user.inc

; --- Per-slot network destination policy (security_todo.md §7) --------------
; CAP_NET above is binary: a slot may touch the network or not. Layered on top
; is an OPT-IN, per-app destination allowlist ("opt-in ATS" - App Transport
; Security style): a slot can declare
;   * a DNS-suffix allowlist  - net_dns_query_a (dns.asm) rejects a hostname
;                               whose suffix is not the slot's allowed suffix
;   * a port-range allowlist  - net_tcp_connect_ipv4 (tcp.asm) rejects a
;                               destination port outside [lo, hi]
;
; The policy lives in kernel BSS (parallel per-slot arrays in
; src/include/net_slot_policy.inc - sec_net_policy_flags/_port_lo/_port_hi/
; _suffix[]), modelled on slot_cap_mask[] / slot_handle_quota[]: OUTSIDE the
; ring-3 arena, so an app cannot widen its own destination policy. DEFAULT
; (BSS-zero) = NO RESTRICTION (CAP_NET alone gates, exactly as before); a
; manifest opts a slot IN via the setters sec_net_set_port_range /
; sec_net_set_suffix. Enforcement is FAIL CLOSED within an active policy.
;
; MANIFEST DECLARATION SHAPE (for the future SYS_NET_SET_POLICY / loader hook
; that wires these into the dispatcher - deferred, see net_slot_policy.inc):
;   PING (CAP_NET) - diagnostic, no TCP/DNS allowlist needed.
;   TERMINAL (CAP_NET) - the only app that opens arbitrary destinations; would
;     declare a broad/empty policy (no restriction) unless an install profile
;     narrows it.
; A representative tightened profile a packaged app could declare:
;   sec_net_set_suffix(slot, "example.com")  ; only *.example.com / example.com
;   sec_net_set_port_range(slot, 443, 443)   ; HTTPS only
; The CAP_NET-holding manifests above (MANIFEST_TERMINAL, MANIFEST_PING) are
; unchanged here because the policy is per-slot runtime state seeded at
; manifest-apply, not a static cap bit; the storage + enforcement land now, the
; per-app declared values plug in when the dispatcher setter is wired.

%endif ; SYSCALL_CAPS_INC
