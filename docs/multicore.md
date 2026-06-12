# Grit Multi-Core (SMP Work Queue)

This document describes how Grit uses more than one CPU core, and how to
offload expensive work so the GUI stays responsive.

## Goal

A heavy operation in an app (SVG rasterisation, image decode, layout) used to
run on the boot CPU inside the single render loop, freezing the whole desktop
until it finished. The SMP work queue lets that work run on another core while
the boot CPU keeps drawing frames at full speed.

## Model: worker-core offload

Grit does **not** schedule whole apps preemptively across cores. It uses a
simpler, lower-risk model:

- **BSP (boot processor, CPU 0)** runs the kernel, the GUI render loop, drivers,
  and all ring-3 app code - exactly as before.
- **APs (application processors, the other cores)** do nothing but pull
  *compute jobs* from a shared queue and run them.

A "job" is a self-contained kernel function plus one argument. The BSP submits
jobs; an idle AP picks one up, runs it, and publishes the result.

## Components

| Piece | File | Role |
|-------|------|------|
| AP bring-up | `src/kernel/arch/apic.asm` | INIT/SIPI trampoline; each AP ends in `smp_worker_loop` and sleeps in HLT when no job is pending. |
| Work queue + worker loop | `src/kernel/proc/workqueue.asm` | Job array, submit/poll/reap API, and the AP worker loop. |
| Wiring | `src/kernel/core/main.asm` | `kmain` calls `workqueue_init` before `smp_ap_startup`, then `workqueue_selftest`. |

## How a core becomes a worker

`smp_ap_startup` (in `apic.asm`) copies a real-mode trampoline low in memory and
sends INIT/SIPI IPIs. Each AP walks 16-bit → 32-bit → 64-bit mode, enables SSE
(so vectorised job code does not `#UD`), records itself live, and then jumps to
`smp_worker_loop`. It never returns; the core is a permanent worker. When no
job is claimable it enables interrupts, executes `hlt`, and wakes on the
workqueue IPI sent after the BSP publishes a job.

Build profiles that define `GRIT_CACHE32_AP_STARTUP` start AP workers. UEFI
enables that path in both `Default` and `Cache32Max`; BIOS enables it only in
`Cache32Max`. Those AP-startup profiles also define `GRIT_ENABLE_RING3_AP`,
so app callbacks are routed to each process `home_core` instead of running
inline on the BSP.

Release builds intentionally keep the timed GUI boot path lean: `smp_ap_startup`
starts at most one AP synchronously and uses a shorter liveness window. If that
worker is not alive quickly, `smp_alive_cores` remains BSP-only and the existing
inline workqueue fallback carries app callbacks until a future asynchronous AP
fan-out path exists. Debug builds keep the full AP fan-out and workqueue
self-test coverage.

## Concurrency design

- **One producer** (the BSP), **N consumers** (the APs).
- A job slot is claimed with a single `lock cmpxchg` on its status word, so
  there is **no global lock**. A slow or dead AP can never stall the BSP, and
  two APs can never run the same job.
- Each slot is its own 64-byte cache line - cores working different slots never
  ping-pong a shared line (no false sharing).
- Status store ordering (x86 TSO) guarantees a worker that observes `PENDING`
  also observes the function pointer and argument written just before it.

Status lifecycle: `FREE → BUILDING → PENDING → RUNNING → DONE → FREE`.

## BSP API (`workqueue.asm`)

| Function | In | Out | Notes |
|----------|----|----|-------|
| `workqueue_init` | - | - | Reset the queue; must run before `smp_ap_startup`. |
| `workqueue_submit` | RDI=func, RSI=arg, RDX=priority | RAX=handle or `-1` | Queues a job; runs it inline if no AP is alive. |
| `workqueue_done` | RDI=handle | RAX=1 if finished | Non-blocking poll. |
| `workqueue_reap` | RDI=handle | RAX=result | Reads result and frees the slot. |
| `workqueue_wait` | RDI=handle | RAX=result | Blocks until done, then reaps. |
| `wq_lock` | RDI=lock ptr | - | Acquire a shared-state spinlock. |
| `wq_unlock` | RDI=lock ptr | - | Release a shared-state spinlock. |

## Job priority - keeping the system responsive

`workqueue_submit` takes a priority in RDX:

| Constant | Value | Use for |
|----------|-------|---------|
| `WQ_PRIO_LOW` | 0 | Background app work - may be starved while higher work exists. |
| `WQ_PRIO_NORMAL` | 1 | The default for ordinary offloaded work. |
| `WQ_PRIO_HIGH` | 2 | System-critical jobs that must not wait behind app work. |

Each sweep, a worker scans all slots and claims the **highest-priority**
`PENDING` job, not the first one it sees. This is what stops a misbehaving or
busy app from degrading the system: a flood of `WQ_PRIO_LOW` jobs from a frozen
or runaway app can never delay a `WQ_PRIO_HIGH` system job, and it can never
affect the BSP at all - the BSP never runs jobs, so the GUI render loop is
isolated from app work by construction.

A job still runs to completion once claimed (APs take no timer IRQs). A job
that loops forever permanently consumes **one** AP, but no more: other APs keep
serving the queue and the BSP is untouched. Priority ensures the remaining
cores spend their time on the work that matters.

## Sharing state safely

A job **may** touch state shared with the BSP - the framebuffer, the page
allocator, driver state - as long as **every** accessor, on the BSP side too,
holds the matching lock. `workqueue.asm` provides a spinlock primitive and
three named locks:

| Lock | Guards |
|------|--------|
| `wq_alloc_lock` | The physical page allocator (`page_alloc` / `page_free`). |
| `wq_fb_lock` | The shared framebuffer. |
| `wq_driver_lock` | Shared driver state. |

```asm
    mov rdi, wq_alloc_lock
    call wq_lock
    ; ... critical section: touch the shared resource ...
    mov rdi, wq_alloc_lock
    call wq_unlock
```

`page_alloc` / `page_free` already take `wq_alloc_lock` internally, so a job can
allocate pages with no extra ceremony. For the framebuffer and driver state the
BSP-side code must be taught to take the lock before that resource is genuinely
job-safe - until then, treat it as BSP-only.

A lock only protects if **both** sides take it. The simplest job is still a
self-contained one that reads only read-only data and writes only its own
output buffer - that needs no lock at all.

## Job contract - REQUIRED

A function submitted as a job **must**:

1. Be trusted kernel code. Jobs are never submitted from ring 3, so the function
   pointer is always a kernel address. **Never expose submit as a syscall.**
2. Take one argument in RDI and return a scalar in RAX.
3. Follow the SysV ABI (preserve RBX, RBP, R12-R15).
4. Touch shared mutable state **only** under the matching lock (see "Sharing
   state safely"). Unlocked access to a resource another core may touch is the
   classic SMP bug - it corrupts memory intermittently and is hard to debug.
5. Do bounded work - APs receive no timer IRQs, so a job runs to completion.

## Recommended usage (keeps the render loop alive)

Submit the heavy job, keep rendering frames, and poll once per frame:

```asm
    mov rdi, svg_rasterise_tile      ; job function
    mov rsi, tile_descriptor         ; argument
    call workqueue_submit
    mov [svg_job], eax               ; stash handle; return to the render loop

    ; ... later, once per frame ...
    mov edi, [svg_job]
    call workqueue_done
    test eax, eax
    jz  .not_ready_yet               ; still rendering on the AP; draw a frame
    mov edi, [svg_job]
    call workqueue_reap              ; result in RAX; slot freed
```

Use `workqueue_wait` only when there is genuinely nothing else to do - it blocks
the BSP and defeats the purpose.

## Verification

`workqueue_selftest` runs during `kmain`, submits 8 known jobs, verifies every
result, and prints `WQ:<submitted>/<passed>` to the serial log. A healthy boot
shows `WQ:...8/...8`. With APs alive (`SMP:` shows >1 core) this exercises the
real cross-core path; otherwise it exercises the inline fallback.

## Future work (roadmap)

- Offload SVG tile rasterisation and image decode to the queue.
- A `workqueue_submit_many` / barrier helper for data-parallel splits.
- Per-AP `mwait` can still replace the current IPI + `hlt` idle path later if
  the scheduler needs lower wake latency.

## Process-manager roadmap (Stage 1 → Stage 3)

The work-queue model above runs **kernel jobs** on APs. The longer-term plan
is a real **process manager** that runs **app code** on APs with affinity. We
get there in three stages so each one ships working value and the kernel never
spends time in a half-broken state.

### Policy: who runs where

- **Cores 0 and 1 are "system" cores.** They run the kernel proper, the BSP
  render loop, drivers, GUI, and high-priority kernel work-queue jobs. App
  code is not permitted to land here.
- **Cores 2+ are "app" cores.** App processes default to an affinity mask of
  `SMP_APP_CORE_MASK = 0xFFFFFFFC` (every bit except 0 and 1). The auto-placer
  picks the least-loaded core in the mask at process-create time.
- **An app may narrow its mask** via `process_set_affinity` (and, in Stage 2,
  a syscall wrapper). The kernel always AND-strips `SMP_SYSTEM_CORE_MASK` from
  any app request, so a hostile or buggy app can never preempt a system core.
- **Multiple apps can share a core.** The placer balances by current
  utilization (read from `smp_core_states[i] + 24`); ties go to the lowest
  core index. Re-balancing happens at process_set_affinity time today.

### Stage 1 - Foundation *(landed)*

Adds data and bookkeeping without changing scheduling. Apps still execute on
the BSP via `call_app_l3`; this stage just records where they would run.

- `process_t` gained `affinity_mask`, `home_core`, `cpu_time_ticks`.
- `SMP_SYSTEM_CORE_MASK` / `SMP_APP_CORE_MASK` defined in `constants.inc`.
- `process_auto_pick_core(mask)` - least-loaded core in a mask, with system
  cores stripped. Used at `process_create` time.
- `process_set_affinity(pid, mask)` / `process_get_affinity(pid)` - kernel
  callable API; syscall wrapper deferred to Stage 2.
- Kernel process (PID 0) carries mask `0xFFFFFFFF` and `home_core = 0`.

### Stage 2a - Dispatch primitives + per-proc billing *(landed)*

The infrastructure to *send* work to a specific AP and *bill* it to a
process. App callbacks still execute on the BSP today; once Stage 2b lights
up ring 3 on APs, the existing routing path is what carries app code to
those cores.

- `WQ_OFF_TARGET` / `WQ_OFF_PROC` added to the work-queue slot (still 64
  bytes per slot; uses previously-padded space).
- `workqueue_submit_to(func, arg, prio, target_core, proc_id)` - submit a
  job that only the named AP may claim, and bill its TSC cycles to the
  named PCB. Plain `workqueue_submit` is now a wrapper that passes
  `target_core = -1` and `proc_id = 0`, so every existing caller is
  unchanged.
- The AP worker honors `target_core` during slot scanning, and `lock add`s
  its busy-cycle delta into `PROCESS_POOL[proc_id].cpu_time_cycles` after
  each job completes.
- `process_submit_job(pid, func, arg, prio)` - kernel API that submits a
  job pinned to a process's `home_core` and billed to its PCB. This is the
  exact entry point Stage 2c will call to dispatch app callbacks.

**Confirming Stage 2a:** submit a CPU-burning kernel job via
`process_submit_job` for an app PID; after the job runs, the value of
`process_get_cpu_time(pid)` should be non-zero, and the AP whose index
equals that app's `home_core` should be the one that ran it (visible as a
spike on that core in task manager during the burn).

### Stage 2b - Ring-3 on AP *(landed)*

Every AP now boots into a state where it could safely execute ring-3 code
and service its own syscalls. The trampoline still ends at `smp_worker_loop`,
so APs continue to run kernel jobs from the work queue - but the moment
Stage 2c routes a `call_app_l3`-equivalent job to an AP, the AP has all the
plumbing it needs to take that callback into ring 3 and back.

What landed:

- **GDT extended** ([src/boot/gdt.asm](../src/boot/gdt.asm)): `SMP_MAX_CORES - 1` additional 16-byte TSS
  descriptor slots immediately after the BSP's TSS. Selector for core N is
  `0x30 + N * 16`. AP slots stay zero until each AP fills its own in.
- **Per-AP TSS + RSP0 stack** ([src/kernel/core/tss.asm](../src/kernel/core/tss.asm)): pool of
  `(SMP_MAX_CORES - 1)` TSS structures and matching 16 KB kernel stacks in
  `.bss`. `tss_init_for_core(idx)` zeroes its TSS, points `RSP0` at the
  AP's stack top, patches the AP's GDT descriptor base, and `ltr`s the
  per-core selector. Each core ends up with its own ring-0 stack so a
  ring-3 exception on one AP can't clobber another's frame.
- **Syscall MSRs are per-CPU** ([src/kernel/proc/syscall.asm](../src/kernel/proc/syscall.asm)): factored out
  `syscall_init_this_cpu` (programs `EFER.SCE`, `STAR`, `LSTAR`, `FMASK`).
  The existing `syscall_init` is now a thin wrapper that calls it and then
  logs the LSTAR target. APs call the same helper during long-mode init.
- **`ap_long_mode_init`** ([src/kernel/arch/apic.asm](../src/kernel/arch/apic.asm)): one-shot per-AP
  function invoked from the trampoline once paging is up. Loads the kernel
  GDT, reloads segments (including a `retfq` to refresh CS), loads the
  kernel IDT (shared with the BSP - APs don't service hardware IRQs but
  must not triple-fault on CPU exceptions), runs `tss_init_for_core` for
  its core index, then `syscall_init_this_cpu`. Returns to the trampoline,
  which then drops into `smp_worker_loop` exactly as before.

**Confirming Stage 2b:** boot with SMP enabled; every AP should still show
up alive in the perfdiag log (no regressions). The visible payoff lands in
Stage 2c, when actual ring-3 callbacks start dispatching to APs and the
machinery exercised here gets used in anger.

### Stage 2c - Dispatch chokepoint + packed thunk *(landed)*

The plumbing to route ring-3 callbacks across cores. Call sites use
`dispatch_app_callback`, and builds with `GRIT_ENABLE_RING3_AP` use the
active Stage 2d body. Builds without that define keep the compile-time
fallback that tail-calls `call_app_l3` on the BSP.

What landed:

- **`dispatch_app_callback`** ([src/kernel/proc/process.asm](../src/kernel/proc/process.asm)) - the
  chokepoint, same signature as `call_app_l3`. With `GRIT_ENABLE_RING3_AP`
  it uses the Stage 2d lock + submit + wait flow; otherwise it tail-calls
  `call_app_l3` for single-core/non-AP builds.
- **`call_app_l3_packed`** ([src/kernel/proc/usermode.asm](../src/kernel/proc/usermode.asm)) - thunk that
  unpacks a 32-byte `{target, win, arg1, arg2}` block from RDI into the
  registers `call_app_l3` expects and tail-calls it. This is what Stage
  2d hands to `process_submit_job` as the kernel-job function pointer.
- **`process_find_by_window(win_id)`** - actual body for the previously
  stub-only global. Returns the PID of the PCB associated with a window,
  or 0 if none. Used by the routing path to look up `home_core`.
- **`app_callback_lock`** - global spinlock data on its own cache line.
  Stage 2d holds this across the submit+wait pair so only one core is in
  ring 3 on behalf of an app at a time (see Stage 2d for why).

`l3_apply_slot_isolation` rewrites the USER bit on *every* slot's PTEs each
call and does `mov cr3,cr3`. Stage 2d prevents cross-core races by holding
`app_callback_lock` across the submit+wait pair, so only one core is in ring 3
on behalf of an app at a time.

### Stage 2d - Active routing under the global lock *(landed)*

The chokepoint is now wired. App callbacks for any PCB with a non-zero
`home_core` and at least one AP alive dispatch through the AP. Stage 2a
billing now records real per-process cycles.

What landed:

- **`dispatch_app_callback` body activated** ([src/kernel/proc/process.asm](../src/kernel/proc/process.asm)):
  acquires `app_callback_lock`, packs `{target, win, arg1, arg2}` into
  `app_callback_pack`, calls `process_submit_job(pid, call_app_l3_packed,
  pack, WQ_PRIO_NORMAL)`, then `workqueue_wait`s. Falls back to inline on
  the BSP if there's no PCB, the PCB's home_core is 0, no APs are alive,
  or the queue is full.
- **Call sites updated**: every `call call_app_l3` in
  [src/kernel/gui/window.asm](../src/kernel/gui/window.asm) and [src/kernel/core/main.asm](../src/kernel/core/main.asm) (4 + 2 sites:
  draw, click, key, drag, key-input, mouse-input) now calls
  `dispatch_app_callback`. Both files keep `extern call_app_l3` because
  the inline fallback path inside `dispatch_app_callback` and the WQ
  thunk both still need it.
- **Source-guard regex updated** ([scripts/test/test_source_guards.ps1](../scripts/test/test_source_guards.ps1))
  to accept either `call call_app_l3` or `call dispatch_app_callback`
  around the focus-restore site in `window.asm`.

**Strategy chosen: global lock.** Cheapest first cut; preserves the full
per-slot ring-3 isolation that `l3_apply_slot_isolation` enforces. The
cost is throughput: at most one ring-3 callback in flight system-wide,
so two apps with concurrent input cannot truly run in parallel today.

To recover that throughput later, pick one:

| Strategy | What changes | Throughput | Isolation |
|---|---|---|---|
| **Static isolation** | Drop `l3_apply_slot_isolation` calls; mark every active slot user-accessible at slot init. | N cores concurrent. | Inter-slot ring-3 boundary disappears. |
| **Per-CPU CR3** | Each AP has its own page-table copy where only its current slot is user-accessible. | N cores concurrent. | Unchanged. |

**Confirming Stage 2d:** boot, open an app whose `home_core` is non-zero
(any app under the default placer, since apps avoid cores 0/1). When the
app's window is interacted with (mouse move over it, click, redraw), the
core matching the app's `home_core` should show a non-zero util on its
task-manager bar, and `process_get_cpu_time(pid)` for that PCB should
increase. The BSP should NOT show that callback's time.

Also still planned at this stage:

- `SYS_PROC_SET_AFFINITY` / `SYS_PROC_GET_AFFINITY` syscalls so apps can
  request a specific mask. Kernel still AND-strips `SMP_SYSTEM_CORE_MASK`.
- Task manager UI showing per-process CPU time (reads `cpu_time_cycles`).

### Stage 3 - Preemption *(planned)*

- Per-core PIT/APIC-timer tick that triggers a context save through the
  existing `process_save_context` / `process_restore_context` plumbing.
- Per-core ready queue keyed by `affinity_mask`; round-robin within a core,
  work-stealing across cores that share a mask bit.
- `cpu_time_ticks` accounting becomes real per-process CPU%.

### Adding the next stage safely

Each stage keeps the previous stage's APIs intact. A reviewer can confirm a
stage is complete by checking:

| Stage | Confirms it works |
|---|---|
| 1 | `process_get_affinity(pid) != 0` for every app process; `home_core` ∈ {2..ncores-1} for apps. |
| 2a | Submitting via `process_submit_job(pid, ...)` increments that PCB's `cpu_time_cycles` and the configured `target_core` is the AP that ran it. |
| 2b | Every AP boots through `ap_long_mode_init` without triple-faulting; perfdiag SMP line still shows all cores alive. |
| 2c | `dispatch_app_callback` symbol exists, links, and all app callback call sites route through it. |
| 2d | App callbacks measurably consume CPU time on `home_core` (visible as non-zero util on that core in task manager while the app is active). |
| 3 | A tight CPU loop in one app does not stall any other app on a different core, and does not stall the BSP. |
