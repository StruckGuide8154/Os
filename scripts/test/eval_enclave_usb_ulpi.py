#!/usr/bin/env python3
# Track-10 enclave gateware A5: verify the fabric USB-2 ULPI device core
# (src/enclave/rtl/usb_ulpi_device.py) at the ULPI transaction level:
#   - enumeration: GET_DESCRIPTOR(device), SET_ADDRESS, SET_CONFIGURATION
#   - a bulk OUT -> IN command/response round-trip on endpoint 1
#   - short-packet = success (a sub-maxpacket bulk transfer completes)
#
# The harness streams USB packets (byte0 = PID, then payload) into the ULPI RX
# byte interface and collects the device's response packet from the TX stream,
# exactly the packet boundary the core implements.

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src'))

from amaranth.sim import Simulator                       # noqa: E402
from enclave.rtl.usb_ulpi_device import (USBUlpiDevice,  # noqa: E402
    pid_byte, PID_OUT, PID_IN, PID_SETUP, PID_DATA0, PID_DATA1, PID_ACK,
    PID_NAK, DEVICE_DESC)

FAILURES = []


def check(label, ok, detail=''):
    print('[usb] %-48s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                  (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def token(pid, addr, ep):
    b1 = (addr & 0x7f) | ((ep & 1) << 7)
    b2 = (ep >> 1) & 0x7
    return bytes([pid_byte(pid), b1, b2])


def data(pid, payload):
    return bytes([pid_byte(pid)]) + bytes(payload)


class Bus:
    """Drives one packet into RX and collects any TX response packet."""

    def __init__(self):
        self.dut = USBUlpiDevice()

    def run(self, packets):
        results = []
        dut = self.dut

        async def tb(ctx):
            for pkt in packets:
                # stream the packet bytes with rx_active high
                ctx.set(dut.rx_active, 1)
                for byte in pkt:
                    ctx.set(dut.rx_stb, 1)
                    ctx.set(dut.rx_data, byte)
                    await ctx.tick()
                ctx.set(dut.rx_stb, 0)
                ctx.set(dut.rx_active, 0)
                # let the device process and possibly respond
                resp = []
                for _ in range(80):
                    await ctx.tick()
                    if ctx.get(dut.tx_stb):
                        resp.append(ctx.get(dut.tx_data))
                        if ctx.get(dut.tx_last):
                            # drain any trailing cycle
                            break
                results.append(bytes(resp))
            results.append(('addr', ctx.get(dut.dev_addr),
                            'cfg', ctx.get(dut.configured)))

        sim = Simulator(dut)
        sim.add_clock(1e-6)
        sim.add_testbench(tb)
        sim.run()
        return results


# ---- enumeration ---------------------------------------------------------
bus = Bus()
seq = [
    token(PID_SETUP, 0, 0),
    data(PID_DATA0, [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00]),  # GET_DESC dev
    token(PID_IN, 0, 0),          # control-IN data stage -> descriptor
    data(PID_ACK, []),            # host ACKs
    token(PID_SETUP, 0, 0),
    data(PID_DATA0, [0x00, 0x05, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00]),  # SET_ADDRESS 42
    token(PID_IN, 0, 0),          # status IN (ZLP) -> address commits
    token(PID_SETUP, 42, 0),
    data(PID_DATA0, [0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]),  # SET_CONFIG 1
    token(PID_IN, 42, 0),         # status IN (ZLP)
]
res = bus.run(seq)

# response indices: [0]SETUP->ACK [1]DATA->ACK [2]IN->DATA1(desc) [3]ACK->none ...
desc_resp = res[2]
check('GET_DESCRIPTOR returns DATA1 PID', len(desc_resp) >= 1
      and desc_resp[0] == pid_byte(PID_DATA1), desc_resp.hex())
check('device descriptor payload matches', desc_resp[1:] == DEVICE_DESC,
      desc_resp[1:].hex())
check('SETUP data stage ACKed', res[1] == bytes([pid_byte(PID_ACK)]))
addr_cfg = res[-1]
check('SET_ADDRESS committed (addr=42)', addr_cfg[1] == 42, str(addr_cfg))
check('SET_CONFIGURATION committed', addr_cfg[3] == 1, str(addr_cfg))

# ---- bulk OUT -> IN round-trip on EP1 -----------------------------------
bus2 = Bus()
cmd = list(range(20))     # a length-tagged AEAD command frame (20 bytes, short)
seq2 = [
    token(PID_OUT, 42, 1),
    data(PID_DATA0, cmd),         # bulk OUT payload
    token(PID_IN, 42, 1),         # bulk IN -> device returns the buffered frame
    data(PID_ACK, []),
]
res2 = bus2.run(seq2)
check('bulk OUT ACKed', res2[1] == bytes([pid_byte(PID_ACK)]), res2[1].hex())
in_resp = res2[2]
check('bulk IN returns a DATA packet', len(in_resp) >= 1
      and in_resp[0] in (pid_byte(PID_DATA0), pid_byte(PID_DATA1)),
      in_resp.hex())
check('bulk IN payload round-trips the command', in_resp[1:] == bytes(cmd),
      in_resp[1:].hex())
check('short packet (20 < 64) completes the transfer',
      len(in_resp) - 1 == len(cmd))

# ---- bulk IN with nothing buffered -> NAK -------------------------------
bus3 = Bus()
res3 = bus3.run([token(PID_IN, 42, 1)])
check('bulk IN with no data NAKs', res3[0] == bytes([pid_byte(PID_NAK)]),
      res3[0].hex())

if FAILURES:
    print('\nFAILED %d:' % len(FAILURES))
    for fr in FAILURES:
        print('  - ' + fr)
    sys.exit(1)
print('\nall USB ULPI device transactions pass')
