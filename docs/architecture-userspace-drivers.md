# User-Space Driver Sandbox (Driver-Host Architecture)

Canonical design for moving Grit's device drivers **out of ring 0** and running
each one as a **ring-3, default-deny, capability-gated sandbox process** that
holds **no direct I/O, no MMIO mapping, no DMA authority, and no kernel R/W**.
A driver reaches hardware ONLY by sending a capability-bound request to the
in-kernel **driver-host broker**, which re-derives authority from the *caller's*
identity (no confused deputy), bounds-checks the request against that driver's
granted windows, performs the access itself, and returns the result.

This is the keystone of the "Kill-Chain Defense" section of
`docs/ghl-beyond-zero-trust-todo.md`: the safe-proxy layer, descriptor rings,
quarantine-and-restart, and the per-stage negative tests all assume drivers are
already ring-3 processes. Authority: this doc is the topology truth for the
driver sandbox; it refines (does not override) `architecture-defense-in-depth.md`
("Kernel-installed apps (drivers etc, as USER-SPACE processes)").

---

## 1. The four guarantees (what "very secure" means here, precisely)

| # | Guarantee | Mechanism | Enforced by (lower component) |
|---|---|---|---|
| G1 | A driver has **no ambient hardware authority** | Driver target compiles with **zero** privileged intrinsics; no `kernel_io`/`kernel_priv`/MMIO/DMA caps reachable from `--target driver` | `gritc` capability gate (compile-time) |
| G2 | A driver **cannot run in ring 0** | No driver binary is linked into the kernel monolith; the in-kernel driver inventory is **frozen + shrink-only**; new device code must be a driver-host process | repo guard `test_userspace_drivers.ps1` + build |
| G3 | A compromised driver **cannot reach memory it was not granted** | Every MMIO/DMA access is brokered: the kernel performs it after bounds-checking against that driver's `{base,len}` grant; default-deny, fail-closed | `driver_host.ghl` broker + `mmio_bounds.inc` registry |
| G4 | A crashed/abusive driver **cannot wedge the system** | Per-driver fault budget; over-budget → quarantine; restart authority is a separate path (MINIX-3 model) | `driver_host.ghl` quarantine FSM |

The point mirrors the defense-in-depth invariant: each stage of "compromise a
driver → escalate" is gated by a **different, smaller, lower** component the
driver cannot reach. Code-exec inside a driver yields nothing, because the
authority to touch hardware lives in the broker, not the driver.

> Honesty rule (carried from STATUS.md §9): the broker becomes part of the TCB.
> We do not claim safety after the broker itself is subverted; we keep it tiny,
> `--forbid-asm --deny-unsafe` except at named hardware boundaries, and
> invariant-checked (Track 3).

---

## 2. Topology

```
  ring 3   [ Driver process ]   memory-safe GHL, --target driver, default-deny.
           (xhci / rtl8156 /     Holds: a code hash, a cap_mask, and shared-memory
            i2c_hid / battery)   descriptor RINGS. Holds NO mapped MMIO/DMA/ports.
               │  capability-bound request (handle, not raw VA)
               ▼
  ring 0   [ Driver-host broker ]   driver_host.ghl. The ONLY path from a driver
                                     to hardware. Re-derives authority from the
                                     CALLER's driver_id, bounds-checks against the
                                     granted window, performs the access, returns.
               │  validated {base,len} access
               ▼
           [ mmio_bounds registry + port/DMA gates ]   fail-closed substrate.
               │
               ▼
              hardware (BAR / port / DMA window / IRQ line)
```

IRQs flow the other way: the kernel's vector stub does the minimal ACK, then
**forwards** the interrupt to the owning driver's IPC endpoint (a ring signal),
so the driver's ISR logic runs in ring 3, not in the kernel.

---

## 3. Capability model (default-deny, per-window)

A driver's authority is a `cap_mask` (coarse class bits) **plus** a set of
explicit `{base,len}` window grants (fine, per-device). The mask says *what kind*
of access is conceivable; a grant is what actually authorizes one region. No
grant ⇒ no access — absence denies (same doctrine as `mmio_bounds_assert`).

Capability classes (`driver_host.ghl`, `DRV_CAP_*`):

| Bit | Class | Authorizes |
|---|---|---|
| `MMIO`  | brokered MMIO | `drvhost_mmio_read/write` within a granted window |
| `PIO`   | brokered port I/O | `drvhost_pio_*` for a granted port range |
| `DMA`   | DMA window | a coherent buffer the broker maps for the device only |
| `IRQ`   | interrupt delivery | receive forwarded IRQ signals for a granted vector |
| `RING`  | descriptor rings | establish shared-memory batch rings |
| `RESET` | device reset | transient reset of the granted device; **threshold-gated** |
| `FWLOAD` | firmware load | persists past reboot - the most dangerous op; **threshold-gated**, never subsumed by `RESET` |

Grants come from the **signed driver policy** (the per-driver manifest, bound
into the Track 2 signed-everything chain), not from the driver asking nicely.
`drvhost_register` records the *requested* mask but only the policy-authorized
subset is ever effective: `effective = requested & policy_granted`. A driver that
requests `RESET` it was not granted gets a mask with that bit clear, and every
`drvhost_*_request` consults the granted table fail-closed.

---

## 4. Fast path (what "very fast" means here)

A per-request ring-0 round trip for every MMIO poke would be unusably slow on
hot paths (NIC TX/RX, xHCI TRBs, framebuffer flips). The design avoids it:

1. **Shared-memory descriptor rings.** The driver and broker share a ring of
   batch descriptors in a grant-bound buffer. The driver fills N descriptors and
   rings a single doorbell; the broker **validates the whole batch once**
   (each descriptor's `{off,len}` against the granted window) and executes it —
   amortizing the privilege transition over N operations, not 1.
2. **Validate-once grants.** A window is bounds-checked at grant time and stored
   pre-computed as `end = base+len` (the `mmio_bounds.inc` trick), so the
   hot-path check is two compares, no add.
3. **Session-bound integrity, not per-op crypto.** Cross-distrust attestation
   (the monitor trail) is established **once** at driver bring-up; steady-state
   ring traffic carries no asymmetric crypto. Capability checks on the in-machine
   hop are kernel-mediated (handle table), never MACed — per defense-in-depth
   rule #1 ("never MAC an already-capability-checked in-process hop").
4. **No per-byte copy where avoidable.** DMA-capable devices' payload buffers are
   the granted window itself; the broker validates descriptors, not bytes.

Perf gates (master TODO P1) bound the residual overhead; the NIC/xHCI/framebuffer
fast paths must stay within budget vs. today's in-kernel numbers.

---

## 5. Maintainability (what "very maintainable" means here)

- **One framework, many drivers.** Every driver speaks the same broker ABI
  (`drvhost_*`) and the same descriptor-ring layout. Adding a driver is writing a
  ring-3 GHL module + a signed manifest; it does **not** touch the kernel monolith
  or any other driver.
- **Schema-versioned ABI.** The ring descriptor and request structs carry an
  `abi_version`; the broker rejects unknown versions fail-closed, so the kernel
  and drivers can evolve on a stable contract (master TODO "App Compatibility").
- **Narrow surface.** The broker exposes a small, enumerated command set, not
  shared mutable state. Each command is independently testable with a hostile
  caller (a driver_id that was granted nothing).
- **Fail-closed isolation of churn.** A driver bug is quarantined and restarted;
  it cannot corrupt the broker or a sibling driver, so driver development does not
  destabilize the kernel.

---

## 6. Migration ladder (the order, and why)

Leaf, non-boot-critical, port-I/O-only drivers go first; latency-critical input
and display go last (long scar-tissue history: input-pump pacer, fb VBE overrun,
KASLR fixups — see project memory). Each rung is independently verifiable.

| Rung | Driver | Why this order |
|---|---|---|
| 2 | `battery` / `acpi_ec` | Simple EC port I/O, off every hot path; proves the broker + register + grant + read loop end to end with the lowest blast radius |
| 3 | `rtl8156` NIC | Hot path; proves descriptor rings + DMA brokering keep throughput (the hard perf case) |
| 4 | (framework) quarantine-and-restart + per-stage negative test | Proves G4 and that driver compromise ≠ kernel authority |
| 5 | `i2c_hid` / `xhci` / `display` | Latency-critical; migrate only once the framework is proven, to protect input/display responsiveness |

Boot-critical ordering: drivers needed *before* the broker exists (the boot
framebuffer via UEFI GOP, the ATA read of the kernel image) stay on their current
path until a recovery story exists; everything reachable after the broker is up
migrates.

---

## 7. Relationship to existing primitives

REUSED: `mmio_bounds.inc` (the `{base,len}` registry + fail-closed assert is
exactly the per-window grant substrate), the handle table (unforgeable caps, no
raw kernel VA crosses the boundary), the per-slot ring-3 sandbox + ASLR +
default-deny syscall gate (drivers are a *kind* of slot), the workqueue (IRQ →
deferred ring-3 work), Track 2 signed manifests (the driver policy is signed),
Track 3 invariants (`INV-DRIVER-NO-DMA-MINT` extends to the broker).

NET-NEW: the `driver_host.ghl` broker, the descriptor-ring ABI, the `--target
driver` compiler gate (G1), the in-kernel-driver freeze guard (G2), the
quarantine/restart FSM (G4), and the per-stage negative tests.
</content>
</invoke>
