#!/usr/bin/env python3
# ============================================================================
# path_canonical_inslot_proof.py
#
# Proof for the 2026-07-20 GSEC daily-security-run finding on
# src/kernel/proc/syscall_validation.inc :: sc_validate_path_canonical.
#
# FINDING (S1 latent - OOB user-memory read, double-fetch / TOCTOU):
#   sc_validate_path_canonical scanned the user command string reading each byte
#   directly under USER_ACCESS_BEGIN/END with NO per-byte in-slot check. It
#   relied on two external preconditions:
#     (1) sc_validate_user_cstring ran first on an IDENTICAL (ptr,max_len), and
#     (2) the terminating NUL that cstring found is STILL where it was.
#   cstring only validates bytes [0 .. nul_index] in-slot (it returns 1 the
#   moment it reads a NUL). If a concurrent same-slot writer flips that NUL to a
#   non-NUL byte AFTER cstring passes (a double-fetch - benign today only because
#   a system-wide lock keeps at most one ring-3 context in flight, but explicitly
#   slated to go away with per-CPU CR3, see process_placement.inc:261-267), the
#   scan runs on up to max_len(=APP_OPEN_CMD_MAX=256) bytes. When ptr sits near
#   the slot end, indices past nul_index read PAST the 2 MiB slot boundary =
#   ring-0 OOB read of memory adjacent to the app slot.
#
# FIX: SPC_REQUIRE_INSLOT before every user-byte dereference re-validates the
#   byte address in the current slot via sc_validate_user_range (fail-closed),
#   exactly as sc_validate_user_cstring already does. The scan is then memory
#   safe under ANY concurrency and trusts no cross-call precondition.
#
# This is a pure arithmetic / behavioral model (no QEMU). It reimplements BOTH
# the OLD (no in-slot guard) and NEW (guarded) scans against an explicit slot
# memory model, and asserts:
#   Part A - double-fetch OOB: exhaustive sweep of (ptr offset near slot end,
#            original NUL index). OLD produces OOB reads past slot_end; NEW = 0.
#   Part B - no legitimate regression + canonicalization preserved: a battery of
#            in-slot paths (no mutation) yields IDENTICAL accept/reject verdicts
#            for OLD and NEW, and the traversal/abs/drive/ctrl rules still hold.
# Exit 0 iff every assertion holds.
# ============================================================================

SLOT_SIZE = 0x200000          # APP_SLOT_SIZE (src/include/boot_memory.inc)
MAX_LEN   = 256               # APP_OPEN_CMD_MAX (src/kernel/proc/syscall.asm:47)
SLOT_BASE = 0x40000000        # arbitrary slot base for the model
SLOT_END  = SLOT_BASE + SLOT_SIZE

class OOB(Exception):
    pass

class Mem:
    """Slot memory model. Reads at [SLOT_BASE, SLOT_END) return the byte;
    any read outside that window raises OOB (models leaving the app slot)."""
    def __init__(self, base_off, data):
        # data laid out starting at SLOT_BASE+base_off; outside -> 0xAA filler
        # but only the in-slot part is 'legal'.
        self.base_off = base_off
        self.data = data
    def read(self, addr, guarded):
        if guarded:
            # sc_validate_user_range(addr,1): reject if not in [SLOT_BASE,SLOT_END)
            if addr < SLOT_BASE or addr + 1 > SLOT_END:
                return None                      # -> caller rejects, no deref
        else:
            if addr < SLOT_BASE or addr >= SLOT_END:
                raise OOB(addr)                  # OLD: unguarded deref past slot
        idx = addr - SLOT_BASE - self.base_off
        if 0 <= idx < len(self.data):
            return self.data[idx]
        return 0xAA                              # in-slot but past our string

def scan(mem, ptr, max_len, guarded):
    """Faithful model of sc_validate_path_canonical. Returns (verdict, oob).
    verdict: 1 accept / 0 reject. oob: True if an OOB deref occurred (OLD only)."""
    def rd(addr):
        b = mem.read(addr, guarded)
        if b is None:
            raise _Reject()
        return b
    class _Reject(Exception):
        pass
    SEP = (0x2F, 0x5C)
    try:
        rcx = 0
        at_start = True
        while True:
            if rcx >= max_len:
                return 1, False                  # .spc_ok
            dl = rd(ptr + rcx)
            if dl == 0:
                return 1, False                  # NUL -> ok
            if dl < 0x20:
                return 0, False                  # ctrl reject
            if rcx == 0:
                if dl in (ord('/'), ord('\\')):
                    return 0, False
                low = dl | 0x20
                if ord('a') <= low <= ord('z') and max_len >= 2:
                    if rd(ptr + 1) == ord(':'):
                        return 0, False
            if dl == ord('.') and at_start:
                rcx += 1
                if rcx >= max_len:
                    return 1, False              # lone '.' at bound
                r8 = rd(ptr + rcx)
                if r8 == ord('.'):
                    rcx += 1
                    if rcx >= max_len:
                        return 0, False          # ".." flush to bound
                    r8 = rd(ptr + rcx)
                    if r8 == 0 or r8 in SEP:
                        return 0, False          # traversal
                # .spc_after_dot: classify r8 without re-reading
                if r8 < 0x20:
                    return 0, False
                at_start = r8 in SEP
                rcx += 1
                continue
            # .spc_advance
            at_start = dl in SEP
            rcx += 1
    except _Reject:
        return 0, False
    except OOB:
        return 0, True

# ---------------------------------------------------------------------------
# Part A: double-fetch OOB sweep.
# cstring passed => original buffer had a NUL at index k (all 0..k in-slot).
# Attacker flips byte[k] to 'A' (0x41). Now scan the MUTATED buffer.
# Place the string so that its byte k lands exactly at slot_end - tail, i.e.
# ptr = slot_end - (k + tail). For tail in [1..k+1], ptr..ptr+k are in-slot,
# but ptr+k+1.. run out of the slot.
# ---------------------------------------------------------------------------
def part_a():
    old_oob = 0
    new_oob = 0
    new_rejects = 0
    cases = 0
    for k in range(0, 40):                       # original NUL index
        for tail in range(1, k + 3):             # how close byte k is to slot end
            ptr = SLOT_END - (k + tail)
            if ptr < SLOT_BASE:
                continue
            base_off = ptr - SLOT_BASE
            # mutated content: k printable name chars, byte[k] flipped 0->'A',
            # then more 'A's with NO NUL for the rest of max_len (worst case).
            data = bytearray()
            for _ in range(k):
                data.append(ord('x'))
            for _ in range(MAX_LEN):             # no NUL after the flipped byte
                data.append(ord('A'))
            m = Mem(base_off, bytes(data))
            _, oob_old = scan(m, ptr, MAX_LEN, guarded=False)
            v_new, oob_new = scan(m, ptr, MAX_LEN, guarded=True)
            if oob_old:
                old_oob += 1
            if oob_new:
                new_oob += 1
            if v_new == 0:
                new_rejects += 1                 # NEW fails closed at the boundary
            cases += 1
    print(f"[A] double-fetch sweep: cases={cases} "
          f"OLD_oob={old_oob} NEW_oob={new_oob} NEW_failclosed={new_rejects}")
    assert old_oob > 0, "model must witness the OLD OOB"
    assert new_oob == 0, "NEW must never OOB"
    assert new_rejects == cases, "NEW must fail-closed on every boundary case"
    return cases

# ---------------------------------------------------------------------------
# Part B: no regression on legitimate (unmutated, fully in-slot) inputs, and
# canonicalization rules preserved. ptr placed with generous slack so every
# byte is in-slot; OLD and NEW must agree, and match the expected verdict.
# ---------------------------------------------------------------------------
def part_b():
    cases = [
        (b"notepad\0",            1),
        (b"apps/notepad\0",       1),
        (b"a..b\0",               1),   # ".." mid-name is a normal name
        (b"..foo\0",              1),   # ".." prefix of a name is fine
        (b"foo..\0",              1),   # trailing ".." not a component
        (b"./foo\0",              1),   # "." current-dir component ok
        (b"foo/./bar\0",          1),
        (b"..\0",                 0),   # traversal
        (b"../etc\0",             0),   # traversal
        (b"..\\win\0",            0),   # backslash traversal
        (b"a/../b\0",             0),   # mid-path traversal
        (b"foo/..\0",             0),   # trailing traversal component
        (b"/abs\0",               0),   # absolute
        (b"\\abs\0",              0),   # absolute backslash
        (b"C:evil\0",             0),   # drive prefix
        (b"c:evil\0",             0),   # drive prefix (lowercase)
        (b"bad\x01name\0",        0),   # control byte
        (b"\0",                   1),   # empty -> canonical
        (b"a\0",                  1),
        (b"a:\0",                 0),   # 1-letter drive
    ]
    ptr = SLOT_BASE + 0x1000                      # deep inside slot, plenty slack
    base_off = ptr - SLOT_BASE
    n = 0
    for content, expect in cases:
        m = Mem(base_off, content)
        v_old, oob_old = scan(m, ptr, MAX_LEN, guarded=False)
        v_new, oob_new = scan(m, ptr, MAX_LEN, guarded=True)
        assert not oob_old and not oob_new, f"no OOB expected in-slot: {content!r}"
        assert v_old == v_new == expect, (
            f"verdict mismatch {content!r}: old={v_old} new={v_new} exp={expect}")
        n += 1
    print(f"[B] legitimacy/canonicalization: {n} paths, OLD==NEW==expected")
    return n

if __name__ == "__main__":
    a = part_a()
    b = part_b()
    print(f"\nPASS: path_canonical self-bounding proof holds "
          f"(A {a} boundary cases fail-closed w/ 0 OOB; B {b} paths no regression).")
