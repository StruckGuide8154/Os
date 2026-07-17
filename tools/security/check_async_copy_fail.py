#!/usr/bin/env python3
"""
check_async_copy_fail.py - cross-path "Copy Fail" scanner (CVE-2026-31431 class).

WHAT THIS CLASS IS
------------------
A "Copy Fail" is a memory-safety bug you CANNOT see by reading one function. It
lives in the *relationship between two sibling code paths* that ingest the same
attacker/device-controlled buffer:

    * one path (usually the original, synchronous one) reads a device-reported
      length, CLAMPS it to the real buffer capacity, then hands [buf, buf+len)
      to a length-trusting frame/copy sink (net_rx_frame / *_handle_frame / a
      rep-movsb into a fixed buffer);
    * a SECOND path - typically an async tick/pump/poll added later - does the
      "same" ingest of the "same" buffer into the "same" sink, but drops the
      clamp.

Each function, read alone, looks fine: the sink is "just a helper", the length
is "just the frame length". The defect only appears when you line the two paths
up SPATIALLY and notice one enforces an invariant the other forgot. That is
exactly how the RTL8156 async-DHCP-pump OOB read (this repo) slipped in:
`rtl8156_consume_event` clamps the device rx_desc length to RTL8156_RX_MAX_FRAME,
but the async `rtl8156_dhcp_pump`, which reads the SAME buffer and calls the SAME
`rtl8156_handle_frame`, checked only the lower bound - letting a device length of
up to 32767 drive the IP/TCP/DNS parsers ~28 KiB past a 4 KiB DMA buffer.

WHAT THE SCANNER DOES
---------------------
1. It finds every "length ingest site": a function that reads a DEVICE-CONTROLLED
   RX length (a mask whose name ends in _LEN_MASK, or the r8152 opts1 literal
   0x7FFF/0x00007FFF applied with `&` / `and`) and then, later in the SAME
   function, reaches a length-trusting SINK (net_rx_frame, *_handle_frame,
   *_handle_udp, *_rx_ipv4, or a rep-movsb frame copy).
2. For each site it decides whether an UPPER-BOUND CLAMP to a capacity token
   (*_MAX_FRAME / *_DMA_LEN / *_BUF_LEN / *_BUF_SIZE / *_FRAME_MAX ...) gates the
   sink - i.e. appears on a line before the sink call.
3. It groups sites by the exact sink symbol they feed. If a sink is fed by BOTH a
   clamped sibling and an unclamped one, every unclamped site is reported as a
   Copy Fail, citing the clamped sibling as the proof the clamp is required
   (rule: copy-fail-sibling-divergence). An unclamped ingest with no clamped
   sibling is still reported (rule: copy-fail-unclamped-ingest), one severity
   lower.

It is deliberately conservative (the house rule for this suite): it only treats a
length as attacker-controlled when the source uses the repo's own
device-length-mask convention, so it does not fire on ordinary local length
arithmetic. `--selftest` proves it trips on a planted unclamped sibling and stays
silent once the clamp is added, so the guard cannot silently rot into a no-op.

Host-only, no build, no QEMU. Exit code 1 iff any Copy Fail is found.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence


SOURCE_TEXT_SUFFIXES = {".asm", ".inc", ".ghl"}

# A device-controlled RX length is recognised by the repo's own convention:
#   * any constant whose name ends in _LEN_MASK (RX_LEN_MASK, RTL8156_RX_LEN_MASK),
#   * or the r8152 rx_desc opts1 15-bit length literal, masked with & / and.
DEVICE_LEN_MASK_NAME = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*_LEN_MASK\b")
DEVICE_LEN_MASK_LIT = re.compile(r"0x0*7fff\b", re.IGNORECASE)

# Length-trusting sinks: they read `len` bytes from a caller pointer and hand them
# to protocol parsers or copy them, trusting `len` as the true buffer bound.
SINK_NAME = re.compile(
    r"\b("
    r"net_rx_frame"
    r"|[A-Za-z0-9_]*handle_frame"
    r"|[A-Za-z0-9_]*handle_udp"
    r"|[A-Za-z0-9_]*_rx_ipv4"
    r"|[A-Za-z0-9_]*_rx_frame"
    r")\b"
)

# An upper-bound clamp to a physical capacity token gates the sink.
CAPACITY_TOKEN = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*"
    r"(?:MAX_FRAME|FRAME_MAX|DMA_LEN|BUF_LEN|BUF_SIZE|RX_MAX|MAX_RX|RING_REMAIN)"
    r"[A-Za-z0-9_]*\b"
)

# rep movsb into a fixed frame/DMA buffer is the "copy" half of the class.
REP_MOVSB = re.compile(r"\brep\s+movsb\b", re.IGNORECASE)

GHL_FN_START = re.compile(r"^\s*(?:nonblocking\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
# A top-level asm label (not a `.local` sub-label) starts a new function block.
ASM_FN_LABEL = re.compile(r"^\s*(?:global\s+)?([A-Za-z_][A-Za-z0-9_$?]*):\s*(?:;.*)?$")


@dataclass
class Finding:
    rule: str
    location: str
    fault: str
    trigger: str
    evidence: str
    fix: str


@dataclass
class IngestSite:
    file: str          # repo-relative path
    func: str          # enclosing function / label
    sink: str          # exact sink symbol fed
    sink_line: int     # 1-based line of the sink call
    mask_line: int     # 1-based line of the device-length read
    clamped: bool      # an upper-bound clamp precedes the sink
    clamp_line: int    # 1-based line of the clamp (0 if none)
    mask_src: str      # the mask text (evidence)


def repo_path(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(path)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def source_files(root: Path) -> list[Path]:
    ignored = {".git", ".claude", "build", "dist", "worktrees", "__pycache__", "sandbox_shadow", "deprecated"}
    files: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in SOURCE_TEXT_SUFFIXES:
            continue
        rel_parts = path.resolve().relative_to(root.resolve()).parts
        if any(part in ignored for part in rel_parts):
            continue
        files.append(path)
    return sorted(files)


def strip_comment(line: str, is_asm: bool) -> str:
    """Remove trailing comments so prose in a comment cannot look like code.

    A `;` (asm) or `#` (ghl) starts a comment unless inside a quoted string.
    """
    marker = ";" if is_asm else "#"
    out: list[str] = []
    quote = ""
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = ""
            continue
        if ch in ('"', "'"):
            quote = ch
            out.append(ch)
            continue
        if ch == marker:
            break
        out.append(ch)
    return "".join(out)


def is_device_len_read(code: str) -> str | None:
    """Return the mask evidence if this line masks a value with a device-length
    mask (`& RX_LEN_MASK`, `and eax, 0x7FFF`, ...), else None. Requires an actual
    masking operation so a `const RX_LEN_MASK = ...` definition does not count."""
    # GHL / C-style bitwise-and, or asm `and reg, mask`.
    has_and_op = "&" in code or re.search(r"\band\s+[A-Za-z]", code, re.IGNORECASE)
    if not has_and_op:
        return None
    m = DEVICE_LEN_MASK_NAME.search(code)
    if m:
        return m.group(0)
    m = DEVICE_LEN_MASK_LIT.search(code)
    if m:
        return m.group(0)
    return None


def is_clamp(code: str) -> bool:
    """A comparison of a length against a physical-capacity token."""
    if not CAPACITY_TOKEN.search(code):
        return False
    # GHL relational compare or asm cmp.
    if re.search(r"[<>]=?", code):
        return True
    if re.search(r"\bcmp\b", code, re.IGNORECASE):
        return True
    return False


def sink_in(code: str) -> str | None:
    """Return the sink symbol if this line calls/branches into a length-trusting
    sink (or performs a rep-movsb frame copy), else None."""
    if REP_MOVSB.search(code):
        return "rep movsb"
    m = SINK_NAME.search(code)
    if not m:
        return None
    # Must look like a call/jump, not a definition of the sink itself.
    sym = m.group(1)
    if re.search(rf"\b(?:call|jmp)\s+{re.escape(sym)}\b", code, re.IGNORECASE):
        return sym                                   # asm call/jmp
    if re.search(rf"\bcall\s+{re.escape(sym)}\s*\(", code):
        return sym                                   # ghl `call sink(...)`
    if re.search(rf"(?<![A-Za-z0-9_]){re.escape(sym)}\s*\(", code) and not re.match(
        r"^\s*(?:nonblocking\s+)?fn\s", code
    ):
        return sym                                   # ghl `... = sink(...)`
    return None


def scan_function(rel: str, func: str, lines: list[tuple[int, str]], is_asm: bool) -> list[IngestSite]:
    """Walk one function/label block in order. A sink call that follows a
    device-length read WITHOUT an intervening clamp is an unclamped ingest."""
    sites: list[IngestSite] = []
    mask_line = 0
    mask_src = ""
    clamp_line = 0
    for line_no, raw in lines:
        code = strip_comment(raw, is_asm)
        if not code.strip():
            continue
        ev = is_device_len_read(code)
        if ev is not None:
            mask_line = line_no
            mask_src = code.strip()
            clamp_line = 0                           # a fresh length restarts the clamp obligation
            continue
        if mask_line and is_clamp(code):
            clamp_line = line_no
            continue
        sink = sink_in(code)
        if sink is not None and mask_line:
            sites.append(
                IngestSite(
                    file=rel,
                    func=func,
                    sink=sink,
                    sink_line=line_no,
                    mask_line=mask_line,
                    clamped=clamp_line != 0,
                    clamp_line=clamp_line,
                    mask_src=mask_src,
                )
            )
    return sites


def collect_ingest_sites(root: Path) -> list[IngestSite]:
    sites: list[IngestSite] = []
    for path in source_files(root):
        rel = repo_path(root, path)
        is_asm = path.suffix.lower() in {".asm", ".inc"}
        text = read_text(path)
        raw_lines = text.splitlines()

        # Segment into function blocks. GHL: `fn name(`. ASM: top-level labels.
        cur_func = "<file>"
        block: list[tuple[int, str]] = []

        def flush(fn: str, blk: list[tuple[int, str]]) -> None:
            if blk:
                sites.extend(scan_function(rel, fn, blk, is_asm))

        for idx, raw in enumerate(raw_lines, 1):
            if not is_asm:
                m = GHL_FN_START.match(raw)
                if m:
                    flush(cur_func, block)
                    cur_func = m.group(1)
                    block = []
            else:
                m = ASM_FN_LABEL.match(strip_comment(raw, True))
                if m:
                    flush(cur_func, block)
                    cur_func = m.group(1)
                    block = []
            block.append((idx, raw))
        flush(cur_func, block)
    return sites


def analyse(sites: Sequence[IngestSite]) -> list[Finding]:
    findings: list[Finding] = []
    by_sink: dict[str, list[IngestSite]] = {}
    for s in sites:
        by_sink.setdefault(s.sink, []).append(s)

    for site in sites:
        if site.clamped:
            continue
        siblings = by_sink.get(site.sink, [])
        clamped_siblings = [
            s for s in siblings
            if s.clamped and not (s.file == site.file and s.func == site.func)
        ]
        if clamped_siblings:
            proof = clamped_siblings[0]
            findings.append(
                Finding(
                    rule="copy-fail-sibling-divergence",
                    location=f"{site.file}:{site.sink_line}",
                    fault=(
                        f"Async/second ingest path `{site.func}` reads a device-controlled RX "
                        f"length and hands it to `{site.sink}` with NO upper-bound clamp, while "
                        f"the sibling path `{proof.func}` feeding the SAME sink clamps it. The "
                        f"device length (up to the full mask width) drives the length-trusting "
                        f"parsers/copy past the physical buffer -> kernel OOB read/write "
                        f"(CVE-2026-31431 'Copy Fail' class)."
                    ),
                    trigger=(
                        f"A malicious/emulated device (or an over-length frame the NIC reports) "
                        f"delivers a frame while `{site.func}` is the active ingest path (e.g. the "
                        f"async DHCP/RX pump running every tick); the un-clamped length reaches "
                        f"`{site.sink}`."
                    ),
                    evidence=(
                        f"{site.file}:{site.mask_line} masks the device length "
                        f"(`{site.mask_src}`); {site.file}:{site.sink_line} calls {site.sink} with "
                        f"no capacity clamp between them. Clamped sibling: {proof.file}:"
                        f"{proof.clamp_line} guards {proof.file}:{proof.sink_line}."
                    ),
                    fix=(
                        f"Before `{site.func}` calls `{site.sink}`, reject/clamp the masked length "
                        f"to the buffer capacity (the same *_MAX_FRAME/*_DMA_LEN bound the sibling "
                        f"`{proof.func}` uses). Fail closed on over-length."
                    ),
                )
            )
        else:
            findings.append(
                Finding(
                    rule="copy-fail-unclamped-ingest",
                    location=f"{site.file}:{site.sink_line}",
                    fault=(
                        f"`{site.func}` reads a device-controlled RX length and hands it to "
                        f"length-trusting `{site.sink}` with no upper-bound clamp to the buffer "
                        f"capacity; the device controls how far past the buffer the parsers/copy "
                        f"read (CVE-2026-31431 'Copy Fail' class)."
                    ),
                    trigger=(
                        f"A device/attacker sets the reported RX length larger than the DMA buffer; "
                        f"`{site.func}` forwards it to `{site.sink}`."
                    ),
                    evidence=(
                        f"{site.file}:{site.mask_line} masks the device length (`{site.mask_src}`); "
                        f"{site.file}:{site.sink_line} calls {site.sink} with no capacity clamp "
                        f"between them, and no sibling path proves the clamp is applied elsewhere."
                    ),
                    fix=(
                        f"Clamp the masked length to the buffer's *_MAX_FRAME/*_DMA_LEN capacity "
                        f"and fail closed before calling `{site.sink}`."
                    ),
                )
            )
    findings.sort(key=lambda f: (f.rule != "copy-fail-sibling-divergence", f.location))
    return findings


# ---------------------------------------------------------------------------
# Self-test: a planted unclamped sibling MUST be caught; adding the clamp MUST
# clear it. Proves the guard is not a silent no-op (enforcement meta-test).
# ---------------------------------------------------------------------------
_SELFTEST_CLAMPED_SIBLING = """\
module "fixture_clamped";
fn ok_consume_event() {
    let rxlen = lw(RX_BUF) & RTL8156_RX_LEN_MASK;
    if rxlen >= 32 {
        if rxlen <= RTL8156_RX_MAX_FRAME {
            let flen = rxlen - 4;
            call rtl8156_handle_frame(rdi: RX_BUF + 24, rcx: flen);
        }
    }
}
"""

_SELFTEST_UNCLAMPED_PUMP = """\
module "fixture_pump";
fn bad_dhcp_pump() {
    let rxlen = lw(RX_BUF) & RX_LEN_MASK;
    if rxlen >= 32 {
        let flen = rxlen - 4;
        call rtl8156_handle_frame(rdi: RX_BUF + 24, rcx: flen);
    }
}
"""

_SELFTEST_FIXED_PUMP = """\
module "fixture_pump";
fn good_dhcp_pump() {
    let rxlen = lw(RX_BUF) & RX_LEN_MASK;
    if rxlen >= 32 {
        if rxlen <= RTL8156_RX_MAX_FRAME {
            let flen = rxlen - 4;
            call rtl8156_handle_frame(rdi: RX_BUF + 24, rcx: flen);
        }
    }
}
"""


def _scan_fixture(name: str, body: str) -> list[IngestSite]:
    lines = [(i, raw) for i, raw in enumerate(body.splitlines(), 1)]
    sites: list[IngestSite] = []
    cur = "<file>"
    block: list[tuple[int, str]] = []
    for i, raw in lines:
        m = GHL_FN_START.match(raw)
        if m:
            if block:
                sites.extend(scan_function(name, cur, block, False))
            cur = m.group(1)
            block = []
        block.append((i, raw))
    if block:
        sites.extend(scan_function(name, cur, block, False))
    return sites


def run_selftest() -> int:
    # 1. The clamped sibling alone is clean.
    clean = analyse(_scan_fixture("clamped.ghl", _SELFTEST_CLAMPED_SIBLING))
    assert not clean, f"self-test: clamped sibling should be clean, got {clean}"

    # 2. Clamped sibling + unclamped pump -> sibling-divergence Copy Fail.
    both = analyse(
        _scan_fixture("clamped.ghl", _SELFTEST_CLAMPED_SIBLING)
        + _scan_fixture("pump.ghl", _SELFTEST_UNCLAMPED_PUMP)
    )
    assert any(f.rule == "copy-fail-sibling-divergence" for f in both), (
        f"self-test: planted unclamped sibling was NOT caught: {both}"
    )

    # 3. A lone unclamped ingest (no clamped sibling) is still caught.
    lone = analyse(_scan_fixture("pump.ghl", _SELFTEST_UNCLAMPED_PUMP))
    assert any(f.rule == "copy-fail-unclamped-ingest" for f in lone), (
        f"self-test: lone unclamped ingest was NOT caught: {lone}"
    )

    # 4. Adding the clamp to the pump clears both.
    fixed = analyse(
        _scan_fixture("clamped.ghl", _SELFTEST_CLAMPED_SIBLING)
        + _scan_fixture("pump.ghl", _SELFTEST_FIXED_PUMP)
    )
    assert not fixed, f"self-test: clamped pump should be clean, got {fixed}"

    print("[copy-fail] self-test OK: divergence + lone-unclamped caught; clamp clears them.")
    return 0


def render_text(findings: Sequence[Finding]) -> str:
    out = ["[copy-fail] cross-path device-length clamp scan (CVE-2026-31431 class)"]
    if not findings:
        out.append("Result: PASS (0 Copy Fail finding(s))")
        return "\n".join(out)
    out.append(f"Result: FAIL ({len(findings)} Copy Fail finding(s))")
    for f in findings:
        out.append(f"[{f.rule}] {f.location}")
        out.append(f"  fault: {f.fault}")
        out.append(f"  trigger: {f.trigger}")
        out.append(f"  evidence: {f.evidence}")
        out.append(f"  fix: {f.fix}")
    return "\n".join(out)


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Scan for cross-path 'Copy Fail' device-length clamp omissions.")
    ap.add_argument("--repo-root", default=".", help="repository root (default: current directory)")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--selftest", action="store_true", help="run the planted-violation self-test and exit")
    args = ap.parse_args(argv)

    if args.selftest:
        return run_selftest()

    root = Path(args.repo_root).resolve()
    try:
        sites = collect_ingest_sites(root)
        findings = analyse(sites)
    except Exception as exc:  # a broken scan must fail the suite, not pass silently
        findings = [
            Finding(
                rule="copy-fail-checker-error",
                location=str(root),
                fault="The Copy Fail scanner could not complete, so the device-length clamp surface was not checked.",
                trigger="Run the security suite.",
                evidence=str(exc),
                fix="Fix the scanner input error, then rerun.",
            )
        ]

    if args.format == "json":
        print(json.dumps({"findings": [asdict(f) for f in findings]}, indent=2))
    else:
        print(render_text(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
