#!/usr/bin/env python3
"""Validate and compile Grit's unified CPU-only theme specification.

The JSON file is authoring input only. The OS never parses JSON/XML at runtime:
this tool emits NASM constants, GritHL seed tables, and NPL1 binary palettes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "assets" / "themes" / "theme-spec.json"
CONSTANTS_PATH = ROOT / "src" / "include" / "constants.inc"
THEME_GHL_PATH = ROOT / "src" / "user" / "grithl" / "lib" / "theme.ghl"
ACTIVE_PATH = ROOT / "assets" / "themes" / "ACTIVE"
BEGIN = "THEME-GENERATED-BEGIN"
END = "THEME-GENERATED-END"
COLOR_RE = re.compile(r"^#[0-9A-F]{6}$")
NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
MAX_SPEC_BYTES = 128 * 1024
MAX_THEMES = 16
MAX_TOKENS = 64


class ThemeError(ValueError):
    pass


def _reject_duplicates(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ThemeError(f"duplicate JSON key: {key}")
        out[key] = value
    return out


def load_spec(path: Path = SPEC_PATH) -> tuple[dict, bytes]:
    raw = path.read_bytes()
    if len(raw) > MAX_SPEC_BYTES:
        raise ThemeError(f"theme spec exceeds {MAX_SPEC_BYTES} bytes")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ThemeError("theme spec must be ASCII") from exc
    try:
        spec = json.loads(text, object_pairs_hook=_reject_duplicates)
    except (json.JSONDecodeError, ThemeError) as exc:
        raise ThemeError(f"invalid theme spec: {exc}") from exc
    validate_spec(spec)
    canonical = (json.dumps(spec, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
    return spec, canonical


def _rgb(value: str) -> tuple[int, int, int]:
    return tuple(int(value[i : i + 2], 16) for i in (1, 3, 5))


def _luminance(value: str) -> float:
    values = []
    for channel in _rgb(value):
        c = channel / 255.0
        values.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722


def _contrast(a: str, b: str) -> float:
    la, lb = _luminance(a), _luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def validate_spec(spec: dict) -> None:
    if not isinstance(spec, dict) or set(spec) != {"schema", "active", "tokens", "themes", "contrast"}:
        raise ThemeError("top level must contain exactly schema, active, tokens, themes, contrast")
    if spec["schema"] != 1:
        raise ThemeError("unsupported theme schema; expected 1")
    tokens = spec["tokens"]
    themes = spec["themes"]
    if not isinstance(tokens, list) or not 1 <= len(tokens) <= MAX_TOKENS:
        raise ThemeError(f"tokens must contain 1..{MAX_TOKENS} entries")
    if len(tokens) != len(set(tokens)):
        raise ThemeError("token names must be unique")
    if any(not isinstance(t, str) or not NAME_RE.fullmatch(t) for t in tokens):
        raise ThemeError("token names must match [a-z][a-z0-9_]{0,31}")
    if not isinstance(themes, dict) or not 1 <= len(themes) <= MAX_THEMES:
        raise ThemeError(f"themes must contain 1..{MAX_THEMES} entries")
    if spec["active"] not in themes:
        raise ThemeError("active theme does not exist")
    expected = set(tokens)
    for name, theme in themes.items():
        if not NAME_RE.fullmatch(name):
            raise ThemeError(f"invalid theme name: {name!r}")
        if not isinstance(theme, dict) or set(theme) != {"display_name", "colors"}:
            raise ThemeError(f"theme {name} must contain exactly display_name and colors")
        display = theme["display_name"]
        if not isinstance(display, str) or not 1 <= len(display) <= 48 or not display.isascii():
            raise ThemeError(f"theme {name} display_name must be 1..48 ASCII characters")
        colors = theme["colors"]
        if not isinstance(colors, dict) or set(colors) != expected:
            missing = sorted(expected - set(colors)) if isinstance(colors, dict) else sorted(expected)
            extra = sorted(set(colors) - expected) if isinstance(colors, dict) else []
            raise ThemeError(f"theme {name} token mismatch; missing={missing}, extra={extra}")
        for token, color in colors.items():
            if not isinstance(color, str) or not COLOR_RE.fullmatch(color):
                raise ThemeError(f"{name}.{token} must be uppercase #RRGGBB")
    if not isinstance(spec["contrast"], list) or len(spec["contrast"]) > 32:
        raise ThemeError("contrast must be a list with at most 32 rules")
    for index, rule in enumerate(spec["contrast"]):
        if not isinstance(rule, dict) or set(rule) != {"foreground", "background", "minimum"}:
            raise ThemeError(f"contrast rule {index} has an invalid shape")
        fg, bg, minimum = rule["foreground"], rule["background"], rule["minimum"]
        if fg not in expected or bg not in expected:
            raise ThemeError(f"contrast rule {index} names an unknown token")
        if isinstance(minimum, bool) or not isinstance(minimum, (int, float)) or not 1 <= minimum <= 21:
            raise ThemeError(f"contrast rule {index} minimum must be between 1 and 21")
        for name, theme in themes.items():
            ratio = _contrast(theme["colors"][fg], theme["colors"][bg])
            if ratio + 1e-9 < minimum:
                raise ThemeError(
                    f"{name}: {fg} on {bg} contrast {ratio:.2f} is below required {minimum:.2f}"
                )


def _hex(color: str) -> str:
    return "0x00" + color[1:]


def _digest(canonical: bytes) -> str:
    return hashlib.sha256(canonical).hexdigest()


def kernel_block(spec: dict, digest: str) -> str:
    c = spec["themes"][spec["active"]]["colors"]
    lines = [
        f"; {BEGIN} - generated by tools/theme_tool.py; DO NOT EDIT",
        f"; source-sha256: {digest}",
        f"THEME_SCHEMA_VERSION equ {spec['schema']}",
        f"THEME_TOKEN_COUNT    equ {len(spec['tokens'])}",
    ]
    for index, token in enumerate(spec["tokens"]):
        lines.append(f"THEME_TOKEN_{token.upper():<24} equ {index}")
    lines.extend(
        [
            "",
            f"COLOR_BG_BASE        equ {_hex(c['bg_base'])}",
            f"COLOR_SURFACE_1       equ {_hex(c['surface'])}",
            f"COLOR_SURFACE_2       equ {_hex(c['surface_2'])}",
            f"COLOR_BORDER          equ {_hex(c['border'])}",
            f"COLOR_BORDER_STRONG   equ {_hex(c['border_2'])}",
            f"COLOR_TEXT_PRIMARY    equ {_hex(c['text'])}",
            f"COLOR_TEXT_SECONDARY  equ {_hex(c['text_muted'])}",
            f"COLOR_TEXT_TERTIARY   equ {_hex(c['text_tertiary'])}",
            f"COLOR_ACCENT_LIGHT    equ {_hex(c['accent_hover'])}",
            f"COLOR_ACCENT          equ {_hex(c['accent'])}",
            f"COLOR_ACCENT_DARK     equ {_hex(c['accent_pressed'])}",
            f"COLOR_ERROR           equ {_hex(c['error'])}",
            f"COLOR_WARNING         equ {_hex(c['warning'])}",
            f"COLOR_SUCCESS         equ {_hex(c['success'])}",
            f"COLOR_CLOSE_HOVER     equ {_hex(c['close_hover'])}",
            f"COLOR_CURSOR          equ {_hex(c['cursor'])}",
            f"COLOR_TASKBAR_BG       equ {_hex(c['taskbar_bg'])}",
            f"COLOR_TASKBAR_SURFACE  equ {_hex(c['taskbar_surface'])}",
            f"COLOR_TITLEBAR         equ {_hex(c['titlebar_active'])}",
            f"COLOR_TITLEBAR_UNF     equ {_hex(c['titlebar_inactive'])}",
            f"COLOR_TITLE_TEXT       equ {_hex(c['titlebar_text_active'])}",
            f"COLOR_TITLE_TEXT_UNF   equ {_hex(c['titlebar_text_inactive'])}",
            f"COLOR_MENU_BG          equ {_hex(c['menu'])}",
            f"COLOR_DROPDOWN_BG      equ {_hex(c['dropdown'])}",
            f"; {END}",
        ]
    )
    return "\n".join(lines)


def ghl_block(spec: dict, digest: str) -> str:
    lines = [
        f"# {BEGIN} - generated by tools/theme_tool.py; DO NOT EDIT",
        f"# source-sha256: {digest}",
        f"const THEME_SCHEMA_VERSION = {spec['schema']}",
    ]
    for index, token in enumerate(spec["tokens"]):
        lines.append(f"const TC_{token.upper()} = {index}")
    lines.append(f"const TC_COUNT = {len(spec['tokens'])}")
    lines.append(f"const THEME_ACTIVE_ID = {list(spec['themes']).index(spec['active'])}")
    for theme_id, (name, theme) in enumerate(spec["themes"].items()):
        lines.append(f"const THEME_{name.upper()} = {theme_id}")
        lines.append(f"fn theme_seed_{name}() {{")
        for token in spec["tokens"]:
            lines.append(f"    sq(theme_slot_addr(TC_{token.upper()}), {_hex(theme['colors'][token])});")
        lines.append("}")
    lines.append("fn theme_seed_active() {")
    lines.append(f"    theme_seed_{spec['active']}();")
    lines.append("}")
    lines.append(f"# {END}")
    return "\n".join(lines)


def _replace_block(path: Path, block: str, prefix: str) -> str:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"(?ms)^{re.escape(prefix)} {BEGIN}.*?^{re.escape(prefix)} {END}(?:\r?\n)?"
    )
    if not pattern.search(text):
        raise ThemeError(f"generated markers missing from {path.relative_to(ROOT)}")
    return pattern.sub(block + "\n", text, count=1)


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def _npl(spec: dict, theme_name: str) -> bytes:
    payload = bytearray()
    for token in spec["tokens"]:
        payload.extend(_rgb(spec["themes"][theme_name]["colors"][token]))
    return b"NPL1" + struct.pack("<HBB", len(spec["tokens"]), 3, 0) + payload


def expected_outputs(spec: dict, canonical: bytes) -> dict[Path, bytes]:
    digest = _digest(canonical)
    constants = _replace_block(CONSTANTS_PATH, kernel_block(spec, digest), ";")
    theme_ghl = _replace_block(THEME_GHL_PATH, ghl_block(spec, digest), "#")
    outputs = {
        CONSTANTS_PATH: constants.encode("utf-8"),
        THEME_GHL_PATH: theme_ghl.encode("utf-8"),
        ACTIVE_PATH: (spec["active"].upper() + "\n").encode("ascii"),
    }
    for name in spec["themes"]:
        palette = _npl(spec, name)
        outputs[ROOT / "assets" / "themes" / name / "palette.npl"] = palette
        outputs[ROOT / "src" / "resources" / "design-system" / f"palette_{name}.npl"] = palette
    return outputs


def cmd_generate(check: bool) -> int:
    spec, canonical = load_spec()
    stale = []
    for path, expected in expected_outputs(spec, canonical).items():
        actual = path.read_bytes() if path.exists() else None
        if actual != expected:
            stale.append(path)
            if not check:
                _atomic_write(path, expected)
    if check and stale:
        for path in stale:
            print(f"stale generated theme output: {path.relative_to(ROOT)}", file=sys.stderr)
        print("run: python tools/theme_tool.py generate", file=sys.stderr)
        return 1
    action = "verified" if check else "generated"
    print(f"theme {action}: {spec['active']} ({len(spec['tokens'])} tokens, {_digest(canonical)[:12]})")
    return 0


def cmd_show() -> int:
    spec, canonical = load_spec()
    print(f"schema={spec['schema']} active={spec['active']} sha256={_digest(canonical)}")
    for name, theme in spec["themes"].items():
        marker = "*" if name == spec["active"] else " "
        print(f"{marker} {name}: {theme['display_name']}")
        for token in spec["tokens"]:
            print(f"    {token:<24} {theme['colors'][token]}")
    return 0


def _write_spec(spec: dict) -> None:
    # Human-readable form is stable too: token/theme insertion order is the ABI
    # order and must not be alphabetically rearranged.
    data = (json.dumps(spec, indent=2, ensure_ascii=True) + "\n").encode("ascii")
    _atomic_write(SPEC_PATH, data)


def cmd_activate(name: str) -> int:
    spec, _ = load_spec()
    if name not in spec["themes"]:
        raise ThemeError(f"unknown theme {name!r}; choose from: {', '.join(spec['themes'])}")
    spec["active"] = name
    validate_spec(spec)
    _write_spec(spec)
    return cmd_generate(False)


def cmd_set(theme: str, token: str, color: str) -> int:
    spec, _ = load_spec()
    if theme not in spec["themes"]:
        raise ThemeError(f"unknown theme {theme!r}; choose from: {', '.join(spec['themes'])}")
    if token not in spec["tokens"]:
        raise ThemeError(f"unknown token {token!r}")
    color = color.upper()
    if not COLOR_RE.fullmatch(color):
        raise ThemeError("color must be #RRGGBB")
    candidate = json.loads(json.dumps(spec))
    candidate["themes"][theme]["colors"][token] = color
    validate_spec(candidate)
    _write_spec(candidate)
    return cmd_generate(False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate", help="strictly validate the canonical specification")
    sub.add_parser("check", help="validate and fail if generated outputs are stale")
    sub.add_parser("generate", help="validate and atomically refresh generated outputs")
    sub.add_parser("show", help="print all resolved tokens")
    activate = sub.add_parser("activate", help="select a build-wide theme and regenerate")
    activate.add_argument("theme")
    set_color = sub.add_parser("set", help="set one semantic color, validate, and regenerate")
    set_color.add_argument("theme")
    set_color.add_argument("token")
    set_color.add_argument("color")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            spec, canonical = load_spec()
            print(f"theme valid: {len(spec['themes'])} themes, {len(spec['tokens'])} tokens, {_digest(canonical)[:12]}")
            return 0
        if args.command == "check":
            return cmd_generate(True)
        if args.command == "generate":
            return cmd_generate(False)
        if args.command == "show":
            return cmd_show()
        if args.command == "activate":
            return cmd_activate(args.theme)
        return cmd_set(args.theme, args.token, args.color)
    except (OSError, ThemeError) as exc:
        print(f"theme error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
