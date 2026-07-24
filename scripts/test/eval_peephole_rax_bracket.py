#!/usr/bin/env python3
# ============================================================================
# eval_peephole_rax_bracket.py - soundness proof for gritc's peephole pass D.
#
# Pass D rewrites the register-preserving bracket
#
#       push rax ; mov DEST, SRC ; pop rax     ->     mov DEST, SRC
#
# which is only legal when the middle `mov` neither writes rax (the value the
# `pop` restores) nor reads rsp (which the `push` displaced). The predicate
# guarding it used to compare the DEST *spelling* against the literal strings
# "rax"/"rsp", so every narrower spelling of the same architectural register -
# `eax`, `ax`, `al` (and `esp`, `sp`, `spl`) - slipped through. In the original
# sequence a partial write to eax/ax/al is DEAD, because `pop rax` overwrites
# the whole register immediately afterwards; with the bracket dropped that same
# write becomes LIVE and clobbers the caller's rax (a 32-bit `mov eax, imm`
# additionally zero-extends, destroying the upper half too).
#
# That matters because the kernel's custom-ABI GritHLK functions declare
# sub-register parameters as a matter of course (`al proto`, `ecx len`,
# `r15d slot`, `edi target`, ...), so partial-width `mov`s are ordinary output
# in this codebase, and pass D runs on EVERY build at the default -O1.
#
# WHY THE EXISTING FUZZER DOES NOT COVER THIS
#   scripts/test/fuzz_codegen.py is a differential miscompile hunter, but it
#   generates GHL *source*, and generated source never declares the custom
#   sub-register ABIs that produce a partial-width `mov` inside the bracket.
#   The defect is therefore invisible to it. This harness instead proves the
#   property directly on the emitted-text pass, where it lives.
#
# Theorem: for every middle instruction `mov DEST, SRC`, whatever pass D emits
# is OBSERVATIONALLY EQUIVALENT to the unoptimized three-instruction sequence -
# same final value in every architectural register, for every starting state.
# This is checked by executing both forms over a register/stack model with
# x86-64 partial-register write semantics (8/16-bit writes merge, 32-bit writes
# zero-extend), not by counting lines, so it stays meaningful if the pass is
# later rewritten or extended.
#
# Sections:
#   P1  Soundness: over the full cross product of DEST spellings (all widths of
#       rax, rsp and a set of unrelated registers) x SRC forms, pass D's output
#       is observationally equivalent to the original bracket.
#   P2  Non-regression: the brackets pass D is legitimately meant to collapse
#       (a plain write to a register unrelated to rax/rsp, at ANY width) are
#       still collapsed, so the fix did not simply disable the optimization.
#
# `--selftest` re-runs P1 against a planted pass D carrying the old
# spelling-compare predicate and requires the proof to REJECT it, so a future
# regression cannot silently pass by making the checks vacuous.
# ============================================================================
import argparse
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
COMPILER_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler')
sys.path.insert(0, COMPILER_DIR)

import gritc  # noqa: E402


class Violation(Exception):
    pass


# --- Register model -------------------------------------------------------
# Architectural state is keyed by canonical 64-bit name; a write through a
# narrower spelling applies x86-64 partial-register semantics.
CANON_REGS = ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'rsp', 'r15']
MASK64 = (1 << 64) - 1


def reg_info(spell):
    """(canonical, width_bits) for a register spelling, or None."""
    e = gritc.REG_TABLE.get(spell)
    return (e[0], e[1]) if e else None


def write_reg(state, spell, value):
    canon, width = reg_info(spell)
    old = state[canon]
    if width == 64:
        state[canon] = value & MASK64
    elif width == 32:
        # 32-bit writes zero-extend into the full 64-bit register.
        state[canon] = value & 0xFFFFFFFF
    elif width == 16:
        state[canon] = (old & ~0xFFFF & MASK64) | (value & 0xFFFF)
    elif width == 8:
        state[canon] = (old & ~0xFF & MASK64) | (value & 0xFF)
    else:
        raise Violation('unmodeled register width %r for %r' % (width, spell))


def read_operand(state, src):
    """Evaluate a SRC operand: immediate, or a register spelling."""
    s = src.strip()
    if re.fullmatch(r'-?\d+', s):
        return int(s) & MASK64
    if re.fullmatch(r'0x[0-9a-fA-F]+', s):
        return int(s, 16) & MASK64
    info = reg_info(s)
    if info is None:
        raise Violation('unmodeled SRC operand %r' % src)
    canon, width = info
    v = state[canon]
    return v & ((1 << width) - 1)


MOV_RE = re.compile(r'^mov\s+([^,]+),\s*(.+)$')


def execute(lines, state, stack):
    """Run a small straight-line sequence over the model, in place."""
    for raw in lines:
        c = gritc._code(raw).strip()
        if not c:
            continue
        if c == 'push rax':
            stack.append(state['rax'])
            state['rsp'] = (state['rsp'] - 8) & MASK64
            continue
        m = re.fullmatch(r'pop\s+(\w+)', c)
        if m:
            if not stack:
                raise Violation('model stack underflow on %r' % c)
            write_reg(state, m.group(1), stack.pop())
            state['rsp'] = (state['rsp'] + 8) & MASK64
            continue
        m = MOV_RE.match(c)
        if m:
            dest, src = m.group(1).strip(), m.group(2).strip()
            write_reg(state, dest, read_operand(state, src))
            continue
        raise Violation('unmodeled instruction in pass-D output: %r' % c)


def start_states():
    """A few adversarial starting states (distinct, non-zero, high bits set)."""
    base = {r: 0 for r in CANON_REGS}
    s1 = dict(base)
    for i, r in enumerate(CANON_REGS):
        s1[r] = (0xDEADBEEF00000000 + (i + 1) * 0x1111) & MASK64
    s2 = dict(base)
    for i, r in enumerate(CANON_REGS):
        s2[r] = (0xFFFFFFFFFFFFFFFF - i) & MASK64
    s3 = dict(base)
    s3['rax'] = 0x123456789ABCDEF0
    return [s1, s2, s3]


# --- Case space -----------------------------------------------------------
# Every spelling of rax and rsp (the two registers the bracket is about), plus
# unrelated registers at every width to pin the non-regression direction.
RAX_SPELLINGS = ['rax', 'eax', 'ax', 'al']
RSP_SPELLINGS = ['rsp', 'esp', 'sp', 'spl']
OTHER_SPELLINGS = ['rbx', 'ebx', 'bx', 'bl', 'rcx', 'ecx', 'r15', 'r15d']
SRCS = ['5', '0x1234', 'rbx', 'ecx', 'rdi']


def known(spell):
    return gritc.REG_TABLE.get(spell) is not None


def run_pass_d(peephole, dest, src):
    seq = ['    push rax', '    mov %s, %s' % (dest, src), '    pop rax']
    return list(seq), peephole(list(seq))


def prove_soundness(peephole):
    """P1: pass D output is observationally equivalent to the original."""
    checks = 0
    for dest in RAX_SPELLINGS + RSP_SPELLINGS + OTHER_SPELLINGS:
        if not known(dest):
            continue
        for src in SRCS:
            if not (re.fullmatch(r'-?\d+|0x[0-9a-fA-F]+', src) or known(src)):
                continue
            original, optimized = run_pass_d(peephole, dest, src)
            for st in start_states():
                a, sa = dict(st), []
                b, sb = dict(st), []
                execute(original, a, sa)
                execute(optimized, b, sb)
                if a != b:
                    bad = [r for r in CANON_REGS if a[r] != b[r]]
                    raise Violation(
                        'pass D MISCOMPILE on `push rax ; mov %s, %s ; pop rax`'
                        ': register(s) %s differ after the rewrite '
                        '(unoptimized %s=0x%016x, optimized %s=0x%016x)'
                        % (dest, src, ','.join(bad), bad[0], a[bad[0]],
                           bad[0], b[bad[0]]))
                checks += 1
    return checks


def prove_non_regression(peephole):
    """P2: brackets pass D legitimately collapses are still collapsed."""
    checks = 0
    for dest in OTHER_SPELLINGS:
        if not known(dest):
            continue
        _, optimized = run_pass_d(peephole, dest, '5')
        codes = [gritc._code(l).strip() for l in optimized
                 if gritc._code(l).strip()]
        if codes != ['mov %s, 5' % dest]:
            raise Violation(
                'pass D no longer collapses the sound bracket '
                '`push rax ; mov %s, 5 ; pop rax` (got %r) - the optimization '
                'was disabled rather than corrected' % (dest, codes))
        checks += 1
    return checks


# --- Planted-defect selftest ----------------------------------------------
def buggy_peephole(lines, extended=True, zero_idiom=False):
    """The pre-fix pass D predicate: compares DEST spelling, not canonical."""
    out = []
    i = 0
    n = len(lines)
    while i < n:
        if i + 2 < n and gritc._PEEP_PUSH_RAX.match(gritc._code(lines[i])):
            mm = gritc._MOV2_RE.match(gritc._code(lines[i + 1]).strip())
            mp = gritc._PEEP_POP_REG.match(gritc._code(lines[i + 2]))
            if mm and mp and mp.group(1) == 'rax':
                dest = mm.group(1).strip()
                src = mm.group(2).strip()
                if (dest not in ('rax', 'rsp')
                        and re.fullmatch(r'[a-z][a-z0-9]+', dest)
                        and gritc._canon(dest)
                        and not re.search(r'\brax\b', src)
                        and not re.search(r'\brsp\b', src)):
                    out.append('    mov %s, %s' % (dest, src))
                    i += 3
                    continue
        out.append(lines[i])
        i += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true',
                    help='require the proof to REJECT a planted buggy pass D')
    args = ap.parse_args()

    if args.selftest:
        try:
            prove_soundness(buggy_peephole)
        except Violation:
            print('[peephole-rax] selftest PASS: the planted spelling-compare '
                  'pass D was caught')
            return 0
        print('[peephole-rax] selftest FAIL: the planted buggy pass D was NOT '
              'caught - the proof no longer tests that clause', file=sys.stderr)
        return 1

    try:
        n1 = prove_soundness(gritc._peephole)
        n2 = prove_non_regression(gritc._peephole)
    except Violation as v:
        print('[peephole-rax] FAIL: %s' % v, file=sys.stderr)
        return 1
    print('[peephole-rax] PASS: pass D is observationally equivalent to the '
          'unoptimized bracket (%d state checks over rax/rsp/unrelated DEST '
          'spellings) and still collapses the %d sound shapes' % (n1, n2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
