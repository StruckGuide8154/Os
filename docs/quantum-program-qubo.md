# Coupled whole-program QUBO for the GHL optimizer (quantum handoff, item C)

Advisory-only. The QPU/solver only **proposes** an optimizer knob configuration;
the **acceptance authority** is a deterministic replay of the real `gritc.py`
compile. No quantum dependency enters the build. Mirrors the discipline of
`tools/quantum/policy_graph_qaoa.py`.

## Files

- `tools/quantum/program_qubo.py` — builds the coupled QUBO, solves it
  classically (brute force / annealing), and gates every proposal through the
  replay authority. Real-backend QAOA on `ibm_kingston` is present but gated
  behind `--enable-hardware` (OFF by default, billable, human-only).
- `tools/quantum/gritc_replay.py` — the **acceptance authority**: re-runs the
  real `gritc.py` compile with the proposed per-wrapper inline knobs, measures
  the real emitted instruction-line count, and assembles the body with NASM
  (`-f elf64`, inlined macro stub) to confirm no new undefined symbols.
- `tools/quantum/test_program_qubo.py` — pure-Python unit tests for energy /
  cross-term correctness and non-separability (no gritc/NASM needed).

## Variables (the four coupled knob families)

| family | QUBO variable | real compiler knob |
|---|---|---|
| per-wrapper inline | `x_inl[w]` (1 bit/wrapper) | `GRITC_O4_INLINE_SET` / `GRITC_O4_NOINLINE_SET` (per wrapper); coarse form is `GRITC_O4_MAXCALLS` |
| register coloring | `x_col[s,c]` (one-hot per slot) | per-fn graph-coloring instance gritc exports via `GRITC_QUBO_OUT` / `_qubo_export_regalloc` |
| instruction selection | `x_isel[t,k]` (one-hot per site) | modelled (no per-site compiler override yet) |
| block layout | `x_lay[b]` | modelled (no per-block override yet) |

## Cross-terms (why it is NP-hard / quantum-worthwhile)

A separable/diagonal QUBO would be the easy case and is explicitly rejected
(`is_diagonal` guard + `test_not_diagonal`). The coupling terms:

1. **inline × coloring** (`inl_pressure`, positive): inlining wrapper `w` grows
   its caller and raises register pressure, so coloring a competing slot *and*
   inlining `w` together is penalized — they fight over the same callee-saved
   registers.
2. **inline × isel** (`inl_isel`, negative): inlining `w` turns an operand into
   a constant / same-register, unlocking a cheaper encoding tile at a site.
3. **inline × layout** (`inl_layout`, negative): inlining `w` merges a block into
   its caller, so that block's fall-through (jmp-drop) win only exists when `w`
   is inlined.

These make the joint optimum non-separable: the best inline set depends on the
coloring/isel/layout choices and vice-versa.

## Acceptance protocol (load-bearing)

For every proposed bit vector:

1. Map inline bits → `GRITC_O4_INLINE_SET` / `GRITC_O4_NOINLINE_SET`.
2. Re-run the **real** `gritc.py --O4 --embed` compile with those env vars.
3. Measure real emitted instruction-lines; assemble with NASM and collect any
   undefined symbols.
4. **Accept iff**: compiles, assembles with **no new undefined symbols**, and
   size ≤ the classical O4-default baseline.

A proposal that fails any check is rejected and the classical O4 baseline (the
shipped output) is used unchanged. The QUBO energy never authorizes shipped code
— only a verified-smaller real compile can.

### Knob-coverage caveat (conservative)

Only the **per-wrapper inline** family is wired end-to-end through the real
compiler today (gritc's `GRITC_O4_INLINE_SET` / `NOINLINE_SET` overrides, added
gated behind `--O4`). The coloring / isel / layout families are modelled in the
QUBO energy (so the cross-terms and the NP-hard shape are genuine) and the
regalloc family is exported for the QPU, but they have no per-decision compiler
override yet — so the replay gate measures their effect only through the inline
knob it can actually drive. This is deliberate: we never ship a predicted win the
real compiler can't reproduce and assemble. Giving gritc per-decision
coloring/isel/layout overrides is a drop-in follow-up (add the env vars, then set
them in `gritc_replay.compile_app`).

## Run it (classical, no token)

```
python tools/quantum/program_qubo.py --app settings --simulate
```

Writes `tools/quantum/program_advisory.json` with the QUBO sizes, the proposed
inline/no-inline sets, the measured proposed vs baseline instruction-lines, and
`accepted_by_replay_gate`.

Measured (instr-lines, classical `--simulate`, default `--max-vars 40`):

| app | baseline O4 | proposed | delta | accepted |
|---|---|---|---|---|
| settings | 4657 | 4643 | −14 | yes |
| taskmgr | 3014 | 2990 | −24 | yes |
| paint | 3287 | 3272 | −15 | yes |

(The win comes from inlining wrappers the global `GRITC_O4_MAXCALLS=4` threshold
keeps standalone; each still assembles clean.)

## Enabling the real ibm_kingston backend (human only)

Billable external action — **not** run by CI or by Claude. The token is read only
from `QISKIT_IBM_TOKEN`; it is never hardcoded, printed, or written to any file.

```
export QISKIT_IBM_TOKEN=...            # already in the dev env; never committed
python tools/quantum/program_qubo.py --app settings \
    --backend ibm_kingston --instance-crn <CRN> --enable-hardware --p 2
```

Without `--enable-hardware` the hardware path is skipped even if a token and
backend are supplied. The QAOA proposal is still gated by the same replay
authority — a QPU result can only win if its real recompile is verifiably
smaller-or-equal and assembles.
```
```
