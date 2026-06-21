# Kernel liveness watchdog — no-freeze invariant

Enforces the directive in `feedback_no_freeze_invariant`: **neither usermode nor
the kernel may ever freeze the rest of the system, regardless of a loop or a
fault.** A stuck operation is abandoned and the culprit terminated; the machine
stays alive. This document covers the *kernel-side* backstops. Ring-3 runaway
callbacks are handled separately (PIT-quantum preemption + the callback deadman +
the priority-manager demote-then-kill).

## Threat → defense map

| BSP stall class | Interrupts | Clock that still ticks | Defense |
|---|---|---|---|
| Kernel infinite loop / livelock | IF=1 (PIT fires) | PIT `tick_count` | **Tier 1** — PIT timer path calls `kwd_check`; longjmp to kmain's r3guard pad |
| Unbounded spinlock / lock deadlock | **IF=0 (cli)** | **TSC only** | **Tier 2** — live AP watches the heartbeat on the TSC clock, fires an **NMI IPI** at the BSP |
| Held lock abandoned by recovery | n/a | — | **Bounded locks** — bounded-steal acquire + per-core held-lock registry; recovery force-releases the BSP's held locks |

The key insight for Tier 2: under `cli` the PIT is masked and `tick_count` is
frozen, so any tick-based deadline is useless. The **TSC keeps advancing with
interrupts disabled**, and an **NMI is non-maskable**, so an AP measuring the
BSP heartbeat against the TSC and punching through with an NMI IPI is the only
construction that can catch a BSP wedged under `cli`.

## Components

### Heartbeat (`watchdog.ghl`)
`kmain` bumps `kwd_hb` once per main-loop iteration (`kwd_bsp_tick`). A frozen
`kwd_hb` past `KWD_STALL_TICKS` (~5 s) means the BSP is wedged. The threshold is
generous on purpose — below it, the finer watchdogs (callback deadman, bounded
locks) act first, so this is a true-freeze backstop, not a scheduler.

### Tier 1 — PIT path (`isr.asm .irq_timer`, IF=1)
On a ring-0 timer tick with a landing pad armed, `kwd_check` (PIT-tick window)
trips if the heartbeat is frozen. The handler releases any BSP-held lock
(`blk_recover_release_bsp`), then longjmps to kmain's `r3guard` landing pad — the
same recovery used for orphaned ring-3 faults — resuming the main loop with
input/render/timers alive.

### Tier 2 — cross-core NMI path (IF=0)
- **`kwd_ap_watch` (`watchdog.ghl`)** — run by every idle AP each worker-loop
  pass. Observes `kwd_hb` against the **TSC** window (`cpu_tsc_per_tick *
  KWD_STALL_TICKS`). On a stall it sets `wd_nmi_pending` and calls
  `wd_send_nmi_bsp`.
- **`wd_send_nmi_bsp` (`apic.asm`)** — LAPIC NMI IPI, physical destination =
  the BSP apic id (`madt_lapic_ids[0]`), `LAPIC_ICR_NMI_PHYS = 0x4400`.
- **`isr_nmi` (`isr.asm`, vector 2)** — a *dedicated* NMI stub that does **not**
  route through `isr_common_stub` (whose nested-exception guard would halt,
  defeating the watchdog). It asks `kwd_nmi_should_recover`; on a yes it releases
  BSP-held locks and longjmps to the r3guard pad, identical to Tier 1.
- **AP self-wake (`wd_arm_ap_tick` + `isr_ap_tick`, vector 48)** — idle APs
  `STI;HLT` and would otherwise only wake on a work IPI. Each idle pass arms a
  one-shot LAPIC timer so the AP self-wakes at a bounded cadence (~tens of ms,
  far tighter than the 5 s deadline) and re-runs `kwd_ap_watch`. The handler is
  trivial (EOI + iretq).

Conservatism: NMI recovery fires **only** when an AP actually flagged a stall
**and** a landing pad is armed. Any other NMI passes through untouched.

### Bounded, recovery-safe locks (`bounded_lock.ghl` + `workqueue.ghl`)
Two failure modes are closed:

1. **Wedged / dead holder.** `wq_lock` no longer spins `while 1`. It spins
   against a **TSC** deadline (valid under `cli`) and, past the deadline,
   **steals** the lock (`wq_lock_steals` diag) so a waiter can never block
   forever. Deadline = `cpu_tsc_per_tick * WQ_LOCK_STALL_TICKS` (~0.5 s) — orders
   of magnitude above the microsecond critical sections here, yet well under the
   5 s freeze deadline.
2. **Holder abandoned by recovery.** Every acquire is recorded in a per-core
   held-lock registry (keyed by `wd_core_index`, disjoint cells → no lock of its
   own). When the watchdog longjmps the BSP, the recovery path calls
   `blk_recover_release_bsp` to drop everything the BSP (slot 0) held, so no
   waiter re-deadlocks on an orphaned holder.

**Deliberate trade-off** (per the no-freeze directive): under a pathological
hold the lock is *stolen*, trading strict mutual exclusion for guaranteed
liveness. The guarded sections (page alloc, framebuffer, driver state, crypto
scratch) are microsecond-scale, so a half-second hold means a wedged holder the
watchdog is independently tearing down.

## Diagnostics
`kwd_recovered_count` (Tier-1 + NMI recoveries), `kwd_nmi_recovered_count`
(NMI trips), `wq_lock_steals` (deadline steals), `blk_recover_count` (locks
force-released by recovery). Serial markers (with `ENABLE_DEBUG_SERIAL`):
`KWDG` (Tier-1 recover), `KWDN` (NMI recover).

## QEMU verification (pending)
- **Tier 1:** a deliberate ring-0 `while(1)` with IF=1 should recover after ~5 s
  (`KWDG`), GUI/input alive.
- **Tier 2:** a deliberate ring-0 `cli; while(1)` should recover after ~5 s via
  the AP→NMI path (`KWDN`). Needs ≥2 cores (`-smp 2+`).
- **Bounded lock:** acquire a `wq_*` lock and never release; a second acquirer
  should steal after ~0.5 s (`wq_lock_steals` increments) instead of hanging.
