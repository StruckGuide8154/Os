#!/usr/bin/env python3
"""
check_mathematical_faults.py - deterministic fault/bypass proofs.

This guard reports only faults that follow from source/build geometry, constants,
or instruction semantics, not from heuristics. Each finding includes:

  * the CPU/security fault that is mathematically reachable,
  * the trigger that reaches it,
  * the source/build evidence used for the proof, and
  * the fix shape.

The first models cover the Grit OS L3 app W^X sandbox because the failure class
is arithmetic: code/data boundary, page alignment, and manifest ranges decide
whether a ring-3 instruction fetch lands in X+!W or W+NX, and whether a writable
app page can ever remain executable. Additional models cover constant slot
interval overlap and provable divide-by-zero. The checker is intentionally
conservative: if it cannot prove a fault, it emits no finding. Missing optional
build listings/artifacts are noted as informational output, not as
vulnerabilities.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import ast
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence


PAGE_SIZE = 4096

SOURCE_TEXT_SUFFIXES = {".asm", ".inc", ".ghl"}

REG_ALIASES = {
    "rax": "rax", "eax": "rax", "ax": "rax", "al": "rax",
    "rbx": "rbx", "ebx": "rbx", "bx": "rbx", "bl": "rbx",
    "rcx": "rcx", "ecx": "rcx", "cx": "rcx", "cl": "rcx",
    "rdx": "rdx", "edx": "rdx", "dx": "rdx", "dl": "rdx",
    "rsi": "rsi", "esi": "rsi", "si": "rsi", "sil": "rsi",
    "rdi": "rdi", "edi": "rdi", "di": "rdi", "dil": "rdi",
    "rbp": "rbp", "ebp": "rbp", "bp": "rbp", "bpl": "rbp",
    "rsp": "rsp", "esp": "rsp", "sp": "rsp", "spl": "rsp",
}
for _i in range(16):
    REG_ALIASES[f"r{_i}"] = f"r{_i}"
    REG_ALIASES[f"r{_i}d"] = f"r{_i}"
    REG_ALIASES[f"r{_i}w"] = f"r{_i}"
    REG_ALIASES[f"r{_i}b"] = f"r{_i}"


@dataclass
class Finding:
    rule: str
    location: str
    fault: str
    trigger: str
    evidence: str
    fix: str


def repo_path(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(path)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def line_of(text: str, needle: str) -> int:
    idx = text.find(needle)
    if idx < 0:
        return 1
    return text[:idx].count("\n") + 1


def add(
    findings: list[Finding],
    rule: str,
    location: str,
    fault: str,
    trigger: str,
    evidence: str,
    fix: str,
) -> None:
    findings.append(Finding(rule, location, fault, trigger, evidence, fix))


def strip_asm_comments(line: str) -> str:
    return line.split(";", 1)[0].strip()


def source_files(root: Path, suffixes: set[str] = SOURCE_TEXT_SUFFIXES) -> list[Path]:
    ignored = {".git", ".claude", "build", "dist", "worktrees", "__pycache__", "sandbox_shadow"}
    files: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in suffixes:
            continue
        rel_parts = path.resolve().relative_to(root.resolve()).parts
        if any(part in ignored for part in rel_parts):
            continue
        files.append(path)
    return sorted(files)


def strip_hash_comment(line: str) -> str:
    in_string = False
    quote = ""
    escaped = False
    out: list[str] = []
    for ch in line:
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                in_string = False
            continue
        if ch in ('"', "'"):
            in_string = True
            quote = ch
            out.append(ch)
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)


def parse_int_literal(token: str) -> int | None:
    token = token.strip().replace("_", "")
    if not re.fullmatch(r"[+-]?(?:0x[0-9A-Fa-f]+|\d+)", token):
        return None
    return int(token, 0)


def safe_eval_expr(expr: str, constants: dict[str, int]) -> int | None:
    expr = expr.split(";", 1)[0].strip()
    expr = re.sub(r"\b([0-9A-Fa-f]+)h\b", r"0x\1", expr)
    if not expr:
        return None
    try:
        tree = ast.parse(expr, mode="eval")
    except SyntaxError:
        return None

    def ev(node: ast.AST) -> int:
        if isinstance(node, ast.Expression):
            return ev(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return int(node.value)
        if isinstance(node, ast.Name):
            if node.id not in constants:
                raise ValueError(node.id)
            return constants[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub, ast.Invert)):
            v = ev(node.operand)
            if isinstance(node.op, ast.UAdd):
                return v
            if isinstance(node.op, ast.USub):
                return -v
            return ~v
        if isinstance(node, ast.BinOp) and isinstance(
            node.op, (ast.Add, ast.Sub, ast.Mult, ast.FloorDiv, ast.Div, ast.Mod, ast.LShift, ast.RShift, ast.BitOr, ast.BitAnd, ast.BitXor)
        ):
            a = ev(node.left)
            b = ev(node.right)
            if isinstance(node.op, ast.Add):
                return a + b
            if isinstance(node.op, ast.Sub):
                return a - b
            if isinstance(node.op, ast.Mult):
                return a * b
            if isinstance(node.op, (ast.FloorDiv, ast.Div)):
                if b == 0:
                    raise ZeroDivisionError
                return a // b
            if isinstance(node.op, ast.Mod):
                if b == 0:
                    raise ZeroDivisionError
                return a % b
            if isinstance(node.op, ast.LShift):
                return a << b
            if isinstance(node.op, ast.RShift):
                return a >> b
            if isinstance(node.op, ast.BitOr):
                return a | b
            if isinstance(node.op, ast.BitAnd):
                return a & b
            return a ^ b
        raise ValueError(type(node).__name__)

    try:
        return ev(tree)
    except Exception:
        return None


def load_asm_constants(root: Path) -> dict[str, int]:
    constants: dict[str, int] = {}
    paths = [
        root / "src/include/boot_memory.inc",
        root / "src/include/constants.inc",
        root / "src/user/lib/grit_window.inc",
        root / "src/kernel/proc/usermode_decls.inc",
    ]
    changed = True
    lines: list[tuple[Path, str]] = []
    for path in paths:
        if path.is_file():
            for line in read_text(path).splitlines():
                lines.append((path, line))
    while changed:
        changed = False
        for _path, line in lines:
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+(.+)$", line.split(";", 1)[0])
            if not m or m.group(1) in constants:
                continue
            val = safe_eval_expr(m.group(2), constants)
            if val is not None:
                constants[m.group(1)] = val
                changed = True
    return constants


def reg_base(name: str) -> str | None:
    return REG_ALIASES.get(name.lower())


def compile_user_apps(root: Path, keep_temp: bool) -> tuple[Path, list[Path], list[str]]:
    compiler = root / "src/user/grithl/compiler/gritc.py"
    lib_dir = root / "src/user/grithl/lib"
    app_dir = root / "src/user/grithl/apps"
    if not compiler.is_file():
        raise FileNotFoundError(f"missing compiler: {compiler}")
    if not app_dir.is_dir():
        raise FileNotFoundError(f"missing user app directory: {app_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="grit-mathfault-"))
    generated: list[Path] = []
    notes: list[str] = []
    try:
        for src in sorted(app_dir.glob("*.ghl")):
            out = temp_dir / (src.stem + ".asm")
            cmd = [
                sys.executable,
                str(compiler),
                str(src),
                "-o",
                str(out),
                "-L",
                str(lib_dir),
                "--prefix",
                src.stem,
                "--embed",
            ]
            proc = subprocess.run(cmd, cwd=str(root), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if proc.returncode != 0:
                raise RuntimeError(
                    f"gritc failed for {repo_path(root, src)} (exit {proc.returncode})\n{proc.stdout}"
                )
            generated.append(out)
        if keep_temp:
            notes.append(f"[math-fault] kept generated app asm: {temp_dir}")
        return temp_dir, generated, notes
    except Exception:
        if not keep_temp:
            shutil.rmtree(temp_dir, ignore_errors=True)
        raise


def cleanup_temp(temp_dir: Path, keep_temp: bool) -> None:
    if not keep_temp:
        shutil.rmtree(temp_dir, ignore_errors=True)


def check_generated_app_sections(root: Path, generated: Sequence[Path], findings: list[Finding]) -> None:
    for asm in generated:
        text = read_text(asm)
        app_name = asm.stem
        loc_name = f"generated:{app_name}.asm"

        for m in re.finditer(r"(?mi)^\s*section\s+\.data\b", text):
            add(
                findings,
                "wx-inline-writable-data",
                f"{loc_name}:{line_of(text, m.group(0))}",
                "A compiler-managed writable app object is emitted outside the .appdata tail. In an embedded app blob this either falls outside [app_blob_start, app_blob_end) or forces a page to be both writable and executable.",
                f"Compile {repo_path(root, root / 'src/user/grithl/apps' / (app_name + '.ghl'))} and launch the app; any write to that object is not protected by the single W^X code/data split.",
                "Generated embedded user app contains `section .data`.",
                "For --embed user apps, route cg.data/buffer output to `section .appdata` and restore `section .text` before EOF.",
            )

        for section_name in (".appdata", ".bss"):
            for m in re.finditer(rf"(?mi)^\s*section\s+{re.escape(section_name)}\b", text):
                tail = text[m.end() :]
                if not re.search(r"(?mi)^\s*section\s+\.text\b", tail):
                    add(
                        findings,
                        "wx-generated-section-not-restored",
                        f"{loc_name}:{line_of(text, m.group(0))}",
                        f"Generated app leaves NASM in {section_name}; the wrapper's following app_seg_*_end label or the next app's code can be assembled into a non-code section, making integrity offsets wrong or making executable callbacks land in W+NX data.",
                        "Build the monolithic app blob after this generated unit; the next emitted label/code inherits the wrong section.",
                        f"`section {section_name}` has no later `section .text` in the same generated embedded unit.",
                        "Emit `section .text` after embedded .appdata/.bss output in gritc.py.",
                    )


def check_paging_fail_closed(root: Path, findings: list[Finding]) -> None:
    path = root / "src/kernel/proc/usermode_paging.inc"
    text = read_text(path)
    m = re.search(r"(?is)test\s+r10d\s*,\s*r10d\s*\n\s*jz\s+(\.[A-Za-z0-9_]+)", text)
    if not m:
        add(
            findings,
            "wx-manifest-validity-branch-missing",
            f"{repo_path(root, path)}:1",
            "The W^X policy no-manifest branch is not recognizable, so the suite cannot prove missing/invalid manifests fail closed.",
            "Any slot whose l3_wx_manifest_ver is missing, zero, or corrupted reaches the unproven path.",
            "No `test r10d,r10d` followed by `jz <target>` was found in l3_apply_wx_policy.",
            "Keep the manifest-validity branch explicit and route invalid manifests to `.wx_set_wnx`.",
        )
        return
    target = m.group(1)
    if target != ".wx_set_wnx":
        add(
            findings,
            "wx-manifestless-rwx",
            f"{repo_path(root, path)}:{line_of(text, m.group(0))}",
            "A manifestless or invalid-manifest app page can remain writable and executable instead of being forced W+NX.",
            "Install or corrupt a slot so l3_wx_manifest_ver != 1, then execute self-written bytes from a copied blob page.",
            f"Invalid-manifest branch jumps to `{target}` after `test r10d,r10d`; it must jump to `.wx_set_wnx`.",
            "Change the no-valid-manifest branch to `.wx_set_wnx` so every present non-stack page is W+NX when the manifest is absent or invalid.",
        )


def check_default_manifest(root: Path, findings: list[Finding]) -> None:
    path = root / "src/kernel/proc/usermode_slot_install.inc"
    text = read_text(path)
    fn = re.search(
        r"(?is)FN_BEGIN\s+l3_copy_app_blob_to_slot\b(?P<body>.*?)(?=\n\s*FN_BEGIN\s+|\Z)",
        text,
    )
    body = fn.group("body") if fn else text
    body_base_line = text[: fn.start("body")].count("\n") + 1 if fn else 1
    required = [
        # Indexed NASM symbols use `abs`; accept `rel` as well for equivalent
        # source forms on targets where the assembler permits indexed RIP data.
        r"mov\s+rdx\s*,\s*\[(?:abs|rel)\s+l3_slot_code_slide\s*\+\s*rcx\*8\]",
        r"add\s+rax\s*,\s*\[rel\s+app_blob_code_size_v\]",
        r"mov\s+\[l3_wx_code_start\s*\+\s*rcx\*8\]\s*,\s*rdx",
        r"mov\s+\[l3_wx_code_end\s*\+\s*rcx\*8\]\s*,\s*rax",
        r"mov\s+qword\s+\[l3_wx_manifest_ver\s*\+\s*rcx\*8\]\s*,\s*1",
    ]
    missing = [pat for pat in required if not re.search(pat, body, re.I)]
    if missing:
        add(
            findings,
            "wx-default-v1-manifest-missing",
            f"{repo_path(root, path)}:1",
            "A copied slot may boot without a valid v1 W^X manifest, causing either fail-closed NX execution faults or a fallback to legacy W+X if paging regresses.",
            "Launch any built-in app that does not call SYS_WX_INSTALL_MANIFEST itself.",
            "l3_copy_app_blob_to_slot does not visibly install [slide, slide + app_blob_code_size_v) as a v1 manifest.",
            "Install l3_wx_manifest_ver=1 and slide-aware code_start/code_end derived from app_blob_code_size_v for every copied slot.",
        )

    legacy_zero = re.search(
        r"(?is)xor\s+eax\s*,\s*eax.{0,240}mov\s+\[l3_wx_manifest_ver\s*\+\s*rcx\*8\]\s*,\s*rax",
        body,
    )
    if legacy_zero:
        add(
            findings,
            "wx-default-v0-manifest",
            f"{repo_path(root, path)}:{body_base_line + line_of(body, legacy_zero.group(0)) - 1}",
            "Slot install explicitly creates the legacy permissive v0 manifest.",
            "Launch any no-manifest app; the slot begins life in the v0 path.",
            "`l3_wx_manifest_ver` is zeroed during slot install.",
            "Remove v0 install and write a default v1 W^X manifest for every slot.",
        )


def check_blob_framing(root: Path, findings: list[Finding]) -> None:
    apps = root / "src/user/apps.asm"
    text = read_text(apps)
    rel = repo_path(root, apps)

    if not re.search(r"(?is)align\s+4096\s+global\s+app_blob_start\s+app_blob_start:", text):
        add(
            findings,
            "wx-blob-start-unaligned",
            f"{rel}:{line_of(text, 'app_blob_start:')}",
            "The W^X split can bisect a 4 KiB page if app_blob_start is not page-aligned, making one page require both X+!W and W+NX.",
            "Build an app whose code tail and data head share the split page, then either execute or write that page.",
            "`app_blob_start` is not immediately protected by `align 4096`.",
            "Align app_blob_start to 4096 before the start sentinel.",
        )

    has_appdata_tail = re.search(r"(?is)\[section\s+\.appdata\s+follows=\.text\s+align=4096\]", text)
    has_late_boundary = re.search(
        r"(?is)align\s+4096\s+global\s+app_blob_code_end\s+app_blob_code_end:\s+.*?section\s+\.appdata",
        text,
    )
    if not (has_appdata_tail and has_late_boundary):
        add(
            findings,
            "wx-code-data-boundary-missing",
            f"{rel}:1",
            "The app blob has no single page-aligned executable/writable boundary, so the kernel cannot prove whole-page W^X.",
            "Build any app with inline writable data and code on the same page.",
            "apps.asm does not both declare `.appdata follows=.text align=4096` and place `app_blob_code_end` after all app code.",
            "Declare `.appdata follows=.text align=4096`, then after all executable app includes `align 4096`, label `app_blob_code_end`, and switch to `.appdata` for the data tail.",
        )

    end_idx = text.find("app_blob_end:")
    if end_idx >= 0:
        last_appdata = text.rfind("section .appdata", 0, end_idx)
        last_text = text.rfind("section .text", 0, end_idx)
        if last_appdata < 0 or last_appdata < last_text:
            add(
                findings,
                "wx-data-tail-outside-blob",
                f"{rel}:{line_of(text, 'app_blob_end:')}",
                "The end sentinel can close the blob before `.appdata`, leaving writable app data outside APPS.BIN/signature/slot copy.",
                "Launch an app that references a compiler/state symbol routed to `.appdata`.",
                "`app_blob_end` is not emitted from the active `.appdata` section.",
                "Move the end sentinel and app_blob_end label into `.appdata` after all app writable data.",
            )

    state = root / "src/user/apps/state.inc"
    st = read_text(state)
    first_section = re.search(r"(?mi)^\s*section\s+\.(text|data|appdata)\b", st)
    if not first_section or first_section.group(1).lower() != "appdata":
        add(
            findings,
            "wx-state-not-appdata",
            f"{repo_path(root, state)}:{line_of(st, first_section.group(0)) if first_section else 1}",
            "Writable asm-glue state shares the executable app code window or falls outside the copied blob.",
            "Launch Notepad/Explorer/Paint/etc.; their seed/draw/key paths write state.inc symbols.",
            "state.inc does not start in `section .appdata`.",
            "Emit all writable app glue state in `.appdata` and restore `.text` at EOF.",
        )
    if not re.search(r"(?mi)^\s*section\s+\.text\s*$", st.splitlines()[-8] if len(st.splitlines()) >= 8 else st):
        tail = "\n".join(st.splitlines()[-12:])
        if not re.search(r"(?mi)^\s*section\s+\.text\s*$", tail):
            add(
                findings,
                "wx-state-section-not-restored",
                f"{repo_path(root, state)}:{len(st.splitlines())}",
                "The include following state.inc can be assembled into `.appdata`, making executable launch code W+NX.",
                "Build apps.asm; launch code after state.inc inherits the data section.",
                "No trailing `section .text` near EOF in state.inc.",
                "Restore `section .text` after the writable state block.",
            )


def check_apps_last_text_unit(root: Path, findings: list[Finding]) -> None:
    path = root / "src/kernel/kernel_build.asm"
    text = read_text(path)
    rel = repo_path(root, path)
    include = re.search(r'(?mi)^\s*%include\s+"src/user/apps\.asm"\s*$', text)
    if not include:
        add(
            findings,
            "wx-app-blob-not-in-kernel-build",
            f"{rel}:1",
            "The kernel build does not include the app blob where the W^X boundary proof expects it.",
            "Build the kernel; APPS.BIN extraction/signing cannot cover the expected blob.",
            '`%include "src/user/apps.asm"` not found.',
            "Include src/user/apps.asm as the final executable app-blob unit.",
        )
        return

    tail = text[include.end() :]
    for raw in tail.splitlines():
        line = strip_asm_comments(raw)
        if not line:
            continue
        if line in {"section .text", "section .bss", "alignb 16"}:
            continue
        if line in {"global _kernel_text_end", "_kernel_text_end:", "_bss_end:"}:
            continue
        add(
            findings,
            "wx-kernel-text-after-apps",
            f"{rel}:{line_of(text, raw)}",
            "Kernel executable bytes after apps.asm make `.appdata follows=.text` land after kernel code instead of immediately after app code; the W^X manifest can mark real app code W+NX.",
            "Build and launch any callback whose address is after the incorrectly early app_blob_code_end.",
            f"Unexpected content after apps.asm include: `{line}`.",
            "Keep apps.asm as the last `.text` content; only `_kernel_text_end` and BSS labels may follow it.",
        )
        return


def check_slot_interval_math(root: Path, findings: list[Finding]) -> None:
    constants = load_asm_constants(root)
    app_slot_size = constants.get("APP_SLOT_SIZE")
    guard = constants.get("L3_SLOT_USER_STACK_GUARD_OFF")
    if app_slot_size is None or guard is None:
        add(
            findings,
            "slot-interval-constants-unresolved",
            f"{repo_path(root, root / 'src/user/lib/grit_window.inc')}:1",
            "The scanner cannot resolve APP_SLOT_SIZE or L3_SLOT_USER_STACK_GUARD_OFF, so slot interval proofs cannot run.",
            "Any slot-local public buffer constant may overlap another region unnoticed.",
            "Required constants were not evaluable from boot_memory/constants/usermode_decls/grit_window includes.",
            "Keep slot layout constants as NASM `equ` expressions over resolvable integer constants.",
        )
        return

    source = root / "src/user/lib/grit_window.inc"
    text = read_text(source)
    rel = repo_path(root, source)
    regions: list[tuple[str, int, int, int]] = []
    for name, off in constants.items():
        m = re.fullmatch(r"APP_SLOT_(.+)_OFF", name)
        if not m:
            continue
        stem = m.group(1)
        size_name = f"APP_SLOT_{stem}_SZ"
        if size_name not in constants:
            continue
        size = constants[size_name]
        end = off + size
        regions.append((stem, off, size, end))
        line = line_of(text, name)
        if off < 0 or size < 0 or end > app_slot_size:
            add(
                findings,
                "slot-buffer-outside-slot",
                f"{rel}:{line}",
                "A public slot-local buffer interval extends outside the 2 MiB app slot, so a full-range user/kernel copy can fault or corrupt the next slot.",
                f"Use the full declared APP_SLOT_{stem}_SZ bytes starting at APP_SLOT_{stem}_OFF.",
                f"APP_SLOT_{stem}_OFF=0x{off:X}, APP_SLOT_{stem}_SZ=0x{size:X}, end=0x{end:X}, APP_SLOT_SIZE=0x{app_slot_size:X}.",
                "Move or shrink the buffer so off >= 0 and off + size <= APP_SLOT_SIZE.",
            )
        if off < app_slot_size and end > guard:
            overlap_lo = max(off, guard)
            overlap_hi = min(end, app_slot_size)
            add(
                findings,
                "slot-buffer-overlaps-stack-guard",
                f"{rel}:{line}",
                "A public slot-local buffer interval overlaps the non-present L3 user-stack guard page, so a full-range access deterministically raises #PF.",
                f"Write/read APP_SLOT_{stem}_SZ bytes from APP_SLOT_{stem}_OFF; bytes [0x{overlap_lo:X},0x{overlap_hi:X}) land in the guard/stack tail.",
                f"APP_SLOT_{stem}_OFF=0x{off:X}, APP_SLOT_{stem}_SZ=0x{size:X}, guard starts at 0x{guard:X}.",
                "Move the buffer below L3_SLOT_USER_STACK_GUARD_OFF or shrink it so off + size <= L3_SLOT_USER_STACK_GUARD_OFF.",
            )

    for i, (a_name, a_off, _a_size, a_end) in enumerate(regions):
        for b_name, b_off, _b_size, b_end in regions[i + 1 :]:
            lo = max(a_off, b_off)
            hi = min(a_end, b_end)
            if lo < hi:
                add(
                    findings,
                    "slot-buffer-overlap",
                    f"{rel}:{line_of(text, 'APP_SLOT_' + a_name + '_OFF')}",
                    "Two public slot-local buffers overlap, so independent users of the constants corrupt each other deterministically.",
                    f"Use APP_SLOT_{a_name}_* and APP_SLOT_{b_name}_* in the same slot lifetime.",
                    f"APP_SLOT_{a_name}=[0x{a_off:X},0x{a_end:X}) overlaps APP_SLOT_{b_name}=[0x{b_off:X},0x{b_end:X}) at [0x{lo:X},0x{hi:X}).",
                    "Give each public slot-local buffer a disjoint interval.",
                )


def check_app_blob_size_artifact(root: Path, findings: list[Finding], notes: list[str]) -> None:
    constants = load_asm_constants(root)
    cap = constants.get("L3_APP_BLOB_PLACE_CAP")
    if cap is None:
        notes.append("[math-fault] APPS.BIN cap proof skipped: L3_APP_BLOB_PLACE_CAP unresolved.")
        return
    candidates = [
        root / "build/esp/EFI/BOOT/APPS.BIN",
        root / "build/APPS.BIN",
    ]
    apps_bin = next((p for p in candidates if p.is_file() and p.stat().st_size > 0), None)
    if apps_bin is None:
        notes.append(
            "[math-fault] APPS.BIN cap proof skipped: no non-empty APPS.BIN found at build/esp/EFI/BOOT/APPS.BIN or build/APPS.BIN."
        )
        return
    size = apps_bin.stat().st_size
    if size > cap:
        add(
            findings,
            "app-blob-exceeds-placement-cap",
            repo_path(root, apps_bin),
            "The built app blob cannot be placed below the L3 user-stack guard, so slot copy/slide math must overlap the guard or stack tail.",
            "Boot with this APPS.BIN and launch any copied app slot.",
            f"APPS.BIN size=0x{size:X}, L3_APP_BLOB_PLACE_CAP=0x{cap:X}.",
            "Reduce app blob size or raise the placement cap only with a corresponding safe slot layout change.",
        )


def check_ghl_literal_divide_by_zero(root: Path, findings: list[Finding]) -> None:
    op_re = re.compile(r"(?<![A-Za-z0-9_])([/%])\s*([+-]?(?:0x0+|0+))(?![A-Za-z0-9_])")
    for path in source_files(root, {".ghl"}):
        text = read_text(path)
        for line_no, line in enumerate(text.splitlines(), 1):
            code = strip_hash_comment(line)
            if not code.strip():
                continue
            # Remove quoted text so docs/examples in strings do not count.
            code_no_strings = re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', '""', code)
            m = op_re.search(code_no_strings)
            if not m:
                continue
            add(
                findings,
                "ghl-literal-divide-by-zero",
                f"{repo_path(root, path)}:{line_no}",
                "GritHL emits x86 idiv for `/` and `%`; a literal zero denominator deterministically raises #DE when the expression executes.",
                f"Execute line {line_no}; denominator is the literal `{m.group(2)}`.",
                line.strip(),
                "Reject zero before the operation, use a nonzero constant, or route through a helper that defines zero-denominator behavior.",
            )


WRITE_REG_RE = re.compile(r"^\s*(mov|xor|sub)\s+([A-Za-z][A-Za-z0-9]*)\s*,\s*(.+)$", re.I)
DIV_REG_RE = re.compile(r"^\s*(div|idiv)\s+([A-Za-z][A-Za-z0-9]*)\s*$", re.I)
LABEL_RE = re.compile(r"^\s*(?:global\s+)?[A-Za-z_.$?][A-Za-z0-9_.$?#@~]*:\s*$")
CONTROL_RE = re.compile(r"^\s*(call|ret|iretq|jmp|j[a-z]+|loop[a-z]*|syscall|int|ud2)\b", re.I)


def check_adjacent_asm_divide_by_zero(root: Path, findings: list[Finding]) -> None:
    for path in source_files(root, {".asm", ".inc"}):
        known_zero: dict[str, tuple[int, str]] = {}
        for line_no, raw in enumerate(read_text(path).splitlines(), 1):
            line = strip_asm_comments(raw)
            if not line:
                continue
            if LABEL_RE.match(line) or CONTROL_RE.match(line):
                known_zero.clear()
                continue

            dm = DIV_REG_RE.match(line)
            if dm:
                base = reg_base(dm.group(2))
                if base and base in known_zero:
                    z_line, z_text = known_zero[base]
                    add(
                        findings,
                        "asm-provable-divide-by-zero",
                        f"{repo_path(root, path)}:{line_no}",
                        "x86 div/idiv with a zero register operand deterministically raises #DE.",
                        f"Execute the straight-line block from line {z_line} through line {line_no}.",
                        f"line {z_line}: `{z_text}` proves {dm.group(2)} == 0; line {line_no}: `{line}` divides by it.",
                        "Load a nonzero divisor, add an explicit zero guard before div/idiv, or branch around the operation when the divisor is zero.",
                    )
                known_zero.clear()
                continue

            wm = WRITE_REG_RE.match(line)
            if not wm:
                # Conservative: unknown instruction may define registers or flags
                # that control the path; drop proofs rather than guessing.
                if re.match(r"^\s*[a-z][a-z0-9]*\b", line, re.I):
                    known_zero.clear()
                continue
            op, dst, src = wm.group(1).lower(), wm.group(2), wm.group(3).strip()
            base = reg_base(dst)
            if base is None:
                known_zero.clear()
                continue
            known_zero.pop(base, None)
            src_reg = reg_base(src)
            literal = parse_int_literal(src)
            if op == "xor" and src_reg == base:
                known_zero[base] = (line_no, line)
            elif op == "sub" and src_reg == base:
                known_zero[base] = (line_no, line)
            elif op == "mov" and literal == 0:
                known_zero[base] = (line_no, line)


LISTING_EMIT_RE = re.compile(r"^\s*\d+\s+([0-9A-Fa-f]{6,16})\s+([0-9A-Fa-f][0-9A-Fa-f<>rep \-]*)")


def first_emit_after(lines: Sequence[str], start_idx: int) -> int | None:
    for i in range(start_idx, min(len(lines), start_idx + 400)):
        m = LISTING_EMIT_RE.match(lines[i])
        if m:
            return int(m.group(1), 16)
    return None


def listing_label_addr(lines: Sequence[str], label: str) -> int | None:
    pat = re.compile(rf"\b{re.escape(label)}:\s*(?:;.*)?$")
    for i, line in enumerate(lines):
        if pat.search(line):
            return first_emit_after(lines, i + 1)
    return None


def listing_fn_addr(lines: Sequence[str], fn: str) -> int | None:
    pat = re.compile(rf"\bFN_BEGIN\s+{re.escape(fn)}\b|\b{re.escape(fn)}:\s*$")
    for i, line in enumerate(lines):
        if pat.search(line):
            return first_emit_after(lines, i + 1)
    return None


def choose_listing(root: Path, explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_absolute() else root / p
    candidates = [root / "build/KA.lst", root / "build/KB.lst", root / "build/_fault_map.lst"]
    usable: list[Path] = []
    for p in candidates:
        if p.is_file():
            try:
                sample = read_text(p)
            except OSError:
                continue
            if "app_blob_code_end:" in sample:
                usable.append(p)
    if not usable:
        return None
    return max(usable, key=lambda p: p.stat().st_mtime)


def callback_symbols(root: Path) -> list[str]:
    symbols: set[str] = {"app_l3_done_trampoline", "app_media_draw"}
    manifest = root / "src/user/grithl/apps"
    for src in manifest.glob("*.ghl"):
        prefix = f"app_hl_{src.stem}"
        for suffix in ("draw", "click", "key", "drag", "rclick"):
            symbols.add(f"{prefix}_{suffix}")

    launch_files = [root / "src/user/apps/launch_dispatch.inc", root / "src/kernel/gui/window_lifecycle.inc"]
    for path in launch_files:
        if not path.is_file():
            continue
        text = read_text(path)
        for m in re.finditer(r"\b(?:mov|lea)\s+r(?:9|10|11|ax|di)\s*,\s*(?:\[rel\s+)?([A-Za-z_][A-Za-z0-9_]*)(?:\])?", text):
            name = m.group(1)
            if name.startswith("app_hl_") or name.startswith("app_") and name.endswith(("_draw", "_click", "_key", "_drag", "_rclick")):
                symbols.add(name)
    return sorted(symbols)


def check_listing_geometry(root: Path, listing_path: Path | None, findings: list[Finding], notes: list[str]) -> None:
    if listing_path is None:
        notes.append("[math-fault] symbol geometry proof skipped: no listing with app_blob_code_end found (run a fresh UEFI build to enable it).")
        return
    if not listing_path.is_file():
        notes.append(f"[math-fault] symbol geometry proof skipped: listing not found: {listing_path}")
        return

    text = read_text(listing_path)
    if "app_blob_code_end:" not in text:
        notes.append(f"[math-fault] symbol geometry proof skipped: {repo_path(root, listing_path)} has no app_blob_code_end (stale listing).")
        return

    lines = text.splitlines()
    start = listing_label_addr(lines, "app_blob_start")
    split = listing_label_addr(lines, "app_blob_code_end")
    if start is None or split is None:
        add(
            findings,
            "wx-listing-boundary-unresolved",
            repo_path(root, listing_path),
            "The assembled listing names the W^X boundary but does not expose resolvable app_blob_start/app_blob_code_end addresses.",
            "Any launch relies on an unverified code/data split.",
            "Could not resolve emitted addresses for app_blob_start and app_blob_code_end from the NASM listing.",
            "Build with a NASM listing that includes emitted addresses, or keep labels adjacent to emitted bytes.",
        )
        return

    code_size = split - start
    if start % PAGE_SIZE != 0 or split % PAGE_SIZE != 0 or code_size <= 0:
        add(
            findings,
            "wx-listing-boundary-unaligned",
            repo_path(root, listing_path),
            "The assembled W^X boundary is not a positive whole-page code window.",
            "Launch any slot; l3_apply_wx_policy can only mark whole PTEs, so the split page cannot satisfy both code and data permissions.",
            f"app_blob_start=0x{start:X}, app_blob_code_end=0x{split:X}, code_size=0x{code_size:X}.",
            "Page-align app_blob_start and `.appdata follows=.text align=4096`.",
        )

    for sym in callback_symbols(root):
        addr = listing_fn_addr(lines, sym)
        if addr is None:
            continue
        rel = addr - start
        if rel < 0:
            add(
                findings,
                "wx-callback-outside-blob",
                f"{repo_path(root, listing_path)}:{sym}",
                "A registered callback target is outside the copied app blob, so target translation cannot safely make it executable in the slot.",
                f"Open/dispatch the window that registers `{sym}`.",
                f"{sym}=0x{addr:X}, app_blob_start=0x{start:X}.",
                "Keep every ring-3 callback symbol inside [app_blob_start, app_blob_code_end).",
            )
        elif rel >= code_size:
            add(
                findings,
                "wx-callback-in-wnx-tail",
                f"{repo_path(root, listing_path)}:{sym}",
                "A registered callback target lies at or beyond app_blob_code_end, so the default v1 manifest marks its page W+NX and the CPU will raise a user instruction-fetch #PF.",
                f"Open/dispatch the window that registers `{sym}`; call_app_l3 translates it into the slot and iretq fetches from an NX page.",
                f"{sym} offset=0x{rel:X}, code window=[0,0x{code_size:X}).",
                "Move the callback code back into `.text` before app_blob_code_end, or move app_blob_code_end after all executable app code and keep writable data in the later `.appdata` tail.",
            )


def render_text(findings: Sequence[Finding], notes: Sequence[str]) -> str:
    out: list[str] = ["[math-fault] deterministic fault scan"]
    out.extend(notes)
    if not findings:
        out.append("Result: PASS (0 mathematically triggerable fault(s))")
        return "\n".join(out)
    out.append(f"Result: FAIL ({len(findings)} mathematically triggerable fault(s))")
    for f in findings:
        out.append(f"[{f.rule}] {f.location}")
        out.append(f"  fault: {f.fault}")
        out.append(f"  trigger: {f.trigger}")
        out.append(f"  evidence: {f.evidence}")
        out.append(f"  fix: {f.fix}")
    return "\n".join(out)


def render_markdown(findings: Sequence[Finding], notes: Sequence[str]) -> str:
    out = ["# Mathematical Fault Scan", ""]
    if notes:
        out.extend(f"- {n}" for n in notes)
        out.append("")
    if not findings:
        out.append("PASS: 0 mathematically triggerable faults.")
        return "\n".join(out)
    out.append(f"FAIL: {len(findings)} mathematically triggerable fault(s).")
    out.append("")
    for f in findings:
        out.append(f"## {f.rule}")
        out.append("")
        out.append(f"- Location: `{f.location}`")
        out.append(f"- Fault: {f.fault}")
        out.append(f"- Trigger: {f.trigger}")
        out.append(f"- Evidence: {f.evidence}")
        out.append(f"- Fix: {f.fix}")
        out.append("")
    return "\n".join(out)


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="List deterministic, mathematically triggerable security faults.")
    ap.add_argument("--repo-root", default=".", help="repository root (default: current directory)")
    ap.add_argument("--format", choices=("text", "json", "markdown"), default="text")
    ap.add_argument("--output", help="optional report path")
    ap.add_argument("--listing", help="optional NASM listing for symbol geometry proof")
    ap.add_argument("--keep-temp", action="store_true", help="keep temporary generated app assembly")
    args = ap.parse_args(argv)

    root = Path(args.repo_root).resolve()
    findings: list[Finding] = []
    notes: list[str] = []
    temp_dir: Path | None = None

    try:
        temp_dir, generated, compile_notes = compile_user_apps(root, args.keep_temp)
        notes.extend(compile_notes)
        check_generated_app_sections(root, generated, findings)
        check_paging_fail_closed(root, findings)
        check_default_manifest(root, findings)
        check_blob_framing(root, findings)
        check_apps_last_text_unit(root, findings)
        check_slot_interval_math(root, findings)
        check_app_blob_size_artifact(root, findings, notes)
        check_ghl_literal_divide_by_zero(root, findings)
        check_adjacent_asm_divide_by_zero(root, findings)
        check_listing_geometry(root, choose_listing(root, args.listing), findings, notes)
    except Exception as exc:
        add(
            findings,
            "math-fault-checker-error",
            str(root),
            "The deterministic fault scanner could not complete, so the security suite cannot claim the mathematical-fault surface was checked.",
            "Run the security suite.",
            str(exc),
            "Fix the checker input/build error, then rerun this script.",
        )
    finally:
        if temp_dir is not None:
            cleanup_temp(temp_dir, args.keep_temp)

    if args.format == "json":
        report = json.dumps({"notes": list(notes), "findings": [asdict(f) for f in findings]}, indent=2)
    elif args.format == "markdown":
        report = render_markdown(findings, notes)
    else:
        report = render_text(findings, notes)

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(report + "\n", encoding="utf-8")
    print(report)
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
