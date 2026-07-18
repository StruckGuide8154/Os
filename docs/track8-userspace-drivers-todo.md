# Track 8 - User-Space Drivers TODO

> **Map of all docs: `docs/TODO-INDEX.md` (read it first).** Design/topology
> truth for this track is `docs/architecture-userspace-drivers.md`. This track
> realizes the "User-space drivers" keystone of the "Kill-Chain Defense" section
> of `ghl-beyond-zero-trust-todo.md` - *"everything else in that section builds
> on it."*

**Goal.** Every device driver runs as a ring-3, default-deny, capability-gated
sandbox process that holds **no** direct I/O, MMIO, DMA, or kernel R/W, and it is
**impossible** to add a new in-kernel driver. Drivers reach hardware only through
the in-kernel **driver-host broker** (`src/kernel/grithlk/driver_host.ghl`).

The four guarantees (see architecture doc §1): **G1** no ambient HW authority
(compile-time), **G2** cannot run in ring 0 (repo/build), **G3** cannot reach
ungranted memory (broker, runtime), **G4** crash ≠ wedge (quarantine/restart).

---

## Rung 0 - Design + enforcement floor  **[LANDED 2026-06-14]**

- [x] Architecture/topology doc (`docs/architecture-userspace-drivers.md`):
      driver-host topology, capability classes, fast-path descriptor rings,
      maintainability contract, migration ladder.
- [x] This track doc + index entry.
- [x] **G2 enforcement (impossible to run in kernel)**: freeze the in-kernel
      driver inventory shrink-only and block any new driver in
      `src/kernel/drivers/`. (`tools/security/driver_inventory.txt` +
      `scripts/test/test_userspace_drivers.ps1`; the guard fails on any `.asm`
      under `src/kernel/drivers/` not on the frozen list, so a *new* in-kernel
      driver cannot be added - it must be a driver-host process. The list is
      monotonic-shrink: a migrated driver is DELETED from it, never re-added.)

## Rung 1 - Driver-host broker framework  **[IN PROGRESS]**

- [x] Broker skeleton `driver_host.ghl`: driver process table, capability
      classes (`DRV_CAP_*`), default-deny grant tables, fail-closed brokered
      MMIO/PIO read/write, IRQ-route registration, descriptor-ring registry,
      quarantine/restart FSM. Compiles `--forbid-asm` (unsafe only at the named
      MMIO/PIO hardware boundary).
- [x] **G1 compiler gate** [LANDED 2026-06-14]: `gritc --target driver` exposes
      NO privileged intrinsic (inb/outb/ind/outd/write_cr*/lgdt/... already
      require `--target kernel`, so ring-3 = rejected) and forces
      `--forbid-asm` + `--deny-unsafe` ON non-overridably, so the module can
      declare no `unsafe kernel_io/kernel_priv/raw_mem` boundary. Load/store
      builtins stay usable but are MMU-confined to the driver's own pages (same
      as a `user` app). Tests: `tests/ghl_kernel/driver_target_{ok,no_io,no_mmio}.ghl`
      in `scripts/test/test_gritc_security.ps1`. Mirrors the
      `user_privileged_forbidden.ghl` gate for `--target user`.
- [x] Wire the broker entry points into the syscall dispatcher. **DONE
      2026-07-17:** fixed sparse rows `232..265`, `CAP_DRIVER`, caller-slot-
      derived identity, kernel-owned policy rows, linked broker, bounded/SMAP-
      bracketed ring submission, fail-closed control-plane rows, verified
      driver-slot creation, concrete grants, DMA mapping, IRQ events, and
      device-manager provisioning.
- [x] MMIO/DMA/reset/fwload capability gates in `gritc`: **MMIO + DMA LANDED
      2026-07-17; RESET + FWLOAD LANDED 2026-07-17 (same day).** `--target
      driver` requires explicit `capability mmio;` / `capability dma;` for the
      corresponding broker syscall families, requires both for DMA pointer
      programming through MMIO, and rejects dynamic syscall numbers so the
      check cannot be hidden. Device reset (row 264) requires `capability
      reset;` and firmware load (row 265) requires `capability fwload;` -
      deliberately split classes (`DRV_CAP_RESET`/`DRV_CAP_FWLOAD`), since
      loaded firmware persists past a reboot, so neither subsumes the other;
      both rows are reserved-only (control-plane denied) until the dispatcher
      wires them. Compiler declarations do not mint authority: signed policy +
      broker window grants still decide at runtime. Fixtures:
      `driver_target_{mmio,dma,reset,fwload}_cap_forbidden.ghl` +
      `driver_target_reset_fwload_ok.ghl` + the dynamic-syscall reject, all in
      `test_gritc_security.ps1`.
- [x] Track 3 invariant extension: `INV-DRIVER-NO-DMA-MINT` re-proven against the
      broker (a driver_id can only reach windows in its granted table). **DONE
      2026-07-17:** `scripts/test/eval_drvhost_dma_mint.py` interprets the REAL
      `driver_host.ghl` (production lexer/parser, emitted-code integer
      semantics, adversarial kernel-primitive stubs) - 98,259 checks across 6
      properties (containment soundness, grant gate/no-partial-mint, signed
      DMA ceiling, pointer-programming no-mint incl. sibling windows,
      cross-grant controller gate, map-own-base-only), plus a planted-broken-
      broker selftest; wired into `test_ghl_security_guards.ps1`. Proof table:
      `docs/track3-invariant-proofs.md` §1b.

## Rung 2 - First migration: `battery` / `acpi_ec`  **[DRIVER LANDED 2026-06-14]**

- [x] Ring-3 `--target driver` battery process: `src/drivers/acpi_ec/battery.ghl`
      requests only `CAP_PIO`, grants PIO over the EC index/data ports
      (0x62/0x66), and ports the EC read protocol + the A/B/C/D layout probing -
      reading battery percent/state via the broker `SC_DRVHOST_PIO_*` syscalls,
      NEVER raw `inb/outb`. Compiles broker-only under `--target driver` (no
      `unsafe`, no privileged intrinsic - G1 holds); asserted in
      `test_ghl_security_guards.ps1` + `test_gritc_security.ps1`.
- [x] Complete the shared Rung-1 runtime path (driver slot + concrete PIO
      grant). **DONE 2026-07-17:** the signed kind-2 battery package is installed
      in slot 10, receives only ports `0x62..0x66`, runs its one-shot probe, and
      publishes bounded periodic status through the driver callback path.
- [x] Delete `battery.asm` + its `driver_inventory.txt` line (the shrink).
      `acpi_ec.asm` remains only for EC dump/thermal APIs not subsumed here.
- [~] QEMU phase: UEFI smoke boot is green with the ring-3 package installed and
      the absent-EC fallback remains live; hardware/firmware with a real EC is
      still required to assert a changing taskbar percentage end to end.

  Canonical `SC_DRVHOST_*` ABI (one numbering across all driver-host processes):
  232 REGISTER, 233 GRANT_MMIO, 234 GRANT_DMA, 235 GRANT_IRQ, 236 GRANT_PIO,
  240 MMIO_READ32, 241 MMIO_WRITE32, 242 DMA_MAP, 243 IRQ_WAIT, 244 PIO_READ8,
  245 PIO_WRITE8, 246 RING_ESTABLISH, 247 RING_SUBMIT, 248 PCI_CFG_READ32,
  249 GRANT_MMIO_FOR, 250-253 MMIO_RD8/16/32/64, 254-257 MMIO_WR8/16/32/64,
  258 MMIO_WR_DMAPTR, 259-262 PIO_RD/WR16/32, 263 NET_RX,
  264 DEVICE_RESET (reserved, `capability reset;`),
  265 FW_LOAD (reserved, `capability fwload;`).

## Rung 2.5 - HDA audio CLASS driver  **[DESIGN + DRIVER LANDED 2026-06-14]**

> Full design + status: `docs/track8-audio-class-driver.md`. One driver covers
> ~90% of machines because HDA (controller) + UAC (USB) are enumerable class
> standards and basic PCM playback needs no software codec. Chosen as the DMA-
> ring proving ground BEFORE the NIC: same hard mechanism (descriptor rings via
> the broker DMA grant), lower blast radius (off the input/display hot path).

- [x] Broker DMA grant table: `drvhost_grant_dma` + `drvhost_dma_contained`
      (`driver_host.ghl`) - the broker mints/maps a coherent window and proves any
      device-physical base/len a driver programs lies inside its own grant.
- [x] `src/drivers/audio/hda.ghl` (`--target driver`, broker-only): controller
      reset, CORB/RIRB DMA rings, generic codec discovery (STATESTS -> AFG ->
      widget scan for a DAC + output-capable pin), path route + unmute, 2-entry
      double-buffered BDL, output stream start. Compiles + asserted in the
      security guard.
- [ ] Wire `SC_DRVHOST_*` into the dispatcher (shared Rung-1 item) so the driver
      can call the broker at runtime; QEMU `-device intel-hda -device hda-output`
      plays PCM sourced from ring 3.
- [ ] Capture (ADC) path + ring-3 mixer; signed quirk table for jack/amp
      exceptions; UAC (USB Audio Class) companion over xHCI (Rung 5).

## Rung 3 - `rtl8156` NIC (hot path, descriptor rings)  **[DRIVER LANDED 2026-06-14]**

- [x] Ring-3 `--target driver` NIC process: `src/drivers/net/rtl8156.ghl`
      requests `CAP_MMIO|CAP_DMA|CAP_IRQ|CAP_RING`, grants its MMIO window + a
      DMA buffer, and drives TX/RX as broker-brokered descriptor-ring batches:
      TX = fill payload (CPU write, no syscall) + one `RING_SUBMIT` per frame;
      RX = `RING_ESTABLISH` a bulk-IN against the pre-authorised buffer, block on
      `IRQ_WAIT` (forwarded xHCI transfer event), then walk the RTL aggregate
      buffer entirely in ring 3 (validate-once, no per-frame syscall - arch §4).
      Controller/PHY init ported from the .asm. Compiles broker-only under
      `--target driver` (no `unsafe`, no privileged intrinsic - G1 holds);
      asserted in both security guards.
- [ ] Wire `SC_DRVHOST_*` (incl. RING_ESTABLISH/SUBMIT 246/247) into the
      dispatcher; until then the .asm net path stays live (not deleted).
- [ ] Net selftest (`net_selftest`) green with the NIC driven from ring 3.
- [ ] Perf gate: TX/RX throughput within budget of the in-kernel baseline.

## Rung 4 - Quarantine-and-restart + negative tests (G4 + the proof)

- [x] Fault-budget accounting per driver; over-budget → quarantine (stop
      delivering IRQs/grants), restart via a separate recovery path. Rejected
      data-plane results and ring-3 driver exceptions charge the same broker
      budget; recovery replays policy-derived grants instead of stale grants.
- [x] **Per-stage negative test**: `eval_drvhost_quarantine.py` forges a write
      exactly outside the granted window, proves `DRV_ERR_GRANT`, proves no raw
      MMIO event occurred, drives eight faults to quarantine, and proves revoked
      authority remains unreachable. Its planted-accounting-break selftest must
      also fail the proof.
- [~] Quarantine-restart test: the executable host proof covers quarantine,
      revocation, separate restart, and no stale-grant resurrection; UEFI smoke
      covers the integrated exception/recovery wiring. A boot probe that kills a
      live device driver mid-operation is still outstanding.

## Rung 4.5 - Stable class ABI + scale foundation

- [x] Common v1 opaque class handle: registry entry, class kind, negotiated ABI
      version, authoritative owner, and 31-bit restart generation. Every field
      is revalidated against kernel-owned rows; sign-bit and generation-wrap
      inputs fail closed, and duplicate live owner/class publication is denied.
- [x] Fixed-capacity 64-endpoint registry supports multiple devices of the same
      class without new syscalls or raw function-pointer publication. Quarantine
      revokes all endpoints before recovery; health-checked republish mints a
      fresh generation.
- [x] First live `net.l2` endpoint: the ring-3 VirtIO backend publishes MTU and
      feature metadata only after ready/DMA/IRQ/MAC setup succeeds, and TX
      resolves the generation-safe handle before using the driver.
- [x] Executable proof + planted-bug selftest (`eval_drvclass_handles.py`) covers
      field forgery, metadata bounds, quarantine, restart, stale handles, fresh
      republish, and generation exhaustion.
- [ ] Define typed common message/event headers and move the remaining legacy
      NIC ops consumers fully onto the opaque class endpoint.

## Rung 5 - Input + display (latency-critical, last)

- [ ] `i2c_hid`, `xhci`, `usb_hid` → driver processes (protect input latency;
      heed the input-pump/pacer history before touching the hot path).
- [ ] `display`/`fbperf` → driver process behind a framebuffer ring (heed the FB
      VBE-MMIO-overrun and KASLR-fixup scar tissue).
- [ ] Final: the in-kernel `src/kernel/drivers/` set is empty of device drivers;
      `driver_inventory.txt` lists only boot-critical pre-broker stubs (if any).

## Done definition

- [ ] No device driver runs in ring 0; the in-kernel driver inventory is empty
      of post-broker drivers and the freeze guard is green.
- [ ] `--target driver` provably cannot emit a privileged intrinsic (G1 tests).
- [ ] Every driver→hardware access is brokered, bounds-checked, default-deny (G3).
- [ ] A compromised/crashed driver is contained + restartable, proven by the
      per-stage negative + quarantine tests (G4).

## Path to 10/10 (security-first; speed maximized under that)

Self-rating now: **security 7 / speed 6**. The keystone: G1/G2 gates + the HDA
class driver landed and a new in-kernel driver is impossible, but most drivers still
run in-kernel until the migration ladder finishes.

- [~] **(sec→10)** Driver syscall foundation is linked and default-deny; finish
      verified driver slots, device-manager grants, DMA mapping, and IRQ events.
- [ ] **(sec→10)** Finish the ladder: battery/acpi_ec → rtl8156 → i2c_hid/xhci/
      usb_hid/display to ring-3; delete each `.asm` + its inventory line.
- [ ] **(sec→10)** Rung 4: fault-budget quarantine-and-restart + the per-stage
      negative test (forged out-of-grant request refused, kernel authority unreachable).
- [x] **(sec→10)** Re-prove `INV-DRIVER-NO-DMA-MINT` (Track 3) against the broker.
      (eval_drvhost_dma_mint.py, 98,259 checks + selftest - see Rung 1.)
- [ ] **Verify:** an independent agent re-rates this track **security 10**.
- **(speed→max under sec 10)** Validate-once batched descriptor rings (TX = one
      submit/frame, RX = walk in ring-3, no per-frame syscall) keep the hot path fast;
      gate TX/RX throughput within budget of the in-kernel baseline. Target speed **8**
      (the ring-3 broker crossing has irreducible but amortizable cost).
</content>
