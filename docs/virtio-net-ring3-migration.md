# VirtIO-net → ring-3 driver-host migration

**Status: DEFERRED — fail-closed at bind (2026-07-20).** The migration *code*
(boot-time PCI enumeration, match/probe/bind, modern and transitional transports,
brokered MMIO/DMA, IRQ-to-workqueue dispatch, net.l2 RX/TX, asynchronous DHCP) is
written and its broker-side invariants are proven, but **the driver is not
launched on any target.** `driver_manager_init` quiesces the device (clears
IO+MEM+BUSMASTER), validates the device-supplied VirtIO capabilities and BAR
apertures, and then hits an unconditional fail-closed gate
(`virtio_dma_isolation_active()` returns 0 → `dl_fail(7)`) that leaves
bus-mastering disabled and never spawns the driver. See the security note below.

> ⚠️ **Why deferred (arbitrary-DMA hazard).** A VirtIO split-ring's per-descriptor
> `addr` fields are written by the ring-3 driver directly into the DMA-mapped ring
> and are then dereferenced by a **bus-mastering device**. CPU page tables (the
> driver's W+NX USER mapping) do **not** constrain that device DMA, and this
> checkout has **no live per-device IOMMU domain**. The broker proves the vq *base*
> pointers lie inside the driver's DMA grant (`drvhost_mmio_write_dma_ptr`,
> `INV-DRIVER-NO-DMA-MINT`) and now also blocks writing those base registers
> through the generic MMIO ops (`drv_mmio_overlaps_dma_ptr`) — but neither can
> constrain the descriptor `addr` fields the device reads asynchronously. So a
> code-exec-compromised ring-3 driver could point the device at arbitrary kernel
> RAM. The **only** truthful mitigation without an IOMMU is to refuse to enable
> bus-mastering, which is what the gate does. Lifting it requires a hardware-backed
> IOMMU-attestation predicate **and** a trusted platform resource-map check proving
> every BAR aperture is MMIO not RAM — **not** a config toggle.

When (and only when) that gate is lifted, the design below applies: the dedicated
slot's pre-reserved identity-mapped DMA subrange is adopted into the signed broker
budget during bind, and RX frames are bounds-checked and copied under SMAP into
kernel-owned scratch before parsing, avoiding both direct user-page parsing and
DMA TOCTOU.

**Verified 2026-07-14:**
- Stage 1 plan ✅
- Stage 2 broker primitives ✅ — width-parametric MMIO/PIO (`drvhost_mmio_rd8/16/64`,
  `wr8/16/64`, `pio_rd16/32`, `pio_wr16/32`) + `drvhost_mmio_write_dma_ptr`
  (proves the vq pointer value ∈ DMA grant) in `driver_host.ghl`; syscall rows
  250-262 wired in `syscall_support.inc` + handlers in `syscall_handlers_wx_net.inc`.
  Compiler gained real 16-bit `lh`/`sh` intrinsics (the virtqueue ring is 16-bit).
  Full UEFI build green; safety budget unchanged (no new extern/module/cap);
  driver-framework + gritc-security + ghl-security guards green.
- Stage 3 driver ✅ — `src/drivers/net/virtio_net.ghl` compiles clean under
  `gritc --target driver` (43 KB blob), P1 descriptor-id fix structural.
- **Stage 4a broker + kernel DMA/IRQ primitives ✅ (build-, guard-, and
  hardware-green)** — the three syscalls a spawned driver needs are no
  longer denied stubs:
  - **234 `GRANT_DMA(size)→phys`**: `drvhost_dma_alloc` (broker) requires signed
    `CAP_DMA`, bounds the request against a new per-policy **`dma_cap`** running
    total, allocates coherent `<4 GiB` frames via `page_alloc_contig`, and mints
    the `{base,len}` grant with the broker's own fail-closed discipline. It is the
    ONE driver-callable DMA path and is deliberately NOT a `drvhost_grant_*`
    call from the ring-3 handler (keeps `test_driver_framework.ps1` green).
  - **242 `DMA_MAP(phys)→va`**: `drvhost_dma_map` proves `phys` is a grant base of
    the caller, then the paging TCB helper **`l3_map_driver_dma`**
    (`usermode_driver_dma.inc`) aliases the window `PRESENT|USER|W+NX` into a
    fixed per-slot DMA VA sub-window (`L3_SLOT_DMA_OFF`=1 MiB, `L3_SLOT_DMA_MAX`
    =256 KiB in `boot_memory.inc`), disjoint by construction from code / handle
    table / stack / shadow, and fail-closed if the slot's committed code range
    would reach it.
  - **243 `IRQ_WAIT()→count`**: `drvhost_irq_note` (called from the vector stub —
    see Stage 4b) bumps a per-driver pending word; the handler drains it and
    otherwise `sti/hlt` yields the AP-homed core to a **bounded** tick deadline,
    returning 0 on timeout so the driver degrades cleanly to polling (no-freeze).
  - Quarantine/restart revocation (`drvhost_revoke_resources`) now also unmaps
    the DMA VA and clears the DMA total + pending IRQ count.
  - Full UEFI build green; `driver-framework` + `userspace-drivers` guards green;
    both `virtio_net.ghl` and `rtl8156.ghl` still compile clean `--target driver`
    against the enabled ABI. `driver_inventory.txt` untouched (G2 intact).
**Origin:** the modern+legacy VirtIO-net driver added in `231890f6` and deleted in
`01afb41a` (merged as PR #44 / `85047fc7`). It was **deferred, not migrated** —
the code was correct but ran in **ring 0**, which the Track-8 architecture and the
frozen 21-entry `driver_inventory.txt` forbid. This document migrates it into the
ring-3 `driver_host` broker model so it can land without re-opening that objection.

The deleted source is preserved at `git show 231890f6:src/kernel/drivers/virtio_net.asm`.

---

## 1. Why the original could not merge

| Property of the deleted driver | Verdict |
| --- | --- |
| Modern VirtIO-1.x PCI-cap + legacy transitional transport, bounded cap walk, 64-bit BAR handling | correct, keep |
| `VERSION_1 + MAC`-only feature negotiation, `FEATURES_OK` readback | correct, keep |
| `CFGGEN` snapshot/re-read MAC atomicity loop | correct, keep |
| Split-virtqueue layout math, `mfence` publish points | correct, keep |
| RX poll keeps device descriptor id in `r8` **across** `rtl8139_handle_frame → net_rx_frame` (declared `preserves(rbx,rsi)`), then recycles `r8w` | **P1 bug** — wrong descriptor recycled; fixed by design in ring-3 (id lives in driver-local state, no cross-call clobber) |
| Runs in ring 0, touches PCI config / MMIO / DMA / port I/O with **ambient authority** | **architecture violation** — the reason it was pulled |

The ring-3 model removes the P1 bug structurally *and* removes the ambient
authority. Nothing about the hardware logic needs to change; only *who is allowed
to issue each access* changes.

## 2. Authority model (target)

The driver holds **no** ambient authority. Every hardware touch is a
`SC_DRVHOST_*` broker syscall, bounds-checked against grants keyed to the caller's
own `driver_id` (see `src/kernel/grithlk/driver_host.ghl`). Mirrors `rtl8156.ghl`.

```
control plane (kernel / signed PnP)          ring-3 virtio_net driver
────────────────────────────────────         ─────────────────────────
enumerate 1af4:1041 / 1af4:1000              (never sees PCI config)
config-WRITE cmd reg (mem+busmaster)   ──►    register(caps)
resolve BARs, cap windows                     grant results arrive as:
grant_mmio(common_cfg, notify, device_cfg)      mmio_rd/wr within window
grant_dma(vq region + RX/TX buffers)             program vq ptrs (value ∈ DMA grant)
grant_irq(vector)  [optional; poll works]        (optional) irq_wait
```

Key rule: **the broker has no PCI-config-write primitive by design** (a config
write could reprogram BARs / the command register — out of a driver's threat-model
reach). So BAR resolution + `command`-register enable happen in the **control
plane**, and the driver receives already-resolved `{base,len}` grants — exactly as
`rtl8156.ghl` receives a pre-resolved `xhci_base`.

## 3. Per-touch mapping

| Deleted-driver hardware touch | Broker primitive | Exists? |
| --- | --- | --- |
| `pci_read_conf_dword` (enumeration, cap walk, BAR read) | control-plane enumeration → grants; driver never calls it | control-plane (Stage 4) |
| `pci_write_conf_dword` (cmd reg mem+busmaster) | control-plane only (no broker write op, by design) | control-plane (Stage 4) |
| modern common_cfg reads/writes — **byte** (STATUS/CFGGEN), **word** (QSELECT/QSIZE/QENABLE/QNOFF), **dword** (DFEATURE/GFEATURE), **qword** (QDESC/QDRIVER/QDEVICE) | `drvhost_mmio_rd8/16/32/64` + `drvhost_mmio_wr8/16/32/64` | **GAP → Stage 2** |
| program `QDESC/QDRIVER/QDEVICE` with a vq **device-physical** address | `drvhost_mmio_write_dma_ptr(id, mmio_addr, dma_addr, width)` — checks `mmio_addr ∈ MMIO grant` **and** `dma_addr ∈ DMA grant` | **GAP → Stage 2** |
| notify write `notify_base + qnoff*mult` (word MMIO) | `drvhost_mmio_wr16` within granted notify window | Stage 2 |
| legacy transitional `in/out` on I/O BAR (byte/word/dword) | `drvhost_pio_read8/write8` (have) + `drvhost_pio_rd16/32` / `wr16/32` | partial GAP → Stage 2 |
| vq desc/avail/used + RX/TX buffers (DMA-coherent) | `drvhost_grant_dma` + `SC_DRVHOST_DMA_MAP` (have) | have |
| hand RX frame up to the IP stack (replaces `rtl8139_handle_frame`) | `NETL2_OP_RX_FRAME` device-class submit / `net_rx_frame` bridge | Stage 3/4 |

**Only two genuinely new broker capabilities are required** (Stage 2): the
width-parametric MMIO/PIO family, and the DMA-pointer-program op. Both are small,
follow the existing `drv_mmio_contained` / `drvhost_dma_contained` discipline, and
are the *right* generalizations — the HDA BDL-base case in the broker comments
already anticipates the DMA-pointer op.

## 4. Staging

- **Stage 1 — plan (this doc).** ✅
- **Stage 2 — broker TCB additions** (`driver_host.ghl` + syscall rows + evals):
  width-parametric brokered MMIO/PIO; `drvhost_mmio_write_dma_ptr`. Re-run
  security guards. *TCB change — review before merge.*
- **Stage 3 — ring-3 driver** (`src/drivers/net/virtio_net.ghl`, `--target driver`):
  faithful re-expression of the modern+legacy bring-up, RX seed, TX, RX poll, with
  the descriptor-id fix structural. No `unsafe`, no privileged intrinsic.
- **Stage 4a — DMA/IRQ primitives ✅ (landed).** `drvhost_dma_alloc` /
  `drvhost_dma_map` / `l3_map_driver_dma` / `drvhost_irq_note`/`_take`, syscall
  rows 234/242/243, per-policy `dma_cap`, and the per-slot DMA VA window. See the
  Verified block above. `drvhost_policy_install` gained a `dma_cap` parameter.
- **Stage 4b — enumerate-and-spawn control plane ✅.** The kernel
  control-plane component (`driver_loader.*`) that: PCI-enumerates virtio-net
  (`1af4:1041` modern / `1af4:1000` legacy), config-writes COMMAND (mem+busmaster),
  resolves BARs + VirtIO caps, `drvhost_policy_install`s a signed row (caps =
  MMIO|PIO|DMA|IRQ, `dma_cap`=`DMA_TOTAL`), **spawns the driver as a ring-3
  process**, `drvhost_register_slot`s it, grants the MMIO/notify/device-cfg
  windows + IRQ vector (control-plane grants), writes the resolved bases +
  transport into the slot handoff, and wires `drvhost_irq_note` into the device
  vector stub. Embed `virtio_net.ghl` (`--target driver`) as a signed ring-3
  package (NOT `driver_inventory.txt`); bump `ghlk_safety_budget.json`.

  > **Execution-model decision (blocking design note, discovered during 4a).**
  > Grit runs ring-3 apps as **cooperative callbacks** (a window's draw/click/key
  > fns invoked by the WM via `call_app_l3`), NOT as preemptive threads with a
  > long-running `main()`. The driver's `main(){ virtio_init(); while(1){ poll_rx();
  > irq_wait(); } }` does not fit that model. Two options:
  >   1. **Tick-callback (recommended, low-risk, matches the OS).** Split the
  >      driver into a one-shot `virtio_init` (run once at spawn) and a
  >      `virtio_tick` callback the kernel invokes from an AP-homed job / the
  >      device-enum worker each frame; `poll_rx` becomes the tick body, `IRQ_WAIT`
  >      is dropped in favour of the kernel's existing bounded scheduling. This
  >      reuses `process_create`+`home_core` and the callback-dispatch path, and is
  >      no-freeze by construction. Requires a small driver refactor + a
  >      broker-registered `driver_tick` entry.
  >   2. **Real ring-3 driver thread.** Build genuine preemptive ring-3 process
  >      scheduling so `main()` runs as-is with `IRQ_WAIT` as the yield. Larger,
  >      riskier (new scheduler surface in the TCB), but keeps the driver source
  >      verbatim. Only pursue if a general ring-3 thread model is wanted anyway.
  >
  > **RESOLVED 2026-07-14 → option 1 (tick-callback).** Rationale, for the record:
  >   * **Security.** Option 2 does not merely enlarge the TCB — a preemptive
  >     ring-3 thread lets a sandboxed driver's `while(1)` hold a core, re-creating
  >     precisely the forcibly-preemptable stall the cooperative model exists to
  >     make *unrepresentable*. That regresses the no-freeze-by-construction
  >     invariant. Option 1's TCB delta is one more `call_app_l3` entry per frame on
  >     an already-trusted path.
  >   * **Maintainability / precedent.** `rtl8156.ghl` carries the identical
  >     `main(){ init(); while(1) }` shape and is *also* unspawned — the live NIC is
  >     still in-kernel (`rtl8156.asm` + `rtl8156_dhcp_*.ghl`). No precedent forces
  >     option 2; we are *setting* the pattern, so we set the minimal-TCB one and
  >     rtl8156 adopts it next.
  >   * **Cost is near-zero on the driver side.** `virtio_init()` is already the
  >     one-shot spawn entry (returns `DRV_OK`); `poll_rx()` is already a bounded,
  >     self-terminating drain — i.e. already the tick body. Only the
  >     `event_loop()`/`main()` wrapper assumes a blocking thread. The verbatim 1:1
  >     hardware bring-up is untouched. See §4b-1 below for the concrete plan.

  > **REFINED 2026-07-14 (efficiency + device-manager) — supersedes "per-frame".**
  > A callback that runs `poll_rx` *every frame* polls the NIC 24/7 and burns CPU
  > on an idle link. The cooperative-**callback** model is kept (safe, no-freeze),
  > but the **trigger is event-driven, not per-frame**, and driver bring-up is owned
  > by a **device manager that probes then binds**:
  >   * **Device manager (match → probe → bind).** After bus enumeration, for each
  >     device with no bound driver, consult a match table (vendor/device/class →
  >     driver package; virtio-net = `1af4:1041`/`1af4:1000`). On a match: spawn the
  >     driver, install signed policy + grants, run its one-shot `main()`/probe. If
  >     it returns `DRV_OK` → **bind** (route IRQ, register the RX callback, keep).
  >     If it fails → tear down (quarantine/release), leave the device unclaimed for
  >     another candidate. This is "try a driver, use it only if it works".
  >   * **IRQ-triggered RX callback (zero idle CPU).** The bound driver gets **no
  >     per-frame tick**. Its vector is routed via `drvhost_grant_irq`; the kernel
  >     vector stub ACKs, calls `drvhost_irq_note`, and enqueues **one** workqueue
  >     job that invokes the driver's RX-drain callback **once** via
  >     `drvhost_tick_begin`/`_end`. Idle NIC ⇒ no IRQ ⇒ no callback ⇒ 0 CPU. TX is
  >     already on-demand (app → syscall → driver TX). A device with no usable IRQ
  >     falls back to a *low-frequency* timer poll, never per-frame.
  >   * **Delta from what landed.** The `virtio_tick`/`poll_rx` body is unchanged —
  >     only its *trigger* moves from a frame loop to the IRQ workqueue job. The
  >     `drvhost_register_tick`/`tick_begin`/`tick_end` in-flight primitives are
  >     exactly the dispatch guard needed; they are now driven by `drvhost_irq_note`.
  >     `CAP_IRQ` returns to the driver's requested mask (the IRQ route is used),
  >     and `SC_DRVHOST_IRQ_WAIT`'s bounded `sti/hlt` becomes the no-IRQ fallback
  >     path only. §4b-3 below is the remaining device-manager + IRQ-dispatch work.

  ### 4b-1. What landed 2026-07-14 (driver + broker halves)

  Option 1's two *substrate-independent* halves are done, build-green and
  guard-green (`test_driver_framework.ps1`, `test_ghl_security_guards.ps1`,
  `test_gritc_security.ps1` all PASS; driver compiles clean `--target driver`):

  - **Driver (`virtio_net.ghl`).** `event_loop()`/`main()`'s blocking loop is
    replaced by two entries: `main()` = one-shot `virtio_init` (spawn entry,
    never loops) and `virtio_tick()` = the bounded `poll_rx` drain (per-frame
    entry). `IRQ_WAIT` is not called; `virtio_init` no longer requests `CAP_IRQ`
    (least privilege — the poll-only tick never uses it).
  - **Broker (`driver_host.ghl`).** New control-plane tick primitive:
    `drvhost_register_tick(id, entry)` records a driver's ring-3 tick VA (kernel
    loader only — never a ring-3 wrapper); `drvhost_tick_begin(id)` is the
    per-frame admission gate (running + entry-registered + not-already-in-flight,
    `atomic_xchg` re-entrancy guard mirroring `l3_slot_in_flight`);
    `drvhost_tick_end(id)` releases it; `drvhost_revoke_resources` clears both so
    a quarantined/restarted driver is no longer ticked and must re-register.

  ### 4b-2. Two design forks resolved by the landed boot/TCB work

  Tracing the spawn path for §4b turned up **two** architectural decisions the
  original §4b sketch glossed. Both are recorded here *decided* so the boot/TCB
  code is a straight build, not a fork — but neither is landed, because each adds
  foundational TCB surface that must not be rushed in blind (no local `nasm`/QEMU
  to validate, and this is the exact class of change past freeze-regressions came
  from).

  **Fork A — windowless ring-3 driver process (the real blocker).** The doc's
  "reuse `process_create` + callback-dispatch" is not off-the-shelf:
  `process_create(entry, slot, win_id)` *requires* `slot < 12` **and**
  `win_id < 12`, builds the user stack from `l3_user_stack_top(slot)`, and
  installs the *window* app-done trampoline; `call_app_l3` picks the slot from a
  **window's** appdata offset (no window ⇒ collapses to slot 0). There is **no**
  windowless-spawn primitive anywhere — the GPU-compartment TODO independently
  confirms this ("no spawn primitive of any kind exists in the codebase today").
  *Decided approach:* add a `driver_process_create(entry, slot)` +
  `driver_tick_dispatch(pid)` that reuse the slot arena / W^X / stack machinery
  but drive the callback from an explicit **PCB-carried slot** instead of a
  window (generalize `l3_prepare_callback`'s slot-pick to take an explicit slot
  when `arg0 == 0`). This is the same primitive GPU compartments need, so it
  should be built once, here, as `driver_process.*` and shared.

  **Fork B — registration/grant ordering handoff.** A driver's `virtio_init`
  self-registers (`SC_DRVHOST_REGISTER`) and then immediately reads MMIO — but
  the control plane can only `drvhost_grant_mmio(id, …)` *after* the driver is
  `RUNNING` (`id = slot+1`), which the self-register sets. That is a chicken-and-
  egg inside a single-threaded init: the MMIO windows must exist *before* the
  first `cc_rd8`. *Decided approach:* the **control plane** registers the driver
  (`drvhost_register(slot+1, caps, policy, hash)` → RUNNING) and installs the
  MMIO/notify/device grants *before* spawn, writes `self_id = slot+1` + resolved
  bases + transport into the driver's handoff `state` block, and the driver
  **drops** its `SC_DRVHOST_REGISTER` call, reading `self_id` from the handoff.
  Brokered DMA/MMIO syscalls already resolve `id` from the caller's slot
  (`drvhost_id_for_slot`), so the driver needs no self-registration once the
  control plane has pre-registered + pre-granted. (Also needs: `gritc --target
  driver` to emit the `virtio_init`/`virtio_tick` entry offsets so the loader can
  compute the in-slot tick VA — a small toolchain addition.)

  ### 4b-3. Remaining, in order (all boot/TCB — review before merge)

  **Landed this pass (build-green, guard-green; NOT yet spawned):**
  - **Fork A windowless spawn — DONE.** `call_app_l3_driver(slot, blob_entry)`
    (`usermode_callbacks.ghl`) runs a ring-3 fn in an explicit slot with no window
    (additive forced-slot override in `l3_prepare_callback`, inert for every GUI
    call). Full kernel builds green; the hot callback path is unchanged when unused.
  - **Device manager — WRITTEN + compiles.** `driver_loader.ghl`: PCI enumerate
    `1af4:1041`, COMMAND write (mem+busmaster), VirtIO cap/BAR resolve, headless
    slot reservation (WF_ACTIVE, no WF_VISIBLE — the wallpaper pattern), Fork-B
    `policy_install`→`register`→`grant_mmio`→state handoff→probe→bind. It compiles
    clean `--target kernel` but is **NOT wired into the build** yet (see blocker).
  - **Driver Fork-B — DONE.** `virtio_net.ghl` drops its self-`REGISTER` (the
    control plane registers + grants first; the broker keys off the slot), signals
    a successful probe via a `ready` state flag, and its obsolete `ld/sd` were
    corrected to `lw/sw` (they broke NASM assembly inside the monolith).

  **RESOLVED (foundation checkpoint, 2026-07-14): the driver cannot ride the
  shared GUI app blob.** Embedding `virtio_net.ghl` into `apps.asm` failed for three independent,
  architectural reasons — so a **separate small driver blob** is required:
  1. **Syscall numbers > 255.** The app-blob per-slot syscall-permutation fixup
     record (`app_sysno.inc` `APP_SYSNO`) stores the syscall number in **one byte**;
     the broker ABI the driver uses spans `256..263` (MMIO_WR32/64, WR_DMAPTR,
     PIO16/32, NET_RX) → `db` overflow, and per-slot permutation would corrupt them.
  2. **DMA window vs shared W^X.** The shared blob is one big X code window
     `[code_start, code_end)`, so `l3_apply_wx_policy` re-flips any DMA VA window
     carved inside it back to X+!W every activation — the driver's DMA buffer must
     be W+NX. A per-slot DMA window only survives if it sits **outside** the code
     window (a small driver blob leaves the rest of the slot free for it).
  3. **No free slot VA.** The shared blob is ~1.8 MiB of a 2 MiB slot; there is no
     room for a 256 KiB DMA window below the handle table / stack.

  **Foundation landed:** `--target driver` now emits raw u32 syscall immediates
  into one dedicated, contiguous `.driverblob` with a page-aligned internal W^X
  split and a driver-local raw `SYS_APP_DONE` trampoline.
  `l3_copy_driver_blob_to_slot` scrubs and installs it below the fixed DMA VA
  window, keeps syscall dispatch in identity mode, publishes exact per-slot blob
  kind/size + W^X metadata, and randomizes placement only within the pre-DMA
  range. Canonical target translation and callback return are blob-kind-gated,
  preventing cross-package entry confusion. NASM assertions fail the build if
  the blob reaches DMA or loses page alignment. Full UEFI dual-KASLR build,
  safety/source guards, driver-framework guards, signature/manifest pipeline,
    and QEMU smoke boot pass. The device manager is now wired at boot.

  **Completed order:**
  1. **Separate driver-blob substrate — DONE.**
  2. Build + boot wiring (device-enum join → lockdown) — **DONE**.
  3. IRQ dispatch: `drvhost_irq_note` in the device vector stub → workqueue job →
     `drvhost_tick_begin` → `call_app_l3_driver(tick)`. Low-freq timer fallback for
     no-IRQ devices — **DONE**.
  4. QEMU modern + transitional DHCP over the ring-3 path — **was demonstrated
     once, now gated off.** Superseded by the fail-closed IOMMU gate (see Status);
     unreachable until a real IOMMU domain exists.

- **Stage 5 — validate (BLOCKED on IOMMU).** Broker invariants are proven
  (`eval_drvhost_dma_mint.py`: `INV-DRIVER-NO-DMA-MINT`, incl. P4 pointer-mint and
  P7 generic-write bypass) and the fail-closed gate is guarded
  (`test_driver_framework.ps1`). **The prior "DHCP over the ring-3 path" bring-up
  predates the fail-closed gate and is no longer reachable** — the driver does not
  bus-master, so there is no end-to-end DHCP to confirm until a real IOMMU domain
  exists. Do not re-mark this ✅ on the strength of that earlier run.

## 5. Invariants this preserves

- **No ambient authority (G3):** every touch is brokered; code-exec in the driver
  gains nothing toward the kernel.
- **DMA containment (INV-DRIVER-NO-DMA-MINT):** vq *base* pointers programmed into
  the device are proven inside the driver's own DMA grant before the broker writes
  them, and the base registers cannot be reached through the generic MMIO write ops
  (`drv_mmio_overlaps_dma_ptr`). **Limit:** this does NOT cover per-descriptor
  `addr` fields (device-dereferenced, not broker-mediated); descriptor-level DMA
  containment requires an IOMMU — hence the fail-closed bind gate. Do not read this
  invariant as "the device can only DMA within the grant."
- **Shrink-only driver inventory:** untouched — this adds a ring-3 package, not an
  in-kernel driver.
- **Quarantine/restart:** a faulting virtio_net driver is quarantined by the
  existing broker containment path; its grants and IRQ routes are revoked.
