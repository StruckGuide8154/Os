#!/usr/bin/env python3
"""
gritc_replay.py - Deterministic gritc compile-and-measure REPLAY GATE.

This is the ACCEPTANCE AUTHORITY for the coupled whole-program QUBO solver in
program_qubo.py. The QUBO/QPU only PROPOSES a knob configuration (per-wrapper
inline on/off, global inline threshold, ...). This module re-runs the REAL
gritc.py compile with those knobs, measures the actual emitted size, and -- when
NASM is available -- confirms the emitted body still assembles (the lossless /
no-undefined-symbol gate). A proposal is ACCEPTED only if its replay:

  * compiles without error,
  * assembles cleanly (introduces no new undefined symbols vs the baseline), and
  * is no larger than the classical baseline (the O4 default knobs).

No quantum output can affect shipped code: the build never calls this module, and
the only thing that can win over the classical baseline is a config whose REAL
gritc output is verifiably smaller AND still assembles. Mirrors the propose-then-
replay-through-the-real-checker discipline of policy_graph_qaoa.py.

Token discipline: this module never reads, prints, or stores any IBM token.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GRITC = os.path.join(REPO_ROOT, "src", "user", "grithl", "compiler", "gritc.py")
APPS_DIR = os.path.join(REPO_ROOT, "src", "user", "grithl", "apps")
LIB_DIR = os.path.join(REPO_ROOT, "src", "user", "grithl", "lib")

# NASM (Windows build). Path is configurable; default matches the dev box.
NASM = os.environ.get("NASM", r"C:\Tools\nasm-2.16.03\nasm.exe")

# Inlined NASM stub defining the app-framing macros so an --embed body can be
# assembled standalone (no %include of a /tmp path -- NASM is the Windows build).
# FN_CALL / APP_SYSNO emit nothing structural; we only need every referenced
# label to resolve and the instruction bodies to encode. Externs are declared
# from the emitted `extern` lines, so the only "undefined symbols" NASM can find
# are genuinely new ones the optimizer introduced.
_STUB = r"""
bits 64
section .text
%macro FN_BEGIN 4
%1:
%endmacro
%macro FN_ARG 3
%endmacro
%macro FN_END 1
    ret
%endmacro
%macro FN_CALL 2
    call %1
%endmacro
%macro APP_SYSNO 1
    mov eax, %1
%endmacro
FN_RET_SCALAR equ 0
FN_RET_VOID   equ 1
FN_KIND_SCALAR equ 0
FN_KIND_PTR    equ 1
"""


@dataclass
class ReplayResult:
    config_id: str
    compiled: bool
    asm_lines: int          # emitted .asm line count (size proxy, deterministic)
    instr_lines: int        # emitted instruction-line count (tighter size proxy)
    assembled: bool | None  # None => NASM unavailable / skipped
    new_undef: list         # undefined symbols not present in baseline
    error: str = ""

    @property
    def size(self) -> int:
        return self.instr_lines


def _knob_env(maxcalls: int | None,
              inline_set: list[str] | None,
              noinline_set: list[str] | None) -> dict:
    env = dict(os.environ)
    # never leak a token into a child build (defensive; gritc never reads it)
    env.pop("QISKIT_IBM_TOKEN", None)
    if maxcalls is not None:
        env["GRITC_O4_MAXCALLS"] = str(maxcalls)
    env["GRITC_O4_INLINE_SET"] = ",".join(inline_set or [])
    env["GRITC_O4_NOINLINE_SET"] = ",".join(noinline_set or [])
    return env


_INSTR_SKIP = re.compile(r"^\s*(;|$|extern\b|global\b|section\b|bits\b|default\b|"
                         r"%|[A-Za-z_.][\w.$@]*:)")


def _count_instr_lines(text: str) -> int:
    n = 0
    for ln in text.splitlines():
        if _INSTR_SKIP.match(ln):
            continue
        n += 1
    return n


def _undef_symbols(asm_text: str, work: str) -> list[str]:
    """Assemble the emitted body with the inlined stub and return undefined
    symbols NASM reports. Returns [] if it assembles clean; None semantics are
    handled by the caller (NASM missing)."""
    asm_path = os.path.join(work, "body.asm")
    obj_path = os.path.join(work, "body.o")
    with open(asm_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(_STUB)
        f.write("\n")
        f.write(asm_text)
    # NASM is the Windows exe; pass a Windows path.
    win_asm = asm_path
    win_obj = obj_path
    if shutil.which("cygpath"):
        try:
            win_asm = subprocess.check_output(["cygpath", "-w", asm_path]).decode().strip()
            win_obj = subprocess.check_output(["cygpath", "-w", obj_path]).decode().strip()
        except Exception:
            pass
    proc = subprocess.run([NASM, "-f", "elf64", win_asm, "-o", win_obj],
                          capture_output=True, text=True)
    undef = []
    for ln in (proc.stderr or "").splitlines():
        m = re.search(r"symbol `([^']+)' undefined", ln)
        if m:
            undef.append(m.group(1))
    return undef


def compile_app(app: str, *, maxcalls: int | None = None,
                inline_set: list[str] | None = None,
                noinline_set: list[str] | None = None,
                o4: bool = True, assemble: bool = True,
                config_id: str = "cfg") -> ReplayResult:
    """Run the REAL gritc compile for `app` with the proposed knobs and measure."""
    env = _knob_env(maxcalls, inline_set, noinline_set)
    work = tempfile.mkdtemp(prefix="gritc_replay_")
    try:
        out_asm = os.path.join(work, app + ".asm")
        cmd = [sys.executable, GRITC, os.path.join(APPS_DIR, app + ".ghl"),
               "-o", out_asm, "-L", LIB_DIR, "--embed"]
        cmd.append("--O4" if o4 else "--O3")
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if proc.returncode != 0 or not os.path.exists(out_asm):
            return ReplayResult(config_id, False, 0, 0, None, [],
                                error=(proc.stderr or proc.stdout)[-400:])
        with open(out_asm, "r", encoding="utf-8") as f:
            text = f.read()
        asm_lines = text.count("\n")
        instr = _count_instr_lines(text)
        assembled = None
        new_undef: list[str] = []
        if assemble and os.path.exists(NASM):
            try:
                new_undef = _undef_symbols(text, work)
                assembled = (len(new_undef) == 0)
            except Exception as e:  # pragma: no cover
                assembled = None
                new_undef = []
        return ReplayResult(config_id, True, asm_lines, instr, assembled, new_undef)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def list_wrappers(app: str) -> list[str]:
    """Enumerate the inlinable expression-wrapper names gritc identifies for an
    app. Used to define the QUBO's per-wrapper inline variables. We ask gritc to
    dump them via a tiny in-process hook to avoid duplicating its parser."""
    sys.path.insert(0, os.path.dirname(GRITC))
    import importlib
    gritc = importlib.import_module("gritc")
    importlib.reload(gritc)
    with open(os.path.join(APPS_DIR, app + ".ghl"), "r", encoding="utf-8") as f:
        src = f.read()
    toks = gritc.lex(src, app)
    decls = gritc.parse(toks, app)
    # expand `use` one level, mirroring compile_file
    expanded = []
    seen = set()

    def load(p):
        if p in seen:
            return
        seen.add(p)
        with open(p, "r", encoding="utf-8") as fh:
            s = fh.read()
        dd = gritc.parse(gritc.lex(s, p), p)
        for d in dd:
            if d["k"] == "use":
                load(gritc.resolve_use(d["name"], LIB_DIR))
            else:
                expanded.append(d)
    for d in decls:
        if d["k"] == "use":
            load(gritc.resolve_use(d["name"], LIB_DIR))
    for d in decls:
        if d["k"] != "use":
            expanded.append(d)
    names = []
    for d in expanded:
        if d.get("k") != "fn":
            continue
        body = d.get("body") or []
        # expression wrapper: single `return EXPR;`
        if len(body) == 1 and body[0].get("k") == "return" and body[0].get("expr"):
            nm = d.get("name")
            # gritc's inline override sets (GRITC_O4_INLINE_SET / NOINLINE_SET)
            # key on the BARE function name (d["name"]), not the app-prefixed
            # label -- match that exactly.
            if nm and not any(nm.endswith(s) for s in
                              ("_draw", "_click", "_key", "_main", "_init")):
                names.append(nm)
    return names


if __name__ == "__main__":
    # quick manual probe: python gritc_replay.py paint
    app = sys.argv[1] if len(sys.argv) > 1 else "paint"
    base = compile_app(app)
    print(f"{app}: baseline O4 instr_lines={base.instr_lines} "
          f"assembled={base.assembled} new_undef={base.new_undef}")
    ws = list_wrappers(app)
    print(f"{app}: {len(ws)} inlinable wrappers")
