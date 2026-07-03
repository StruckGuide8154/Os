# Proof: `net_tcp_rx_ipv4` is memory-safe and injection-resistant

Scope: `src/kernel/net/tcp.asm`, label `net_tcp_rx_ipv4` (the remote-packet RX
path — the only attacker-controlled entry point in the TCP module). This is the
GSEC G1/G2/G6 proof for the file.

## Contract
- `RDI` = pointer to the start of an IPv4 packet.
- `ECX` = number of bytes actually captured into that buffer (the *true* buffer
  length, established by the NIC/IP layer — not any length field inside the
  packet). This is the trust boundary: the packet **contents** are fully
  attacker-controlled; `ECX` is not.

Let `B = [RDI, RDI + ECX)` be the valid buffer. G1 requires: every byte the
routine dereferences lies in `B`.

## Guarded quantities
Let `L = ECX` (unsigned 32-bit) and let the IPv4 IHL nibble be `h ∈ [0,15]`, so
the IPv4 header length is `H = (h & 0xF) << 2 = 4·h ∈ {0,4,…,60}`.

The routine executes these guards in order (tcp.asm:244–260):

1. `cmp ecx,40 / jb .drop`  ⇒ accepted only if **L ≥ 40**.
2. `H = 4·h` computed from `byte[RDI]`. `byte[RDI]` ∈ B because L ≥ 40 > 0.
3. `cmp eax,20 / jb .drop`  ⇒ **H ≥ 20**.
4. `cmp ecx,eax / jbe .drop` ⇒ **L > H** (strict; blocks the L==H and L<H
   unsigned-underflow cases before the subtract).
5. `add rdi,rax` ⇒ `RDI' = RDI + H`. `sub ecx,eax` ⇒ `L' = L − H`. By (4),
   `L' ≥ 1` and no unsigned wrap occurs (G2).
6. `cmp ecx,20 / jb .drop` ⇒ **L' ≥ 20**.

## Interval argument (G1)
From (3) and (6): `20 ≤ H ≤ 60` and `L' = L − H ≥ 20`, hence `L = H + L' ≥ 40`
(consistent with (1)). The TCP header window the routine reads is
`[RDI', RDI' + 20) = [RDI + H, RDI + H + 20)`. Since `L' ≥ 20`,
`RDI + H + 20 ≤ RDI + H + L' = RDI + L = RDI + ECX`. And `RDI + H ≥ RDI`.
Therefore `[RDI', RDI'+20) ⊆ [RDI, RDI+ECX) = B`. ∎

Every dereference after the guards is at `RDI'` + one of {0, 2, 4..7, 8..11, 13}
(tcp.asm:263,267,269,278,293), all `< 20`, so all lie in `[RDI', RDI'+20) ⊆ B`.
The two pre-guard reads (`byte[RDI]` at offset 0, `dword[RDI+12]` at 12..15) lie
in B because L ≥ 40. **No out-of-bounds access is reachable for any input.** ∎

Note: TCP data-offset/options are never parsed on RX; only the fixed 20-byte
base header is read, so a lying data-offset field cannot induce an over-read.

## G2 — integer faults
No `div`/`idiv`. The only arithmetic on attacker input is `H = 4·h`
(h ≤ 15 ⇒ H ≤ 60, no overflow) and `L − H` (guarded strict-greater, no wrap).

## G3 — races
Single entry from the polled RX path (`net_nic_poll_rx`); NIC RX is polled, not
IRQ-driven (see xHCI INTx→polled decision), so no reentrancy. Connection state
(`net_tcp_state`, `net_tcp_remote_seq`) is single-connection and transitioned
monotonically within one call. No shared-state race.

## G6 — off-path injection resistance (RFC 793 / RFC 5961)
A SYN-ACK is accepted only if: state == SYN_SENT (1), flags == SYN|ACK, and the
segment ACK == `iss + 1` (full 32-bit keyed-PRNG ISN). A RST is honoured only if
state ≥ 1, the ACK bit is set, and ACK == `iss + 1`. Consequently a blind
off-path attacker must guess the full 32-bit ISN (from `net_tcp_next_isn`'s
SplitMix64-over-keyed-secret PRNG), not merely the 14-bit ephemeral source port,
to inject a spurious handshake completion or teardown. The ISN key is seeded
from RDTSC^RDRAND and stored XOR-masked at rest (`nx_secret_mask`), unmasked only
into a register at draw time.

Known, intentional limitation: in ESTABLISHED the RST is gated on `ACK==iss+1`
rather than a sequence-window check. Correct for this handshake-only client
(SND.NXT stays iss+1 until data is sent); revisit when a data path is added.

## Verification
`tools/security/tcp_rx_bounds_proof.py` enumerates every `(L, h)` in
`L ∈ [0,120], h ∈ [0,15]` and asserts the accept decision and the read window
against an independent model — the executable form of the interval argument
above. Run: `python tools/security/tcp_rx_bounds_proof.py` (exit 0 = proven).
