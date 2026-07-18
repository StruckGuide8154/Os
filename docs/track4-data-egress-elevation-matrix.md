# Track 4 Part D - Exfiltration → Elevation Matrix

_The load-bearing claim of Track 4: **a leaked RAM dump must NOT compose into
privilege elevation.**_ This document is the **static-audit half** of
`track4-ram-secure-erasure-todo.md` Part D item 12 - for every artifact an
attacker can recover from a fully-reversed dump, it names the independent
barriers that defeat reuse of that artifact on a *fresh boot*, and cites the
live code that enforces each barrier. The **dynamic half** (a planted-leak
negative test that boots twice and proves the per-boot/per-slot rotation makes a
dumped secret stale, so elevation still fails) is now **DONE and re-verified**
(`scripts/dev/test_track4_planted_leak.ps1`, all tiers PASS incl. the two-boot
QEMU ephemerality proof) - see "Honest gaps" below for the script set and its
TCG hardware caveat.

_Reconciled: 2026-06-27. Authority: this is a Track 4 doc, subordinate to
`STATUS.md` §9 (scope) and `architecture-defense-in-depth.md` (topology)._

---

## Attacker model for this matrix

A **one-shot snapshot attacker** (single `pmemsave` / cold-boot image / DMA
capture) who then **fully reverses** the dump offline and recovers *every*
secret in it: per-boot `kernel_canary`, `l3_boot_nonce`,
`l3_slot_key[]`, the build-time blob-signing/cap key, the per-slot code/stack
ASLR slides, live CPI/cap-mask tags, the heterogeneous syscall permutation, and
all file/blob bytes. The attacker then attempts to use that knowledge to elevate
(escape a ring-3 slot, forge a kernel-checked authenticator, or run a
dump-built exploit blob) on a **subsequent fresh boot** of the same image.

Out of scope (unchanged from STATUS §9): a *sustained* attacker who reads DRAM
repeatedly or single-steps the CPU (reads the on-die working set as it
decrypts), and a physical attacker who rewrites the boot medium.

---

## Why a fresh boot defeats a dumped secret - the two pivots

1. **Per-boot ephemerality.** Every authenticator-bearing secret is re-drawn
   from `RDTSC ^ RDRAND` (CPUID-gated, folded through splitmix64 + the certified
   qrng seed) on each boot, in `kmain` via `kernel_canary_init()` →
   `slot_cap_hmac_init()` → `nx_mem_key_ensure()` → `nx_secret_mask_seed()`
   (`src/kernel/grithlk/kernel_lifecycle.ghl:272`). A value lifted from boot A
   is statistically unrelated to boot B.
2. **Per-slot/per-launch diversification.** Keys, ASLR slides, and the syscall
   numbering are not even constant *within* a boot - they are re-derived per slot
   install / per launch, so a secret valid for slot _i_ at launch _t_ is wrong
   for slot _j_ or launch _t+1_.

Every row below reduces to one or both pivots, and each is independent: defeating
one does not defeat the others.

---

## The matrix - recoverable artifact × barriers that defeat its reuse

| Recovered artifact | Barriers that independently defeat its reuse on a fresh boot |
|---|---|
| **qrng seed** (compiled into image) | (1) folded into per-boot `kernel_canary`/`nx_mem_key` draws, never used raw as an authenticator; (8) measured boot + manifest MAC means a *modified* image won't boot anyway |
| **`kernel_canary`** | (1) per-boot RDTSC^RDRAND; (5) CPI tags also bind the live window VA; (6) cap-mask HMAC also binds slot id + domain; (12) shadow-stack/guard-page ROP defense is canary-independent |
| **`l3_boot_nonce`** | (1) per-boot draw; consumed only as a per-boot mixing input, never a standalone gate |
| **`l3_slot_key[]`** | (1) per-boot; (2) per-slot - one slot's key never widens another; (11) the slot is still confined to its manifest's allowlist regardless of key |
| **blob-signing / cap key** (build-time) | (6) a forged/widened cap mask still needs the *fresh* canary + slot id + domain constant and is re-stamped on every legit write - a stale mask fails closed → CANARY panic; (8) a re-signed blob still fails measured boot unless the image itself is replaced (physical-attacker, out of scope) |
| **per-slot code/stack ASLR slide** (`l3_slot_code_slide[]`, `l3_slot_ustack_off[]`) | (4) re-drawn per slot install; leaked gadget addresses don't transfer to the next slot/boot; (5) CPI tags reject a dumped callback target; (7) W^X + nk-monitor blocks the write-then-exec the gadget chain would need |
| **live CPI tag** | (5) tag binds the live window VA *and* the per-boot canary - a dumped tag won't verify after boot; verified at *every* dispatch site (click/key callbacks) |
| **heterogeneous syscall permutation** | (3) per-launch permutation - a static exploit blob built from the dump lands on the wrong handler next launch → out-of-range → `.sc_invalid` → −1 |
| **file / blob bytes** | (8) tampering the bytes fails measured boot + blob MAC, fail-closed; (11) reading them grants no capability the manifest didn't already allow; (10) a slot iterating an attack is killed by the anomaly/strike teardown |
| **gadget addresses (kernel)** | (7) W^X + nk-monitor: no secret lets ring-3 make a page W+X or remap a slot supervisor - the PTE write `#PF`s; (9) KPTI/SMAP/SMEP keep kernel memory non-reachable from ring-3; (12) kernel shadow stack fails ROP closed |

---

## The twelve barriers (audited present in live code)

Legend: `[x]` mechanism confirmed present + the per-boot/per-slot rotation
argument holds by code inspection. `[ ]` not yet independently *tested* by a
planted-leak vector (the dynamic half).

- [x] **(1) Per-boot ephemeral secrets.** `kernel_canary`, `l3_boot_nonce`,
      `nx_mem_key` drawn `RDTSC^RDRAND` per boot in `kmain`
      (`kernel_lifecycle.ghl:272-276`); RDRAND CPUID-gated, falls back to
      RDTSC+canary+qrng-seed fold. _Dump from boot A is worthless vs boot B._
- [x] **(2) Per-slot key separation.** `l3_slot_key[]` is per-slot AND per-boot
      (`src/kernel/proc/usermode_slot_state.inc`, `usermode_storage.inc`); one
      slot's key never widens another.
- [x] **(3) Heterogeneous syscall numbering.** Per-launch permutation
      (`src/kernel/proc/syscall_perm.inc`, `syscall_dispatch_core.inc`,
      `app_sysno.inc`); out-of-range → `.sc_invalid`.
- [x] **(4) Per-slot code ASLR.** `l3_slot_code_slide[]` / `l3_slot_ustack_off[]`
      re-drawn per slot install (`usermode_slot_install.inc`,
      `usermode_translate.inc`); leaked gadget addrs don't transfer.
- [x] **(5) Code-pointer integrity tags.** `cpi_verify_callback` bound to live
      window VA + per-boot canary, verified at every dispatch site
      (`syscall_security.inc`, `syscall_handlers_gui_wm.inc`,
      `grithlk/input_dispatch.ghl`).
- [x] **(6) Cap-mask HMAC + time-of-check auth.** `slot_cap_hmac[]` keyed by
      fresh-boot canary + slot id + domain, re-stamped on every legit write
      (`syscall_secure.ghl`, `syscall_perm.inc`, `syscall_dispatch_core.inc`); a
      stale dumped mask fails closed → CANARY panic.
- [x] **(7) W^X + nested-kernel page-table monitor.** `nk_monitor` maps the PT
      region RO post-lockdown; every PTE write `#PF`s outside the audited window
      (`src/kernel/core/nk_monitor.asm`, `usermode_paging.inc`,
      `syscall_handlers_wx_net.inc`). _No secret makes a page W+X._
- [x] **(8) Measured boot + blob MAC, fail-closed.** `measured_boot_init` →
      `mb_digest`, `app_manifest_verify` / `app_segment_verify` (and rollback
      `app_blob_verify_signature`) halt before any ring-3 entry on mismatch
      (`crypto.ghl`, `kernel_lifecycle.ghl:279-285`).
- [~] **(9) KPTI / SMAP / SMEP.** SMAP/SMEP active; KPTI is build-gated and
      **default-OFF** (`src/include/kpti.inc`; triple-faults on ring-3
      round-trips until the entry trampoline relocates below 2 MiB - see memory
      `feedback_kpti_default_off_triplefault`). Marked `[~]`: the SMAP/SMEP barrier
      holds; the KPTI leg is scaffold, not on by default.
- [x] **(10) Anomaly detector + strike teardown.** Risk-scored syscall probing
      kills a slot before it can iterate a leaked-secret attack
      (`syscall_security.inc`, `syscall_perm.inc`, `syscall_data.inc`).
- [x] **(11) Default-deny caps + per-syscall allowlist.** A hijacked slot is
      confined to its manifest's exact call set (`syscall_perm.inc`,
      `syscall_dispatch_core.inc`; capability manifests per memory
      `syscall_capability_manifests`).
- [x] **(12) Kernel shadow stack + guard pages.** `rsp^0x2000` mirror on the
      syscall path + syscall-stack guard pages (`syscall_security.inc`,
      `usermode_paging.inc`, `l3_install_syscall_stack_pt`); ROP into the kernel
      fails closed.

**11 of 12 barriers are confirmed present and load-bearing by static audit; (9)
is `[~]` because its KPTI leg is default-off scaffold (SMAP/SMEP hold).** No
single recovered artifact, and no small set of them, composes into elevation -
each artifact's row above is defeated by ≥2 independent barriers.

---

## Honest gaps (NOT closed by this document)

- **Formal proof of the three diversification barriers DONE (2026-06-10).**
  Barriers (1) per-boot ephemerality, (2)/(4) per-slot key+ASLR confinement, and
  (3) per-launch syscall permutation are now machine-checked theorems in the
  Track-3 proven-invariant kernel, not merely static audit: `INV-EPHEMERAL-NO-REPLAY`,
  `INV-PER-SLOT-KEY-CONFINED`, `INV-SYSCALL-PERM-PER-LAUNCH` in
  `src/tools/security/invariant_check.ghl`, each proven exhaustively over its
  bounded context space (`scripts/test/eval_invariants.py --exhaustive`, 32,768
  evaluations apiece). They encode the load-bearing claim directly: a secret
  bound to context A (boot epoch / slot id / launch permutation) fails closed
  when presented in any context B. This closes the *formal* half of "leak ≠
  elevation" for the three diversification pivots; the planted-leak *boot* test
  below remains the empirical complement.
- **Dynamic proof DONE (2026-06-09; strengthened and reverified 2026-07-17).**
  The two dynamic test scripts now live at
  `scripts/dev/test_track4_planted_leak.ps1` (planted-leak negative test -
  four tiers: symbol audit, two-boot ephemerality proof, structural barrier
  argument, and execution of the real planted 128-bit stale/lane-corrupted
  cap-MAC rejection vectors) and `scripts/dev/test_track4_pmemsave.ps1` (QEMU
  `pmemsave` pre/post-wipe dump grep with a mandatory runtime-only positive
  control). Both carry the mandatory QEMU TCG caveat: software barriers only;
  TME/SME Part C requires real silicon or KVM+SEV.
- **Barrier (9) KPTI is default-off** (triple-faults until the trampoline moves
  below 2 MiB). The SMEP/SMAP leg is live; the KPTI leg is not a barrier you can
  rely on today.
- **TCG cannot test the HW-gated legs.** Per STATUS §9 / TODO-INDEX, TME/SME and
  CET are no-ops under QEMU TCG; barriers that lean on them are software-only
  until verified on real silicon.
