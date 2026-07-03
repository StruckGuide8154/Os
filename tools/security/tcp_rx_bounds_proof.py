#!/usr/bin/env python3
"""Exhaustive bounds proof for net_tcp_rx_ipv4 (src/kernel/net/tcp.asm).

This is the executable form of docs/security/proof-net-tcp-rx.md. It models the
guard sequence exactly as the assembly runs it, and for every (buffer length,
IHL nibble) pair asserts two things:

  1. Whenever the routine proceeds past the guards (i.e. would dereference the
     TCP header), the entire read window it touches lies inside the caller's
     buffer [0, L).  ==> no out-of-bounds read is reachable (GSEC G1).
  2. The guard arithmetic never underflows (GSEC G2).

The input space (L up to 120 bytes covers min-frame..IHL-max+slack, h the full
nibble) is enumerated exhaustively, so a pass is a proof over that domain, not a
sample. Runs on the host; needs no QEMU.
"""

MASK32 = 0xFFFFFFFF

# Byte offsets the routine dereferences, relative to the *TCP header* start,
# after the IP header has been skipped. Widths in bytes. (tcp.asm:263..293)
TCP_READS = [(0, 2), (2, 2), (4, 4), (8, 4), (13, 1)]
# Pre-skip reads relative to the IPv4 packet start. (tcp.asm:250, 248)
IP_READS = [(0, 1), (12, 4)]


def proceeds_and_window(L: int, h: int):
    """Model the guards. Return (proceeds, tcp_hdr_off) — proceeds=True means the
    routine reaches the TCP header dereferences at absolute offset tcp_hdr_off."""
    # Guard 1: cmp ecx,40 / jb .drop
    if L < 40:
        return (False, None)
    # Pre-skip IP reads happen here; L>=40 guarantees they're in-bounds, but we
    # still assert it below for completeness.
    H = (h & 0x0F) << 2                      # IHL*4, 0..60
    # Guard 3: cmp eax,20 / jb .drop  (H>=20)
    if H < 20:
        return (False, None)
    # Guard 4: cmp ecx,eax / jbe .drop  (strict L>H — blocks underflow)
    if L <= H:
        return (False, None)
    Lp = (L - H) & MASK32                    # sub ecx,eax ; must not wrap
    assert Lp == L - H and Lp >= 1, f"underflow at L={L} h={h}"   # G2
    # Guard 6: cmp ecx,20 / jb .drop  (L'>=20)
    if Lp < 20:
        return (False, None)
    return (True, H)


def main():
    checked = 0
    accepted = 0
    for L in range(0, 121):
        for h in range(0, 16):
            # Pre-skip IP reads: valid whenever we don't drop at guard 1.
            if L >= 40:
                for off, width in IP_READS:
                    assert off + width <= L, f"IP read OOB L={L} off={off}"
            proceeds, H = proceeds_and_window(L, h)
            checked += 1
            if not proceeds:
                continue
            accepted += 1
            # Every TCP read must lie inside [0, L).
            for off, width in TCP_READS:
                hi = H + off + width
                assert hi <= L, (
                    f"OOB read: L={L} h={h} H={H} read[{off}:{off+width}] "
                    f"-> abs {H+off}..{hi} exceeds L")
            # And the whole fixed 20-byte header window is in-bounds.
            assert H + 20 <= L, f"header window OOB L={L} h={h} H={H}"
    print(f"tcp_rx_bounds_proof: OK  ({checked} (L,h) pairs, "
          f"{accepted} reached the TCP header, 0 OOB, 0 underflow)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
