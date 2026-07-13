#!/usr/bin/env python3
# ============================================================================
# fuzz_codegen.py - GHL compiler / codegen differential fuzzer + asm simulator.
#
# WHAT THIS IS
#   A self-contained harness that hunts for *miscompiles*, *compiler crashes*,
#   and *stack/frame/immediate overflows* across EVERY gritc optimization level
#   (--O0 .. --O4) - and that actually SIMULATES the emitted x86-64 machine code
#   to verify it computes the right answer, instead of just diffing text.
#
# HOW IT FINDS BUGS (the oracle)
#   For each generated program we have THREE independent verdicts that must all
#   agree:
#     1. An AST interpreter (this file) - the language-level ground truth.
#     2. The bytes gritc emits at O0, run on a real CPU emulator (Unicorn).
#     3. The bytes gritc emits at O1/O2/O3/O4, run on the same emulator.
#   Any disagreement is a real defect:
#     - O0 != interpreter      -> a frontend / naive-codegen bug.
#     - On!= O0 (n>=1)         -> an OPTIMIZER miscompile (regalloc / peephole /
#                                 inlining changed observable behavior).
#   The cross-opt-level differential is self-calibrating: it needs no trust in
#   the interpreter at all, so it catches optimizer bugs with zero false
#   positives. The interpreter is the extra leg that also catches O0 bugs; its
#   few semantically-ambiguous operators (>>, /, %, signed compares) are
#   AUTO-CALIBRATED at startup against the real compiler+CPU, so it never guesses.
#
# MODES
#   fuzz     (default) generate random GHL, compile at all opt levels, simulate,
#            and triple-check. The core miscompile hunter.
#   robust   throw pathological GHL (deep nesting, huge immediates, thousands of
#            locals, long expression chains) at every pass; a Python traceback,
#            a hang, or invalid emitted asm is a compiler overflow/robustness bug.
#   modules  take the REAL OS .ghl sources and compile each at every opt level;
#            a crash or non-assembling output is a compiler bug on shipping code.
#   rawasm   static overflow-pattern audit of the hand-written .asm / .inc that
#            the compiler does NOT produce (unbounded rep/loops, raw rsp growth).
#   asmoob   EXECUTE hand-written asm routines in a guard-page sandbox and prove
#            real out-of-bounds reads/writes: slice a routine from its label,
#            auto-stub the kernel constants nasm reports undefined, point a
#            buffer flush against an unmapped guard page, and sweep the count /
#            index register. A missing bound check faults on the exact emitted
#            instruction (disassembled + reported). Routines that address their
#            own fixed memory are flagged 'unmodeled' (need a hand-written spec),
#            never reported as a bug -- findings are witness-backed only.
#            Use --selftest-only to see the detector fire on a known-bad memset.
#
# DEPS: unicorn, capstone (pip); nasm (C:\Tools\nasm-2.16.03\nasm.exe).
# ============================================================================
import argparse
import os
import random
import re
import subprocess
import sys
import traceback

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
COMPILER_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler')
LIB_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'lib')
OUT_DIR = os.path.join(ROOT, 'build', 'fuzz_out')
TMP_DIR = os.path.join(ROOT, 'build', 'fuzz_tmp')
NASM = os.environ.get('NASM', r'C:\Tools\nasm-2.16.03\nasm.exe')

sys.path.insert(0, COMPILER_DIR)
import gritc  # noqa: E402  the production GHL compiler - the unit under test

try:
    from unicorn import (Uc, UcError, UC_ARCH_X86, UC_MODE_64,
                         UC_HOOK_MEM_UNMAPPED, UC_HOOK_INSN_INVALID,
                         UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE)
    from unicorn.x86_const import (UC_X86_REG_RSP, UC_X86_REG_RAX, UC_X86_REG_RIP,
                                   UC_X86_REG_RBP,
                                   UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX,
                                   UC_X86_REG_RCX, UC_X86_REG_RBX,
                                   UC_X86_REG_R8, UC_X86_REG_R9, UC_X86_REG_R10,
                                   UC_X86_REG_R11, UC_X86_REG_R12, UC_X86_REG_R13,
                                   UC_X86_REG_R14, UC_X86_REG_R15)
except ImportError:
    sys.stderr.write("fuzz_codegen: needs `pip install unicorn capstone`\n")
    raise

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
    _CS = Cs(CS_ARCH_X86, CS_MODE_64)
except ImportError:
    _CS = None


def _disasm_at(uc, addr, n=16):
    """Disassemble one instruction at addr (for fault reporting)."""
    if _CS is None:
        return "?"
    try:
        code = uc.mem_read(addr, n)
    except UcError:
        return "?"
    for ins in _CS.disasm(bytes(code), addr):
        return "%s %s" % (ins.mnemonic, ins.op_str)
    return "(bad)"

M = (1 << 64) - 1          # 64-bit mask
ARG_UC = [UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX,
          UC_X86_REG_RCX, UC_X86_REG_R8, UC_X86_REG_R9]   # System V (gritc CALL_REGS)

# Opt levels -> compile_file kwargs.  Mirrors gritc.main()'s flag fold.
OPT_LEVELS = {
    'O0': dict(optimize=False, regalloc=False, o3=False, o4=False),
    'O1': dict(optimize=True,  regalloc=False, o3=False, o4=False),
    'O2': dict(optimize=True,  regalloc=True,  o3=False, o4=False),
    'O3': dict(optimize=True,  regalloc=True,  o3=True,  o4=False),
    'O4': dict(optimize=True,  regalloc=True,  o3=True,  o4=True),
}


def s64(x):
    x &= M
    return x - (1 << 64) if x & (1 << 63) else x


def u64(x):
    return x & M


# ============================================================================
# Toolchain driver: GHL source -> emitted asm -> flat machine code -> result.
# ============================================================================
class CompileError(Exception):
    pass


class AssembleError(Exception):
    pass


def compile_ghl(src_text, prefix, opt_kwargs):
    """GHL text -> emitted nasm asm text, at the given opt level."""
    os.makedirs(TMP_DIR, exist_ok=True)
    path = os.path.join(TMP_DIR, prefix + '.ghl')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(src_text)
    try:
        return gritc.compile_file(path, LIB_DIR, app_prefix=prefix,
                                  embed=True, **opt_kwargs)
    except (SyntaxError, ValueError, KeyError) as e:
        raise CompileError(str(e))


_PRELUDE = ("bits 64\ndefault rel\n"
            "%macro FN_BEGIN 4\n%1:\n%endmacro\n"   # FN_BEGIN emits the fn label
            "%macro FN_ARG 3\n%endmacro\n"
            "%macro FN_END 1\n%endmacro\n"
            "%macro FN_CALL 2\n    call %1\n%endmacro\n"  # inter-fn call -> direct call
            "section .text\n")


def assemble(asm_body, entry_symbol, prefix):
    """Wrap emitted asm with stub macros + an entry trampoline, run nasm -f bin.
    Returns (code_bytes, entry_offset=0)."""
    os.makedirs(TMP_DIR, exist_ok=True)
    wrap = _PRELUDE + "    jmp " + entry_symbol + "\n" + asm_body
    apath = os.path.join(TMP_DIR, prefix + '.asm')
    bpath = os.path.join(TMP_DIR, prefix + '.bin')
    with open(apath, 'w', encoding='utf-8') as f:
        f.write(wrap)
    r = subprocess.run([NASM, '-f', 'bin', '-o', bpath, apath],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise AssembleError(r.stderr.strip())
    with open(bpath, 'rb') as f:
        return f.read(), 0


_BASE = 0x100000
_STACK = 0x800000
_STACK_SZ = 0x100000
_RET = 0xdeadbee0


def simulate(code, args, insn_budget=400000):
    """Run flat machine code (entry at offset 0) with System-V int args.
    Returns rax as an unsigned 64-bit int. Raises on fault / runaway."""
    mu = Uc(UC_ARCH_X86, UC_MODE_64)
    cap = (len(code) + 0xFFF) & ~0xFFF
    cap = max(cap, 0x10000)
    mu.mem_map(_BASE, cap)
    mu.mem_write(_BASE, code)
    mu.mem_map(_STACK, _STACK_SZ)
    sp = _STACK + _STACK_SZ - 0x1000
    mu.mem_write(sp, _RET.to_bytes(8, 'little'))
    mu.reg_write(UC_X86_REG_RSP, sp)
    for i, a in enumerate(args[:6]):
        mu.reg_write(ARG_UC[i], a & M)
    faults = []
    mu.hook_add(UC_HOOK_MEM_UNMAPPED,
                lambda uc, t, addr, sz, val, ud: faults.append(('mem', addr)) or False)
    mu.hook_add(UC_HOOK_INSN_INVALID,
                lambda uc, ud: faults.append(('insn', uc.reg_read(UC_X86_REG_RIP))) or False)
    try:
        mu.emu_start(_BASE, _RET, count=insn_budget)
    except UcError as e:
        rip = mu.reg_read(UC_X86_REG_RIP)
        raise RuntimeError("emu fault %s @ rip=0x%x faults=%s" % (e, rip, faults))
    if mu.reg_read(UC_X86_REG_RIP) != _RET:
        raise RuntimeError("runaway: did not return within %d insns (rip=0x%x)"
                           % (insn_budget, mu.reg_read(UC_X86_REG_RIP)))
    return mu.reg_read(UC_X86_REG_RAX)


# ============================================================================
# GHL program generator + matching AST interpreter (the language oracle).
# ============================================================================
# Operator semantics are calibrated at startup (see SEM). Everything is computed
# in 64-bit; the interpreter mirrors exactly what the calibration discovered.
SEM = {'shr': 'logical', 'div': 'signed', 'mod': 'signed', 'cmp': 'signed'}

BINOPS_SAFE = ['+', '-', '*', '&', '|', '^']     # unambiguous mod 2^64
CMPOPS = ['==', '!=', '<', '<=', '>', '>=']


class Gen:
    def __init__(self, rng, nparams, max_depth=4):
        self.rng = rng
        self.nparams = nparams
        self.max_depth = max_depth
        self.fns = []          # list of (name, nparams)
        self.scopes = [[]]     # lexical scope stack of local names (init-before-use)
        self.protected = set()  # loop counters: never reassigned in their body
        self.let_ct = 0

    @property
    def in_scope(self):
        return [n for sc in self.scopes for n in sc]

    @property
    def assignable(self):
        return [n for n in self.in_scope if n not in self.protected]

    # ---- expression AST: tuples (op, ...) ----
    def expr(self, depth):
        r = self.rng
        if depth <= 0 or r.random() < 0.35:
            return self._leaf()
        c = r.random()
        if c < 0.45:
            op = r.choice(BINOPS_SAFE)
            return ('bin', op, self.expr(depth - 1), self.expr(depth - 1))
        if c < 0.58:
            op = r.choice(CMPOPS)
            return ('cmp', op, self.expr(depth - 1), self.expr(depth - 1))
        if c < 0.68:
            return ('shl', self.expr(depth - 1), r.randint(0, 63))
        if c < 0.78:
            return ('shr', self.expr(depth - 1), r.randint(0, 63))
        if c < 0.86:
            # safe divisor: positive, nonzero -> no #DE, no INT_MIN/-1 trap
            return ('div', self.expr(depth - 1), ('safe', self.expr(depth - 1)))
        if c < 0.92:
            return ('mod', self.expr(depth - 1), ('safe', self.expr(depth - 1)))
        if c < 0.96:
            return ('un', '-', self.expr(depth - 1))   # GHL has unary - only
        if self.fns and r.random() < 0.7:
            name, na = r.choice(self.fns)
            return ('call', name, [self.expr(depth - 1) for _ in range(na)])
        return self._leaf()

    def _leaf(self):
        r = self.rng
        c = r.random()
        scope = self.in_scope
        if c < 0.4 and self.nparams:
            return ('param', r.randrange(self.nparams))
        if c < 0.6 and scope:
            return ('local', r.choice(scope))
        edge = [0, 1, -1, 2, 0xFFFFFFFF, 0x100000000, (1 << 63),
                (1 << 63) - 1, -(1 << 63), 0x7FFFFFFF, 0xDEADBEEF]
        if c < 0.75:
            return ('lit', r.choice(edge))
        return ('lit', r.randint(-(1 << 40), 1 << 40))

    # ---- statements ----
    def block(self, depth, nstmts):
        """A new lexical scope: locals declared here are popped on exit, so any
        later reference is to an enclosing (already-initialized) local."""
        self.scopes.append([])
        out = [self.stmt(depth) for _ in range(nstmts)]
        self.scopes.pop()
        return out

    def stmt(self, depth):
        r = self.rng
        c = r.random()
        assignable = self.assignable
        if c < 0.4 or not self.in_scope:
            name = 'v%d' % self.let_ct
            self.let_ct += 1
            e = self.expr(depth)          # evaluated BEFORE name is in scope
            self.scopes[-1].append(name)
            return ('let', name, e)
        if c < 0.65 and assignable:
            return ('assign', r.choice(assignable), self.expr(depth))
        if c < 0.8 and depth > 0:
            return ('if', self.expr(depth - 1),
                    self.block(depth - 1, r.randint(1, 2)),
                    self.block(depth - 1, r.randint(0, 2)))
        if c < 0.9 and depth > 0:
            # bounded loop: counter declared in THIS scope, unambiguous != guard,
            # body cannot reassign the counter (protected), decrement, terminates.
            cname = 'v%d' % self.let_ct
            self.let_ct += 1
            self.scopes[-1].append(cname)
            self.protected.add(cname)
            body = self.block(depth - 1, r.randint(1, 2))
            self.protected.discard(cname)
            return ('loop', cname, r.randint(1, 6), body)
        if assignable:
            return ('assign', r.choice(assignable), self.expr(depth))
        # fallback: declare a fresh local
        name = 'v%d' % self.let_ct
        self.let_ct += 1
        e = self.expr(depth)
        self.scopes[-1].append(name)
        return ('let', name, e)

    # ---- emit GHL text for one fn ----
    def emit_fn(self, name, nparams, depth):
        self.nparams = nparams
        self.scopes = [[]]        # fresh fn scope (kept in scope for `return`)
        self.protected = set()
        self.let_ct = 0
        params = ['p%d' % i for i in range(nparams)]
        # fn-body statements live in the fn scope (NOT a popped child scope) so
        # the return expression can reference them.
        body = [self.stmt(depth) for _ in range(self.rng.randint(2, 5))]
        ret = self.expr(depth)
        lines = ['fn %s(%s) {' % (name, ', '.join(params))]
        self._emit_block(body, lines, 1)
        lines.append('    return %s;' % self._emit_expr(ret))
        lines.append('}')
        return '\n'.join(lines), body, ret

    def _emit_block(self, block, lines, ind):
        pad = '    ' * ind
        for s in block:
            k = s[0]
            if k == 'let':
                lines.append('%slet %s = %s;' % (pad, s[1], self._emit_expr(s[2])))
            elif k == 'assign':
                lines.append('%s%s = %s;' % (pad, s[1], self._emit_expr(s[2])))
            elif k == 'if':
                lines.append('%sif (%s) {' % (pad, self._emit_expr(s[1])))
                self._emit_block(s[2], lines, ind + 1)
                if s[3]:
                    lines.append('%s} else {' % pad)
                    self._emit_block(s[3], lines, ind + 1)
                lines.append('%s}' % pad)
            elif k == 'loop':
                lines.append('%slet %s = %d;' % (pad, s[1], s[2]))
                lines.append('%swhile (%s != 0) {' % (pad, s[1]))
                self._emit_block(s[3], lines, ind + 1)
                lines.append('%s    %s = %s - 1;' % (pad, s[1], s[1]))
                lines.append('%s}' % pad)

    def _emit_expr(self, e):
        k = e[0]
        if k == 'lit':
            return str(e[1])
        if k == 'param':
            return 'p%d' % e[1]
        if k == 'local':
            return e[1]
        if k == 'bin':
            return '(%s %s %s)' % (self._emit_expr(e[2]), e[1], self._emit_expr(e[3]))
        if k == 'cmp':
            return '(%s %s %s)' % (self._emit_expr(e[2]), e[1], self._emit_expr(e[3]))
        if k == 'shl':
            return '(%s << %d)' % (self._emit_expr(e[1]), e[2])
        if k == 'shr':
            return '(%s >> %d)' % (self._emit_expr(e[1]), e[2])
        if k == 'div':
            return '(%s / %s)' % (self._emit_expr(e[1]), self._emit_expr(e[2]))
        if k == 'mod':
            return '(%s %% %s)' % (self._emit_expr(e[1]), self._emit_expr(e[2]))
        if k == 'un':
            return '(%s%s)' % (e[1], self._emit_expr(e[2]))
        if k == 'safe':
            # positive nonzero divisor: ((x & 0x7fffffff) + 1)
            return '((%s & 2147483647) + 1)' % self._emit_expr(e[1])
        if k == 'call':
            return '%s(%s)' % (e[1], ', '.join(self._emit_expr(a) for a in e[2]))
        raise AssertionError(k)


class Interp:
    """Evaluates a generated program's AST with the calibrated semantics."""
    def __init__(self, fns_ast):
        self.fns = fns_ast  # name -> (params, body, ret)

    def call(self, name, args):
        params, body, ret = self.fns[name]
        env = {p: u64(a) for p, a in zip(params, args)}
        self._exec(body, env)
        return u64(self._eval(ret, env))

    def _exec(self, block, env):
        for s in block:
            k = s[0]
            if k == 'let' or k == 'assign':
                env[s[1]] = u64(self._eval(s[2], env))
            elif k == 'if':
                if self._eval(s[1], env) != 0:
                    self._exec(s[2], env)
                else:
                    self._exec(s[3], env)
            elif k == 'loop':
                env[s[1]] = u64(s[2])
                guard = 0
                while env[s[1]] != 0:
                    self._exec(s[3], env)
                    env[s[1]] = u64(env[s[1]] - 1)
                    guard += 1
                    if guard > 100000:
                        raise RuntimeError("interp loop runaway")

    def _eval(self, e, env):
        k = e[0]
        if k == 'lit':
            return u64(e[1])
        if k == 'param' or k == 'local':
            key = ('p%d' % e[1]) if k == 'param' else e[1]
            return env[key]
        if k == 'bin':
            a = self._eval(e[2], env); b = self._eval(e[3], env)
            op = e[1]
            if op == '+': return u64(a + b)
            if op == '-': return u64(a - b)
            if op == '*': return u64(a * b)
            if op == '&': return a & b
            if op == '|': return a | b
            if op == '^': return a ^ b
        if k == 'shl':
            return u64(self._eval(e[1], env) << (e[2] & 63))
        if k == 'shr':
            v = self._eval(e[1], env)
            if SEM['shr'] == 'logical':
                return v >> (e[2] & 63)
            return u64(s64(v) >> (e[2] & 63))
        if k == 'cmp':
            a = self._eval(e[2], env); b = self._eval(e[3], env)
            op = e[1]
            if op == '==': return 1 if a == b else 0
            if op == '!=': return 1 if a != b else 0
            if SEM['cmp'] == 'signed':
                a, b = s64(a), s64(b)
            if op == '<': return 1 if a < b else 0
            if op == '<=': return 1 if a <= b else 0
            if op == '>': return 1 if a > b else 0
            if op == '>=': return 1 if a >= b else 0
        if k == 'div' or k == 'mod':
            a = self._eval(e[1], env); b = self._eval(e[2], env)
            if b == 0:
                b = 1
            if SEM['div'] == 'signed':
                sa, sb = s64(a), s64(b)
                q = abs(sa) // abs(sb)
                q = -q if (sa < 0) != (sb < 0) else q
                r = sa - q * sb
            else:
                q = a // b; r = a % b
            return u64(q if k == 'div' else r)
        if k == 'un':
            v = self._eval(e[2], env)
            return u64(-v) if e[1] == '-' else u64(~v)
        if k == 'safe':
            return u64((self._eval(e[1], env) & 0x7FFFFFFF) + 1)
        if k == 'call':
            return self.call(e[1], [self._eval(a, env) for a in e[2]])
        raise AssertionError(k)


def build_program(rng):
    """Generate a multi-fn GHL unit. Returns (src_text, fns_ast, entry_name)."""
    g = Gen(rng, 0)
    nhelpers = rng.randint(0, 3)
    parts = []
    fns_ast = {}
    for h in range(nhelpers):
        name = 'h%d' % h
        na = rng.randint(0, 3)
        txt, body, ret = g.emit_fn(name, na, rng.randint(1, 3))
        parts.append(txt)
        fns_ast[name] = (['p%d' % i for i in range(na)], body, ret)
        g.fns.append((name, na))   # only callable by later fns
    na = rng.randint(1, 3)
    txt, body, ret = g.emit_fn('entry', na, rng.randint(2, 4))
    parts.append(txt)
    fns_ast['entry'] = (['p%d' % i for i in range(na)], body, ret)
    return '\n\n'.join(parts), fns_ast, ('entry', na)


# ============================================================================
# Calibration: discover gritc's ambiguous-operator semantics empirically.
# ============================================================================
def _probe(op_src, a, b):
    src = "fn t(x, y) {\n    return %s;\n}\n" % op_src
    asm = compile_ghl(src, 'cal', OPT_LEVELS['O0'])
    code, _ = assemble(asm, 'app_hl_cal_t', 'cal')
    return simulate(code, [a, b])


def calibrate():
    # >> : arithmetic vs logical, probe with a negative value
    v = (-16) & M
    got = _probe("x >> 2", v, 0)
    SEM['shr'] = 'arith' if got == u64(s64(v) >> 2) else 'logical'
    # signed compare: -1 < 1 ?  signed=>1, unsigned=>0 (since -1 is huge)
    got = _probe("x < y", (-1) & M, 1)
    SEM['cmp'] = 'signed' if got == 1 else 'unsigned'
    # signed div: -8 / 2 == -4 (signed) vs huge (unsigned)
    got = _probe("x / y", (-8) & M, 2)
    SEM['div'] = 'signed' if s64(got) == -4 else 'unsigned'
    got = _probe("x - (x / y) * y", (-7) & M, 2)  # remainder consistency probe
    SEM['mod'] = SEM['div']
    print("[calibrate] shr=%s cmp=%s div/mod=%s" % (SEM['shr'], SEM['cmp'], SEM['div']))


# ============================================================================
# Failure reporting
# ============================================================================
def save_failure(tag, src_text, detail):
    os.makedirs(OUT_DIR, exist_ok=True)
    n = len([f for f in os.listdir(OUT_DIR) if f.startswith(tag)])
    base = os.path.join(OUT_DIR, "%s_%03d" % (tag, n))
    with open(base + '.ghl', 'w', encoding='utf-8') as f:
        f.write("# FAILURE: %s\n# %s\n\n%s\n" % (tag, detail.replace('\n', '\n# '), src_text))
    return base + '.ghl'


# ============================================================================
# MODE: fuzz - the core miscompile hunter
# ============================================================================
def vectors(rng, nparams, n=6):
    edges = [0, 1, (-1) & M, 2, (1 << 63), (1 << 63) - 1, 0xFFFFFFFF, 0xDEADBEEFCAFE]
    out = []
    for _ in range(n):
        out.append([rng.choice(edges) if rng.random() < 0.5
                    else rng.randint(0, M) for _ in range(nparams)])
    return out


def mode_fuzz(args):
    rng = random.Random(args.seed)
    bugs = 0
    for it in range(args.iters):
        try:
            src, fns_ast, (entry, na) = build_program(rng)
        except Exception as e:
            print("[gen] internal generator error:", e)
            continue
        interp = Interp(fns_ast)
        # compile every opt level once
        codes = {}
        compile_failed = False
        for lvl, kw in OPT_LEVELS.items():
            try:
                asm = compile_ghl(src, 'fz', kw)
                code, _ = assemble(asm, 'app_hl_fz_entry', 'fz_' + lvl)
                codes[lvl] = code
            except CompileError as e:
                p = save_failure('compilecrash', src, "%s: %s" % (lvl, e))
                print("[BUG] compile error @ %s -> %s" % (lvl, p))
                bugs += 1; compile_failed = True; break
            except AssembleError as e:
                p = save_failure('badasm', src, "%s emitted non-assembling asm: %s" % (lvl, e))
                print("[BUG] non-assembling emit @ %s -> %s" % (lvl, p))
                bugs += 1; compile_failed = True; break
        if compile_failed:
            continue
        for vec in vectors(rng, na):
            try:
                expect = interp.call(entry, vec)
            except RuntimeError:
                continue  # interp runaway on this vector; skip
            results = {}
            faulted = False
            for lvl, code in codes.items():
                try:
                    results[lvl] = simulate(code, vec)
                except RuntimeError as e:
                    p = save_failure('emufault', src,
                                     "%s faulted on args=%s: %s" % (lvl, vec, e))
                    print("[BUG] emu fault @ %s args=%s -> %s" % (lvl, vec, p))
                    bugs += 1; faulted = True; break
            if faulted:
                break
            # cross-opt-level differential (self-calibrating, zero false positive)
            ref = results['O0']
            disagree = {l: v for l, v in results.items() if v != ref}
            if disagree:
                p = save_failure('miscompile', src,
                                 "args=%s O0=0x%x but %s" % (
                                     vec, ref, {l: hex(v) for l, v in disagree.items()}))
                print("[BUG] OPTIMIZER MISCOMPILE args=%s O0=0x%x %s -> %s" % (
                    vec, ref, {l: hex(v) for l, v in disagree.items()}, p))
                bugs += 1
                break
            # interpreter cross-check (catches O0 / frontend bugs)
            if ref != expect:
                p = save_failure('o0_vs_interp', src,
                                 "args=%s interp=0x%x O0=0x%x (frontend/O0 or harness-sem)" % (
                                     vec, expect, ref))
                print("[BUG] O0 != interpreter args=%s interp=0x%x O0=0x%x -> %s" % (
                    vec, expect, ref, p))
                bugs += 1
                break
        if args.verbose and it % 200 == 0:
            print("[fuzz] %d/%d  bugs=%d" % (it, args.iters, bugs))
    print("\n[fuzz] done: %d iterations, %d bug(s). Artifacts in %s" % (args.iters, bugs, OUT_DIR))
    return bugs


# ============================================================================
# MODE: robust - pathological inputs -> compiler crashes / overflows
# ============================================================================
def mode_robust(args):
    rng = random.Random(args.seed)
    bugs = 0
    cases = []
    # 1. very deep expression nesting (parser recursion / stack-machine depth)
    cases.append(('deep_nest', "fn t(x) {\n    return " +
                  "(" * 600 + "x" + " + 1)" * 600 + ";\n}\n"))
    # 2. enormous immediate (imm64 path / wrap handling)
    cases.append(('huge_imm', "fn t() {\n    return %d;\n}\n" % ((1 << 63) + 12345)))
    cases.append(('neg_huge_imm', "fn t() {\n    return %d;\n}\n" % (-(1 << 63))))
    # 3. thousands of locals (frame-size sizing / sub rsp overflow)
    body = "\n".join("    let a%d = %d;" % (i, i) for i in range(4000))
    cases.append(('many_locals', "fn t() {\n%s\n    return a3999;\n}\n" % body))
    # 4. very long flat expression chain (stack-machine spill depth)
    chain = " + ".join("x" for _ in range(2000))
    cases.append(('long_chain', "fn t(x) {\n    return %s;\n}\n" % chain))
    # 5. max shift counts
    cases.append(('shift_edges',
                  "fn t(x) {\n    return ((x << 63) >> 63) << 0;\n}\n"))
    # 6. deeply nested blocks (scope / label generation)
    s = "    return x;\n"
    for _ in range(200):
        s = "    if (x) {\n" + s + "    }\n"
    cases.append(('deep_blocks', "fn t(x) {\n%s}\n" % s))
    # 7. random structurally-large generated programs
    g_rng = random.Random(args.seed ^ 0x5151)
    for i in range(args.iters):
        gg = Gen(g_rng, 0, max_depth=8)
        try:
            txt, _, _ = gg.emit_fn('t', 3, 8)
            cases.append(('rand_big_%d' % i, txt))
        except RecursionError:
            pass

    for tag, src in cases:
        for lvl, kw in OPT_LEVELS.items():
            try:
                asm = compile_ghl(src, 'rb', kw)
            except CompileError as e:
                # a clean diagnostic is ACCEPTABLE robustness behavior
                if args.verbose:
                    print("[robust] %-14s %s clean-reject: %s" % (tag, lvl, str(e)[:70]))
                continue
            except RecursionError:
                p = save_failure('compiler_recursion', src, "%s %s: RecursionError" % (tag, lvl))
                print("[BUG] compiler RecursionError %s @ %s -> %s" % (tag, lvl, p))
                bugs += 1; continue
            except Exception as e:
                p = save_failure('compiler_crash', src,
                                 "%s %s: %s\n%s" % (tag, lvl, e, traceback.format_exc()))
                print("[BUG] compiler CRASH %s @ %s: %s -> %s" % (tag, lvl, type(e).__name__, p))
                bugs += 1; continue
            try:
                assemble(asm, 'app_hl_rb_t', 'rb_' + lvl)
            except AssembleError as e:
                p = save_failure('badasm', src, "%s %s non-assembling: %s" % (tag, lvl, e))
                print("[BUG] %s @ %s emitted non-assembling asm -> %s" % (tag, lvl, p))
                bugs += 1
    print("\n[robust] done: %d case(s), %d bug(s)." % (len(cases), bugs))
    return bugs


# ============================================================================
# MODE: modules - compile the REAL OS .ghl at every opt level
# ============================================================================
def mode_modules(args):
    import glob
    bugs = 0
    files = sorted(glob.glob(os.path.join(ROOT, 'src', '**', '*.ghl'), recursive=True))
    print("[modules] %d .ghl files" % len(files))
    for path in files:
        rel = os.path.relpath(path, ROOT)
        is_kernel = (os.sep + 'kernel' + os.sep) in path or (os.sep + 'enclave' + os.sep) in path \
            or (os.sep + 'tools' + os.sep) in path or (os.sep + 'boot' + os.sep) in path
        kw_target = {}
        if is_kernel:
            kw_target = dict(kernel=True, target='kernel')
        prefix = os.path.splitext(os.path.basename(path))[0]
        for lvl, kw in OPT_LEVELS.items():
            try:
                gritc.compile_file(path, LIB_DIR, app_prefix=prefix,
                                   embed=True, **kw, **kw_target)
            except (SyntaxError, ValueError) as e:
                # Could be a legit source error or a real compiler bug; surface O0 only
                if lvl == 'O0':
                    print("[modules] %-50s %s reject: %s" % (rel, lvl, str(e)[:80]))
                break
            except Exception as e:
                p = save_failure('module_crash', rel,
                                 "%s %s: %s\n%s" % (rel, lvl, e, traceback.format_exc()))
                print("[BUG] compiler CRASH on real module %s @ %s: %s -> %s"
                      % (rel, lvl, type(e).__name__, p))
                bugs += 1
                break
    print("\n[modules] done: %d bug(s)." % bugs)
    return bugs


# ============================================================================
# MODE: asmoob - EXECUTE hand-written asm in a guard-page sandbox and catch
#               real out-of-bounds reads/writes (not a grep - actual emulation).
#
# Idea: place the routine's destination buffer flush against an UNMAPPED guard
# page, point the pointer register at it, then sweep the count/index register
# (incl. attacker-style huge / negative values). If the routine writes or reads
# N bytes governed by a register it never clamps to the buffer size, the access
# crosses the guard page and Unicorn faults on the EXACT instruction - which we
# disassemble and report, along with the input that triggered it. Underflow
# (access below the buffer base, still inside its own page) is caught by a
# byte-level read/write hook. Either way we get a concrete OOB witness.
#
# Kernel .inc files are not standalone-assemblable, so we slice a routine from
# its label and auto-stub every constant/label nasm reports undefined (pointing
# them into a mapped scratch page). Targets whose body uses kernel *macros* are
# reported as skipped (can't auto-stub a macro) rather than silently passed.
# ============================================================================
REG_BY_NAME = {
    'rax': UC_X86_REG_RAX, 'rbx': UC_X86_REG_RBX, 'rcx': UC_X86_REG_RCX,
    'rdx': UC_X86_REG_RDX, 'rsi': UC_X86_REG_RSI, 'rdi': UC_X86_REG_RDI,
    'rbp': UC_X86_REG_RBP, 'r8': UC_X86_REG_R8, 'r9': UC_X86_REG_R9,
    'r10': UC_X86_REG_R10, 'r11': UC_X86_REG_R11, 'r12': UC_X86_REG_R12,
    'r13': UC_X86_REG_R13, 'r14': UC_X86_REG_R14, 'r15': UC_X86_REG_R15,
}

_SCRATCH = 0x300000          # mapped, R/W: every auto-stubbed symbol points here
_SCRATCH_SZ = 0x40000
_GUARD_PAGE = 0x1000


def extract_routine(path, label):
    """Slice `label:` .. (next column-0 label / EOF) out of a .inc/.asm file.
    Returns the body text, or None if the label isn't found."""
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    start = None
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s == label + ':' or s.startswith(label + ':'):
            start = i
            break
    if start is None:
        return None
    out = [lines[start]]
    for ln in lines[start + 1:]:
        s = ln.lstrip()
        # stop at the next top-level (non-dotted) label definition
        if ln[:1] not in (' ', '\t', ';', '') and ':' in s.split(';', 1)[0] \
                and not s.startswith('.') and not s.startswith(label):
            break
        out.append(ln)
    return '\n'.join(out)


_UNDEF_RES = [
    re.compile(r"symbol `([A-Za-z_.$][\w.$]*)' (?:undefined|not defined)"),
    re.compile(r"undefined symbol `([A-Za-z_.$][\w.$]*)'"),
]


def stub_assemble(body, prefix, max_iters=200):
    """Assemble a sliced routine, auto-stubbing undefined symbols into scratch.
    Returns (code_bytes, stubbed_set) or raises AssembleError (e.g. on macros)."""
    os.makedirs(TMP_DIR, exist_ok=True)
    apath = os.path.join(TMP_DIR, prefix + '_oob.asm')
    bpath = os.path.join(TMP_DIR, prefix + '_oob.bin')
    stubbed = {}
    for _ in range(max_iters):
        defs = ''.join('%%define %s 0x%x\n' % (name, addr)
                       for name, addr in stubbed.items())
        wrap = ("bits 64\ndefault rel\nsection .text\n" + defs +
                "__oob_entry:\n" + body + "\n    ret\n")
        with open(apath, 'w', encoding='utf-8') as f:
            f.write(wrap)
        r = subprocess.run([NASM, '-f', 'bin', '-o', bpath, apath],
                           capture_output=True, text=True)
        if r.returncode == 0:
            with open(bpath, 'rb') as f:
                return f.read(), set(stubbed)
        # harvest every freshly-undefined symbol from this pass
        new = False
        for line in r.stderr.splitlines():
            for rx in _UNDEF_RES:
                m = rx.search(line)
                if m and m.group(1) not in stubbed:
                    # spread stubs across scratch so distinct symbols differ
                    stubbed[m.group(1)] = _SCRATCH + 0x800 + 0x40 * len(stubbed)
                    new = True
        if not new:
            raise AssembleError(r.stderr.strip().splitlines()[-1]
                                if r.stderr.strip() else 'nasm failed')
    raise AssembleError('stub fixpoint not reached')


# ----------------------------------------------------------------------------
# Structured input generators. Random register sweeps never build the valid-ish
# STRUCTURE a parser walks into (a HID item header, a dir entry, a TLV length),
# so they can't reach the deep OOBs. These emit almost-valid structured bytes
# with a fuzzed corruption (a length that lies, an unterminated nesting, a count
# that runs past the buffer) - exactly the shape that trips a missing bound.
# ----------------------------------------------------------------------------
def gen_random(rng, n):
    return bytes(rng.randrange(256) for _ in range(n))


def gen_hid(rng, n):
    """HID report-descriptor-ish item stream: <prefix><data...>. Prefix low 2
    bits = data length; we sometimes claim a length that overruns the buffer."""
    out = bytearray()
    tags = [0x05, 0x09, 0x15, 0x25, 0x75, 0x95, 0x81, 0xa1, 0xc0]
    while len(out) < n:
        if rng.random() < 0.15:                  # lie: long-form item near the end
            out.append(0xfe); out.append(0xff)   # claims a huge following length
            break
        sz = rng.choice([0, 1, 2, 3])
        out.append(rng.choice(tags) | sz)
        out += gen_random(rng, sz if sz != 3 else 4)
    return bytes(out[:n]) if len(out) >= n else bytes(out) + b'\x00' * (n - len(out))


def gen_fat16_dirent(rng, n):
    """32-byte FAT16 directory entries; some with attr/size/cluster edge values."""
    out = bytearray()
    while len(out) + 32 <= n:
        name = bytes(rng.choice(b'ABCDEFGHIJK0123 ~') for _ in range(11))
        attr = rng.choice([0x00, 0x0f, 0x10, 0x20, 0xff])   # 0x0f = LFN
        ent = bytearray(name) + bytes([attr]) + gen_random(rng, 8)
        ent += rng.choice([0, 0xffff, rng.randrange(0x10000)]).to_bytes(2, 'little')  # cluster
        ent += rng.choice([0, 0xffffffff, rng.randrange(1 << 32)]).to_bytes(4, 'little')  # size
        out += ent[:32]
    return bytes(out[:n]).ljust(n, b'\x00')


def gen_tlv(rng, n):
    """type/len/value packets where len frequently exceeds what remains."""
    out = bytearray()
    while len(out) + 2 < n:
        out.append(rng.randrange(256))                       # type
        claimed = rng.choice([0, 1, 255, rng.randrange(256)])
        out.append(claimed)                                  # length (may lie)
        out += gen_random(rng, min(claimed, rng.randrange(4)))
    return bytes(out[:n]).ljust(n, b'\x00')


GENERATORS = {'random': gen_random, 'hid': gen_hid,
              'fat16': gen_fat16_dirent, 'tlv': gen_tlv}


def _norm_buffers(spec):
    """Accept both the terse {reg:size} form and the rich
    {reg:{size,role,gen}} form; return a list of normalized buffer dicts."""
    out = []
    for reg, v in spec['buffers'].items():
        if isinstance(v, dict):
            out.append(dict(reg=reg, size=v['size'],
                            role=v.get('role', 'out'), gen=v.get('gen', 'random')))
        else:
            out.append(dict(reg=reg, size=v, role='out', gen='random'))
    return out


# ----------------------------------------------------------------------------
# The sandbox: maps each buffer flush against an unmapped guard page and runs the
# routine under THREE oracles, each producing a concrete instruction-level
# witness:
#   * overflow / underflow - read or write outside a buffer's [base,base+size).
#   * uninitialized-read    - read of an output byte the routine never wrote
#                             (shadow-memory / MSAN-lite; info-leak class).
#   * wild                  - access to memory in no declared region at all
#                             (only counted when faulting RIP is in the routine,
#                             else it's 'unmodeled': addresses its own globals).
# ----------------------------------------------------------------------------
def sandbox_run(code, spec, seed_regs, contents, size_override=None,
                insn_budget=200000):
    mu = Uc(UC_ARCH_X86, UC_MODE_64)
    base = 0x100000
    cap = max((len(code) + 0xFFF) & ~0xFFF, 0x10000)
    code_lo, code_hi = base, base + len(code)
    mu.mem_map(base, cap)
    mu.mem_write(base, code)
    mu.mem_map(0x800000, 0x100000)                       # stack
    mu.mem_map(_SCRATCH, _SCRATCH_SZ)                    # stubbed globals (R/W)
    sp = 0x800000 + 0x100000 - 0x1000
    mu.mem_write(sp, _RET.to_bytes(8, 'little'))
    mu.reg_write(UC_X86_REG_RSP, sp)

    size_override = size_override or {}
    bufs = []          # dicts: reg, lo, hi, page, role, init(set of written offs)
    bregion = 0x500000
    for b in _norm_buffers(spec):
        sz = size_override.get(b['reg'], b['size'])
        page = bregion
        mu.mem_map(page, _GUARD_PAGE)                    # guard page above NOT mapped
        lo = page + _GUARD_PAGE - sz                     # buffer ends at page end
        if b['role'] == 'in':                            # prefill input buffers
            mu.mem_write(lo, contents.get(b['reg'], b'\x00' * sz)[:sz])
        bufs.append(dict(reg=b['reg'], lo=lo, hi=lo + sz, page=page,
                         role=b['role'], init=set()))
        mu.reg_write(REG_BY_NAME[b['reg']], lo)
        bregion += 0x10000
    for reg, val in seed_regs.items():
        mu.reg_write(REG_BY_NAME[reg], val & M)

    hit = {}

    def find_buf(addr):
        for b in bufs:
            if b['page'] <= addr < b['page'] + _GUARD_PAGE:
                return b
        return None

    def on_read(uc, t, addr, sz, val, ud):
        if hit:
            return
        b = find_buf(addr)
        if b is None:
            return
        if addr < b['lo']:
            hit.update(kind='read-underflow', addr=addr, sz=sz, buf=b['reg'],
                       rip=uc.reg_read(UC_X86_REG_RIP)); uc.emu_stop(); return
        # uninitialized-read oracle: output byte read before written
        if b['role'] == 'out':
            for o in range(addr - b['lo'], addr - b['lo'] + sz):
                if o not in b['init']:
                    hit.update(kind='uninit-read', addr=addr, sz=sz, buf=b['reg'],
                               rip=uc.reg_read(UC_X86_REG_RIP)); uc.emu_stop(); return

    def on_write(uc, t, addr, sz, val, ud):
        if hit:
            return
        b = find_buf(addr)
        if b is None:
            return
        if addr < b['lo']:
            hit.update(kind='write-underflow', addr=addr, sz=sz, buf=b['reg'],
                       rip=uc.reg_read(UC_X86_REG_RIP)); uc.emu_stop(); return
        for o in range(addr - b['lo'], addr - b['lo'] + sz):
            b['init'].add(o)
    mu.hook_add(UC_HOOK_MEM_READ, on_read)
    mu.hook_add(UC_HOOK_MEM_WRITE, on_write)

    def on_unmapped(uc, t, addr, sz, val, ud):
        for b in bufs:
            if b['hi'] <= addr < b['page'] + 4 * _GUARD_PAGE:
                if not hit:
                    hit.update(kind='overflow', addr=addr, sz=sz, buf=b['reg'],
                               over=addr - b['hi'], rip=uc.reg_read(UC_X86_REG_RIP))
                return False
        if not hit:
            hit.update(kind='wild', addr=addr, sz=sz,
                       rip=uc.reg_read(UC_X86_REG_RIP))
        return False
    mu.hook_add(UC_HOOK_MEM_UNMAPPED, on_unmapped)

    try:
        mu.emu_start(base, _RET, count=insn_budget)
    except UcError:
        pass
    if not hit:
        return None
    real = ('overflow', 'underflow', 'read-underflow', 'write-underflow',
            'uninit-read')
    if hit['kind'] in real and code_lo <= hit['rip'] < code_hi:
        hit['insn'] = _disasm_at(mu, hit['rip'])
        return hit
    return {'unmodeled': True, 'kind': hit['kind'], 'rip': hit['rip']}


# A built-in self-test proves the detector fires; the rest are discovered.
_SELFTEST_ASM = (
    "    test rcx, rcx\n"
    ".lp:\n"
    "    jz .done\n"
    "    mov byte [rdi], 0x41\n"        # write WITHOUT comparing to a buffer limit
    "    inc rdi\n"
    "    dec rcx\n"
    "    jmp .lp\n"
    ".done:\n"
)

ASMOOB_TARGETS = [
    dict(name='SELFTEST_unclamped_memset', selftest=True,
         buffers={'rdi': 32}, sweep_regs=['rcx'], contract='count_clamp',
         note='deliberately-buggy fill: writes rcx bytes, never clamps to 32'),

    # --- real routines with HAND-VERIFIED input contracts (findings = PROVEN) ---
    # HID report descriptor parser: RSI = descriptor, RCX = its length. The
    # parser sets rbp=rsi+rcx and bounds every read against it (confirmed by
    # reading the asm), so this should come back CLEAN - a true negative on real
    # code, and the template for declaring a (ptr,len) contract.
    dict(name='hid_parser_parse.inc::hid_parse_report_desc_v2',
         file=os.path.join(ROOT, 'src', 'kernel', 'drivers', 'hid_parser_parse.inc'),
         label='hid_parse_report_desc_v2', contract='ptr_len',
         buffers={'rsi': dict(size=64, role='in', gen='hid')},
         sweep_regs=['rcx']),
    # Boot-keyboard report parser: RSI = a FIXED 8-byte report, no length reg.
    # Reads modifier + 6 keycodes; if it ever touched rsi+8 we'd catch it.
    dict(name='usb_hid_data.inc::usb_parse_keyboard_report',
         file=os.path.join(ROOT, 'src', 'kernel', 'drivers', 'usb_hid_data.inc'),
         label='usb_parse_keyboard_report', contract='in_string',
         buffers={'rsi': dict(size=8, role='in', gen='random')},
         sweep_regs=[]),
]


def _sweep_values(rng, size):
    """Counts the routine is TOLD to process - may legally exceed the buffer
    (the 'count_clamp' contract: routine must clamp to its fixed buffer)."""
    base = [0, 1, size - 1, size, size + 1, size + 8, size * 2, size * 16,
            0x1000, 0x10000, M, M - 1, 1 << 63]
    base += [rng.randint(0, size * 4) for _ in range(8)]
    return base


def _sweep_lengths(rng, cap=256):
    """Coupled buffer lengths to try: every small value, every power-of-two and
    its off-by-one neighbours up to cap, plus a few randoms. Bugs cluster at
    these boundaries, so we don't need a linear 0..cap scan."""
    vals = set(range(0, 17))                       # all tiny lengths
    p = 8
    while p <= cap:
        vals.update((p - 1, p, p + 1))
        p *= 2
    vals.update(rng.randint(0, cap) for _ in range(12))
    return sorted(v for v in vals if 0 <= v <= cap)


# Heuristic discovery: classify a sliced routine's input surface from how it
# touches argument registers, so it leaves 'unmodeled' and becomes testable.
_MEM_RX = re.compile(r'\[\s*(rdi|rsi|rbx|rdx|r8|r9)\b', re.I)
_RDREG_RX = re.compile(r'\b(?:mov|movzx|movsx|cmp|add|lea|test)\b[^;,\[]*\[\s*(rsi|rdx|r8)\b', re.I)
_LEN_REGS = ['rcx', 'rdx', 'r8', 'esi', 'edx']


def _spec_from_body(name, path, label, body):
    """Build a buffer/sweep spec from how the routine addresses memory."""
    mem_regs = set(m.lower() for m in _MEM_RX.findall(body))
    if not mem_regs:
        return None
    buffers = {}
    for r in mem_regs:
        # From a slice we cannot prove a buffer is an output the routine is
        # contractually obliged to fill, so we never auto-assume 'out' (that
        # would make the uninit-read oracle fire on legit input reads). Every
        # discovered buffer is an INPUT, prefilled with structured content; the
        # uninit-read oracle is reserved for hand-declared role='out' specs.
        gen = ('hid' if 'hid' in name.lower() else
               'fat16' if 'fat' in name.lower() or 'dir' in name.lower() else
               'tlv' if any(k in name.lower() for k in ('parse', 'tlv', 'pkt', 'arp', 'dhcp')) else
               'random')
        buffers[r] = dict(size=64, role='in', gen=gen)
    sweep = [r for r in ('rcx', 'rdx', 'r8') if r not in mem_regs] or ['rcx']
    return dict(name=name, file=path, label=label, buffers=buffers,
                sweep_regs=sweep[:2], discovered=True)


def _discover_targets(rng, max_targets):
    import glob
    label_rx = re.compile(r'^([A-Za-z_][\w]*):')
    seen = set()
    out = []
    for path in sorted(glob.glob(os.path.join(ROOT, 'src', '**', '*.inc'),
                                 recursive=True)):
        lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
        # collect (label, body) for every top-level routine that touches memory
        cur, body = None, []
        for ln in lines + ['__eof__:']:
            m = label_rx.match(ln)
            if m:
                if cur and any(_MEM_RX.search(b) for b in body):
                    nm = '%s::%s' % (os.path.basename(path), cur)
                    if nm not in seen:
                        sp = _spec_from_body(nm, path, cur, '\n'.join(body))
                        if sp:
                            out.append(sp); seen.add(nm)
                cur, body = m.group(1), []
            elif cur:
                body.append(ln)
            if len(out) >= max_targets:
                return out
    return out


def mode_asmoob(args):
    rng = random.Random(args.seed)
    bugs = 0
    targets = list(ASMOOB_TARGETS)
    if not args.selftest_only:
        hand = {t['name'] for t in ASMOOB_TARGETS}
        disc = [d for d in _discover_targets(rng, args.max_targets)
                if d['name'] not in hand]
        targets += disc
        print("[asmoob] %d discovered candidate routine(s) + %d built-in\n"
              % (len(disc), len(ASMOOB_TARGETS)))

    stats = dict(oob=0, cand=0, clean=0, unmodeled=0, skip=0)
    for t in targets:
        try:
            if t.get('selftest'):
                code, _ = stub_assemble(_SELFTEST_ASM, 'selftest')
            else:
                body = extract_routine(t['file'], t['label'])
                if body is None:
                    print("[asmoob] SKIP %-44s (label not found)" % t['name'])
                    stats['skip'] += 1
                    continue
                code, _ = stub_assemble(body, re.sub(r'\W', '_', t['name']))
        except AssembleError as e:
            print("[asmoob] SKIP %-44s (not standalone: %s)"
                  % (t['name'], str(e)[:42]))
            stats['skip'] += 1
            continue

        bspecs = _norm_buffers(t)
        size = bspecs[0]['size']
        sweeps = t.get('sweep_regs', ['rcx'])
        # The input contract decides the memory model. We can only PROVE a bug
        # when the contract is known (hand-declared / self-test); a discovered
        # routine's contract is GUESSED, so its findings are reported as
        # candidates to verify, never as proven. Three contracts:
        #   count_clamp: fixed output buffer + a count the routine must clamp to
        #                it; we sweep the count BEYOND the buffer - an overflow
        #                means the routine failed to clamp (the classic bug).
        #   in_string  : NUL-terminated input in a generously-sized buffer with
        #                the terminator placed well within bounds; a correct
        #                scanner stops at it, so any overflow is a genuine
        #                read-past-terminator/buffer - not us starving the buffer.
        #   ptr_len    : buffer size == a length register (coupled); overflow
        #                means reading past the length actually given.
        contract = t.get('contract',
                         'count_clamp' if not t.get('discovered') else 'in_string')
        proven = not t.get('discovered')
        found = None
        unmodeled = False

        def run_trial(seed, contents, sizeov):
            try:
                return sandbox_run(code, t, seed, contents, size_override=sizeov)
            except Exception:
                return None

        if contract == 'count_clamp':
            for v in _sweep_values(rng, size):
                contents, sizeov = {}, {}
                for b in bspecs:
                    sizeov[b['reg']] = b['size']
                    if b['role'] == 'in':
                        g = GENERATORS.get(b['gen'], gen_random)
                        data = bytearray(g(rng, b['size']))
                        if not args.adversarial and b['size']:
                            data[-1] = 0
                        contents[b['reg']] = bytes(data)
                r = run_trial({sr: v for sr in sweeps}, contents, sizeov)
                if r and r.get('unmodeled'):
                    unmodeled = True; break
                if r:
                    found = (v, r); break
        elif contract == 'ptr_len':
            for v in _sweep_lengths(rng):
                for _ in range(4):
                    contents, sizeov = {}, {}
                    for b in bspecs:
                        sz = v if b['role'] == 'in' else b['size']
                        sizeov[b['reg']] = sz
                        if b['role'] == 'in':
                            g = GENERATORS.get(b['gen'], gen_random)
                            data = bytearray(g(rng, sz))
                            if not args.adversarial and sz:
                                data[-1] = 0
                            contents[b['reg']] = bytes(data)
                    r = run_trial({sr: v for sr in sweeps}, contents, sizeov)
                    if r and r.get('unmodeled'):
                        unmodeled = True; break
                    if r:
                        found = (v, r); break
                if found or unmodeled:
                    break
        else:  # in_string: generous fixed buffer, terminator placed early
            for _ in range(40):
                contents, sizeov = {}, {}
                for b in bspecs:
                    sizeov[b['reg']] = b['size']
                    if b['role'] == 'in':
                        g = GENERATORS.get(b['gen'], gen_random)
                        data = bytearray(g(rng, b['size']))
                        if not args.adversarial:
                            # terminator in the first half => a correct scanner
                            # stops far from the guard page.
                            data[rng.randint(1, max(1, b['size'] // 2))] = 0
                        contents[b['reg']] = bytes(data)
                # length regs (if any) bounded by what we actually provided
                r = run_trial({sr: b['size'] for sr in sweeps}, contents, sizeov)
                if r and r.get('unmodeled'):
                    unmodeled = True; break
                if r:
                    found = (b['size'], r); break
        if found:
            v, r = found
            tag = 'PROVEN' if proven else 'CANDID'
            stats['oob' if proven else 'cand'] += 1
            if proven:
                bugs += 1
            print("[asmoob] *** %-6s %-10s %s"
                  % (tag, r['kind'].upper(), t['name']))
            print("           contract=%s  buf=%s  sweep %s=0x%x"
                  % (contract, r.get('buf', '?'), '/'.join(sweeps), v))
            print("           faulting insn @0x%x: %s  (access 0x%x%s)"
                  % (r['rip'], r.get('insn', '?'), r['addr'],
                     (', +%d past end' % r['over']) if 'over' in r else ''))
            if t.get('note'):
                print("           note: %s" % t['note'])
        elif unmodeled:
            stats['unmodeled'] += 1
        else:
            stats['clean'] += 1

    print("\n[asmoob] PROVEN OOB/uninit: %d   candidates(verify contract): %d"
          % (stats['oob'], stats['cand']))
    print("[asmoob] clean: %d   unmodeled: %d   not-standalone: %d"
          % (stats['clean'], stats['unmodeled'], stats['skip']))
    print("[asmoob] PROVEN = contract hand-declared in ASMOOB_TARGETS; CANDIDATE ="
          "\n          contract guessed by discovery - read the routine to confirm"
          " the\n          input contract before treating it as a real bug.")
    return bugs


# ============================================================================
# MODE: rawasm - static overflow audit of hand-written asm
# ============================================================================
def mode_rawasm(args):
    import glob
    import re
    findings = 0
    pats = [
        ('unbounded rep', re.compile(r'^\s*rep[a-z]*\s+(movs|stos|cmps|scas)', re.I)),
        ('raw rsp growth', re.compile(r'^\s*sub\s+rsp\s*,\s*(0x[0-9a-f]{4,}|\d{4,})', re.I)),
        ('loop w/o cmp guard', re.compile(r'^\s*loop\b', re.I)),
        ('add to ptr no clamp', re.compile(r'^\s*add\s+(rdi|rsi|rbx|rbp)\s*,\s*r', re.I)),
        ('jmp rax/reg (indirect)', re.compile(r'^\s*jmp\s+r[a-z0-9]+\s*$', re.I)),
    ]
    files = []
    for ext in ('*.asm', '*.inc'):
        files += glob.glob(os.path.join(ROOT, 'src', '**', ext), recursive=True)
    for path in sorted(files):
        rel = os.path.relpath(path, ROOT)
        try:
            lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
        except OSError:
            continue
        for ln, line in enumerate(lines, 1):
            code = line.split(';', 1)[0]
            for label, pat in pats:
                if pat.search(code):
                    print("[rawasm] %-12s %s:%d  %s" % (label, rel, ln, code.strip()[:70]))
                    findings += 1
    print("\n[rawasm] %d pattern hit(s) to review (heuristic; not all are bugs)." % findings)
    return 0


def main():
    ap = argparse.ArgumentParser(description="GHL compiler/codegen differential fuzzer + asm simulator")
    ap.add_argument('--mode', choices=['fuzz', 'robust', 'modules', 'rawasm', 'asmoob'], default='fuzz')
    ap.add_argument('--iters', type=int, default=500)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--selftest-only', action='store_true',
                    help='asmoob: run only the built-in self-test target')
    ap.add_argument('--max-targets', type=int, default=40,
                    help='asmoob: cap on auto-discovered routines')
    ap.add_argument('--adversarial', action='store_true',
                    help='asmoob: drop string terminators / use hostile input '
                         '(separate lower-confidence "no length bound" pass)')
    args = ap.parse_args()

    if args.mode in ('fuzz',):
        calibrate()
    fn = {'fuzz': mode_fuzz, 'robust': mode_robust,
          'modules': mode_modules, 'rawasm': mode_rawasm,
          'asmoob': mode_asmoob}[args.mode]
    bugs = fn(args)
    sys.exit(1 if bugs else 0)


if __name__ == '__main__':
    main()
