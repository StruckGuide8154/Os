#!/usr/bin/env python3
"""Exhaustive proof for the RTL8156 RX descriptor-length clamp (rtl8156_usb.inc).

The RTL8156/RTL8152 (r8152-family) USB-Ethernet NIC prefixes each received frame
with a 24-byte Realtek rx_desc. The frame length lives in rx_desc opts1, low 15
bits (RTL8156_RX_LEN_MASK = 0x7FFF), and is FULLY device-controlled: an attacker
on the wire (or a malicious/emulated device) sets it to anything in [0, 32767].

Before the clamp, `rtl8156_consume_event` (.have_rx) did:

    eax = [RX_BUF] & 0x7FFF        ; device length, up to 32767
    if eax < 32: drop
    eax -= 4                       ; strip FCS
    rdi = RX_BUF + 24              ; frame body
    ecx = eax
    call rtl8156_handle_frame      ; reads ecx bytes from [rdi]

But the bulk-IN TRB only DMAs RTL8156_RX_DMA_LEN (4096) bytes into the single RX
buffer. A descriptor claiming up to 32763 usable bytes made handle_frame ->
net_rx_frame -> the DHCP/ARP/ICMP parsers read ~28 KiB of stale (or, if the DMA
region is a single mapped page, unmapped -> #PF) memory past the buffer. Same
device-reported-length OOB class as the rtl8139 RX clamp.

The fix adds, before `sub eax,4`:

    cmp eax, RTL8156_RX_MAX_FRAME   ; = RTL8156_RX_DMA_LEN - RTL8156_RX_DESC_LEN
    ja  .requeue                    ; fail-closed drop

This models the clamped path exactly and asserts that, for EVERY device-reported
length in the full 15-bit space, whenever a frame is handed to handle_frame the
read window [RX_BUF+24, RX_BUF+24+ecx) stays inside the DMA buffer
[RX_BUF, RX_BUF + RTL8156_RX_DMA_LEN). Host-only; no QEMU.
"""

RTL8156_RX_LEN_MASK = 0x7FFF   # rtl8156.asm
RTL8156_RX_DMA_LEN  = 4096     # constants.inc (bulk-IN TRB length)
RTL8156_RX_DESC_LEN = 24       # constants.inc (Realtek rx_desc header)
RTL8156_RX_MAX_FRAME = RTL8156_RX_DMA_LEN - RTL8156_RX_DESC_LEN   # 4072

MIN_LEN = 18 + 14              # .have_rx: cmp eax, 18+14 / jb .requeue


def delivered_read_extent(reported_raw: int):
    """Model rtl8156_usb.inc .have_rx AFTER the clamp. Returns (delivered, end)
    where, if delivered, end is the highest buffer offset read by handle_frame
    (exclusive): 24 + ecx. delivered=False means the frame was dropped."""
    eax = reported_raw & RTL8156_RX_LEN_MASK      # and eax, RTL8156_RX_LEN_MASK
    if eax < MIN_LEN:                             # cmp eax,18+14 / jb .requeue
        return (False, None)
    if eax > RTL8156_RX_MAX_FRAME:                # cmp eax,MAX / ja .requeue  (THE FIX)
        return (False, None)
    eax -= 4                                      # sub eax,4 (strip FCS)
    ecx = eax                                     # mov ecx,eax
    # handle_frame reads [RX_BUF + 24, RX_BUF + 24 + ecx)
    return (True, RTL8156_RX_DESC_LEN + ecx)


def unclamped_read_extent(reported_raw: int):
    """The PRE-FIX path (no MAX_FRAME check) — for the regression witness."""
    eax = reported_raw & RTL8156_RX_LEN_MASK
    if eax < MIN_LEN:
        return (False, None)
    eax -= 4
    return (True, RTL8156_RX_DESC_LEN + eax)


def main():
    checked = 0
    delivered = 0
    worst_end = 0
    # Enumerate the ENTIRE device-controllable input space: the raw dword's low
    # 16 bits are all that survive the &0x7FFF mask, so 0..0xFFFF is exhaustive.
    for reported in range(0, 0x10000):
        ok, end = delivered_read_extent(reported)
        checked += 1
        if not ok:
            continue
        delivered += 1
        worst_end = max(worst_end, end)
        assert end <= RTL8156_RX_DMA_LEN, (
            f"OOB: reported=0x{reported:04x} reads to buffer offset {end} "
            f"> DMA window {RTL8156_RX_DMA_LEN}")

    # Confirm the clamp is what closed it: the pre-fix model MUST overrun.
    pre_overruns = sum(
        1 for r in range(0, 0x10000)
        if (ext := unclamped_read_extent(r))[0] and ext[1] > RTL8156_RX_DMA_LEN)

    print(f"[rtl8156-rx] inputs checked      : {checked}  (full 16-bit space)")
    print(f"[rtl8156-rx] frames delivered    : {delivered}")
    print(f"[rtl8156-rx] worst read offset   : {worst_end}  (<= {RTL8156_RX_DMA_LEN})")
    print(f"[rtl8156-rx] pre-fix OOB inputs  : {pre_overruns}  (all now dropped)")
    assert worst_end <= RTL8156_RX_DMA_LEN
    assert pre_overruns > 0, "regression witness vanished — proof no longer meaningful"
    print("[rtl8156-rx] PROOF OK: no device-reported length can drive an OOB read.")


if __name__ == "__main__":
    main()
