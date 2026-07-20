# TODO / Spec Index - READ THIS FIRST

Single map of every TODO/spec/roadmap doc so a new session knows **which doc is
authoritative for what** and does not get tripped up by the sprawl. If two docs
disagree, the authority rules below win. Keep this file current when you add or
retire a doc.

_Last reconciled: 2026-07-17._

---

## Security/Speed scorecard + Path-to-10 (2026-06-23)

Each track now carries a **"Path to 10/10"** section (security-first; speed
maximized under security 10). Self-ratings — to be re-rated by an independent
audit agent, NOT trusted as final:

| Track | Security /10 | Speed /10 | 10/10 reachable? |
|---|---|---|---|
| 1 repo-enforcement | 8 | 10 | yes (sec→10 via reproducible-build + signed CI provenance) |
| 2 signed-everything | 10 software / HW-blocked | 7->8 | software complete; full zero-TODO closure blocked on NVMe/USB block backend |
| 3 seL4-invariants | 10 | 10 | complete; independently verified 2026-06-28 |
| 4 ram-erasure | 5 | 5→9 | **10 only where FME hardware present** (bounded) |
| 5 hw-monitor | 4 | 4→8 | **10 only where virt+IOMMU present** (the keystone) |
| 6 compartment-monitor | 6 | 6→8 | 10 with Track 5 (floor-disable residual) |
| 7 public-root | 9 | 9 | yes (QEMU boot + first-link SB) |
| 8 userspace-drivers | 7 | 6→8 | yes (finish migration ladder + quarantine) |
| 9 speed-isolation | 5 | **10** | sec inherited from Tracks 2/3/6/8 |
| 10 fpga-enclave | 6 | 5→7 | **bounded 10** (board + documented residuals; speed capped by USB latency) |
| 11 structural-cfi | 8 | 9 | 10 with Track 5/6 monitor |

**Global ceiling-lifter (do FIRST): Track 5 G1** — privilege-below-ring-0 makes the
shared `nk_monitor` root *un-disableable* in hardware. Until it lands, NO track can
exceed 9 (every track rests on that software root, per STATUS.md §9). Getting one
vendor (Intel VT-x) to `tested-accel` is what raises the whole stack's ceiling.

Honest bounds that are NOT faked to 10: Track 4/5/10 carry hardware/physical caps;
their "10" is explicitly conditional ("10 where FME / virt+IOMMU / board present").

---

## Authority hierarchy (who wins on a conflict)

1. **`docs/STATUS.md`** - formal source of truth for *project status* and the
   *security threat-model / scope boundary* (§9). Nothing overrides STATUS on
   "what is the state" or "what is in/out of scope."
2. **`docs/architecture-defense-in-depth.md`** - canonical *target topology*
   (separation-kernel, the kill-chain defense matrix, the capability-vs-crypto
   rule, opportunistic-hardware-with-software-floor rule). Nothing overrides this
   on "what is the intended architecture."
3. **The `trackN-*.md` docs** - authoritative for their slice of the
   beyond-zero-trust program, and **more current than the master list** where they
   overlap (the master list lags; trust the track doc).
4. **`docs/ghl-beyond-zero-trust-todo.md`** - the master program checklist
   (includes the newer "Extended Hardening" + "Kill-Chain Defense" + "Hardware
   Memory Encryption" sections). Authoritative only where no track doc covers it.
5. **`docs/security_todo.md`** - the *original* §1-§13 runtime hardening. All
   items LANDED. This is a different (earlier) program from the tracks - see
   "Two security programs" below.

---

## Two security programs (do not confuse them)

- **`security_todo.md` (§1-§13)** = the **landed runtime mitigations** baked into
  today's kernel (W^X, CPI, cap-mask HMAC, nk-monitor, KPTI/SMAP/CET scaffolds,
  heterogeneous syscall numbering, per-slot keys, measured boot + blob MAC, etc.).
  **All `[x]`** and live. It is *done*; treat it as the security baseline, not a
  backlog.
- **`ghl-beyond-zero-trust-todo.md` + `trackN` + `architecture-defense-in-depth.md`**
  = the **newer GHL-only "beyond zero trust" architecture** layered on top
  (signed-everything, threshold, seL4 invariants, RAM-only/secure-erasure,
  user-space drivers + proxies + monitor). This is the *active backlog*.

They are complementary, not duplicates: the tracks build the architecture; the
§1-§13 mitigations are the enforcement primitives that architecture reuses.

---

## Every doc, what it is, and current state

### Status & architecture (truth docs)
| Doc | Authoritative for | State |
|---|---|---|
| `STATUS.md` | project status; threat-model scope (§9, incl. the RAM-dump refinement) | current |
| `architecture-defense-in-depth.md` | target separation-kernel topology + kill-chain matrix | current (2026-06-04) |

### Active backlog - beyond-zero-trust program
| Doc | Scope | State (2026-06-04) |
|---|---|---|
| `ghl-beyond-zero-trust-todo.md` | master checklist + Extended Hardening + Kill-Chain Defense + HW mem-enc | active; master P0/P1 mostly `[ ]`; Extended/Kill-Chain are net-new |
| `track1-repo-enforcement-todo.md` | repo enforcement (no new .asm/.inc, presubmits, CI) | **DONE / green** |
| `track2-signed-everything-todo.md` | signed-artifact envelope + threshold | **software complete / HW-blocked** - envelope reader, real Ed25519 threshold signatures, boot/update/kernel/class call sites, persistent floors, device binding, reject matrix, fuzzing, and independent Worker A software verification are green. Full zero-TODO closure is blocked on the real NVMe/USB `blk_write_sectors` backend for cross-reboot floor persistence on those boot media. |
| `track3-sel4-validity-todo.md` | seL4-style authority invariants | **COMPLETE / CLOSED / independently verified 2026-06-28** - 21 invariants `proven` (4,576,644 evaluations), translation validation, planted-drift meta-tests, and P3 mapping done: authority bitmasks derived from real signed policy (`derive_authority.py`, 208 checks in the runner); proofs + containment claim table in `track3-invariant-proofs.md` |
| `track4-ram-secure-erasure-todo.md` | RAM-only/volatile + secure-erasure + HW FME (TME/SME) + leak≠elevation | **Software verification complete**: planted-leak + fail-closed `pmemsave` positive-control tests green; full whitening remains FME-hardware-gated |
| `track4-data-egress-elevation-matrix.md` | Part D leak≠elevation matrix: artifact × barrier, with code citations | **Static + dynamic audit DONE**: two-boot replay test and planted 128-bit stale-MAC rejection vectors green |
| `track5-hypervisor-monitor-todo.md` | **all-vendor hardware** monitor tier - the two irreducible-hardware guarantees only (G1 privilege-below-ring-0 to make the floor un-disableable; G2 IOMMU device-DMA), abstracted across Intel VT-x/VT-d, AMD SVM/AMD-Vi, ARM EL2/SMMUv3, RISC-V H-ext/IOMMU behind one `mon_hal` | **new, design only**; opportunistic; hardens Track 6 |
| `track6-compartmentalized-monitor-todo.md` | the **software "-1" monitor** decomposed into mutually-isolated single-authority compartments (PT/KEY/HASH/CAP/DMA/LOAD-MON) so one compromise ≠ total compromise; the non-hardware half of the final goal, TCG-verifiable | **new, design only**; the realizable core; Track 5 makes it un-disableable |
| `track8-userspace-drivers-todo.md` | the Kill-Chain keystone: **drivers as ring-3 default-deny sandbox processes** behind the in-kernel **driver-host broker** (`src/kernel/grithlk/driver_host.ghl`); design in `architecture-userspace-drivers.md` | **Rung 0+1 LANDED 2026-06-14**: design doc, broker framework (compiles `--target kernel --forbid-asm`), and **G2 enforcement** (`tools/security/driver_inventory.txt` freeze + `scripts/test/test_userspace_drivers.ps1`, wired into the entry point with a negative self-test) make a NEW in-kernel driver impossible. Next: Rung 1 G1 `--target driver` compiler gate + Rung 2 battery/acpi_ec migration |
| `track9-speed-isolation-microarea-todo.md` | sandboxed **speed-isolation prioritisation micro-area**: signed custom scripts running real-time "faster than perfect asm" (whole-program O3/QUBO codegen + runtime-tax removal) inside the Track 2/3/6/8 envelope; multi-core pin/isolate; broker-proxied optimised module/net access; target = server HFT + fast provably-fair RNG/result generation | **new, design only** (2026-06-14); not started |
| `track11-structural-cfi-memsafety-todo.md` | **structural CFI + memory-safety-by-construction**, replacing hardware PAC/CET with GHL-emitted, monitor-gated, vendor-neutral enforcement: L1 type-signature call tables (fine-grained forward edge), L2 SafeStack split (backward edge, removes the overwrite primitive vs detecting it), L3 spatial+temporal memory safety (the data-only/DOP class PAC/CET miss), L4 CFI-as-a-checked-theorem from the whole-program call graph. Stronger (no forgeable tags/keys, covers data-only), faster (1–3 ALU ops, mostly elided vs sign+auth crypto), portable (GHL + nk WP monitor). | **design COMPLETE** (2026-07-20; sketch 2026-06-23); implementation not started. Full design now grounded in real primitives (`table`/`call_table`, `buffer`/OOB-trap, `nk_pt_window`, the Track-3 `inv_*`/`.invariant`/`eval_*` vehicle): four layers broken into tagged phases (L1a–c, L2a–c, L3-spatial/temporal, L4a–b), cross-layer INV table, suggested landing order, done-definition. CODE-NOW = L1/L2/L3-spatial/L4; language-gated = L3-temporal. **L4b invariant model LANDED 2026-07-20 `proven`**: `inv_cfi_forward_target_in_set` / `inv_cfi_no_offset_entry` / `inv_safestack_return_unwritable` in `invariant_check.ghl` (+ `.invariant`/`.vectors` + exhaustive specs); the shared seL4 runner now proves **24 invariants** green (incl. meta-tests + `--forbid-asm --deny-unsafe` compile). Runtime L1-table / L2-SafeStack emission still not-started. Depends on GHL compiler + Track 5/6 monitor |
| `track10-fpga-secure-enclave-todo.md` | **USB-attached FPGA secure-enclave board**, always-on but **single-use-per-boot**: a Phase-A boot one-shot releases only a derived measurement-bound key, then a **triplicated hardware latch** gates the privileged opcodes off in silicon until power-cycle; Phase B serves only board-signed sign/RNG/counter/attest, with the **Track 5 monitor/hypervisor + IOMMU** exclusively owning the device so no ring-3 app (or compromised kernel) can reach it. Moves root-of-trust (Track 7)/anti-rollback floors (Track 2)/real TRNG off host CPU+DRAM; AEAD+nonce session channel; board-enforced (not host-text) required/optional policy. Beyond-iOS = one-transaction privileged window vs SEP's whole-session reachability. Includes threat model + non-goals (lab-physical = raised bar not guarantee) + an **open-problem section on the first-instruction bootstrap gap** (host measures itself; 5 candidate tiers A–E, recommended = B earliest-self-measurement-into-board, in-ethos; C/D vendor-TPM/DRTM only as optional opportunistic hardening) | **new, design only** (2026-06-14); not started; depends on Track 2/5/7/8 |

> **Track 10 status correction (2026-06-14):** software/design is complete: GHL
> phase/session/boot/host/service models, the ring-3 Phase-B driver, USB and
> supply/provisioning/power/bootstrap models, 61 RTL checks, post-synthesis
> secret-taint gates, and RTLIL/Verilog generation are green. Physical board,
> vendor programming reproducibility, and laboratory validation remain `[~]`.

### Landed baseline
| Doc | Scope | State |
|---|---|---|
| `security_todo.md` | §1-§13 runtime mitigations | **all `[x]` / live**; §5/§7 dispatcher wiring + §12 loader rewrite are now WIRED (2026-06-04) |

### Other backlogs (not part of the security program)
| Doc | Scope | State |
|---|---|---|
| `grithl-zero-asm-roadmap.md` | zero-asm migration (compiler track + verification) | active; kernel modules zero-asm; boot blocked on codegen |
| `grithl-boot-conversion.md` | boot module-by-module zero-asm ladder | active; blocked on PE/COFF + UEFI-ABI codegen |
| `maintainability-todo.md` | code maintainability backlog (`src/` only) | draft/working |

### Background / historical (not live checklists)
| Doc | What it is |
|---|---|
| `agent-beyond-zero-trust-security.md` | early vision note for the GHL-only architecture (superseded by the tracks) |
| `agent-ghl-no-asm-audit.md` | read-only audit findings (historical) |
| `reference-index.md` | index of *reference* docs (kernel/syscall/spec), not TODOs |

---

## Single verification entry point

```
powershell -ExecutionPolicy Bypass -File scripts\test\test_ghl_security_guards.ps1
```
Covers: release-privacy + no-asm + legacy inventory + policy-module compile
(`--forbid-asm --deny-unsafe`) + checker fixtures + seL4 invariants (now
vector-evaluated via `scripts\test\eval_invariants.py`).

Build: monolithic `nasm -f bin` on `src/kernel/kernel_build.asm` via
`scripts\build\build_uefi.ps1` (run from repo root). UEFI smoke:
`scripts\test\test_smoke_uefi.ps1`.

---

## GOTCHAS - known false alarms (do not chase)

- **`worktrees/` inventory failures (RESOLVED 2026-06-27 - stale note kept for
  history).** This used to EXIT 1 with ~400 `[new-legacy-extension]
  worktrees/...` findings from a stray untracked git worktree. It no longer
  happens: `tools/security/check_no_asm.ps1:127` now ignores the `worktrees`,
  `.claude`, `.git`, and `sandbox_shadow` prefixes, AND git-ignored paths are
  excluded via `git ls-files --others --ignored`, so a stray worktree produces
  zero findings. If `test_ghl_security_guards.ps1` exits 1, the cause is a REAL
  finding (e.g. a new `.asm/.inc` not in `legacy_asm_inventory.txt`, a toolchain
  pin drift after editing `gritc.py` - re-bake with
  `check_toolchain_pins.ps1 -Update` after review, or a reproducible-build digest
  drift - re-bake with `check_reproducible_build.py --update` after review), not
  worktree noise.
- **`security_todo.md` "SCOPED OUT / DEFERRED" notes are stale.** §5 (snapshot-on-
  open), §7 (net active-slot), and §12 (syscall-perm loader rewrite) were written
  as deferred but are **now wired** (each item carries an `_UPDATE (now LIVE)_`
  note). Do not re-implement them.
- **Master list lags the track docs.** Several `[ ]` items under
  `ghl-beyond-zero-trust-todo.md` "P0: Repository Enforcement" are actually DONE in
  `track1-*.md`. Trust the track doc.
- **QEMU TCG cannot test some features.** Hardware memory encryption (TME/SME),
  CET shadow-stack arming, and KPTI live-mode are no-ops or untestable under TCG.
  `pmemsave`/smoke tests validate only the software layers. Don't claim a
  hardware-gated feature works from a TCG boot.
- **GPU rendering is mostly deprecated.** `STATUS.md` "Active focus: GPU" predates
  the 2026-05-26 deprecation; Tier 2/3 (DCN/GFX11) are retired, only the portable
  Tier 1 survives. The real thrust is zero-asm + the security program.

---

## Current frontier (what to pick up next)

- **Track 2**: reader + reject matrix LANDED (2026-06-09); structural quorum +
  host writer LANDED (2026-06-09); P1 parser-safety suite (fuzz + differential
  decoder + canonical round-trip property, `scripts/test/fuzz_envelope.py`)
  LANDED (2026-06-10); **real Ed25519 threshold crypto LANDED (2026-06-10)**
  (`ed25519_check.ghl` in the kernel image, `envelope_verify_signed` entry
  point, real-signing writer, `eval_ed25519.py` in the guard suite); boot/
  update call sites + verified-artifact hash cache LANDED (2026-06-10,
  envelope_gate.ghl); **quorum-change tracking path LANDED (2026-06-10)** -
  staged KQUORUM.ENV requires BOTH old+new quorum approval
  (`security_threshold_change_valid` now enforced at a real call site) and
  ratchets the active per-class quorum for all later admissions; stolen-key
  negative suite (one key/build server/update server/recovery key) green.
  **RTC/now binding LANDED (2026-06-10)** - rtc_time.ghl (zero-asm CMOS RTC
  -> unix seconds) bound into the gate's verifier clock at K5, floor-clamped
  + forward-ratcheting; validity windows re-judged on every admit incl.
  hash-cache hits (eval_ed25519 §9 + QEMU phase 7: an expired-but-signed
  update is rejected with ENVR_ERR_WINDOW). **Persistent anti-rollback
  floors LANDED (2026-06-10)** - floor_store.ghl keeps the per-class
  version/counter/epoch minimums (+ the clock high-water) in a checksummed
  data.img sector (FLOOR_LBA=2, raw ATA PIO, fail-soft without IDE media);
  loaded at K5 before any admission, ratcheted by every accepted envelope,
  persisted after the call sites (eval_ed25519 §10 + QEMU phase 8: a v3
  admit in boot A makes a validly signed v2 inadmissible in boot B across
  a power cycle). **Loader-side KERNEL.BIN envelope LANDED (2026-06-10)** -
  the build signs SHA-256(KERNEL.BIN container) into a kernel-class 3-of
  KERNEL.ENV; the loader publishes it plus the pristine container read
  buffer (VBE 0xB0..0xC8); kernel_env_verify_boot (envelope_gate.ghl, K5)
  re-hashes and fail-closed compares ('KSG*' panics; QEMU phase 9 of
  test_track2_envelope_callsites.ps1 green). Track 2 software is COMPLETE;
  device_id and driver/config/policy class residuals are closed; the only
  remaining blocker is NVMe/USB-boot floor write-back behind the still-stubbed
  `blk_write_sectors` backend.
- **Track 3**: **COMPLETE / CLOSED / independently verified (2026-06-28)** - all 21 invariants `proven`
  AND the P3 mapping landed: `scripts/test/derive_authority.py` derives the
  authority bitmasks from the real signed policy (app manifests / policy graph
  / compiler unsafe caps over the signed build list / artifact-class quorums)
  and re-proves the invariants against them inside the Track-3 runner.
  Theorems, bounds, state counts, and the containment claim table live in
  `docs/track3-invariant-proofs.md` (read its honesty statement before
  claiming anything). Extensions follow its maintenance section without
  reopening the track.
- **Track 4**: the software-verifiable RAM-erasure work is complete. Part D's
  exfil→elevation matrix is backed by a two-fresh-boot replay test plus real
  128-bit stale/lane-corrupted cap-MAC rejection vectors. The `pmemsave` test
  now fails closed unless its runtime-only sentinel is absent from the immutable
  image, present before wipe, and absent after wipe. Remaining closure is the
  explicitly bounded hardware leg: software whitening cannot protect against a
  full one-shot DRAM dump while its mask co-resides in DRAM, so full protection
  still requires FME-capable TME/SME hardware and real-silicon validation.
- **Kill-Chain Defense**: biggest lift is moving drivers out of the kernel into
  user-space sandboxed processes - everything else in that section builds on it.
  **STARTED (Track 8, 2026-06-14)**: see `track8-userspace-drivers-todo.md` +
  `architecture-userspace-drivers.md`. Rung 0 (design) and Rung 1 (driver-host
  broker framework `driver_host.ghl`) landed; **G2 enforcement is live** - a new
  in-kernel driver is now impossible (frozen shrink-only inventory guard, wired
  into the security entry point with a negative self-test). **G1 `--target driver`
  compiler gate landed** (forces forbid-asm + deny-unsafe; ring-3 blocks
  privileged intrinsics; tests `driver_target_{ok,no_io,no_mmio}.ghl`). **Rung 2.5
  HDA audio CLASS driver landed** (`src/drivers/audio/hda.ghl`, broker-only;
  one driver ≈90% of machines because HDA+UAC are enumerable class standards and
  PCM needs no software codec - see `track8-audio-class-driver.md`; broker gained
  a DMA grant table). Remaining ladder: SC_DRVHOST_* dispatcher wiring, then the
  battery/acpi_ec → rtl8156 → input/display migrations, quarantine-restart, and
  the per-stage negative tests.
