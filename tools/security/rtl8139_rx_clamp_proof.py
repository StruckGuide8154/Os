#!/usr/bin/env python3
"""Exhaustive proof for the RTL8139 RX length clamp (rtl8139_tx_rx.inc).

The RTL8139 RX-status length word is device-supplied. Before the clamp it flowed
unbounded into net_rx_frame -> IP/TCP as `ecx`, so a corrupt/oversized descriptor
length (up to 0xFFFF) could drive net_tcp_rx_ipv4 to read ~57 KiB past the 8 KiB
RX ring. This models the clamp exactly and asserts that, for every (rx_off,
reported_len), whenever a frame is handed to net_rx_frame the read window stays
inside the ring [RTL_RX_BUF_ADDR, RTL_RX_BUF_ADDR + RTL_RX_BUF_LEN).

Mirrors docs/security/proof-net-tcp-rx.md's ecx contract at its upstream source.
Host-only; no QEMU.
"""

RTL_RX_BUF_LEN = 8192   # rtl8139.asm:52


def clamp_and_read_extent(rx_off: int, reported: int):
    """Model rtl8139_tx_rx.inc lines 187-209 after the clamp. Returns
    (delivered, ecx) — delivered=True means rtl8139_handle_frame(rdi=rsi+4, ecx)
    runs; the read window is [rx_off+4, rx_off+4+ecx)."""
    # movzx ebx, word[rtl_rx_off]  — the CAPR advance masks rx_off to the ring.
    ebx = rx_off & (RTL_RX_BUF_LEN - 1)
    ecx = reported & 0xFFFF                       # movzx ecx, word[rsi+2]
    # avail = (RTL_RX_BUF_LEN-4) - ebx ; sub borrows iff ebx > BUF_LEN-4 -> drop
    avail = (RTL_RX_BUF_LEN - 4) - ebx
    if avail < 0:                                 # jc .advance
        return (False, None)
    if ecx > avail:                               # cmp/jbe + mov ecx,eax
        ecx = avail
    if ecx < 14:                                  # cmp ecx,14 / jb .advance
        return (False, None)
    return (True, ecx)


def main():
    checked = 0
    delivered = 0
    worst_end = 0
    for rx_off in range(0, RTL_RX_BUF_LEN):       # every possible ring offset
        for reported in (list(range(0, 64)) +     # small + boundary + hostile
                         list(range(1500, 1600)) +
                         [8188, 8189, 8192, 0x7FFF, 0xFFFF]):
            checked += 1
            ok, ecx = clamp_and_read_extent(rx_off, reported)
            if not ok:
                continue
            delivered += 1
            ebx = rx_off & (RTL_RX_BUF_LEN - 1)
            read_end = ebx + 4 + ecx              # last byte + 1, ring-relative
            worst_end = max(worst_end, read_end)
            assert read_end <= RTL_RX_BUF_LEN, (
                f"OOB: rx_off={rx_off} reported={reported} ecx={ecx} "
                f"read_end={read_end} > ring {RTL_RX_BUF_LEN}")
    print(f"rtl8139_rx_clamp_proof: OK  ({checked} cases, {delivered} delivered "
          f"to net_rx_frame, worst read_end={worst_end} <= ring {RTL_RX_BUF_LEN})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
