# Track 3 - Invariant Proofs & Containment Claims

Proof-oriented record for the seL4 validity track: one theorem per invariant
with its exact bound and checked state count, the policy→authority derivation
that binds the model to the *real* system configuration, and the containment
claim table. Companion to `docs/track3-sel4-validity-todo.md`.

**Honesty statement (read first).** These are *exhaustive bounded checks* of
GHL predicates over a finite authority model, plus a mechanical derivation of
the model's inputs from the real signed policy, plus a mechanical
*translation-validation* of the authority constants against the gritc-emitted
artifact (§4). They are real machine-checked results, but they are NOT a
seL4-style refinement proof from implementation code to abstract spec: nothing
here proves the kernel's machine code refines the *control flow* of these
predicates. The translation-validation step is narrower than a refinement
proof - it binds the proven authority *constants* to the immediates the
production compiler actually emits, closing the constant-level model↔code gap;
it does not prove the surrounding logic. The predicates are, moreover, the same
source the enforcement call sites compile (`--forbid-asm --deny-unsafe`),
evaluated through the production compiler's own parser - there is no second
implementation to drift. Total hardware compromise (below-ring-0, DMA from
outside the IOMMU scope, physical RAM capture) is explicitly out of scope here;
see Track 4/5.

Verification entry points (both run inside `test_ghl_security_guards.ps1`):

```
scripts\test\test_ghl_invariants.ps1          # full Track-3 runner
python scripts\test\eval_invariants.py --exhaustive               # bounded proofs only
python scripts\test\eval_invariants.py --translation-validation   # model<->emitted-code constants (§4)
python scripts\test\derive_authority.py       # policy-derived mapping checks
scripts\test\test_invariant_meta.ps1          # meta-tests: planted drift must be caught
```

---

## 1. Theorems (exhaustive bounded checks)

Authority space `A` = all masks `0 .. 2**w - 1` where the bit-width `w` is
DERIVED at runtime from the `AUTH_*` constants in
`src/tools/security/invariant_check.ghl` (currently AUTH_MEMORY_GRANT=1,
AUTH_MINT_IDENTITY=2, AUTH_DMA_MAP=4, AUTH_PERSIST=8, AUTH_SIGN_MEASUREMENT=16,
AUTH_INSTALL_POLICY=32, AUTH_GLOBAL=64 ⇒ `w = 7`, `A = 0..127`). The width is
`1 + position of the highest AUTH_* bit`, so adding a new authority bit (e.g.
`const AUTH_NEW = 128;`) automatically widens `A` to 8 bits and every theorem
re-proves over the larger space - the proof can never silently fall behind the
policy (see §4). `B` = {0,1}. Every theorem below is checked for EVERY point of
its bound by `eval_invariants.py --exhaustive`, comparing the real interpreted
predicate against the stated truth table; one mismatch fails the suite. Checked
counts are emitted by the run itself (the counts below are for `w = 7`).

| Invariant | Theorem (∀ over the bound) | Predicate | Bound | States checked | Status |
|---|---|---|---|---|---|
| INV-CAP-DERIVATION | child ⊆ parent accepted iff `(child & parent) == child` - derivation never amplifies authority | `inv_subset` | A × A | 16,384 | proven |
| INV-NO-GLOBAL-MINT | a domain holding AUTH_GLOBAL is accepted only with threshold approval | `inv_requires_threshold` | A × {G} × B | 256 | proven |
| INV-SCHED-NO-MEMORY | accepted iff the scheduler mask lacks AUTH_MEMORY_GRANT | `inv_scheduler_no_memory_grant` | A | 128 | proven |
| INV-IPC-NO-FORGE | accepted iff the IPC mask lacks AUTH_MINT_IDENTITY | `inv_ipc_no_identity_forge` | A | 128 | proven |
| INV-DRIVER-NO-DMA-MINT | AUTH_DMA_MAP accepted only with an external grant present | `inv_driver_no_dma_mint` | A × B | 256 | proven |
| INV-PT-NO-PERSIST | AUTH_PERSIST accepted only with threshold approval | `inv_pt_no_persist_without_threshold` | A × B | 256 | proven |
| INV-POLICY-SIGNED-ONLY | unsigned policy install always rejected | `inv_policy_loader_signed_only` | B | 2 | proven |
| INV-HV-NO-FOREIGN-MEASURE | a measurement-signing domain is accepted only measuring itself | `inv_hypervisor_no_foreign_measurement` | A × A × B | 32,768 | proven |
| INV-RELEASE-NO-OBSERVE | any telemetry flag rejected in release | `inv_release_no_observation` | B | 2 | proven |
| INV-RECOVERY-NO-BYPASS | proceeding requires measured == expected; the result is CONSTANT in recovery_mode (recovery grants no exemption) | `inv_recovery_no_measure_bypass` | B × A × A × B | 65,536 | proven |
| INV-IPC-NO-CONFUSED-DEPUTY | an op through a deputy accepted iff op ⊆ requester ∩ deputy (no authority laundering either direction) | `inv_ipc_no_deputy_laundering` | A × A × A | 2,097,152 | proven |
| INV-APP-MEM-ISOLATION | granted cross-namespace access without a shared handle is always rejected | `inv_app_mem_isolation` | A × A × B × B | 65,536 | proven |
| INV-COMPARTMENT-ONE-AUTHORITY | a compartment authority mask is accepted iff it is a singleton (non-zero power of two) | `inv_compartment_one_authority` | A | 128 | proven |
| INV-COMPARTMENT-NO-CROSS-MAP | a present map authority accepted only over the holder's own region | `inv_compartment_no_cross_map` | A × A × B | 32,768 | proven |
| INV-COMPARTMENT-NO-AUTH-LAUNDER | effective authority must equal the callee's; CONSTANT in caller_auth (trampoline launders nothing) | `inv_compartment_no_auth_launder` | A × A × A | 2,097,152 | proven |
| INV-EPHEMERAL-NO-REPLAY | a per-boot secret authenticates only against its own boot epoch | `inv_ephemeral_no_replay` | A × A × B | 32,768 | proven |
| INV-PER-SLOT-KEY-CONFINED | a per-slot key authenticates only for its own slot | `inv_per_slot_key_confined` | A × A × B | 32,768 | proven |
| INV-SYSCALL-PERM-PER-LAUNCH | a static syscall blob dispatches only under its own launch permutation | `inv_syscall_perm_per_launch` | A × A × B | 32,768 | proven |
| INV-PLANTED-CAP-HMAC-REJECTED | a 128-bit cap-mask MAC recovered from one boot is accepted on a fresh boot only if both 64-bit lanes re-derive under the live canary | `inv_planted_cap_hmac_rejected` | C × C × S × M × P × B | 648 | proven |
| INV-NO-ROLLBACK | an admitted artifact must have version >= the persisted floor | `inv_no_rollback` | A × A × B | 32,768 | proven |
| INV-FLOOR-RATCHET-MONOTONIC | the persisted floor only ratchets forward (new >= old) | `inv_floor_ratchet_monotonic` | A × A | 16,384 | proven |
| INV-CFI-FORWARD-TARGET-IN-SET | an indirect forward transfer accepted iff target typeid == site AND target ∈ that type's table (Track 11 L4) | `inv_cfi_forward_target_in_set` | T × T × B | 128 | proven |
| INV-CFI-NO-MIDFUNCTION-ENTRY | a forward target accepted iff its offset is 0 (a function entry, never mid-function) (Track 11 L4) | `inv_cfi_no_offset_entry` | O | 64 | proven |
| INV-SAFESTACK-RETURN-NO-FOREIGN-WRITE | a return-slot write accepted only from the canonical push/ret writer; CONSTANT in a foreign writer id (Track 11 L2) | `inv_safestack_return_unwritable` | W × W × B | 128 | proven |

**Total: 24 invariants, 4,556,876 predicate evaluations, zero mismatches**
(verified by Worker A on 2026-06-28: +3 Track-6 compartment-isolation,
+4 Track-4 leak/elevation replay-binding and cap-mask theorems, +2 Track-2
anti-rollback theorems; +3 Track-11 structural-CFI/SafeStack modeling theorems
on 2026-07-20, `T`/`O`/`W` = the bounded typeid/offset/writer spaces, NOT AUTH_*
bits — they do not widen the authority enumeration). These three are Track-11
invariants riding this shared runner; Track 3 itself remains closed. State counts
are re-derived on every run.

### 1b. INV-DRIVER-NO-DMA-MINT re-proven against the real broker (Track 8)

The abstract `inv_driver_no_dma_mint` theorem above models "grant present" as
one boolean. `scripts/test/eval_drvhost_dma_mint.py` closes the model-to-code
gap: it parses the REAL enforcement module `src/kernel/grithlk/driver_host.ghl`
with the production compiler's own lexer/parser and interprets the actual
broker functions over a modeled data segment with the emitted-code integer
semantics (64-bit wrap-around, signed comparisons, logical shifts). The kernel
primitives outside the broker (`page_alloc_contig`, `l3_map_driver_dma`) are
stubbed adversarially permissive, so the proof rests on the broker's own checks
only, and the raw MMIO boundary helpers are intercepted so "the device saw the
access" is an observed event, never a side effect.

| # | Property (∀ over the bound) | Real functions exercised | Checks |
|---|---|---|---|
| P1 | `drvhost_dma_contained(id,addr,len)==1` ⇒ `[addr,addr+len)` lies (unsigned) inside a window RECORDED FOR `id`, incl. adversarially planted malformed rows; complete on well-formed rows | `drvhost_dma_contained` | 96,768 |
| P2 | a DMA window row is minted only for a RUNNING driver holding `DRV_CAP_DMA`, never zero-length; a refused request mutates nothing (no partial mint) | `drvhost_grant_dma`, `drv_has_cap`, `drv_is_running` | 400 |
| P3 | across alloc sequences a driver's granted-DMA total never exceeds its signed policy ceiling (size-mask/overflow edges included); refused allocs leave table+accounting untouched | `drvhost_dma_alloc`, `drv_dma_grant_len` | 68 |
| P4 | the DMA-pointer MMIO write reaches the device iff the register is in the caller's MMIO grant AND the pointer VALUE is in the caller's OWN DMA grant - a sibling's window never satisfies it | `drvhost_mmio_write_dma_ptr` + the real admission path (`drvhost_policy_install` → `drvhost_register_slot` → grants) | 1,008 |
| P5 | only a `DRV_CAP_PCICFG` controller may route a window to a DIFFERENT driver_id | `drvhost_grant_mmio_for` | 8 |
| P6 | `drvhost_dma_map` maps only a granted base of the CALLER, idempotently; a second live mapping / a sibling base is refused | `drvhost_dma_map` | 7 |

**98,259 checks, zero violations.** `--selftest` (run first in the guard suite)
re-runs the proof over three PLANTED broken brokers - ownership check dropped,
capability gate dropped, pointer-value containment dropped - and requires each
to be caught, so the harness cannot silently rot into a no-op (same doctrine as
the §4 translation-validation meta-tests).

---

## 2. Policy → authority derivation (the P3 mapping)

`scripts/test/derive_authority.py` GENERATES the authority bitmasks from four
real sources and re-proves the invariants against them, so the model checks
*real configuration*, not hand-set values. 208 checks; any violation fails
the Track-3 runner.

| # | Real source | What is derived | How it is signed/enforced |
|---|---|---|---|
| S1 | `src/include/syscall_caps.inc` `MANIFEST_*` rows | per-app authority masks (CAP_FS_WRITE/CAP_FS_DELETE → AUTH_PERSIST; no syscall capability maps to any other authority) | manifests live inside KERNEL.BIN, admitted only under the 3-of KERNEL.ENV envelope (Track 2) |
| S2 | `src/tools/security/policy_graph_check.ghl` | per-domain obtainable authority, enumerated through the real `security_policy_graph_edge_is_valid` predicate over all (src, dst, cap, threshold); CAP_MEMORY→AUTH_MEMORY_GRANT, CAP_DMA→AUTH_DMA_MAP, CAP_POLICY_WRITE→AUTH_INSTALL_POLICY, CAP_UPDATE/CAP_STORAGE→AUTH_PERSIST | the same module the trusted path compiles `--forbid-asm --deny-unsafe` |
| S3 | `$KernelModules` build list + each module's `unsafe <cap>;` declarations + `nk_pt_window` bracketing | per-kernel-module authority: kernel_io → AUTH_DMA_MAP; PTE-writer (nk_pt_window) → AUTH_MEMORY_GRANT; raw_mem/kernel_priv/kernel_int/implicit_extern mint nothing cross-domain | compiler-enforced (`_require_cap`): an undeclared capability is a compile error; the build list is what ships in the signed image |
| S4 | `src/tools/security/threshold_check.ghl` class tables | artifact-class → TCB authority (BOOT/KERNEL/HYPERVISOR/UPDATE/RECOVERY → AUTH_GLOBAL; POLICY/CONFIG → AUTH_INSTALL_POLICY; DRIVER → AUTH_DMA_MAP; APP → derived app max) and the quorum floor that gates it | enforced at runtime by `envelope_verify_signed` / `artifact_gate_admit` (Track 2, real Ed25519) |

Derived results re-proved through the real predicates, highlights:

- No policy-graph domain can obtain AUTH_MINT_IDENTITY, AUTH_SIGN_MEASUREMENT,
  or AUTH_GLOBAL through ANY edge - those authorities are not mintable in the
  schema at all; AUTH_GLOBAL exists only as artifact-class admission under a
  ≥3-signature quorum.
- Every threshold-gated capability (DMA, UPDATE, DIAGNOSTIC, POLICY_WRITE per
  the real `requires_threshold` predicate) is unobtainable by every domain when
  threshold approval is absent (checked per capability - CAP_UPDATE and
  CAP_STORAGE share AUTH_PERSIST but differ in gating).
- Unsigned endpoints form no valid edge anywhere in the schema (exhaustive over
  all domain pairs × capabilities × threshold states).
- All 11 real app manifests lack all six non-app authorities; the widest app
  authority is AUTH_PERSIST (FS write), within the derived DOMAIN_APP bound.
- Scheduler tier (`frame_pacing.ghl`, `cpu_acct.ghl`) derives authority 0x00 →
  INV-SCHED-NO-MEMORY holds on real modules; IPC tier (`input_dispatch.ghl`,
  `net_dhcp_dispatch.ghl`) derives 0x00 → INV-IPC-NO-FORGE holds. A binding
  that names a module absent from the signed build list fails the suite.
- The only PTE-writing GHL module (`ram_volatile.ghl`) and every kernel_io
  module are admissible solely inside the threshold-admitted image; the real
  predicates reject them with the grant/threshold absent.
- The Track-3 enforcement modules themselves (`src/tools/security/*.ghl`)
  declare zero compiler capabilities - the checker holds no authority.
- Every artifact class requires a multi-party quorum (min_count ≥ 2; the
  global-authority classes require 3) and its rule is self-consistent per the
  real `security_threshold_class_quorum_ok`.

Detection plumbing is meta-tested: a planted `nk_pt_window` reference in a
scheduler-bound module flows into the derived mask and fails
INV-SCHED-NO-MEMORY (verified 2026-06-10, then reverted).

---

## 3. Containment claim table

Each row: compromise exactly ONE component; the listed authority is what it
provably cannot obtain *within the bounded model derived from real policy*.
Claims do not compose to "compromise of everything is safe", and none survive
total hardware compromise.

| Compromised component (real binding) | Authority it cannot obtain | Invariant | Proof status | Real-config binding |
|---|---|---|---|---|
| Any capability holder (derivation path) | more authority than its parent | INV-CAP-DERIVATION | proven (16,384) | S2 graph derivation |
| Any single domain | AUTH_GLOBAL without quorum | INV-NO-GLOBAL-MINT | proven (256) | S4 class quorums (all ≥ 2) |
| Scheduler (`frame_pacing.ghl`, `cpu_acct.ghl`) | AUTH_MEMORY_GRANT | INV-SCHED-NO-MEMORY | proven (128) | S3 derived mask 0x00 |
| IPC/dispatch (`input_dispatch.ghl`, `net_dhcp_dispatch.ghl`) | AUTH_MINT_IDENTITY | INV-IPC-NO-FORGE | proven (128) | S3 derived mask 0x00 |
| Any device driver module | self-minted DMA window | INV-DRIVER-NO-DMA-MINT | proven (256) | S3 kernel_io set, grant = signed-image admission |
| Page-table manager (`ram_volatile.ghl` + nk-monitored PTE writers) | persistence without threshold | INV-PT-NO-PERSIST | proven (256) | S3 nk_pt_window set |
| Policy loader | installing unsigned policy | INV-POLICY-SIGNED-ONLY | proven (2) | S2: no unsigned edge is valid, exhaustive |
| Hypervisor/monitor module | signing a foreign domain's measurement | INV-HV-NO-FOREIGN-MEASURE | proven (32,768) | model-level (monitor tier is Track 5/6 design) |
| Release build | observing the user (telemetry) | INV-RELEASE-NO-OBSERVE | proven (2) | release_privacy_guard + release pipeline |
| Recovery path | skipping measurement | INV-RECOVERY-NO-BYPASS | proven (65,536; constant in recovery_mode) | S4: ART_RECOVERY 3-of incl. RECOVERY role |
| Any deputy/proxy peer | laundering authority its requester lacks (or being pushed past its own) | INV-IPC-NO-CONFUSED-DEPUTY | proven (2,097,152) | S2 IPC domain derivation |
| Any app (all 11 real manifests) | reading another app's memory without a shared handle; any authority beyond AUTH_PERSIST | INV-APP-MEM-ISOLATION + S1 checks | proven (65,536 + per-manifest) | S1 signed manifest table |
| Any single monitor compartment (Track 6) | a second authority bit (mask is a singleton) | INV-COMPARTMENT-ONE-AUTHORITY | proven (128) | Track 6 C3 compartment model |
| Any compartment holding map authority (Track 6) | mapping a foreign compartment's region | INV-COMPARTMENT-NO-CROSS-MAP | proven (32,768) | Track 6 C3 region layout |
| A caller crossing the compartment trampoline (Track 6) | laundering its authority into the callee | INV-COMPARTMENT-NO-AUTH-LAUNDER | proven (2,097,152; constant in caller_auth) | Track 6 C3 trampoline |
| RAM-dump replay of a per-boot secret (Track 4 barrier 1) | authenticating on a fresh boot | INV-EPHEMERAL-NO-REPLAY | proven (32,768) | per-boot RDTSC^RDRAND redraw |
| RAM-dump replay of a per-slot key/slide (Track 4 barriers 2/4) | authenticating for another slot | INV-PER-SLOT-KEY-CONFINED | proven (32,768) | per-slot install diversification |
| RAM-dump-built static syscall blob (Track 4 barrier 3) | dispatching under a fresh launch permutation | INV-SYSCALL-PERM-PER-LAUNCH | proven (32,768) | per-launch heterogeneous numbering |
| RAM-dump replay of a planted 128-bit cap-mask MAC (Track 4 Part D) | widening a slot on a fresh boot unless both MAC lanes re-derive under the live canary | INV-PLANTED-CAP-HMAC-REJECTED | proven (648: genuine dump/live pairs plus independent lane corruptions) | `cap_mask_mac_lane` canary/slot/full-mask binding |
| Replay of a superseded signed artifact (Track 2) | admission below the persisted floor | INV-NO-ROLLBACK | proven (32,768) | floor_store.ghl FLOOR_LBA=2 |
| A floor-rewind attempt (Track 2) | lowering the persisted anti-rollback floor | INV-FLOOR-RATCHET-MONOTONIC | proven (16,384) | floor_store ratchet + RTC forward-ratchet |

---

## 4. Translation-validation & dynamic-width proof closure

Two mechanical steps close the "proof ≠ implementation" gap stated above as far
as is honest without a full refinement proof. Both run inside
`test_ghl_invariants.ps1`.

**Translation-validation (model ↔ emitted code).**
`eval_invariants.py --translation-validation` compiles `invariant_check.ghl`
with the *production* `gritc.py` (the same `--forbid-asm --deny-unsafe`
invocation the trusted path uses), splits the emitted assembly per function by
its `; ===== fn <name>` banner, and confirms that each proven authority
constant is exactly an immediate operand gritc placed into the corresponding
function body. Two independent oracles must agree per binding:

1. a FIXED documented literal (`TV_EXPECTED` in `eval_invariants.py`: the
   scheduler denies AUTH_MEMORY_GRANT=1, IPC denies AUTH_MINT_IDENTITY=2, the
   driver gate keys on AUTH_DMA_MAP=4, the PT gate on AUTH_PERSIST=8, the
   cap-mask authenticator on the exact domain, slot/mask, mixer, finalizer, and
   per-lane constants used by the 128-bit implementation), and
2. the immediate the compiler actually emitted into that function.

Because the expected value is a fixed literal (not re-read from the module), a
source const that is *consistently* changed (which would otherwise still "prove"
a different, weaker property silently) is caught: the changed const no longer
equals the documented literal, and the emitted immediate no longer matches it.
This is honestly bounded: it validates the authority *constants* carried into
the binary, NOT the predicates' control flow - it is translation validation of
the bits, not a refinement proof. The meta-test below proves it fires.

**Dynamic-width auto-extension.** The exhaustive space width is derived from the
module's `AUTH_*` constants (`discover_auth_width` / `set_auth_space`), not a
hard-coded 0..127. Each constant is checked to be a single non-zero bit, and the
space is `0 .. 2**(highest_bit_length) - 1`. Introducing a new authority bit
therefore widens every theorem's enumeration automatically, so the proof tracks
the policy it derives from rather than lagging behind a stale 7-bit bound.

**Meta-test (`test_invariant_meta.ps1`).** A proof/check that never fails is no
proof. The meta-test plants drift into a temp copy of the module (fed via the
`GHL_INVARIANT_MODULE` override; the real tree is never modified) and asserts:

1. a planted wrong authority constant (`AUTH_MEMORY_GRANT` → 1024) makes
   `--translation-validation` FAIL;
2. a planted new authority bit (`AUTH_BACKDOOR = 128`) that breaks `inv_subset`
   only in the now-wider 8-bit space makes `--exhaustive` FAIL - which can only
   happen if the width auto-widened with the new bit; and
3. a benign new authority bit (no predicate break) still PASSES `--exhaustive`
   over the auto-widened 8-bit space (the widening is sound, not spurious).

Verified passing 2026-06-23.

## 5. Maintenance

- Adding an invariant still follows the 4-artifact pattern (`.invariant` file,
  `.vectors` file, predicate in `invariant_check.ghl`, exhaustive spec in
  `eval_invariants.py`); if it claims a real component, add a binding in
  `derive_authority.py` and a row to the claim table here.
- If the policy schema grows (e.g. Trust Partitioning adds domains), the S2
  derivation enumerates domains/capabilities from the module's constants, so
  new domains are covered automatically; new *capabilities* need a mapping
  entry in `derive_authority.py` (the tool's mapping table is the single place).
- Adding a new `AUTH_*` authority bit auto-widens the exhaustive space (§4); no
  edit to the enumeration is required. If the new bit is referenced by a
  named-bit predicate whose proven semantics you want bound to the emitted code,
  add a `TV_EXPECTED` entry (fixed literal) in `eval_invariants.py` so
  translation-validation covers it too. Each `AUTH_*` const must remain a single
  non-zero bit or `discover_auth_width` fails closed.
- State counts above are re-derived on every run; this doc records the values
  verified by Worker A on 2026-06-28.
