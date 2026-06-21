#!/usr/bin/env python3
# ============================================================================
# generate.py - emit the synthesizable netlist for the Track 10 enclave gateware.
#
# Amaranth's native output is RTLIL (always available, pure-Python). Verilog is
# produced by running yosys over that RTLIL; this script emits RTLIL
# unconditionally and Verilog when yosys is on PATH, so CI can prove the design
# elaborates to a netlist even on a box without yosys installed.
#
#   python -m enclave.rtl.generate [outdir]
#
# Outputs (default build/enclave_rtl/):
#   enclave_top.il   - RTLIL netlist of the full one-shot phase machine
#   enclave_top.v    - Verilog (only if yosys is available)
# ============================================================================

import os
import sys

from amaranth.back import rtlil

from .enclave_top import EnclaveTop
from .crypto_session import FixedLatencyCryptoCore
from .entropy import EntropyHealthMonitor
from .monotonic_counter import MonotonicCounter
from .puf_seal import PUFKeySeal
from .tamper import FilteredTamperMonitor
from .field25519 import Field25519
from .x25519 import X25519
from .ed25519 import Ed25519
from .aead_chacha import AEADChaCha20Poly1305
from .usb_ulpi_device import USBUlpiDevice
from .sha512 import SHA512Block

PORTS = ('power_on', 'cmd_valid', 'cmd_op', 'cmd_arg', 'tick', 'boot_complete',
         'prov_we', 'prov_master', 'resp_valid', 'resp_status', 'derive_out',
         'latched', 'phase', 'boot_counter', 'used_mask', 'attest_latch',
         'attest_counter', 'tamper_a', 'tamper_b', 'tamper_c',
         'tamper_latched', 'counter_fault')

BLOCKS = (
    ('enclave_top', EnclaveTop, PORTS),
    ('crypto_session', FixedLatencyCryptoCore,
     ('start', 'op', 'key', 'message', 'busy', 'done', 'result')),
    ('entropy_health', EntropyHealthMonitor,
     ('raw_bit', 'raw_valid', 'env_voltage_ok', 'env_temp_ok', 'env_clock_ok',
      'power_on', 'random_word', 'random_valid', 'health_fault', 'env_fault')),
    ('monotonic_counter', MonotonicCounter,
     ('increment', 'clear_fault', 'value', 'integrity_fault')),
    ('puf_seal', PUFKeySeal,
     ('puf_sample', 'helper_data', 'ciphertext_in', 'data_in', 'start_seal',
      'start_unseal', 'zeroize', 'busy', 'done', 'data_out')),
    ('tamper_filter', FilteredTamperMonitor,
     ('sensor_a', 'sensor_b', 'sensor_c', 'power_on', 'tamper', 'zeroize',
      'suspect')),
)


def main(argv):
    # Anchor the default output at the repo-root build/ (the gitignored,
    # regenerable artifact tree) regardless of the caller's cwd.
    root = os.path.abspath(os.path.join(os.path.dirname(__file__),
                                        '..', '..', '..'))
    outdir = argv[1] if len(argv) > 1 else os.path.join(root, 'build',
                                                        'enclave_rtl')
    os.makedirs(outdir, exist_ok=True)
    for name, factory, port_names in BLOCKS:
        dut = factory()
        ports = [getattr(dut, p) for p in port_names]
        il_path = os.path.join(outdir, name + '.il')
        with open(il_path, 'w', encoding='utf-8') as fh:
            fh.write(rtlil.convert(dut, name=name, ports=ports))
        print('[generate] wrote RTLIL netlist -> %s' % il_path)

        try:
            from amaranth.back import verilog
            v_path = os.path.join(outdir, name + '.v')
            with open(v_path, 'w', encoding='utf-8') as fh:
                fh.write(verilog.convert(dut, name=name, ports=ports))
            print('[generate] wrote Verilog       -> %s' % v_path)
        except Exception as exc:                   # yosys absent / conversion err
            print('[generate] Verilog skipped for %s: %s' % (name, exc))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
