#!/usr/bin/env python3
"""
policy_graph_qaoa.py - Advisory quantum policy-graph minimizer for Grit.

WHAT THIS IS
------------
Layer 1 of the quantum hardening map (see docs/quantum-workloads.md and
docs/quantum-hardening-map.md). Given a set of CANDIDATE capability grants and a
set of REQUIRED reachability constraints, it searches for the smallest / lowest-
rank subset of grants that still satisfies reachability, using shallow QAOA on a
156-qubit Heron-r2-class backend (native fractional RZZ) -- or a classical
simulator / brute force when no QPU token is supplied.

ADVISORY ONLY -- THIS IS LOAD-BEARING
-------------------------------------
The QPU only *proposes* a reduced grant set. Acceptance authority stays with the
deterministic checker in src/tools/security/policy_graph_check.ghl. Every grant
in every sampled candidate is replayed here through `edge_is_valid`, a byte-for-
byte Python port of that GHL kernel. A proposal is emitted ONLY if:
  * every retained grant is edge_is_valid == 1, AND
  * all required reachability pairs remain reachable, AND
  * the proposal is no larger (count, then summed rank) than the input.
No QPU output authorizes a release, weakens a policy, or proves an invariant.
The tool writes a human-readable advisory file; it never edits policy in place.

USAGE
-----
  # runs today, no quantum token -- classical baselines only:
  python policy_graph_qaoa.py --instance examples --simulate

  # later, on the real machine:
  export QISKIT_IBM_TOKEN=...
  python policy_graph_qaoa.py --instance examples \
      --backend <heron-r2-name> --instance-crn <CRN> --p 2
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import sys
from dataclasses import dataclass, field

# --------------------------------------------------------------------------
# Faithful port of src/tools/security/policy_graph_check.ghl
# Keep these in lockstep with the GHL kernel -- it is the acceptance authority.
# --------------------------------------------------------------------------
DOMAIN_POLICY, DOMAIN_CRYPTO, DOMAIN_UPDATE, DOMAIN_RECOVERY = 1, 2, 3, 4
DOMAIN_MEMORY, DOMAIN_IPC, DOMAIN_DEVICE, DOMAIN_APP = 5, 6, 7, 8

CAP_IPC, CAP_MEMORY, CAP_DMA, CAP_DEVICE = 1, 2, 3, 4
CAP_UPDATE, CAP_STORAGE, CAP_DIAGNOSTIC, CAP_POLICY_WRITE = 5, 6, 7, 8

_CAP_RANK = {CAP_IPC: 1, CAP_STORAGE: 2, CAP_MEMORY: 3, CAP_DEVICE: 4,
             CAP_DMA: 5, CAP_UPDATE: 6, CAP_DIAGNOSTIC: 7, CAP_POLICY_WRITE: 8}


def is_known_domain(d: int) -> int:
    return 1 if DOMAIN_POLICY <= d <= DOMAIN_APP else 0


def is_known_capability(c: int) -> int:
    return 1 if CAP_IPC <= c <= CAP_POLICY_WRITE else 0


def requires_threshold(c: int) -> int:
    return 1 if c in (CAP_DMA, CAP_UPDATE, CAP_DIAGNOSTIC, CAP_POLICY_WRITE) else 0


def capability_rank(c: int) -> int:
    return _CAP_RANK.get(c, 255)


def edge_is_valid(src_domain, dst_domain, capability, src_signed, dst_signed,
                  threshold_ok, wildcard, production) -> int:
    if is_known_domain(src_domain) == 0:
        return 0
    if is_known_domain(dst_domain) == 0:
        return 0
    if is_known_capability(capability) == 0:
        return 0
    if src_signed == 0:
        return 0
    if dst_signed == 0:
        return 0
    if wildcard != 0 and production != 0:
        return 0
    if requires_threshold(capability) != 0 and threshold_ok == 0:
        return 0
    if src_domain == DOMAIN_APP:
        if capability == CAP_POLICY_WRITE:
            return 0
        if capability == CAP_DMA:
            return 0
    if dst_domain == DOMAIN_POLICY:
        if capability != CAP_POLICY_WRITE:
            return 0
    return 1


# --------------------------------------------------------------------------
# Problem model
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class Grant:
    """One candidate capability edge. Mirrors edge_is_valid's parameters."""
    src_domain: int
    dst_domain: int
    capability: int
    src_signed: int = 1
    dst_signed: int = 1
    threshold_ok: int = 1
    wildcard: int = 0
    production: int = 1

    def valid(self) -> bool:
        return edge_is_valid(self.src_domain, self.dst_domain, self.capability,
                             self.src_signed, self.dst_signed,
                             self.threshold_ok, self.wildcard,
                             self.production) == 1

    def rank(self) -> int:
        return capability_rank(self.capability)

    def reach_edge(self):
        return (self.src_domain, self.dst_domain)


@dataclass
class PolicyProblem:
    grants: list[Grant]
    # required reachability: (src_domain, dst_domain) pairs that must stay
    # connected through retained, valid grants (transitively).
    required_reach: list[tuple[int, int]] = field(default_factory=list)

    def reachable_pairs(self, kept: list[bool]) -> set[tuple[int, int]]:
        """Transitive closure over kept+valid grant edges."""
        adj: dict[int, set[int]] = {}
        for g, k in zip(self.grants, kept):
            if k and g.valid():
                adj.setdefault(g.src_domain, set()).add(g.dst_domain)
        closure: set[tuple[int, int]] = set()
        for start in list(adj):
            stack, seen = [start], set()
            while stack:
                n = stack.pop()
                for m in adj.get(n, ()):
                    if (start, m) not in closure:
                        closure.add((start, m))
                    if m not in seen:
                        seen.add(m)
                        stack.append(m)
        return closure

    def satisfies_reach(self, kept: list[bool]) -> bool:
        cl = self.reachable_pairs(kept)
        return all(pair in cl for pair in self.required_reach)

    def cost(self, kept: list[bool]) -> int:
        """Minimization objective: count, tie-broken by summed rank."""
        n = sum(1 for k in kept if k)
        r = sum(g.rank() for g, k in zip(self.grants, kept) if k)
        return n * 1000 + r


# --------------------------------------------------------------------------
# Advisory gate -- the only path a proposal can reach the user.
# --------------------------------------------------------------------------
def accept_proposal(problem: PolicyProblem, kept: list[bool]) -> bool:
    baseline = [True] * len(problem.grants)
    # every retained grant must independently pass the GHL authority
    if any(k and not g.valid() for g, k in zip(problem.grants, kept)):
        return False
    # reachability must be preserved
    if not problem.satisfies_reach(kept):
        return False
    # must not be worse than the (all-valid-grants) baseline
    return problem.cost(kept) <= problem.cost(
        [g.valid() for g in problem.grants]) and problem.cost(kept) <= problem.cost(baseline)


# --------------------------------------------------------------------------
# Classical baselines (always run; QPU must beat or match these)
# --------------------------------------------------------------------------
def brute_force(problem: PolicyProblem):
    n = len(problem.grants)
    best, best_cost = None, math.inf
    if n > 22:
        return None, None  # too wide for exhaustive; rely on annealing
    for bits in itertools.product([False, True], repeat=n):
        kept = list(bits)
        if accept_proposal(problem, kept):
            c = problem.cost(kept)
            if c < best_cost:
                best, best_cost = kept, c
    return best, best_cost


def greedy_drop(problem: PolicyProblem):
    """Simulated-annealing-free greedy: drop the highest-rank droppable grant
    while reachability + validity hold. Cheap classical reference."""
    kept = [g.valid() for g in problem.grants]
    improved = True
    while improved:
        improved = False
        order = sorted(
            (i for i, k in enumerate(kept) if k),
            key=lambda i: -problem.grants[i].rank())
        for i in order:
            trial = list(kept)
            trial[i] = False
            if accept_proposal(problem, trial):
                kept = trial
                improved = True
                break
    return kept, problem.cost(kept)


# --------------------------------------------------------------------------
# QUBO construction (for QAOA -- native rzz couplings, lowered to cz on backends
# that don't expose fractional gates)
# --------------------------------------------------------------------------
def coverers(problem: PolicyProblem) -> dict:
    """For each required reach pair, the indices of *valid* candidate grants
    whose direct edge covers it. (Multi-hop coverage is ignored in the QUBO but
    re-checked by the classical accept gate, which uses full transitive
    closure.)"""
    cov: dict = {pair: [] for pair in problem.required_reach}
    for i, g in enumerate(problem.grants):
        if g.valid() and g.reach_edge() in cov:
            cov[g.reach_edge()].append(i)
    return cov


def build_qubo(problem: PolicyProblem, penalty: float = 40.0,
               invalid_pin: float = 1000.0):
    """Weighted set-cover QUBO. x_i = 1 keeps grant i.

        C(x) = sum_i w_i x_i  +  P * sum_p (1 - sum_{i in cov(p)} x_i)^2

    The first term minimizes retained capability rank; the penalty drives each
    required reach pair to be covered by exactly one kept grant -- this is what
    gives the problem real quadratic structure (rzz couplings between alternative
    coverers) so QAOA is doing genuine work, not rubber-stamping a linear opt.
    Invalid grants get a large linear pin so the QPU can never 'buy' them; the
    classical accept gate is still the final authority. Returns Q as an upper-
    triangular dict {(i,j): coeff} plus the constant offset."""
    n = len(problem.grants)
    Q: dict = {}

    def add(i, j, v):
        key = (i, j) if i <= j else (j, i)
        Q[key] = Q.get(key, 0.0) + v

    for i, g in enumerate(problem.grants):
        add(i, i, g.rank() if g.valid() else invalid_pin)

    const = 0.0
    for _, idxs in coverers(problem).items():
        # (1 - S)^2 = 1 - S + 2*sum_{i<j} x_i x_j   (x binary => x^2 = x)
        const += penalty
        for i in idxs:
            add(i, i, -penalty)
        for a in range(len(idxs)):
            for b in range(a + 1, len(idxs)):
                add(idxs[a], idxs[b], 2.0 * penalty)
    return Q, n, const


def qubo_energy(Q: dict, const: float, bits: list[int]) -> float:
    e = const
    for (i, j), c in Q.items():
        if i == j:
            e += c * bits[i]
        else:
            e += c * bits[i] * bits[j]
    return e


# --------------------------------------------------------------------------
# Example instance matching Grit's 8 domains x 8 capabilities
# --------------------------------------------------------------------------
def example_problem() -> PolicyProblem:
    g = [
        Grant(DOMAIN_APP, DOMAIN_IPC, CAP_IPC),
        Grant(DOMAIN_APP, DOMAIN_DEVICE, CAP_DEVICE, threshold_ok=1),
        Grant(DOMAIN_IPC, DOMAIN_MEMORY, CAP_MEMORY),
        Grant(DOMAIN_DEVICE, DOMAIN_MEMORY, CAP_DMA, threshold_ok=1),
        Grant(DOMAIN_UPDATE, DOMAIN_CRYPTO, CAP_UPDATE, threshold_ok=1),
        Grant(DOMAIN_RECOVERY, DOMAIN_POLICY, CAP_POLICY_WRITE, threshold_ok=1),
        Grant(DOMAIN_APP, DOMAIN_MEMORY, CAP_STORAGE),   # covers (APP,MEMORY) cheap rank2
        Grant(DOMAIN_APP, DOMAIN_MEMORY, CAP_MEMORY),    # ALT coverer of (APP,MEMORY), rank3 -> QAOA must drop
        Grant(DOMAIN_APP, DOMAIN_POLICY, CAP_POLICY_WRITE),  # INVALID: app->policy write
        Grant(DOMAIN_APP, DOMAIN_MEMORY, CAP_DMA),       # INVALID: app dma
        Grant(DOMAIN_CRYPTO, DOMAIN_MEMORY, CAP_MEMORY, wildcard=1, production=1),  # INVALID wildcard in prod
    ]
    req = [
        (DOMAIN_APP, DOMAIN_IPC),
        (DOMAIN_APP, DOMAIN_MEMORY),
        (DOMAIN_RECOVERY, DOMAIN_POLICY),
        (DOMAIN_UPDATE, DOMAIN_CRYPTO),
    ]
    return PolicyProblem(g, req)


# --------------------------------------------------------------------------
# QAOA on a real backend (only used when a token + backend are supplied)
# --------------------------------------------------------------------------
def _qaoa_ansatz(n, Q, p):
    """Standard QAOA ansatz from the QUBO. Linear terms -> rz, quadratic -> rzz
    (the transpiler lowers rzz to cz+sx on backends without fractional gates).
    Parameters: gammas[0..p-1], betas[0..p-1]."""
    from qiskit import QuantumCircuit
    from qiskit.circuit import ParameterVector
    gammas = ParameterVector("g", p)
    betas = ParameterVector("b", p)
    qc = QuantumCircuit(n)
    qc.h(range(n))
    for layer in range(p):
        for (i, j), c in Q.items():
            if c == 0.0:
                continue
            if i == j:
                qc.rz(gammas[layer] * c, i)
            else:
                qc.rzz(gammas[layer] * c, i, j)
        for q in range(n):
            qc.rx(2.0 * betas[layer], q)
    qc.measure_all()
    return qc, list(gammas) + list(betas)


def run_qaoa(problem: PolicyProblem, args):
    import numpy as np
    import itertools as _it
    from qiskit_ibm_runtime import QiskitRuntimeService, SamplerV2 as Sampler
    from qiskit.transpiler import generate_preset_pass_manager

    Q, n, const = build_qubo(problem)
    service = QiskitRuntimeService(channel=args.channel, token=args.token,
                                   instance=args.instance_crn)
    backend = service.backend(args.backend)
    print(f"[+] backend={backend.name} ({backend.num_qubits} qubits) "
          f"QAOA p={args.p} vars={n} shots={args.shots} grid={args.grid}")

    ansatz, params = _qaoa_ansatz(n, Q, args.p)
    pm = generate_preset_pass_manager(optimization_level=2, backend=backend)
    isa = pm.run(ansatz)
    print(f"[+] transpiled: depth={isa.depth()} "
          f"2q_gates={isa.num_nonlocal_gates()}")

    best = {"energy": math.inf, "bits": None}

    def absorb(counts):
        tot = sum(counts.values())
        e = 0.0
        for bitstr, ct in counts.items():
            bits = [int(b) for b in bitstr[::-1]][:n]  # qiskit little-endian
            en = qubo_energy(Q, const, bits)
            e += en * ct
            if en < best["energy"]:
                best["energy"], best["bits"] = en, bits
        return e / tot

    # Open plan: one batched job with the whole parameter grid (no Session,
    # no per-eval queueing). gamma absorbs QUBO scale; beta is the mixer angle.
    axis = np.linspace(0.05, math.pi - 0.05, args.grid)
    grid = list(_it.product(axis, repeat=2 * args.p))  # p gammas + p betas
    pubs = [isa.assign_parameters(dict(zip(params, theta))) for theta in grid]
    print(f"[+] submitting ONE job with {len(pubs)} grid circuits "
          f"x {args.shots} shots (queue once)", flush=True)

    sampler = Sampler(mode=backend)
    sampler.options.default_shots = args.shots
    result = sampler.run(pubs).result()

    best_avg, best_theta = math.inf, None
    for theta, pub in zip(grid, result):
        avg = absorb(pub.data.meas.get_counts())
        if avg < best_avg:
            best_avg, best_theta = avg, theta
    print(f"[+] best grid <C>={best_avg:.3f} at theta={np.round(best_theta,3)}")
    print(f"[+] best sampled bitstring energy={best['energy']:.3f}")
    return [bool(b) for b in best["bits"]]


# --------------------------------------------------------------------------
def emit_advisory(problem, source, kept, cost, args):
    grants_out = []
    for g, k in zip(problem.grants, kept):
        grants_out.append({
            "src_domain": g.src_domain, "dst_domain": g.dst_domain,
            "capability": g.capability, "rank": g.rank(),
            "valid": g.valid(), "kept": bool(k),
        })
    advisory = {
        "advisory": True,
        "authority": "NONE -- proposal only; "
                     "policy_graph_check.ghl + invariant runner decide",
        "source": source,
        "accepted_by_replay_gate": accept_proposal(problem, kept),
        "cost": cost,
        "kept_count": sum(1 for k in kept if k),
        "required_reach_preserved": problem.satisfies_reach(kept),
        "grants": grants_out,
    }
    path = args.out
    with open(path, "w") as f:
        json.dump(advisory, f, indent=2)
    print(f"[+] wrote advisory -> {path} "
          f"(accepted={advisory['accepted_by_replay_gate']})")
    return advisory


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--instance", default="examples",
                   help="problem instance name (only 'examples' built in)")
    p.add_argument("--simulate", action="store_true",
                   help="classical baselines only; no QPU token needed")
    p.add_argument("--backend", default=None, help="IBM Heron r2 backend name")
    p.add_argument("--token", default=os.environ.get("QISKIT_IBM_TOKEN"))
    p.add_argument("--instance-crn", dest="instance_crn", default=None)
    p.add_argument("--channel", default="ibm_cloud")
    p.add_argument("--p", type=int, default=2, help="QAOA depth (reps)")
    p.add_argument("--shots", type=int, default=4096, help="shots per circuit")
    p.add_argument("--grid", type=int, default=6,
                   help="param-scan points per axis (grid**(2p) circuits, one job)")
    p.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "policy_advisory.json"))
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.instance != "examples":
        print("[!] only the built-in 'examples' instance is wired up",
              file=sys.stderr)
        return 2
    problem = example_problem()

    print(f"[+] instance: {len(problem.grants)} candidate grants, "
          f"{sum(g.valid() for g in problem.grants)} valid, "
          f"{len(problem.required_reach)} required-reach pairs")

    bf_kept, bf_cost = brute_force(problem)
    gd_kept, gd_cost = greedy_drop(problem)
    print(f"[+] brute force : cost={bf_cost} kept={sum(bf_kept) if bf_kept else 'n/a'}")
    print(f"[+] greedy drop : cost={gd_cost} kept={sum(gd_kept)}")

    if args.simulate or not args.backend:
        if not args.backend and not args.simulate:
            print("[i] no --backend given; running classical-only "
                  "(pass --simulate to silence this).")
        best_kept = bf_kept if bf_kept is not None else gd_kept
        best_cost = bf_cost if bf_kept is not None else gd_cost
        return 0 if emit_advisory(problem, "classical", best_kept,
                                  best_cost, args)["accepted_by_replay_gate"] else 1

    # live QPU path
    q_kept = run_qaoa(problem, args)
    q_cost = problem.cost(q_kept)
    print(f"[+] QAOA        : cost={q_cost} kept={sum(q_kept)} "
          f"accepted={accept_proposal(problem, q_kept)}")
    # QPU must beat-or-match the best classical; otherwise emit classical.
    candidates = [("qaoa", q_kept, q_cost)]
    if gd_kept is not None:
        candidates.append(("greedy", gd_kept, gd_cost))
    if bf_kept is not None:
        candidates.append(("brute", bf_kept, bf_cost))
    candidates = [c for c in candidates if accept_proposal(problem, c[1])]
    src, kept, cost = min(candidates, key=lambda c: c[2])
    adv = emit_advisory(problem, src, kept, cost, args)
    return 0 if adv["accepted_by_replay_gate"] else 1


if __name__ == "__main__":
    sys.exit(main())
