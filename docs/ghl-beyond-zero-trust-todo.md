# GHL Beyond-Zero-Trust TODO

> **Map of all docs: `docs/TODO-INDEX.md` (read it first).** This master list
> LAGS the `trackN-*.md` docs where they overlap - on a conflict the track doc
> wins. See TODO-INDEX for the authority hierarchy and current state.

This is the master TODO for the new GHL-only security architecture. "GHL" here
means GritHL/GritHLK source and toolchain work only. This plan intentionally
does not accept new `.asm`, `.inc`, generated assembly include files, or inline
assembly escape hatches for the new trusted path.

The design target is stronger than ordinary zero trust: compromise of one
kernel partition, hypervisor partition, signing key, build service, update
service, driver, app, or operator path must not be enough to compromise the
whole system, leak private data, or authorize persistent malicious state.

## Active Track Plans

Per-track working plans (with their own granular TODOs and verified increments):

- `docs/track1-repo-enforcement-todo.md` - P0 repository enforcement.
- `docs/track2-signed-everything-todo.md` - P0 signed-everything keystone.
- `docs/track3-sel4-validity-todo.md` - P2 seL4 validity / invariants.
- `docs/track4-ram-secure-erasure-todo.md` - RAM-only / volatile execution +
  best-effort secure-erasure memory (threat-model expansion: snapshot/RAM-dump
  attacker, with the irreducible software residual documented).

Single verification entry point for all of the above:
`scripts/test/test_ghl_security_guards.ps1` (privacy + no-asm + inventory +
policy-module compile + checker fixtures + seL4 invariants).

The "Extended Hardening" sections at the bottom of this file capture work that
goes *beyond* the original program (toolchain trust, proof depth, TCB reduction,
transparency/attestation, crypto agility/PQC, side-channel, continuous assurance,
data-at-rest). They are not yet split into their own track docs.

## Global Non-Negotiables

- [ ] Treat all new security work as GHL/GritHLK-only.
- [ ] Block new `.asm` files in the active implementation path.
- [ ] Block new `.inc` files in the active implementation path.
- [ ] Block inline `asm`, `asm {}`, textual instruction injection, and compiler
      escape hatches.
- [ ] Block generated assembly include files as a supported interface.
- [ ] Keep legacy assembly only as quarantined migration input until replaced.
- [ ] Require every new module to compile with `--forbid-asm`.
- [ ] Require security-critical modules to compile with `--deny-unsafe`.
- [ ] Allow unsafe capabilities only at named hardware boundaries.
- [ ] Require unsafe boundaries to be tiny, documented, reviewed, and tested.
- [ ] Make the default compiler behavior fail closed for unknown targets,
      unknown intrinsics, unknown signer roles, unknown policy fields, and
      unknown artifact types.
- [ ] Prefer typed compiler intrinsics over opaque low-level escape mechanisms.
- [ ] Keep each feature fast by design: bounded parsing, bounded verification,
      no hidden network waits, no unbounded allocation, no quadratic policy
      checks in hot paths.
- [ ] Keep each feature maintainable by design: schema versioning, generated
      validators, central policy definitions, narrow stable APIs, and no need
      to update most apps for one kernel/security change.

## P0: Repository Enforcement

- [x] Add a source guard that fails if a new `.asm` file appears outside the
      documented legacy quarantine list. (`check_no_asm.ps1 -InventoryGuard`)
- [x] Add a source guard that fails if a new `.inc` file appears outside the
      documented legacy quarantine list. (`check_no_asm.ps1 -InventoryGuard`)
- [x] Add a source guard that fails on inline assembly syntax in `.ghl`,
      compiler sources, build scripts, or generated artifacts.
- [ ] Add a source guard that fails on raw instruction-emitter strings unless
      they are inside the compiler backend allowlist.
- [ ] Add a source guard that fails when generated `.asm` or `.inc` artifacts
      are treated as source of truth.
- [~] Add a migration inventory file listing every legacy `.asm` and `.inc`
      file, owner, risk, replacement module, and deletion gate.
      (`tools/security/legacy_asm_inventory.txt` lists all 181 files + enforces
      monotonic shrink; owner/risk/replacement columns still TODO - see Track 1.)
- [ ] Add CI output that reports "GHL-only trusted path: pass/fail".
- [ ] Add CI output that reports "legacy assembly quarantine unchanged:
      pass/fail".
- [ ] Add a presubmit test that rejects new public APIs exposed through include
      files.
- [ ] Add a presubmit test that rejects undocumented compiler intrinsics.
- [x] Add a presubmit test that rejects security modules without a threat note.
      `test_source_guards.ps1` now requires every `src/tools/security/*.ghl` to
      carry a `# THREAT:` header line naming the adversary it defends against
      (all 12 modules annotated; the guard trips on any module lacking one).
- [ ] Add a presubmit test that rejects release logging calls in security,
      identity, update, policy, and crypto modules.
- [ ] Add a presubmit test that rejects raw user data in log/trace format
      strings.

## P0: GHL Compiler Security

- [ ] Make `--forbid-asm` mandatory for every new boot, kernel, hypervisor, and
      security module.
- [ ] Make `--deny-unsafe` mandatory for non-boundary security modules.
- [x] Split unsafe capabilities by exact authority instead of broad categories.
      DONE (2026-06-10): gritc gained narrow per-authority kernel caps
      (`kernel_creg`, `kernel_pgtable`, `kernel_dtable`, `kernel_idtable`)
      alongside the existing `kernel_io` / `kernel_int`. The broad `kernel_priv`
      remains a SUPERSET (satisfies any narrow cap via `_KERNEL_PRIV_SUBSUMES`)
      so legacy modules compile unchanged. Proven by
      `tests/ghl_kernel/exact_authority_caps.ghl` (narrow caps only compile) +
      `exact_authority_wrong.ghl` (kernel_creg does NOT grant lgdt → rejected),
      wired into `scripts/test/test_gritc_security.ps1`.
- [x] Add capability gates for control-register operations. DONE - `write_cr0`
      / `write_cr4` require `kernel_creg`.
- [x] Add capability gates for descriptor-table operations. DONE - `lgdt` /
      `ltr` require `kernel_dtable`.
- [x] Add capability gates for interrupt-table operations. DONE - `lidt`
      requires `kernel_idtable`.
- [x] Add capability gates for port I/O operations. DONE - `inb`/`outb`/`inw`/
      `outw`/`ind`/`outd` require `kernel_io` (boot path: `boot_io`).
- [x] Add capability gates for MMIO operations. DONE (2026-07-17) - under
      `--target driver`, every constant broker MMIO syscall requires an explicit
      `capability mmio;`; dynamic syscall numbers are rejected fail-closed.
- [x] Add capability gates for page-table mutation. DONE - `write_cr3` /
      `invlpg` require `kernel_pgtable`.
- [x] Add capability gates for DMA mapping. DONE (2026-07-17) - broker DMA
      allocation/mapping requires `capability dma;`, and the MMIO DMA-pointer
      programming operation requires both `mmio` and `dma`. Signed policy and
      broker window checks remain the independent runtime authority.
- [x] Add capability gates for device reset and firmware load. DONE
      (2026-07-17) - under `--target driver`, the reserved broker rows 264
      (device reset) / 265 (firmware load) require explicit `capability reset;`
      / `capability fwload;`. The classes are split on purpose (firmware
      persists past a reboot; `DRV_CAP_RESET` never subsumes `DRV_CAP_FWLOAD`).
      Proven by `driver_target_{reset,fwload}_cap_forbidden.ghl` (the adjacent
      class must not satisfy the gate) + `driver_target_reset_fwload_ok.ghl`.
- [ ] Add capability gates for clock, timer, and monotonic-counter reads.
- [ ] Add target-specific intrinsic allowlists for boot, kernel, hypervisor,
      driver, app, tool, and recovery targets.
- [x] Add compiler tests proving user apps cannot request privileged
      intrinsics. (`tests/ghl_kernel/user_privileged_forbidden.ghl` -
      write_cr0() rejected under --target user even with kernel_creg declared,
      asserted by `test_gritc_security.ps1`)
- [ ] Add compiler tests proving drivers cannot mutate unrelated page tables.
- [ ] Add compiler tests proving recovery code cannot call normal update
      authority without threshold authorization.
- [x] Add compiler tests proving raw memory access is unavailable without an
      explicit capability. (`raw_mem_forbidden.ghl` rejected / `raw_mem_caps.ghl`
      accepted - proves the gate keys off `unsafe raw_mem`, not the builtin)
- [x] Add compiler tests proving unknown unsafe declarations are hard errors.
      (`unknown_cap_forbidden.ghl` - unsafe namespace is a closed allowlist)
- [x] Add compiler tests proving unsafe declarations are rejected by
      `--deny-unsafe`. (existing `boot_unsafe_decl.ghl` guard in
      `test_gritc_security.ps1`)
- [x] Add compiler tests proving generated code contains no inline assembly
      escape blocks. (existing `asm_forbidden.ghl` --forbid-asm/--target boot
      guards)
- [ ] Add compiler tests proving generated code includes a machine-readable
      authority manifest.
- [ ] Add source maps from GHL lines to generated low-level symbols for audits.
- [ ] Add deterministic build output for security-critical GHL modules.
- [ ] Add compiler documentation for every intrinsic, its authority, arguments,
      side effects, and verification tests.

## P0: Trust Partitioning

- [ ] Define the minimum set of security domains.
- [ ] Define a policy-control domain.
- [ ] Define a crypto-identity domain.
- [ ] Define an update-verification domain.
- [ ] Define a recovery-attestation domain.
- [ ] Define a memory-authority domain.
- [ ] Define an IPC-authority domain.
- [ ] Define a device-authority domain.
- [ ] Define an application-execution domain.
- [ ] Ensure no domain can mint global authority alone.
- [ ] Ensure no domain can sign for another domain.
- [ ] Ensure no domain can silently disable another domain's measurements.
- [ ] Ensure no domain can silently disable release privacy controls.
- [ ] Ensure each domain has a stable GHL interface contract.
- [ ] Ensure each domain exposes narrow commands instead of broad shared state.
- [ ] Ensure each domain can be tested with hostile peers.
- [ ] Ensure each domain can fail closed without corrupting global state.
- [ ] Add a document mapping every critical action to required domains and
      threshold approvals.

## P0: Compromised Kernel And Hypervisor Containment

- [ ] Stop treating "the kernel" as one trusted authority in the architecture.
- [ ] Split kernel authority into independently measured pieces.
- [ ] Define memory authority separately from scheduler authority.
- [ ] Define IPC authority separately from memory authority.
- [ ] Define device authority separately from IPC authority.
- [ ] Define policy loading separately from runtime policy enforcement.
- [ ] Define recovery authority separately from normal runtime authority.
- [ ] Define hypervisor authority as partitioned modules, not a monolith.
- [ ] Ensure a compromised scheduler cannot grant memory access.
- [ ] Ensure a compromised IPC router cannot forge component identity.
- [ ] Ensure a compromised device driver cannot mint DMA access.
- [ ] Ensure a compromised page-table manager cannot authorize persistence
      without threshold policy.
- [ ] Ensure a compromised policy loader cannot install unsigned policy.
- [ ] Ensure a compromised hypervisor module cannot sign a trusted measurement
      for unrelated modules.
- [ ] Add negative tests for each single-domain compromise assumption.
- [ ] Add recovery tests that quarantine one failed partition.
- [ ] Add recovery tests that continue with reduced capability where safe.
- [ ] Add recovery tests that halt when reduced operation would leak data.

## P0: Signed Everything

- [x] Define a signed artifact envelope shared by boot, kernel, hypervisor,
      drivers, apps, policies, configs, updates, recovery bundles, and tests.
      (Spec `docs/signed-artifact-envelope.md` v1 + structural kernel
      `src/tools/security/signed_envelope.ghl`. The Track 2 runtime reader/writer
      that this item was gated on has landed: in-kernel `envelope_verify_signed`
      + the host envelope writer, with boot/kernel/update call sites bound through
      `envelope_gate.ghl` and the loader KERNEL.ENV path - one shared v1 envelope
      across all artifact classes. See track2 "Done definition".)
- [ ] Include artifact type in every signature.
- [ ] Include target domain in every signature.
- [ ] Include target device or target device class in every signature.
- [ ] Include artifact hash in every signature.
- [ ] Include schema version in every signature.
- [ ] Include signer role in every signature.
- [ ] Include validity window in every signature.
- [ ] Include monotonic version in every signature.
- [ ] Include anti-rollback counter in every signature.
- [ ] Include required co-signer roles in every signature.
- [ ] Include revocation epoch in every signature.
- [ ] Include build provenance hash in every release artifact signature.
- [ ] Include policy dependency hash in every runnable artifact signature.
- [ ] Reject unsigned artifacts.
- [ ] Reject malformed signed envelopes.
- [ ] Reject mismatched artifact types.
- [ ] Reject wrong target domains.
- [ ] Reject wrong target devices.
- [ ] Reject expired signatures.
- [ ] Reject stale revocation epochs.
- [ ] Reject replayed artifacts.
- [ ] Reject downgraded artifacts.
- [ ] Reject valid signatures from roles not authorized for the artifact type.
- [ ] Reject artifacts whose manifest and payload disagree.
- [x] Add constant-time comparison helpers where secrets or MACs are involved.
      DONE (2026-06-10): `security_envelope_ct_equal4/8`
      (`src/tools/security/signed_envelope.ghl`) made truly constant-time -
      replaced the per-word `if a != b` data-dependent branches (which leaked,
      via timing/branch-prediction, which word first mismatched = a byte-by-byte
      forgery oracle) with branchless XOR-OR accumulation; the sole remaining
      branch is on the public all-equal result. Verified through the real GHL
      frontend by eval_envelope.py (payload_hash_mismatch + valid_envelope_accept
      both green) and eval_ed25519.py.
- [ ] Add bounded streaming verification for large artifacts.

## P0: Threshold Signing

- [ ] Define threshold policy for boot acceptance.
- [ ] Define threshold policy for kernel partition activation.
- [ ] Define threshold policy for hypervisor partition activation.
- [ ] Define threshold policy for driver activation.
- [ ] Define threshold policy for app store or app bundle activation.
- [ ] Define threshold policy for policy updates.
- [ ] Define threshold policy for config updates.
- [ ] Define threshold policy for firmware updates.
- [ ] Define threshold policy for recovery actions.
- [ ] Define threshold policy for key rotation.
- [ ] Define threshold policy for key revocation.
- [ ] Ensure one stolen signing key cannot authorize updates.
- [ ] Ensure one compromised build server cannot authorize releases.
- [ ] Ensure one compromised operator cannot enable diagnostics.
- [ ] Ensure one compromised update server cannot ship payloads.
- [ ] Ensure one compromised recovery key cannot reset trust anchors.
- [ ] Add tests for every missing-cosigner failure.
- [ ] Add tests for duplicate signer rejection.
- [ ] Add tests for wrong-role signer rejection.
- [ ] Add tests for threshold downgrade rejection.
- [ ] Add tests for quorum changes requiring old and new quorum approval.

## P0: Release Privacy

- [ ] Define release mode as no private logging by default.
- [ ] Remove or compile out debug traces from release security modules.
- [ ] Remove or compile out message payload logging in release builds.
- [ ] Remove or compile out raw pointer logging in release builds.
- [ ] Remove or compile out process/app identity trails unless required for
      local safety state.
- [ ] Remove or compile out network telemetry in release builds.
- [ ] Remove or compile out crash dumps containing memory in release builds.
- [ ] Remove or compile out filesystem path logging in release builds unless
      the user explicitly enables diagnostics.
- [ ] Remove or compile out keystroke, clipboard, window-title, and app-content
      logging in release builds.
- [ ] Make diagnostic mode explicit, local-visible, temporary, signed, scoped,
      and revocable.
- [ ] Require threshold authorization for diagnostic mode on production images.
- [ ] Require user-visible state when diagnostics are active.
- [ ] Require diagnostic output redaction by schema, not by ad hoc formatting.
- [ ] Add tests that scan release images for banned log strings.
- [ ] Add tests that scan release symbol tables for debug-only entry points.
- [ ] Add tests that prove diagnostics expire.
- [ ] Add tests that prove diagnostics cannot be enabled silently.
- [ ] Add tests that prove diagnostics cannot collect payload data outside the
      signed scope.

## P0: Capability Policy

- [ ] Define a signed capability-policy schema.
- [ ] Define stable component identities.
- [ ] Define stable domain identities.
- [ ] Define device capability classes.
- [ ] Define memory capability classes.
- [ ] Define IPC endpoint capability classes.
- [ ] Define update capability classes.
- [ ] Define recovery capability classes.
- [ ] Define diagnostic capability classes.
- [ ] Make default policy deny all.
- [ ] Require explicit grants for every IPC edge.
- [ ] Require explicit grants for every memory mapping.
- [ ] Require explicit grants for every DMA window.
- [ ] Require explicit grants for every device operation.
- [ ] Require explicit grants for every update channel.
- [ ] Require explicit grants for every persistent storage namespace.
- [ ] Require explicit grants for every diagnostic sink.
- [ ] Reject policies that expand privilege without threshold approval.
- [ ] Reject policies that contain unknown capability classes.
- [ ] Reject policies that contain wildcard authority in production.
- [ ] Reject policies that grant authority to unsigned components.
- [ ] Add a policy graph validator.
- [ ] Add a policy graph diff tool.
- [ ] Add a policy graph minimizer to find unnecessary grants.
- [ ] Add tests for hostile policy graphs.
- [ ] Add tests for cyclic authority escalation.
- [ ] Add tests for confused-deputy IPC flows.

## P0: App Compatibility And Maintainability

- [ ] Create a stable app ABI manifest so security internals can evolve without
      updating most apps.
- [ ] Route app access through versioned service APIs, not direct kernel
      internals.
- [ ] Keep app permissions declarative and signed.
- [ ] Keep app manifests separate from app code.
- [ ] Support capability negotiation with safe defaults.
- [ ] Support app manifest migration by schema adapters.
- [ ] Support deprecating capabilities without breaking unrelated apps.
- [ ] Add a compatibility test corpus for existing `.ghl` apps.
- [ ] Add tests proving a security-policy change does not require touching app
      source unless the app requested the affected capability.
- [ ] Add generated documentation for app-facing APIs.
- [ ] Add an ABI stability checklist before changing syscall/service contracts.
- [ ] Add a service facade layer so apps do not depend on partition layout.
- [ ] Add a policy translation layer so old app manifests can be denied or
      safely mapped instead of rewritten by hand.

## P1: Boot Chain

- [ ] Define the minimal trusted boot input set.
- [ ] Define hardware root-of-trust integration points.
- [ ] Define measured boot records in GHL data structures.
- [ ] Define boot artifact manifests.
- [ ] Define boot partition manifests.
- [ ] Define boot policy manifests.
- [ ] Verify each stage before activation.
- [ ] Measure each stage before activation.
- [ ] Bind measurements to the signed policy version.
- [ ] Bind measurements to the device identity.
- [ ] Bind measurements to anti-rollback state.
- [ ] Reject boot on missing measurements.
- [ ] Reject boot on stale rollback counters.
- [ ] Reject boot on unsigned fallback paths.
- [ ] Add recovery boot path with separate authority.
- [ ] Add boot tests for broken signatures.
- [ ] Add boot tests for valid signature on wrong target.
- [ ] Add boot tests for downgraded but validly signed images.
- [ ] Add boot tests for missing co-signers.
- [ ] Add boot tests for corrupted measured state.

## P1: Runtime Identity

- [ ] Define `component_id` as a hash over public key, manifest, code hash, and
      policy binding.
- [ ] Define `domain_id` as a hash over partition manifest and policy binding.
- [ ] Require mutual authentication on security-sensitive IPC.
- [ ] Require replay protection on signed or MACed messages.
- [ ] Require nonces or monotonic counters on update, policy, recovery, and
      diagnostic requests.
- [ ] Require message type binding in every signature or MAC.
- [ ] Require endpoint binding in every signature or MAC.
- [ ] Reject messages signed for another endpoint.
- [ ] Reject messages signed for another policy epoch.
- [ ] Reject messages signed by stale component identities.
- [ ] Add tests for replayed IPC messages.
- [ ] Add tests for reflected IPC messages.
- [ ] Add tests for confused component identity.
- [ ] Add tests for endpoint substitution.

## P1: Update System

- [ ] Define signed update bundle schema.
- [ ] Define signed update manifest schema.
- [ ] Define per-domain update permissions.
- [ ] Define staged update activation.
- [ ] Define atomic update commit.
- [ ] Define update rollback only to still-trusted versions.
- [ ] Define update cancellation.
- [ ] Define partial update recovery.
- [ ] Define incompatible update rejection.
- [ ] Require threshold approval for production updates.
- [ ] Require compatibility declaration for each update.
- [ ] Require policy impact summary for each update.
- [ ] Require privacy impact summary for each update.
- [ ] Add tests for interrupted updates.
- [ ] Add tests for malicious update server payload substitution.
- [ ] Add tests for signed payload under wrong manifest.
- [ ] Add tests for rollback attack.
- [ ] Add tests for stale policy after update.
- [ ] Add tests for failed update quarantine.

## P1: Recovery And Revocation

- [ ] Define recovery partition authority.
- [ ] Define recovery partition dependencies.
- [ ] Define recovery activation policy.
- [ ] Define local recovery UX without leaking private data.
- [ ] Define key revocation records.
- [ ] Define revocation propagation.
- [ ] Define emergency revocation threshold.
- [ ] Define compromised domain quarantine.
- [ ] Define compromised key quarantine.
- [ ] Define re-keying after compromise.
- [ ] Define remeasurement after recovery.
- [ ] Define recovery audit output without private logs.
- [ ] Add tests for revoked signer rejection.
- [ ] Add tests for partition quarantine.
- [ ] Add tests for recovery without trusting the compromised partition.
- [ ] Add tests for failed recovery halting safely.
- [ ] Add tests for re-keying after one key compromise.

## P1: Crypto Implementation Rules

- [ ] Use vetted primitives only.
- [ ] Centralize crypto APIs behind small GHL interfaces.
- [ ] Avoid ad hoc hashing or signature formats.
- [ ] Avoid exposing raw key material to normal domains.
- [ ] Keep private keys out of release images.
- [ ] Keep signing separated from verification.
- [ ] Keep test keys visibly marked and impossible to trust in production.
- [ ] Require constant-time operations where needed.
- [ ] Require RNG health checks before key generation.
- [ ] Require deterministic test vectors for every primitive.
- [ ] Require negative test vectors for every parser.
- [ ] Require fuzzing for artifact envelopes.
- [ ] Require fuzzing for policy parsers.
- [ ] Require fuzzing for update manifests.
- [ ] Require bounded memory use during verification.
- [ ] Require bounded CPU use during verification.
- [ ] Document every accepted algorithm and rejection timeline.

## P1: Parser And Schema Safety

- [ ] Define all security schemas with explicit versions.
- [ ] Define canonical serialization for signed data.
- [ ] Reject duplicate fields in signed data.
- [ ] Reject unknown critical fields.
- [ ] Reject non-canonical encodings.
- [ ] Reject integer overflows.
- [ ] Reject length overflows.
- [ ] Reject deeply nested structures beyond a small bound.
- [ ] Reject cyclic references.
- [ ] Reject ambiguous string normalization.
- [ ] Reject path traversal in bundles.
- [ ] Reject external references in signed security manifests.
- [ ] Add property tests for canonicalization.
- [ ] Add parser differential tests where possible.
- [ ] Add corpus tests for malformed envelopes.
- [ ] Add corpus tests for malformed policies.
- [ ] Add corpus tests for malformed configs.
- [ ] Add corpus tests for malformed update bundles.

## P1: Security Checker Fixtures

- [x] Add pass/fail fixtures for signed artifact checks.
- [x] Add pass/fail fixtures for policy graph checks.
- [x] Add pass/fail fixtures for threshold checks.
- [x] Add pass/fail fixtures for canonical schema checks.
- [x] Add pass/fail fixtures for revocation checks.
- [x] Add pass/fail fixtures for compatibility checks.
- [x] Add a fixture verification entry point that compiles referenced GHL
      checker modules with `--forbid-asm --deny-unsafe`.

## P1: Performance Gates

- [ ] Set maximum boot verification time budget.
- [ ] Set maximum policy verification time budget.
- [ ] Set maximum IPC authentication overhead budget.
- [ ] Set maximum update manifest verification time budget.
- [ ] Set maximum memory overhead per component identity.
- [ ] Set maximum memory overhead per policy edge.
- [ ] Add microbenchmarks for signature verification.
- [ ] Add microbenchmarks for MAC verification.
- [ ] Add microbenchmarks for policy lookup.
- [ ] Add microbenchmarks for artifact parsing.
- [ ] Add microbenchmarks for canonical serialization.
- [ ] Cache verified immutable artifacts by hash.
- [ ] Cache policy decisions only when bound to policy epoch.
- [ ] Avoid per-message public-key verification in hot IPC paths; use
      session-bound keys or MACs after authenticated setup.
- [ ] Add regression gates for verification latency.
- [ ] Add regression gates for memory growth.

## P1: Documentation Requirements

- [ ] Document every security domain.
- [ ] Document every trust assumption.
- [ ] Document every unsafe compiler capability.
- [ ] Document every signed artifact type.
- [ ] Document every signer role.
- [ ] Document every threshold rule.
- [ ] Document every release privacy rule.
- [ ] Document every diagnostic exception.
- [ ] Document every policy capability class.
- [ ] Document every recovery path.
- [ ] Document every revocation path.
- [ ] Document every compatibility promise.
- [ ] Document every API stability rule.
- [ ] Document every test gate required before merging security changes.
- [ ] Keep docs generated or checked against schemas where practical.

## P2: Migration From Existing Code

- [ ] Inventory current boot assembly.
- [ ] Inventory current kernel assembly.
- [ ] Inventory current driver assembly.
- [ ] Inventory current GUI assembly.
- [ ] Inventory current network assembly.
- [ ] Inventory current user assembly.
- [ ] Inventory current include-file ABI dependencies.
- [ ] Rank legacy modules by security criticality.
- [ ] Rank legacy modules by migration difficulty.
- [ ] Rank legacy modules by test coverage.
- [ ] Migrate leaf boot helpers first.
- [ ] Migrate pure data-layout declarations to typed GHL records.
- [ ] Migrate pure helper functions before authority-heavy modules.
- [ ] Migrate syscall validation before broad syscall dispatch.
- [ ] Migrate policy and identity code before drivers.
- [ ] Migrate drivers behind stable service interfaces.
- [ ] Keep byte-identical or behavior-identical tests for each migrated module.
- [ ] Delete legacy assembly only after the replacement is live and verified.
- [ ] Update the quarantine inventory after each migration.
- [ ] Prevent new dependencies on quarantined legacy APIs.

## P2: seL4 Validity Track

**COMPLETE / CLOSED 2026-06-10** - see `track3-sel4-validity-todo.md`
(authoritative) and `track3-invariant-proofs.md` (theorems, bounds, state
counts, containment claim table, honesty statement).

- [x] Define which seL4-style properties this system wants to preserve.
- [x] Define capability derivation invariants. (INV-CAP-DERIVATION)
- [x] Define authority confinement invariants. (INV-NO-GLOBAL-MINT)
- [x] Define IPC authorization invariants. (INV-IPC-NO-FORGE,
      INV-IPC-NO-CONFUSED-DEPUTY)
- [x] Define memory isolation invariants. (INV-APP-MEM-ISOLATION)
- [x] Define device isolation invariants. (INV-DRIVER-NO-DMA-MINT)
- [x] Define scheduler non-authority invariants. (INV-SCHED-NO-MEMORY)
- [x] Define recovery non-bypass invariants. (INV-RECOVERY-NO-BYPASS)
- [x] Define privacy non-observation invariants for release builds.
      (INV-RELEASE-NO-OBSERVE)
- [x] Map GHL policy schema to capability graph invariants.
      (`derive_authority.py` S2 - derived through the real edge predicates)
- [x] Map compiler unsafe capabilities to authority graph edges.
      (`derive_authority.py` S3 - signed build list + `unsafe` decls +
      nk_pt_window)
- [x] Map signed artifacts to trusted computing base changes.
      (`derive_authority.py` S4 - class→TCB authority vs the real quorum table)
- [x] Add machine-checkable invariant files. (`tests/security/invariants/*`)
- [x] Add invariant tests to full verification.
      (`scripts/test/test_ghl_invariants.ps1`, wired into the entry point)
- [x] Add proof-oriented docs for every P0 invariant.
      (`track3-invariant-proofs.md` §1)
- [x] Avoid claiming full security after arbitrary total hardware compromise.
      (honesty statement, `track3-invariant-proofs.md`)
- [x] Be precise: each containment claim must name the compromised component and
      the authority it does not have. (claim table, `track3-invariant-proofs.md` §3)

## P2: Tooling

- [x] Add bootstrap guard wrapper `tools/security/check_no_asm.ps1`.
- [x] Add bootstrap guard wrapper `tools/security/check_release_privacy.ps1`.
- [x] Add GHL-native no-ASM guard policy source.
- [x] Add GHL-native release privacy guard policy source.
- [ ] Port the no-ASM guard logic into GHL-native source.
- [ ] Port the release privacy guard logic into GHL-native source.
- [x] Add GHL-native signed artifact checker.
- [x] Add GHL-native policy graph checker.
- [x] Add GHL-native threshold rule checker.
- [x] Add GHL-native canonical schema checker.
- [x] Add GHL-native revocation checker.
- [x] Add GHL-native compatibility checker.
- [ ] Add GHL-native security documentation generator.
- [ ] Add GHL-native security dashboard.
- [ ] Keep host scripts as thin launchers only; policy, parsing, validation,
      and security decisions must live in GHL/GritHLK modules.
- [ ] Reject new security-tool TODOs or implementation plans that target host
      scripting instead of GHL/GritHLK.
- [x] Add a single verification entry point for the trusted GHL path.
- [x] Add clear output that separates legacy migration debt from trusted-path
      failures.

## Extended Hardening (Beyond The Original Program)

Additions that push past the original tracks. Grouped by theme; priority noted
per section. None started unless marked.

### P0/P1: Toolchain Trust (defeat "trusting trust")
The whole posture assumes the compiler and build tools are honest; nothing yet
verifies that. Largest unaddressed surface.

- [ ] Bootstrappable build: compile the GHL toolchain from a minimal auditable
      seed so a backdoored binary compiler cannot silently persist.
- [ ] Diverse double-compilation (DDC): build via two independent toolchains/
      paths and prove the outputs converge.
- [ ] Bit-for-bit reproducible full images a third party can independently
      rebuild and confirm against a published digest (extend the A/B ORG passes).
- [ ] Pin + hash every build input (the assembler, the GHL toolchain
      interpreter, build scripts); verify before use.
- [ ] Emit a machine-readable SBOM for the OS image.
- [ ] Proof-carrying codegen / translation validation: prove emitted NASM
      preserves GHL source semantics for security-critical modules.

### P2: Proof Depth (beyond authority-bitmask invariants)
- [ ] Non-interference / information-flow proof: no data flows between app slots
      except through an explicit shared handle (proven, not modeled).
- [ ] Constant-time verification as a CI gate over secret-handling asm
      (kernel_canary, l3_slot_key[], blob-signing key, HMAC paths) - make CT a
      checked property, not a hand-applied one.
- [ ] Bounded model-check the syscall dispatch state machine for any path that
      dispatches without all gates (cap -> allowlist -> rate -> validate -> perm).
- [ ] Mutation-test the security regression suite: prove it fails when a
      mitigation is broken.

### P1: TCB Reduction / True Partitioning
- [ ] Privilege-separate drivers / net / fs into ring-3 partitions with
      capability IPC (not ambient kernel calls).
- [ ] Measure and publish the TCB size; CI fails on TCB growth.
- [ ] User-space reference monitor for policy decisions, outside the monolith.

### P1: Transparency & Attestation
- [ ] Binary transparency log (append-only Merkle / Rekor-style) for releases.
- [ ] Remote attestation protocol over mb_digest: nonce challenge -> signed quote.
- [ ] Hash-chain the cap_audit_ring so the §4 capability-transition log is
      tamper-evident (cannot be silently truncated/rewritten).

### P1: Crypto Agility & Post-Quantum
- [ ] PQC artifact-signature option (SPHINCS+ / ML-DSA) in the signed envelope -
      leverages the existing quantum entropy seed (qrng_seed).
- [ ] Key hierarchy + rotation + forward secrecy; per-boot ephemeral keys.
- [ ] Threshold / Shamir-split signing keys (key material never fully assembled).
- [ ] RNG health checks before every key/nonce draw (enforce the P1 rule on
      kernel_canary_init / l3_boot_nonce).

### P1: Side-Channel & Micro-Architectural
- [ ] Audit every indirect branch for Spectre-v2 coverage (prove the lfence set
      is complete); consider retpoline-style thunks.
- [ ] Cross-slot cache/timing isolation (flush or partition on slot switch).
- [ ] SSB / MDS mitigations where portable.
- [ ] Timer-driven ASLR re-randomization (shrink the leak-then-exploit window).

### P1: Continuous Adversarial Assurance
- [ ] Coverage-guided fuzzing of the envelope decoder, policy parser, syscall
      validators, and XML/SVG parsers, wired into CI (not one-shot).
- [ ] Symbolic execution of sc_validate_from_table and the path canonicalizer.
- [ ] One fail-closed PoC per landed mitigation in -SecurityRegression.

### P1: Data-at-Rest & Secret Hygiene
- [ ] Per-install keyed FS encryption (l3_slot_key) so a copied DATA.IMG is not
      plaintext (within the non-physical threat model).
- [ ] Zeroize transient secrets after use everywhere (HMAC scratch, key
      derivation buffers, decrypted pages).
- [ ] Secure-delete semantics for the FS.
- See `docs/track4-ram-secure-erasure-todo.md` for the in-RAM (not at-rest)
  variant of this work.

### P1: Hardware Memory Encryption (opportunistic - detect + enable, no-op if absent)
Transparent memory-controller AES so a cold-boot / physical-DIMM / DMA-of-DRAM
capture is ciphertext. Same scaffold pattern as CET/SMAP/KPTI (detect always
compiled, enable gated, status via SYS_SYSINFO). Full detail + MSR/CPUID specifics
in `docs/track4-ram-secure-erasure-todo.md` Part C.

- [x] **Intel TME** detect (CPUID.7.0.ECX[13]; IA32_TME_ACTIVATE MSR 0x982 bit 1
      = enabled / bit 0 = locked) - OS detects + asserts (BIOS enables+locks).
- [x] **Intel TME-MK** per-KeyID separation → maps onto the per-slot key model.
      `security_fme_mktme_supported` + `security_fme_mktme_key_count` (usable
      KeyIDs = `2^TME_KEYID_BITS - 1`) in `fme_memory_encryption_check.ghl`.
- [x] **AMD SME** detect (CPUID 0x8000001F EAX[0]; C-bit = EBX[5:0]; enable via
      SYSCFG MSR 0xC0010010 bit 23) + opportunistic per-page C-bit on
      kernel-secret / slot / FS-cache pages. Detect + C-bit-mask + page-class
      policy in `fme_memory_encryption_check.ghl`
      (`security_fme_amd_cbit_mask`, `_sme_page_markable`,
      `_sme_class_wants_cbit`); PTE write is the kernel-integration tail.
      See track4 Part C.
- [x] **AMD SEV / SEV-ES / SEV-SNP** + **Intel TDX** detect - confidential-VM
      tier; only if Grit runs as a guest or hosts VMs. Decide whether to target
      running as a confidential guest (cheapest path to true whole-memory opacity
      on cloud hardware). Detect landed in `fme_memory_encryption_check.ghl`
      (SEV/ES/SNP CPUID+MSR tiers, SNP `armed` gated on a provisioned RMP, TDX via
      the `CPUID 0x21` "IntelTDX" signature). DECISION: detect-and-report only, do
      NOT target being a guest - conceding a trusted host hypervisor contradicts
      the Track 5/6 "Grit is the most-privileged software" model and the
      bare-metal direction (full rationale in track4 Part C).
- [x] Caveat doc: QEMU TCG does NOT emulate TME/SME - verifiable only on real
      silicon (or KVM+SEV); the software at-rest layer is what TCG `pmemsave` tests.

### P0/P1: Kill-Chain Defense (make iOS-class chains unreachable AND unusable)
Canonical design + per-stage matrix in `docs/architecture-defense-in-depth.md`.
Core invariant: every kill-chain stage is gated by a DIFFERENT, smaller, lower
component the attacker has not compromised and cannot reach. Stratify enforcers so
compromise of stage N yields nothing for N+1.

Stage gates to build (net-new beyond today's software floor):
- [ ] **User-space drivers**: move drivers out of the kernel into sandboxed
      processes with default-deny caps (drivers are in-kernel today). A driver
      holds NO direct I/O / kernel R/W.
- [ ] **Safe-proxy reference-monitor layer**: a driver/app reaches I/O, kernel
      R/W, or the monitor ONLY via a capability-bound request to a minimal proxy
      that re-derives authority from the CALLER's identity (no confused deputy).
- [ ] **One-shot ephemeral parser workers**: every untrusted-input decode
      (image/font/XML/SVG/packet) runs in a fresh near-zero-authority worker
      killed after one operation (kills the long-lived-daemon corruption class).
- [ ] **Opportunistic separation-monitor / hypervisor tier** above the always-on
      nk_monitor floor: VT-x/AMD-V + IOMMU when present for raw memory/IO/DMA
      gating; nk_monitor + mmio_bounds.inc when absent (detect+enable pattern).
- [ ] **Monitor-checked attested request trail**: privileged actions carry a
      provenance chain the monitor re-validates; a subverted kernel partition
      cannot forge it (it lacks the monitor key), so its grant is refused.
- [ ] **Threshold authority for dangerous runtime ops** (make-page-executable,
      grant-DMA, load-policy): no single partition authorizes - runtime
      co-approval (Track 2 threshold applied to operations, not just artifacts).
- [ ] **Information-flow labels**: no flow from a secret region to an exfil sink
      without a declassifier (extends the Track 3 non-interference invariant).
- [ ] **Shared-memory attested descriptor rings** for hot driver paths (validate
      the batch once; session-bound MACs after one-time setup; no per-op crypto)
      so the user-space-driver model keeps NIC/xHCI/framebuffer throughput.
- [ ] **Quarantine-and-restart** (MINIX-3-style) for any failed/over-budget/
      crashed component, with recovery authority in a separate partition, so
      fail-closed never means system-wedged.
- [ ] **Per-stage negative tests**: for each kill-chain row, a test that performs
      the stage-N compromise and proves stage N+1 is still independently blocked
      (the concrete proof that the chain cannot progress).

## Done Definition For This Program

- [ ] The trusted boot/security path is GHL/GritHLK-only.
- [ ] No new trusted-path `.asm` files exist.
- [ ] No new trusted-path `.inc` files exist.
- [x] No inline assembly or assembly escape hatches exist in trusted-path GHL.
- [ ] Every trusted artifact is signed and policy-bound.
- [ ] Every critical action requires the configured threshold approvals.
- [ ] One compromised key cannot authorize critical changes.
- [ ] One compromised kernel partition cannot grant unrelated authority.
- [ ] One compromised hypervisor partition cannot grant unrelated authority.
- [ ] One compromised driver cannot access unrelated device or memory authority.
- [ ] One compromised app cannot access unrelated app or private system state.
- [ ] One compromised update server cannot ship a trusted malicious update.
- [ ] Release builds contain no private logging or silent telemetry.
- [ ] Diagnostic mode is explicit, signed, temporary, scoped, visible, and
      revocable.
- [ ] Policy changes do not require updating most apps.
- [ ] Compatibility is handled through stable manifests and service APIs.
- [ ] Security docs, schemas, tests, and implementation agree automatically.
- [ ] Full verification reports the trusted path as clean.
