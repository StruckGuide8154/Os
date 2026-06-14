# Quantum Workloads for Grit

This note maps Grit's current code and security roadmap to experiments that
fit a 156-qubit IBM Heron r2 processor. These are hybrid research workloads,
not production dependencies. Every result must be checked against a classical
baseline, and no QPU output may authorize a release, weaken a policy, prove an
invariant, or supply the only entropy protecting a runtime secret.

## Hardware fit

The available processor is well suited to shallow graph and Ising workloads:

- 156 heavy-hex qubits and 176 couplers.
- Native `CZ`, `RX`, `RZ`, and fractional `RZZ` operations.
- Median two-qubit error around 0.19%, so useful experiments should minimize
  routed two-qubit gates and compare several depths.
- Readout error around 0.79%, so sampled bitstrings need measurement-error
  mitigation or strong classical post-processing.
- Dedicated access and 340K CLOPS favor parameter sweeps, calibration-aware
  repetitions, and hybrid optimization loops more than one very deep circuit.

## Ranked Grit uses

### 1. Policy-graph minimization

**Repo inputs:** `src/tools/security/policy_graph_check.ghl`, signed app
capability manifests, and the Track 2 threshold rules.

Formulate candidate grants as binary variables. Penalize forbidden edges,
privilege expansion, missing threshold approval, and loss of required
reachability; minimize the number and rank of retained grants. This is a QUBO
or higher-order binary optimization problem and maps naturally to shallow
QAOA using native `RZZ` interactions.

The QPU should propose policy reductions only. The existing deterministic GHL
checker and invariant suite remain the acceptance authority. This directly
supports the roadmap item for a policy graph minimizer.

### 2. Security counterexample search

**Repo inputs:** `src/tools/security/invariant_check.ghl`,
`scripts/test/eval_invariants.py`, and the invariant vector files.

Search bounded authority states for low-Hamming-weight violations, especially
after adding larger state spaces that make exhaustive enumeration expensive.
Encode "predicate is false" plus a sparsity objective as a QUBO, sample many
candidates, then replay every candidate through the production-compiler-backed
classical evaluator.

This is useful as a bug-finding heuristic, not a proof. The current 7-bit
spaces are already cheap enough to exhaust classically, so quantum work becomes
interesting only when temporal state, graph topology, or many compartments are
added.

### 3. Compartment and process placement

**Repo inputs:** process placement, scheduler authority, IPC edges, shared
handles, and per-core/cache topology.

Build a weighted graph where high-traffic pairs prefer co-location while
mutually distrusting or side-channel-sensitive pairs prefer separation.
Solve the resulting constrained graph partition or Max-Cut problem offline.
Feed candidate layouts into QEMU benchmarks and the classical security checks.

Do not put a variational QPU loop in the live scheduler. Use it to discover
static placement profiles that compile into ordinary deterministic policy.

### 4. Verification-suite selection

**Repo inputs:** source ownership, invariant IDs, build stages, security
fixtures, and measured test runtimes.

Use a set-cover QUBO to choose the smallest presubmit suite covering all files,
security tracks, invariants, and recent failure modes under a time budget. The
full suite still runs for releases; the QPU-generated subset is for rapid local
and pull-request feedback.

This becomes practical after test-to-requirement coverage is exported as a
machine-readable matrix.

### 5. GritHL compiler optimization experiments

**Repo inputs:** compiler IR, function call graph, register pressure, basic
block frequencies, and generated-code size.

Candidate formulations include register allocation, bounded instruction
scheduling, function ordering, and hot/cold layout. Start with individual hot
functions small enough to verify by exhaustive or integer-programming
baselines. Quantum output must pass the compiler's lossless-equivalence and
security-authority checks before use.

### 6. Fuzz-corpus diversification

**Repo inputs:** envelope decoder, policy parser, XML/SVG parsers, syscall
validation, and existing fuzz harnesses.

Use QPU samples to choose mutation combinations or seed a corpus-diversity
objective. This can produce unusual correlated choices, but it is less valuable
than coverage-guided classical fuzzing and should be treated as an auxiliary
campaign only.

### 7. QPU and mitigation research using Grit-shaped graphs

Run heavy-hex-native Ising models derived from sanitized policy and IPC graph
statistics. Compare `CZ` decomposition against fractional `RZZ`, circuit depth,
layout choices, twirling, readout mitigation, and zero-noise extrapolation.
This is the cleanest use of dedicated access because the output is scientific
measurement rather than a production decision.

## Existing QRNG tool

`tools/quantum/qrng_seed.py` is suitable for generating a supplemental build
diversity input. It is not a certified QRNG:

- A simple observed-bias estimate does not establish adversarial min-entropy.
- A noisy random-circuit sample is not automatically device-independent or
  unpredictable to the service operator.
- Once folded into a distributed kernel image, the seed is public and static.
- Fresh per-boot secrets still require a trusted runtime entropy source and
  health testing.

The script therefore uses coupling-map-native CZ matchings and labels its
entropy estimate as heuristic. Keep its output out of source control.

## Recommended first experiment

Start with policy-graph minimization on synthetic graphs matching Grit's eight
domains and eight capability classes:

1. Generate 20-60 variable instances with known classical optima.
2. Run depth `p=1..3` QAOA with native fractional `RZZ` where available.
3. Compare against brute force, simulated annealing, and a MILP/QUBO solver.
4. Replay all sampled policies through `security_policy_graph_edge_is_valid`
   and the Track 3 invariant runner.
5. Scale only if solution quality beats or complements the classical heuristic
   at equal wall-clock and QPU cost.

Dedicated access makes the iterative parameter loop and repeated mitigation
comparisons practical. It does not remove the need for classical validation.

## References

- IBM Quantum processor types: https://quantum.cloud.ibm.com/docs/guides/processor-types
- IBM QAOA tutorial: https://quantum.cloud.ibm.com/docs/en/tutorials/quantum-approximate-optimization-algorithm
- IBM fractional gates guide: https://quantum.cloud.ibm.com/docs/guides/fractional-gates
- IBM error mitigation tutorial: https://quantum.cloud.ibm.com/docs/tutorials/combine-error-mitigation-techniques
- IBM backend metrics: https://quantum.cloud.ibm.com/docs/guides/qpu-information
