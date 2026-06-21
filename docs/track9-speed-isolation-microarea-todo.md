# Track 9 - Sandboxed Speed-Isolation Micro-Area (TODO)

**Status: NEW / design-only (2026-06-14). Not started.**

A dedicated, sandboxed "speed-isolation prioritisation micro-area": a place where
custom Grit/GHL script programs run in **real time at extreme speed - faster than
hand-perfect asm** - while staying inside the Track 2/3/6/8 security envelope. The
target use is latency/throughput-critical workloads run on a **server** instance of
this OS: HFT-style strategies, and high-rate RNG/result generation for services
(e.g. a provably-fair dice/duel-style site doing fast RNG for round generation).

The "faster than asm" claim rests on the existing optimizer direction: whole-program
expression-tree codegen + coupled QUBO regalloc (see `compiler_optimizer_baseline_and_gap`,
`compiler_o3_landed`) feeding a micro-area that removes the syscall/scheduler/cache
overheads a normal app pays. Speed comes from *removing the runtime tax*, not from
unsafe code - the sandbox stays on.

---

## P0 - The micro-area runtime

- [ ] Define the **speed micro-area**: an isolated execution region (own arena,
      own page set, W^X-clean) where a signed script program runs without the
      normal per-syscall dispatcher/cap-mask/trace overhead on its hot path.
- [ ] **Real-time scheduling class**: a priority tier above normal app slots;
      cooperative-yield + bounded preemption so a hot script is not stalled by
      UI/idle-frame governor work.
- [ ] **Deterministic latency**: pin the micro-area off the boot/UI critical path;
      no lazy faults on the hot path (pre-fault + pre-pin all pages), no allocator
      calls in steady state (arena pre-reserved).
- [ ] **Beyond-asm codegen path**: route micro-area scripts through the O3
      expression-tree + QUBO regalloc pipeline; measure against a hand-asm baseline
      kernel (the "faster than perfect asm" gate - publish the benchmark numbers).
- [ ] **Hot syscall fast-path / batching**: vDSO-style or shared-ring interface so
      the script gets module services without a full ring transition per call.

## P0 - Security (the sandbox stays on)

- [ ] Micro-area programs are **signed artifacts** (Track 2 envelope) - no unsigned
      hot code, ever. Same single public root of trust (Track 7).
- [ ] **Default-deny capability manifest** per micro-area script (Track 3 authority
      model). Fast path does not mean ungated - caps are resolved/locked at admit
      time so the hot loop pays no per-call check but cannot exceed its grant.
- [ ] Memory isolation: micro-area arena is compartment-isolated (Track 6) - a
      script compromise stays in its compartment; cannot read other slots' memory.
- [ ] **Optimised module access**: internet/net + other modules reachable from the
      micro-area only via the user-space driver broker (Track 8), through a
      pre-granted, rate-bounded fast channel - speed-optimised but still proxied.

## P1 - Multi-core / scaling

- [ ] **Multi-core support + core pinning**: bind a micro-area script to dedicated
      AP core(s); isolate those cores from general scheduling (housekeeping/IRQs
      steered away) for jitter-free max throughput.
- [ ] Per-core arenas + lock-free / shared-ring IPC between pinned workers (no
      cross-core cache-line bouncing on the hot path).
- [ ] NUMA/cache-aware placement of the micro-area arena relative to its pinned core.
- [ ] Scale-out: N independent micro-areas across N cores for parallel
      RNG/result generation.

## P1 - Module surface for the target workloads

- [ ] **Fast RNG service**: hardware RNG (rdrand, CPUID-gated - see
      `feedback_nhl_rdrand_must_cpuid_gate`) + the existing QRNG seed path, exposed
      as a high-rate, low-latency micro-area module for provably-fair generation
      (commit/reveal hooks so results are auditable - the duel.com/dice use case).
- [ ] **Network fast path**: pre-bound socket/result-serving channel via the broker
      for serving generated results off-box at high rate.
- [ ] **Timing/clock**: low-overhead TSC-based timestamps for HFT-style strategies
      and for stamping generation events.

## P2 - Tooling & validation

- [ ] Benchmark harness proving "faster than perfect asm" on representative kernels
      (RNG batch, tight numeric loop, packet build) - numbers in this doc.
- [ ] Jitter/latency-distribution test (worst-case, not just mean) under load.
- [ ] Negative tests: a micro-area script cannot escape its cap manifest, cannot
      touch another compartment, cannot run unsigned, cannot un-pin/escalate.

---

## Notes / open questions

- "Faster than asm" must be stated honestly: it's whole-program optimisation +
  runtime-tax removal vs a *naive* asm baseline, not magic. Gate the claim on the
  published benchmark, per `compiler_optimizer_baseline_and_gap`.
- Server profile: this is a non-GUI / headless deployment shape - confirm a server
  boot profile exists (BOOTCFG feature toggles) that strips UI subsystems to free
  cores for the micro-area.
- The duel.com/HFT framing is a **use case example**, not an endorsement of any
  specific operator - the deliverable is the secure fast-execution primitive.
