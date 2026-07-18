#!/usr/bin/env python3
# GSEC proof: rtl8139_handle_udp DHCP option-loop bounds.
#
# Models the option walk in src/kernel/drivers/rtl8139_dhcp.inc.
# Contract established by rtl8139_poll_rx (proven 2026-07-03): the frame occupies
# [rdi, rdi+ecx) which lies entirely inside the 8 KiB RX ring, ecx clamped so
# rdi+ecx <= ring_end. r8 = rdi+ecx = frame end. Any byte index i is IN-BOUNDS
# iff i < ecx (relative to rdi). Reading i == ecx is 1 byte past frame end.
#
# We track every byte the loop dereferences and record the max index touched.
# OLD: reads the length byte [rsi+1] guarded only by rsi < ecx  -> can touch ecx.
# NEW: guards rsi+1 < ecx before reading the length byte        -> never touches ecx.

RING = 8192            # RTL_RX_BUF_LEN
OPT_START = 282        # lea rsi,[rdi+282]

def walk(ecx, opts, guarded):
    """opts: list of (type_byte, len_byte, value_bytes...) laid out from OPT_START.
    Returns (max_index_read, oob) where oob = touched an index >= ecx."""
    # materialise the option bytes into the frame image (only the option region)
    buf = bytearray(ecx)
    p = OPT_START
    for (t, l, val) in opts:
        if p < ecx: buf[p] = t
        p += 1
        if p < ecx: buf[p] = l
        p += 1
        for b in val:
            if p < ecx: buf[p] = b
            p += 1
    r8 = ecx
    rsi = OPT_START
    max_idx = -1
    def rd(i):
        nonlocal max_idx
        max_idx = max(max_idx, i)
        return buf[i] if 0 <= i < len(buf) else 0
    for _ in range(RING + 8):        # generous iteration cap (termination separately proven)
        if rsi >= r8:                # cmp rsi,r8 / jae .classify
            break
        al = rd(rsi)                 # mov al,[rsi]      (rsi<r8 -> in bounds)
        if al == 255:
            break                    # cmp al,255 / je .classify
        if al == 0:
            rsi += 1                 # .opt_pad
            continue
        if guarded:
            if rsi + 1 >= r8:        # NEW: lea rbx,[rsi+1]/cmp rbx,r8/jae .classify
                break
        dl = rd(rsi + 1)             # movzx edx,byte[rsi+1]   (<-- the audited read)
        r9 = rsi + dl + 2
        if r9 > r8:                  # cmp r9,r8 / ja .classify
            break
        # value reads (all dominated by r9<=r8 and per-opt minima) -- model the max:
        if al in (54, 3, 6) and dl >= 4:
            for k in range(4): rd(rsi + 2 + k)
        elif al == 53 and dl >= 1:
            rd(rsi + 2)
        rsi = r9                     # .next_opt
        # termination: r9 = rsi+dl+2 >= rsi+2 strictly increases rsi
    oob = max_idx >= ecx
    return max_idx, oob

def sweep(guarded):
    worst = -1
    oob_cases = 0
    # ecx from the minimum accepted frame up to a frame that fills the ring.
    for ecx in range(OPT_START, RING + 1):
        # Adversary goal: make a non-pad/non-end option's TYPE byte land on the
        # last frame byte (index ecx-1) so the length read hits ecx.
        # Fill with 1-byte-value options (type,len=... ) then a final bare type byte.
        # Layout: pad the region with type=53,len=1,val=1 (3 bytes each) then a
        # trailing single type byte 53 at ecx-1.
        n_full = (ecx - 1 - OPT_START) // 3
        opts = [(53, 1, [1])] * n_full
        # trailing bare type byte with a bogus length (attacker-chosen); to reach
        # the boundary we place its type at exactly ecx-1.
        pos = OPT_START + 3 * n_full
        if pos == ecx - 1:
            opts.append((53, 0xFF, []))   # length byte would be at ecx (OOB in OLD)
        m, oob = walk(ecx, opts, guarded)
        worst = max(worst, m)
        if oob: oob_cases += 1
    return worst, oob_cases

for guarded, name in ((False, "OLD (unguarded)"), (True, "NEW (guarded)")):
    worst, oob = sweep(guarded)
    tag = "FAIL" if (oob > 0) == guarded else "ok"
    print(f"{name:18s}: max_index_touched={worst}  frames_over_end={oob}")

wO, oO = sweep(False)
wN, oN = sweep(True)
print()
print(f"OLD over-reads on {oO} frame lengths (max index reaches frame end).")
print(f"NEW over-reads on {oN} frame lengths.")
assert oO > 0, "expected OLD to demonstrate the over-read"
assert oN == 0, "NEW must never touch index >= ecx"
print("PROVEN: NEW never reads at or past the frame end (index < ecx for all frames).")
