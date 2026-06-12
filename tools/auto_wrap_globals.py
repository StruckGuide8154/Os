#!/usr/bin/env python3
"""Auto-wrap `global X` + `X:` patterns into `FN_BEGIN X, ...`.

For every `.asm` file in the configured slice, the script:

  * locates every line matching ``\\s*global NAME``;
  * finds the matching label ``NAME:`` somewhere later in the file;
  * if the label is not already preceded by an ``FN_BEGIN`` or ``FN_DECL``,
    rewrites the ``global NAME`` line to a stub comment and replaces the
    ``NAME:`` label with ``FN_BEGIN NAME, 0, 0, FN_RET_SCALAR`` (default
    signature - argc/kindmask are placeholders the author can refine later).

Existing FN_BEGIN'd functions are left untouched.  An allowlist skips data
symbols (``wm_window_count`` etc.) and special-purpose entry points where
runtime tracing is unsafe (the ISR/IRQ landing pads already use FN_DECL).

The script is idempotent: re-running over already-wrapped files is a no-op.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

GLOBAL_RE = re.compile(r"^\s*global\s+([A-Za-z_.$][\w.$]*)\s*$")
LABEL_RE_TPL = r"^(?P<indent>\s*){name}\s*:\s*(?:;.*)?$"

# Symbols that are data, not functions - never wrap.
DATA_ALLOW = {
    "wm_window_count",
    "wm_focused_window",
    "wm_drag_window_id",
    "wm_drag_preview_x",
    "wm_drag_preview_y",
    "wm_drag_preview_w",
    "wm_drag_preview_h",
    "syscall_count",
    "tick_count",
    "trace_seq",
    "trace_active_slot",
    "sig_registry_start",
    "sig_registry_end",
    "xhci_op_base",
    "xhci_max_ports",
    "usb_slot2_id",
    "usb_hid_protocol2",
    "usb_no_xhci",
    "usb_use_parsed",
    "usb_kb_prev_keys",
    "usb_kb_prev_mods",
    "kb_buffer",
    "kb_repeat_scancode",
    "kb_repeat_ascii",
    "kb_repeat_next_tick",
    "mouse_buttons",
    "mouse_im_mode",
    "mouse_pinch_delta",
    "gesture_swipe_dir",
    "gesture_pinch_dist_prev",
    "gesture_scroll_ref_x",
    "hid_parsed_is_absolute",
    "hid_parsed_conf_bit_offset",
    "hid_parsed_conf_size",
    "hid_f1_x",
}

# Functions where an inserted call to trace_fn_enter would be unsafe (raw
# entry trampolines, syscall landing pad, etc.).  Use FN_DECL instead.
DECL_ONLY = {
    "syscall_landing",
    "isr_common_stub",
    "irq_common_stub",
    "kernel_entry",
    "_start",
}


def process_file(path: Path, dry_run: bool) -> tuple[int, int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines(keepends=True)
    wrapped = 0
    skipped = 0

    # Index globals declared in this file
    targets = []  # (line_idx, name)
    for i, line in enumerate(lines):
        m = GLOBAL_RE.match(line)
        if m:
            name = m.group(1)
            if name in DATA_ALLOW:
                continue
            targets.append((i, name))

    # For each, find its label and check if already instrumented
    for global_idx, name in targets:
        label_re = re.compile(LABEL_RE_TPL.format(name=re.escape(name)), re.MULTILINE)
        label_idx = None
        for j in range(len(lines)):
            if label_re.match(lines[j]):
                label_idx = j
                break
        if label_idx is None:
            skipped += 1
            continue
        # Look backwards for an existing FN_BEGIN/FN_DECL within ~3 lines
        already = False
        for k in range(max(0, label_idx - 3), label_idx):
            if "FN_BEGIN" in lines[k] or "FN_DECL" in lines[k]:
                already = True
                break
        if already:
            continue
        # Replace the label line with FN_BEGIN
        macro = "FN_DECL" if name in DECL_ONLY else "FN_BEGIN"
        m = re.match(LABEL_RE_TPL.format(name=re.escape(name)), lines[label_idx])
        indent = m.group("indent") if m else ""
        lines[label_idx] = f"{indent}{macro} {name}, 0, 0, FN_RET_SCALAR\n"
        # Comment out the original `global NAME` (FN_BEGIN re-emits it)
        lines[global_idx] = re.sub(
            r"^(\s*)global\s+",
            r"\1; auto-wrapped (FN_BEGIN emits global): global ",
            lines[global_idx],
        )
        wrapped += 1

    if wrapped and not dry_run:
        path.write_text("".join(lines), encoding="utf-8")
    return wrapped, skipped


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=Path(__file__).resolve().parents[1])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("paths", nargs="*", help="explicit .asm files; default = curated kernel slice")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    if args.paths:
        files = [Path(p).resolve() for p in args.paths]
    else:
        files = [
            root / "src/kernel/proc/syscall.asm",
            root / "src/kernel/proc/usermode.asm",
            root / "src/kernel/proc/process.asm",
            root / "src/kernel/gui/window.asm",
            root / "src/kernel/gui/taskbar.asm",
            root / "src/kernel/core/main.asm",
            root / "src/kernel/core/memory.asm",
            root / "src/kernel/core/isr.asm",
            root / "src/kernel/drivers/usb_hid.asm",
            root / "src/kernel/drivers/display.asm",
            root / "src/kernel/drivers/hid_parser.asm",
            root / "src/kernel/fs/fat16.asm",
            root / "src/kernel/arch/apic.asm",
        ]

    total_wrapped = 0
    for f in files:
        if not f.exists():
            print(f"  (skip, not found) {f}")
            continue
        w, s = process_file(f, args.dry_run)
        total_wrapped += w
        print(f"  {f.relative_to(root)}: wrapped={w} unresolved={s}")
    verb = "would wrap" if args.dry_run else "wrapped"
    print(f"\nauto_wrap: {verb} {total_wrapped} functions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
