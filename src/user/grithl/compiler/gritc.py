#!/usr/bin/env python3
# GritHL compiler (gritc) - translates .ghl -> NASM .asm
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
    "global","data","table","naked","align","unsafe",
    # Kernel-mode explicit-register ABI:
    #   preserves(...) - callee-save contract (see gen_kernel_fn)
    #   call           - register-annotated call statement `call f(al: x);`
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
    # Legacy high-byte registers are needed for BIOS ABIs (AH=function,
    # CH/CL=cylinder/sector, DH=head). They alias the same canonical 64-bit
    # register as their low-byte partner; codegen moves them explicitly.
    t["ah"]=("rax",8); t["bh"]=("rbx",8); t["ch"]=("rcx",8); t["dh"]=("rdx",8)
    for n in range(8,16):
        q=f"r{n}"; t[q]=(q,64); t[f"r{n}d"]=(q,32); t[f"r{n}w"]=(q,16); t[f"r{n}b"]=(q,8)
    return t

REG_TABLE=_build_reg_table()

# SSE2 XMM register names. The XMM data path (display non-temporal blits, dword
# broadcast fills) is expressed with statement-form intrinsics that take a BARE
# xmm register name - the same explicit-register discipline as push_reg/set_reg.
# XMM lifetimes are the author's responsibility: the structured stack machine
# keeps live values only in GP rbp slots, so it never relies on an XMM register
# surviving across statements (consistent with set_reg semantics).
XMM_REGS=frozenset(f"xmm{i}" for i in range(16))

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
                # this is the only place a GritHL author can spell a quote,
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
            if p.peek().v=="extern":
                # `const NAME = extern;` - symbolic passthrough: NAME is an
                # assembly-time constant (an `equ` defined in a kernel include).
                # Codegen emits the bare symbol and NASM resolves it, so the
                # value is never duplicated into GHLK (maintainability: the header
                # stays the single source of the name). Not const-foldable.
                p.eat(); p.match(";")
                decls.append(node("const",name=nm,symbolic=True))
            else:
                neg=False
                if p.peek().k=="-": p.eat(); neg=True
                v=p.eat("num").v
                if neg: v = -v
                p.match(";")
                decls.append(node("const",name=nm,val=v))
        elif t.v=="module":
            # Kernel-mode unit marker: `module "name";`. Names the translation
            # unit for the generated-file banner. Presence does NOT itself switch
            # codegen - the --target kernel flag does - but it documents intent
            # and is rejected by the user-mode path so a kernel module can't be
            # compiled as an app by accident.
            p.eat(); nm=p.eat("str").v; p.match(";")
            decls.append(node("module",name=nm))
        elif t.v=="global":
            # Kernel-mode: export a symbol so other kernel modules / main.asm
            # can reference it. `global name;` - emits `global name` ahead of
            # the label. Ignored (with a clear error) in user mode.
            p.eat(); nm=p.eat("id").v; p.match(";")
            decls.append(node("global",name=nm))
        elif t.v=="extern":
            p.eat(); nm=p.eat("id").v; p.match(";")
            decls.append(node("extern",name=nm))
        elif t.v=="unsafe":
            p.eat(); cap=p.eat("id").v; p.match(";")
            decls.append(node("unsafe",cap=cap,line=t.line))
        elif t.v=="data":
            # Kernel-mode data with an EXACT (unprefixed) symbol name. Forms:
            #   data NAME: <count> [x <width>] [= <init>];   element array
            #   data NAME = "string";                        NUL-terminated bytes
            # <count> is a number, const, or product of two (e.g. MAXW * TBL_count);
            # <width> in {1,2,4,8} -> db/dw/dd/dq (default 1); <init> number/const
            # fill (default 0). Indexable like `state` (bounds-checked, byte-addr).
            # Export with `global NAME;`. Lets kernel buffers keep the exact
            # names/sizes/widths/inits the rest of the kernel binds to.
            p.eat(); nm=p.eat("id").v
            if p.match("="):
                # string form
                sval=p.eat("str").v; p.match(";")
                decls.append(node("data",name=nm,strval=sval))
                continue
            p.eat(":")
            def _data_term(pp):
                if pp.peek().k=="num": return ("num",pp.eat("num").v)
                return ("id",pp.eat("id").v)
            factors=[_data_term(p)]
            if p.peek().k=="*":
                p.eat(); factors.append(_data_term(p))
            width=1
            if p.peek().k=="id" and p.peek().v=="x":
                p.eat(); width=p.eat("num").v
            init=node("int",val=0)
            if p.match("="):
                if p.match("["):
                    vals=[]
                    while not p.match("]"):
                        neg=False
                        if p.peek().k=="-": p.eat(); neg=True
                        if p.peek().k=="num":
                            v=p.eat("num").v
                            vals.append(-v if neg else v)
                        else:
                            vals.append(("id", p.eat("id").v, neg))
                        p.match(",")
                    init=node("list",vals=vals)
                else:
                    neg=False
                    if p.peek().k=="-": p.eat(); neg=True
                    if p.peek().k=="num":
                        v=p.eat("num").v
                        init=node("int",val=(-v if neg else v))
                    else:
                        init=node("ident",name=p.eat("id").v)
            p.match(";")
            decls.append(node("data",name=nm,factors=factors,width=width,init=init))
        elif t.v=="align":
            p.eat(); n=p.eat("num").v; p.match(";")
            decls.append(node("align",n=n))
        elif t.v=="bits":
            p.eat(); n=p.eat("num").v; p.match(";")
            decls.append(node("bits",n=n))
        elif t.v=="org":
            p.eat()
            neg=False
            if p.peek().k=="-": p.eat(); neg=True
            v=p.eat("num").v
            if neg: v = -v
            p.match(";")
            decls.append(node("org",val=v))
        elif t.v=="pad_to":
            p.eat(); n=p.eat("num").v
            fill=0
            if p.match("="):
                fill=p.eat("num").v
            p.match(";")
            decls.append(node("pad_to",n=n,fill=fill))
        elif t.v=="boot_signature":
            p.eat(); p.match(";")
            decls.append(node("boot_signature"))
        elif t.v=="table":
            # Kernel-mode dispatch table: a fixed, ordered list of handler fn
            # names. Emits `NAME: dq fn0, dq fn1, ...` and registers a count so
            # `call_table(NAME, idx)` can do a BOUNDS-CHECKED indirect call into
            # only this controlled set - the safe replacement for a raw
            # `jmp [reg+off]` through an arbitrary pointer.
            p.eat(); nm=p.eat("id").v; p.eat("{")
            entries=[]
            while not p.match("}"):
                entries.append(p.eat("id").v)
                p.match(",")
            p.match(";")
            decls.append(node("table",name=nm,entries=entries))
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
    fl=p.peek().line
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
    # `naked`: no compiler-emitted frame/prologue/epilogue/ret. The body owns
    # the entire stack discipline via intrinsics (read_rsp/write_rsp/push_val/
    # pop_val) and ends with its own control transfer (sysretq/iretq/...). For
    # the SYSCALL `LSTAR` entry trampoline, which runs on the user stack with no
    # frame and exits via sysret - unrepresentable by a normal `fn`.
    naked=False
    if p.peek().v=="naked":
        p.eat(); naked=True
    body=parse_block(p)
    return node("fn",name=name,params=params,regparams=regparams,
                preserves=preserves,body=body,line=fl,naked=naked)

def parse_block(p):
    p.eat("{")
    stmts=[]
    while not p.match("}"):
        stmts.append(parse_stmt(p))
    return stmts

def parse_stmt(p):
    # Capture the source line of every statement so codegen can stamp each
    # emitted instruction with `; <file>:<line>` provenance (zero runtime cost,
    # no extra instructions - see gen_stmt). This is the backbone of GHLK's
    # "disassembly traces straight back to source" debugging story.
    ln=p.peek().line
    nd=_parse_stmt_inner(p)
    if isinstance(nd,dict) and "line" not in nd:
        nd["line"]=ln
    return nd

def _parse_stmt_inner(p):
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
    if t.v=="cfg":
        # Build-time conditional compilation: `cfg "NAME" { ... }` wraps the
        # block in `%ifdef NAME ... %endif`; `cfg !"NAME" { ... }` uses %ifndef;
        # an optional `else { ... }` emits the %else arm. The only way structured
        # GHLK can express the kernel's per-build-config (ENABLE_CET, GRIT_SMP,
        # FBPERF_NO_WC, ...) code paths without dropping to an asm escape.
        p.eat()
        neg=False
        if p.peek().k=="!":
            p.eat(); neg=True
        name=p.eat("str").v
        body=parse_block(p)
        els=None
        if p.match("else"):
            els=parse_block(p)
        return node("cfg",name=name,neg=neg,body=body,els=els)
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

# Zero-argument CPU instruction intrinsics (kernel mode only). Each maps to a
# fixed instruction sequence emitted inline - no call, no asm{} escape. Control
# intrinsics (sysretq/iretq/hlt) do not return; value intrinsics leave their
# result in rax (the accumulator) so they compose in expressions. See the
# intrinsic dispatch in gen_expr for the arg-taking forms (rdmsr/wrmsr/inb/...).
_NULLARY_INTRINSICS={
    # control / barrier - no value
    "cli":["cli"], "sti":["sti"], "hlt":["hlt"], "swapgs":["swapgs"],
    "sysretq":["o64 sysret"], "iretq":["iretq"], "ud2":["ud2"],
    "ret_naked":["ret"],              # explicit near return for `naked` fns
                                      # (naked has no auto epilogue/ret)
    "lfence":["lfence"], "mfence":["mfence"], "sfence":["sfence"],
    "pause":["pause"], "wbinvd":["wbinvd"], "nop":["nop"],
    "smap_open":["stac"], "smap_close":["clac"],
    # value-producing - result in rax
    "rdtsc":["rdtsc","shl rdx, 32","mov eax, eax","or rax, rdx"],
    "rdrand":["rdrand rax"],          # single attempt; CF=success (loop in GHLK if needed)
    "read_cr0":["mov rax, cr0"],
    "read_cr2":["mov rax, cr2"],
    "read_cr3":["mov rax, cr3"],
    "read_cr4":["mov rax, cr4"],
    # naked/raw-stack primitives (for `naked` fns, e.g. the SYSCALL trampoline)
    "read_rsp":["mov rax, rsp"],      # current stack pointer
    "pop_val":["pop rax"],            # pop top of stack into rax
    # EFLAGS read (value, naked/iret paths). pushfq/pop is the only architectural
    # way to materialize RFLAGS into a GPR. Pairs with write_flags(v).
    "read_flags":["pushfq","pop rax"],
}

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
        s.target="kernel" if kernel else "user"
        s.boot_bits=64
        s.src=None          # source basename for `; file:line` provenance
        s.srcmap=True       # stamp provenance comments (zero runtime cost)
        s.globals=set()       # kernel-mode: symbols to emit `global` for
        s.prefix=app_prefix
        s.str_lbls={}
        s.state_defs={}
        s.state_sizes={}      # state buffer name -> byte size (for bounds checks)
        s.state_widths={}     # state/data name -> element width in bytes
        s.table_counts={}     # dispatch table name -> entry count (for call_table)
        s.fnbegin_emitted=set()  # exported kernel fns emitted via FN_BEGIN (skip top-level global)
        s.consts={}
        s.symconsts=set()   # `const X = extern;` - emit bare symbol, NASM resolves
        s.externs=set()
        s.unsafe_caps=set()
        s.deny_unsafe=False
        s.loops=[]  # (brk_lbl, cont_lbl)
        s.sigs=[]
        s.need_oob=False      # an out-of-bounds trap stub is referenced
    def L(s,base="L"):
        s.lbl+=1; return f".{base}{s.lbl}"
    def oob(s):
        # Shared per-unit out-of-bounds trap target. Referencing it marks the
        # stub for emission at unit end. The stub is `ud2` - an unforgeable #UD
        # fault - so a bounds violation can never silently corrupt memory.
        s.need_oob=True
        return f"{s.prefix}_ghlk_oob"
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
    # be robust to any content - including backslashes (paths) and quotes -
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
#   D) push rax ; mov REG, OP ; pop rax   -> mov REG, OP
#      The push/pop bracket only protects rax across the middle mov; when the
#      middle mov neither reads nor writes rax (and does not read rsp, which
#      the push displaced), the bracket is a pure no-op and is dropped. This is
#      the dominant binary-op RHS shape left after pass C (mov rcx, imm/slot).
#   E) jmp L ; L:   -> L:
#      A jump to the literally-next code line (the unconditional `jmp .fn_end`
#      the emitter places before the epilogue label on every final return).
#   F) mov [rbp±K], R ; mov R, [rbp±K]   -> mov [rbp±K], R
#      An adjacent reload of the exact slot/register pair just stored; R
#      already holds the value, the reload is a no-op.
# B/C/D are iterated to a fixpoint: removing one bracket exposes the next.

_PEEP_LOAD_RAX = re.compile(r"^\s*mov\s+rax,\s*(.+?)\s*$")
_PEEP_PUSH_RAX = re.compile(r"^\s*push\s+rax\s*$")
_PEEP_POP_REG  = re.compile(r"^\s*pop\s+([a-z][a-z0-9]+)\s*$")
_PEEP_MOV_R_RAX = re.compile(r"^\s*mov\s+([a-z][a-z0-9]+),\s*rax\s*$")

def _code(line):
    # The instruction text of a generated line, minus any `; file:line`
    # provenance comment. Generated .text never contains a literal ';' except
    # as a comment (string data lives in .rodata as db bytes), so a plain split
    # is safe. The peephole matches on this so provenance never blocks an
    # optimization; the comment is re-attached to whichever instruction survives.
    h = line.find(";")
    return line if h < 0 else line[:h].rstrip()

def _comment(line):
    h = line.find(";")
    return ("    " + line[h:]) if h >= 0 else ""
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
        # ban rax/rbx/rcx/rdx/rsi/rdi/r8..r15 - these can be clobbered.
        if w == "rax" or w == "rbx" or w == "rcx" or w == "rdx" \
           or w == "rsi" or w == "rdi" or (w.startswith("r") and w[1:].isdigit()):
            return False
    return True

def _peephole(lines, extended=True):
    # `extended=False` (--O0) limits this pass to the original single-round
    # A/B/C patterns so -O0 reproduces the historical byte-exact output for
    # debugging / byte-diffing. The D/E/F passes and the B/C/D fixpoint loop
    # are part of the default (-O1) optimizer.
    # Pass A: collapse N-arg push/pop staging into direct moves.
    out = []
    i = 0
    n = len(lines)
    while i < n:
        # Detect run of (mov rax, OP ; push rax) pairs.
        ops = []
        cmts = []
        j = i
        while j + 1 < n:
            m1 = _PEEP_LOAD_RAX.match(_code(lines[j]))
            if not m1: break
            if not _PEEP_PUSH_RAX.match(_code(lines[j+1])): break
            ops.append(m1.group(1))
            cmts.append(_comment(lines[j]))   # provenance of the load survives
            j += 2
        if ops:
            # Count trailing pops (must equal len(ops), all distinct, none rax).
            pops = []
            k = j
            while k < n:
                m2 = _PEEP_POP_REG.match(_code(lines[k]))
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
                # regs since those moves happen later - but later moves can't
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
                        out.append(f"    mov {popreg}, {src}{cmts[N - 1 - m]}")
                    i = k
                    continue
        out.append(lines[i])
        i += 1

    # Passes B/C/D iterate to a fixpoint: each removed staging bracket can make
    # a new adjacent pattern (bounded: every pass only deletes/shrinks lines).
    lines = out
    for _round in range(16 if extended else 1):
        changed = False

        # Pass B: any remaining adjacent push rax / pop REG.
        out = []
        i = 0
        n = len(lines)
        while i < n:
            if (i + 1 < n
                and _PEEP_PUSH_RAX.match(_code(lines[i]))
                and _PEEP_POP_REG.match(_code(lines[i+1]))):
                reg = _PEEP_POP_REG.match(_code(lines[i+1])).group(1)
                if reg != "rax":
                    out.append(f"    mov {reg}, rax{_comment(lines[i])}")
                i += 2
                changed = True
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
                m1 = _PEEP_LOAD_RAX.match(_code(lines[i]))
                m2 = _PEEP_MOV_R_RAX.match(_code(lines[i+1]))
                m3 = _PEEP_POP_REG.match(_code(lines[i+2]))
                if m1 and m2 and m3 and m3.group(1) == "rax" and m2.group(1) != "rax":
                    op = m1.group(1)
                    tgt = m2.group(1)
                    if _operand_safe_for_target(op, tgt):
                        out.append(f"    mov {tgt}, {op}{_comment(lines[i])}")
                        out.append(lines[i+2])
                        i += 3
                        changed = True
                        continue
            out.append(lines[i])
            i += 1

        if not extended:
            lines = out
            break

        # Pass D: push rax / mov REG, OP / pop rax  -> mov REG, OP.
        # Sound iff the middle mov is independent of the bracket: REG is a plain
        # GPR other than rax/rsp, and OP mentions neither rax (the protected
        # value) nor rsp (displaced by the push). The push/pop then cancels.
        lines = out
        out = []
        i = 0
        n = len(lines)
        while i < n:
            if i + 2 < n and _PEEP_PUSH_RAX.match(_code(lines[i])):
                mm = _MOV2_RE.match(_code(lines[i+1]).strip())
                mp = _PEEP_POP_REG.match(_code(lines[i+2]))
                if mm and mp and mp.group(1) == "rax":
                    dest = mm.group(1).strip()
                    src = mm.group(2).strip()
                    if (dest not in ("rax", "rsp")
                        and re.fullmatch(r"[a-z][a-z0-9]+", dest)
                        and _canon(dest)
                        and not re.search(r"\brax\b", src)
                        and not re.search(r"\brsp\b", src)):
                        out.append(f"    mov {dest}, {src}{_comment(lines[i+1])}")
                        i += 3
                        changed = True
                        continue
            out.append(lines[i])
            i += 1

        lines = out
        if not changed:
            break

    if not extended:
        return lines

    # Pass E: drop `jmp L` when the immediately following code line is `L:`.
    out = []
    i = 0
    n = len(lines)
    while i < n:
        c = _code(lines[i]).strip()
        if c.startswith("jmp ") and i + 1 < n:
            nxt = _code(lines[i+1]).strip()
            if nxt.endswith(":") and nxt[:-1].strip() == c[4:].strip():
                i += 1
                continue
        out.append(lines[i])
        i += 1

    # Pass F: drop an adjacent exact-pair reload `mov [rbp±K], R` / `mov R,
    # [rbp±K]` (same slot text, same 64-bit reg). R already holds the value.
    lines = out
    out = []
    i = 0
    n = len(lines)
    _slot_re = re.compile(r"^\[rbp[+-]\d+\]$")
    while i < n:
        if i + 1 < n:
            m1 = _MOV2_RE.match(_code(lines[i]).strip())
            m2 = _MOV2_RE.match(_code(lines[i+1]).strip())
            if m1 and m2:
                d1, s1 = m1.group(1).strip(), m1.group(2).strip()
                d2, s2 = m2.group(1).strip(), m2.group(2).strip()
                if (_slot_re.match(d1) and s2 == d1 and d2 == s1
                        and _canon(s1) and REG_TABLE.get(s1, (None, 0))[1] == 64):
                    out.append(lines[i])
                    i += 2
                    continue
        out.append(lines[i])
        i += 1
    return out

# -------------------- function-level optimizer (lossless) --------------------
# The peephole above collapses push/pop arg staging but leaves the per-function
# scaffolding the naive emitter always emits: a full rbp frame, a memory "home
# slot" spill of every register parameter (immediately reloaded), an
# unconditional push/pop of the rbx/r12 callee-saved pair the user-mode body
# almost never touches, and a `jmp .fn_end` to the very next line. On the thin
# syscall-wrapper functions that dominate an app these turn a 3-instruction body
# into ~17 instructions. This pass removes that scaffolding when - and ONLY
# when - it can prove the removal changes nothing observable. It is allowlist
# based exactly like _operand_safe_for_target: any function or pattern it cannot
# prove safe is passed through verbatim, so it can never make code wrong, only
# decline to shrink it. Set with -O1 (default); -O0 reproduces the verbose
# output for debugging / byte-diffing.
#
# Safety is also a security win: fewer spills means fewer copies of argument
# values (tokens/keys passed as args) left sitting in the writable stack frame,
# and ~3-4x less .text per app means a smaller W^X code window to hash and
# protect.
#
# Runtime note: this pass is intentionally disabled for default user builds
# until the full app/kernel callback and syscall register contract is tightened.
# The peephole pass above remains enabled; it is local and matches the stable
# --O0 boot behavior. The broader frame/spill cleanup can corrupt control flow
# in slot-1 app callbacks when older helpers/syscalls violate the strict SysV
# assumptions it needs.
_ENABLE_USER_FUNCTION_OPT = False

# A memory operand that is a plain, constant rbp-relative slot: [rbp-8], [rbp+16].
_RBP_SLOT_RE = re.compile(r"\[rbp([+-]\d+)\]")
# Exactly one such slot and nothing else inside the brackets (rejects indexed
# forms like [rbp-8+rax] that we cannot reason about).
_RBP_SLOT_ONLY_RE = re.compile(r"^\[rbp[+-]\d+\]$")
_MOV2_RE = re.compile(r"^mov\s+([^,]+),\s*(.+)$")
_CALLER_SAVED = {"rax","rcx","rdx","rsi","rdi","r8","r9","r10","r11"}
_SYSCALL_CLOBBERED = _CALLER_SAVED | {"rbx","r12","r13","r14","r15"}

def _canon(tok):
    e = REG_TABLE.get(tok.strip())
    return e[0] if e else None

def _fn_segments(lines):
    # Yield (is_fn, [lines]) segments. A function segment starts at an
    # `FN_BEGIN ` line and runs up to (not including) the next one; everything
    # before the first FN_BEGIN and any trailing non-fn lines pass through.
    out=[]; i=0; n=len(lines)
    # leading non-fn preamble
    while i<n and not _code(lines[i]).startswith("FN_BEGIN "):
        out.append((False,[lines[i]])); i+=1
    while i<n:
        j=i+1
        while j<n and not _code(lines[j]).startswith("FN_BEGIN "):
            j+=1
        out.append((True, lines[i:j])); i=j
    return out

def _opt_fn_uses_addr_of_frame(codes):
    # Bail conditions for value-forwarding / dead-store / frame removal: if the
    # function takes the address of a stack slot (lea ...,[rbp...]) or uses an
    # indexed/odd rbp form, a memory write through a pointer could alias a slot
    # we are tracking - we cannot prove anything, so disable those passes.
    for c in codes:
        if "rbp" not in c:
            continue
        if c.startswith(("push rbp","pop rbp","mov rbp, rsp","mov rsp, rbp",
                         "sub rsp","add rsp")):
            continue
        if c.startswith("lea ") and "rbp" in c:
            return True
        # every rbp mention in this line must be a plain constant slot
        # (strip the known-good slot forms; if 'rbp' still remains, it's odd)
        stripped=_RBP_SLOT_RE.sub("", c)
        if "rbp" in stripped:
            return True
    return False

def _writes_reg_canons(code):
    # Conservative set of canonical 64-bit registers an instruction writes.
    # Returns None to mean "clears all tracking" (unknown / control flow).
    if code.endswith(":"):                      # a label = a jump target
        return None
    mnem=code.split(None,1)[0] if code else ""
    if mnem in ("test","cmp","push","jmp","je","jz","jne","jnz","ja","jae",
                "jb","jbe","jg","jge","jl","jle","sfence","mfence","lfence",
                "nop","cld","std","FN_BEGIN","FN_ARG","FN_END"):
        return set()
    if mnem=="syscall":
        # GritOS syscalls are not a normal System-V call boundary and the
        # kernel-side dispatcher is free to reuse GPRs. Do not forward or
        # promote values through it as if any non-frame GPR survived.
        return set(_SYSCALL_CLOBBERED)
    if mnem=="APP_SYSNO":
        return {"rax"}
    if mnem in ("call","FN_CALL") or code.startswith("call "):
        return set(_CALLER_SAVED)
    if mnem in ("cqo","cdq"):
        return {"rdx"}
    if mnem in ("idiv","div","mul"):
        return {"rax","rdx"}
    if mnem=="pop":
        c=_canon(code.split(None,1)[1]); return {c} if c else None
    if mnem in ("mov","movzx","movsx","movsxd","lea","add","sub","and","or",
                "xor","imul","neg","shl","shr","sar","ror","rol","sete","setne",
                "setl","setg","setle","setge","seta","setb","movd","pshufd",
                "movdqu","movdqa","movntdq"):
        m=_MOV2_RE.match(code) if mnem=="mov" else None
        # two-operand: dest is text up to first comma
        rest=code.split(None,1)[1] if " " in code else ""
        dest=rest.split(",",1)[0].strip()
        if dest.startswith("[") or dest.startswith("xmm"):
            return set()                         # memory / xmm dest: no GPR write
        c=_canon(dest)
        return {c} if c else None
    return None                                  # unknown instruction: clear all

def _p_value_forward(seg, codes):
    # Remove a reload `mov R, [rbp±K]` when R already holds [rbp±K]'s value
    # because an earlier `mov [rbp±K], R` (same 64-bit reg, no intervening write
    # to R or the slot) put it there. Tracks reg->slot equalities; clears at any
    # label or unknown instruction. Only 64-bit GP moves participate.
    reg_slot={}     # canon reg -> slot string (reg currently equals this slot)
    drop=set()
    for idx,c in enumerate(codes):
        m=_MOV2_RE.match(c)
        if m:
            dest=m.group(1).strip(); src=m.group(2).strip()
            d_can=_canon(dest); s_can=_canon(src)
            # store: mov [slot], R64
            if _RBP_SLOT_ONLY_RE.match(dest) and s_can:
                slot=_RBP_SLOT_RE.match(dest).group(1)
                # this reg now equals this slot; any other reg equal to slot is
                # still valid (mem unchanged value), but regs equal to it stay.
                for r in [r for r,sv in reg_slot.items() if sv==slot and r!=s_can]:
                    pass
                reg_slot[s_can]=slot
                continue
            # reload: mov R64, [slot]
            if d_can and _RBP_SLOT_ONLY_RE.match(src):
                slot=_RBP_SLOT_RE.match(src).group(1)
                if reg_slot.get(d_can)==slot:
                    drop.add(idx)                # redundant: R already holds it
                    continue
                reg_slot[d_can]=slot
                continue
            # plain reg<-reg / reg<-imm move: dest no longer tracks a slot
            if d_can:
                reg_slot.pop(d_can,None)
                # if dest is now an independent value, also it doesn't alias slot
                continue
        w=_writes_reg_canons(c)
        if w is None:
            reg_slot.clear()
        else:
            for r in w:
                if r: reg_slot.pop(r,None)
    if not drop:
        return seg, codes
    seg2=[ln for k,ln in enumerate(seg) if k not in drop]
    codes2=[c for k,c in enumerate(codes) if k not in drop]
    return seg2, codes2

def _p_dead_store(seg, codes):
    # Remove a param spill `mov [rbp±K], R` whose slot is never read afterwards
    # (a read = the slot text appears as a source anywhere later in the fn).
    # Compute, per slot, whether any later line mentions it outside its own
    # store dest. Conservative: a store to the slot does not count as a read.
    n=len(codes)
    drop=set()
    for idx,c in enumerate(codes):
        m=_MOV2_RE.match(c)
        if not m: continue
        dest=m.group(1).strip(); src=m.group(2).strip()
        if not (_RBP_SLOT_ONLY_RE.match(dest) and _canon(src)):
            continue
        slot_txt=dest                            # e.g. "[rbp-8]"
        read=False
        for k in range(idx+1,n):
            ck=codes[k]
            if slot_txt in ck:
                mk=_MOV2_RE.match(ck)
                # a later store to the SAME slot overwrites it; stop scanning
                if mk and mk.group(1).strip()==slot_txt:
                    break
                read=True; break
        if not read:
            drop.add(idx)
    if not drop:
        return seg, codes
    seg2=[ln for k,ln in enumerate(seg) if k not in drop]
    codes2=[c for k,c in enumerate(codes) if k not in drop]
    return seg2, codes2

def _body_codes(codes):
    # Indices of the function body: between the prologue (after the last of
    # push rbp / mov rbp,rsp / sub rsp / spills / push rbx / push r12) and the
    # epilogue (the .fn_end label). Returns (lo, hi) exclusive-hi over codes, or
    # None if the standard shape isn't found.
    try:
        p_rbp=codes.index("push rbp")
    except ValueError:
        return None
    lo=p_rbp+1
    # skip mov rbp,rsp / sub rsp / spills / push rbx / push r12
    while lo<len(codes) and (codes[lo]=="mov rbp, rsp"
            or codes[lo].startswith("sub rsp,")
            or codes[lo] in ("push rbx","push r12")
            or (_MOV2_RE.match(codes[lo]) and _RBP_SLOT_ONLY_RE.match(
                    _MOV2_RE.match(codes[lo]).group(1).strip()))):
        lo+=1
    # epilogue label = first line ending ':' that starts with '.fn_end'
    hi=None
    for k in range(lo,len(codes)):
        if codes[k].startswith(".fn_end") and codes[k].endswith(":"):
            hi=k; break
    if hi is None:
        return None
    return (lo,hi)

def _p_dead_callee_save(seg, codes):
    # Drop `push rbx`/`push r12` (prologue) + matching `pop r12`/`pop rbx`
    # (epilogue) if the body never names that register at any width.
    body=_body_codes(codes)
    if body is None: return seg, codes
    lo,hi=body
    bodytext=" ".join(codes[lo:hi])
    def used(canon):
        for spell,(c,_w) in REG_TABLE.items():
            if c==canon and re.search(r"\b"+re.escape(spell)+r"\b", bodytext):
                return True
        return False
    drop=set()
    if not used("rbx"):
        for k,c in enumerate(codes):
            if c in ("push rbx","pop rbx"): drop.add(k)
    if not used("r12"):
        for k,c in enumerate(codes):
            if c in ("push r12","pop r12"): drop.add(k)
    if not drop: return seg, codes
    seg2=[ln for k,ln in enumerate(seg) if k not in drop]
    codes2=[c for k,c in enumerate(codes) if k not in drop]
    return seg2, codes2

def _p_jmp_to_next(seg, codes):
    # Drop `jmp L` when the immediately following code line is `L:`.
    drop=set()
    for k in range(len(codes)-1):
        c=codes[k]
        if c.startswith("jmp ") and codes[k+1].endswith(":"):
            tgt=c[4:].strip()
            if codes[k+1][:-1].strip()==tgt:
                drop.add(k)
    if not drop: return seg, codes
    seg2=[ln for k,ln in enumerate(seg) if k not in drop]
    codes2=[c for k,c in enumerate(codes) if k not in drop]
    return seg2, codes2

def _p_frame(seg, codes, addr_of_frame):
    # Two levels of frame trimming, both alignment-safe:
    #   (1) if no [rbp-...] local/spill slot is referenced anywhere, the `sub rsp,N`
    #       reserved only dead space -> remove it (rbp frame kept, so any inner
    #       call stays 16-byte aligned: push rbp made rsp%16==0).
    #   (2) additionally, if the body has no call / push / pop and no rbp/rsp
    #       reference at all, the whole frame is dead -> remove push rbp / mov
    #       rbp,rsp and the epilogue mov rsp,rbp / pop rbp. (No call means no ABI
    #       alignment obligation; syscall does not require 16-byte alignment.)
    if addr_of_frame:
        return seg, codes
    body=_body_codes(codes)
    if body is None: return seg, codes
    lo,hi=body
    has_neg_slot=any(_RBP_SLOT_RE.search(c) and "[rbp-" in c for c in codes)
    drop=set()
    if not has_neg_slot:
        for k,c in enumerate(codes):
            if c.startswith("sub rsp,"): drop.add(k)
    # level 2
    bodytext=codes[lo:hi]
    has_call=any(c.startswith(("call ","FN_CALL")) or c=="call" or c.startswith("call_table")
                 for c in bodytext)
    has_stack=any(c.startswith(("push ","pop ")) for c in bodytext)
    has_rbp_any=any("rbp" in c for c in bodytext) or any("rbp" in c for c in
                    [codes[i] for i in range(hi,len(codes))
                     if not codes[i].startswith(("mov rsp, rbp","pop rbp"))])
    if (not has_call) and (not has_stack) and (not has_rbp_any) and (not has_neg_slot):
        for k,c in enumerate(codes):
            if c in ("push rbp","mov rbp, rsp","mov rsp, rbp","pop rbp"):
                drop.add(k)
    if not drop: return seg, codes
    seg2=[ln for k,ln in enumerate(seg) if k not in drop]
    codes2=[c for k,c in enumerate(codes) if k not in drop]
    return seg2, codes2

def _opt_one_fn(seg):
    codes=[_code(l).strip() for l in seg]
    addr_of_frame=_opt_fn_uses_addr_of_frame(codes)
    # jmp-to-next is local control-flow cleanup. Keep the default rbx/r12 save
    # pair in user functions: the app/kernel syscall boundary and older shared
    # app helpers do not form a strict SysV-only call graph, and O0's save pair
    # is the compatibility bracket that keeps app callbacks from leaking
    # callee-saved corruption back into the kernel scheduler.
    seg,codes=_p_jmp_to_next(seg,codes)
    if not addr_of_frame:
        seg,codes=_p_value_forward(seg,codes)
        seg,codes=_p_dead_store(seg,codes)
    seg,codes=_p_frame(seg,codes,addr_of_frame)
    return seg

def _optimize_functions(lines, target):
    # Per-function lossless cleanup. Restricted to the user target, whose
    # gen_fn shape this matches; kernel/boot codegen (naked fns, custom ABIs)
    # is left untouched.
    if target!="user":
        return lines
    out=[]
    for is_fn,chunk in _fn_segments(lines):
        out.extend(_opt_one_fn(chunk) if is_fn else chunk)
    return out

# -------------------- Phase 2: register allocator (--O2, lossless) -----------
# Phase 1 only removes dead scaffolding; the surviving body still round-trips
# every `let` local and every register-param through its `[rbp-N]` home slot on
# every read and write (the naive stack-machine emitter). Phase 2 promotes such
# a home slot into a *callee-saved* GPR for the whole function so the value
# stays live in a register across its entire range - the real path toward
# hand-written-asm density on compute-heavy bodies.
#
# It is allowlist/conservative exactly like the Phase-1 passes: a slot is
# promoted ONLY when every property below is PROVEN; anything unproven leaves
# the slot on its memory home (never a miscompile, only a missed shrink).
#
# Safety contract for a promoted negative slot S -> callee-saved reg R:
#   * USER target only (System-V AMD64 ABI; rbp frame shape from gen_fn).
#   * Control flow is allowed (if/while/loops/multiple returns): promotion is
#     WHOLE-FUNCTION and rewrites every access to S 1:1 into R, so R's read/write
#     trace is identical to S's on every path and the slot's memory is fully
#     dead - merge points and back-edges cannot make them disagree. The only
#     control-flow construct rejected is an INDIRECT branch/call (target not a
#     visible label); see _o2_control_flow_ok. Additionally, a real
#     definite-assignment dataflow over the function CFG must PROVE every read of
#     S is preceded by a store on all paths (so the register is never read before
#     defined); see _o2_build_cfg / _o2_slot_definitely_assigned.
#   * The function does not take the address of any frame slot, nor use any
#     indexed/odd rbp form (_opt_fn_uses_addr_of_frame) - no aliasing writer can
#     touch S through a pointer.
#   * S is referenced ONLY as a whole, plain `[rbp-K]` operand of a 2-operand
#     `mov`, paired with a *64-bit canonical* register (or as a `mov` between S
#     and a 64-bit reg). Never sub-width, never inside lea/test/cmp/arith,
#     never as part of a larger addressing expression. (gen_fn always spills /
#     reloads whole 8-byte slots, so this is the common shape.)
#   * R is a callee-saved GPR (rbx, r12, r13, r14, r15) that the body never
#     mentions at any width AND that is not already push/pop-saved. Each R we
#     actually use is push/pop-saved in prologue/epilogue, so the ABI's
#     callee-saved discipline is preserved.
#   * Only NEGATIVE slots are eligible. `[rbp+K]` are inbound stack arguments
#     (params 6+) living in the caller's frame; they are read in place and must
#     never be turned into a private register.
#
# Because R is callee-saved it survives `call`/`syscall`, so a value living in
# R across a call needs no extra spill. We do NOT change `sub rsp,N` / the rbp
# frame, so 16-byte call alignment is untouched (push rbp already aligned it,
# and each added push R is balanced by its pop R before the epilogue).

_O2_CALLEE_SAVED=["rbx","r12","r13","r14","r15"]
# All register spellings (any width) that map to a given canonical 64-bit reg,
# for the "body never mentions R" freedom test.
def _spellings_for_canon(canon):
    return [sp for sp,(c,_w) in REG_TABLE.items() if c==canon]

_NEG_SLOT_RE=re.compile(r"^\[rbp-\d+\]$")

def _o2_collect_neg_slots(text):
    return set(re.findall(r"\[rbp-\d+\]", text))

def _o2_slot_only_plain_mov(slot, codes_body):
    # Prove `slot` appears only as a whole operand of a 2-operand mov, paired
    # with a 64-bit canonical register. Returns False at the first violation.
    for c in codes_body:
        if slot not in c:
            continue
        m=_MOV2_RE.match(c)
        if not m:
            return False            # appears in non-mov (lea/cmp/add/...) -> bail
        dest=m.group(1).strip(); src=m.group(2).strip()
        if dest==slot:
            # store: mov [slot], R64  - src must be a 64-bit canonical reg
            if not _canon(src) or REG_TABLE.get(src.strip(),(None,0))[1]!=64:
                return False
        elif src==slot:
            # reload: mov R64, [slot] - dest must be a 64-bit canonical reg
            if not _canon(dest) or REG_TABLE.get(dest.strip(),(None,0))[1]!=64:
                return False
        else:
            # slot text occurs but not as a whole operand (indexed/substring) -> bail
            return False
    return True

_O2_INDIRECT_RE=re.compile(r"^(jmp|call)\s+(\[|r[a-z0-9]+\b|e[a-z]{2}\b)")

def _o2_control_flow_ok(codes, lo, hi):
    # Cross-basic-block allocation is sound for WHOLE-FUNCTION promotion: every
    # access to the slot is rewritten 1:1 to the register, so the register's
    # read/write trace is identical to the slot's on EVERY path - merge points,
    # loop back-edges and multiple returns cannot make them disagree (the slot's
    # memory becomes entirely dead). The single thing that genuinely breaks this
    # is an INDIRECT branch/call (`jmp rax`, `call [rcx]`): its target is not a
    # visible label, so we cannot bound where control re-enters and the
    # "register never touched except by our movs" reasoning no longer holds by
    # inspection. User codegen never emits those (call_table is kernel-only), so
    # bail conservatively if one appears. Plain `jXX label` / labels are fine.
    for k in range(lo,hi):
        if _O2_INDIRECT_RE.match(codes[k]):
            return False
    return True

_O2_JUMP_MNEMS={"jmp","je","jz","jne","jnz","ja","jae","jb","jbe","jg","jge",
                "jl","jle","jc","jnc","jo","jno","js","jns","loop","loope","loopne"}

def _o2_slot_kind(code, slot):
    # 'store' (mov [slot], R), 'read' (mov R, [slot]), or None. Assumes the slot
    # has already passed _o2_slot_only_plain_mov so it appears only in these two
    # whole-operand mov forms.
    if slot not in code:
        return None
    m=_MOV2_RE.match(code)
    if not m:
        return None
    return "store" if m.group(1).strip()==slot else "read"

def _o2_build_cfg(codes):
    # Build a basic-block CFG over the function's instruction list. Returns
    # (blocks, idx2blk, preds) where blocks=[(start,end)] index ranges, idx2blk
    # maps an instruction index to its block id, and preds[bid]=set of predecessor
    # block ids. Returns None if any jump target label is unresolved (bail).
    # Leaders: index 0, every label line, and every line after a jump/ret.
    n=len(codes)
    if n==0:
        return None
    labels={}
    leader=[False]*n
    leader[0]=True
    for i,c in enumerate(codes):
        if c.endswith(":"):
            labels[c[:-1].strip()]=i
            leader[i]=True
        mnem=c.split(None,1)[0] if c else ""
        if (mnem in _O2_JUMP_MNEMS or mnem=="ret") and i+1<n:
            leader[i+1]=True
    starts=[i for i in range(n) if leader[i]]
    blocks=[]
    idx2blk=[0]*n
    for b,s in enumerate(starts):
        e=starts[b+1] if b+1<len(starts) else n
        blocks.append((s,e))
        for k in range(s,e):
            idx2blk[k]=b
    succ=[set() for _ in blocks]
    for b,(s,e) in enumerate(blocks):
        term=codes[e-1]
        mnem=term.split(None,1)[0] if term else ""
        if mnem=="ret":
            continue
        if mnem in _O2_JUMP_MNEMS:
            parts=term.split(None,1)
            tgt=parts[1].strip() if len(parts)>1 else ""
            if tgt not in labels:
                return None                      # unresolved/indirect target -> bail
            succ[b].add(idx2blk[labels[tgt]])
            if mnem!="jmp" and e<n:              # conditional: also fall through
                succ[b].add(idx2blk[e])
        else:
            if e<n:
                succ[b].add(idx2blk[e])          # straight-line fall-through
    preds=[set() for _ in blocks]
    for b in range(len(blocks)):
        for t in succ[b]:
            preds[t].add(b)
    return blocks, idx2blk, preds

def _o2_slot_definitely_assigned(slot, codes, cfg):
    # Real definite-assignment dataflow: PROVE that on every path from function
    # entry to each READ of `slot`, a STORE to it executes first. If so, the
    # promoted register is never read before it is defined and whole-function
    # promotion is fully sound across arbitrary (reducible) control flow -
    # top-level `let`s initialised after an earlier branch, and both-branches-
    # store-then-read-at-merge, both qualify; a genuine use-before-def (a `let`
    # stored in one branch and read from a sibling) is correctly rejected.
    #
    # Forward MUST analysis (AND/intersection over predecessors):
    #   in[B]  = AND over preds P of out[P]      (in[entry]=False, no preds)
    #   out[B] = in[B] OR (B contains a store to slot)
    # A read at index r in block B is definitely assigned iff there is a store in
    # B strictly before r, OR in[B] is True.
    blocks, idx2blk, preds = cfg
    nb=len(blocks)
    has_store=[False]*nb
    for b,(s,e) in enumerate(blocks):
        for k in range(s,e):
            if _o2_slot_kind(codes[k],slot)=="store":
                has_store[b]=True; break
    out=[True]*nb                                # optimistic top for intersection
    entry=idx2blk[0]
    changed=True
    while changed:
        changed=False
        for b in range(nb):
            if b==entry:
                inb=False
            elif preds[b]:
                inb=all(out[p] for p in preds[b])
            else:
                inb=False                        # unreachable-from-entry: be safe
            nout=inb or has_store[b]
            if nout!=out[b]:
                out[b]=nout; changed=True
    # recompute in[] for the read check (cheap, one pass)
    def in_of(b):
        if b==entry or not preds[b]:
            return False
        return all(out[p] for p in preds[b])
    for b,(s,e) in enumerate(blocks):
        stored_before=False
        for k in range(s,e):
            kind=_o2_slot_kind(codes[k],slot)
            if kind=="read" and not (stored_before or in_of(b)):
                return False                     # read before any store on some path
            if kind=="store":
                stored_before=True
    return True

def _o2_reg_free_in_body(canon, codes, lo, hi):
    # Body never mentions any width-spelling of `canon`.
    bodytext=" ".join(codes[lo:hi])
    for sp in _spellings_for_canon(canon):
        if re.search(r"\b"+re.escape(sp)+r"\b", bodytext):
            return False
    return True

def _o2_fn_name(seg):
    # The function's label name from its FN_BEGIN marker, or None.
    for l in seg:
        c=_code(l).strip()
        if c.startswith("FN_BEGIN "):
            return c.split(None,1)[1].split(",",1)[0].strip()
    return None

def _o2_is_leaf(codes, lo, hi):
    for c in codes[lo:hi]:
        if (c.startswith(("call ","FN_CALL","call_table")) or c=="call"
                or c.startswith(("syscall","APP_SYSNO"))):
            return False
    return True

def _o2_preserved_regs(seg):
    # For a LEAF same-unit function (final, post-regalloc text): the set of
    # callee-saved regs it provably preserves. A reg is preserved if the
    # segment push/pop-brackets it, or if no spelling of it appears anywhere
    # in the segment (a leaf cannot clobber a reg it never names).
    codes=[_code(l).strip() for l in seg]
    text=" ".join(codes)
    preserved=set()
    for r in _O2_CALLEE_SAVED:
        if f"push {r}" in codes and f"pop {r}" in codes:
            preserved.add(r); continue
        if not any(re.search(r"\b"+re.escape(sp)+r"\b", text)
                   for sp in _spellings_for_canon(r)):
            preserved.add(r)
    return preserved

def _regalloc_one_fn(seg, safe_callees=None):
    codes=[_code(l).strip() for l in seg]
    if _opt_fn_uses_addr_of_frame(codes):
        return seg
    body=_body_codes(codes)
    if body is None:
        return seg
    lo,hi=body
    if not _o2_control_flow_ok(codes, lo, hi):
        return seg
    # SOUNDNESS GATE (leaf-only promotion): a slot promoted into a callee-saved
    # GPR is only safe if that register is guaranteed intact across the slot's
    # whole live range. Two GritOS realities break the textbook "callee-saved
    # survives a call" assumption:
    #   * a `syscall` is NOT a System-V boundary - the kernel dispatcher reuses
    #     GPRs and clobbers rbx/rbp across the entry (see syscall_entry notes);
    #   * GHL callees only bracket rbx/r12 (the compatibility save pair); they
    #     freely clobber r13/r14/r15, and hand-asm helpers may clobber any reg.
    # Rather than prove per-callee preservation, restrict promotion to LEAF
    # regions: if the body contains any call/syscall, skip regalloc for this
    # function. Then no promoted value ever crosses an ABI boundary, so the
    # promotion is sound regardless of callee register behavior. Compute-heavy
    # leaf bodies (the intended target) still benefit; call-laden syscall
    # wrappers are already shrunk by Phase 1.
    #
    # GATE EXTENSION (same-unit leaf callees): a body containing direct `call`s
    # is also eligible when EVERY call targets a same-unit GHL LEAF function
    # whose final emitted text provably preserves a known set of callee-saved
    # regs (push/pop-bracketed, or never named anywhere in the leaf - a leaf
    # cannot clobber a reg it never names). Promotion candidates are then
    # restricted to the intersection of all callees' preserved sets. syscall /
    # APP_SYSNO / indirect / extern / non-leaf targets still bail.
    allowed_regs=set(_O2_CALLEE_SAVED)
    for c in codes[lo:hi]:
        if c.startswith(("syscall","APP_SYSNO","call_table")) or c=="call":
            return seg
        if c.startswith(("call ","FN_CALL ")):
            # `call name` / `FN_CALL name, argc` - FN_CALL is a pure compile-
            # time argc check followed by `call name` (src/include/trace.inc).
            tgt=c.split(None,1)[1].split(",",1)[0].strip()
            pres=(safe_callees or {}).get(tgt)
            if not pres:
                return seg              # extern / non-leaf / unknown callee
            allowed_regs&=pres
            if not allowed_regs:
                return seg              # no commonly-preserved reg left
    # Promotable negative slots referenced anywhere in the segment. The prologue
    # spill `mov [rbp-K], <call_reg>` sits before `lo`; include the whole
    # segment when proving the plain-mov property and when rewriting.
    whole=codes
    slots=sorted(_o2_collect_neg_slots(" ".join(whole)),
                 key=lambda s:int(re.search(r"-(\d+)",s).group(1)))
    if not slots:
        return seg
    # Determine which callee-saved regs are already saved (Phase-1 may have
    # dropped the default push rbx/r12) so we never double-allocate one.
    already_saved=set()
    for c in codes:
        if c.startswith("push "):
            r=_canon(c.split(None,1)[1])
            if r in _O2_CALLEE_SAVED: already_saved.add(r)
    promote={}                      # slot -> chosen callee-saved reg
    used_regs=set(already_saved)
    cfg=_o2_build_cfg(whole)
    if cfg is None:
        return seg                  # unresolved control flow: don't risk it
    for slot in slots:
        if not _o2_slot_only_plain_mov(slot, whole):
            continue                # leave this slot on its memory home
        if not _o2_slot_definitely_assigned(slot, whole, cfg):
            continue                # read-before-store on some path: keep on memory
        # find a free callee-saved reg
        chosen=None
        for r in _O2_CALLEE_SAVED:
            if r not in allowed_regs: continue
            if r in used_regs: continue
            if not _o2_reg_free_in_body(r, codes, lo, hi): continue
            chosen=r; break
        if chosen is None:
            continue                # out of registers -> memory fallback
        promote[slot]=chosen
        used_regs.add(chosen)
    if not promote:
        return seg
    new_saves=[r for r in _O2_CALLEE_SAVED if r in used_regs and r not in already_saved]
    # Locate the prologue boundary in the ORIGINAL segment: the index just past
    # the last of `mov rbp, rsp` / `sub rsp,N` / existing `push rbx`/`push r12` /
    # any param-spill store. Everything from `push rbp` up to and including that
    # is the prologue; the body follows. We need a clean boundary so we can
    # insert our `push R` BEFORE any rewritten promoted spill (`mov R, <argreg>`)
    # - otherwise we'd push the parameter value, not the caller's R, and the
    # epilogue would restore the wrong value.
    # Walk the prologue from `push rbp` forward, consuming only the recognized
    # prologue instruction shapes; stop at the first line that isn't one (= body
    # start). This must NOT keep scanning into the body, or a body store like
    # `mov [rbp-16], rax` would wrongly extend the prologue.
    try:
        p_rbp=[i for i,l in enumerate(seg) if _code(l).strip()=="push rbp"][0]
    except IndexError:
        return seg
    # Split the prologue into two parts so our `push R` lands between them:
    #   frame_end  = past `push rbp`/`mov rbp,rsp`/`sub rsp,N`/existing push
    #                rbx/r12  (the callee-save region)
    #   spill_end  = additionally past any param-spill stores (`mov [rbp-K], R`)
    # Our `push R` MUST precede any rewritten promoted spill (`mov R, <argreg>`),
    # or we'd push the parameter value instead of the caller's R and the epilogue
    # would restore the wrong value into R.
    frame_end=p_rbp; idx=p_rbp+1
    while idx<len(seg):
        c=_code(seg[idx]).strip()
        if c=="mov rbp, rsp" or c.startswith("sub rsp,") or c in ("push rbx","push r12"):
            frame_end=idx; idx+=1; continue
        break
    spill_end=frame_end
    while idx<len(seg):
        c=_code(seg[idx]).strip()
        m=_MOV2_RE.match(c) if c.startswith("mov ") else None
        if m and _RBP_SLOT_ONLY_RE.match(m.group(1).strip()):
            spill_end=idx; idx+=1; continue       # param spill store
        break
    # Rewrite the slot movs (store/reload) to register movs everywhere, dropping
    # any that become `mov R, R`. Provenance comments ride along.
    def rewrite(ln):
        c=_code(ln); cmt=_comment(ln); cs=c.strip()
        m=_MOV2_RE.match(cs)
        if m:
            dest=m.group(1).strip(); src=m.group(2).strip()
            if dest in promote:
                r=promote[dest]
                return None if r==src else f"    mov {r}, {src}{cmt}"
            if src in promote:
                r=promote[src]
                return None if dest==r else f"    mov {dest}, {r}{cmt}"
        return ln
    def rewrite_all(chunk):
        out=[]
        for ln in chunk:
            rw=rewrite(ln)
            if rw is not None: out.append(rw)
        return out
    frame   = rewrite_all(seg[:frame_end+1])
    spills  = rewrite_all(seg[frame_end+1:spill_end+1])
    body    = rewrite_all(seg[spill_end+1:])
    if not new_saves:
        return frame+spills+body
    # Stack discipline: `push R` sits right after the frame's callee-save region
    # (before the rewritten spills, so caller's R is saved first); the matching
    # `pop R` goes in the epilogue right before `mov rsp, rbp`. The total number
    # of callee pushes after `mov rbp, rsp` must stay EVEN so every body-level
    # `call`/`syscall` is 16-byte aligned (push rbp made rsp%16==0; sub rsp,N
    # keeps it; an even push count keeps it). Pad with a balanced `sub rsp,8`/
    # `add rsp,8` when odd - no register cost, alignment preserved.
    total_callee=len(already_saved)+len(new_saves)
    odd=(total_callee%2)!=0
    push_lines=[f"    push {r}" for r in new_saves]
    if odd: push_lines.append("    sub rsp, 8")
    pop_lines=[]
    if odd: pop_lines.append("    add rsp, 8")
    pop_lines+=[f"    pop {r}" for r in reversed(new_saves)]
    # find `mov rsp, rbp` in the body to anchor the pops
    pops_at=None
    for idx,ln in enumerate(body):
        if _code(ln).strip()=="mov rsp, rbp":
            pops_at=idx; break
    if pops_at is None:
        return frame+spills+body        # unexpected shape: ship rewrite w/o saves
    body=body[:pops_at]+pop_lines+body[pops_at:]
    return frame+push_lines+spills+body

def _regalloc_functions(lines, target):
    if target!="user":
        return lines
    # Pass 1: regalloc every function under the base (leaf-only) gate. Collect
    # the FINAL text of each same-unit leaf fn so pass 2 can prove which
    # callee-saved regs each one preserves.
    segs=[]
    for is_fn,chunk in _fn_segments(lines):
        segs.append((is_fn, _regalloc_one_fn(chunk) if is_fn else chunk))
    safe_callees={}
    for is_fn,chunk in segs:
        if not is_fn: continue
        name=_o2_fn_name(chunk)
        if not name: continue
        codes=[_code(l).strip() for l in chunk]
        body=_body_codes(codes)
        if body is None: continue
        lo,hi=body
        if _o2_is_leaf(codes, lo, hi):
            pres=_o2_preserved_regs(chunk)
            if pres: safe_callees[name]=pres
    # Pass 2: retry the call-containing fns (pass 1 left them unchanged) now
    # that callee preservation facts are known. Leaf fns are already done.
    out=[]
    for is_fn,chunk in segs:
        if is_fn:
            codes=[_code(l).strip() for l in chunk]
            body=_body_codes(codes)
            if body is not None and not _o2_is_leaf(codes,*body):
                chunk=_regalloc_one_fn(chunk, safe_callees)
        out.extend(chunk)
    return out

def _contains_asm_stmt(stmts):
    for st in stmts:
        if st.get("k")=="asm":
            return True
        if st.get("k")=="if":
            if _contains_asm_stmt(st.get("then") or []):
                return True
            if _contains_asm_stmt(st.get("els") or []):
                return True
        elif st.get("k")=="while":
            if _contains_asm_stmt(st.get("body") or []):
                return True
    return False

def _enforce_no_asm(decls, why):
    offenders=[]
    for d in decls:
        if d.get("k")=="fn" and _contains_asm_stmt(d.get("body") or []):
            offenders.append(f"{d.get('name','<fn>')}:{d.get('line','?')}")
    if offenders:
        names=", ".join(offenders[:8])
        more="" if len(offenders)<=8 else f" (+{len(offenders)-8} more)"
        raise SyntaxError(f"{why}: inline asm is forbidden in {names}{more}")

_VALID_UNSAFE_CAPS={
    "raw_mem",
    "implicit_extern",
    "boot_call",
    "boot_int",
    "boot_io",
    "boot_lgdt",
    "kernel_priv",
    "kernel_io",
    "kernel_int",
    # Exact-authority kernel caps (ghl-beyond-zero-trust-todo.md "Split unsafe
    # capabilities by exact authority instead of broad categories"). Each names a
    # single privileged hardware authority so a security module can declare only
    # what it touches instead of the broad `kernel_priv`. The broad `kernel_priv`
    # remains a SUPERSET that satisfies any of these (see _require_cap), so legacy
    # modules that already declare it keep compiling unchanged.
    "kernel_creg",     # control-register writes (write_cr0 / write_cr4)
    "kernel_pgtable",  # page-table / TLB authority (write_cr3, invlpg)
    "kernel_dtable",   # descriptor-table loads (lgdt, ltr)
    "kernel_idtable",  # interrupt-table loads (lidt)
}

# Narrow kernel caps that the broad `kernel_priv` is allowed to stand in for, so
# splitting an intrinsic off kernel_priv does not break modules that still
# declare the broad cap.
_KERNEL_PRIV_SUBSUMES={
    "kernel_creg","kernel_pgtable","kernel_dtable","kernel_idtable",
}

def _require_cap(cg, cap, what):
    caps=getattr(cg,"unsafe_caps",set())
    if cap in caps:
        return
    # The broad kernel_priv authority subsumes the narrow exact-authority caps.
    if cap in _KERNEL_PRIV_SUBSUMES and "kernel_priv" in caps:
        return
    raise SyntaxError(f"{what} requires `unsafe {cap};`")

def compile_unit(decls,app_prefix,embed=False,kernel=False,src=None,target="user",forbid_asm=False,deny_unsafe=False,optimize=True,regalloc=False):
    global LAST_SIGS
    if forbid_asm:
        _enforce_no_asm(decls, "--forbid-asm")
    if target=="boot":
        _enforce_no_asm(decls, "--target boot")
    declared_caps=[d for d in decls if d.get("k")=="unsafe"]
    for d in declared_caps:
        if d["cap"] not in _VALID_UNSAFE_CAPS:
            raise SyntaxError(f"unsafe {d['cap']}: unknown capability")
    if deny_unsafe and declared_caps:
        caps=", ".join(d["cap"] for d in declared_caps[:8])
        raise SyntaxError(f"--deny-unsafe rejects unsafe capability declarations: {caps}")
    cg=CG(app_prefix,kernel=kernel)
    cg.deny_unsafe=deny_unsafe
    cg.unsafe_caps={d["cap"] for d in declared_caps}
    cg.embed=embed
    cg.src=src
    cg.target=target
    # Source-line provenance is kernel-only: it is pure NASM comments (zero
    # machine-code cost), but gating it to kernel mode guarantees the ring-3
    # app blobs + their MAC signatures stay byte-identical and keeps the
    # traceability where it matters - ring-0 debugging.
    cg.srcmap=kernel and (src is not None)
    app_meta={"name":app_prefix,"stack":4096}
    boot_bits=None
    boot_org=None
    # collect top-level
    str_defs={}
    for d in decls:
        if d["k"]=="unsafe":
            continue
        if d["k"]=="app":
            if kernel:
                raise SyntaxError("`app` declaration is not allowed in a kernel module (--target kernel); use `module`")
            app_meta["name"]=d["name"]; app_meta["stack"]=d["stack"]
        elif d["k"]=="module":
            if not kernel:
                raise SyntaxError("`module` declaration requires --target kernel or --target boot")
            app_meta["name"]=d["name"]
        elif d["k"]=="global":
            if not kernel:
                raise SyntaxError("`global` declaration requires --target kernel or --target boot")
            cg.globals.add(d["name"])
        elif d["k"]=="strdef":
            lbl=f"{app_prefix}_{d['name']}"
            cg.str_lbls[d["val"]]=lbl
            cg.rodata.append(f"{lbl}: " + _emit_db_bytes(d["val"]))
            str_defs[d["name"]]=lbl
        elif d["k"]=="const":
            if d.get("symbolic"):
                cg.symconsts.add(d["name"])
            else:
                cg.consts[d["name"]]=d["val"]
        elif d["k"]=="extern":
            cg.externs.add(d["name"])
        elif d["k"]=="data":
            if not kernel:
                raise SyntaxError("`data` declaration requires --target kernel or --target boot")
            nm=d["name"]
            cg.state_defs[nm]=nm          # exact, unprefixed name
            if "strval" in d:
                raw=d["strval"].encode("utf-8")
                parts=", ".join(str(b) for b in raw)
                cg.data.append(f"{nm}: db {parts}, 0" if raw else f"{nm}: db 0")
                cg.state_sizes[nm]=len(raw)+1
                cg.state_widths[nm]=1
                continue
            def _resolve_term(t):
                if t[0]=="num": return t[1]
                n=t[1]
                if n in cg.consts: return cg.consts[n]
                if n in cg.table_counts: return cg.table_counts[n]
                raise SyntaxError(f"data {nm}: unknown size term {n!r}")
            count=1
            for f in d["factors"]:
                count*=_resolve_term(f)
            w=d["width"]
            if w not in (1,2,4,8):
                raise SyntaxError(f"data {nm}: width must be 1/2/4/8, got {w}")
            if count<=0:
                raise SyntaxError(f"data {nm}: size must be positive")
            iv=d["init"]
            if iv["k"]=="int":
                initval=iv["val"]
            elif iv["k"]=="ident" and iv["name"] in cg.consts:
                initval=cg.consts[iv["name"]]
            elif iv["k"]=="list":
                vals=[]
                for item in iv["vals"]:
                    if isinstance(item, tuple):
                        _tag, cn, neg = item
                        if cn not in cg.consts:
                            raise SyntaxError(f"data {nm}: unknown const {cn!r} in initializer")
                        cv = cg.consts[cn]
                        if not isinstance(cv, int):
                            raise SyntaxError(f"data {nm}: non-integer const {cn!r} in initializer")
                        vals.append(-cv if neg else cv)
                    else:
                        vals.append(item)
                if len(vals) > count:
                    raise SyntaxError(f"data {nm}: initializer has {len(vals)} values for {count} slots")
                directive={1:"db",2:"dw",4:"dd",8:"dq"}[w]
                if vals:
                    cg.data.append(f"{nm}: {directive} " + ", ".join(str(v) for v in vals))
                else:
                    cg.data.append(f"{nm}:")
                if len(vals) < count:
                    cg.data.append(f"    times {count - len(vals)} {directive} 0")
                cg.state_sizes[nm]=count*w
                cg.state_widths[nm]=w
                continue
            else:
                raise SyntaxError(f"data {nm}: init must be a number or const")
            directive={1:"db",2:"dw",4:"dd",8:"dq"}[w]
            cg.data.append(f"{nm}: times {count} {directive} {initval}")
            cg.state_sizes[nm]=count*w     # byte size for bounds checks
            cg.state_widths[nm]=w
        elif d["k"]=="align":
            if not kernel:
                raise SyntaxError("`align` declaration requires --target kernel or --target boot")
            cg.data.append(f"align {d['n']}")
        elif d["k"]=="pad_to":
            if target!="boot":
                raise SyntaxError("`pad_to` declaration requires --target boot")
            if d["n"] <= 0:
                raise SyntaxError("pad_to target must be positive")
            if d["fill"] < 0 or d["fill"] > 255:
                raise SyntaxError("pad_to fill byte must be 0..255")
            cg.data.append(f"times 0x{d['n']:X} - ($ - $$) db 0x{d['fill']:02X}")
        elif d["k"]=="boot_signature":
            if target!="boot":
                raise SyntaxError("`boot_signature` declaration requires --target boot")
            cg.data.append("dw 0xAA55")
        elif d["k"]=="bits":
            if target!="boot":
                raise SyntaxError("`bits` declaration requires --target boot")
            if d["n"] not in (16,32,64):
                raise SyntaxError(f"bits must be 16, 32, or 64, got {d['n']}")
            boot_bits=d["n"]
        elif d["k"]=="org":
            if target!="boot":
                raise SyntaxError("`org` declaration requires --target boot")
            if boot_org is not None:
                raise SyntaxError("only one `org` declaration is allowed")
            boot_org=d["val"]
        elif d["k"]=="table":
            if not kernel:
                raise SyntaxError("`table` declaration requires --target kernel or --target boot")
            nm=d["name"]; entries=d["entries"]
            if not entries:
                raise SyntaxError(f"table {nm}: must have at least one entry")
            cg.table_counts[nm]=len(entries)
            cg.consts[nm+"_count"]=len(entries)   # usable in `data` size exprs
            cg.data.append(f"{nm}: dq " + ", ".join(entries))
        elif d["k"]=="state":
            for nm,sz in d["fields"]:
                if sz <= 0:
                    raise SyntaxError(f"state {nm}: size must be positive")
                lbl=f"{app_prefix}_{nm}"
                cg.state_defs[nm]=lbl
                cg.state_sizes[nm]=sz
                cg.state_widths[nm]=1
                cg.data.append(f"{lbl}: times {sz} db 0")
    cg.str_defs=str_defs
    # collect local fn names (so calls resolve to prefixed symbols)
    cg.local_fns={d["name"] for d in decls if d["k"]=="fn"}
    cg.fn_argc={d["name"]:len(d["params"]) for d in decls if d["k"]=="fn"}
    if target=="boot":
        cg.boot_bits=boot_bits or 64
    # functions
    for d in decls:
        if d["k"]=="fn":
            if target=="boot":
                gen_boot_fn(cg,d)
            elif kernel:
                gen_kernel_fn(cg,d)
            else:
                gen_fn(cg,d,app_prefix)
    # Out-of-bounds trap stub (emitted once, only if referenced by a checked
    # index). `ud2` raises #UD - an unforgeable, non-resumable fault - so a
    # state-buffer bounds violation halts at the faulting site instead of
    # writing past the buffer into adjacent memory.
    if cg.need_oob:
        cg.emit(f"{cg.prefix}_ghlk_oob:")
        cg.emit("    ud2")
    # assemble output
    out=[]
    out.append(f"; GritHL generated - do not edit by hand")
    if kernel:
        out.append(f'; module="{app_meta["name"]}" target={target}')
    else:
        out.append(f'; app="{app_meta["name"]}" stack={app_meta["stack"]}')
    if target=="boot":
        out.append(f"bits {boot_bits or 64}")
        if boot_org is not None:
            out.append(f"org 0x{boot_org:X}")
        if boot_bits in (None,64):
            out.append("default rel")
    elif not embed and not kernel:
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
            if g in cg.fnbegin_emitted:
                continue   # FN_BEGIN already emitted `global g` for this fn
            out.append(f"global {g}")
    if not embed:
        out.append("section .text")
    body=_peephole(cg.text, extended=optimize)
    # Phase 1 (function scaffolding cleanup) runs when the global default switch
    # is on OR when --O2 is requested. --O2 is the explicit opt-in that turns the
    # whole function optimizer on without disturbing the default (-O0/-O1) builds,
    # which stay byte-identical to today while the global switch remains off.
    if optimize and (_ENABLE_USER_FUNCTION_OPT or regalloc):
        body=_optimize_functions(body, target)
    # Phase 2 (--O2): register-allocate frame slots into callee-saved GPRs.
    # Implies Phase 1 (it runs on the Phase-1-cleaned stream). USER target only.
    if regalloc and optimize:
        body=_regalloc_functions(body, target)
    out.extend(body)
    # Strings: emit as inert bytes in current section. In standalone mode put
    # them in .rodata; in embed mode keep them in .text (safe - no code falls
    # through into them since every fn ends with `ret`).
    if cg.rodata:
        if not embed:
            out.append("section .rodata")
        out.extend(cg.rodata)
    if cg.data:
        if target!="boot" and (not embed or kernel):
            out.append("section .data")
        out.extend(cg.data)
    LAST_SIGS=cg.sigs
    return "\n".join(out)+"\n"

def _boot_regs(bits):
    if bits==16:
        return {
            "acc":"ax", "acc32":"eax", "acc64":"rax", "tmp":"cx", "tmp2":"dx",
            "addr":"bx", "sp":"sp", "bp":"bp", "word":"word", "ptr":"word",
            "width":2, "bits":16,
        }
    if bits==32:
        return {
            "acc":"eax", "acc32":"eax", "acc64":"rax", "tmp":"ecx", "tmp2":"edx",
            "addr":"ebx", "sp":"esp", "bp":"ebp", "word":"dword", "ptr":"dword",
            "width":4, "bits":32,
        }
    return {
        "acc":"rax", "acc32":"eax", "acc64":"rax", "tmp":"rcx", "tmp2":"rdx",
        "addr":"rbx", "sp":"rsp", "bp":"rbp", "word":"qword", "ptr":"qword",
        "width":8, "bits":64,
    }

def _boot_reg_width(bits, width_bytes):
    if bits==16:
        return {1:"al",2:"ax",4:"eax",8:"rax"}[width_bytes]
    if bits==32:
        return {1:"al",2:"ax",4:"eax",8:"rax"}[width_bytes]
    return {1:"al",2:"ax",4:"eax",8:"rax"}[width_bytes]

def _boot_mem_directive(width_bytes):
    return {1:"byte",2:"word",4:"dword",8:"qword"}[width_bytes]

def _boot_zero_extend(cg, width_bytes):
    bits=cg.boot_bits
    acc=_boot_regs(bits)["acc"]
    if width_bytes==1:
        cg.emit(f"    movzx {acc}, al")
    elif width_bytes==2 and bits!=16:
        cg.emit(f"    movzx {acc}, ax")
    elif width_bytes==4 and bits==64:
        cg.emit("    mov eax, eax")

class BootState:
    def __init__(s,cg,scope):
        s.cg=cg
        s.scope=scope              # local name -> (label, width_bytes)
        s.regparams={}             # local name -> (reg spelling, width bytes)
        s.epilogue=""

def _boot_count_lets(stmts):
    n=[]
    def walk(xs):
        for st in xs:
            if st.get("k")=="let":
                n.append(st["name"])
            elif st.get("k")=="if":
                walk(st.get("then") or [])
                walk(st.get("els") or [])
            elif st.get("k")=="while":
                walk(st.get("body") or [])
    walk(stmts)
    return n

def gen_boot_fn(cg,fn):
    name=fn["name"]
    bits=cg.boot_bits
    if bits not in (16,32,64):
        raise SyntaxError(f"boot fn {name}: unsupported bits {bits}")
    if fn.get("params"):
        raise SyntaxError(f"boot fn {name}: use explicit register params, e.g. `fn f(dl drive)`")
    if fn.get("preserves") is not None:
        raise SyntaxError(f"boot fn {name}: preserves(...) is not supported in boot mode yet")
    if fn.get("naked"):
        raise SyntaxError(f"boot fn {name}: boot functions are already bare; `naked` is redundant")

    scope={}
    for local in _boot_count_lets(fn["body"]):
        lbl=f"__{name}_{local}"
        if local not in scope:
            scope[local]=(lbl,_boot_regs(bits)["width"])
            directive={1:"db",2:"dw",4:"dd",8:"dq"}[_boot_regs(bits)["width"]]
            cg.data.append(f"{lbl}: times 1 {directive} 0")

    st=BootState(cg,scope)
    for spell,pn in fn.get("regparams") or []:
        if spell not in REG_TABLE:
            raise SyntaxError(f"boot fn {name}: {spell} is not a register")
        _canon,width_bits=REG_TABLE[spell]
        width_bytes=max(1,width_bits//8)
        st.regparams[pn]=(spell,width_bytes)

    cg.emit(f"{name}:")
    st.epilogue=f".boot_fn_end_{cg.lbl}_{name}"
    for stmt in fn["body"]:
        gen_boot_stmt(st,stmt)
    cg.emit(f"{st.epilogue}:")
    cg.emit("    ret")

def gen_boot_stmt(st,s):
    cg=st.cg; k=s["k"]
    if k=="asm":
        raise SyntaxError("--target boot forbids inline asm")
    if k=="let":
        if s["name"] not in st.scope:
            raise SyntaxError(f"boot let {s['name']}: internal local allocation error")
        lbl,w=st.scope[s["name"]]
        gen_boot_expr(st,s["expr"])
        cg.emit(f"    mov [{lbl}], {_boot_reg_width(cg.boot_bits,w)}")
    elif k=="assign":
        lhs=s["lhs"]
        if lhs["k"]!="ident":
            raise SyntaxError("boot assignment supports identifiers only")
        gen_boot_expr(st,s["rhs"])
        n=lhs["name"]
        if n in st.scope:
            lbl,w=st.scope[n]
            cg.emit(f"    mov [{lbl}], {_boot_reg_width(cg.boot_bits,w)}")
        elif n in st.regparams:
            reg,w=st.regparams[n]
            src=_boot_reg_width(cg.boot_bits,w)
            cg.emit(f"    mov {reg}, {src}")
        elif n in cg.state_defs:
            lbl=cg.state_defs[n]; w=cg.state_widths.get(n,1)
            cg.emit(f"    mov [{lbl}], {_boot_reg_width(cg.boot_bits,w)}")
        else:
            raise SyntaxError(f"boot assignment: unknown target {n}")
    elif k=="exprstmt":
        gen_boot_expr(st,s["expr"])
    elif k=="return":
        if s.get("expr"):
            gen_boot_expr(st,s["expr"])
        cg.emit(f"    jmp {st.epilogue}")
    elif k=="if":
        lelse=cg.L("boot_else"); lend=cg.L("boot_endif")
        gen_boot_expr(st,s["cond"])
        cg.emit(f"    test {_boot_regs(cg.boot_bits)['acc']}, {_boot_regs(cg.boot_bits)['acc']}")
        cg.emit(f"    jz {lelse}")
        for stmt in s["then"]:
            gen_boot_stmt(st,stmt)
        cg.emit(f"    jmp {lend}")
        cg.emit(f"{lelse}:")
        for stmt in s.get("els") or []:
            gen_boot_stmt(st,stmt)
        cg.emit(f"{lend}:")
    elif k=="while":
        lstart=cg.L("boot_wst"); lend=cg.L("boot_wend")
        cg.loops.append((lend,lstart))
        cg.emit(f"{lstart}:")
        gen_boot_expr(st,s["cond"])
        cg.emit(f"    test {_boot_regs(cg.boot_bits)['acc']}, {_boot_regs(cg.boot_bits)['acc']}")
        cg.emit(f"    jz {lend}")
        for stmt in s["body"]:
            gen_boot_stmt(st,stmt)
        cg.emit(f"    jmp {lstart}")
        cg.emit(f"{lend}:")
        cg.loops.pop()
    elif k=="break":
        if not cg.loops: raise SyntaxError("break outside loop")
        cg.emit(f"    jmp {cg.loops[-1][0]}")
    elif k=="continue":
        if not cg.loops: raise SyntaxError("continue outside loop")
        cg.emit(f"    jmp {cg.loops[-1][1]}")
    elif k=="regcall":
        # Register-annotated boot call (e.g. a BIOS ABI: ah=function, al/bl/...).
        # Every argument is evaluated and pushed FIRST, then popped into the
        # target registers in reverse source order. Writing no target until all
        # args are evaluated means one arg's evaluation (which flows through the
        # accumulator/tmp regs) can never clobber a register another arg already
        # prepared -- the bug when each target was written inline.
        regargs=s["regargs"]
        rr=_boot_regs(cg.boot_bits); accfull=rr["acc"]; wordw=rr["width"]
        targets=[]; seen=set()
        for spell,_expr in regargs:
            if spell not in REG_TABLE:
                raise SyntaxError(f"boot call {s['target']}: {spell} is not a register")
            canon,wbits=REG_TABLE[spell]; wb=max(1,wbits//8)
            if spell in seen:
                raise SyntaxError(f"boot call {s['target']}: register {spell} set twice")
            seen.add(spell)
            if wb not in (1,wordw):
                raise SyntaxError(f"boot call {s['target']}: {spell} width unsupported in {cg.boot_bits}-bit boot calls")
            if wb==1 and cg.boot_bits!=64 and spell not in ("al","bl","cl","dl","ah","bh","ch","dh"):
                raise SyntaxError(f"boot call {s['target']}: byte register {spell} is not encodable in {cg.boot_bits}-bit mode (needs a REX prefix)")
            targets.append((spell,canon,wb))
        # Reject ambiguous overlap (e.g. ax + al share rax); a high+low byte pair
        # such as ah + al is fine because the two bytes are written independently.
        bycanon={}
        for spell,canon,wb in targets:
            bycanon.setdefault(canon,[]).append(wb)
        for canon,ws in bycanon.items():
            if len(ws)>1 and any(w!=1 for w in ws):
                raise SyntaxError(f"boot call {s['target']}: overlapping target registers on {canon}")
        # 1) Evaluate + stage every argument (source order).
        for _spell,expr in regargs:
            gen_boot_expr(st,expr)
            cg.emit(f"    push {accfull}")
        # 2) Pick a scratch register for sub-word target moves. A byte (8-bit)
        #    move must source from a legacy low byte (al/bl/cl/dl): sil/dil/bpl
        #    need a REX prefix (invalid in bits 16/32, and illegal mixed with a
        #    high-byte target), so byte scratch is restricted to rax..rdx. Wider
        #    sub-word moves (e.g. a 16-bit target in 32-bit mode) can use any reg.
        used={canon for _,canon,_ in targets}
        needs_scratch=any(wb!=wordw for _,_,wb in targets)
        needs_byte=any(wb==1 for _,_,wb in targets)
        scratch=None
        if needs_scratch:
            pool=("rcx","rdx","rbx","rax") if needs_byte else ("rcx","rdx","rbx","rsi","rdi","rbp","rax")
            scratch=next((c for c in pool if c not in used), None)
            if scratch is None:
                kind="byte " if needs_byte else ""
                raise SyntaxError(f"boot call {s['target']}: no free encodable {kind}scratch register for the argument registers used")
        # 3) Pop in reverse source order into the target registers.
        for spell,canon,wb in reversed(targets):
            if wb==wordw:
                cg.emit(f"    pop {_reg_at_width(canon,cg.boot_bits)}")
            else:
                cg.emit(f"    pop {_reg_at_width(scratch,cg.boot_bits)}")
                cg.emit(f"    mov {spell}, {_reg_at_width(scratch,wb*8)}")
        cg.emit(f"    call {s['target']}")
    else:
        raise SyntaxError(f"boot stmt not supported yet: {k}")

def gen_boot_expr(st,e):
    cg=st.cg; bits=cg.boot_bits; r=_boot_regs(bits); acc=r["acc"]; tmp=r["tmp"]
    k=e["k"]
    if k=="int":
        cg.emit(f"    mov {acc}, {e['val']}")
    elif k=="ident":
        n=e["name"]
        if n in st.scope:
            lbl,w=st.scope[n]
            cg.emit(f"    mov {_boot_reg_width(bits,w)}, [{lbl}]")
            _boot_zero_extend(cg,w)
        elif n in st.regparams:
            reg,w=st.regparams[n]
            dst=_boot_reg_width(bits,w)
            if dst!=reg:
                cg.emit(f"    mov {dst}, {reg}")
            _boot_zero_extend(cg,w)
        elif n in cg.consts:
            cg.emit(f"    mov {acc}, {cg.consts[n]}")
        elif n in cg.state_defs:
            lbl=cg.state_defs[n]; w=cg.state_widths.get(n,1)
            cg.emit(f"    mov {_boot_reg_width(bits,w)}, [{lbl}]")
            _boot_zero_extend(cg,w)
        else:
            raise SyntaxError(f"boot expr: unknown identifier {n}")
    elif k=="addr":
        n=e["name"]
        if n in st.scope:
            cg.emit(f"    mov {acc}, {st.scope[n][0]}")
        elif n in cg.state_defs:
            cg.emit(f"    mov {acc}, {cg.state_defs[n]}")
        elif n in cg.str_defs:
            cg.emit(f"    mov {acc}, {cg.str_defs[n]}")
        else:
            cg.emit(f"    mov {acc}, {n}")
    elif k=="neg":
        gen_boot_expr(st,e["expr"]); cg.emit(f"    neg {acc}")
    elif k=="not":
        gen_boot_expr(st,e["expr"])
        cg.emit(f"    test {acc}, {acc}")
        cg.emit("    sete al")
        _boot_zero_extend(cg,1)
    elif k=="bin":
        op=e["op"]
        gen_boot_expr(st,e["rhs"])
        cg.emit(f"    push {acc}")
        gen_boot_expr(st,e["lhs"])
        cg.emit(f"    pop {tmp}")
        if op=="+": cg.emit(f"    add {acc}, {tmp}")
        elif op=="-": cg.emit(f"    sub {acc}, {tmp}")
        elif op=="&": cg.emit(f"    and {acc}, {tmp}")
        elif op=="|": cg.emit(f"    or {acc}, {tmp}")
        elif op=="^": cg.emit(f"    xor {acc}, {tmp}")
        elif op=="<<": cg.emit(f"    shl {acc}, cl")
        elif op==">>": cg.emit(f"    shr {acc}, cl")
        elif op in ("==","!=","<",">","<=",">="):
            cg.emit(f"    cmp {acc}, {tmp}")
            setop={"==":"sete","!=":"setne","<":"setl",">":"setg","<=":"setle",">=":"setge"}[op]
            cg.emit(f"    {setop} al")
            _boot_zero_extend(cg,1)
        else:
            raise SyntaxError(f"boot binary op not supported yet: {op}")
    elif k=="call":
        name=e["name"]; args=e["args"]
        if name in ("cli","sti","hlt","nop","ud2"):
            if args: raise SyntaxError(f"{name} takes no args")
            op={"cli":"cli","sti":"sti","hlt":"hlt","nop":"nop","ud2":"ud2"}[name]
            cg.emit(f"    {op}")
            if name not in ("hlt","ud2"):
                cg.emit(f"    xor {acc}, {acc}")
        elif name=="intn":
            _require_cap(cg,"boot_int","boot intn()")
            if len(args)!=1: raise SyntaxError("intn takes 1 arg")
            vec=const_fold_int(cg,args[0])
            if vec is None or vec<0 or vec>255:
                raise SyntaxError("intn vector must be constant 0..255")
            cg.emit(f"    int 0x{vec:02X}")
            cg.emit(f"    xor {acc}, {acc}")
        elif name=="inb":
            _require_cap(cg,"boot_io","boot inb()")
            if len(args)!=1: raise SyntaxError("inb takes 1 arg")
            gen_boot_expr(st,args[0])
            cg.emit("    mov dx, ax")
            cg.emit("    in al, dx")
            _boot_zero_extend(cg,1)
        elif name=="outb":
            _require_cap(cg,"boot_io","boot outb()")
            if len(args)!=2: raise SyntaxError("outb takes 2 args")
            gen_boot_expr(st,args[0])
            cg.emit(f"    push {acc}")
            gen_boot_expr(st,args[1])
            cg.emit(f"    mov {tmp}, {acc}")
            cg.emit(f"    pop {r['tmp2']}")
            cg.emit("    mov al, cl")
            cg.emit("    out dx, al")
            cg.emit(f"    xor {acc}, {acc}")
        elif name in ("load_ds","load_es","load_fs","load_gs","load_ss"):
            if len(args)!=1: raise SyntaxError(f"{name} takes 1 arg")
            gen_boot_expr(st,args[0])
            cg.emit(f"    mov {name[-2:]}, ax")
            cg.emit(f"    xor {acc}, {acc}")
        elif name=="lgdt":
            _require_cap(cg,"boot_lgdt","boot lgdt()")
            if len(args)!=1: raise SyntaxError("lgdt takes 1 arg")
            gen_boot_expr(st,args[0])
            cg.emit(f"    mov {r['addr']}, {acc}")
            cg.emit(f"    lgdt [{r['addr']}]")
            cg.emit(f"    xor {acc}, {acc}")
        elif name=="farjmp":
            if len(args)!=2: raise SyntaxError("farjmp(selector, offset) takes 2 args")
            sel=const_fold_int(cg,args[0]); off=const_fold_int(cg,args[1])
            if sel is None or off is None:
                raise SyntaxError("farjmp selector and offset must be constants")
            cg.emit(f"    jmp 0x{sel:X}:0x{off:X}")
        elif name=="call":
            raise SyntaxError("use plain function syntax, e.g. f()")
        else:
            if args:
                raise SyntaxError("boot direct calls do not support System-V args; use explicit-register call syntax")
            if name not in cg.local_fns:
                _require_cap(cg,"boot_call",f"boot direct call to undeclared label {name}")
            cg.emit(f"    call {name}")
    else:
        raise SyntaxError(f"boot expr not supported yet: {k}")

def _kfn_label(cg,name,argc):
    # Emit the entry label for a kernel fn. Exported fns (declared `global`)
    # go through FN_BEGIN so they register a signature (satisfies
    # tools/check_coverage.py and the signature registry / traceability). Under
    # the default build (no ENABLE_TRACE/ENABLE_SIG_SECTION) FN_BEGIN expands to
    # exactly `global name` + `name:`, so this is byte-identical to a bare label.
    # Internal (non-exported) fns keep a plain label.
    if name in cg.globals:
        cg.emit(f"FN_BEGIN {name}, {argc}, 0, FN_RET_SCALAR")
        cg.fnbegin_emitted.add(name)
    else:
        cg.emit(f"{name}:")

def _kfn_end(cg,name):
    # Matching FN_END (only for FN_BEGIN-opened fns), emitted just before `ret`.
    if name in cg.fnbegin_emitted:
        cg.emit(f"    FN_END {name}")

def gen_kernel_fn(cg,fn):
    # Kernel-mode function codegen.
    #
    # Two forms:
    #
    #  (1) Register-exact ABI shim - the body is ONE OR MORE `asm { }` blocks and
    #      nothing else. The function's NASM label is emitted and the asm lines
    #      are passed through verbatim; the asm owns the entire prologue, the
    #      custom (non-System-V) register ABI, and its own `ret`. The compiler
    #      adds NO frame, NO callee-save, NO FN_BEGIN/FN_END trace framing. This
    #      is how hand-rolled kernel leaf helpers (e.g. arg in AL, all regs
    #      preserved) are ported faithfully - the security property we keep here
    #      is that every such block is explicitly author-marked `asm`, never
    #      synthesised.
    #
    #  (2) Structured body - any non-`asm` statement present. Emits a standard
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
    if getattr(cg,"srcmap",False) and cg.src and fn.get("line"):
        cg.emit(f"; ===== fn {name}  <{cg.src}:{fn['line']}> =====")
    all_asm = len(body)>0 and all(s.get("k")=="asm" for s in body)
    if all_asm:
        if params or regparams or preserves:
            raise SyntaxError(
                f"kernel asm-shim fn {name!r} must declare no params - the custom "
                f"register ABI is defined inside the asm block (document it in a comment)")
        cg.emit(f"{name}:")
        for s in body:
            for ln in s["text"].split("\\n"):
                cg.emit("    "+ln)
        return
    if fn.get("naked"):
        # Naked fn: no compiler frame/prologue/epilogue/ret. The body owns the
        # stack via read_rsp/write_rsp/push_val/pop_val and exits via its own
        # control intrinsic (sysretq/iretq/...). No `let` (there is no frame to
        # hold locals - use `state`/`data` scratch buffers instead). Exported
        # naked fns emit a bare `global`+label (NOT FN_BEGIN: the raw entry can't
        # run the FN_BEGIN trace push/call; syscall_entry is in the coverage
        # CONTROL_ALLOW set for exactly this reason).
        if params or regparams or preserves is not None:
            raise SyntaxError(f"naked fn {name!r} takes no params/preserves clause")
        def _has_let(stmts):
            for s in stmts:
                if s.get("k")=="let": return True
                if s.get("k")=="if" and (_has_let(s.get("then",[])) or _has_let(s.get("els",[]) or [])): return True
                if s.get("k")=="while" and _has_let(s.get("body",[])): return True
            return False
        if _has_let(body):
            raise SyntaxError(f"naked fn {name!r} cannot use `let` (no frame); use state/data buffers")
        cg.emit(f"{name}:")
        st=FnState(cg,{},[-8],0)
        st.epilogue=f".fn_end_{cg.lbl}_{name}"
        for stmt in body:
            gen_stmt(st,stmt)
        cg.emit(f"{st.epilogue}:")    # target for any `return;` (no auto ret follows)
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
            if k=="cfg":
                n+=count_lets(s.get("body",[]))
                n+=count_lets(s.get("els",[]) or [])
        return n
    reg_param_count=min(len(params),len(CALL_REGS))
    n_locals=count_lets(body)
    local_size=8*(reg_param_count+n_locals)+64
    local_size=(local_size+15)&~15
    _kfn_label(cg,name,len(params))
    cg.emit("    push rbp")
    cg.emit("    mov rbp, rsp")
    cg.emit("    push rbx")
    cg.emit("    push r12")
    cg.emit(f"    sub rsp, {local_size}")
    for i,pn in enumerate(params):
        if i<len(CALL_REGS):
            cg.emit(f"    mov [rbp{rbpoff(scope[pn])}], {CALL_REGS[i]}")
    next_off=[-8*(reg_param_count+1)]
    st=FnState(cg,scope,next_off,local_size)
    st.epilogue=f".fn_end_{cg.lbl}_{name}"
    for stmt in body:
        gen_stmt(st,stmt)
    cg.emit(f"{st.epilogue}:")
    cg.emit("    lea rsp, [rbp-16]")
    cg.emit("    pop r12")
    cg.emit("    pop rbx")
    cg.emit("    pop rbp")
    _kfn_end(cg,name)
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
                raise SyntaxError(f"{name}: preserves({r}) - not a register")
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
            if k=="cfg":
                n+=count_lets(s.get("body",[]))
                n+=count_lets(s.get("els",[]) or [])
        return n
    n_locals=count_lets(body)
    nregp=len(bindings)
    local_size=8*(nregp+n_locals)+64
    local_size=(local_size+15)&~15

    scope={}
    off=-8
    for b in bindings:
        b[3]=off; scope[b[0]]=off; off-=8

    _kfn_label(cg,name,len(bindings))
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
    # Write register params back to their physical registers - but ONLY for
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
    _kfn_end(cg,name)
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
            if k=="cfg":
                n+=count_lets(s.get("body",[]))
                n+=count_lets(s.get("els",[]) or [])
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
    # Provenance: remember where this statement's emitted instructions start so
    # we can stamp the FIRST one with `; <file>:<line>` (zero runtime cost, no
    # added instructions). asm-escape statements already carry author text, so
    # skip them; labels are never stamped (handled below).
    _prov_start = len(cg.text)
    _gen_stmt_body(st,s)
    if (getattr(cg,"srcmap",False) and cg.src and s.get("line")
            and k!="asm" and len(cg.text) > _prov_start):
        ln = cg.text[_prov_start]
        # only stamp a real instruction line (indented, not a label) with no
        # existing comment
        if ln.startswith("    ") and not ln.rstrip().endswith(":") and ";" not in ln:
            cg.text[_prov_start] = ln + f"    ; {cg.src}:{s['line']}"

def _gen_stmt_body(st,s):
    cg=st.cg; k=s["k"]
    if k=="let":
        off=st.new_local(s["name"])
        gen_expr(st,s["expr"])  # into rax
        cg.emit(f"    mov [rbp{rbpoff(off)}], rax")
    elif k=="assign":
        lhs=s["lhs"]
        if lhs["k"]=="index":
            # Bounds-checked store into a state buffer: buf[idx] = val.
            # Guarantees the write lands inside buf - out-of-range traps (#UD)
            # before touching memory, so this path cannot corrupt neighbours.
            _gen_state_index_store(st,lhs,s["rhs"])
            return
        if lhs["k"]!="ident":
            raise SyntaxError("only simple variable / state-buffer-index assignment supported")
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
    elif k=="cfg":
        # Wrap the generated block in a NASM build-config conditional. The block
        # is self-contained (fresh labels), so NASM including/excluding it does
        # not affect the surrounding code's labels. `cfg "X" {..}` -> %ifdef X,
        # `cfg !"X" {..}` -> %ifndef X, optional `else {..}` -> %else.
        directive = "%ifndef" if s.get("neg") else "%ifdef"
        cg.emit(f"{directive} {s['name']}")
        for stmt in s["body"]: gen_stmt(st,stmt)
        if s.get("els"):
            cg.emit("%else")
            for stmt in s["els"]: gen_stmt(st,stmt)
        cg.emit("%endif")
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

def _gen_state_index_store(st,lhs,rhs):
    # buf[idx] = val, with a compile-time-sized bounds check. The store address
    # is computed only after the index is proven in-range (else #UD), so this
    # is the safe, non-corrupting way to write a state buffer.
    cg=st.cg
    tgt=lhs["target"]
    if tgt.get("k")!="ident" or tgt["name"] not in cg.state_sizes:
        raise SyntaxError("[] store target must be a `state` buffer (bounds-checked)")
    nm=tgt["name"]; sz=cg.state_sizes[nm]; base=cg.state_defs[nm]
    gen_expr(st,rhs); cg.emit("    push rax")     # value
    gen_expr(st,lhs["idx"])                        # idx -> rax
    cg.emit(f"    cmp rax, {sz}")
    cg.emit(f"    jae {cg.oob()}")
    cg.emit(f"    lea rcx, [rel {base}]")
    cg.emit("    add rcx, rax")
    cg.emit("    pop rax")                          # value
    cg.emit("    mov [rcx], al")
    cg.emit("    xor rax, rax")

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
        elif n in getattr(cg,"symconsts",set()):
            # symbolic passthrough const: NASM resolves the equ at assemble time.
            cg.emit(f"    mov rax, {n}")
        elif n in cg.str_defs:
            cg.emit(f"    lea rax, [rel {cg.str_defs[n]}]")
        elif n in cg.state_defs:
            cg.emit(f"    lea rax, [rel {cg.state_defs[n]}]")
        else:
            raise SyntaxError(f"unknown identifier {n}")
    elif k=="index":
        # Bounds-checked load: buf[idx] -> rax (zero-extended byte). idx is
        # compared against the buffer's compile-time size; out-of-range jumps
        # to the unit's #UD trap. There is no way to express an unchecked
        # state-buffer access, so GHLK code cannot read past a buffer.
        tgt=e["target"]
        if tgt.get("k")!="ident" or tgt["name"] not in cg.state_sizes:
            raise SyntaxError("[] indexing is only supported on a `state` buffer (bounds-checked)")
        nm=tgt["name"]; sz=cg.state_sizes[nm]; base=cg.state_defs[nm]
        gen_expr(st,e["idx"])
        cg.emit(f"    cmp rax, {sz}")
        cg.emit(f"    jae {cg.oob()}")
        cg.emit(f"    lea rcx, [rel {base}]")
        cg.emit("    movzx rax, byte [rcx+rax]")
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
            # implicit extern: allow &any_symbol - register it so NASM resolves it
            if getattr(cg,"target","user")!="user":
                _require_cap(cg,"implicit_extern",f"address of undeclared symbol {n}")
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
        # signed (truncate-toward-zero) semantics GritHL `/` guarantees.
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
        # (not permuted - there is no immediate to rewrite).
        numc=const_fold_int(cg, e["num"])
        if numc is not None:
            cg.emit(f"    APP_SYSNO {numc}")
        else:
            gen_expr(st,e["num"])
        cg.emit("    syscall")
    elif k=="call":
        args=e["args"]
        name=e["name"]
        # Builtins: memory load/store - compile inline, no actual call.
        if name in ("lb","lw","lq","sb","sw","sq"):
            if getattr(cg,"target","user")!="user":
                _require_cap(cg,"raw_mem",f"{cg.target} raw memory builtin {name}()")
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
        if name in ("ror32","rol32"):
            if len(args)!=2: raise SyntaxError(f"{name} takes 2 args")
            gen_expr(st,args[0]); cg.emit("    push rax")
            gen_expr(st,args[1]); cg.emit("    mov rcx, rax"); cg.emit("    pop rax")
            if name=="ror32":
                cg.emit("    ror eax, cl")
            else:
                cg.emit("    rol eax, cl")
            cg.emit("    mov eax, eax")
            return
        # Builtin: bounds-checked dispatch. call_table(TBL, idx) calls the
        # idx-th handler fn registered in `table TBL { ... }`, after checking
        # idx < entry-count (out-of-range -> #UD). The only reachable targets
        # are the table's fixed handler set, so this is a SAFE replacement for a
        # raw `jmp/call [reg]` through an attacker-influenceable pointer. The
        # handler's return value is left in rax.
        if name=="call_table":
            if not getattr(cg,"kernel",False):
                raise SyntaxError("call_table() requires --target kernel")
            if len(args)!=2: raise SyntaxError("call_table takes (table, index)")
            tnode=args[0]
            if tnode.get("k")!="ident" or tnode["name"] not in cg.table_counts:
                raise SyntaxError("call_table: first arg must be a declared `table`")
            tname=tnode["name"]; cnt=cg.table_counts[tname]
            gen_expr(st,args[1])                 # idx -> rax
            cg.emit(f"    cmp rax, {cnt}")
            cg.emit(f"    jae {cg.oob()}")
            cg.emit(f"    lea rcx, [rel {tname}]")
            cg.emit("    call [rcx + rax*8]")
            return
        # Builtins: privileged / raw CPU instruction intrinsics (kernel mode
        # only). They let the syscall entry/exit trampoline and other ring-0
        # code be written in structured GHLK without dropping to an `asm{}`
        # escape - each intrinsic emits exactly one (or a tiny fixed) real
        # instruction. Author intent stays explicit (a named builtin), so the
        # "no hidden privileged ops" security property is preserved: privileged
        # instructions appear ONLY where the source names an intrinsic.
        if name in _NULLARY_INTRINSICS:
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if name not in ("nop","ud2") and getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv",f"kernel intrinsic {name}()")
            if args: raise SyntaxError(f"{name}() takes no args")
            for ln in _NULLARY_INTRINSICS[name]:
                cg.emit("    "+ln)
            return
        if name in ("cpuid_eax","cpuid_ebx","cpuid_ecx","cpuid_edx"):
            # cpuid_<reg>(leaf) -> rax = the requested result register.
            # Clobbers rbx/rcx/rdx (cpuid overwrites all four) - safe in the
            # structured stack machine, which keeps live values in rbp slots.
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if len(args)!=1: raise SyntaxError(f"{name} takes 1 arg (leaf)")
            gen_expr(st,args[0])              # leaf -> rax (eax)
            cg.emit("    mov eax, eax")
            cg.emit("    xor ecx, ecx")
            cg.emit("    cpuid")
            pick={"cpuid_eax":"eax","cpuid_ebx":"ebx","cpuid_ecx":"ecx","cpuid_edx":"edx"}[name]
            if pick!="eax":
                cg.emit(f"    mov eax, {pick}")
            cg.emit("    mov eax, eax")        # zero-extend result into rax
            return
        if name in ("write_rsp","push_val"):
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if len(args)!=1: raise SyntaxError(f"{name} takes 1 arg")
            gen_expr(st,args[0])
            if name=="write_rsp":
                cg.emit("    mov rsp, rax")
            else:  # push_val
                cg.emit("    push rax")
            cg.emit("    xor rax, rax")
            return
        if name=="pop_to_mem":
            # pop_to_mem(addr): pop the top stack qword into *addr. addr is
            # evaluated FIRST into rax (stack-balanced), then `pop qword [rax]`
            # consumes the caller-left top-of-stack value. Used by the naked
            # resume trampoline to capture the slot id POP_ALL left at [rsp]
            # without the addr-then-value ordering hazard of sq(addr, pop_val()).
            # kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError("pop_to_mem() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv","kernel intrinsic pop_to_mem()")
            if len(args)!=1: raise SyntaxError("pop_to_mem takes 1 arg (dest address)")
            gen_expr(st,args[0])                  # addr -> rax (stack-balanced)
            cg.emit("    pop qword [rax]")
            cg.emit("    xor rax, rax")
            return
        if name in ("save_rsp","save_flags"):
            # save_rsp(addr) / save_flags(addr): store the CURRENT rsp / RFLAGS to
            # *addr, where addr is evaluated FIRST into rax (its internal codegen
            # is stack-balanced, so rsp is back at the true frame level by the
            # store). This is the correct way to record the kernel resume frame in
            # a naked trampoline: writing rsp through the normal sq(addr, read_rsp)
            # path would capture rsp while the sq destination address is still
            # pushed, recording a value 8 bytes low. kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv",f"kernel intrinsic {name}()")
            if len(args)!=1: raise SyntaxError(f"{name} takes 1 arg (dest address)")
            gen_expr(st,args[0])                  # addr -> rax (stack-balanced)
            if name=="save_rsp":
                cg.emit("    mov [rax], rsp")
            else:
                cg.emit("    pushfq")
                cg.emit("    pop qword [rax]")
            cg.emit("    xor rax, rax")
            return
        if name=="write_flags":
            # write_flags(v): restore RFLAGS from v (push v ; popfq). Pairs with
            # read_flags(); used on the kernel-resume side of the ring-3 callback
            # round-trip to reinstate the saved kernel RFLAGS. kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError("write_flags() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv","kernel intrinsic write_flags()")
            if len(args)!=1: raise SyntaxError("write_flags takes 1 arg (flags value)")
            gen_expr(st,args[0])
            cg.emit("    push rax")
            cg.emit("    popfq")
            cg.emit("    xor rax, rax")
            return
        if name in ("push_reg","pop_reg"):
            # push_reg(REG) / pop_reg(REG): push/pop a NAMED general-purpose
            # register verbatim. The argument MUST be a bare register identifier
            # (not an expression) so the callee-save/restore discipline of a naked
            # ring-3-trampoline frame is expressed explicitly, one register per
            # statement, with no hidden scratch use. Author intent stays exact:
            # the saved set and its order are visible in the source. kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv",f"kernel intrinsic {name}()")
            if len(args)!=1 or args[0].get("k")!="ident":
                raise SyntaxError(f"{name} takes one bare register name (e.g. {name}(rbx))")
            reg=args[0]["name"]
            if reg not in REG_TABLE or REG_TABLE[reg][1]!=64:
                raise SyntaxError(f"{name}: {reg} is not a 64-bit general register")
            canon=REG_TABLE[reg][0]
            cg.emit(f"    push {canon}" if name=="push_reg" else f"    pop {canon}")
            cg.emit("    xor rax, rax")
            return
        if name=="set_reg":
            # set_reg(REG, v): load a NAMED general-purpose register with v
            # (eval v -> rax ; mov REG, rax). For naked ring-3-trampoline frames
            # that must place exact values in the System-V arg registers
            # (rdi/rsi/rdx) right before an iretq/sysretq, where the structured
            # stack machine cannot keep them live. The register MUST be a bare
            # identifier and is the author's explicit responsibility: any later
            # codegen that uses REG/rax as scratch would clobber it, so set_reg is
            # only correct as the LAST writes before the control-transfer
            # intrinsic. kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError("set_reg() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv","kernel intrinsic set_reg()")
            if len(args)!=2 or args[0].get("k")!="ident":
                raise SyntaxError("set_reg takes (REG, value) with REG a bare register name")
            reg=args[0]["name"]
            if reg not in REG_TABLE or REG_TABLE[reg][1]!=64:
                raise SyntaxError(f"set_reg: {reg} is not a 64-bit general register")
            canon=REG_TABLE[reg][0]
            gen_expr(st,args[1])
            cg.emit(f"    mov {canon}, rax")
            cg.emit("    xor rax, rax")
            return
        if name in ("xmm_loadu","xmm_loada","xmm_store","xmm_store_nt","xmm_bcast32") and getattr(cg,"kernel",False):
            # SSE2 XMM data-path intrinsics (statement form, bare xmm register
            # operand). These let the display non-temporal blit + dword-broadcast
            # fill loops be written zero-asm; the loop structure itself is ordinary
            # GHL while/if. Each emits exactly one (bcast32: two) real SSE2
            # instruction. The 16-byte memory operand of a movdqa / movntdq store
            # MUST be 16-byte aligned or the CPU #GP-faults - that alignment is the
            # author's contract (the same as the hand-written driver). A movntdq
            # (xmm_store_nt) is a non-temporal store: pair the loop with sfence()
            # before the data is read back. raw_mem (these touch raw VRAM/buffers).
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"raw_mem",f"kernel intrinsic {name}()")
            # arg shapes:
            #   xmm_loadu/loada(XMM, addr)        load  16B [addr] -> XMM
            #   xmm_store/store_nt(addr, XMM)     store XMM -> 16B [addr]
            #   xmm_bcast32(XMM, val32)           XMM = [v,v,v,v]
            if len(args)!=2:
                raise SyntaxError(f"{name} takes 2 args")
            if name in ("xmm_loadu","xmm_loada","xmm_bcast32"):
                xnode,vnode=args[0],args[1]          # (XMM, addr|val)
            else:
                vnode,xnode=args[0],args[1]          # (addr, XMM)
            if xnode.get("k")!="ident" or xnode["name"] not in XMM_REGS:
                raise SyntaxError(f"{name}: xmm operand must be a bare xmm register (xmm0..xmm15)")
            xr=xnode["name"]
            gen_expr(st,vnode)                        # addr or val32 -> rax
            if name=="xmm_loadu":
                cg.emit(f"    movdqu {xr}, [rax]")
            elif name=="xmm_loada":
                cg.emit(f"    movdqa {xr}, [rax]")
            elif name=="xmm_store":
                cg.emit(f"    movdqa [rax], {xr}")
            elif name=="xmm_store_nt":
                cg.emit(f"    movntdq [rax], {xr}")
            else:  # xmm_bcast32: replicate the low dword across all four lanes
                cg.emit(f"    movd {xr}, eax")
                cg.emit(f"    pshufd {xr}, {xr}, 0")
            cg.emit("    xor rax, rax")
            return
        if name=="isqrt" and getattr(cg,"kernel",False):
            # isqrt(n) -> rax = floor(sqrt(n)) for an unsigned 64-bit n via the SSE2
            # scalar-FP idiom the display fill_circle uses (cvtsi2sd/sqrtsd/
            # cvttsd2si). Clobbers xmm0 (documented - author owns XMM lifetimes).
            # Exact for n < 2^52 (the double mantissa); display radii are tiny so
            # this matches the hand-written behavior. raw_mem not needed (no mem).
            if not getattr(cg,"kernel",False):
                raise SyntaxError("isqrt() intrinsic requires --target kernel")
            if len(args)!=1: raise SyntaxError("isqrt takes 1 arg (n)")
            gen_expr(st,args[0])                      # n -> rax
            cg.emit("    cvtsi2sd xmm0, rax")
            cg.emit("    sqrtsd xmm0, xmm0")
            cg.emit("    cvttsd2si rax, xmm0")
            return
        if name=="rep_movsq":
            # rep_movsq(dst, src, qcount): copy qcount qwords src->dst (cld; rep
            # movsq), the structured form of the shadow-window block copy. Loads
            # rdi=dst, rsi=src, rcx=qcount, clears DF, then rep movsq. The caller
            # is responsible for any SMAP bracket (smap_open/smap_close) around it
            # when either side is user (PTE.U) memory. kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError("rep_movsq() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv","kernel intrinsic rep_movsq()")
            if len(args)!=3: raise SyntaxError("rep_movsq takes 3 args (dst, src, qcount)")
            gen_expr(st,args[0]); cg.emit("    push rax")    # dst
            gen_expr(st,args[1]); cg.emit("    push rax")    # src
            gen_expr(st,args[2]); cg.emit("    mov rcx, rax")# qcount
            cg.emit("    pop rsi")                            # src
            cg.emit("    pop rdi")                            # dst
            cg.emit("    cld")
            cg.emit("    rep movsq")
            cg.emit("    xor rax, rax")
            return
        if name in ("rep_stosd","rep_movsd") and getattr(cg,"kernel",False):
            # rep_stosd(dst, val32, dcount): fill dcount dwords at dst with val32
            #   (cld; rep stosd). rep_movsd(dst, src, dcount): copy dcount dwords
            # src->dst (cld; rep movsd). The structured form of the dword block
            # fill/copy idiom the GUI/display fast paths use. Caller owns any SMAP
            # bracket when either side is user (PTE.U) memory. kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv",f"kernel intrinsic {name}()")
            if len(args)!=3: raise SyntaxError(f"{name} takes 3 args (dst, {'val32' if name=='rep_stosd' else 'src'}, dcount)")
            gen_expr(st,args[0]); cg.emit("    push rax")     # dst
            gen_expr(st,args[1]); cg.emit("    push rax")     # val32 / src
            gen_expr(st,args[2]); cg.emit("    mov rcx, rax") # dcount
            if name=="rep_stosd":
                cg.emit("    pop rax")                         # val32 -> eax (source)
                cg.emit("    pop rdi")                         # dst
                cg.emit("    cld")
                cg.emit("    rep stosd")
            else:
                cg.emit("    pop rsi")                         # src
                cg.emit("    pop rdi")                         # dst
                cg.emit("    cld")
                cg.emit("    rep movsd")
            cg.emit("    xor rax, rax")
            return
        if name=="atomic_xchg" and getattr(cg,"kernel",False):
            # atomic_xchg(addr, val32) -> rax = old *addr (dword). `xchg` with a
            # memory operand is implicitly LOCK'd, so this is an atomic
            # read-modify-write - the primitive behind the driver xchg spinlocks
            # (e.g. display raster_select_*). addr is evaluated first, then val.
            # kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError("atomic_xchg() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv","kernel intrinsic atomic_xchg()")
            if len(args)!=2: raise SyntaxError("atomic_xchg takes 2 args (addr, val32)")
            gen_expr(st,args[0]); cg.emit("    push rax")     # addr
            gen_expr(st,args[1]); cg.emit("    mov ecx, eax") # new value
            cg.emit("    pop rax")                            # addr -> rax
            cg.emit("    xchg dword [rax], ecx")              # atomic: ecx <- old *addr
            cg.emit("    mov eax, ecx")                       # old value -> rax (zero-extended)
            return
        if name=="syscall_raw":
            # syscall_raw(num): issue a syscall with a RAW immediate number - NO
            # APP_SYSNO fixup record. For kernel-resident code that runs in ring 3
            # at a kernel VA OUTSIDE the per-slot copied app blob (the app-done
            # trampoline, the L3 test blob): the dispatcher attributes such a
            # syscall to slot 0 (identity permutation), so the raw number is the
            # real table row. Emitting APP_SYSNO here would push a bogus .scfix
            # record at a kernel-relative offset the loader must never rewrite.
            # The number must be a compile-time constant. kernel_priv.
            if not getattr(cg,"kernel",False):
                raise SyntaxError("syscall_raw() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                _require_cap(cg,"kernel_priv","kernel intrinsic syscall_raw()")
            if len(args)!=1: raise SyntaxError("syscall_raw takes 1 arg (constant number)")
            numc=const_fold_int(cg,args[0])
            if numc is None or numc<0 or numc>255:
                raise SyntaxError("syscall_raw number must be a constant in 0..255")
            cg.emit(f"    mov eax, {numc}")
            cg.emit("    syscall")
            cg.emit("    xor rax, rax")
            return
        if name in ("rdmsr","write_cr0","write_cr3","write_cr4","invlpg",
                    "inb","outb","inw","outw","ind","outd","wrmsr","wrmsr_split","lgdt","lidt","ltr",
                    "intn","load_ds","load_es","load_fs","load_gs","load_ss"):
            if not getattr(cg,"kernel",False):
                raise SyntaxError(f"{name}() intrinsic requires --target kernel")
            if getattr(cg,"target","user")!="boot":
                if name in ("inb","outb","inw","outw","ind","outd"):
                    _require_cap(cg,"kernel_io",f"kernel intrinsic {name}()")
                elif name=="intn":
                    _require_cap(cg,"kernel_int","kernel intn()")
                elif name in ("write_cr0","write_cr4"):
                    _require_cap(cg,"kernel_creg",f"kernel intrinsic {name}()")
                elif name in ("write_cr3","invlpg"):
                    _require_cap(cg,"kernel_pgtable",f"kernel intrinsic {name}()")
                elif name in ("lgdt","ltr"):
                    _require_cap(cg,"kernel_dtable",f"kernel intrinsic {name}()")
                elif name=="lidt":
                    _require_cap(cg,"kernel_idtable","kernel intrinsic lidt()")
                else:
                    _require_cap(cg,"kernel_priv",f"kernel intrinsic {name}()")
            if name=="rdmsr":
                # rdmsr(msr) -> rax = (edx<<32)|eax. ecx = msr.
                if len(args)!=1: raise SyntaxError("rdmsr takes 1 arg (msr)")
                gen_expr(st,args[0]); cg.emit("    mov ecx, eax")
                cg.emit("    rdmsr")
                cg.emit("    shl rdx, 32"); cg.emit("    mov eax, eax"); cg.emit("    or rax, rdx")
            elif name=="wrmsr":
                # wrmsr(msr, val64): ecx=msr, edx:eax = val64.
                if len(args)!=2: raise SyntaxError("wrmsr takes 2 args (msr, val64)")
                gen_expr(st,args[0]); cg.emit("    push rax")          # msr
                gen_expr(st,args[1])                                   # val64 -> rax
                cg.emit("    mov rdx, rax"); cg.emit("    shr rdx, 32") # hi
                cg.emit("    pop rcx")                                 # msr -> ecx (low 32 used)
                cg.emit("    wrmsr")
                cg.emit("    xor rax, rax")
            elif name=="wrmsr_split":
                # wrmsr_split(msr, lo32, hi32): ecx=msr, eax=lo, edx=hi.
                if len(args)!=3: raise SyntaxError("wrmsr_split takes 3 args (msr, lo, hi)")
                gen_expr(st,args[0]); cg.emit("    push rax")          # msr
                gen_expr(st,args[1]); cg.emit("    push rax")          # lo
                gen_expr(st,args[2]); cg.emit("    mov edx, eax")      # hi -> edx
                cg.emit("    pop rax")                                 # lo -> eax
                cg.emit("    pop rcx")                                 # msr -> ecx
                cg.emit("    wrmsr")
                cg.emit("    xor rax, rax")
            elif name=="write_cr3":
                if len(args)!=1: raise SyntaxError("write_cr3 takes 1 arg")
                gen_expr(st,args[0]); cg.emit("    mov cr3, rax"); cg.emit("    xor rax, rax")
            elif name=="write_cr0":
                if len(args)!=1: raise SyntaxError("write_cr0 takes 1 arg")
                gen_expr(st,args[0]); cg.emit("    mov cr0, rax"); cg.emit("    xor rax, rax")
            elif name=="write_cr4":
                if len(args)!=1: raise SyntaxError("write_cr4 takes 1 arg")
                gen_expr(st,args[0]); cg.emit("    mov cr4, rax"); cg.emit("    xor rax, rax")
            elif name=="invlpg":
                if len(args)!=1: raise SyntaxError("invlpg takes 1 arg (addr)")
                gen_expr(st,args[0]); cg.emit("    invlpg [rax]"); cg.emit("    xor rax, rax")
            elif name=="lgdt":
                if len(args)!=1: raise SyntaxError("lgdt takes 1 arg (descriptor pointer)")
                gen_expr(st,args[0]); cg.emit("    lgdt [rax]"); cg.emit("    xor rax, rax")
            elif name=="lidt":
                if len(args)!=1: raise SyntaxError("lidt takes 1 arg (descriptor pointer)")
                gen_expr(st,args[0]); cg.emit("    lidt [rax]"); cg.emit("    xor rax, rax")
            elif name=="ltr":
                if len(args)!=1: raise SyntaxError("ltr takes 1 arg (selector)")
                gen_expr(st,args[0]); cg.emit("    ltr ax"); cg.emit("    xor rax, rax")
            elif name.startswith("load_"):
                if len(args)!=1: raise SyntaxError(f"{name} takes 1 arg (selector)")
                seg=name[-2:]
                gen_expr(st,args[0]); cg.emit(f"    mov {seg}, ax"); cg.emit("    xor rax, rax")
            elif name=="intn":
                if len(args)!=1: raise SyntaxError("intn takes 1 arg (constant vector)")
                vec=const_fold_int(cg,args[0])
                if vec is None or vec < 0 or vec > 255:
                    raise SyntaxError("intn vector must be a constant in 0..255")
                cg.emit(f"    int 0x{vec:02X}"); cg.emit("    xor rax, rax")
            elif name=="inb":
                # inb(port) -> rax = byte read. dx = port.
                if len(args)!=1: raise SyntaxError("inb takes 1 arg (port)")
                gen_expr(st,args[0]); cg.emit("    mov dx, ax")
                cg.emit("    in al, dx"); cg.emit("    movzx rax, al")
            elif name=="outb":
                # outb(port, val): dx=port, al=val.
                if len(args)!=2: raise SyntaxError("outb takes 2 args (port, val)")
                gen_expr(st,args[0]); cg.emit("    push rax")          # port
                gen_expr(st,args[1]); cg.emit("    mov ecx, eax")      # val -> cl
                cg.emit("    pop rdx")                                 # port -> dx
                cg.emit("    mov al, cl"); cg.emit("    out dx, al")
                cg.emit("    xor rax, rax")
            elif name=="inw":
                # inw(port) -> rax = word read. dx = port. Zero-extended into rax.
                if len(args)!=1: raise SyntaxError("inw takes 1 arg (port)")
                gen_expr(st,args[0]); cg.emit("    mov dx, ax")
                cg.emit("    in ax, dx"); cg.emit("    movzx rax, ax")
            elif name=="outw":
                # outw(port, val): dx=port, ax=val (16-bit OUT).
                if len(args)!=2: raise SyntaxError("outw takes 2 args (port, val)")
                gen_expr(st,args[0]); cg.emit("    push rax")          # port
                gen_expr(st,args[1]); cg.emit("    mov ecx, eax")      # val -> cx
                cg.emit("    pop rdx")                                 # port -> dx
                cg.emit("    mov ax, cx"); cg.emit("    out dx, ax")
                cg.emit("    xor rax, rax")
            elif name=="ind":
                # ind(port) -> rax = dword read. dx = port. Zero-extended into rax.
                if len(args)!=1: raise SyntaxError("ind takes 1 arg (port)")
                gen_expr(st,args[0]); cg.emit("    mov dx, ax")
                cg.emit("    in eax, dx"); cg.emit("    mov eax, eax")
            elif name=="outd":
                # outd(port, val): dx=port, eax=val (32-bit OUT).
                if len(args)!=2: raise SyntaxError("outd takes 2 args (port, val)")
                gen_expr(st,args[0]); cg.emit("    push rax")          # port
                gen_expr(st,args[1]); cg.emit("    mov ecx, eax")      # val -> ecx
                cg.emit("    pop rdx")                                 # port -> dx
                cg.emit("    mov eax, ecx"); cg.emit("    out dx, eax")
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
    path=os.path.join(lib_dir, name.replace(".", os.sep)+".ghl")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"use {name}: {path} not found")
    return path

def compile_file(path, lib_dir, app_prefix=None, embed=False, return_sigs=False,
                 kernel=False, target="user", forbid_asm=False, deny_unsafe=False,
                 optimize=True, regalloc=False):
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
    # Kernel/boot modules are not prefixed (their labels must match existing
    # symbols verbatim); the prefix is retained only for the user-mode path.
    unit_prefix = prefix if kernel else "app_hl_"+prefix
    asm=compile_unit(expanded, unit_prefix, embed=embed, kernel=kernel,
                     src=os.path.basename(path), target=target,
                     forbid_asm=forbid_asm, deny_unsafe=deny_unsafe,
                     optimize=optimize, regalloc=regalloc)
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
    ap.add_argument("--target",choices=["user","kernel","boot"],default="user",
                    help="user (default): emit a ring-3 app blob with syscall wrappers. "
                         "kernel: emit plain NASM for %%include into kernel_build.asm - "
                         "bare labels, direct in-unit calls, no app framing, no syscall wrappers. "
                         "boot: emit guarded boot-layout NASM with bits/org support and no inline asm.")
    ap.add_argument("--forbid-asm",action="store_true",
                    help="reject any inline asm block. Use for new code and migration gates.")
    ap.add_argument("--deny-unsafe",action="store_true",
                    help="reject unsafe capability declarations and unsafe-only operations.")
    ap.add_argument("--O0","--no-opt",dest="no_opt",action="store_true",
                    help="disable the lossless function-level optimizer (dead frame / "
                         "callee-save / spill-reload removal). Reproduces the verbose, "
                         "unoptimized output for debugging or byte-diffing. The optimizer "
                         "is on by default (-O1) and is provably semantics-preserving.")
    ap.add_argument("--O2",dest="o2",action="store_true",
                    help="enable the Phase-2 register allocator (USER target only): "
                         "promotes frame home-slots into callee-saved GPRs across their "
                         "live range so values stay in registers instead of round-tripping "
                         "through memory. Implies -O1. OFF by default; conservative and "
                         "signature-preserving (only .text changes).")
    args=ap.parse_args()
    optimize=not args.no_opt
    # --O2 is the explicit opt-in for the function optimizer + register allocator.
    # It no longer depends on the global default switch (which gates -O1 builds);
    # passing --O2 turns the passes on for that compile.
    regalloc=args.o2 and optimize
    kernel=(args.target in ("kernel","boot"))
    if args.emit_sigs:
        asm,sigs=compile_file(args.input, os.path.abspath(args.lib), args.prefix,
                              embed=args.embed, return_sigs=True, kernel=kernel,
                              target=args.target, forbid_asm=args.forbid_asm,
                              deny_unsafe=args.deny_unsafe, optimize=optimize,
                              regalloc=regalloc)
    else:
        asm=compile_file(args.input, os.path.abspath(args.lib), args.prefix,
                         embed=args.embed, kernel=kernel, target=args.target,
                         forbid_asm=args.forbid_asm, deny_unsafe=args.deny_unsafe,
                         optimize=optimize, regalloc=regalloc)
        sigs=[]
    with open(args.output,"w",encoding="utf-8",newline="\n") as f: f.write(asm)
    if args.emit_sigs:
        sig_path=os.path.splitext(args.output)[0]+".sig.json"
        with open(sig_path,"w",encoding="utf-8",newline="\n") as f:
            json.dump(sigs,f,indent=2)
            f.write("\n")
    print(f"[gritc] {args.input} -> {args.output} ({len(asm)} bytes)")

if __name__=="__main__":
    main()
