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
- [ ] Wire the broker entry points into the syscall dispatcher (a `SC_DRVHOST_*`
      family, default-deny in the slot allow bitmap; only driver slots get them).
- [ ] MMIO/DMA capability gates in `gritc` (the open `[ ]` items under "P0: GHL
      Compiler Security": "capability gates for MMIO operations" / "for DMA
      mapping" / "for device reset and firmware load") - these ARE the G1
      substrate; land them here.
- [ ] Track 3 invariant extension: `INV-DRIVER-NO-DMA-MINT` re-proven against the
      broker (a driver_id can only reach windows in its granted table).

## Rung 2 - First migration: `battery` / `acpi_ec`  **[DRIVER LANDED 2026-06-14]**

- [x] Ring-3 `--target driver` battery process: `src/drivers/acpi_ec/battery.ghl`
      requests only `CAP_PIO`, grants PIO over the EC index/data ports
      (0x62/0x66), and ports the EC read protocol + the A/B/C/D layout probing -
      reading battery percent/state via the broker `SC_DRVHOST_PIO_*` syscalls,
      NEVER raw `inb/outb`. Compiles broker-only under `--target driver` (no
      `unsafe`, no privileged intrinsic - G1 holds); asserted in
      `test_ghl_security_guards.ps1` + `test_gritc_security.ps1`.
- [ ] Wire `SC_DRVHOST_*` into the dispatcher (shared Rung-1 item) - until then
      the .asm stays live and is NOT deleted (same gate as the HDA driver).
- [ ] Delete `battery.asm` (and `acpi_ec.asm` if subsumed) + its
      `driver_inventory.txt` line (the shrink) - GATED on the dispatcher wiring.
- [ ] QEMU phase: battery status still reads correctly, sourced from ring 3.

  Canonical `SC_DRVHOST_*` ABI (one numbering across all driver-host processes):
  232 REGISTER, 233 GRANT_MMIO, 234 GRANT_DMA, 235 GRANT_IRQ, 236 GRANT_PIO,
  240 MMIO_READ32, 241 MMIO_WRITE32, 242 DMA_MAP, 243 IRQ_WAIT, 244 PIO_READ8,
  245 PIO_WRITE8, 246 RING_ESTABLISH, 247 RING_SUBMIT.

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

- [ ] Fault-budget accounting per driver; over-budget → quarantine (stop
      delivering IRQs/grants), restart via a separate recovery path.
- [ ] **Per-stage negative test**: compromise a driver (forge a request for a
      window outside its grant) and prove the broker refuses + the kernel's
      authority is unreachable - the concrete proof the chain cannot progress.
- [ ] Quarantine-restart test: kill a driver mid-operation, prove the system
      stays live and the driver comes back.

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
</content>
