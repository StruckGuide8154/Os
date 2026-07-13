# Track 11 — Structural CFI + Memory-Safety-by-Construction (replaces hardware PAC/CET)

**Status:** new, design only (2026-06-23). Depends on the GHL compiler (whole-program
codegen + O3/QUBO) and the `nk_monitor` MMU+WP software floor (Track 5/6).

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

## The four layers (all GHL-emitted, vendor-neutral, monitor-gated)

### L1 — Forward edges: type-signature-indexed call tables  `[ ]`
- Lower every indirect call to `target ∈ table[typeid]` — a 1–3 ALU-op mask/compare,
  fully pipelined, no crypto, no serialization.
- Valid target set = exact type-matched function set (fine-grained): beats PAC
  (no "any pointer signed with this modifier") and CET-IBT (no "any ENDBR").
- Whole-program GHL resolves most indirect calls statically → **emit zero check**;
  only genuinely dynamic dispatch pays the table hit.
- Tasks: `typeid` assignment in the front end; per-type table emission in codegen;
  optimizer pass to elide statically-resolved sites; negative test (forged target
  outside table → trap to monitor).

### L2 — Backward edges: SafeStack (split stack), not a shadow stack  `[ ]`
- Replace the `rsp^0x2000` mirror-and-compare with a *split*: return addresses +
  provably-safe locals on a protected stack with **no computed/attacker-influenceable
  access**; arrays / address-taken locals on a separate unsafe stack.
- Removes the return-address overwrite *primitive* instead of detecting it after the
  fact. Single-digit % overhead; nothing to forge.
- Protected region gated by the existing `nk_pt_window` WP window → deterministic,
  not secrecy-based. (Supersedes the syscall-path shadow stack on the hot path; keep
  shadow stack only where SafeStack can't reach, e.g. cross-ABI trampolines.)
- Tasks: GHL stack-frame splitter (escape analysis for "unsafe" locals); protected
  stack allocation + WP-gating; interaction with existing IST/syscall stacks.

### L3 — Data-only attacks: memory safety by construction in GHL  `[ ]`
The "fewer holes" win — the bug class CFI only mitigates.
- **Spatial:** compiler-inserted bounds, optimizer-elided where provably in-bounds.
  Build on existing bounds-checked state indexing + `buffer NAME[BYTES]`.
- **Temporal (UAF):** ownership / region / lifetime types in GHL — compile-time,
  **zero runtime cost**. This is the language-design lift; biggest item on the track.
- Tasks: spatial-bounds lowering + elision pass; ownership-type front-end (move/borrow
  checking); region-typed allocator binding; migration story for existing `.ghl`.

### L4 — Promote CFI from runtime tag to a checked theorem  `[ ]`
- Reuse the whole-program call graph + QUBO export to have the tiny trusted-root
  verifier *prove* every indirect transfer's target set is sound at build time —
  CFI becomes a build-gate invariant (like the Track-3 invariants), not a per-call
  instruction. Runtime cost → 0 for the statically-resolvable majority.
- Tasks: call-graph soundness extractor; verifier integration into the security gate;
  `eval_cfi.py` exhaustive check + wire into `test_ghl_security_guards.ps1`.

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
  stack + code-pointer pools are writable again. Same caveat as STATUS.md §9 — keep the
  monitor tiny, formally checked, split-authority (Track 5/6).
- **Temporal safety is a real language lift**, not a codegen flag (L3 ownership types).
- **Spatial bounds cost** where the optimizer can't prove in-bounds; depends on O3/regalloc maturity.

## Scope: CODE-NOW vs language-gated
- **CODE-NOW:** L1 (call tables), L2 (SafeStack), L4 (call-graph theorem), L3-spatial.
- **Language-gated (front-end lift):** L3-temporal (ownership/region types).

## Relationship to existing tracks
- Reuses `nk_monitor` WP window (Track 5/6) for L2/L4 enforcement.
- Complements Track 8 (ring-3 drivers): structural CFI inside each compartment.
- Subsumes the syscall-path shadow stack and CPI-callback verification on the hot path
  (keep CPI where dynamic callback identity must be authenticated across the kernel).

## Path to 10/10 (security-first; speed maximized under that)

Self-rating now: **security 8 / speed 9 (target)**. Design-only, but the design
removes the data-only/DOP hole PAC/CET leave and uses no forgeable tags/keys —
capped under 10 only because it rests on the nk-monitor root.

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
