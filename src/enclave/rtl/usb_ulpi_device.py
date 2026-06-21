# ============================================================================
# usb_ulpi_device.py - Track 10 enclave gateware A5: a synthesizable USB 2.0
# device core over the ULPI 8-bit data path (the USB3300 link), Amaranth HDL.
#
# This replaces the byte-level software model in src/enclave/usb_protocol.py
# (kept as the framing spec this core must satisfy) with real fabric logic:
#   * a packet-level SIE over the ULPI RX/TX byte streams (link-layer turnaround
#     and register access are the PHY's job; this is the UTMI+/packet boundary);
#   * endpoint 0 control transfers: GET_DESCRIPTOR, SET_ADDRESS, SET_CONFIG;
#   * bulk OUT/IN endpoint 1 carrying the length-tagged AEAD command/response
#     frames, with DATAx toggles and ACK/NAK handshakes;
#   * short-packet = transfer complete (per feedback_xhci_short_packet).
#
# Packet boundary: this core operates on USB packets (byte 0 = PID, then the
# payload); CRC16 generation/checking and NRZI/bit-stuffing are the link-layer
# job of the ULPI PHY beneath this boundary (crc16_upd is provided for that).
#
# ULPI RX interface (PHY -> device):  rx_active, rx_stb, rx_data[8]
# ULPI TX interface (device -> PHY):  tx_stb, tx_data[8], tx_last; tx_busy out
# A received packet is the bytes streamed while rx_active is high (byte 0 = PID).
# A response packet is streamed out with tx_stb, tx_last marking the final byte.
# ============================================================================

from amaranth import Module, Signal, Elaboratable, Array, Mux, Cat

# USB PID low nibbles
PID_OUT = 0x1
PID_IN = 0x9
PID_SETUP = 0xD
PID_DATA0 = 0x3
PID_DATA1 = 0xB
PID_ACK = 0x2
PID_NAK = 0xA
PID_STALL = 0xE

# Standard requests
REQ_GET_DESCRIPTOR = 0x06
REQ_SET_ADDRESS = 0x05
REQ_SET_CONFIGURATION = 0x09

MAXPKT = 72            # 64-byte payload + PID + CRC16 headroom
EP1 = 1

# 18-byte device descriptor (bcdUSB 2.00, vendor-specific class, EP0 size 64).
DEVICE_DESC = bytes([
    0x12, 0x01, 0x00, 0x02, 0xFF, 0x00, 0x00, 0x40,
    0x55, 0x10, 0x10, 0xE1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
])


def pid_byte(pid4):
    """USB PID byte = pid | (~pid << 4)."""
    return pid4 | ((pid4 ^ 0xF) << 4)


def crc16_upd(crc, data):
    """One byte into the reflected USB CRC16 (poly 0xA001), 8 bits unrolled."""
    c = crc
    for i in range(8):
        b = c[0] ^ data[i]
        c = Mux(b, (c >> 1) ^ 0xA001, c >> 1)
    return c


class USBUlpiDevice(Elaboratable):
    def __init__(self):
        # RX (PHY -> device)
        self.rx_active = Signal()
        self.rx_stb = Signal()
        self.rx_data = Signal(8)
        # TX (device -> PHY)
        self.tx_stb = Signal()
        self.tx_data = Signal(8)
        self.tx_last = Signal()
        self.tx_busy = Signal()
        # observability
        self.dev_addr = Signal(7)
        self.configured = Signal()

    def elaborate(self, platform):
        m = Module()

        rxbuf = Array([Signal(8, name=f'rx{i}') for i in range(MAXPKT)])
        rxlen = Signal(range(MAXPKT + 1))
        rx_idx = Signal(range(MAXPKT + 1))
        rx_active_d = Signal()
        m.d.sync += rx_active_d.eq(self.rx_active)
        pkt_done = Signal()
        m.d.comb += pkt_done.eq(rx_active_d & ~self.rx_active)

        # collect incoming bytes
        with m.If(self.rx_active):
            with m.If(self.rx_stb):
                m.d.sync += [rxbuf[rx_idx].eq(self.rx_data), rx_idx.eq(rx_idx + 1)]
        with m.Else():
            with m.If(rx_active_d):
                m.d.sync += rxlen.eq(rx_idx)
            m.d.sync += rx_idx.eq(0)

        # device / control state
        pending_addr = Signal(7)
        addr_pending = Signal()
        last_token = Signal(4)        # PID of the last token packet
        cur_ep = Signal(4)            # endpoint of the last token packet
        ctrl_in = Array([Signal(8, name=f'ci{i}') for i in range(18)])
        ctrl_in_len = Signal(range(19))
        ctrl_in_ready = Signal()
        # bulk EP1
        bulk = Array([Signal(8, name=f'bk{i}') for i in range(64)])
        bulk_len = Signal(range(65))
        bulk_ready = Signal()
        ep1_in_toggle = Signal(reset=0)

        # response packet buffer
        resp = Array([Signal(8, name=f'tx{i}') for i in range(MAXPKT)])
        resp_len = Signal(range(MAXPKT + 1))
        resp_go = Signal()

        # ---- TX streaming FSM ---------------------------------------------
        tx_idx = Signal(range(MAXPKT + 1))
        with m.FSM(name='tx'):
            with m.State('idle'):
                m.d.comb += self.tx_busy.eq(0)
                with m.If(resp_go):
                    m.d.sync += tx_idx.eq(0)
                    m.next = 'send'
            with m.State('send'):
                m.d.comb += [self.tx_busy.eq(1), self.tx_stb.eq(1),
                             self.tx_data.eq(resp[tx_idx]),
                             self.tx_last.eq(tx_idx == resp_len - 1)]
                m.d.sync += tx_idx.eq(tx_idx + 1)
                with m.If(tx_idx == resp_len - 1):
                    m.next = 'idle'

        # helper: build a handshake or data response
        def emit_handshake(pid4):
            m.d.sync += [resp[0].eq(pid_byte(pid4)), resp_len.eq(1),
                         resp_go.eq(1)]

        # ---- packet dispatch ----------------------------------------------
        m.d.sync += resp_go.eq(0)
        pid = Signal(4)
        m.d.comb += pid.eq(rxbuf[0][0:4])
        plen = rx_idx        # live byte count at pkt_done (rxlen latches a cycle later)

        # setup fields (valid when a DATA packet follows a SETUP token)
        bmReq = rxbuf[1]
        bRequest = rxbuf[2]
        wValueL = rxbuf[3]
        wValueH = rxbuf[4]
        wLength = rxbuf[7]

        with m.If(pkt_done):
            with m.Switch(pid):
                with m.Case(PID_SETUP, PID_OUT, PID_IN):
                    m.d.sync += [last_token.eq(pid),
                                 cur_ep.eq(Cat(rxbuf[1][7], rxbuf[2][0:3]))]
                    with m.If(pid == PID_IN):
                        # respond with prepared data or NAK
                        ep = Cat(rxbuf[1][7], rxbuf[2][0:3])
                        with m.If((ep == 0) & ctrl_in_ready):
                            for i in range(18):
                                m.d.sync += resp[i + 1].eq(ctrl_in[i])
                            m.d.sync += [resp[0].eq(pid_byte(PID_DATA1)),
                                         resp_len.eq(ctrl_in_len + 1),
                                         resp_go.eq(1), ctrl_in_ready.eq(0)]
                            # address takes effect after the IN status stage
                            with m.If(addr_pending):
                                m.d.sync += [self.dev_addr.eq(pending_addr),
                                             addr_pending.eq(0)]
                        with m.Elif((ep == EP1) & bulk_ready):
                            for i in range(64):
                                m.d.sync += resp[i + 1].eq(bulk[i])
                            m.d.sync += [
                                resp[0].eq(pid_byte(Mux(ep1_in_toggle,
                                                        PID_DATA1, PID_DATA0))),
                                resp_len.eq(bulk_len + 1), resp_go.eq(1),
                                bulk_ready.eq(0),
                                ep1_in_toggle.eq(~ep1_in_toggle)]
                        with m.Else():
                            emit_handshake(PID_NAK)
                with m.Case(PID_DATA0, PID_DATA1):
                    with m.If(last_token == PID_SETUP):
                        # control SETUP data stage: decode the 8-byte request
                        with m.Switch(bRequest):
                            with m.Case(REQ_GET_DESCRIPTOR):
                                with m.If(wValueH == 1):       # DEVICE
                                    n = Mux(wLength < 18, wLength, 18)
                                    for i in range(18):
                                        m.d.sync += ctrl_in[i].eq(DEVICE_DESC[i])
                                    m.d.sync += [ctrl_in_len.eq(n),
                                                 ctrl_in_ready.eq(1)]
                            with m.Case(REQ_SET_ADDRESS):
                                m.d.sync += [pending_addr.eq(wValueL[0:7]),
                                             addr_pending.eq(1),
                                             ctrl_in_len.eq(0),
                                             ctrl_in_ready.eq(1)]  # ZLP status
                            with m.Case(REQ_SET_CONFIGURATION):
                                m.d.sync += [self.configured.eq(1),
                                             ctrl_in_len.eq(0),
                                             ctrl_in_ready.eq(1)]
                        emit_handshake(PID_ACK)
                    with m.Elif(last_token == PID_OUT):
                        # bulk OUT (EP1) or control status OUT (EP0, ZLP)
                        with m.If((cur_ep == EP1) & (plen > 1)):
                            # payload = rxbuf[1 : rxlen]
                            for i in range(64):
                                m.d.sync += bulk[i].eq(rxbuf[i + 1])
                            m.d.sync += [bulk_len.eq(plen - 1),
                                         bulk_ready.eq(1)]
                        emit_handshake(PID_ACK)
                with m.Case(PID_ACK):
                    pass        # host acknowledged our IN data; nothing to send

        return m
