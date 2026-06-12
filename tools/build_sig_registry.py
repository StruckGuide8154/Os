#!/usr/bin/env python3
"""Build a Grit function signature registry from NASM sources.

The kernel currently builds as one flat NASM translation unit, so there are no
object files to scrape in the normal build. This pass reads FN_BEGIN/FN_ARG
macro uses from source/generated assembly and emits both a NASM include and a
JSON sidecar for offline tooling.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

FN_BEGIN_HEAD_RE = re.compile(r"^\s*(?:FN_BEGIN(?:_FULL)?|FN_DECL)\s+(.*)$")
FN_ARG_HEAD_RE = re.compile(r"^\s*FN_ARG\s+(.*)$")
NAME_RE = re.compile(r"^[A-Za-z_.$][\w.$]*$")
ISR_NOERR_RE = re.compile(r"^\s*ISR_NOERRCODE\s+(\d+)")
ISR_ERR_RE = re.compile(r"^\s*ISR_ERRCODE\s+(\d+)")
IRQ_RE = re.compile(r"^\s*IRQ_STUB\s+(\d+)\s*,")


def strip_comment(text: str) -> str:
    """Drop a trailing NASM ``;`` comment.  Operands here are identifiers and
    macro invocations with no string literals, so a plain split is safe."""
    idx = text.find(";")
    return text if idx < 0 else text[:idx]


def split_top_commas(text: str) -> list[str]:
    """Split on commas that sit at paren/bracket depth 0 so macro arguments
    like ``SC_KIND3(a, b, c)`` stay in a single field."""
    parts: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in text:
        if ch in "([":
            depth += 1
            cur.append(ch)
        elif ch in ")]":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur).strip())
    return parts


def fnv1a64(text: str) -> int:
    h = 0xCBF29CE484222325
    for b in text.encode("utf-8"):
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def iter_asm_files(root: Path):
    for base in (root / "src", root / "build" / "ghl"):
        if base.exists():
            yield from sorted(base.rglob("*.asm"))
            yield from sorted(base.rglob("*.inc"))


def parse_file(path: Path, root: Path):
    current = None
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line_no, line in enumerate(f, 1):
            m = FN_BEGIN_HEAD_RE.match(line)
            if m:
                fields = split_top_commas(strip_comment(m.group(1)))
                if len(fields) < 4 or not NAME_RE.match(fields[0]):
                    continue
                name, argc, kindmask, retkind = fields[:4]
                current = {
                    "fn_id": fnv1a64(name),
                    "name": name,
                    "argc": argc,
                    "kindmask": kindmask,
                    "retkind": retkind,
                    "source": path.relative_to(root).as_posix(),
                    "line": line_no,
                    "args": [],
                }
                yield current
                continue
            m = FN_ARG_HEAD_RE.match(line)
            if m and current is not None:
                fields = split_top_commas(strip_comment(m.group(1)))
                if len(fields) >= 3 and NAME_RE.match(fields[1]):
                    idx, arg_name, kind = fields[0], fields[1], fields[2]
                    current["args"].append({"index": idx, "name": arg_name, "kind": kind})
                continue
            for rx, prefix in ((ISR_NOERR_RE, "isr_"), (ISR_ERR_RE, "isr_"), (IRQ_RE, "irq_")):
                m = rx.match(line)
                if m:
                    name = prefix + m.group(1)
                    current = {
                        "fn_id": fnv1a64(name),
                        "name": name,
                        "argc": "0",
                        "kindmask": "0",
                        "retkind": "FN_RET_VOID",
                        "source": path.relative_to(root).as_posix(),
                        "line": line_no,
                        "args": [],
                    }
                    yield current
                    break


def collect(root: Path):
    """Collect signatures.  Fail the build on duplicate name OR fn_id collision."""
    by_name: dict[str, dict] = {}
    by_id: dict[int, dict] = {}
    errors: list[str] = []
    for path in iter_asm_files(root):
        for entry in parse_file(path, root):
            name = entry["name"]
            fid = entry["fn_id"]
            if name in by_name:
                prev = by_name[name]
                errors.append(
                    f"duplicate FN_BEGIN name {name!r}: "
                    f"{prev['source']}:{prev['line']} and {entry['source']}:{entry['line']}"
                )
                continue
            if fid in by_id:
                prev = by_id[fid]
                errors.append(
                    f"hash collision 0x{fid:016x} between {prev['name']} "
                    f"({prev['source']}:{prev['line']}) and {name} "
                    f"({entry['source']}:{entry['line']})"
                )
                continue
            by_name[name] = entry
            by_id[fid] = entry
    if errors:
        for e in errors:
            print(f"sig_registry: ERROR: {e}", file=sys.stderr)
        raise SystemExit(2)
    return [by_name[k] for k in sorted(by_name)]


def nasm_quote(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_inc(entries, out_path: Path):
    lines = [
        "; Generated by tools/build_sig_registry.py - do not edit by hand",
        "section .rodata",
        "align 8",
        "global sig_registry_start",
        "global sig_registry_end",
        "sig_registry_start:",
    ]
    for e in entries:
        label = "sig_name_" + re.sub(r"\W", "_", e["name"])
        src_label = label + "_src"
        lines.extend(
            [
                f"    dq 0x{e['fn_id']:016x}",
                f"    dq {label}",
                f"    db {e['argc']}",
                f"    dd {e['kindmask']}",
                f"    db {e['retkind']}",
                f"    dq {src_label}",
                f"    dd {e['line']}",
            ]
        )
    lines.append("sig_registry_end:")
    for e in entries:
        label = "sig_name_" + re.sub(r"\W", "_", e["name"])
        src_label = label + "_src"
        lines.append(f"{label}: db {nasm_quote(e['name'])}, 0")
        lines.append(f"{src_label}: db {nasm_quote(e['source'])}, 0")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_hashes(entries, out_path: Path):
    lines = ["; Generated by tools/build_sig_registry.py - do not edit by hand"]
    for e in entries:
        lines.append(f"%define {e['name']}__hash 0x{e['fn_id']:016x}")
        lines.append(f"%define {e['name']}__hash32 0x{e['fn_id'] & 0xffffffff:08x}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=Path(__file__).resolve().parents[1])
    ap.add_argument("--inc", default="build/sig_registry.inc")
    ap.add_argument("--hashes", default="build/sig_hashes.inc")
    ap.add_argument("--json", default="build/sig_registry.json")
    ap.add_argument("--print", action="store_true", dest="do_print")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    entries = collect(root)
    write_inc(entries, root / args.inc)
    write_hashes(entries, root / args.hashes)
    out_json = root / args.json
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")

    if args.do_print:
        for e in entries:
            print(
                f"0x{e['fn_id']:016x} {e['name']} argc={e['argc']} "
                f"kindmask={e['kindmask']} ret={e['retkind']} {e['source']}:{e['line']}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
