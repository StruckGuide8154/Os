# Track 6 - Compartmentalized "-1" Separation Monitor (least-authority monitor tier)

Goal: implement the monitor of `docs/The final goal after the rest.txt` **not as
one monolithic TCB, but as a set of minimal, mutually-isolated single-purpose
"-1" compartments**, each of which owns exactly ONE authority and nothing else.
The defining property:

> The "-1" compartments are so isolated and protected that one taken over will not
> compromise any other "-1" part.

This is the stratified-enforcer rule of `architecture-defense-in-depth.md` applied
**recursively to the monitor itself**: even the thing that protects ring-0 is
split so no single compromise yields total authority. It is the
software-floor-first realization of the final goal - **everything here is
enforceable without hardware virtualization and verifiable under QEMU-TCG**
(built on paging + `CR0.WP`, the same basis as [[nested_kernel_monitor]]). Track 5
later makes these compartments *un-disableable* and adds device-DMA confinement,
but Track 6 stands on its own.

Maps to `docs/ghl-beyond-zero-trust-todo.md` → "P0: Compromised Kernel And
Hypervisor Containment" + Kill-Chain "split kernel partitions". Depends on Track 2
(verify-before-map-exec) and feeds Track 3 (the isolation invariants become
machine-checkable). Track 5 is the hardware hardening of this tier.

## Honesty rule
Maturity tags: `modeled` → `tested-tcg` (real enforcement here - WP/NX faults DO
fire under TCG, unlike Track 5) → `tested-hw`. The one thing TCG cannot show is
that a same-privilege ring-0 cannot *disable* the floor (that is Track 5 G1); name
that residual, do not hide it.

## Status legend
- [x] done at the stated tag   [~] partial   [ ] not started

---

## The "-1" compartments (each owns ONE authority, nothing else)

| Compartment | Owns (and ONLY this) | Today |
|---|---|---|
| **PT-MON** | page-table permissions / mapping authority (W^X, who-maps-what) | `nk_monitor` (narrow it down to just this) |
| **HASH-MON** | code-hash registry + page measurement | partial (measured boot) |
| **KEY-MON** | signing pubkeys + per-boot HMAC keys - **verify-only oracle, never releases a key** | keys currently kernel-global |
| **CAP-MON** | the capability / handle table | partial (handle table + cap-mask HMAC) |
| **DMA-MON** | DMA-grant policy (software: descriptor validation; Track 5 G2 backs it with the IOMMU) | none |
| **LOAD-MON** | orchestrates verify→hash→map; **holds NO standing authority** - must request each step from the owner above | none |

Design rules for the set:
- **One authority per compartment.** No compartment can perform another's
  privileged action (KEY-MON cannot map a page; PT-MON cannot read a key).
- **No shared writable state.** Compartments never share a writable region.
- **Narrow, validated request channels only.** Cross-compartment calls go through a
  tiny trampoline that transfers a *request*, never authority; the callee
  re-derives authority from its own state, never from the caller (no confused
  deputy).
- **No compartment can map or write another compartment's memory.** This is the
  load-bearing isolation invariant (below).
- **LOAD-MON is authority-less glue:** compromising the orchestrator yields the
  ability to *ask*, not to *do* - each owner still independently checks.

---

## Phase C0 - split today's monolith into compartments (software floor)

- [ ] Define the compartment model in GHL: each compartment = its own code region
      (R+X, hashed), its own data region (R/W, NX), and an entry trampoline; all
      regions live in a page-table sub-tree only that compartment's window can
      write. `modeled`
- [ ] Narrow `nk_monitor` to **PT-MON**: it owns ONLY page-table-permission edits.
      Move every other current responsibility out. Keep the "every PTE writer
      brackets `nk_pt_window`" convention but make the window PT-MON-private. `modeled`
- [ ] Stand up **KEY-MON** as a verify-only oracle: signing/HMAC keys live in
      KEY-MON-private pages, unmapped from the rest of the kernel AND from the
      other compartments; expose `verify(envelope)`/`hmac_check(tag)` that return a
      yes/no and never return key bytes. `modeled` → `tested-tcg`
- [ ] Stand up **HASH-MON**: owns the code-hash registry; only HASH-MON can record
      a measured hash; others query. `modeled`
- [ ] Move the cap/handle table behind **CAP-MON**: mutations only via a CAP-MON
      request that CAP-MON validates (threshold ops gate here). `modeled`
- [ ] Stand up **LOAD-MON**: verify (KEY-MON) → hash (HASH-MON) → map RX / data NX
      (PT-MON), holding no authority of its own. `modeled` → `tested-tcg`

## Phase C1 - enforce mutual isolation (the core invariant)

- [ ] Lay out each compartment's pages so no compartment's page-table window can
      reach another's: per-compartment PTE sub-tree, each marked RO to everyone
      except its owner's window. `modeled`
- [ ] Cross-compartment trampoline: switches the active window, passes a copied
      request struct (no shared buffer), validates the callee's own preconditions,
      transfers no caller authority. `modeled` → `tested-tcg`
- [ ] **Negative test (compromise containment):** simulate a compromised
      compartment (a build flag, like `-ProbeNkPt`) that tries to (a) write another
      compartment's data, (b) read KEY-MON's keys, (c) map a page on PT-MON's
      behalf, (d) record a hash in HASH-MON, (e) widen its own caps via CAP-MON -
      each must `#PF` / be rejected, proving compromise of one ≠ compromise of
      another. `tested-tcg`
- [ ] Serial markers per compartment bring-up + a single "COMP+" all-isolated
      marker; "COMP!" on any isolation failure. `tested-tcg`

## Phase C2 - wire to the rest of the system

- [ ] LOAD-MON becomes the only path that maps executable pages; the legacy
      permissive map path (and the v0 W+X blob hole, see Track 4 follow-up) is
      removed in favor of verify-before-exec through LOAD-MON. `modeled`
- [ ] Boot chain + update path route artifact acceptance through KEY-MON
      (depends on Track 2 reader). `modeled`
- [ ] All DMA descriptor programming routes through DMA-MON (software validation
      now; Track 5 G2 IOMMU later). `modeled`

## Phase C3 - make isolation machine-checkable (feeds Track 3)

- [x] Add invariants to `invariant_check.ghl`:
      `INV-COMPARTMENT-ONE-AUTHORITY` (a compartment's authority bitmask is a
      singleton), `INV-COMPARTMENT-NO-CROSS-MAP` (no compartment holds map
      authority over another's region), `INV-COMPARTMENT-NO-AUTH-LAUNDER`
      (trampoline transfers no caller authority). **LANDED 2026-06-10** - three
      `fn`s in `invariant_check.ghl`, compiles `--target kernel --forbid-asm
      --deny-unsafe`. `proven`
- [x] Positive/negative vectors + exhaustive bounded check over the compartment
      authority space (same vehicle as the existing 12 invariants). **LANDED** -
      `.invariant` + `.vectors` files under `tests/security/invariants/`;
      `eval_invariants.py` exhaustive specs prove all three over their full
      bounded spaces (one-authority 128, no-cross-map 32,768, no-auth-launder
      2,097,152 evaluations; the launder theorem quantifies over every caller
      authority to prove the predicate is constant in it). `tested-tcg`
- [ ] Containment claim table: compartment → exactly the authority it has, and the
      authorities it provably cannot reach.

---

## What Track 6 gives you WITHOUT hardware (and the one residual)

Achieved on the software floor, `tested-tcg`:
- monitor owns page perms / code hashes / keys / cap table - split so no single
  compromise yields all of them
- monitor + each compartment never mapped writable to the kernel or to peers
- verify→hash→map-RX / data-NX; no raw unmapped writes; MMIO outside grant denied
  (existing `mmio_bounds.inc`); callback outside CFG killed (existing CPI)

**The one residual Track 6 cannot close (→ Track 5 G1):** because the compartments
run at the same privilege as the kernel, a compromised ring-0 can attempt to
*disable* the floor (clear `CR0.WP`, etc.). The floor makes this expensive and
detectable; only Track 5's privilege-below-ring-0 interposition makes it
impossible. Device DMA past the MMU is the other residual (→ Track 5 G2). Name
both in STATUS.md §9; claim neither closed without the hardware tier.

## Done definition for Track 6

- [ ] The monitor is decomposed into the single-authority compartments above; each
      owns exactly one authority (proven by C3 invariant).
- [ ] Compromise of any one compartment provably cannot read/write/act-for any
      other (C1 negative tests green at `tested-tcg`).
- [ ] LOAD-MON is the only executable-map path; verify→hash→map enforced.
- [ ] The two un-closeable-in-software residuals (floor-disable, device DMA) are
      documented and handed to Track 5; nothing overclaims.

## Path to 10/10 (security-first; speed maximized under that)

Self-rating now: **security 6 / speed 6**. The C3 isolation invariants are proven,
but the compartments (PT/KEY/HASH/CAP/DMA/LOAD-MON) are still design-only — the
realizable software floor is not yet built.

- [ ] **(sec→10)** Land Phase C0+C1: the six single-authority compartments as real
      isolated PTE sub-trees with per-compartment WP windows, plus the C1 negative
      test (a compromised compartment cannot read KEY-MON / map on PT-MON's behalf /
      widen caps) green at `tested-tcg`.
- [ ] **(sec→10)** LOAD-MON becomes the ONLY executable-map path (Phase C2), closing
      the legacy permissive map + v0 W+X hole.
- [ ] **(sec→10)** Containment claim table (C3) maps each compartment to exactly its
      authority and what it provably cannot reach.
- [ ] **Verify:** an independent agent re-rates this track **security 10**.
- **Honest cap:** the floor-disable residual is un-closeable in software — Track 6's
      10 is "10 against compartment-cross-compromise"; full un-disableability needs
      Track 5 G1. Speed: WP-window bracketing is cheap; batch cross-compartment
      requests + O3-hoist the window. Realistic ceiling **sec 10 (with Track 5) / speed 8**.
