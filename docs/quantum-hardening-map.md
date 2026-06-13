# Quantum Hardening Map for Grit

This is the layered plan for using dedicated IBM Heron r2 access to harden Grit.
It is the execution companion to `docs/quantum-workloads.md` (the why/what-fits
analysis). Read that first.

## Cardinal rule (load-bearing)

The QPU is an **advisory / entropy oracle, never an authority**. No quantum
output may authorize a release, prove an invariant, weaken a policy, or be the
*sole* entropy for a runtime secret. Every quantum result is replayed through the
existing classical authorities (the GHL checkers, the Track 3 invariant runner,
the envelope reject matrix) which remain the sole acceptance gate.

## Target machine

156-qubit / 176-coupler Heron r2 (us-east), native `cz, rx, rz, rzz, sx, x`,
2Q median 1.86e-3 (best 7.71e-4), readout 7.93e-3, T1 252us / T2 126us, 340K
CLOPS, dedicated. Implications: shallow circuits (p=1..3), low-error edge
subsets, native `rzz` penalties, mandatory readout mitigation, batch circuits
into single jobs, favor parameter sweeps over one deep circuit.

## Layers

| Layer | Target | Workload | Classical authority it defers to | Status |
|---|---|---|---|---|
| 0 | Entropy / key material | QRNG seed (random circuits -> vN + Toeplitz) | seed never shipped; only signed SHA-256 commitment | tool exists: `tools/quantum/qrng_seed.py` |
| 1 | Policy / capability graph | QUBO + shallow QAOA grant minimization | `src/tools/security/policy_graph_check.ghl` + invariant runner | **tool built: `tools/quantum/policy_graph_qaoa.py`** |
| 2 | Invariant counterexample search | QUBO "predicate false + low Hamming wt" sampling | production-compiler-backed evaluator (`eval_invariants.py`) | pending (only worth it once state spaces > 7 bits) |
| 3 | Compartment / process placement | offline Max-Cut / graph partition | QEMU benchmarks + classical security checks | design only |
| 4 | Verification-suite selection | set-cover QUBO | full suite still runs for releases | needs coverage matrix export first |
| 5 | Fuzz-corpus diversification | QPU-sampled mutation combos | coverage-guided classical fuzzing (primary) | auxiliary |

## Layer 1 tool (built, ready)

`tools/quantum/policy_graph_qaoa.py`:

- Contains a byte-for-byte Python port of `edge_is_valid` from the GHL kernel.
  Keep them in lockstep -- the GHL kernel is the authority.
- `accept_proposal()` is the only path a proposal reaches the user: every
  retained grant must be `edge_is_valid == 1`, all required reachability must be
  preserved (transitive closure), and the proposal must be no worse than the
  all-valid baseline.
- Always runs brute force (<=22 grants) + greedy-drop classical baselines; the
  QPU must beat-or-match them or the classical result is emitted instead.
- Writes `policy_advisory.json` (gitignored) -- a proposal only, never edits
  policy in place.

Runs today with no token:

```
python tools/quantum/policy_graph_qaoa.py --instance examples --simulate
```

Later, on the real machine:

```
export QISKIT_IBM_TOKEN=...
python tools/quantum/policy_graph_qaoa.py --instance examples \
    --backend <heron-r2-name> --instance-crn <CRN> --p 2
```

## Hardware run log

- **2026-06-13, ibm_kingston (156q Heron r2):** Layer 1 QAOA p=1, 6x6 (gamma,
  beta) grid submitted as one batched job, 4096 shots. Transpiled depth 17, 2
  two-qubit gates. Best sampled bitstring energy 17.0 = global QUBO optimum,
  matched brute force (cost 4017, 4 grants kept), replay gate accepted. QPU kept
  the rank-2 APP->MEMORY edge, dropped the rank-3 alternative + all 3 invalid
  grants. Averaged grid energy ~170 (noise-dominated at p=1); optimum recovered
  as best-shot then classically verified (QAOA-as-sampler). QPU added no new
  authority by design -- it validated the quantum->classical-gate pipeline.

### Hardware gotchas

- **Open plan forbids `Session` mode** (HTTP 400, code 1352). Use single batched
  jobs (a `pubs` list), not adaptive per-eval optimizers. This is why `run_qaoa`
  does a batched parameter-grid scan instead of `scipy.minimize`/COBYLA.
- ibm_kingston basis = `cz, id, rz, sx, x` -- **no fractional `rzz`**; `rzz`
  penalty terms transpile down to `cz`.
- Connect via `channel='ibm_cloud'`, `token` + `instance`=CRN.

## Execution order

1. **Layer 1 policy-graph minimization** (chosen first; advisory-only). RAN on
   ibm_kingston 2026-06-13 (see log above): QPU recovered the optimal minimal
   policy, classically verified, advisory accepted.
2. Layer 0 QRNG as the connectivity/credential smoke test whenever convenient.
3. Layers 2 -> 5 as their classical prerequisites land.

## What's needed to run on hardware

IBM Quantum API token + instance CRN (new `ibm_cloud` platform) + the exact
backend name for the Heron r2 machine.
