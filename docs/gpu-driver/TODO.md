# Grit GPU Driver — Spec & TODO (general AMD amdgpu, ring-3, compartmentalized)

Status: **ACTIVE** (un-deprecated 2026-06-23). Supersedes the retired single-model
780M bring-up, preserved for reference at `reference-780M-asm/`.

Goal: a **general** AMD GPU driver (every lineup, ~one day of effort per new IP
generation) that delivers **detection → display scanout → accelerated 2D**, built
to Grit's invariants: **zero-asm GHL**, **ring-3 sandboxed**, **compartmentalized so
no level of compromise reaches the rest of the driver, other drivers, or the kernel**,
and dispatched by an **independent device controller** (PnP) the way the net stack
binds a NIC — so multiple GPUs / multiple driver versions never conflict.

---

## 0. Non-negotiable architecture constraints

These override convenience. Every task below must hold all of them.

1. **Zero-asm.** All driver logic is GHL. No `.asm`, no asm shims. New device code
   is forbidden in-kernel by the Track-8 guard (`tools/security/driver_inventory.txt`);
   the GPU driver is a **ring-3 driver-host process**, full stop. The retired asm in
   `reference-780M-asm/` is **reference only** — transliterate the *sequences* into
   GHL from amdgpu headers, do not resurrect the asm.

2. **No ambient authority.** The driver holds no mapped MMIO, no DMA, no port I/O,
   no kernel R/W. Every hardware touch goes through `src/kernel/grithlk/driver_host.ghl`
   (the broker), keyed by the caller's `driver_id`, bounds-checked against signed,
   policy-granted `{base,len}` windows. Absence denies. See
   `docs/architecture-userspace-drivers.md` (G3).

3. **Compartmentalization (the headline requirement).** Split the driver into
   independent ring-3 compartments so that a full code-exec compromise of *any one*
   gains **nothing** toward the others, the system, or the kernel. See §3.

4. **Minimal TCB.** The only new kernel-side code is broker grants + the PnP bind
   table (§4). Both are tiny, table-driven, fail-closed, and outside any
   ring-3-writable slot. `unsafe` only at the named MMIO/DMA boundary.

5. **Spec-first & maintainable.** Each IP block (GMC/PSP/GFX/DCN/SDMA) gets a written
   contract (registers used, sequence, wait-conditions, failure modes) BEFORE code,
   so a new lineup is a data swap against a stable spec, not a re-derivation.

6. **Generality over per-model.** No hardcoded per-chip offsets. Everything keys off
   the GPU's own **IP-discovery table** + per-IP-version generated register maps. The
   unit of work is the **IP version** (e.g. `gfx_v11`), not the SKU.

---

## 1. Salvage map — what transfers from the 780M work

Scored against a *general* driver. Reuse the verified plumbing; **redo** the rungs
that hit the probe wall, this time transliterated from amdgpu source/headers.

| Subsystem | 780M state | Action |
|---|---|---|
| PCI detect + BAR map | working | **port → GHL**, generalize to PnP (§4) |
| SMN proxy (NBIO INDEX2/DATA2) | **verified silicon** | **port → GHL** as-is; it's the master key |
| SMU/MP1 mailbox + msg IDs | **verified** | **port → GHL**; keep msg table per-IP-version |
| IP-discovery decode | parsed, not e2e | **port + finish**; make it the dispatch source |
| PSP fw-load | unresolved (MP0 seg) | **REDO from `psp_v13_0.c`** using discovery base, not Linux header constant |
| GMC (VRAM + GART) | scaffolding only | **BUILD NEW** — real long pole, no prior art |
| CP ring + PM4 NOP | never retired | **REDO from `gfx_v11_0.c`** |
| Accelerated 2D blit | not started | new |
| DCN display/scanout | probe + DMUB diag only | new (programmed scanout) |
| Generality / extractor | none | new (§5) |

Firmware blobs in `reference-780M-asm/firmware/` (`PHX*.BIN`, `DCN*`, `GC*`) are
AMD-signed and redistributable — keep, but load **by firmware-header**, never by
hardcoded layout.

---

## 2. Milestone ladder (each rung gates the next; verify on HW before claiming done)

- [~] **M0 — PnP detect.** Controller **ported to GHL** in `src/drivers/gpu/gpu_pnp.ghl`
      (compiles `--target driver`): brokered PCI walk, signed match table, unique instance
      ids + exclusive BAR ownership (refuses dup/overlap), fail-closed. ~85%.
      `DRV_CAP_PCICFG=64` + `drvhost_pci_cfg_read32` + `drvhost_grant_mmio_for` are now
      LANDED in `driver_host.ghl` (2026-07-01, build-green: compiles `--target kernel
      --forbid-asm`, `gpu_pnp.ghl` compiles `--target driver` against the real broker
      calls) — but **the kernel's actual syscall dispatcher does not yet route to any
      of the GHL broker functions in `driver_host.ghl`** (see new §2c). Until that
      lands, M0 does not run against real hardware even though every GHL-side piece
      is now correct and gated. Still needs the spawn IPC (§3) before per-instance
      grant routing can be exercised end-to-end.
- [~] **M1 — Plumbing.** BAR map (brokered) + SMN proxy + SMU mailbox **ported to
      GHL** in `src/drivers/gpu/amdgpu.ghl` (compiles `--target driver`, broker-only).
      Pending real-HW re-verify (asm versions were HW-verified on Strix Point).
- [~] **M2 — IP discovery.** Self-enumeration parser **ported to GHL** (same file).
      Code-complete; needs FB-window grant from PnP + a broker bulk-scan primitive
      (perf TODO) + e2e validation on silicon.
- [~] **M3 — PSP fw-load.** **Ported to GHL** in `src/drivers/gpu/amd_psp.ghl` (compiles
      `--target driver`): SOS probe → GPCOM ring → SETUP_TMR → LOAD_IP_FW, fw-by-header,
      DMA-contained staging. ~70% code-complete. THE FIX for the prior stall: MP0 base is
      discovery-derived (`psp_resolve_mp0`), not the hardcoded Linux constant.
      `DRV_CAP_RESET=32` already existed in `driver_host.ghl`'s generic capability mask
      (`drv_has_cap` gates any bit uniformly, so requesting/holding it was already
      functional) — confirmed 2026-07-01, no code change needed there. What's still
      open: CAP_RESET does not gate any *specific* reset primitive yet (no
      `drvhost_*reset*` function exists — the bit is requested by `amd_psp.ghl` but
      nothing in the broker branches on it specially today), and real silicon
      (0% HW-verified). Open: BAR0 over-grant for the SMN proxy wants a dedicated
      MP0-only broker primitive (§2b stretch item, not attempted this session).
- [~] **M4 — GMC/GART.** **Ported to GHL** in `src/drivers/gpu/amd_gmc.ghl` (compiles
      `--target driver`): DMA-contained flat GART PT, GFXHUB VM-context-0 program + TLB
      invalidate + fault capture, `gart_map/unmap/flush` (the double-gate choke point),
      GTT accounting. ~80% codeable. Deferred: MMHUB, VRAM-size readback, multi-level PT.
      0% HW-verified. GC base from IP-discovery (`ipd_gc`), not hardcoded.
- [ ] **M5 — CP ring NOP retires.** The historic wall. PM4 NOP submitted + retired.
- [ ] **M6 — Accelerated 2D blit.** PM4 copy into a surface.
- [ ] **M7 — Scanout.** DCN programs that surface to the display (or hand to GOP FB).
- [ ] **M8 — Generality.** Second lineup (GFX10 or GFX12) bound + 2D, mostly by
      re-running the extractor (§5). Proves the one-day-per-lineup claim.

Honest baseline today (from the deprecated work): **~12–15% toward general 2D**
(~30% toward single-model). Easy rungs (M1/M2) front-loaded; M3–M6 are the hard 70%.
This session (2026-07-01) closed the M0 GHL/broker-layer gaps in §2b (PCI-config read
primitive, per-instance grant routing) but did NOT move the runtime percentage: §2c's
newly-found syscall-dispatch gap means M0 still cannot execute against real hardware
or QEMU, so "runs end-to-end" is not yet true for any Track-8 driver, GPU included.

---

## 2b. Integration debt (broker/kernel side — assumed by the ported compartments)

The M0/M3/M4 GHL compartments compile and are self-consistent. Status as of 2026-07-01:

- [x] **`SC_DRVHOST_PCI_CFG_READ32` broker primitive — GHL-side LANDED.**
      `driver_host.ghl` now defines `DRV_CAP_PCICFG = 64` and
      `drvhost_pci_cfg_read32(id, bus, dev, func, reg)`: bounds-checks bus∈[0,255],
      dev∈[0,31], func∈[0,7], reg∈[0,255], assembles the CF8 address itself
      (`0x80000000 | bus<<16 | dev<<11 | func<<8 | (reg&0xFC)`), does the
      out-dword-0xCF8/in-dword-0xCFC access, and returns the dword — gated by
      `drv_has_cap(id, DRV_CAP_PCICFG)`, default-deny (open-bus 0xFFFFFFFF) on any
      failure, exactly mirroring `drvhost_mmio_read32`'s deny convention. Raw port
      I/O stays entirely inside the broker; `gpu_pnp.ghl` never touches 0xCF8/0xCFC.
      Compiles `--target kernel --forbid-asm` (build-green). **Read-only by design**
      — no config-space write primitive was added (out of threat-model reach for a
      PnP controller; see the module comment for why).
- [x] **`CAP_RESET = 32` — was already broker-functional, verified not fictional.**
      `driver_host.ghl`'s `drv_has_cap`/`drvhost_register` gate ANY capability bit
      generically (intersection of requested & signed-policy mask), so `CAP_RESET`
      already worked exactly like every other bit the moment `amd_psp.ghl` requested
      it — this was not actually blocked, just under-documented. Still genuinely
      open: no `drvhost_*reset*` function branches on it specifically yet (there is
      no reset primitive to gate — `amd_psp.ghl`'s M3 sequence today only needs
      MMIO+DMA, both of which do work). Revisit once M3 needs an actual PSP/engine
      reset op that should be CAP_RESET-gated.
- [x] **Per-instance grant routing — GHL-side LANDED, still blocked on spawn/IPC.**
      Added `drvhost_grant_mmio_for(granter, target, base, len)` to `driver_host.ghl`:
      only succeeds if `granter` holds `DRV_CAP_PCICFG` (i.e. is the signed PnP
      controller), then applies the *existing* `drvhost_grant_mmio(target, ...)`
      capability/bounds checks against `target` unchanged — so PnP can route a grant
      to a DIFFERENT driver_id than its own, but only once it knows that id.
      `gpu_pnp.ghl`'s `pnp_assign_instance` no longer calls the old (buggy)
      self-granting `SC_DRVHOST_GRANT_MMIO` at all; it records `inst_engine_id =
      ENGINE_ID_UNSPAWNED` (0) per instance and leaves the grant unrequested. The
      new `pnp_bind_engine_instance(iid, engine_driver_id)` is the wired completion
      path (`SC_DRVHOST_GRANT_MMIO_FOR = 249`) but is **not yet called from `main()`**
      because no compartment-spawn/IPC primitive exists anywhere in this codebase
      (confirmed by search — §3's "spawn/bind the compartment set" is still 0%
      built). This is now correctly a NO-OP (no mis-grant to PnP's own id, no grant
      at all) rather than the previous placeholder bug that would have granted GPU
      MMIO to the PCI-config-only PnP compartment.
- [ ] Consider a narrow **MP0-only SMN-proxy** broker primitive so `gpu-fwload` need not
      be granted all of BAR0 just to reach the SMN INDEX2/DATA2 pair (flagged in amd_psp.ghl).
      Not attempted this session (stretch item).
- [ ] FB bulk-scan / FB-VA-map primitive so IP-discovery isn't ~1M brokered read32s (M2).
      Not attempted this session (stretch item).
- [ ] Compartment spawn/IPC path (§3) — required before `pnp_bind_engine_instance` can
      ever be called with a real `engine_driver_id`. Not attempted this session; no
      spawn primitive of any kind exists in the codebase today (verified by search).

## 2c. NEW FINDING (2026-07-01): the SC_DRVHOST_* syscall family is not routed by the
real kernel dispatcher — this blocks ALL userspace drivers, not just GPU

While wiring the above, found that `syscall(SC_DRVHOST_REGISTER, ...)` etc. (numbers
232–236, 240–248/249) are **not present as rows in the kernel's actual syscall
dispatch table** (`src/kernel/proc/syscall_support.inc`'s `syscall_table:`, a dense,
POSITIONAL array where row index == syscall number — currently ~84 entries, nowhere
near 232). There is no sparse/gap-filled dispatch, no jump table, and no reference to
any `drvhost_*` function anywhere under `src/kernel/proc/` or `src/include/` — the
outer app-manifest capability system (`src/include/syscall_caps.inc`, `CAP_CORE` /
`CAP_FS` / … / `MANIFEST_*`) also has no `CAP_PCICFG` bit or driver-process manifest
class, only GUI-app manifests (Explorer, Terminal, …).

**This is not new to the GPU work and not GPU-specific.** `rtl8156.ghl`, `hda.ghl`,
and `battery.ghl` already assume the identical unwired `SC_DRVHOST_*` numbers — the
whole Track-8 driver-host broker is validated ONLY at compile-time
(`--target driver` compiles broker-only, checked in `test_ghl_security_guards.ps1`),
never actually exercised against the real dispatcher. Every "ported to GHL, 0%
HW-verified" note across rtl8156/hda/battery/GPU has been accurately hedged, but the
size of this specific gap (dispatcher wiring, not just device bring-up) was not
previously called out explicitly.

Closing it needs (separate, larger effort, cross-cutting across every Track-8
driver, not scoped to this session):
- [ ] Extend `syscall_table` (`syscall_support.inc`) with real rows for 232–236 and
      240–249, each wrapping a `driver_host.ghl` function via a `syscall_entry.*`
      handler (following the existing `SYSCALL_ENTRY` macro convention).
- [ ] Add a `CAP_PCICFG`-equivalent (or reuse a driver-class capability) to the OUTER
      `syscall_caps.inc` CAP_* / manifest system so a driver-process app_id can be
      declared and gated the same way GUI apps are.
- [ ] Decide how ring-3 driver PROCESSES get an app_id / slot / manifest at all —
      today `app_manifest_table` only has GUI app rows (Explorer..Shell); there is no
      "driver" app class.

Until this lands, M0–M4 across every Track-8 driver (not just the GPU compartments)
are GHL-correct and broker-gated but **do not execute against real hardware or even
real QEMU I/O** — `syscall(SC_DRVHOST_*, ...)` calls a number the dispatcher does not
route.

## 3. Compartmentalization design (the security spine)

Run the driver as **several** cooperating ring-3 processes, not one. Each is a
separate `driver_id` with its own minimal broker grant. A compromise is contained to
the windows that compartment was granted — it cannot read/write another
compartment's MMIO, cannot widen its own grant, and cannot reach the kernel.

Proposed compartments (each = own driver_id, own signed policy, own grant set):

| Compartment | Granted authority (broker windows) | If compromised, blast radius |
|---|---|---|
| `gpu-pnp` (controller) | PCI config read only | cannot touch GPU MMIO at all |
| `gpu-fwload` (PSP) | MP0 window + the fw DMA staging buffer only | can load fw; cannot drive GFX/DCN, cannot see VRAM |
| `gpu-mem` (GMC/GART) | GMC regs + page-table DMA region only | controls GART; **cannot** submit CP work or scan out |
| `gpu-gfx` (CP/PM4) | GFX doorbell + ring buffer DMA only | can submit blits **only into GART-mapped, GMC-approved pages** |
| `gpu-display` (DCN) | DCN regs + scanout surface only | can change what's on screen; cannot touch GFX or VRAM mgmt |

Cross-compartment rules (enforced by broker + IPC, default-deny):

- **No shared writable memory.** Compartments exchange *handles/offsets*, brokered;
  one compartment cannot hand another a pointer outside its own grant.
- **DMA is double-gated.** `gpu-gfx` can only ring work whose target pages were mapped
  by `gpu-mem`; `drvhost_dma_contained` confines all DMA to IOMMU-confined regions
  (broker G2). A compromised `gpu-gfx` cannot DMA over the kernel or another driver.
- **Faults are local.** `drvhost_fault`/`drvhost_quarantine`/`drvhost_restart`: a
  crashed/quarantined compartment is restarted without taking down the others or the
  GPU (matches NO-FREEZE invariant — loop or fail, never wedge the system).
- **Authority is signed, not requested.** Effective caps = `requested & policy_granted`;
  the broker never widens on request. (Track 2.)

Net: compromise at the **lowest** level (`gpu-fwload` running attacker fw) is boxed to
the PSP staging window; compromise at the **highest** level (`gpu-display`) can only
corrupt pixels. Neither reaches the kernel, the other compartments, or other drivers.

> Open question to resolve in design review: compartment count vs. IPC overhead. Start
> coarser (pnp / engine / display = 3) if 5-way IPC is too chatty, but keep `gpu-fwload`
> and `gpu-mem` separate from `gpu-gfx` — those three boundaries carry the real security
> value.

---

## 4. The device controller (PnP) — independent identify-and-bind, like the net stack

A standalone controller process owns device→driver binding so multiple GPUs and/or
multiple driver versions never conflict (the explicit requirement). Mirrors how a NIC
gets matched and claimed.

- **Match table (signed, data-driven):** `(vendor_id, device_id-range, IP-version) →
  driver package`. AMD = `0x1002`. New SKUs that report a known IP version bind the
  existing driver with **no code change**.
- **Claim/ownership:** controller assigns each detected device a unique instance id and
  exclusive ownership of its BAR windows; a second matching driver instance is refused
  the same windows (broker grants are per-instance) — **no conflict possible** even
  with two AMD GPUs or a stale driver build present.
- **Independent identification:** binding is decided by *what the device reports* (PCI
  ids + IP-discovery version), not by load order or hardcoded assumptions, so it
  generalizes to unseen SKUs and coexists with future Intel/NVIDIA drivers under the
  same controller.
- **Kernel side stays tiny:** the controller is ring-3; the kernel only holds the bind
  table + per-instance window grants (fail-closed, outside ring-3-writable slots).

TODO:
- [ ] Define the signed match-table format + loader.
- [ ] Controller process: enumerate → match → assign instance id → request per-instance
      broker grants → spawn/bind the compartment set (§3) for that instance.
- [ ] Conflict tests: two AMD devices; duplicate driver; unknown device (must fail-closed).

---

## 5. The transliteration extractor (generality engine)

Python tool (beside `gritc.py`) so a new lineup is a data swap, not a rewrite. Splits
amdgpu into **data** (auto-generated, per-version, parseable) and **logic** (small,
hand-ported once per generation).

- [ ] **Header parser** → `*_offset.h` / `*_sh_mask.h` → GHL `const` register maps.
- [ ] **Init/golden-table extractor** → C `{reg,mask,val}` arrays → GHL data tables the
      generic runtime replays.
- [ ] **Firmware-header binding** → generate `common_firmware_header` offsets so the
      loader places segments generically (port once).
- [ ] **Bootstrap on GFX11**, then validate by regenerating GFX11 and diffing against the
      hand port; then point at GFX10/GFX12 headers to prove one-day-per-lineup.
- Pin a specific amdgpu/linux-firmware tag; AMD reorganizes headers occasionally.

Hand-written generic runtime (logic, built once, generation-agnostic): MMIO/SMN, ring
submit, GART fill, fence poll, PSP handshake. ~few thousand GHL lines.

---

## 6. Suggested build order

1. M0 controller + M1 plumbing in GHL (high reuse, testable in QEMU). Establishes the
   compartment skeleton + broker grants early so security isn't bolted on later.
2. M2 IP discovery → wire as the dispatch source.
3. M4 GMC/GART **before** M3/M5 chasing — it's the long pole and de-risks everything.
4. M3 PSP fw-load (from `psp_v13_0.c`, discovery base).
5. M5 CP ring NOP → M6 blit → M7 scanout.
6. M8 second lineup via the extractor.

> Reality check (do not delete): none of M3–M7 can be *claimed done* without running on
> real AMD silicon — they fail silently otherwise. Code-complete ≠ working here. Treat
> every rung as "ported, pending HW verify" until a real GPU confirms it.
