# Security finding: an unprivileged app can permanently disable its own syscall-strike kill switch

**Severity:** High (defense-in-depth bypass — neutralizes the §12 anti-probing/anti-fuzzing
auto-kill that exists specifically to stop a sandboxed tenant from brute-forcing the syscall
interface for a memory-safety bug).

**Status:** Introduced by the *currently uncommitted* diff on branch `dev`
(`syscall_security.inc`, `syscall_handlers_gui_wm.inc`, `syscall_perm.inc`, `constants.inc`).
Provable by static control-flow analysis; no build required to confirm the chain.

**Class:** Logic / security-control bypass (TOCTOU on a security flag the attacker can clear).

---

## Summary

The uncommitted change gates *all* syscall strike accounting behind the
`WF_MANIFEST_OK` (0x20) flag of the **window whose index equals the calling slot id**:

```asm
; src/kernel/proc/syscall_security.inc  (sc_record_strike, NEW code)
    mov   eax, ecx                       ; ecx = r15b = slot id
    imul  eax, eax, WINDOW_STRUCT_SIZE
    add   rax, WINDOW_POOL_ADDR
    test  qword [rax + WIN_OFF_FLAGS], WF_MANIFEST_OK
    jnz   .srs_sandboxed                 ; only HERE does a strike count / kill
    ...                                  ; flag clear -> strike SILENTLY IGNORED
    ret
```

Strikes are only counted — and `SC_STRIKE_LIMIT` (16) can only fire the
demote/kill teardown — when `window[slot].WF_MANIFEST_OK` is set.

The author's threat model covered one way to mint a strike-immune slot
(`SYS_WM_CREATE`, which the diff patches to set `WF_MANIFEST_OK` on new windows)
but **missed `SYS_WM_CLOSE`**, which *clears* the flag on the slot's existing
primary window while the app keeps running.

## The chain

An app runs in slot `N`; its primary window is `window[N]` and the launcher set
`WF_MANIFEST_OK` on it via `kernel_apply_app_manifest`.

1. App calls `SYS_WM_CLOSE(N)` (app syscall #15) — closing **its own** window.
   `sc_wm_close` explicitly permits this: it only requires `edi == r15d`
   (the window being closed is the slot's own), `WF_ACTIVE`, and an APPDATA
   ownership match — all true for the app's own window.

2. `wm_close_window` (`src/kernel/gui/window_lifecycle.inc:260`) does:
   ```asm
   mov qword [rax + WIN_OFF_FLAGS], 0   ; Clear all flags (inactive)
   ```
   → `WF_MANIFEST_OK` on `window[N]` is now **0**.

3. The same handler calls `l3_release_slot(N)`. Because the slot being released
   is the *current* slot (`edi == r15`), it takes the early-out
   (`usermode_slot_install.inc:230`):
   ```asm
   cmp r8, r15
   je  .release_clear_meta   ; "do not erase code under an active syscall"
   ```
   The slot's code/stack pages are **not** wiped — only metadata is cleared.

4. `sc_wm_close` returns 0 and `SYSRET`s back to ring 3. The app's code is still
   mapped and **continues executing** (its window is gone, but it is a live slot
   with the CAP_CORE floor still granted: print, exit, app_done, ticks, sysinfo,
   handles, and any CAP_CORE pointer-bearing syscalls).

5. From now on every security reject (cap / arg-validate / rate) routes through
   `sc_record_strike`, which reads `window[N].WF_MANIFEST_OK == 0` and takes the
   **`ret` (strike ignored)** path. `slot_sc_strikes[N]` is never incremented,
   `SC_STRIKE_LIMIT` is never reached, and the slot is **never** demoted or killed.

The app is now permanently strike-immune and can probe/fuzz the CAP_CORE syscall
surface — including pointer-validation paths — with no penalty beyond the
per-tick rate limit (which only slows, never kills). The kill path inside
`sc_record_strike` (`.srs_sandboxed` → `wm_close_window`) is itself now
unreachable for this slot, because the gate above it is never taken.

## Why it matters

§12's strike→demote→kill engine is the control that makes interface
brute-forcing "no longer silent and cost-free" (its own comment). An attacker
trying to discover a kernel memory-safety bug by hammering syscall argument
validators is exactly who it targets. This regression hands that attacker an
unlimited, consequence-free probing budget by issuing a single ordinary syscall
the sandbox already allows.

## Proof-of-concept

A minimal app (GritHL/asm). After `SYS_WM_CLOSE` of its own window it loops
issuing a deliberately-invalid CAP_CORE pointer syscall; pre-patch this kills the
slot after 16 strikes, post-patch it loops forever untouched. See
`scripts/dev/poc_strike_immunity.inc` for the syscall sequence.

```
; slot N, window N already open + manifested
SYS_WM_CLOSE  N                ; clears window[N].WF_MANIFEST_OK; slot stays live
.probe:
    ; any syscall that returns -1 for a security reason (bad pointer, denied cap,
    ; rate) now feeds sc_record_strike, which IGNORES the strike post-close.
    SYS_SYSINFO  0xFFFFFFFFDEAD0000      ; bogus out-ptr -> validate reject, no strike
    jmp .probe                            ; never killed; pre-patch: dead at 16
```

**Observable difference (the assertion that proves it):**
- *Without* the diff (or with the fix below): the slot is torn down after 16
  rejects — `CAP_AUDIT_STRIKE` is logged and the window/slot reclaimed.
- *With* the diff: the loop runs unbounded; no `CAP_AUDIT_STRIKE`, slot stays live.

## Fix

Strike accounting must key off the slot's *liveness/sandbox* state, not a window
flag the tenant can clear. Options, simplest first:

1. **Track sandbox state per slot, not per window.** Set a `slot_sandboxed[N]`
   byte in `kernel_apply_app_manifest`/the CAP_CORE floor apply, and test *that*
   in `sc_record_strike`. It is never cleared by `wm_close_window`. (`l3_release_slot`
   for a genuinely recycled slot clears it; the self-close active-syscall path does
   not, which is correct — a still-running slot must remain strike-eligible.)

2. If staying window-flag based: in `wm_close_window`, only zero the flags when the
   slot is actually being torn down (`edi != r15`), mirroring `l3_release_slot`'s
   own active-syscall guard — i.e. do not clear `WF_MANIFEST_OK` for a self-close
   while the app keeps running.

Option 1 is preferred: the strike control's subject is the *slot/process*, so its
gating state should live with the slot, decoupled from window lifecycle entirely.

## Secondary observation (separate, lower severity)

`blend_span_argb` and `blend_span_argb_screen` (`src/kernel/drivers/display_blend.inc`)
clip Y against `scr_height` and stride with `scr_pitch_q` while basing writes at
`raster_target_addr`; the `_multiply` variant correctly uses
`raster_target_height`/`raster_target_pitch_q` throughout. For the only non-screen
target (the slot-0 wallpaper cache, which is *packed* `scr_width*4`), a framebuffer
with padded stride (`scr_pitch_q > scr_width*4`, common on real-HW GOP) makes the
bottom rows write past the packed cache — a kernel OOB write. Not attacker-controlled
(pixels come from a built-in SVG theme) and masked on QEMU (pitch == width*4), but it
should be made geometry-consistent with the `_multiply` variant.
