#!/usr/bin/env python3
"""Symbolize GritOS trace dump records from serial logs."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TRACE_RE = re.compile(
    r"#(?P<seq>[0-9A-Fa-f]{16})\s+F(?P<fn>[0-9A-Fa-f]{16}):"
    r"(?P<flags>[0-9A-Fa-f]{16}):(?P<arg>[0-9A-Fa-f]{16}):(?P<parent>[0-9A-Fa-f]{16})"
)

FLAG_NAMES = (
    (0x01, "ENTER"),
    (0x02, "EXIT"),
    (0x04, "SYS_ENTER"),
    (0x08, "SYS_EXIT"),
    (0x10, "VALIDATE_FAIL"),
)


def load_symbols(path: Path) -> dict[int, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    out: dict[int, str] = {}
    for entry in data:
        fn_id = int(entry["fn_id"]) & 0xFFFFFFFF
        out[fn_id] = entry["name"]
    return out


def flags_text(flags: int) -> str:
    names = [name for bit, name in FLAG_NAMES if flags & bit]
    return "|".join(names) if names else f"0x{flags:x}"


def parse_records(text: str):
    for m in TRACE_RE.finditer(text):
        yield {
            "seq": int(m.group("seq"), 16),
            "fn": int(m.group("fn"), 16) & 0xFFFFFFFF,
            "flags": int(m.group("flags"), 16),
            "arg": int(m.group("arg"), 16),
            "parent": int(m.group("parent"), 16) & 0xFFFFFFFF,
        }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("serial_log")
    ap.add_argument("--registry", default="build/sig_registry.json")
    ap.add_argument("--expect", action="append", default=[])
    ap.add_argument("--min-records", type=int, default=1)
    ap.add_argument("--tail", type=int, default=64)
    args = ap.parse_args()

    symbols = load_symbols(Path(args.registry))
    text = Path(args.serial_log).read_text(encoding="ascii", errors="ignore")
    by_seq = {}
    for rec in parse_records(text):
        by_seq[rec["seq"]] = rec
    records = [by_seq[k] for k in sorted(by_seq)]
    if args.tail > 0:
        records = records[-args.tail:]
    if len(records) < args.min_records:
        print(f"[trace_replay] expected at least {args.min_records} records, saw {len(records)}", file=sys.stderr)
        return 1

    rendered = []
    for rec in records:
        name = symbols.get(rec["fn"], f"0x{rec['fn']:08x}")
        parent = symbols.get(rec["parent"], f"0x{rec['parent']:08x}") if rec["parent"] else "-"
        line = (
            f"{rec['seq']:08d} {flags_text(rec['flags']):<18} "
            f"{name:<32} parent={parent:<32} arg=0x{rec['arg']:016x}"
        )
        rendered.append(line)
        print(line)

    haystack = "\n".join(rendered)
    missing = [item for item in args.expect if item not in haystack]
    if missing:
        for item in missing:
            print(f"[trace_replay] missing expected symbol/text: {item}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
