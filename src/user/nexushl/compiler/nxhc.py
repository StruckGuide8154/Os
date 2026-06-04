#!/usr/bin/env python3
# NexusHL compiler (nxhc) — translates .nxh -> NASM .asm
# Host-side only. Zero runtime. Every memory access goes through typed
# accessors; every kernel call goes through a named syscall wrapper. No raw
# register access unless the caller writes an `asm { ... }` escape block.
#
# Pipeline: lex -> parse -> sema -> emit. One file, no deps.

import os, re, sys, json

KEYWORDS = {
    "use","app","module","fn","let","if","else","while","for","return",
    "str","i8","i16","i32","i64","u8","u16","u32","u64","ptr","void","bool",
    "true","false","asm","syscall","extern","const","struct","state","break","continue",
    "global",
    # Kernel-mode explicit-register ABI:
    #   preserves(...) — callee-save contract (see gen_kernel_fn)
    #   call           — register-annotated call statement `call f(al: x);`
    "preserves","call"
}

# ---------------------------------------------------------------------------
# Kernel-mode explicit-register ABI register table.
#
# Maps every legal GP register spelling to (canonical 64-bit name, width in
# bits). Used by the kernel `fn name(REG param, ...)` syntax, by `preserves(...)`
# (which always operates on the full 64-bit register regardless of the spelling
# the body uses), and by register-annotated calls `call f(REG: expr, ...)`.
#
# A named register parameter is a *physical-register binding*: inside the body
# the parameter name reads/writes that register at the declared width via the
# normal expression machinery (mov/movzx into rax on read; sized mov out of rax
# on write). This is the minimal mechanism that lets hand-rolled kernel leaf
# routines (arg in al/eax/rsi, all registers preserved) be written structurally
# without dropping to `asm{}`.
# ---------------------------------------------------------------------------
def _build_reg_table():
    t={}
    # base name -> (q,d,w,b)  64/32/16/8 spellings
    rows=[
        ("rax","eax","ax","al"),
        ("rbx","ebx","bx","bl"),
        ("rcx","ecx","cx","cl"),
        ("rdx","edx","dx","dl"),
        ("rsi","esi","si","sil"),
        ("rdi","edi","di","dil"),
        ("rbp","ebp","bp","bpl"),
        ("rsp","esp","sp","spl"),
    ]
    for q,d,w,b in rows:
        t[q]=(q,64); t[d]=(q,32); t[w]=(q,16); t[b]=(q,8)
    for n in range(8,16):
        q=f"r{n}"; t[q]=(q,64); t[f"r{n}d"]=(q,32); t[f"r{n}w"]=(q,16); t[f"r{n}b"]=(q,8)
    return t

REG_TABLE=_build_reg_table()

def _reg_at_width(canon, bits):
    # Return the register spelling for canonical 64-bit reg `canon` at `bits`.
    for spell,(c,w) in REG_TABLE.items():
        if c==canon and w==bits:
            return spell
    raise SyntaxError(f"no {bits}-bit spelling for {canon}")

TOK_RE = re.compile(r"""
    (?P<ws>\s+)
  | (?P<cmt>\#[^\n]*)
  | (?P<str>"(?:\\.|[^"\\])*")
  | (?P<hex>0x[0-9a-fA-F]+)
  | (?P<num>\d+)
  | (?P<id>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>==|!=|<=|>=|&&|\|\||<<|>>|[+\-*/%=&|^<>!{}()\[\],;:.])
""", re.X)

class Tok:
    __slots__=("k","v","line","col")
    def __init__(s,k,v,line,col): s.k,s.v,s.line,s.col=k,v,line,col
    def __repr__(s): return f"<{s.k}:{s.v!r}@{s.line}:{s.col}>"

def lex(src, path):
    out=[]; i=0; line=1; col=1
    while i<len(src):
        m=TOK_RE.match(src,i)
        if not m: raise SyntaxError(f"{path}:{line}:{col}: bad char {src[i]!r}")
        g=m.lastgroup; v=m.group()
        if g=="ws":
            nl=v.count("\n")
            if nl: line+=nl; col=len(v)-v.rfind("\n")
            else: col+=len(v)
        elif g=="cmt":
            col+=len(v)
        else:
            if g=="id" and v in KEYWORDS:
                out.append(Tok(v,v,line,col))
            elif g=="str":
                # Process common escape sequences inside string literals.
                # NASM's own double-quoted strings don't process escapes, so
                # this is the only place a NexusHL author can spell a quote,
                # a backslash, or a control character.
                raw=v[1:-1]
                buf=[]; j=0
                while j<len(raw):
                    ch=raw[j]
                    if ch=='\\' and j+1<len(raw):
                        nx=raw[j+1]
                        if nx=='n': buf.append('\n')
                        elif nx=='t': buf.append('\t')
                        elif nx=='r': buf.append('\r')
                        elif nx=='0': buf.append('\x00')
                        elif nx=='\\': buf.append('\\')
                        elif nx=='"': buf.append('"')
                        elif nx=="'": buf.append("'")
                        else: buf.append(nx)
                        j+=2
                    else:
                        buf.append(ch); j+=1
                out.append(Tok("str","".join(buf),line,col))
            elif g=="hex":
                out.append(Tok("num",int(v,16),line,col))
            elif g=="num":
                out.append(Tok("num",int(v),line,col))
            elif g=="id":
                out.append(Tok("id",v,line,col))
            else:
                out.append(Tok(v,v,line,col))
            col+=len(v)
        i=m.end()
    out.append(Tok("eof","",line,col))
    return out

class P:
    def __init__(s,toks,path): s.t=toks; s.i=0; s.path=path
    def peek(s,k=0): return s.t[s.i+k]
    def eat(s,kind=None,val=None):
        x=s.t[s.i]
        if kind and x.k!=kind: s.err(f"expected {kind}, got {x.k}({x.v!r})")
        if val is not None and x.v!=val: s.err(f"expected {val!r}, got {x.v!r}")
        s.i+=1; return x
    def match(s,kind,val=None):
        x=s.t[s.i]
        if x.k!=kind: return False
        if val is not None and x.v!=val: return False
        s.i+=1; return True
    def err(s,msg):
        x=s.t[s.i]
        raise SyntaxError(f"{s.path}:{x.line}:{x.col}: {msg}")

# AST
def node(k,**kw): kw["k"]=k; return kw

def parse(toks,path):
    p=P(toks,path)
    decls=[]
    while p.peek().k!="eof":
        t=p.peek()
        if t.v=="use":
            p.eat(); name=p.eat("id").v
            while p.match(".",):
                name+="."+p.eat("id").v
            p.match(";")
            decls.append(node("use",name=name))
        elif t.v=="app":
            p.eat(); nm=p.eat("str").v
            stack=4096
            if p.match("{"):
                while not p.match("}"):
                    k=p.eat("id").v; p.eat("="); v=p.eat("num").v; p.match(";")
                    if k=="stack": stack=v
            decls.append(node("app",name=nm,stack=stack))
        elif t.v=="str":
            p.eat(); nm=p.eat("id").v; p.eat("="); val=p.eat("str").v; p.match(";")
            decls.append(node("strdef",name=nm,val=val))
        elif t.v=="const":
            p.eat(); nm=p.eat("id").v; p.eat("=")
            neg=False
            if p.peek().k=="-": p.eat(); neg=True
            v=p.eat("num").v
            if neg: v = -v
            p.match(";")
            decls.append(node("const",name=nm,val=v))
        elif t.v=="module":
            # Kernel-mode unit marker: `module "name";`. Names the translation
            # unit for the generated-file banner. Presence does NOT itself switch
            # codegen — the --target kernel flag does — but it documents intent
            # and is rejected by the user-mode path so a kernel module can't be
            # compiled as an app by accident.
            p.eat(); nm=p.eat("str").v; p.match(";")
            decls.append(node("module",name=nm))
        elif t.v=="global":
            # Kernel-mode: export a symbol so other kernel modules / main.asm
            # can reference it. `global name;` — emits `global name` ahead of
            # the label. Ignored (with a clear error) in user mode.
            p.eat(); nm=p.eat("id").v; p.match(";")
            decls.append(node("global",name=nm))
        elif t.v=="extern":
            p.eat(); nm=p.eat("id").v; p.match(";")
            decls.append(node("extern",name=nm))
        elif t.v=="state":
            p.eat(); p.eat("{")
            fields=[]
            while not p.match("}"):
                nm=p.eat("id").v
                if p.match(":") or p.match("="):
                    sz=p.eat("num").v
                else:
                    p.err("state field needs ': <byte_count>'")
                p.match(";")
                fields.append((nm,sz))
            decls.append(node("state",fields=fields))
        elif t.v=="fn":
            decls.append(parse_fn(p))
        else:
            p.err(f"unexpected top-level {t.v!r}")
    return decls

def parse_fn(p):
    p.eat("fn"); name=p.eat("id").v
    p.eat("(")
    params=[]      # plain param names (user-mode / System-V kernel fns)
    regparams=[]   # list of (regname, paramname) for explicit-register kernel fns
    if not p.match(")"):
        while True:
            first=p.eat("id").v
            # Explicit-register param: `REG name` (two adjacent identifiers,
            # the first a known GP register spelling). Kernel-mode only; the
            # sema/codegen rejects it in user mode.
            if p.peek().k=="id" and first in REG_TABLE:
                pn=p.eat("id").v
                regparams.append((first,pn))
            else:
                params.append(first)
            if p.match(")"): break
            p.eat(",")
    # Optional register-preservation contract: `preserves(all)` or
    # `preserves(rbx, rsi, ...)`. Kernel-mode only.
    preserves=None
    if p.peek().v=="preserves":
        p.eat(); p.eat("(")
        plist=[]
        while True:
            r=p.eat("id").v
            plist.append(r)
            if p.match(")"): break
            p.eat(",")
        preserves=plist
    body=parse_block(p)
    return node("fn",name=name,params=params,regparams=regparams,
                preserves=preserves,body=body)

def parse_block(p):
    p.eat("{")
    stmts=[]
    while not p.match("}"):
        stmts.append(parse_stmt(p))
    return stmts

def parse_stmt(p):
    t=p.peek()
    if t.v=="let":
        p.eat(); nm=p.eat("id").v; p.eat("="); e=parse_expr(p); p.match(";")
        return node("let",name=nm,expr=e)
    if t.v=="return":
        p.eat()
        e=None
        if p.peek().k!=";" and p.peek().k!="}":
            e=parse_expr(p)
        p.match(";")
        return node("return",expr=e)
    if t.v=="if":
        p.eat(); cond=parse_expr(p); thn=parse_block(p); els=None
        if p.match("else",):
            if p.peek().v=="if":
                els=[parse_stmt(p)]
            else:
                els=parse_block(p)
        return node("if",cond=cond,then=thn,els=els)
    if t.v=="while":
        p.eat(); cond=parse_expr(p); body=parse_block(p)
        return node("while",cond=cond,body=body)
    if t.v=="break":
        p.eat(); p.match(";"); return node("break")
    if t.v=="continue":
        p.eat(); p.match(";"); return node("continue")
    if t.v=="asm":
        p.eat(); s=p.eat("str").v; p.match(";")
        return node("asm",text=s)
    if t.v=="call":
        # Register-annotated call (kernel-mode): load the named registers from
        # the given expressions, then `call target`. The target uses a custom
        # (non-System-V) register ABI, so we name each input register explicitly:
        #     call svg_dump_nibble(al: nib);
        #     call f();                       # bare call, no register setup
        p.eat(); tgt=p.eat("id").v; p.eat("(")
        regargs=[]   # list of (regname, expr)
        if not p.match(")"):
            while True:
                r=p.eat("id").v; p.eat(":"); e=parse_expr(p)
                regargs.append((r,e))
                if p.match(")"): break
                p.eat(",")
        p.match(";")
        return node("regcall",target=tgt,regargs=regargs)
    # expr-stmt or assign
    e=parse_expr(p)
    if p.match("="):
        rhs=parse_expr(p); p.match(";")
        return node("assign",lhs=e,rhs=rhs)
    p.match(";")
    return node("exprstmt",expr=e)

PREC={"||":1,"&&":2,"==":3,"!=":3,"<":4,">":4,"<=":4,">=":4,
      "+":5,"-":5,"|":5,"^":5,"*":6,"/":6,"%":6,"&":6,"<<":6,">>":6}

def parse_expr(p): return parse_binop(p,0)

def parse_binop(p,minp):
    lhs=parse_unary(p)
    while True:
        t=p.peek()
        op=t.v if t.k in ("==","!=","<=",">=","&&","||","<<",">>","+","-","*","/","%","&","|","^","<",">") else None
        if op is None or op not in PREC or PREC[op]<minp: break
        p.eat()
        rhs=parse_binop(p,PREC[op]+1)
        lhs=node("bin",op=op,lhs=lhs,rhs=rhs)
    return lhs

def parse_unary(p):
    t=p.peek()
    if t.v=="-":
        p.eat(); e=parse_unary(p); return node("neg",expr=e)
    if t.v=="!":
        p.eat(); e=parse_unary(p); return node("not",expr=e)
    if t.v=="&":
        p.eat(); nm=p.eat("id").v; return node("addr",name=nm)
    return parse_postfix(p)

def parse_postfix(p):
    e=parse_primary(p)
    while True:
        if p.match("("):
            args=[]
            if not p.match(")"):
                while True:
                    args.append(parse_expr(p))
                    if p.match(")"): break
                    p.eat(",")
            if e.get("k")=="ident":
                e=node("call",name=e["name"],args=args)
            else:
                p.err("callable must be identifier")
        elif p.match("["):
            idx=parse_expr(p); p.eat("]")
            e=node("index",target=e,idx=idx)
        else:
            break
    return e

def parse_primary(p):
    t=p.peek()
    if t.k=="num":
        p.eat(); return node("int",val=t.v)
    if t.v=="true":
        p.eat(); return node("int",val=1)
    if t.v=="false":
        p.eat(); return node("int",val=0)
    if t.k=="str":
        p.eat(); return node("strlit",val=t.v)
    if t.v=="syscall":
        p.eat(); p.eat("(")
        args=[]
        if not p.match(")"):
            while True:
                args.append(parse_expr(p))
                if p.match(")"): break
                p.eat(",")
        if not args: p.err("syscall needs number")
        return node("syscall",num=args[0],args=args[1:])
    if t.k=="id":
        p.eat(); return node("ident",name=t.v)
    if p.match("("):
        e=parse_expr(p); p.eat(")"); return e
    p.err(f"unexpected {t.v!r}")

# -------------------- codegen --------------------
ARG_REGS=["rdi","rsi","rdx","r10","r8","r9"]           # syscall ABI
CALL_REGS=["rdi","rsi","rdx","rcx","r8","r9"]          # System V AMD64 (regular calls)

def rbpoff(o):
    # Format a signed rbp displacement: negative locals -> "-N", positive
    # (stack-passed params 7+) -> "+N".  o == 0 collapses to "".
    if o<0: return str(o)
    if o>0: return "+"+str(o)
    return ""

class CG:
    def __init__(s,app_prefix,kernel=False):
        s.text=[]; s.rodata=[]; s.data=[]
        s.lbl=0
        s.kernel=kernel
        s.globals=set()       # kernel-mode: symbols to emit `global` for
        s.prefix=app_prefix
        s.str_lbls={}
        s.state_defs={}
        s.consts={}
        s.externs=set()
        s.loops=[]  # (brk_lbl, cont_lbl)
        s.sigs=[]
    def L(s,base="L"):
        s.lbl+=1; return f".{base}{s.lbl}"
    def emit(s,line): s.text.append(line)
    def str_label(s,val):
        if val in s.str_lbls: return s.str_lbls[val]
        n=len(s.str_lbls); lbl=f"{s.prefix}_str{n}"
        s.str_lbls[val]=lbl
        s.rodata.append(f"{lbl}: " + _emit_db_bytes(val))
        return lbl

def _emit_db_bytes(val):
    # NASM double-quoted strings do NOT process escapes (no \n, no \\), and
    # putting an embedded " requires switching to a single-quoted form. To
    # be robust to any content — including backslashes (paths) and quotes —
    # emit the string as a list of byte values plus a NUL terminator. The
    # output is identical in size but immune to NASM quoting quirks.
    raw = val.encode("utf-8")
    if not raw:
        return "db 0"
    parts = ", ".join(str(b) for b in raw)
    return f"db {parts}, 0"

# -------------------- peephole optimizer --------------------
# The codegen above is a naive stack machine: every expression result lands in
# rax and is push/pop-shuffled into ABI registers. That makes hot inner loops
# (e.g. the SVG rasterizer's per-pixel fixed-point math) waste a huge fraction
# of their cycles on push/pop. This pass losslessly rewrites a few mechanical
# patterns to direct register moves. Semantics are preserved: every rewrite is
# a straight-line substitution within a basic block, and we bail out on any
# line that isn't a known pure data-move instruction.
#
# Patterns:
#   A) (mov rax, OP_i ; push rax){N} (pop REG_j){N}
#        -> mov REG_pop_order, OP_i ...
#      Used for N-arg call/syscall arg marshalling.
#   B) push rax ; pop REG     -> mov REG, rax
#      Catches any leftover single-arg case not covered by A.
#   C) mov rax, OP ; mov rcx, rax ; pop rax
#        -> mov rcx, OP ; pop rax
#      Catches binary-op RHS evaluation where rax is about to be overwritten.

_PEEP_LOAD_RAX = re.compile(r"^\s*mov\s+rax,\s*(.+?)\s*$")
_PEEP_PUSH_RAX = re.compile(r"^\s*push\s+rax\s*$")
_PEEP_POP_REG  = re.compile(r"^\s*pop\s+([a-z][a-z0-9]+)\s*$")
_PEEP_MOV_R_RAX = re.compile(r"^\s*mov\s+([a-z][a-z0-9]+),\s*rax\s*$")
_REG_WORD = re.compile(r"\b([a-z][a-z0-9]+)\b")
# Operands considered safe to relocate: they read no registers other than
# rbp/rip-relative or are pure immediates. We detect by checking the operand
# does not mention any general-purpose reg name that could be clobbered by
# the move target. Conservative: only allow rbp, rsp, rip in operands.
_ALLOWED_OPERAND_REGS = {"rbp","rsp","rip"}

def _operand_safe_for_target(op, target_reg):
    # Reject if operand references the target register (would change meaning).
    if re.search(r"\b" + re.escape(target_reg) + r"\b", op):
        return False
    # Reject if operand references any register not in the allowlist (could be
    # clobbered by an earlier move in the rewritten sequence).
    for m in _REG_WORD.finditer(op):
        w = m.group(1)
        # skip pure decimal numbers (already filtered by \b[a-z]) and known-safe
        if w in _ALLOWED_OPERAND_REGS: continue
        if w in ("byte","word","dword","qword","ptr","rel"): continue
        # any other identifier that looks like a register? Be conservative:
        # ban rax/rbx/rcx/rdx/rsi/rdi/r8..r15 — these can be clobbered.
        if w == "rax" or w == "rbx" or w == "rcx" or w == "rdx" \
           or w == "rsi" or w == "rdi" or (w.startswith("r") and w[1:].isdigit()):
            return False
    return True

def _peephole(lines):
    # Pass A: collapse N-arg push/pop staging into direct moves.
    out = []
    i = 0
    n = len(lines)
    while i < n:
        # Detect run of (mov rax, OP ; push rax) pairs.
        ops = []
        j = i
        while j + 1 < n:
            m1 = _PEEP_LOAD_RAX.match(lines[j])
            if not m1: break
            if not _PEEP_PUSH_RAX.match(lines[j+1]): break
            ops.append(m1.group(1))
            j += 2
        if ops:
            # Count trailing pops (must equal len(ops), all distinct, none rax).
            pops = []
            k = j
            while k < n:
                m2 = _PEEP_POP_REG.match(lines[k])
                if not m2: break
                pops.append(m2.group(1))
                k += 1
            if (len(pops) == len(ops)
                and len(set(pops)) == len(pops)
                and "rax" not in pops):
                # pops are LIFO: pops[m] receives ops[N-1-m].
                N = len(ops)
                regs = pops
                # Verify each chosen src is safe given the target register
                # AND every later target's register isn't referenced by an
                # earlier-emitted src (we emit pops in order; src for pops[0]
                # gets emitted first, so it must not reference pops[1..]'s
                # regs since those moves happen later — but later moves can't
                # clobber an already-emitted src, only the destination reg.
                # So just check: src must not reference its own destination.
                safe = True
                for m, popreg in enumerate(pops):
                    src = ops[N - 1 - m]
                    if not _operand_safe_for_target(src, popreg):
                        safe = False; break
                if safe:
                    # Additional check: src must not reference a destination
                    # that will be written before this move (i.e., any pops[<m]).
                    # Emit order: pops[0], pops[1], ... pops[N-1].
                    written = set()
                    for m, popreg in enumerate(pops):
                        src = ops[N - 1 - m]
                        for w in written:
                            if re.search(r"\b" + re.escape(w) + r"\b", src):
                                safe = False; break
                        if not safe: break
                        written.add(popreg)
                if safe:
                    for m, popreg in enumerate(pops):
                        src = ops[N - 1 - m]
                        out.append(f"    mov {popreg}, {src}")
                    i = k
                    continue
        out.append(lines[i])
        i += 1

    # Pass B: any remaining adjacent push rax / pop REG.
    lines = out
    out = []
    i = 0
    n = len(lines)
    while i < n:
        if (i + 1 < n
            and _PEEP_PUSH_RAX.match(lines[i])
            and _PEEP_POP_REG.match(lines[i+1])):
            reg = _PEEP_POP_REG.match(lines[i+1]).group(1)
            if reg != "rax":
                out.append(f"    mov {reg}, rax")
            i += 2
            continue
        out.append(lines[i])
        i += 1

    # Pass C: mov rax, OP / mov rcx, rax / pop rax  -> mov rcx, OP / pop rax
    # (and same for any target reg, not just rcx). The trailing pop rax shows
    # the rax load was only a staging step.
    lines = out
    out = []
    i = 0
    n = len(lines)
    while i < n:
        if i + 2 < n:
            m1 = _PEEP_LOAD_RAX.match(lines[i])
            m2 = _PEEP_MOV_R_RAX.match(lines[i+1])
            m3 = _PEEP_POP_REG.match(lines[i+2])
            if m1 and m2 and m3 and m3.group(1) == "rax" and m2.group(1) != "rax":
                op = m1.group(1)
                tgt = m2.group(1)
                if _operand_safe_for_target(op, tgt):
                    out.append(f"    mov {tgt}, {op}")
                    out.append(lines[i+2])
                    i += 3
                    continue
        out.append(lines[i])
        i += 1
    return out

def compile_unit(decls,app_prefix,embed=False,kernel=False):
    global LAST_SIGS
    cg=CG(app_prefix,kernel=kernel)
    cg.embed=embed
    app_meta={"name":app_prefix,"stack":4096}
    # collect top-level
    str_defs={}
    for d in decls:
        if d["k"]=="app":
            if kernel:
                raise SyntaxError("`app` declaration is not allowed in a kernel module (--target kernel); use `module`")
            app_meta["name"]=d["name"]; app_meta["stack"]=d["stack"]
        elif d["k"]=="module":
            if not kernel:
                raise SyntaxError("`module` declaration requires --target kernel")
            app_meta["name"]=d["name"]
        elif d["k"]=="global":
            if not kernel:
                raise SyntaxError("`global` declaration requires --target kernel")
            cg.globals.add(d["name"])
        elif d["k"]=="strdef":
            lbl=f"{app_prefix}_{d['name']}"
            cg.str_lbls[d["val"]]=lbl
            cg.rodata.append(f"{lbl}: " + _emit_db_bytes(d["val"]))
            str_defs[d["name"]]=lbl
        elif d["k"]=="const":
            cg.consts[d["name"]]=d["val"]
        elif d["k"]=="extern":
            cg.externs.add(d["name"])
        elif d["k"]=="state":
            for nm,sz in d["fields"]:
                if sz <= 0:
                    raise SyntaxError(f"state {nm}: size must be positive")
                lbl=f"{app_prefix}_{nm}"
                cg.state_defs[nm]=lbl
                cg.data.append(f"{lbl}: times {sz} db 0")
    cg.str_defs=str_defs
    # collect local fn names (so calls resolve to prefixed symbols)
    cg.local_fns={d["name"] for d in decls if d["k"]=="fn"}
    cg.fn_argc={d["name"]:len(d["params"]) for d in decls if d["k"]=="fn"}
    # functions
    for d in decls:
        if d["k"]=="fn":
            if kernel:
                gen_kernel_fn(cg,d)
            else:
                gen_fn(cg,d,app_prefix)
    # assemble output
    out=[]
    out.append(f"; NexusHL generated — do not edit by hand")
    if kernel:
        out.append(f'; module="{app_meta["name"]}" target=kernel')
    else:
        out.append(f'; app="{app_meta["name"]}" stack={app_meta["stack"]}')
    if not embed and not kernel:
        out.append("bits 64")
        out.append("default rel")
        out.append('%include "trace.inc"')
    for e in sorted(cg.externs):
        out.append(f"extern {e}")
    # Kernel mode: emit `global` for every exported symbol. Under -f bin (the
    # kernel's single-TU build) these are %unmacro'd to no-ops by
    # kernel_build.asm; they remain meaningful for any future -f elf reuse and
    # they document the module's public surface.
    if kernel:
        for g in sorted(cg.globals):
            out.append(f"global {g}")
    if not embed:
        out.append("section .text")
    out.extend(_peephole(cg.text))
    # Strings: emit as inert bytes in current section. In standalone mode put
    # them in .rodata; in embed mode keep them in .text (safe — no code falls
    # through into them since every fn ends with `ret`).
    if cg.rodata:
        if not embed:
            out.append("section .rodata")
        out.extend(cg.rodata)
    if cg.data:
        if not embed:
            out.append("section .data")
        out.extend(cg.data)
    LAST_SIGS=cg.sigs
    return "\n".join(out)+"\n"

def gen_kernel_fn(cg,fn):
    # Kernel-mode function codegen.
    #
    # Two forms:
    #
    #  (1) Register-exact ABI shim — the body is ONE OR MORE `asm { }` blocks and
    #      nothing else. The function's NASM label is emitted and the asm lines
    #      are passed through verbatim; the asm owns the entire prologue, the
    #      custom (non-System-V) register ABI, and its own `ret`. The compiler
    #      adds NO frame, NO callee-save, NO FN_BEGIN/FN_END trace framing. This
    #      is how hand-rolled kernel leaf helpers (e.g. arg in AL, all regs
    #      preserved) are ported faithfully — the security property we keep here
    #      is that every such block is explicitly author-marked `asm`, never
    #      synthesised.
    #
    #  (2) Structured body — any non-`asm` statement present. Emits a standard
    #      System-V frame (same convention as user mode: args in
    #      rdi/rsi/rdx/rcx/r8/r9, locals on the stack) but WITHOUT the app-blob
    #      FN_BEGIN/FN_END syscall-trace framing and WITHOUT name prefixing, so
    #      the label is callable directly from hand-written kernel asm. Typed
    #      memory accessors (lb/lw/lq/sb/sw/sq) and direct `call <kernel_label>`
    #      are available exactly as in user mode. (Not exercised by the initial
    #      serial-diag port, which is entirely form (1), but supported so future
    #      logic-bearing kernel code need not drop to asm.)
    name=fn["name"]
    params=fn["params"]
    regparams=fn.get("regparams") or []
    preserves=fn.get("preserves")
    body=fn["body"]
    all_asm = len(body)>0 and all(s.get("k")=="asm" for s in body)
    if all_asm:
        if params or regparams or preserves:
            raise SyntaxError(
                f"kernel asm-shim fn {name!r} must declare no params — the custom "
                f"register ABI is defined inside the asm block (document it in a comment)")
        cg.emit(f"{name}:")
        for s in body:
            for ln in s["text"].split("\\n"):
                cg.emit("    "+ln)
        return
    # ------------------------------------------------------------------
    # Explicit-register-ABI structured function (kernel mode).
    #
    # Distinguished from the System-V structured form by the presence of any
    # register-bound param or a `preserves(...)` clause. The frame is:
    #
    #   <label>:
    #       push <preserved regs in declared order>      ; callee-save contract
    #       push rbp ; mov rbp,rsp ; sub rsp,<frame>     ; local frame
    #       mov [slot_p], <reg_p>                         ; spill each reg param
    #       ... body (reg params are normal stack locals) ...
    #   .epilogue:
    #       mov <reg_p>, [slot_p]                         ; write reg params back
    #       mov rsp,rbp ; pop rbp
    #       pop <preserved regs, reverse order>
    #       ret
    #
    # Spilling register params to stack locals (rather than keeping them live in
    # their physical registers) lets the existing rax/rcx-clobbering expression
    # codegen run unchanged; the named register's *value* is what the body reads
    # and mutates, and it is written back on exit so output-register ABIs (e.g.
    # "rdi advanced" cursors) are honored. `preserves` is taken on the FULL
    # 64-bit register regardless of the width the param/body uses.
    # ------------------------------------------------------------------
    if regparams or preserves is not None:
        gen_kernel_fn_regabi(cg,fn,name,regparams,preserves,body)
        return
    if regparams:
        raise SyntaxError(f"internal: regparams without regabi path for {name!r}")
    # Structured kernel function: standard System-V frame, no FN_* framing.
    scope={}
    for i,pn in enumerate(params):
        if i<len(CALL_REGS):
            scope[pn]=-8*(i+1)
        else:
            scope[pn]=16+8*(i-len(CALL_REGS))
    def count_lets(stmts):
        n=0
        for s in stmts:
            k=s.get("k")
            if k=="let": n+=1
            if k=="if":
                n+=count_lets(s.get("then",[]))
                n+=count_lets(s.get("els",[]) or [])
            if k=="while":
                n+=count_lets(s.get("body",[]))
        return n
    reg_param_count=min(len(params),len(CALL_REGS))
    n_locals=count_lets(body)
    local_size=8*(reg_param_count+n_locals)+64
    local_size=(local_size+15)&~15
    cg.emit(f"{name}:")
    cg.emit("    push rbp")
    cg.emit("    mov rbp, rsp")
    cg.emit(f"    sub rsp, {local_size}")
    for i,pn in enumerate(params):
        if i<len(CALL_REGS):
            cg.emit(f"    mov [rbp{rbpoff(scope[pn])}], {CALL_REGS[i]}")
    cg.emit("    push rbx")
    cg.emit("    push r12")
    next_off=[-8*(reg_param_count+1)]
    st=FnState(cg,scope,next_off,local_size)
    st.epilogue=f".fn_end_{cg.lbl}_{name}"
    for stmt in body:
        gen_stmt(st,stmt)
    cg.emit(f"{st.epilogue}:")
    cg.emit("    pop r12")
    cg.emit("    pop rbx")
    cg.emit("    mov rsp, rbp")
    cg.emit("    pop rbp")
    cg.emit("    ret")

# Deterministic full GP set for `preserves(all)`: every caller-visible
# general-purpose register except the frame regs (rsp/rbp, managed by the
# prologue). rax IS included: the "preserves all registers" leaf shims this
# feature replaces save/restore rax too (it is scratch in their custom ABI,
# never a return value), and a register *param* bound to rax is therefore an
# input-only, caller-preserved register (saved on entry, not written back).
PRESERVE_ALL_SET=["rax","rbx","rcx","rdx","rsi","rdi","r8","r9","r10","r11",
                  "r12","r13","r14","r15"]

def _resolve_preserves(preserves, name):
    if preserves is None:
        return []
    canon=[]
    if len(preserves)==1 and preserves[0]=="all":
        canon=list(PRESERVE_ALL_SET)
    else:
        for r in preserves:
            if r=="all":
                raise SyntaxError(f"{name}: preserves(all) must be the only entry")
            if r not in REG_TABLE:
                raise SyntaxError(f"{name}: preserves({r}) — not a register")
            canon.append(REG_TABLE[r][0])
    # de-dup preserving order
    seen=set(); out=[]
    for c in canon:
        if c in ("rbp","rsp"):
            raise SyntaxError(f"{name}: cannot preserve frame register {c}")
        if c in seen: continue
        seen.add(c); out.append(c)
    # A register may be BOTH a parameter and in preserves(...). That expresses
    # an *input-only, caller-preserved* register: it is pushed on entry (so its
    # original value is restored on exit by the matching pop) and the function's
    # internal mutation of the param is NOT written back. A param register NOT
    # in preserves is an *output*: its (possibly mutated) value is written back
    # to the physical register on exit (e.g. an advanced cursor in rdi). This is
    # the whole input-vs-output distinction, and it matches the original shims:
    # svg_dump_nibble `preserves(all)` restores its al input; diag_puth64
    # `preserves(rax,rcx)` does NOT list rdi, so the advanced cursor is exported.
    return out

def gen_kernel_fn_regabi(cg,fn,name,regparams,preserves,body):
    # Resolve param register bindings.
    regparam_canons=[]
    bindings=[]   # (paramname, canon, width, spill_off)
    for spell,pn in regparams:
        if spell not in REG_TABLE:
            raise SyntaxError(f"{name}: {spell} is not a register")
        canon,width=REG_TABLE[spell]
        if canon in regparam_canons:
            raise SyntaxError(f"{name}: register {canon} bound to two params")
        regparam_canons.append(canon)
        bindings.append([pn,canon,width,None])
    preserved=_resolve_preserves(preserves,name)
    preserved_set=set(preserved)

    # Frame: one 8-byte slot per register param + one per `let`.
    def count_lets(stmts):
        n=0
        for s in stmts:
            k=s.get("k")
            if k=="let": n+=1
            if k=="if":
                n+=count_lets(s.get("then",[]))
                n+=count_lets(s.get("els",[]) or [])
            if k=="while":
                n+=count_lets(s.get("body",[]))
        return n
    n_locals=count_lets(body)
    nregp=len(bindings)
    local_size=8*(nregp+n_locals)+64
    local_size=(local_size+15)&~15

    scope={}
    off=-8
    for b in bindings:
        b[3]=off; scope[b[0]]=off; off-=8

    cg.emit(f"{name}:")
    # callee-save contract first, so it brackets the whole frame.
    for c in preserved:
        cg.emit(f"    push {c}")
    cg.emit("    push rbp")
    cg.emit("    mov rbp, rsp")
    cg.emit(f"    sub rsp, {local_size}")
    # Spill each register param into its slot at its declared width. Reads in
    # the body go through the slot; the named register itself is now free.
    for pn,canon,width,slot in bindings:
        spell=_reg_at_width(canon,width)
        if width==64:
            cg.emit(f"    mov [rbp{rbpoff(slot)}], {spell}")
        elif width==32:
            # 32-bit store zero-extends conceptually; store the dword and the
            # high dword is don't-care because reads use the declared width.
            cg.emit(f"    mov dword [rbp{rbpoff(slot)}], {spell}")
        elif width==16:
            cg.emit(f"    mov word [rbp{rbpoff(slot)}], {spell}")
        else:
            cg.emit(f"    mov byte [rbp{rbpoff(slot)}], {spell}")

    st=FnState(cg,scope,[off],local_size)
    # widths for sized read/write of register params
    st.regparam_width={b[0]:b[2] for b in bindings}
    st.epilogue=f".fn_end_{cg.lbl}_{name}"
    for stmt in body:
        gen_stmt(st,stmt)
    cg.emit(f"{st.epilogue}:")
    # Write register params back to their physical registers — but ONLY for
    # output params (those whose register is NOT in the preserved set). An
    # input-only, caller-preserved param reg is restored by its push/pop pair
    # below, so writing the mutated value back would defeat the preservation.
    for pn,canon,width,slot in bindings:
        if canon in preserved_set:
            continue
        spell=_reg_at_width(canon,width)
        if width==64:
            cg.emit(f"    mov {spell}, [rbp{rbpoff(slot)}]")
        elif width==32:
            cg.emit(f"    mov {spell}, dword [rbp{rbpoff(slot)}]")
        elif width==16:
            cg.emit(f"    mov {spell}, word [rbp{rbpoff(slot)}]")
        else:
            cg.emit(f"    mov {spell}, byte [rbp{rbpoff(slot)}]")
    cg.emit("    mov rsp, rbp")
    cg.emit("    pop rbp")
    for c in reversed(preserved):
        cg.emit(f"    pop {c}")
    cg.emit("    ret")

def gen_fn(cg,fn,prefix):
    name=f"{prefix}_{fn['name']}"
    params=fn["params"]
    # The explicit-register ABI (register-bound params, preserves(...)) is a
    # kernel-mode-only feature; reject it on the user-mode path so app codegen
    # is unchanged and these constructs can't leak into a ring-3 blob.
    if fn.get("regparams"):
        raise SyntaxError(
            f"explicit-register parameters in fn {fn['name']!r} require --target kernel")
    if fn.get("preserves") is not None:
        raise SyntaxError(
            f"preserves(...) in fn {fn['name']!r} requires --target kernel")
    # scope: var -> rbp offset
    scope={}
    # Params 0..5 arrive in CALL_REGS and are spilled to negative rbp slots.
    # Params 6+ arrive on the caller's stack (System V): after `push rbp`,
    # arg6 sits at [rbp+16], arg7 at [rbp+24], ...  They are read in place.
    for i,pn in enumerate(params):
        if i<len(CALL_REGS):
            scope[pn]=-8*(i+1)
        else:
            scope[pn]=16+8*(i-len(CALL_REGS))
    kindmask=0
    cg.sigs.append({
        "name": name,
        "argc": len(params),
        "kindmask": kindmask,
        "retkind": "FN_RET_SCALAR",
        "args": [{"index": i, "name": pn, "kind": "FN_KIND_SCALAR"} for i, pn in enumerate(params)],
    })
    cg.emit(f"FN_BEGIN {name}, {len(params)}, {kindmask}, FN_RET_SCALAR")
    for i,pn in enumerate(params):
        cg.emit(f"FN_ARG {i}, {pn}, FN_KIND_SCALAR")
    # Frame size = one 8-byte slot per `let` in the body (scopes are not
    # reclaimed) plus the register-param spill area, rounded up to 16 bytes.
    # Sizing per-function keeps recursive functions' frames small while
    # letting wide functions declare as many locals as they need.
    def count_lets(stmts):
        n=0
        for s in stmts:
            k=s.get("k")
            if k=="let": n+=1
            if k=="if":
                n+=count_lets(s.get("then",[]))
                n+=count_lets(s.get("els",[]) or [])
            if k=="while":
                n+=count_lets(s.get("body",[]))
        return n
    reg_param_count=min(len(params),len(CALL_REGS))
    n_locals=count_lets(fn["body"])
    local_size=8*(reg_param_count+n_locals)+64
    local_size=(local_size+15)&~15
    cg.emit("    push rbp")
    cg.emit("    mov rbp, rsp")
    cg.emit(f"    sub rsp, {local_size}")
    # save register params to their negative slots (stack params stay put)
    for i,pn in enumerate(params):
        if i<len(CALL_REGS):
            cg.emit(f"    mov [rbp{rbpoff(scope[pn])}], {CALL_REGS[i]}")
    # callee-saved (we use rbx, r12 in body possibly)
    cg.emit("    push rbx")
    cg.emit("    push r12")
    # body
    next_off=[-8*(reg_param_count+1)]  # locals start below the reg-param slots
    st=FnState(cg,scope,next_off,local_size)
    st.epilogue=f".fn_end_{cg.lbl}_{name}"
    for stmt in fn["body"]:
        gen_stmt(st,stmt)
    cg.emit(f"{st.epilogue}:")
    cg.emit(f"    FN_END {name}")
    cg.emit("    pop r12")
    cg.emit("    pop rbx")
    cg.emit("    mov rsp, rbp")
    cg.emit("    pop rbp")
    cg.emit("    ret")

class FnState:
    def __init__(s,cg,scope,next_off,local_size):
        s.cg=cg; s.scope=scope; s.next_off=next_off; s.local_size=local_size
        s.epilogue=""
        # name -> (canonical_64bit_reg, width_bits) for explicit-register params
        # (kernel mode). Empty for user-mode and System-V kernel fns.
        s.regscope={}
    def new_local(s,name):
        s.next_off[0]-=8
        if -s.next_off[0]>s.local_size:
            raise SyntaxError("too many locals (>128 bytes)")
        s.scope[name]=s.next_off[0]
        return s.scope[name]

def gen_stmt(st,s):
    cg=st.cg; k=s["k"]
    if k=="let":
        off=st.new_local(s["name"])
        gen_expr(st,s["expr"])  # into rax
        cg.emit(f"    mov [rbp{rbpoff(off)}], rax")
    elif k=="assign":
        lhs=s["lhs"]
        if lhs["k"]!="ident":
            raise SyntaxError("only simple variable assignment supported")
        if lhs["name"] not in st.scope:
            raise SyntaxError(f"unknown var {lhs['name']}")
        gen_expr(st,s["rhs"])
        off=st.scope[lhs["name"]]
        w=getattr(st,"regparam_width",{}).get(lhs["name"])
        offs=rbpoff(off)
        if w==8:
            cg.emit(f"    mov byte [rbp{offs}], al")
        elif w==16:
            cg.emit(f"    mov word [rbp{offs}], ax")
        elif w==32:
            cg.emit(f"    mov dword [rbp{offs}], eax")
        else:
            cg.emit(f"    mov [rbp{rbpoff(off)}], rax")
    elif k=="exprstmt":
        gen_expr(st,s["expr"])
    elif k=="return":
        if s["expr"]:
            gen_expr(st,s["expr"])
        cg.emit(f"    jmp {st.epilogue}")
    elif k=="if":
        lelse=cg.L("else"); lend=cg.L("endif")
        gen_expr(st,s["cond"])
        cg.emit("    test rax, rax")
        cg.emit(f"    jz {lelse}")
        for stmt in s["then"]: gen_stmt(st,stmt)
        cg.emit(f"    jmp {lend}")
        cg.emit(f"{lelse}:")
        if s.get("els"):
            for stmt in s["els"]: gen_stmt(st,stmt)
        cg.emit(f"{lend}:")
    elif k=="while":
        lstart=cg.L("wst"); lend=cg.L("wend")
        cg.loops=getattr(cg,"loops",[])
        cg.loops.append((lend,lstart))
        cg.emit(f"{lstart}:")
        gen_expr(st,s["cond"])
        cg.emit("    test rax, rax")
        cg.emit(f"    jz {lend}")
        for stmt in s["body"]: gen_stmt(st,stmt)
        cg.emit(f"    jmp {lstart}")
        cg.emit(f"{lend}:")
        cg.loops.pop()
    elif k=="break":
        if not cg.loops: raise SyntaxError("break outside loop")
        cg.emit(f"    jmp {cg.loops[-1][0]}")
    elif k=="continue":
        if not cg.loops: raise SyntaxError("continue outside loop")
        cg.emit(f"    jmp {cg.loops[-1][1]}")
    elif k=="asm":
        for ln in s["text"].split("\\n"):
            cg.emit("    "+ln)
    elif k=="regcall":
        # Register-annotated call to a custom-ABI kernel routine: evaluate each
        # input expression, load it into the named register at the declared
        # width, then `call target`. Inputs are staged on the stack and popped
        # in reverse so an earlier arg's evaluation can't clobber a register a
        # later arg already loaded.
        if not getattr(cg,"kernel",False):
            raise SyntaxError("register-annotated `call` requires --target kernel")
        regargs=s["regargs"]
        canons=[]
        for spell,_ in regargs:
            if spell not in REG_TABLE:
                raise SyntaxError(f"call {s['target']}: {spell} is not a register")
            canon,_w=REG_TABLE[spell]
            if canon in canons:
                raise SyntaxError(f"call {s['target']}: register {canon} set twice")
            canons.append(canon)
        for _spell,expr in regargs:
            gen_expr(st,expr); cg.emit("    push rax")
        for canon in reversed(canons):
            cg.emit(f"    pop {canon}")
        cg.emit(f"    call {s['target']}")
    else:
        raise SyntaxError(f"bad stmt {k}")

def const_fold_int(cg, e):
    # Return the integer value of a compile-time-constant expression node, or
    # None if it isn't a plain int literal / const identifier. Used to emit
    # syscall numbers through APP_SYSNO (which needs a literal immediate).
    k=e.get("k")
    if k=="int":
        v=e["val"]
        return v if isinstance(v,int) else None
    if k=="ident":
        n=e["name"]
        if n in cg.consts and isinstance(cg.consts[n],int):
            return cg.consts[n]
    return None

def gen_expr(st,e):
    cg=st.cg; k=e["k"]
    if k=="int":
        cg.emit(f"    mov rax, {e['val']}")
    elif k=="strlit":
        lbl=cg.str_label(e["val"])
        cg.emit(f"    lea rax, [rel {lbl}]")
    elif k=="ident":
        n=e["name"]
        if n in st.scope:
            # Register params are stored at their declared width; read them at
            # that width (zero-extended into rax) so a sub-64-bit ABI value
            # never picks up garbage from the high bits of its qword slot.
            w=getattr(st,"regparam_width",{}).get(n)
            off=rbpoff(st.scope[n])
            if w==8:
                cg.emit(f"    movzx rax, byte [rbp{off}]")
            elif w==16:
                cg.emit(f"    movzx rax, word [rbp{off}]")
            elif w==32:
                cg.emit(f"    mov eax, dword [rbp{off}]")
            else:
                cg.emit(f"    mov rax, [rbp{rbpoff(st.scope[n])}]")
        elif n in cg.consts:
            cg.emit(f"    mov rax, {cg.consts[n]}")
        elif n in cg.str_defs:
            cg.emit(f"    lea rax, [rel {cg.str_defs[n]}]")
        elif n in cg.state_defs:
            cg.emit(f"    lea rax, [rel {cg.state_defs[n]}]")
        else:
            raise SyntaxError(f"unknown identifier {n}")
    elif k=="addr":
        n=e["name"]
        if n in st.scope:
            cg.emit(f"    lea rax, [rbp{rbpoff(st.scope[n])}]")
        elif n in cg.str_defs:
            cg.emit(f"    lea rax, [rel {cg.str_defs[n]}]")
        elif n in cg.state_defs:
            cg.emit(f"    lea rax, [rel {cg.state_defs[n]}]")
        elif n in cg.externs:
            cg.emit(f"    lea rax, [rel {n}]")
        else:
            # implicit extern: allow &any_symbol — register it so NASM resolves it
            cg.externs.add(n)
            cg.emit(f"    lea rax, [rel {n}]")
    elif k=="neg":
        gen_expr(st,e["expr"]); cg.emit("    neg rax")
    elif k=="not":
        gen_expr(st,e["expr"])
        cg.emit("    test rax, rax"); cg.emit("    sete al"); cg.emit("    movzx rax, al")
    elif k=="bin":
        op=e["op"]
        # Strength-reduce `/` and `%` by a compile-time power-of-two constant.
        # idiv is ~20-90 cycles; the shift idiom below is ~3 and preserves the
        # signed (truncate-toward-zero) semantics NexusHL `/` guarantees.
        if op in ("/","%"):
            cv=None
            r=e["rhs"]
            if r["k"]=="int":
                cv=r["val"]
            elif r["k"]=="ident" and r["name"] in cg.consts:
                cvv=cg.consts[r["name"]]
                if isinstance(cvv,int): cv=cvv
            if isinstance(cv,int) and cv>0 and (cv&(cv-1))==0:
                kbit=cv.bit_length()-1
                gen_expr(st,e["lhs"])
                if kbit==0:
                    if op=="%": cg.emit("    xor rax, rax")
                else:
                    cg.emit("    mov rcx, rax")
                    cg.emit("    sar rcx, 63")
                    cg.emit(f"    shr rcx, {64-kbit}")
                    cg.emit("    add rax, rcx")
                    if op=="/":
                        cg.emit(f"    sar rax, {kbit}")
                    else:
                        cg.emit(f"    and rax, {cv-1}")
                        cg.emit("    sub rax, rcx")
                return
        gen_expr(st,e["lhs"]); cg.emit("    push rax")
        gen_expr(st,e["rhs"]); cg.emit("    mov rcx, rax"); cg.emit("    pop rax")
        if op=="+": cg.emit("    add rax, rcx")
        elif op=="-": cg.emit("    sub rax, rcx")
        elif op=="*": cg.emit("    imul rax, rcx")
        elif op=="/": cg.emit("    cqo"); cg.emit("    idiv rcx")
        elif op=="%": cg.emit("    cqo"); cg.emit("    idiv rcx"); cg.emit("    mov rax, rdx")
        elif op=="&": cg.emit("    and rax, rcx")
        elif op=="|": cg.emit("    or rax, rcx")
        elif op=="^": cg.emit("    xor rax, rcx")
        elif op=="<<": cg.emit("    shl rax, cl")
        elif op==">>": cg.emit("    shr rax, cl")
        elif op in ("==","!=","<",">","<=",">="):
            cg.emit("    cmp rax, rcx")
            setop={"==":"sete","!=":"setne","<":"setl",">":"setg","<=":"setle",">=":"setge"}[op]
            cg.emit(f"    {setop} al"); cg.emit("    movzx rax, al")
        elif op=="&&":
            cg.emit("    test rax, rax"); lbl=cg.L("andfalse"); lend=cg.L("andend")
            cg.emit(f"    jz {lbl}")
            cg.emit("    test rcx, rcx"); cg.emit(f"    jz {lbl}")
            cg.emit("    mov rax, 1"); cg.emit(f"    jmp {lend}")
            cg.emit(f"{lbl}:"); cg.emit("    xor rax, rax"); cg.emit(f"{lend}:")
        elif op=="||":
            lt=cg.L("ortrue"); lend=cg.L("orend")
            cg.emit("    test rax, rax"); cg.emit(f"    jnz {lt}")
            cg.emit("    test rcx, rcx"); cg.emit(f"    jnz {lt}")
            cg.emit("    xor rax, rax"); cg.emit(f"    jmp {lend}")
            cg.emit(f"{lt}:"); cg.emit("    mov rax, 1"); cg.emit(f"{lend}:")
        else:
            raise SyntaxError(f"bad op {op}")
    elif k=="syscall":
        # move args into ABI regs, then syscall num in rax
        args=e["args"]
        if len(args)>6: raise SyntaxError("syscall has max 6 args")
        # evaluate to stack first (left-to-right), then pop in reverse
        for a in args:
            gen_expr(st,a); cg.emit("    push rax")
        for reg in reversed(ARG_REGS[:len(args)]):
            cg.emit(f"    pop {reg}")
        # Heterogeneous syscall numbering (security_todo.md §12): if the syscall
        # number is a compile-time constant (it always is for the SYS_* consts),
        # emit it through APP_SYSNO so the build records a fixup for the loader to
        # rewrite per slot. A non-constant number falls back to a plain rax load
        # (not permuted — there is no immediate to rewrite).
        numc=const_fold_int(cg, e["num"])
        if numc is not None:
            cg.emit(f"    APP_SYSNO {numc}")
        else:
            gen_expr(st,e["num"])
        cg.emit("    syscall")
    elif k=="call":
        args=e["args"]
        name=e["name"]
        # Builtins: memory load/store — compile inline, no actual call.
        if name in ("lb","lw","lq","sb","sw","sq"):
            if name in ("lb","lw","lq") and len(args)!=1: raise SyntaxError(f"{name} takes 1 arg")
            if name in ("sb","sw","sq") and len(args)!=2: raise SyntaxError(f"{name} takes 2 args")
            if name=="lb":
                gen_expr(st,args[0]); cg.emit("    movzx rax, byte [rax]")
            elif name=="lw":
                gen_expr(st,args[0]); cg.emit("    movsxd rax, dword [rax]")
            elif name=="lq":
                gen_expr(st,args[0]); cg.emit("    mov rax, [rax]")
            elif name in ("sb","sw","sq"):
                gen_expr(st,args[0]); cg.emit("    push rax")
                gen_expr(st,args[1]); cg.emit("    mov rcx, rax"); cg.emit("    pop rax")
                if name=="sb": cg.emit("    mov [rax], cl")
                elif name=="sw": cg.emit("    mov [rax], ecx")
                else: cg.emit("    mov [rax], rcx")
                cg.emit("    xor rax, rax")
            return
        if name in getattr(cg,"fn_argc",{}) and len(args)!=cg.fn_argc[name]:
            raise SyntaxError(f"{name} expects {cg.fn_argc[name]} args, got {len(args)}")
        reg_args=args[:len(CALL_REGS)]
        stack_args=args[len(CALL_REGS):]
        # System V: push stack args 7+ right-to-left so arg6 lands at [rsp].
        for a in reversed(stack_args):
            gen_expr(st,a); cg.emit("    push rax")
        # Evaluate register args, stage on the stack, then pop into regs so
        # earlier args' evaluation can't clobber a register already loaded.
        for a in reg_args:
            gen_expr(st,a); cg.emit("    push rax")
        for reg in reversed(CALL_REGS[:len(reg_args)]):
            cg.emit(f"    pop {reg}")
        if getattr(cg,"kernel",False):
            # Kernel mode: direct call to an in-unit label (the kernel is one
            # NASM translation unit, so every label resolves without extern
            # wiring). No FN_CALL trace framing, no app-prefix on local fns.
            cg.emit(f"    call {name}")
        elif name in getattr(cg,"local_fns",set()):
            cg.emit(f"    FN_CALL {cg.prefix}_{name}, {len(args)}")
        else:
            cg.externs.add(name)
            cg.emit(f"    FN_CALL {name}, {len(args)}")
        if stack_args:
            cg.emit(f"    add rsp, {8*len(stack_args)}")
    else:
        raise SyntaxError(f"bad expr {k}")

# -------------------- driver --------------------
def resolve_use(name, lib_dir):
    path=os.path.join(lib_dir, name.replace(".", os.sep)+".nxh")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"use {name}: {path} not found")
    return path

def compile_file(path, lib_dir, app_prefix=None, embed=False, return_sigs=False, kernel=False):
    with open(path,"r",encoding="utf-8") as f: src=f.read()
    toks=lex(src,path); decls=parse(toks,path)
    # expand uses: prepend decls from lib files
    expanded=[]
    seen=set()
    def load(p):
        if p in seen: return
        seen.add(p)
        with open(p,"r",encoding="utf-8") as f: s=f.read()
        tt=lex(s,p); dd=parse(tt,p)
        # libs can themselves `use`, but keep simple: one level
        for d in dd:
            if d["k"]=="use":
                sub=resolve_use(d["name"], lib_dir)
                load(sub)
            else:
                expanded.append(d)
    # resolve top-level `use` first
    for d in decls:
        if d["k"]=="use":
            sub=resolve_use(d["name"], lib_dir)
            load(sub)
    for d in decls:
        if d["k"]!="use":
            expanded.append(d)
    prefix=app_prefix or os.path.splitext(os.path.basename(path))[0]
    # Kernel modules are not prefixed (their labels must match existing kernel
    # symbols verbatim); the prefix is retained only for the user-mode path.
    unit_prefix = prefix if kernel else "app_hl_"+prefix
    asm=compile_unit(expanded, unit_prefix, embed=embed, kernel=kernel)
    if return_sigs:
        return asm, LAST_SIGS
    return asm

def main():
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o","--output",required=True)
    ap.add_argument("-L","--lib",default=os.path.join(os.path.dirname(__file__),"..","lib"))
    ap.add_argument("--prefix",default=None)
    ap.add_argument("--embed",action="store_true",
                    help="emit for %%include into a larger NASM unit: no bits/default/section/extern directives, strings inline in .text")
    ap.add_argument("--emit-sigs",action="store_true",
                    help="write a .sig.json sidecar next to the generated assembly")
    ap.add_argument("--target",choices=["user","kernel"],default="user",
                    help="user (default): emit a ring-3 app blob with syscall wrappers. "
                         "kernel: emit plain NASM for %%include into kernel_build.asm — "
                         "bare labels, direct in-unit calls, no app framing, no syscall wrappers.")
    args=ap.parse_args()
    kernel=(args.target=="kernel")
    if args.emit_sigs:
        asm,sigs=compile_file(args.input, os.path.abspath(args.lib), args.prefix, embed=args.embed, return_sigs=True, kernel=kernel)
    else:
        asm=compile_file(args.input, os.path.abspath(args.lib), args.prefix, embed=args.embed, kernel=kernel)
        sigs=[]
    with open(args.output,"w",encoding="utf-8",newline="\n") as f: f.write(asm)
    if args.emit_sigs:
        sig_path=os.path.splitext(args.output)[0]+".sig.json"
        with open(sig_path,"w",encoding="utf-8",newline="\n") as f:
            json.dump(sigs,f,indent=2)
            f.write("\n")
    print(f"[nxhc] {args.input} -> {args.output} ({len(asm)} bytes)")

if __name__=="__main__":
    main()
