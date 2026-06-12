#!/usr/bin/env python3
"""Embed src/resources/wallpapers/*.svg into wallpaper.ghl as escaped strings.

Updates the three (str <name> = "..."; const <NAME>_LEN = N) declarations in
src/user/grithl/apps/wallpaper.ghl so the native GritHL SVG renderer has the
current SVG source. If wallpaper.ghl uses the lightweight procedural renderer,
the declarations are absent and this tool exits cleanly without changing it.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GHL = ROOT / "src" / "user" / "grithl" / "apps" / "wallpaper.ghl"

WALLPAPERS = (
    ("liquid_svg", "LIQUID_SVG_LEN", "liquid-metal.svg"),
    ("ribbons_svg", "RIBBONS_SVG_LEN", "glass-ribbons.svg"),
    ("bloom_svg", "BLOOM_SVG_LEN", "frosted-bloom.svg"),
)


def escape(raw: str) -> str:
    return raw.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main() -> int:
    text = GHL.read_text(encoding="utf-8")
    if "LIQUID_SVG_LEN" not in text:
        print("[wallpaper-strings] SVG wallpaper strings not present; skipping")
        return 0
    for var, length_const, svg_name in WALLPAPERS:
        raw = (ROOT / "src" / "resources" / "wallpapers" / svg_name).read_text(encoding="utf-8")
        esc = escape(raw)
        byte_len = len(raw.encode("utf-8"))
        str_pat = re.compile(rf'(str\s+{var}\s*=\s*")(?:\\.|[^"\\])*(";)')
        len_pat = re.compile(rf'(const\s+{length_const}\s*=\s*)\d+')
        new_text, n1 = str_pat.subn(lambda m: m.group(1) + esc + m.group(2), text, count=1)
        if n1 != 1:
            raise SystemExit(f"failed to find str {var} declaration")
        new_text, n2 = len_pat.subn(lambda m: m.group(1) + str(byte_len), new_text, count=1)
        if n2 != 1:
            raise SystemExit(f"failed to find const {length_const} declaration")
        text = new_text
        print(f"[wallpaper-strings] {svg_name} -> {var} ({byte_len} bytes)")
    GHL.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
