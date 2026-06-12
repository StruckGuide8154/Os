#!/usr/bin/env python3
"""
qrng_seed.py - Harvest non-replicable randomness from an IBM Quantum backend
and distill it into a Grit boot entropy seed blob.

WHAT THIS IS
------------
This runs DEEP RANDOM CIRCUITS across all qubits of an IBM Heron-class
machine and collects the measured bitstrings. The whole point: the output
distribution of a sufficiently deep random circuit is classically
intractable to sample from (this is the random-circuit-sampling /
"quantum supremacy" property). So the raw bits we pull down could not
have been precomputed or reproduced by ANY classical adversary - not even
one holding our full machine state, source, and seed.

Raw quantum samples are biased and noisy, so we DO NOT use them directly.
We run a Toeplitz-hashing randomness extractor (with a von Neumann
de-bias prepass) to squeeze the device + classical noise out and emit a
clean, uniform seed. The extractor seed itself is public; security comes
from the min-entropy of the quantum source, not from hiding the matrix.

OUTPUT
------
  seed.bin          raw extracted seed bytes (feed into the OS entropy pool)
  seed.inc          NASM include: `qrng_seed_blob: db 0x..,..` for Grit
  qrng_manifest.txt provenance (backend, job ids, depth, shots, entropy est.)

USAGE
-----
  pip install -r requirements.txt
  export QISKIT_IBM_TOKEN=...           # or pass --token
  python qrng_seed.py --backend ibm_fez --minutes 5 --out-bytes 256

You hand me the token / backend name when you're ready to connect.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import math
import os
import sys
import time

import numpy as np


# --------------------------------------------------------------------------
# Circuit construction: deep, hardware-native random circuits
# --------------------------------------------------------------------------
def build_random_circuit(num_qubits: int, depth: int, rng: np.random.Generator):
    """A brickwork random circuit: alternating layers of random single-qubit
    rotations and a brick pattern of two-qubit entanglers, then measure all.

    Depth is chosen so total runtime fits the coherence budget: with CNOT
    ~235 ns and T2 ~220 us you can stack a few hundred entangling layers
    before decoherence dominates. We stay conservative (the bits stay hard
    to simulate well before they decohere)."""
    from qiskit import QuantumCircuit

    qc = QuantumCircuit(num_qubits, num_qubits)
    for layer in range(depth):
        # single-qubit layer: random SU(2) via U(theta, phi, lam)
        for q in range(num_qubits):
            theta = rng.uniform(0, math.pi)
            phi = rng.uniform(0, 2 * math.pi)
            lam = rng.uniform(0, 2 * math.pi)
            qc.u(theta, phi, lam, q)
        # entangling layer: brick pattern, offset alternates each layer
        offset = layer % 2
        for q in range(offset, num_qubits - 1, 2):
            qc.cx(q, q + 1)
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
    nq = min(args.qubits or backend.num_qubits, backend.num_qubits)
    print(f"[+] backend={backend.name} qubits={nq} "
          f"max_shots={getattr(backend, 'max_shots', 'n/a')}")

    # --- Build all circuits up front -----------------------------------
    # On the free Open Plan jobs sit in a QUEUE and the budget you have is
    # QPU *execution* time, not wall-clock. So we submit every circuit in a
    # SINGLE job: one queue wait, then all circuits run back-to-back. Tune
    # the QPU-time spend with --circuits x --shots, not wall-clock.
    rng = np.random.default_rng(args.circuit_seed)
    n_circuits = args.max_circuits or 20
    pm = generate_preset_pass_manager(optimization_level=1, backend=backend)
    print(f"[+] building + transpiling {n_circuits} depth-{args.depth} "
          f"circuits ...")
    pubs = []
    for _ in range(n_circuits):
        qc = build_random_circuit(nq, args.depth, rng)
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
    print(f"[+] est. min-entropy ~ {h_inf:.4f} bits/bit (raw)")

    debiased = von_neumann_debias(raw)
    print(f"[+] {len(debiased)} bits after von Neumann de-bias")

    out_bits = args.out_bytes * 8
    # Leftover Hash Lemma budget: need input min-entropy >= out + 2log2(1/eps)
    eps = 2 ** -64
    needed = out_bits + 2 * math.log2(1 / eps)
    avail = len(debiased) * estimate_min_entropy_per_bit(debiased)
    print(f"[+] entropy budget: need ~{needed:.0f} bits, have ~{avail:.0f} bits")
    if avail < needed:
        print("[!] WARNING: short on min-entropy; increase --max-circuits/--shots",
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

    # NASM include for Grit
    inc = [
        "; Auto-generated by tools/quantum/qrng_seed.py -- DO NOT EDIT",
        f"; backend={backend_name}  bytes={len(seed)}  "
        f"generated={_dt.datetime.utcnow().isoformat()}Z",
        "qrng_seed_blob:",
    ]
    for i in range(0, len(seed), 16):
        row = seed[i : i + 16]
        inc.append("    db " + ", ".join(f"0x{b:02x}" for b in row))
    inc.append(f"qrng_seed_len equ {len(seed)}")
    with open(os.path.join(outdir, "seed.inc"), "w") as f:
        f.write("\n".join(inc) + "\n")

    with open(os.path.join(outdir, "qrng_manifest.txt"), "w") as f:
        f.write(f"backend       : {backend_name}\n")
        f.write(f"generated     : {_dt.datetime.utcnow().isoformat()}Z\n")
        f.write(f"circuits       : {circuits}\n")
        f.write(f"depth         : {args.depth}\n")
        f.write(f"shots/circuit : {args.shots}\n")
        f.write(f"raw bits      : {raw_bit_count}\n")
        f.write(f"raw H_inf/bit : {h_inf:.4f}\n")
        f.write(f"seed bytes    : {len(seed)}\n")
        f.write(f"extractor_seed: {args.extractor_seed}\n")
        f.write("job_ids       :\n")
        for j in job_ids:
            f.write(f"  - {j}\n")

    print(f"[+] wrote {outdir}/seed.bin, seed.inc, qrng_manifest.txt")
    print(f"[+] seed (hex): {seed.hex()}")


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
    p.add_argument("--out-bytes", dest="out_bytes", type=int, default=256,
                   help="final seed size in bytes (default 256)")
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
