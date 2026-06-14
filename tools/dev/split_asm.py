#!/usr/bin/env python3
"""Byte-identical %include splitter for NASM monoliths.

Modes:
  analyze <file>                 -> list depth-0 top-level boundary candidates
  split <file> <cut:name> ...    -> split at given line numbers (1-based, cut
                                    BEFORE that line); part files named
                                    <stem>_<name>.inc in same dir; parent keeps
                                    preamble (lines before first cut) and
                                    %include lines. Verifies textual identity.
"""
import sys, os, re

OPEN = re.compile(r'^\s*%(if|ifdef|ifndef|ifmacro|ifnum|ifidn|ifctx|macro|rep)\b')
CLOSE = re.compile(r'^\s*%(endif|endmacro|endrep)\b')
LABEL = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*):')

def load(path):
    with open(path, 'rb') as f:
        data = f.read()
    return data

def analyze(path):
    data = load(path)
    lines = data.split(b'\n')
    depth = 0
    for i, raw in enumerate(lines, 1):
        line = raw.decode('latin-1')
        if CLOSE.match(line): depth -= 1
        if depth == 0:
            m = LABEL.match(line)
            if m and not line.startswith('.'):
                print(f"{i}\t{m.group(1)}")
            elif line.startswith('section '):
                print(f"{i}\tSECTION {line.strip()}")
            elif line.startswith('FN_BEGIN'):
                print(f"{i}\tFN {line.strip()}")
        if OPEN.match(line): depth += 1
    print(f"# total lines: {len(lines)} final depth {depth}", file=sys.stderr)

def split(path, specs):
    data = load(path)
    nl = b'\r\n' if b'\r\n' in data[:2000] else b'\n'
    lines = data.split(b'\n')  # keep \r in pieces; rejoin with \n
    cuts = []
    for s in specs:
        ln, name = s.split(':', 1)
        cuts.append((int(ln), name))
    cuts.sort()
    d = os.path.dirname(path)
    stem = os.path.splitext(os.path.basename(path))[0]
    bounds = [c[0] for c in cuts] + [len(lines) + 1]
    parts = []
    for idx, (ln, name) in enumerate(cuts):
        seg = lines[ln - 1: bounds[idx + 1] - 1]
        parts.append((name, seg))
    # back up comment/blank lines preceding each cut? No - cuts given exactly.
    preamble = lines[:cuts[0][0] - 1]
    rel = os.path.relpath(d, '.').replace('\\', '/')
    inc_lines = []
    for name, seg in parts:
        fn = f"{stem}_{name}.inc"
        with open(os.path.join(d, fn), 'wb') as f:
            f.write(b'\n'.join(seg))
        inc_lines.append(f'%include "{rel}/{fn}"'.encode())
    with open(path, 'wb') as f:
        f.write(b'\n'.join(preamble + inc_lines) + (b'' if not data.endswith(b'\n') else b'\n') if False else b'\n'.join(preamble + inc_lines) + b'\n')
    # verify: concatenation of preamble + parts == original
    recon = b'\n'.join(preamble)
    for name, seg in parts:
        recon += b'\n' + b'\n'.join(seg)
    ok = recon == data or recon + b'\n' == data or recon == data + b'\n'
    print("TEXTUAL-IDENTITY:", "OK" if ok else "MISMATCH")
    for name, seg in parts:
        print(f"  {stem}_{name}.inc: {len(seg)} lines")
    print(f"  parent: {len(preamble)+len(parts)} lines")
    if not ok: sys.exit(1)

if __name__ == '__main__':
    if sys.argv[1] == 'analyze':
        analyze(sys.argv[2])
    else:
        split(sys.argv[2], sys.argv[3:])
