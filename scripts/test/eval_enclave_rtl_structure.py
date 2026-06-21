#!/usr/bin/env python3
"""Post-synthesis secret-independent-control gate for enclave crypto RTL.

This is an information-flow shape check, not a side-channel proof. It rejects
netlists where ``key`` or ``message`` can influence completion/control outputs,
mux selectors, clocks, resets, register enables, or memory control ports.
Secret influence on datapath D inputs and ``result`` is intentionally allowed.
"""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))

from amaranth import Elaboratable, Module, Signal  # noqa: E402
from amaranth.back import rtlil                    # noqa: E402
from enclave.rtl.crypto_session import FixedLatencyCryptoCore  # noqa: E402
from enclave.rtl.puf_seal import PUFKeySeal                    # noqa: E402

CONTROL_PORTS = frozenset({
    'S', 'EN', 'CE', 'CLK', 'C', 'ARST', 'SRST', 'CLR', 'SET', 'LOAD',
    'WE', 'WR_EN', 'RD_EN', 'ADDR', 'WR_ADDR', 'RD_ADDR',
})


def _bits(connection):
    return {bit for bit in connection if isinstance(bit, int)}


def synth_json(dut, name, ports, directory):
    il_path = os.path.join(directory, name + '.il')
    json_path = os.path.join(directory, name + '.json')
    with open(il_path, 'w', encoding='utf-8') as fh:
        fh.write(rtlil.convert(dut, name=name, ports=ports))
    il_arg = os.path.relpath(il_path, ROOT).replace('\\', '/')
    json_arg = os.path.relpath(json_path, ROOT).replace('\\', '/')
    command = ('read_rtlil %s; hierarchy -top %s; proc; opt; write_json %s'
               % (il_arg, name, json_arg))
    subprocess.run([sys.executable, '-m', 'amaranth_yosys', '-q', '-p', command],
                   cwd=ROOT, check=True)
    with open(json_path, encoding='utf-8') as fh:
        return json.load(fh)['modules'][name]


def audit_module(module, secret_ports=('key', 'message'),
                 timing_outputs=('busy', 'done')):
    ports = module['ports']
    tainted = set()
    for name in secret_ports:
        tainted.update(_bits(ports[name]['bits']))

    # Conservative fixed point: every cell output is data-tainted when any
    # input is tainted. This includes state across clock boundaries (D -> Q).
    changed = True
    while changed:
        changed = False
        for cell in module.get('cells', {}).values():
            directions = cell.get('port_directions', {})
            inputs = set()
            outputs = set()
            for port, direction in directions.items():
                conn = _bits(cell['connections'].get(port, []))
                if direction in ('input', 'inout'):
                    inputs.update(conn)
                if direction in ('output', 'inout'):
                    outputs.update(conn)
            if inputs & tainted and not outputs <= tainted:
                tainted.update(outputs)
                changed = True

    failures = []
    for name in timing_outputs:
        if _bits(ports[name]['bits']) & tainted:
            failures.append('secret reaches timing output %s' % name)

    for cell_name, cell in module.get('cells', {}).items():
        directions = cell.get('port_directions', {})
        for port, direction in directions.items():
            if direction not in ('input', 'inout'):
                continue
            upper = port.upper()
            is_mux_select = cell['type'] in ('$mux', '$pmux') and upper == 'S'
            is_control = upper in CONTROL_PORTS or is_mux_select
            if is_control and (_bits(cell['connections'].get(port, [])) & tainted):
                failures.append('secret reaches %s.%s (%s)'
                                % (cell_name, port, cell['type']))
    return sorted(set(failures))


class BadSecretDone(Elaboratable):
    def __init__(self):
        self.key = Signal(256)
        self.message = Signal(256)
        self.busy = Signal()
        self.done = Signal()
        self.result = Signal(256)

    def elaborate(self, platform):
        m = Module()
        m.d.comb += [self.done.eq(self.key[0]), self.busy.eq(0),
                     self.result.eq(self.message)]
        return m


class BadSecretEnable(Elaboratable):
    def __init__(self):
        self.key = Signal(256)
        self.message = Signal(256)
        self.busy = Signal()
        self.done = Signal()
        self.result = Signal(256)

    def elaborate(self, platform):
        m = Module()
        with m.If(self.key[0]):
            m.d.sync += self.result.eq(self.message)
        m.d.comb += [self.busy.eq(0), self.done.eq(0)]
        return m


def ports(dut):
    return [dut.key, dut.message, dut.busy, dut.done, dut.result]


def main():
    build_dir = os.path.join(ROOT, 'build')
    os.makedirs(build_dir, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='enclave-rtl-', dir=build_dir) as tmp:
        core = FixedLatencyCryptoCore()
        core_ports = [core.start, core.op, core.key, core.message,
                      core.busy, core.done, core.result]
        failures = audit_module(synth_json(core, 'crypto_session', core_ports, tmp))
        if failures:
            for failure in failures:
                print('[rtl-ct] FAIL: ' + failure)
            return 1
        print('[rtl-ct] synthesized crypto boundary has no secret-tainted control sink [ok]')

        puf = PUFKeySeal()
        puf_ports = [puf.puf_sample, puf.helper_data, puf.ciphertext_in,
                     puf.data_in, puf.start_seal, puf.start_unseal,
                     puf.zeroize, puf.busy, puf.done, puf.data_out]
        puf_failures = audit_module(
            synth_json(puf, 'puf_seal', puf_ports, tmp),
            secret_ports=('puf_sample', 'helper_data', 'ciphertext_in', 'data_in'))
        if puf_failures:
            for failure in puf_failures:
                print('[rtl-ct] FAIL: PUF boundary: ' + failure)
            return 1
        print('[rtl-ct] synthesized PUF boundary has no secret-tainted control sink [ok]')

        bad_done = BadSecretDone()
        caught_done = audit_module(synth_json(bad_done, 'bad_secret_done',
                                               ports(bad_done), tmp))
        if not any('timing output done' in item for item in caught_done):
            print('[rtl-ct] FAIL: negative secret->done mutant escaped')
            return 1
        print('[rtl-ct] negative secret->done mutant rejected                 [ok]')

        bad_enable = BadSecretEnable()
        caught_enable = audit_module(synth_json(bad_enable, 'bad_secret_enable',
                                                 ports(bad_enable), tmp))
        if not any(('.EN ' in item) or ('.S ' in item) for item in caught_enable):
            print('[rtl-ct] FAIL: negative secret->enable mutant escaped')
            return 1
        print('[rtl-ct] negative secret->enable mutant rejected               [ok]')

    print('[rtl-ct] structural gate proves secret-independent control shape; '
          'it does not prove physical side-channel resistance')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
