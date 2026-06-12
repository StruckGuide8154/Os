# GritOS Defense-in-Depth Architecture (Separation-Kernel Topology)

Canonical picture of the layered, capability-mediated, attested architecture, and
the design rules that make an iOS-class exploit chain both **unreachable** and
**unusable**. This is the target topology the beyond-zero-trust tracks climb to;
each box below names the real primitive that already implements part of it.

## The core invariant (why this beats iOS)

> Every stage of an exploit kill-chain is gated by a DIFFERENT component that is
> smaller and lower-privileged than the one being attacked, isolated from it, and
> NOT reachable from where the attacker currently sits.

iOS layers mitigations (sandbox, PAC, PPL, KTRR, trustcache) but the **kernel
enforces all of them**, so one kernel R/W primitive disables the whole stack. Here
the enforcers are **stratified**: a compromised parser can't reach the proxy's
authority, a compromised driver can't reach the kernel's, a compromised kernel
partition can't reach the monitor's. Compromise of stage N yields nothing for
N+1 because N+1's enforcer is out of N's reach.

Honesty rule (carried from STATUS.md §9): "impossible" is always bounded by the
stated verification. There is one irreducible root - the lowest **separation
monitor** - which we do not pretend is unbreakable; we make it tiny, formally
checked, and split-authority for the most dangerous operations. We never claim
security after the monitor itself is subverted.

## Topology (top = lowest privilege enforcer)

```
[ Separation Monitor ]   raw memory/IO/DMA gate; re-validates attested requests.
   (hypervisor tier)     Opportunistic (VT-x/AMD-V + IOMMU when present);
                         nk_monitor.asm is the always-on SOFTWARE FLOOR.
        ▲  attested request trail (the kernel cannot forge the monitor's key)
        │
[ Kernel partitions ]    Split authority: memory ≠ scheduler ≠ IPC ≠ device ≠
                         policy-load ≠ recovery. "Trusted root apps / pre-signed
                         syscalls" run here but are STILL sandboxed + capability-
                         gated. No partition can mint global authority alone.
        ▲  capabilities (unforgeable, kernel-mediated) - fast path
        │
[ Safe proxy processes ] Reference monitors. A driver/app holds NO direct I/O,
                         kernel R/W, or hypervisor call - it sends a capability-
                         bound request to a proxy, which re-derives authority from
                         the CALLER's identity (no confused deputy) and forwards a
                         minimal, attested request down.
        ▲                       ▲
        │ caps                  │ caps
[ Kernel-installed apps ]   [ Userland apps ]   Both heavily sandboxed, default-
  (drivers etc, as              (per-slot)       deny, per-slot keys, ASLR,
  USER-SPACE processes)                          heterogeneous syscall numbering.
        ▲
        │ one-shot
[ Ephemeral parser workers ]  Every untrusted-input decode (image/font/XML/SVG/
                              packet) runs in a fresh, near-zero-authority worker
                              that is KILLED after one operation. No long-lived
                              daemon to corrupt (kills the FORCEDENTRY class).
```

## The kill-chain, stage by stage (reach AND use both blocked)

| # | iOS-class step | "Can't REACH it" | "Can't USE it" | Enforcer (lower component) |
|---|---|---|---|---|
| 1 | Malicious input hits a memory-unsafe parser | Untrusted input only reaches **memory-safe GHL** parsers (bounds-checked, `--forbid-asm`); thin schema/canonical validator first | n/a - the corruption class is absent in safe code | compiler + presubmit |
| 2 | Code exec in the component | Parser runs in a **one-shot ephemeral worker** with near-zero caps; no persistent state to groom | W^X + no ambient JIT; CFI/CPI on every indirect call; default-deny caps make exec a dead end | kernel W^X, CPI tags, code-range hash |
| 3 | Sandbox escape (IPC to a privileged peer) | **No ambient IPC** - a component can only reach endpoints it holds an unforgeable capability for; interface IDs are per-launch randomized | Proxy binds the request to the **caller's** identity, re-derives authority itself (no confused deputy); request is replay/epoch-bound | safe proxy + capability system |
| 4 | Kernel R/W primitive | Only **handles** cross the boundary (no raw kernel VA); SMAP/SMEP/KPTI wall off kernel memory | Even a kernel-write can't flip security state: cap masks are **HMAC-authenticated** (forge → panic), page tables are **nk-monitor read-only** (write → #PF), code is **W^X + range-hashed** (modify → panic) | nk_monitor, cap-HMAC, code-range hash |
| 5 | Disable mitigations / elevate | Mitigations are enforced **below** the kernel (monitor/nk), not by the kernel - a kernel R/W can't reach the enforcer | The **monitor re-validates** every privileged action against the attested trail; a subverted kernel can't produce a valid attestation (no monitor key), so its grant is refused | separation monitor |
| 6 | Persist across reboot | **Amnesiac** (Track 4): nothing survives power-off; no trustcache to poison | Per-boot ephemeral secrets → an offline-prepared payload is stale next boot | Track 4 + measured boot |
| 7 | Lateral / cross-process read | Per-slot isolation + at-rest in-RAM encryption | **Non-interference** invariant: no cross-slot flow except via an explicit shared handle | Track 3 INV + per-slot key |

The point of the two middle columns: iOS-class chains progress because each step's
*reach* OR *use* is left open. Here both are independently closed, by different
components.

## The 5 hard parts, designed out

1. **Capabilities for the common path, crypto only across distrust.** In-machine
   IPC the kernel mediates uses **unforgeable kernel-managed capabilities** (the
   handle table) - fast, no per-call crypto. Cryptographic attestation is used
   ONLY where the verifier does not trust the mediator: the request trail the
   **monitor** re-checks so a compromised kernel partition can't forge a grant.
   Never MAC an already-capability-checked in-process hop.

2. **Performance on hot driver paths.** No per-operation round trip: drivers use
   **shared-memory descriptor rings with attested batch descriptors** (validate
   the batch once, not each byte) and **session-bound MACs after a one-time
   authenticated setup** (never per-packet asymmetric crypto). The framebuffer /
   NIC / xHCI fast paths run on a pre-validated grant, re-attested only on policy
   change. Perf gates (master TODO P1) bound the overhead.

3. **Portability - hardware is opportunistic, software is the floor.** The
   monitor's raw gate uses **VT-x/AMD-V + IOMMU when present**, and falls back to
   the always-on **`nk_monitor.asm` page-table monitor + `mmio_bounds.inc` driver
   region registry** when absent. Same detect-and-opportunistically-enable pattern
   as CET/SMAP/KPTI and the Track 4 TME/SME tier. The design NEVER requires a
   specific CPU feature to be safe - it gets *stronger* when one is present.

4. **TCB concentration.** The proxy and monitor become the TCB, so they are kept
   **minimal, capability-checking, and formally verified** (Track 3 invariants
   bind their authority). Every request carries the caller's identity bound in
   (endpoint binding + confused-deputy tests). More layers ⇒ each must be smaller
   and checked, or the chain just relocates its single point of failure.

5. **Liveness - fail-closed but recoverable.** Every gate fails closed, but a
   rejected/over-budget/crashed component is **quarantined and restarted**
   (MINIX-3-style driver restart), so "deny" never means "system wedged." Recovery
   authority is a separate partition (it cannot be used to skip measurement).

## Beyond iOS - additional hardening (net-new classes)

- **One-shot ephemeral workers** for all untrusted parsing - no long-lived daemon
  to corrupt; the single biggest structural difference from iOS's daemon model.
- **Attested request provenance**: every privileged action carries a chain proving
  which authorities approved it, re-checkable by the monitor; a forged step breaks
  the chain.
- **Threshold authority for the most dangerous runtime ops** (make-page-executable,
  grant-DMA, load-policy): no single partition can authorize - runtime co-approval,
  the Track 2 threshold idea applied to *operations*, not just artifacts.
- **Information-flow labels**: data can't flow from a secret region to an exfil
  sink without a declassifier (extends the Track 3 non-interference invariant).
- **Per-component, per-boot randomization of everything** - ASLR, syscall numbers,
  interface IDs, struct layouts - so no static exploit ever transfers between
  launches or boots.
- **End-to-end CFI**: CET/IBT where present + software CFI floor; shadow stacks on
  every privileged path.
- **Deterministic, formally-checked IPC protocol** - do NOT hand-roll attested IPC
  (reflection/replay/endpoint-substitution bugs); use one verified protocol with
  message-type + endpoint + epoch + nonce binding.

## What exists vs. what is net-new

ALREADY REAL (software floor, today): nk_monitor page-table RO enforcement,
handle-table (no raw kernel VA), syscall manifests + default-deny caps +
per-syscall allowlist, cap-mask HMAC, code-range hashing, W^X + slot scrub,
heterogeneous syscall numbering, per-slot ASLR, CPI tags, shadow stack + guard
pages, KPTI/SMAP/SMEP/CET scaffolds, measured boot + blob MAC, anomaly + strike
teardown, per-slot key, `mmio_bounds.inc` driver region registry.

NET-NEW for this topology (tracked in the master TODO "Kill-Chain Defense"
section): user-space drivers as sandboxed processes (drivers are in-kernel today),
the safe-proxy reference-monitor layer, the opportunistic hypervisor + IOMMU gate
above the nk-monitor floor, one-shot ephemeral parser workers, the monitor-checked
attested request trail, threshold authority for dangerous runtime ops, and
information-flow labeling.
