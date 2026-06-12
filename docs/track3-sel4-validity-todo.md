# Track 3 - seL4 Validity Track (machine-checkable invariants)

Goal: produce evidence of the *kind* that makes seL4 credible - explicit,
mechanically-checkable invariants over the authority graph - adapted honestly to
this project. This is the only track that lets Grit make a defensible
"≥ seL4 on the properties we chose" claim instead of marketing.

**Honesty rule (non-negotiable):** seL4 has a machine-checked *proof* from C code
to abstract spec. This track does NOT yet. Every invariant carries a `status`:
`modeled` (predicate exists, fails closed) → `tested` (positive + negative test
vectors) → `proven` (machine-checked against the implementation). We never label
something `proven` we have not proven, and we never claim full security after
*arbitrary total hardware* compromise. Each invariant names the compromised
component and the authority it does not have.

Maps to `docs/ghl-beyond-zero-trust-todo.md` → "P2: seL4 Validity Track" and
"P0: Compromised Kernel And Hypervisor Containment".

## Status legend
- [x] done and verified green
- [~] partial / landed but incomplete
- [ ] not started

## Landed in this increment

- [x] Authority-graph invariant kernel `src/tools/security/invariant_check.ghl`
      (bitmask authority model; primitives: subset / lacks-authority /
      requires-threshold / same-domain / flag-absent; named containment
      invariants for scheduler, IPC, driver-DMA, page-table persistence, policy
      loader, hypervisor measurement, release observation). Compiles
      `--forbid-asm --deny-unsafe`.
- [x] 12 machine-checkable invariant files under `tests/security/invariants/`,
      each binding a compromised component + denied authority to a predicate
      and marked `proven` after exhaustive bounded checking.
- [x] Runner `scripts/test/test_ghl_invariants.ps1`: validates files, asserts
      every referenced predicate is exported by the kernel, compiles the kernel,
      and now EVALUATES positive/negative vectors against the real predicate
      source (via `scripts/test/eval_invariants.py`, which parses
      `invariant_check.ghl` with the production compiler's own lexer/parser and
      interprets each predicate as a pure integer fn - no re-implementation).
- [x] Exhaustive bounded checker for the current 12 invariants: `eval_invariants.py
      --exhaustive` enumerates the full 7-bit authority/domain space (0..127)
      plus boolean side conditions for each theorem and compares the real
      predicate result to the theorem table before the runner passes.
- [x] Wired into the verification entry point.

## P2 - define the property set precisely (status: all 12 `proven`)

- [x] capability derivation invariant (no amplification)        - INV-CAP-DERIVATION
- [x] authority confinement (no single-domain global mint)      - INV-NO-GLOBAL-MINT
- [x] scheduler non-authority over memory                       - INV-SCHED-NO-MEMORY
- [x] IPC authorization / no identity forgery                   - INV-IPC-NO-FORGE
- [x] device isolation / no self-minted DMA                     - INV-DRIVER-NO-DMA-MINT
- [x] memory authority / no persistence without threshold       - INV-PT-NO-PERSIST
- [x] policy install requires signature                         - INV-POLICY-SIGNED-ONLY
- [x] hypervisor measures only its own domain                   - INV-HV-NO-FOREIGN-MEASURE
- [x] privacy non-observation in release                        - INV-RELEASE-NO-OBSERVE
- [x] recovery non-bypass invariant (recovery cannot be used to skip measurement)
      - INV-RECOVERY-NO-BYPASS (2026-06-10): proceed requires measured_hash ==
      expected_hash; recovery_mode is quantified over both values in the
      exhaustive check and proven irrelevant (65,536 cases).
- [x] confused-deputy IPC invariant (no authority laundering through a peer)
      - INV-IPC-NO-CONFUSED-DEPUTY (2026-06-10): op authority must be a subset
      of requester ∩ deputy; full 128^3 space proven (2,097,152 cases).
- [x] memory isolation between apps (no cross-namespace read without shared handle)
      - INV-APP-MEM-ISOLATION (2026-06-10): granted cross-namespace access
      without a shared handle is the violation; 65,536 cases proven.

## P2 - promote `modeled` → `tested`

For EVERY invariant add positive + negative test vectors that call the predicate:

- [x] Build a tiny GHL test harness (or host harness) that invokes each predicate
      with a passing input (returns 1) and a violating input (returns 0).
      Done as a host harness (`scripts/test/eval_invariants.py`) that interprets
      the real GHL predicate source - see note below.
- [x] INV-CAP-DERIVATION: child⊆parent passes; child with an extra bit fails.
- [x] INV-NO-GLOBAL-MINT: AUTH_GLOBAL with threshold passes; without fails.
- [x] INV-SCHED-NO-MEMORY: scheduler without AUTH_MEMORY_GRANT passes; with fails.
- [x] INV-IPC-NO-FORGE: ipc without AUTH_MINT_IDENTITY passes; with fails.
- [x] INV-DRIVER-NO-DMA-MINT: DMA bit + grant passes; DMA bit no grant fails.
- [x] INV-PT-NO-PERSIST: persist + threshold passes; persist no threshold fails.
- [x] INV-POLICY-SIGNED-ONLY: signed passes; unsigned fails.
- [x] INV-HV-NO-FOREIGN-MEASURE: same-domain measure passes; foreign fails.
- [x] INV-RELEASE-NO-OBSERVE: telemetry=0 passes; telemetry=1 fails.
- [x] Add the negative vectors as `.invariant` companions or a vector file the
      runner executes (extend runner to actually evaluate, not just type-check).
      Done as a vector file per invariant under
      `tests/security/invariants/vectors/*.vectors` (declarative `case = accept|
      reject | <args>` lines). The runner cross-checks every invariant has a
      vector file whose id+predicate agree with its `.invariant`, then runs
      `eval_invariants.py` which EXECUTES the real predicate against each vector
      and asserts accept→1 / reject→0. A deliberately-flipped negative vector
      makes the runner fail (verified). All 9 `.invariant` files are now `proven`
      after the bounded exhaustive checker runs.

## P2 - map the model onto the real system (the hard part)

DONE (2026-06-10): `scripts/test/derive_authority.py` (run by the Track-3
runner inside `test_ghl_security_guards.ps1`) GENERATES the authority bitmasks
from the four real policy sources and re-proves the invariants against them
(~194 checks, fail-closed; detection meta-tested with a planted PTE-writer
violation). Full mapping + derivation record: `docs/track3-invariant-proofs.md`.

- [x] Map the bitmask authority model onto the actual capability/policy schema:
      per-domain obtainable authority is enumerated through the REAL
      `security_policy_graph_edge_is_valid` / `requires_threshold` predicates
      (interpreted from production GHL source) over all (src, dst, cap,
      threshold). New domains added later (e.g. Trust Partitioning) are picked
      up automatically - the derivation enumerates the module's constants.
- [x] Map compiler unsafe capabilities to authority-graph edges: each module in
      the signed `$KernelModules` build list is scanned for `unsafe <cap>;`
      declarations (compiler-enforced via `_require_cap`) and `nk_pt_window`
      bracketing; kernel_io → AUTH_DMA_MAP, PTE-writer → AUTH_MEMORY_GRANT.
      Named bindings (scheduler = frame_pacing+cpu_acct, ipc/dispatch =
      input_dispatch+net_dhcp_dispatch) derive mask 0x00 and satisfy their
      invariants; the policy modules themselves hold zero capabilities.
- [x] Map signed artifacts to TCB changes: artifact class → TCB authority
      (BOOT/KERNEL/HYPERVISOR/UPDATE/RECOVERY → AUTH_GLOBAL, POLICY/CONFIG →
      AUTH_INSTALL_POLICY, DRIVER → AUTH_DMA_MAP, APP → derived app max),
      checked against the real `security_threshold_class_min_count` /
      `class_quorum_ok` tables: every TCB-expanding class needs ≥2 (global
      classes ≥3) signatures; single-key expansion rejected by the predicates.
- [x] Generate the domain authority bitmasks from the signed capability policy
      rather than hand-asserting them: app masks derive from the real
      `MANIFEST_*` table in `syscall_caps.inc` (inside the KERNEL.ENV-signed
      image); all 10 manifests lack all six non-app authorities, max app
      authority is AUTH_PERSIST, within the derived DOMAIN_APP bound.

## P2 - promote `tested` → `proven` (long horizon, do not overclaim)

- [x] Decide the proof vehicle (exhaustive enumeration over the bounded bitmask
      space is tractable: 7 authority bits ⇒ 128 domain states - small enough to
      check ALL states per invariant by brute force).
- [x] Add an exhaustive checker that proves each invariant holds over the full
      bounded state space (this is a real, if modest, machine-checked result).
- [x] Write proof-oriented docs per P0 invariant stating the theorem, the bound,
      and the checked state count. DONE (2026-06-10):
      `docs/track3-invariant-proofs.md` §1 - all 12 theorems with exact bounds;
      2,278,404 predicate evaluations total, zero mismatches.
- [x] Keep a precise containment claim table: component → authority it cannot
      obtain, with the invariant id and proof status. DONE (2026-06-10):
      `docs/track3-invariant-proofs.md` §3, including the real-config binding
      column (which derivation source backs each claim).

## Done definition for Track 3 - COMPLETE 2026-06-10

- [x] Every chosen property has a `modeled` predicate, `tested` vectors, and a
      `proven` exhaustive check over the bounded authority space.
      (12 invariants; vectors + exhaustive checks run by
      `test_ghl_invariants.ps1` inside the guards entry point.)
- [x] The authority bitmasks are derived from real signed policy, not hand-set.
      (`scripts/test/derive_authority.py`; sources: signed app manifests,
      policy graph, compiler unsafe caps over the signed build list,
      artifact-class quorum tables.)
- [x] A containment claim table maps each single-component compromise to the
      authority it provably cannot gain. (`docs/track3-invariant-proofs.md` §3.)
- [x] No claim exceeds what is checked; hardware-total-compromise is explicitly
      out of scope. (Honesty statement at the top of the proofs doc: these are
      exhaustive bounded checks + mechanical policy derivation, NOT a
      code-to-spec refinement proof; below-ring-0 / DMA / physical RAM capture
      belong to Tracks 4/5.)

Track 3 is CLOSED. Future work that touches it (new invariants, Trust
Partitioning domains, new compiler capabilities) follows the maintenance
section of `docs/track3-invariant-proofs.md` - it extends the track without
reopening it.
