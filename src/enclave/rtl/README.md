# `src/enclave/rtl/` — Track 10 enclave gateware (synthesizable FPGA logic)

The **silicon** of the one-shot phase machine. This is the FPGA gateware that
the software model (`../enclave_phase.ghl`) describes — written in
[Amaranth HDL](https://amaranth-lang.org/) (synthesizable, vendor-neutral,
emits Verilog/RTLIL) and cycle-simulated in CI so the hardware logic is verified
without the board (QEMU/TCG cannot model an FPGA).

## On-die only — the hard security constraint

The enclave's whole value is that its secrets sit nowhere an attacker can reach.
So the gateware uses **only on-die fabric resources** and deliberately avoids
anything that would push state off-chip or onto a soft processor:

- **No external RAM/DRAM/SRAM, no memory controller.** All state is fabric
  registers + `SecureRAM`, a custom register-array RAM built from scratch
  (`secure_ram.py`) — distributed LUT-RAM / flip-flops, never an off-die part
  that could be probed, swapped, or cold-booted.
- **No soft-CPU running firmware from memory.** The design is a fixed FSM in
  hardware; there is no instruction stream to subvert and no external program
  store. Smaller attack surface, and nothing to re-flash at runtime.
- **No secret-dependent control flow / timing.** Every command has a fixed
  one-cycle response latency, so the USB-reachable command port is not a remote
  timing oracle. (The real KDF/crypto core is a constant-time gateware block;
  the mix here is a placeholder of the right shape.)
- **One sticky-reset domain.** The latch's only path back to 0 is `clear_i`,
  wired to power-on alone — ordinary logic resets cannot reach it.

## Module arrangement (one concern each)

| File | Role |
|---|---|
| `latch.py` | `StickyMajorityLatch`: triplicated sticky cells + 2-of-3 majority vote. A single glitched cell cannot flip the verdict; cleared only by `clear_i` (power-on). Cells exposed as ports so the majority property is directly testable. |
| `secure_ram.py` | `SecureRAM`: custom internal RAM with a **structural export firewall** — secret slots are readable on the internal port A but hardwired to 0 on the export port B. The master key can be *used* but has no wire to any output pin. |
| `enclave_top.py` | `EnclaveTop`: the phase FSM — command decode, single-use bitmap, the four auto-close triggers, the KDF mix (reads master via RAM port A, writes the released key to the export slot), boot counter, attest read-outs. Mirrors `enclave_phase.ghl` opcode-for-opcode. |
| `crypto_session.py` | Fixed-latency session-crypto integration boundary. The datapath is a non-cryptographic placeholder; reviewed X25519/Ed25519/AEAD cores must preserve its tested cycle contract. |
| `entropy.py` | Online repetition-count/adaptive-proportion tests and voltage, temperature, and clock fail-stop inputs. Raw entropy and a reviewed DRBG are device-specific. |
| `monotonic_counter.py` | Redundant value/complement counter front-end. Corruption is sticky and freezes increments; persistence requires secure NV/eFuse. |
| `puf_seal.py` | Fixed-latency PUF/helper-data seal model with no reconstructed-key output. A characterized PUF and fuzzy extractor remain hardware-specific. |
| `tamper.py` | Voted and filtered tamper response. Sustained 2-of-3 events close the latch and zeroize every secure-RAM slot. |
| `generate.py` | Emits the RTLIL netlist (always) and Verilog (when yosys / `amaranth-yosys` is available) to `build/enclave_rtl/`. |

## Verify / build

```
python scripts/test/eval_enclave_rtl.py        # cycle and fault simulation
python scripts/test/eval_enclave_rtl_structure.py # post-synthesis taint gate
cd src && python -m enclave.rtl.generate        # -> build/enclave_rtl/*.il,*.v
```
Both run from `scripts/test/test_enclave_phase.ps1` alongside the software model.
Dependencies: `pip install amaranth amaranth-yosys`.

## Interface

A single-cycle command port (`power_on`, `cmd_valid`, `cmd_op[8]`, `cmd_arg[64]`,
`tick`, `boot_complete`, `prov_we`, `prov_master[64]` → `resp_valid`,
`resp_status[3]`, `derive_out[64]`, `latched`, `phase`, `boot_counter[64]`,
`used_mask[8]`, `attest_*`) plus three tamper inputs and sticky tamper/counter
integrity outputs. The host driver / monitor wraps this in the
authenticated + nonce'd USB session (the AEAD layer is a separate, later piece);
this module is the trust core underneath it.

## Honest boundary

This RTL proves control-flow shape, fixed cycle counts, fail-stop behavior,
fault filtering, and structural key-export/zeroize properties. It does not
prove physical entropy, PUF stability, secure-NV persistence, or calibrated
sensor thresholds.

The post-synthesis structure gate conservatively propagates crypto and PUF
secret taint through the optimized Yosys cell graph. It rejects taint at
`busy`/`done`, mux selectors, register clocks/enables/resets, and memory control
ports. Negative mutation tests inject secret-dependent completion and register
enable logic to prove both classes are detected. This establishes a
secret-independent control-flow shape for the placeholder boundaries; it is
not a claim about real-crypto correctness, routing balance, power/EM leakage,
synthesis timing, or lab-measured side-channel resistance.

Real cryptographic correctness, implementation timing, and physical
side-channel resistance still need reviewed cores, a selected part, and the
hardware rig. The present checks are not physical validation; leak does not
imply elevation.
