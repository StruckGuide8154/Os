# Track 11 — Structural CFI + Memory-Safety-by-Construction (replaces hardware PAC/CET)

**Status:** design **complete** (2026-07-20; sketch was 2026-06-23). Implementation
**not started**. Depends on the GHL compiler (whole-program codegen + O3/QUBO regalloc)
and the `nk_monitor` MMU+`CR0.WP` software floor (Track 5/6). This doc is now the
authoritative design for the track — enough to start L1/L2/L4 (CODE-NOW) without
further design, with L3-temporal called out as the one front-end language lift.

## Honesty rule
Maturity tags mirror Track 6: `modeled` → `tested-tcg` (real enforcement — a forged
forward edge / overwritten return address / OOB store DOES trap under QEMU-TCG,
because the enforcement is paging + `CR0.WP` + emitted compares, not silicon) →
`tested-hw`. Two residuals are **un-closeable in this track** and must never be
claimed closed here: (a) the whole scheme rests on the `nk_monitor` WP root — a
subverted monitor makes the protected stack and code-pointer pools writable again
(→ Track 5 G1 for un-disableability); (b) same-privilege ring-0 can still attempt to
clear `CR0.WP` before Track 5. Name both; hide neither. Self-ratings here are
provisional until an independent audit agent re-rates (see Path to 10/10).

## Status legend
- [x] done at the stated tag   [~] partial   [ ] not started

---

## Thesis

PAC (ARM) and CET (Intel/AMD) are *detection-after-write* mitigations: they assume the
attacker already holds a memory-write primitive and try to catch the corrupted pointer
at use. That model has three intrinsic holes Grit must not inherit:

1. **Vendor lock.** PAC = ARMv8.3+; CET = recent x86. Neither is portable; both are
   no-ops under TCG (see TODO-INDEX gotcha). Grit already rejected CET for `nk_monitor`.
2. **Tag/oracle holes.** PAC: sign/auth-gadget reuse, sign oracles, bounded entropy,
   same-context substitution. CET-IBT: any `ENDBR` is a valid forward target (coarse).
3. **Zero coverage of data-only / DOP attacks** — the class neither PAC nor CET touch.

A single kernel R/W disables the whole hardware-tag scheme at once.

Grit's leverage: **we own the compiler (GHL emits all code, zero-asm) and an always-on
portable software monitor.** So we make corruption *inexpressible by construction*,
checked at build time + by the WP monitor, instead of renting detection from silicon.

## What already exists to build on (grounding)
The track is not greenfield; three of the four layers extend primitives already in
the tree:
- **L1** extends `table NAME { fn0, fn1, ... }` + `call_table(NAME, idx)` in
  `src/user/grithl/compiler/gritc.py` (~line 351) — today a *bounds-checked* indirect
  call into a controlled set (the safe replacement for `jmp [reg+off]`). L1 makes the
  set **type-indexed**, not just bounds-checked.
- **L3-spatial** extends the `buffer NAME[BYTES]` / `reserve NAME[BYTES]` arenas and
  the shared out-of-bounds trap stub (`need_oob`, gritc.py ~line 690/3049), which
  already ride the `state` bounds machinery so every index is checked or the store
  halts at the faulting site.
- **L2/L4** reuse the `nk_pt_window` WP bracket (`src/kernel/core/nk_monitor.asm`,
  [[nested_kernel_monitor]]) and supersede the syscall-path shadow stack
  ([[shadow_stack_syscall_path]]) + CPI callback-verify-at-dispatch
  ([[feedback_cpi_callback_verify_at_dispatch]]) on the hot path.
- **L4** reuses the exact Track-3 vehicle: `inv_*` predicates in
  `src/tools/security/invariant_check.ghl`, declarative `tests/security/invariants/*.invariant`
  + `.vectors`, exhaustively proven by `scripts/test/eval_invariants.py --exhaustive`,
  wired into `scripts/test/test_ghl_security_guards.ps1`.

---

## The four layers (all GHL-emitted, vendor-neutral, monitor-gated)

### L1 — Forward edges: type-signature-indexed call tables

Lower every indirect call to `target ∈ table[typeid]` — a 1–3 ALU-op mask/compare,
fully pipelined, no crypto, no serialization. Valid target set = exact type-matched
function set (fine-grained): beats PAC (no "any pointer signed with this modifier")
and CET-IBT (no "any ENDBR"). Whole-program GHL resolves most indirect calls
statically → **emit zero check**; only genuinely dynamic dispatch pays the table hit.

**Phase L1a — front-end typeid**  `[ ]`
- [ ] Assign a `typeid` to every function *signature* (param/return register
      contract + effect class from the existing effects analysis, gritc.py ~2378
      `indirect_call`) in the front end; two functions share a `typeid` iff a
      call site of that signature could legally target either. `modeled`
- [ ] Record, per `typeid`, the exact target set from the whole-program pass; this is
      the fine-grained forward-edge set. `modeled`

**Phase L1b — codegen per-type tables**  `[ ]`
- [ ] Generalize `table`/`call_table` so a table is *keyed by typeid* and
      `call_table` lowers an indirect call as: resolve index → bounds/identity-check
      against `table[typeid]` → call. Reuse the existing OOB trap target for the
      reject path (trap to monitor, halt at faulting site). `modeled` → `tested-tcg`
- [ ] Emit the tables into an **RO, monitor-owned** region (same WP discipline as
      code-pointer pools, L2) so the table itself is not an overwrite target. `modeled`

**Phase L1c — elision + negative test**  `[ ]`
- [ ] Optimizer pass: any indirect call the whole-program graph resolves to a single
      target becomes a direct call — **emit zero check** (this is where "mostly
      elided" is earned; ties into the existing `_O2_INDIRECT_RE` bail so O2/O3 no
      longer has to give up at the indirect site once it is proven single-target).
      `modeled`
- [ ] **Negative test** `cfi_forward_forged.ghl`: a forged target outside `table[typeid]`
      (wrong-signature function, mid-function address, data address) → trap; a
      correct in-set target → pass. Serial marker `CFI1+` / `CFI1!`. `tested-tcg`

### L2 — Backward edges: SafeStack (split stack), not a shadow stack

Replace the `rsp^0x2000` mirror-and-compare with a *split*: return addresses +
provably-safe locals on a protected stack with **no computed/attacker-influenceable
access**; arrays / address-taken locals on a separate unsafe stack. Removes the
return-address overwrite *primitive* instead of detecting it after the fact.
Single-digit % overhead; nothing to forge.

**Phase L2a — frame splitter**  `[ ]`
- [ ] Escape analysis in codegen: classify each local as *safe* (never
      address-taken, never indexed, fixed size) → protected stack, or *unsafe*
      (address-taken / array / `buffer`-backed) → unsafe stack. Reuse the
      address-taken / `bounds_checked_slice` signals already tracked (gritc.py ~2400).
      `modeled`
- [ ] Emit two stack pointers: protected `rsp` (return addresses + safe locals) and an
      unsafe-stack pointer for the rest; no instruction computes an address into the
      protected stack from attacker-influenceable data. `modeled` → `tested-tcg`

**Phase L2b — WP-gate the protected stack**  `[ ]`
- [ ] Allocate the protected stack in a page sub-tree writable **only** inside the
      PT-MON `nk_pt_window` (Track 6 PT-MON); ordinary code writes it via the
      push/ret path but cannot *remap* it writable-from-elsewhere. Deterministic,
      not secrecy-based (unlike the old shadow-stack XOR mirror). `modeled` → `tested-tcg`
- [ ] Interaction with existing IST / syscall kernel-stack-first entry
      ([[syscall_entry_kernel_stack_first]]) and per-slot stacks: the protected
      stack composes with, does not replace, the IST switch. `modeled`

**Phase L2c — supersede shadow stack on the hot path**  `[ ]`
- [ ] On the SafeStack-covered hot path, drop the syscall-path shadow-stack
      mirror-and-compare; **keep** the shadow stack only where SafeStack can't reach
      (cross-ABI trampolines, asm-escape islands, boot). `modeled`
- [ ] **Negative test** `cfi_backward_overwrite.ghl`: an attempted store to a return
      slot on the protected stack from an unsafe-stack overflow → `#PF` (not a
      post-hoc mismatch); a normal call/return → pass. Marker `CFI2+` / `CFI2!`.
      `tested-tcg`

### L3 — Data-only attacks: memory safety by construction in GHL
The "fewer holes" win — the bug class CFI only mitigates. Split into a CODE-NOW
spatial half and a language-gated temporal half.

**Phase L3-spatial — bounds by construction (CODE-NOW)**  `[ ]`
- [ ] Extend the existing `buffer`/`state`/`reserve` bounds machinery so **every**
      pointer-derived access (not only declared arenas) carries a compile-time or
      cheap-runtime bound; lower to the shared OOB trap on violation. `modeled` → `tested-tcg`
- [ ] Optimizer elision pass: drop the bound where the index is provably in range
      (loop-invariant / const-folded / range-narrowed). Depends on O3/regalloc
      maturity ([[compiler_optimizer_baseline_and_gap]]) — publish the % of checks
      elided as the cost gate. `modeled`
- [ ] **Negative test** `mem_spatial_oob.ghl`: an over-/under-index into a `buffer`
      and into a general pointer access both trap; the in-bounds path elides. `tested-tcg`

**Phase L3-temporal — ownership / region / lifetime types (LANGUAGE-GATED)**  `[ ]`
This is the biggest single item on the track and the one genuine language lift.
- [ ] Front-end ownership types: move/borrow checking so a use-after-free /
      double-free is a **compile error**, zero runtime cost. `modeled`
- [ ] Region-typed allocator binding: allocations carry a region; a reference cannot
      outlive its region (checked, not runtime-tagged). `modeled`
- [ ] Migration story for existing `.ghl` (the whole tree must still compile):
      staged opt-in — new modules `--deny-unsafe`-strict; existing modules grandfathered
      behind an escape until ported, tracked like the zero-asm inventory. `modeled`
- [ ] **Negative test** `mem_temporal_uaf.ghl`: a use-after-free / escaping-borrow
      program is *rejected by the compiler* (build fails), proving temporal safety is
      structural, not runtime. `tested-tcg` (build-time)

### L4 — Promote CFI from runtime tag to a checked theorem
Reuse the whole-program call graph + QUBO export to have the tiny trusted-root
verifier *prove* every indirect transfer's target set is sound at build time — CFI
becomes a build-gate invariant (like the Track-3 invariants), not a per-call
instruction. Runtime cost → 0 for the statically-resolvable majority.

**Phase L4a — soundness extractor**  `[ ]`
- [ ] Call-graph soundness extractor: from the whole-program graph, emit for each
      indirect site its computed target set and the typeid it was lowered against;
      the theorem is *every reachable indirect target ∈ its L1 table set*. `modeled`

**Phase L4b — invariants + exhaustive eval (mirror Track 3)**  `[x]` **LANDED 2026-07-20** `proven`
- [x] Added predicates to `src/tools/security/invariant_check.ghl`
      (compiles `--forbid-asm --deny-unsafe`):
      - `inv_cfi_forward_target_in_set` → **INV-CFI-FORWARD-TARGET-IN-SET**: an indirect
        target is admitted iff its typeid matches the call site AND it is a member of
        that type's table (forged/off-set target → predicate 0).
      - `inv_cfi_no_offset_entry` → **INV-CFI-NO-MIDFUNCTION-ENTRY**: a forward target
        equals a function entry (offset 0), never a mid-function offset.
      - `inv_safestack_return_unwritable` → **INV-SAFESTACK-RETURN-NO-FOREIGN-WRITE**:
        a return-slot write is admitted only from the canonical push/ret writer;
        constant in the foreign writer identity (à la the no-auth-launder theorem).
- [x] Declarative `tests/security/invariants/{cfi_forward_target_in_set,
      cfi_no_midfunction_entry,safestack_return_unwritable}.invariant` + matching
      `vectors/*.vectors` (positive + negative), plus exhaustive theorem specs in
      `scripts/test/eval_invariants.py` over the bounded typeid×target (128), offset
      (64), and writer×writer×slot (128) spaces. All three prove green; the runner
      now reports **24 invariants** exhaustively checked.
- [x] Wired via the existing `test_ghl_invariants.ps1` (itself inside
      `test_ghl_security_guards.ps1`), so a model/spec edit that would admit an
      off-set forward transfer, a mid-function entry, or a foreign return-slot write
      **fails the security gate**. `tested-tcg` (the *model*; runtime L1/L2 emission
      is still L1b/L2b, below).
- **Honest scope:** this lands the L4 *checked-theorem model* only — it bounds what a
  sound emitter may admit. It does NOT emit L1 tables or L2 SafeStack yet (those are
  L1b/L2a-b, still `[ ]`), exactly as Track 6 C3 invariants landed `proven` while
  C0/C1 compartments stayed design-only.

---

## Cross-layer invariants (feed Track 3)
| INV name | Predicate | Meaning |
|---|---|---|
| INV-CFI-FORWARD-TARGET-IN-SET | `inv_cfi_forward_target_in_set` | every indirect call target ∈ its typeid table |
| INV-CFI-NO-MIDFUNCTION-ENTRY | `inv_cfi_no_offset_entry` | forward targets are entries, never offsets |
| INV-SAFESTACK-RETURN-NO-FOREIGN-WRITE | `inv_safestack_return_unwritable` | only push/ret writes the protected stack |
| INV-MEM-SPATIAL-IN-BOUNDS | (codegen-checked, L3a) | no access outside its object's bound |
| INV-MEM-TEMPORAL-NO-UAF | (build-time reject, L3b) | no reference outlives its region |

The first three are runtime/graph predicates provable on the Track-3 vehicle; the
last two are compiler-enforced (spatial = emitted check/elision; temporal = rejected
at build). Keep that distinction honest in any status claim.

## Comparison (why this is stronger AND faster)

| Axis | PAC | CET | Track 11 |
|---|---|---|---|
| Forward edge | modifier-scoped | any `ENDBR` (coarse) | exact type-matched set |
| Backward edge | sign+auth crypto | shadow stack + #CP | SafeStack (no detect, no forge) |
| Data-only / DOP | none | none | L3 memory safety |
| Hot-path cost | sign+auth per call/ret | µarch + exceptions | 1–3 ALU ops; mostly elided |
| Vendor | ARMv8.3+ | recent x86 | portable (GHL + WP monitor) |
| Forgeable tag/key | yes | n/a | none (no tags/keys) |

## Honest holes (irreducible)
- **Monitor is the root.** If the WP window / `nk_monitor` is subverted, the protected
  stack + code-pointer pools + L1 tables are writable again. Same caveat as STATUS.md
  §9 — keep the monitor tiny, formally checked, split-authority (Track 5/6). This
  track cannot exceed the monitor's own security (capped under 10 until Track 5 G1).
- **Temporal safety is a real language lift**, not a codegen flag (L3 ownership types) —
  the migration of the existing `.ghl` tree is the schedule risk, not the theory.
- **Spatial bounds cost** where the optimizer can't prove in-bounds; the honesty gate
  is the published elision % against O3/regalloc maturity.
- **Escape islands.** `asm { }` escapes and cross-ABI trampolines fall outside
  SafeStack/L1; they retain the shadow stack + CPI verify. As zero-asm completes these
  shrink; until then they are named residuals, not covered surface.

## Scope: CODE-NOW vs language-gated
- **CODE-NOW** (buildable against today's compiler + monitor): L1 (type-indexed call
  tables), L2 (SafeStack), L3-spatial (bounds+elision), L4 (call-graph theorem +
  invariants).
- **Language-gated** (front-end lift): L3-temporal (ownership/region/lifetime types).

## Relationship to existing tracks
- Reuses `nk_monitor` WP window (Track 5/6) for L1-table / L2-stack / L4 enforcement.
- Complements Track 8 (ring-3 drivers): structural CFI applies *inside* each broker
  compartment, so a driver compromise is bounded both by the ring-3 sandbox and by
  intra-compartment CFI/memory-safety.
- Subsumes the syscall-path shadow stack and CPI-callback verification **on the hot
  path** (keep CPI where dynamic callback identity must be authenticated across the
  kernel, and shadow stack in escape islands / boot).
- Feeds Track 3: the L4 predicates become machine-checkable invariants in the same
  runner.

## Suggested landing order (dependency-first)
1. **L1a+L1b** (typeid + type-indexed tables) — smallest, unblocks L4a.
2. **L4a+L4b** (theorem + invariants) — turns L1 into a build-gate; cheap once L1 lands.
3. **L1c** elision — recovers the speed the whole-program graph promises.
4. **L2** SafeStack — independent of L1; land after so the WP discipline is shared.
5. **L3-spatial** — extends existing bounds machinery; gated on O3 elision quality.
6. **L3-temporal** — the language lift; last, largest, migration-staged.

## Done definition for Track 11
- [ ] L1 type-indexed tables enforce the exact forward-edge set; forged target traps
      (`cfi_forward_forged` green at `tested-tcg`); statically-resolved sites emit
      zero check.
- [ ] L2 SafeStack removes the return-overwrite primitive, WP-gated via `nk_pt_window`;
      `cfi_backward_overwrite` `#PF`s at `tested-tcg`; shadow stack retained only in
      named escape islands.
- [ ] L3-spatial bounds enforced/elided with a published elision %; L3-temporal
      ownership types reject a UAF program at build time.
- [ ] L4 predicates (`inv_cfi_*`, `inv_safestack_*`) proven exhaustively and wired into
      `test_ghl_security_guards.ps1`; a call-graph edit admitting an off-set transfer
      fails the gate.
- [ ] The two un-closeable residuals (monitor-root subversion, same-privilege WP
      disable) are documented and handed to Track 5; escape islands named; nothing
      overclaims.

## Path to 10/10 (security-first; speed maximized under that)

Self-rating now: **security 8 / speed 9 (target)**. Design complete, implementation
not started. The design removes the data-only/DOP hole PAC/CET leave and uses no
forgeable tags/keys — capped under 10 only because it rests on the nk-monitor root.

- [ ] **(sec→10)** Land L1 type-signature call tables + L4 call-graph theorem so
      every indirect transfer's target set is sound (build-gate, like Track 3).
- [ ] **(sec→10)** Land L2 SafeStack (removes the return-address overwrite primitive)
      WP-gated via `nk_pt_window`.
- [ ] **(sec→10)** Land L3: spatial bounds (optimizer-elided) + temporal
      ownership/region types — the language lift that eliminates UAF/data-only,
      the bug class CFI only mitigates.
- [ ] **Verify:** an independent agent re-rates this track **security 10 (with
      Track 5/6 monitor)**, bounded by the shared nk-monitor-root caveat.
- **(speed→max under sec 10)** 1–3 ALU-op table checks, whole-program elision of
      statically-resolved calls, SafeStack off the hot path, zero-runtime ownership
      types. This track *improves* speed vs PAC/CET. Target speed **9**.
