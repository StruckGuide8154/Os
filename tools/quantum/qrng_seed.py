#!/usr/bin/env python3
"""
qrng_seed.py - Harvest noisy quantum samples from an IBM Quantum backend and
condition them into a Grit build-diversity seed blob.

WHAT THIS IS
------------
This runs random circuits across a connected set of qubits on an IBM
Heron-class machine and collects measured bitstrings. Entangling layers are
drawn from disjoint edges in the backend coupling map, avoiding an accidental
linear-connectivity assumption and unnecessary routing SWAPs.

Raw samples are biased, noisy, and not device-independently certified. We do
not use them directly. A von Neumann pass and Toeplitz universal hash provide
conditioning, but the simple bias estimate in this tool is diagnostic rather
than a cryptographic entropy proof. The private extracted seed is never compiled
into a release. Grit ships only SHA-256(seed), a public commitment signed as part
of KERNEL.BIN and mixed as a KDF salt/domain separator. Fresh hardware entropy
remains the secret input.

OUTPUT
------
  seed.bin          private extracted seed bytes (never ship or compile in)
  qrng_commitment.txt  public SHA-256(seed), safe to sign and distribute
  qrng_manifest.txt provenance (backend, job ids, depth, shots, entropy est.)

USAGE
-----
  pip install -r requirements.txt
  export QISKIT_IBM_TOKEN=...           # or pass --token
  python qrng_seed.py --backend ibm_fez --minutes 5 --out-bytes 1024

You hand me the token / backend name when you're ready to connect.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import math
import os
import sys
import time

import numpy as np


# --------------------------------------------------------------------------
# Circuit construction: deep, hardware-native random circuits
# --------------------------------------------------------------------------
def _canonical_edges(edges, allowed_qubits):
    allowed = set(allowed_qubits)
    return sorted({tuple(sorted((a, b))) for a, b in edges
                   if a != b and a in allowed and b in allowed})


def select_connected_qubits(num_qubits: int, edges, count: int) -> list[int]:
    """Select a deterministic connected physical-qubit subset."""
    if count < 1 or count > num_qubits:
        raise ValueError("qubit count must be between 1 and backend width")
    if count == num_qubits:
        return list(range(num_qubits))

    adjacency = {q: set() for q in range(num_qubits)}
    for a, b in _canonical_edges(edges, range(num_qubits)):
        adjacency[a].add(b)
        adjacency[b].add(a)

    for start in sorted(adjacency, key=lambda q: (-len(adjacency[q]), q)):
        selected = []
        seen = {start}
        queue = [start]
        while queue and len(selected) < count:
            q = queue.pop(0)
            selected.append(q)
            for neighbor in sorted(adjacency[q],
                                   key=lambda n: (-len(adjacency[n]), n)):
                if neighbor not in seen:
                    seen.add(neighbor)
                    queue.append(neighbor)
        if len(selected) == count:
            return sorted(selected)
    raise ValueError(f"no connected {count}-qubit subset in coupling map")


def _random_matching(edges, rng: np.random.Generator):
    """Return a random maximal matching for one parallel CZ layer."""
    order = rng.permutation(len(edges))
    used = set()
    matching = []
    for i in order:
        a, b = edges[int(i)]
        if a in used or b in used:
            continue
        matching.append((a, b))
        used.add(a)
        used.add(b)
    return matching


def build_random_circuit(num_qubits: int, depth: int, rng: np.random.Generator,
                         coupling_edges):
    """Build native-shape random layers followed by full measurement."""
    from qiskit import QuantumCircuit

    qc = QuantumCircuit(num_qubits, num_qubits)
    edges = _canonical_edges(coupling_edges, range(num_qubits))
    if num_qubits > 1 and not edges:
        raise ValueError("selected qubits contain no coupling-map edges")
    for _ in range(depth):
        # RZ is virtual on IBM hardware; SX is a calibrated native pulse.
        for q in range(num_qubits):
            qc.rz(rng.uniform(0, 2 * math.pi), q)
            if rng.integers(0, 2):
                qc.sx(q)
            else:
                qc.x(q)
            qc.rz(rng.uniform(0, 2 * math.pi), q)
        for a, b in _random_matching(edges, rng):
            qc.cz(a, b)
    qc.measure(range(num_qubits), range(num_qubits))
    return qc


# --------------------------------------------------------------------------
# Randomness extraction
# --------------------------------------------------------------------------
def von_neumann_debias(bits: np.ndarray) -> np.ndarray:
    """Classic von Neumann extractor: map bit pairs 01->0, 10->1, drop 00/11.
    Removes first-order bias regardless of the (unknown) bias value. Throws
    away ~75%+ of bits but the survivors are much closer to fair."""
    pairs = bits[: (len(bits) // 2) * 2].reshape(-1, 2)
    keep = pairs[:, 0] != pairs[:, 1]
    return pairs[keep, 0].astype(np.uint8)


def toeplitz_extract(bits: np.ndarray, out_bits: int, seed: int) -> np.ndarray:
    """Toeplitz-hashing strong extractor.

    A Toeplitz matrix is a universal hash family; the Leftover Hash Lemma
    guarantees the output is within negligible statistical distance of
    uniform as long as the input min-entropy k satisfies
        k >= out_bits + 2*log2(1/eps).
    We build an (out_bits x in_bits) Toeplitz matrix from a public random
    seed and multiply over GF(2)."""
    in_bits = len(bits)
    if in_bits < out_bits:
        raise ValueError(
            f"not enough input bits ({in_bits}) for {out_bits} output bits"
        )
    sd_rng = np.random.default_rng(seed)
    # Toeplitz defined by its first column (out_bits) + first row (in_bits-1)
    col = sd_rng.integers(0, 2, size=out_bits, dtype=np.uint8)
    row = sd_rng.integers(0, 2, size=in_bits - 1, dtype=np.uint8)
    gen = np.concatenate([col[::-1], row])  # length out_bits + in_bits - 1

    out = np.zeros(out_bits, dtype=np.uint8)
    x = bits.astype(np.uint8)
    for i in range(out_bits):
        # row i of the Toeplitz matrix is a sliding window over `gen`
        window = gen[out_bits - 1 - i : out_bits - 1 - i + in_bits]
        out[i] = np.bitwise_xor.reduce(window & x)
    return out


def bits_to_bytes(bits: np.ndarray) -> bytes:
    n = (len(bits) // 8) * 8
    return np.packbits(bits[:n]).tobytes()


def estimate_min_entropy_per_bit(bits: np.ndarray) -> float:
    """Crude min-entropy estimate from the most-common-bit frequency.
    H_inf = -log2(p_max). Conservative; real certification needs more."""
    p1 = bits.mean()
    p_max = max(p1, 1 - p1)
    p_max = min(max(p_max, 1e-9), 1 - 1e-9)
    return -math.log2(p_max)


# --------------------------------------------------------------------------
# Main harvest loop
# --------------------------------------------------------------------------
def harvest(args) -> None:
    from qiskit.transpiler import generate_preset_pass_manager
    from qiskit_ibm_runtime import QiskitRuntimeService, SamplerV2 as Sampler

    # --- Authenticate against the current IBM Quantum Platform ----------
    # New platform (quantum.cloud.ibm.com) uses channel="ibm_cloud" + a CRN
    # instance. If neither token nor CRN is passed we fall back to a
    # previously saved account (QiskitRuntimeService.save_account(...)).
    token = args.token or os.environ.get("QISKIT_IBM_TOKEN")
    if token or args.instance:
        service = QiskitRuntimeService(
            channel=args.channel, token=token, instance=args.instance)
    else:
        service = QiskitRuntimeService()  # saved account
    backend = service.backend(args.backend)
    backend_edges = list(backend.coupling_map.get_edges())
    nq = min(args.qubits or backend.num_qubits, backend.num_qubits)
    physical_qubits = select_connected_qubits(backend.num_qubits,
                                              backend_edges, nq)
    physical_to_logical = {q: i for i, q in enumerate(physical_qubits)}
    logical_edges = [(physical_to_logical[a], physical_to_logical[b])
                     for a, b in _canonical_edges(backend_edges,
                                                  physical_qubits)]
    print(f"[+] backend={backend.name} qubits={nq} "
          f"max_shots={getattr(backend, 'max_shots', 'n/a')}")

    # --- Build all circuits up front -----------------------------------
    # On the free Open Plan jobs sit in a QUEUE and the budget you have is
    # QPU *execution* time, not wall-clock. So we submit every circuit in a
    # SINGLE job: one queue wait, then all circuits run back-to-back. Tune
    # the QPU-time spend with --circuits x --shots, not wall-clock.
    rng = np.random.default_rng(args.circuit_seed)
    n_circuits = args.max_circuits or 20
    pm = generate_preset_pass_manager(
        optimization_level=1,
        backend=backend,
        initial_layout=physical_qubits,
    )
    print(f"[+] building + transpiling {n_circuits} depth-{args.depth} "
          f"circuits ...")
    pubs = []
    for _ in range(n_circuits):
        qc = build_random_circuit(nq, args.depth, rng, logical_edges)
        pubs.append(pm.run(qc))

    sampler = Sampler(mode=backend)
    job = sampler.run(pubs, shots=args.shots)
    job_ids = [job.job_id()]
    print(f"[+] submitted job {job.job_id()} with {n_circuits} circuits "
          f"x {args.shots} shots  (now queued - this can take a while)")
    result = job.result()

    raw_bits: list[np.ndarray] = []
    for pub_result in result:
        data = pub_result.data
        bitarray = next(iter(data.values()))  # classical reg, name-agnostic
        for bs in bitarray.get_bitstrings():
            raw_bits.append(np.frombuffer(bs.encode(), dtype=np.uint8) - ord("0"))
    circuits_run = n_circuits

    if not raw_bits:
        print("[!] no bits collected", file=sys.stderr)
        sys.exit(1)

    raw = np.concatenate(raw_bits).astype(np.uint8)
    print(f"[+] collected {len(raw)} raw bits over {circuits_run} circuits")

    h_inf = estimate_min_entropy_per_bit(raw)
    print(f"[+] diagnostic bias-only H_inf ~ {h_inf:.4f} bits/bit (raw)")

    debiased = von_neumann_debias(raw)
    print(f"[+] {len(debiased)} bits after von Neumann de-bias")

    out_bits = args.out_bytes * 8
    # Leftover Hash Lemma budget: need input min-entropy >= out + 2log2(1/eps)
    eps = 2 ** -64
    needed = out_bits + 2 * math.log2(1 / eps)
    avail = len(debiased) * estimate_min_entropy_per_bit(debiased)
    print(f"[+] heuristic conditioning budget: need ~{needed:.0f} bits, "
          f"estimate ~{avail:.0f} bits")
    if avail < needed:
        print("[!] WARNING: short on heuristic entropy estimate; increase "
              "--max-circuits/--shots",
              file=sys.stderr)

    seed_bits = toeplitz_extract(debiased, out_bits, seed=args.extractor_seed)
    seed = bits_to_bytes(seed_bits)

    _write_outputs(args, seed, backend.name, job_ids, circuits_run,
                   len(raw), h_inf)


def _write_outputs(args, seed: bytes, backend_name: str, job_ids, circuits,
                   raw_bit_count, h_inf):
    outdir = args.outdir
    os.makedirs(outdir, exist_ok=True)

    with open(os.path.join(outdir, "seed.bin"), "wb") as f:
        f.write(seed)

    commitment = hashlib.sha256(seed).hexdigest()
    with open(os.path.join(outdir, "qrng_commitment.txt"), "w") as f:
        f.write(commitment + "\n")

    with open(os.path.join(outdir, "qrng_manifest.txt"), "w") as f:
        f.write(f"backend       : {backend_name}\n")
        f.write(f"generated     : {_dt.datetime.utcnow().isoformat()}Z\n")
        f.write(f"circuits       : {circuits}\n")
        f.write(f"depth         : {args.depth}\n")
        f.write(f"shots/circuit : {args.shots}\n")
        f.write(f"raw bits      : {raw_bit_count}\n")
        f.write(f"raw H_inf/bit : {h_inf:.4f}\n")
        f.write(f"seed bytes    : {len(seed)}\n")
        f.write(f"seed sha256   : {commitment}\n")
        f.write(f"extractor_seed: {args.extractor_seed}\n")
        f.write("job_ids       :\n")
        for j in job_ids:
            f.write(f"  - {j}\n")

    print(f"[+] wrote private {outdir}/seed.bin")
    print(f"[+] wrote public commitment + provenance (sha256={commitment})")


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--backend", required=True,
                   help="IBM backend name, e.g. ibm_fez / ibm_torino / ibm_marrakesh")
    p.add_argument("--token", default=None, help="IBM Quantum API key "
                   "(44 chars; or set QISKIT_IBM_TOKEN; or use a saved account)")
    p.add_argument("--instance", default=None,
                   help="instance CRN (from the Instances page). Required with "
                        "--token on the new ibm_cloud platform.")
    p.add_argument("--channel", default="ibm_cloud",
                   help="runtime channel (default ibm_cloud for the new platform)")
    p.add_argument("--minutes", type=float, default=5.0,
                   help="advisory QPU-time budget; actual spend = circuits x shots")
    p.add_argument("--qubits", type=int, default=None,
                   help="qubits to use (default: all on backend)")
    p.add_argument("--depth", type=int, default=100,
                   help="brickwork layers; deeper = harder to simulate, "
                        "until decoherence (default 100)")
    p.add_argument("--shots", type=int, default=4096,
                   help="shots per circuit (default 4096)")
    p.add_argument("--out-bytes", dest="out_bytes", type=int, default=1024,
                   help="final seed size in bytes (default 1024, matching Grit)")
    p.add_argument("--max-circuits", type=int, default=0,
                   help="number of circuits in the single batched job (0 -> 20)")
    p.add_argument("--circuit-seed", type=int, default=None,
                   help="PRNG seed for circuit gate angles (provenance only)")
    p.add_argument("--extractor-seed", type=int, default=0xC0FFEE,
                   help="public Toeplitz extractor seed")
    p.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)),
                   help="output directory")
    return p.parse_args(argv)


if __name__ == "__main__":
    harvest(parse_args())
