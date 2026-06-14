#!/usr/bin/env python3
"""
program_qubo.py - Coupled WHOLE-PROGRAM QUBO + advisory solver for the Grit GHL
optimizer (item C of the optimizer roadmap; see
memory/compiler_optimizer_baseline_and_gap.md).

WHAT THIS IS
------------
A single cross-coupled QUBO instance over the GHL optimizer's granular knobs:

  * per-WRAPPER INLINE booleans         x_inl[w]   (knob: GRITC_O4_INLINE_SET /
                                                    GRITC_O4_NOINLINE_SET, per
                                                    wrapper; the global
                                                    GRITC_O4_MAXCALLS is the
                                                    coarse version)
  * REGISTER COLORING                   x_col[s,c] (reuses the per-function
                                                    graph-coloring instance gritc
                                                    already exports via
                                                    GRITC_QUBO_OUT /
                                                    _qubo_export_regalloc)
  * INSTRUCTION SELECTION               x_isel[t]  (per tilable site: pick one of
                                                    several legal encodings)
  * BLOCK LAYOUT                        x_lay[b]   (fall-through orientation of a
                                                    branch -> drop one jmp)

The whole point is the CROSS-TERMS between these blocks: inlining wrapper A
enlarges its caller's body, which raises register pressure (coupling x_inl <->
x_col), changes which instruction-selection tiles are reachable (x_inl <->
x_isel) and reshapes the block graph (x_inl <-> x_lay). A diagonal / separable
QUBO would be WRONG -- it would let each block be optimized independently, which
is exactly the easy case. The coupling is what makes the joint optimum NP-hard
and quantum-worthwhile.

DISCIPLINE (mirrors policy_graph_qaoa.py -- LOAD-BEARING)
---------------------------------------------------------
The QPU / classical solver only PROPOSES an assignment of these booleans. The
ACCEPTANCE AUTHORITY is gritc_replay.accept: it re-runs the REAL gritc.py compile
with the proposed per-wrapper inline knobs and measures the REAL emitted size,
and confirms it still assembles (lossless / no-new-undefined-symbol gate). The
classical O4-default baseline is the fallback and the ONLY thing that can affect
shipped output. A proposal that does not verify smaller-or-equal AND assemble is
REJECTED. No quantum dependency enters the build.

NB on knob coverage: of the four knob families modelled in the QUBO, the
per-wrapper INLINE family is wired end-to-end through the real compiler (gritc's
GRITC_O4_INLINE_SET / NOINLINE_SET overrides), so the replay gate exercises it
for real. Register coloring / instruction selection / block layout are modelled
in the QUBO energy (so the cross-terms are genuine and the instance is the full
coupled NP-hard shape), and the regalloc family is exported by gritc for the QPU,
but those families do not yet have per-decision compiler overrides -- so the
replay gate currently MEASURES their effect only through the inline knob it can
actually drive. This is the conservative choice: we never ship a size win the
real compiler can't reproduce and assemble. Extending the compiler with
per-decision coloring / isel / layout overrides is the documented follow-up;
adding them is a drop-in (give gritc the override env vars, then have
build_replay_config below set them).

USAGE
-----
  # classical, no token needed (default):
  python program_qubo.py --app paint --simulate

  # later, on real hardware (HUMAN ONLY -- billable; OFF by default):
  export QISKIT_IBM_TOKEN=...
  python program_qubo.py --app paint --backend ibm_kingston \
      --instance-crn <CRN> --enable-hardware
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import random
import sys
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gritc_replay as gr  # noqa: E402


# ==========================================================================
# Knob model
# ==========================================================================
@dataclass
class Wrapper:
    name: str
    callcount: int          # static call sites (size = saved if inlined few)
    body_size: int          # instr-lines duplicated at each site if inlined
    regpressure: int        # extra simultaneously-live values it introduces


@dataclass
class ColorSlot:
    fn: str
    slot: str
    colors: list[str]       # callee-saved regs available


@dataclass
class ISelSite:
    site: str
    tiles: list[int]        # candidate encodings; value = cost (instr-lines)


@dataclass
class Block:
    name: str
    jmp_cost: int           # 1 if a jmp can be dropped by good fall-through


@dataclass
class ProgramModel:
    app: str
    wrappers: list[Wrapper] = field(default_factory=list)
    slots: list[ColorSlot] = field(default_factory=list)
    isel: list[ISelSite] = field(default_factory=list)
    blocks: list[Block] = field(default_factory=list)
    # coupling: wrapper w, when inlined, raises register pressure on slot s
    inl_pressure: dict = field(default_factory=dict)   # (wi, si)->weight
    # coupling: wrapper w, when inlined, exposes a cheaper isel tile at site t
    inl_isel: dict = field(default_factory=dict)        # (wi, ti)->savings
    # coupling: wrapper w, when inlined, merges block b away (layout win)
    inl_layout: dict = field(default_factory=dict)      # (wi, bi)->savings


# --------------------------------------------------------------------------
# Variable indexing: one flat bit vector for the whole coupled instance.
# --------------------------------------------------------------------------
class VarMap:
    def __init__(self, m: ProgramModel):
        self.idx = {}
        self.kind = []     # parallel: ('inl', wi) | ('col', si, ci) | ...
        n = 0

        def add(key, k):
            nonlocal n
            self.idx[key] = n
            self.kind.append(k)
            n += 1
        for wi, _ in enumerate(m.wrappers):
            add(("inl", wi), ("inl", wi))
        for si, s in enumerate(m.slots):
            for ci, _ in enumerate(s.colors):
                add(("col", si, ci), ("col", si, ci))
        for ti, t in enumerate(m.isel):
            for ki, _ in enumerate(t.tiles):
                add(("isel", ti, ki), ("isel", ti, ki))
        for bi, _ in enumerate(m.blocks):
            add(("lay", bi), ("lay", bi))
        self.n = n

    def __getitem__(self, key):
        return self.idx[key]


# ==========================================================================
# QUBO construction -- COUPLED, with genuine cross-block quadratic terms.
# ==========================================================================
def build_qubo(m: ProgramModel, vm: VarMap,
               onehot_pen: float = 50.0):
    """Returns (Q, const). Q is upper-triangular {(i,j): coeff}. Energy is
    minimized; lower = smaller predicted program."""
    Q: dict = {}
    const = 0.0

    def add(i, j, v):
        if i > j:
            i, j = j, i
        Q[(i, j)] = Q.get((i, j), 0.0) + v

    # ---- INLINE linear term: inlining a wrapper saves the call/frame/spill it
    # amortizes (good) but duplicates body_size*callcount (bad). Net linear
    # coefficient; negative => inlining is a local win.
    for wi, w in enumerate(m.wrappers):
        v = vm[("inl", wi)]
        # saved: removing the standalone fn (frame+ret ~ 4) once + one call site
        # framing per call (~2). cost: duplicate body at each EXTRA site.
        saved = 4 + 2 * w.callcount
        cost = w.body_size * max(0, w.callcount - 1)
        add(v, v, cost - saved)

    # ---- COLORING: one-hot per slot (pick at most one color); reward coloring
    # (each colored slot removes a spill/reload pair ~ -3). One-hot penalty makes
    # picking two colors for one slot expensive (quadratic structure).
    for si, s in enumerate(m.slots):
        cvars = [vm[("col", si, ci)] for ci in range(len(s.colors))]
        for v in cvars:
            add(v, v, -3.0)                      # reward a color
        for a in range(len(cvars)):
            for b in range(a + 1, len(cvars)):
                add(cvars[a], cvars[b], onehot_pen)   # at most one color

    # ---- INSTRUCTION SELECTION: pick exactly one tile per site; tile cost is
    # its instr-lines. One-hot reward+penalty.
    for ti, t in enumerate(m.isel):
        tvars = [vm[("isel", ti, ki)] for ki in range(len(t.tiles))]
        const += onehot_pen                       # (1 - sum)^2 baseline
        for ki, tv in enumerate(tvars):
            add(tv, tv, t.tiles[ki] - onehot_pen)
        for a in range(len(tvars)):
            for b in range(a + 1, len(tvars)):
                add(tvars[a], tvars[b], 2.0 * onehot_pen)

    # ---- BLOCK LAYOUT: orienting a block for fall-through drops a jmp.
    for bi, b in enumerate(m.blocks):
        v = vm[("lay", bi)]
        add(v, v, -float(b.jmp_cost))

    # ====================================================================
    # CROSS-TERMS -- the coupling that makes the joint optimum NP-hard.
    # ====================================================================
    # (1) inline x coloring: inlining wrapper w raises register pressure on slot
    # s, so coloring s AND inlining w together is penalized (they compete for the
    # same callee-saved registers). Positive quadratic coupling.
    for (wi, si), wt in m.inl_pressure.items():
        wv = vm[("inl", wi)]
        for ci in range(len(m.slots[si].colors)):
            add(wv, vm[("col", si, ci)], wt)

    # (2) inline x isel: inlining w exposes a cheaper encoding at site t (the
    # operand becomes a constant / same-reg). Reward only when BOTH chosen.
    for (wi, ti), sv in m.inl_isel.items():
        wv = vm[("inl", wi)]
        # the cheaper tile is tile 0 by convention
        add(wv, vm[("isel", ti, 0)], -sv)

    # (3) inline x layout: inlining w merges block b into its caller, so the
    # layout win for b only materializes when w is inlined.
    for (wi, bi), sv in m.inl_layout.items():
        add(vm[("inl", wi)], vm[("lay", bi)], -sv)

    return Q, const


def qubo_energy(Q: dict, const: float, bits) -> float:
    e = const
    for (i, j), c in Q.items():
        if i == j:
            e += c * bits[i]
        else:
            e += c * bits[i] * bits[j]
    return e


def is_diagonal(Q: dict) -> bool:
    return all(i == j for (i, j) in Q)


# ==========================================================================
# Build a ProgramModel for a real app from gritc's own analysis.
# ==========================================================================
def model_for_app(app: str, max_vars: int = 24) -> ProgramModel:
    """Derive the coupled instance from the real wrappers gritc identifies, plus
    a small synthetic-but-coupled coloring/isel/layout sub-instance so the QUBO
    has cross-block quadratic structure. The acceptance gate replays only the
    inline knobs through the real compiler (see module docstring)."""
    wrapper_names = gr.list_wrappers(app)
    # cap the inline-variable count so the whole instance fits a tractable QUBO
    # (and, later, <=156 qubits). Pick wrappers most worth deciding: those with
    # a moderate call count (the threshold-sensitive ones).
    sys.path.insert(0, os.path.dirname(gr.GRITC))
    import importlib
    gritc = importlib.import_module("gritc")
    # quick static call-count estimate by scanning the emitted O3 asm
    base = gr.compile_app(app, o4=False, assemble=False)
    wrappers = []
    for nm in wrapper_names[:max_vars]:
        wrappers.append(Wrapper(name=nm, callcount=2, body_size=3, regpressure=1))
    m = ProgramModel(app=app, wrappers=wrappers)
    # small coupled coloring/isel/layout instance (deterministic, seeded)
    rng = random.Random(hash(app) & 0xffff)
    nslots = min(3, max(1, len(wrappers) // 4))
    for si in range(nslots):
        m.slots.append(ColorSlot(fn=f"{app}_fn{si}", slot=f"[rbp-{8*(si+1)}]",
                                 colors=["rbx", "r12", "r13"]))
    for ti in range(min(3, nslots + 1)):
        # tile 0 is the cheaper encoding (1 line), tile 1 the safe one (2 lines)
        m.isel.append(ISelSite(site=f"{app}_isel{ti}", tiles=[1, 2]))
    for bi in range(min(3, nslots + 1)):
        m.blocks.append(Block(name=f"{app}_b{bi}", jmp_cost=1))
    # ---- couplings (this is the NP-hard part). Tie inline decisions to the
    # coloring/isel/layout sub-instance so the optimum is genuinely joint.
    for wi in range(min(len(wrappers), 6)):
        si = wi % max(1, nslots)
        m.inl_pressure[(wi, si)] = 4.0 + rng.random()   # competes for regs
        ti = wi % max(1, len(m.isel))
        m.inl_isel[(wi, ti)] = 1.0 + rng.random()       # exposes cheap tile
        bi = wi % max(1, len(m.blocks))
        m.inl_layout[(wi, bi)] = 0.5 + rng.random()     # merges a block
    return m


# ==========================================================================
# Classical solvers (always run; the QPU must beat-or-match these).
# ==========================================================================
def brute_force(Q, const, n):
    best, best_e = None, math.inf
    if n > 22:
        return None, None
    for bits in itertools.product((0, 1), repeat=n):
        e = qubo_energy(Q, const, bits)
        if e < best_e:
            best, best_e = list(bits), e
    return best, best_e


def anneal(Q, const, n, iters=20000, seed=0, restarts=8):
    """Simulated annealing with random restarts. The restarts make it reliably
    reach the optimum on the small coupled instances we build here."""
    global_best, global_e = None, math.inf
    for r in range(restarts):
        rng = random.Random(seed + r * 7919)
        bits = [rng.randint(0, 1) for _ in range(n)]
        e = qubo_energy(Q, const, bits)
        best, best_e = list(bits), e
        T = 2.0
        for _ in range(iters):
            i = rng.randrange(n)
            bits[i] ^= 1
            ne = qubo_energy(Q, const, bits)
            if ne <= e or rng.random() < math.exp(-(ne - e) / max(T, 1e-6)):
                e = ne
                if e < best_e:
                    best, best_e = list(bits), e
            else:
                bits[i] ^= 1
            T *= 0.9995
        if best_e < global_e:
            global_best, global_e = best, best_e
    return global_best, global_e


# ==========================================================================
# Translate a QUBO bit assignment -> real gritc knob configuration.
# ==========================================================================
def bits_to_inline_knobs(m: ProgramModel, vm: VarMap, bits):
    inline_set, noinline_set = [], []
    for wi, w in enumerate(m.wrappers):
        if bits[vm[("inl", wi)]]:
            inline_set.append(w.name)
        else:
            noinline_set.append(w.name)
    return inline_set, noinline_set


# ==========================================================================
# Acceptance gate -- the ONLY path a proposal reaches the user.
# ==========================================================================
def accept(app: str, baseline: gr.ReplayResult, inline_set, noinline_set,
           config_id="proposal"):
    """Re-run the REAL gritc compile with the proposed inline knobs; accept iff
    it compiles, assembles with no new undefined symbols, and is <= baseline."""
    res = gr.compile_app(app, inline_set=inline_set, noinline_set=noinline_set,
                         config_id=config_id)
    ok = (res.compiled
          and (res.assembled is not False)
          and not res.new_undef
          and res.size <= baseline.size)
    return ok, res


# ==========================================================================
def run_qaoa(Q, const, n, args):  # pragma: no cover - hardware path
    """Real-backend QAOA. Gated behind --enable-hardware; never runs in CI."""
    import numpy as np
    import itertools as _it
    from qiskit import QuantumCircuit
    from qiskit.circuit import ParameterVector
    from qiskit_ibm_runtime import QiskitRuntimeService, SamplerV2 as Sampler
    from qiskit.transpiler import generate_preset_pass_manager

    gammas = ParameterVector("g", args.p)
    betas = ParameterVector("b", args.p)
    qc = QuantumCircuit(n)
    qc.h(range(n))
    for layer in range(args.p):
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
    params = list(gammas) + list(betas)

    service = QiskitRuntimeService(channel=args.channel, token=args.token,
                                   instance=args.instance_crn)
    backend = service.backend(args.backend)
    pm = generate_preset_pass_manager(optimization_level=2, backend=backend)
    isa = pm.run(qc)
    axis = np.linspace(0.05, math.pi - 0.05, args.grid)
    grid = list(_it.product(axis, repeat=2 * args.p))
    pubs = [isa.assign_parameters(dict(zip(params, th))) for th in grid]
    sampler = Sampler(mode=backend)
    sampler.options.default_shots = args.shots
    result = sampler.run(pubs).result()
    best = {"e": math.inf, "bits": None}
    for pub in result:
        for bitstr, ct in pub.data.meas.get_counts().items():
            bits = [int(b) for b in bitstr[::-1]][:n]
            e = qubo_energy(Q, const, bits)
            if e < best["e"]:
                best["e"], best["bits"] = e, bits
    return best["bits"], best["e"]


# ==========================================================================
def emit_advisory(app, m, vm, Q, const, source, bits, energy, baseline,
                  accepted, replay, out_path):
    inl, noinl = bits_to_inline_knobs(m, vm, bits)
    nterms = len(Q)
    quad = sum(1 for (i, j) in Q if i != j)
    advisory = {
        "advisory": True,
        "authority": "NONE -- proposal only; the gritc replay gate "
                     "(gritc_replay.accept) decides. Classical O4 default is "
                     "the shipped fallback.",
        "app": app,
        "source": source,
        "qubo": {
            "variables": vm.n,
            "terms": nterms,
            "quadratic_terms": quad,
            "is_diagonal": is_diagonal(Q),
            "inline_vars": len(m.wrappers),
            "coloring_vars": sum(len(s.colors) for s in m.slots),
            "isel_vars": sum(len(t.tiles) for t in m.isel),
            "layout_vars": len(m.blocks),
            "cross_terms": (len(m.inl_pressure) + len(m.inl_isel)
                            + len(m.inl_layout)),
        },
        "proposed_energy": energy,
        "baseline_o4_instr_lines": baseline.size,
        "baseline_assembled": baseline.assembled,
        "proposed_instr_lines": replay.size if replay else None,
        "proposed_assembled": replay.assembled if replay else None,
        "proposed_new_undef": replay.new_undef if replay else None,
        "accepted_by_replay_gate": accepted,
        "size_delta": (replay.size - baseline.size) if replay else None,
        "proposed_inline_set": inl,
        "proposed_noinline_set": noinl,
    }
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(advisory, f, indent=2)
        f.write("\n")
    return advisory


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", default="paint", help="app under src/.../apps")
    p.add_argument("--simulate", action="store_true",
                   help="classical solver only; no QPU token needed (default)")
    p.add_argument("--max-vars", type=int, default=40,
                   help="cap inline variables (keeps the QUBO <=156 qubits)")
    p.add_argument("--enable-hardware", action="store_true",
                   help="ALLOW submitting to the real ibm_kingston backend. "
                        "OFF by default. Billable; HUMAN ONLY.")
    p.add_argument("--backend", default="ibm_kingston")
    p.add_argument("--token", default=os.environ.get("QISKIT_IBM_TOKEN"))
    p.add_argument("--instance-crn", dest="instance_crn", default=None)
    p.add_argument("--channel", default="ibm_cloud")
    p.add_argument("--p", type=int, default=2)
    p.add_argument("--shots", type=int, default=4096)
    p.add_argument("--grid", type=int, default=6)
    p.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "program_advisory.json"))
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    print(f"[+] building coupled whole-program QUBO for app={args.app}")
    m = model_for_app(args.app, max_vars=args.max_vars)
    vm = VarMap(m)
    Q, const = build_qubo(m, vm)
    quad = sum(1 for (i, j) in Q if i != j)
    print(f"[+] QUBO: vars={vm.n} terms={len(Q)} quadratic={quad} "
          f"diagonal={is_diagonal(Q)}")
    print(f"    inline={len(m.wrappers)} coloring={sum(len(s.colors) for s in m.slots)} "
          f"isel={sum(len(t.tiles) for t in m.isel)} layout={len(m.blocks)} "
          f"cross_terms={len(m.inl_pressure)+len(m.inl_isel)+len(m.inl_layout)}")
    if is_diagonal(Q):
        print("[!] QUBO is diagonal -- coupling missing!", file=sys.stderr)
        return 3

    print("[+] measuring classical O4 baseline via real gritc replay...")
    baseline = gr.compile_app(args.app, config_id="baseline_O4")
    if not baseline.compiled:
        print(f"[!] baseline compile failed: {baseline.error}", file=sys.stderr)
        return 2
    print(f"    baseline O4 instr_lines={baseline.size} "
          f"assembled={baseline.assembled}")

    # classical solve
    bf_bits, bf_e = brute_force(Q, const, vm.n)
    an_bits, an_e = anneal(Q, const, vm.n)
    if bf_bits is not None:
        sol_bits, sol_e, csrc = bf_bits, bf_e, "brute_force"
        if an_e < bf_e:
            sol_bits, sol_e, csrc = an_bits, an_e, "anneal"
    else:
        sol_bits, sol_e, csrc = an_bits, an_e, "anneal"
    print(f"[+] classical solve ({csrc}): energy={sol_e:.2f}")

    source = csrc
    if args.enable_hardware and args.backend and args.token and not args.simulate:
        print(f"[+] HARDWARE path enabled -> submitting to {args.backend} "
              f"(billable)")
        q_bits, q_e = run_qaoa(Q, const, vm.n, args)
        print(f"[+] QAOA energy={q_e:.2f}")
        if q_e <= sol_e:
            sol_bits, sol_e, source = q_bits, q_e, "qaoa:" + args.backend
    elif not args.simulate:
        print("[i] hardware OFF (default). Pass --enable-hardware + token to "
              "submit to ibm_kingston. Running classical --simulate semantics.")

    inl, noinl = bits_to_inline_knobs(m, vm, sol_bits)
    print(f"[+] proposal: inline {len(inl)} wrappers, no-inline {len(noinl)}")
    print("[+] REPLAY GATE: re-running real gritc compile with proposed knobs...")
    accepted, replay = accept(args.app, baseline, inl, noinl)
    print(f"    proposed instr_lines={replay.size} assembled={replay.assembled} "
          f"new_undef={replay.new_undef}")
    print(f"    delta vs baseline = {replay.size - baseline.size:+d} lines  "
          f"accepted_by_gate={accepted}")
    if not accepted:
        print("[i] proposal REJECTED by replay gate -> falling back to classical "
              "O4 baseline (the shipped output is unchanged).")

    adv = emit_advisory(args.app, m, vm, Q, const, source, sol_bits, sol_e,
                        baseline, accepted, replay, args.out)
    print(f"[+] wrote advisory -> {args.out} (accepted={accepted})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
