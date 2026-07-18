# Proof: RTL8156 USB-Ethernet RX descriptor-length OOB is closed

**File:** `src/kernel/drivers/rtl8156_usb.inc` (`rtl8156_consume_event`, `.have_rx`)
**Class:** device-reported length → out-of-bounds read (same class as the RTL8139
RX clamp, `tools/security/rtl8139_rx_clamp_proof.py`).
**Proof tool:** `tools/security/rtl8156_rx_clamp_proof.py` (host-only, no QEMU).

## The untrusted quantity

Each frame the r8152-family NIC delivers over its bulk-IN endpoint is prefixed
with a 24-byte Realtek `rx_desc`. The frame length lives in `opts1`, low 15 bits
(`RTL8156_RX_LEN_MASK = 0x7FFF`). Those bytes are written by the device via DMA,
so an attacker on the wire — or a malicious/emulated device — controls the length
field completely: any value in `[0, 32767]`.

## The bug (pre-fix)

`.have_rx` masked the length, rejected anything under 32 bytes, subtracted the
4-byte FCS, then handed `ecx = len - 4` bytes starting at `RX_BUF + 24` to
`rtl8156_handle_frame` → `net_rx_frame` → the ARP/DHCP/ICMP parsers.

But the bulk-IN TRB DMAs only `RTL8156_RX_DMA_LEN = 4096` bytes into the single
RX buffer at `RTL8156_RX_BUF_ADDR`. A descriptor claiming the maximum `0x7FFF`
made `handle_frame` read `32767 - 4 = 32763` bytes from `RX_BUF + 24`, i.e. up to
buffer offset **32787** — ~28 KiB past the 4096-byte DMA window. Depending on the
backing, that is either stale/adjacent DMA memory forwarded into the network
stack, or unmapped memory → `#PF`.

## The fix

A single fail-closed bound, added before the FCS subtraction:

```asm
    cmp eax, RTL8156_RX_MAX_FRAME   ; = RTL8156_RX_DMA_LEN - RTL8156_RX_DESC_LEN = 4072
    ja  .requeue                    ; drop; re-arm bulk-IN for the next frame
```

`RTL8156_RX_DMA_LEN`, `RTL8156_RX_DESC_LEN`, and `RTL8156_RX_MAX_FRAME` are
defined in `src/include/constants.inc` next to the buffer addresses, and the DMA
length is pinned there with a `%error` static-assert that it can never overrun
into the adjacent TX buffer region. The two RX-arming sites now use
`RTL8156_RX_DMA_LEN` instead of a bare `4096` literal, so the clamp and the TRB
length cannot silently drift apart.

Fail-closed is correct here: a legitimate Ethernet frame is ≤ 1518 bytes, far
under the 4072 cap, and a genuinely larger frame is truncated by the 4096-byte
TRB anyway — so a length over-claim can only be corrupt or hostile.

## The proof

`rtl8156_rx_clamp_proof.py` models `.have_rx` after the clamp and enumerates the
**entire** device-controllable input space (the raw dword's low 16 bits are all
that survive the `&0x7FFF` mask, so `0..0xFFFF` is exhaustive). For every input
it asserts that a delivered frame's read window `[RX_BUF+24, RX_BUF+24+ecx)` ends
at or before `RX_BUF + RTL8156_RX_DMA_LEN`.

```
inputs checked      : 65536  (full 16-bit space)
frames delivered    : 8082
worst read offset   : 4092  (<= 4096)
pre-fix OOB inputs  : 57382  (all now dropped)
PROOF OK: no device-reported length can drive an OOB read.
```

The tool also models the pre-fix path and asserts it overruns for at least one
input (57382 do) — a live regression witness, so the proof stays meaningful if
the clamp is ever removed.

## Related hardening in the same pass

`src/kernel/drivers/rtl8156_eps.inc` (`rtl8156_find_bulk_eps`): the USB
config-descriptor walk is already bounds-safe (bLength ≥ 2 prevents an infinite
loop; each descriptor is checked to lie within `wTotalLength`, itself clamped to
`[4, 512]`). The SuperSpeed-Endpoint-Companion *peek* read the next descriptor at
`offset + bLength` without first checking it fell within `wTotalLength`; a
truncated list could latch stale control-buffer bytes as `bMaxBurst`. Added a
`offset + bLength + 6 <= wTotalLength` guard at both peek sites so every load in
the walk is provably within the device-declared total.

## Deferred (asm-before-GHL rule)

`rtl8156_handle_frame` and the DHCP option parser live in
`src/kernel/grithlk/rtl8156_dhcp_parse.ghl` (GHL, not asm). They now receive a
`ecx` already clamped to the DMA window by the fix above. Per the GSEC order of
work, the GHL side is reviewed-not-modified this run; the internal DHCP option
walk there is the next parser to audit once the asm tier is complete.
