#!/usr/bin/env python3
"""Check signature instrumentation coverage for the active migration slice."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from build_sig_registry import collect

FN_BEGIN_RE = re.compile(r"^\s*FN_BEGIN(?:_FULL)?\s+([A-Za-z_.$][\w.$]*)\s*,")
GLOBAL_RE = re.compile(r"^\s*global\s+(.+)$")
LABEL_RE = re.compile(r"^\s*([A-Za-z_.$][\w.$]*):")

DATA_GLOBAL_ALLOW = {
    "wm_window_count",
    "wm_focused_window",
    "wm_drag_window_id",
    "wm_drag_preview_x",
    "wm_drag_preview_y",
    "wm_drag_preview_w",
    "wm_drag_preview_h",
    "syscall_count",
    "kernel_canary",
    "slot_sc_budget",
}

CONTROL_ALLOW = {
    # The raw SYSCALL landing path must not call helpers until it has switched
    # to the per-slot kernel stack. It emits syscall trace records after PUSH_ALL.
    "syscall_entry",
    # Panic landing pad: reached only on canary mismatch, halts the CPU. Cannot
    # safely run FN_BEGIN trace push/call sequence on a corrupted stack frame.
    "kernel_panic_canary",
    # Shadow-stack panic landing pad: reached only on a shadow/return-address
    # mismatch (KEPILOGUE), halts the CPU. Same constraint as the canary pad -
    # the stack frame it lands on is, by definition, suspect.
    "kernel_panic_shadow",
    # Build-gated (-dENABLE_SHADOW_STACK_POC) shadow-stack proof harness. It
    # switches RSP onto a syscall stack and calls a protected stub by hand, so
    # it cannot run the FN_BEGIN trace push/call sequence.
    "shadow_stack_poc_run",
}


def strip_comment(line: str) -> str:
    return line.split(";", 1)[0].strip()


def instrumented_names(path: Path) -> set[str]:
    out: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = FN_BEGIN_RE.match(line)
        if m:
            out.add(m.group(1))
    return out


def global_names_with_labels(path: Path) -> set[str]:
    globals_seen: set[str] = set()
    labels: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        clean = strip_comment(line)
        gm = GLOBAL_RE.match(clean)
        if gm:
            for name in gm.group(1).split(","):
                name = name.strip()
                if name:
                    globals_seen.add(name)
            continue
        lm = LABEL_RE.match(clean)
        if lm:
            labels.add(lm.group(1))
    return globals_seen & labels


def check_file(path: Path) -> list[str]:
    required = global_names_with_labels(path) - DATA_GLOBAL_ALLOW - CONTROL_ALLOW
    present = instrumented_names(path)
    return [f"{path}: global {name} missing FN_BEGIN" for name in sorted(required - present)]


def check_macro_stubs(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    errors = []
    for macro, marker in (
        ("ISR_NOERRCODE", "FN_BEGIN isr_%1"),
        ("ISR_ERRCODE", "FN_BEGIN isr_%1"),
        ("IRQ_STUB", "FN_BEGIN irq_%1"),
    ):
        m = re.search(rf"%macro\s+{macro}\b(?P<body>.*?)%endmacro", text, re.S)
        if not m:
            errors.append(f"{path}: macro {macro} missing")
        elif marker not in m.group("body"):
            errors.append(f"{path}: macro {macro} missing {marker}")
    return errors


def check_hash_collisions(root: Path) -> list[str]:
    by_hash: dict[int, list[str]] = {}
    by_hash32: dict[int, list[str]] = {}
    for entry in collect(root):
        by_hash.setdefault(int(entry["fn_id"]), []).append(entry["name"])
        by_hash32.setdefault(int(entry["fn_id"]) & 0xFFFFFFFF, []).append(entry["name"])
    errors = []
    for fn_id, names in sorted(by_hash.items()):
        unique = sorted(set(names))
        if len(unique) > 1:
            errors.append(f"hash collision 0x{fn_id:016x}: {', '.join(unique)}")
    for fn_id, names in sorted(by_hash32.items()):
        unique = sorted(set(names))
        if len(unique) > 1:
            errors.append(f"runtime hash32 collision 0x{fn_id:08x}: {', '.join(unique)}")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=Path(__file__).resolve().parents[1])
    args = ap.parse_args()

    root = Path(args.root).resolve()
    errors: list[str] = []
    for rel in ("src/kernel/proc/syscall.asm", "src/kernel/gui/window.asm"):
        errors.extend(check_file(root / rel))
    errors.extend(check_macro_stubs(root / "src/include/macros.inc"))
    errors.extend(check_hash_collisions(root))

    if errors:
        for err in errors:
            print(f"[coverage] {err}", file=sys.stderr)
        return 1
    print("[coverage] signature coverage OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
