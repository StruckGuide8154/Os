#!/usr/bin/env python3
# ============================================================================
# gen_cap_usage_matrix.py - derive each Grit app's REQUIRED capability set from
# its source, compare it against the declared MANIFEST_* mask, and report any
# over-grant (declared but unused).
#
# This is the machine-readable "uses" ground truth that the per-app capability
# manifests in src/include/syscall_caps.inc are hand-maintained against (the
# file comments say: "A grep against src/user/apps/*.inc and
# src/user/grithl/apps/*.ghl is the source of truth for what each app calls").
# It replaces that manual grep with a sound, repeatable analysis, and feeds the
# quantum Layer-1 policy-graph minimizer (tools/quantum/policy_graph_qaoa.py)
# real per-app capability requirements instead of a synthetic example.
#
# Pipeline:
#   1. CAP_* bit values + MANIFEST_* masks      <- src/include/syscall_caps.inc
#   2. SYS_* macro name -> syscall number         <- src/include/syscall_user.inc
#   3. syscall number -> required CAP tag         <- syscall_table in
#                                                    src/kernel/proc/syscall_support.inc
#   4. per-app used SYS_* set:
#        * .ghl apps: function-level call-graph closure (an app `use`s libraries
#          like core/gui/fs/net whose wrappers issue the syscalls; we resolve
#          which wrapper functions the app actually reaches, NOT every syscall
#          the library wraps - core.ghl alone wraps ~all syscalls).
#        * .inc apps (e.g. security_probe, raw asm): direct SYS_* macro tokens.
#   5. used_mask = OR of the CAP tags of every used syscall (the gate requires
#      (slot_mask & tag) == tag, so the minimal sufficient mask is exactly this
#      union). over_grant = declared & ~used_mask.
#
# Output: JSON (--json PATH, default tools/security/cap_usage_matrix.json) plus
# a human-readable table on stdout. Exit code is non-zero with --strict if any
# app is over-granted (excluding the implicitly-granted CAP_CORE).
# ============================================================================

import argparse
import json
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

CAPS_INC = os.path.join(REPO, "src", "include", "syscall_caps.inc")
USER_INC = os.path.join(REPO, "src", "include", "syscall_user.inc")
TABLE_INC = os.path.join(REPO, "src", "kernel", "proc", "syscall_support.inc")
GHL_APPS = os.path.join(REPO, "src", "user", "grithl", "apps")
GHL_LIBS = os.path.join(REPO, "src", "user", "grithl", "lib")
INC_APPS = os.path.join(REPO, "src", "user", "apps")

# app_id -> (comment label from app_manifest_table, MANIFEST_* name, source files).
# This mirrors app_manifest_table in src/kernel/proc/syscall_perm.inc row-for-row.
# Source files are deliberately over-inclusive (a missed file would UNDER-count
# used caps and produce a false over-grant report); for .ghl apps the library
# call-graph closure pulls in the real per-function syscalls.
APPS = [
    (2,  "APP_EXPLORER",       "MANIFEST_EXPLORER",       ["grithl/apps/explorer.ghl"]),
    (3,  "APP_TERMINAL",       "MANIFEST_TERMINAL",       ["grithl/apps/terminal.ghl"]),
    (4,  "APP_NOTEPAD",        "MANIFEST_NOTEPAD",        ["grithl/apps/notepad.ghl"]),
    (5,  "APP_SETTINGS",       "MANIFEST_SETTINGS",       ["grithl/apps/settings.ghl"]),
    (6,  "APP_PAINT",          "MANIFEST_PAINT",          ["grithl/apps/paint.ghl"]),
    (7,  "APP_ABOUT",          "MANIFEST_ABOUT",          ["grithl/apps/about.ghl"]),
    (8,  "APP_SECURITY_PROBE", "MANIFEST_SECURITY_PROBE", ["apps/security_probe.inc"]),
    (9,  "APP_TASKMGR",        "MANIFEST_TASKMGR",        ["grithl/apps/taskmgr.ghl"]),
    (10, "APP_PING",           "MANIFEST_PING",           ["grithl/apps/ping.ghl"]),
    (11, "APP_MEDIA",          "MANIFEST_MEDIA",          ["grithl/apps/media.ghl"]),
]
USER_ROOT = os.path.join(REPO, "src", "user")

# Single-bit (atomic) capability names, in report order.
ATOMIC_CAPS = [
    "CAP_CORE", "CAP_NET", "CAP_APP_CTRL", "CAP_WX", "CAP_MEDIA",
    "CAP_FS_READ", "CAP_FS_WRITE", "CAP_FS_DELETE",
    "CAP_GUI_DRAW", "CAP_GUI_DISPLAY",
]


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comment(line, ch):
    # Remove a trailing line comment introduced by `ch`, ignoring occurrences
    # inside a double-quoted string literal.
    out = []
    in_str = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"':
            in_str = not in_str
        elif c == ch and not in_str:
            break
        out.append(c)
        i += 1
    return "".join(out)


def eval_mask_expr(expr, names):
    """Evaluate a `CAP_A | CAP_B | (CAP_C | CAP_D)` style mask expression using
    the integer values in `names`. Only |, names, parens and hex/dec ints."""
    expr = expr.strip()
    # Replace known names with their values; tokenise defensively.
    def repl(m):
        tok = m.group(0)
        if tok in names:
            return str(names[tok])
        return tok
    safe = re.sub(r"[A-Za-z_][A-Za-z0-9_]*", repl, expr)
    if not re.fullmatch(r"[0-9xXa-fA-F_()|\s]*", safe):
        raise ValueError("unsafe mask expr: %r -> %r" % (expr, safe))
    if safe.strip() == "":
        return 0
    return eval(safe, {"__builtins__": {}}, {})


def parse_caps_inc():
    """Return (cap_values, manifest_masks). cap_values maps every CAP_* name to
    its int value; manifest_masks maps MANIFEST_* -> int mask (non-RELEASE
    branch preferred)."""
    text = read(CAPS_INC)
    cap_values = {}
    manifest_masks = {}

    # %ifdef RELEASE_BUILD tracker: RELEASE_BUILD is undefined for this audit,
    # so we want the %else branch values.
    release_active = []  # stack of bool "currently-emitting" per ifdef level
    suppress = False

    for raw in text.splitlines():
        line = strip_comment(raw, ";").strip()

        m = re.match(r"%ifdef\s+RELEASE_BUILD\b", line)
        if m:
            release_active.append("if")
            suppress = True  # skip the RELEASE_BUILD body
            continue
        if line.startswith("%ifdef") or line.startswith("%ifndef"):
            release_active.append("other")
            continue
        if line.startswith("%else"):
            if release_active and release_active[-1] == "if":
                suppress = False  # emit the non-release branch
            continue
        if line.startswith("%endif"):
            if release_active:
                top = release_active.pop()
                if top == "if":
                    suppress = False
            continue
        if suppress:
            continue

        m = re.match(r"(CAP_[A-Z0-9_]+)\s+equ\s+(.+)$", line)
        if m:
            name, expr = m.group(1), m.group(2)
            try:
                cap_values[name] = eval_mask_expr(expr, cap_values)
            except Exception:
                pass
            continue

        m = re.match(r"(MANIFEST_[A-Z0-9_]+)\s+equ\s+(.+)$", line)
        if m:
            name, expr = m.group(1), m.group(2)
            manifest_masks[name] = eval_mask_expr(expr, cap_values)
            continue

    return cap_values, manifest_masks


def parse_syscall_numbers():
    """SYS_* macro name -> syscall number (from APP_SYSNO N inside each macro)."""
    text = read(USER_INC)
    name_to_no = {}
    cur = None
    for raw in text.splitlines():
        line = strip_comment(raw, ";")
        m = re.match(r"\s*%macro\s+(SYS_[A-Z0-9_]+)\s+\d+", line)
        if m:
            cur = m.group(1)
            continue
        if cur:
            m = re.search(r"APP_SYSNO\s+(\d+)", line)
            if m:
                name_to_no[cur] = int(m.group(1))
                cur = None
        if re.match(r"\s*%endmacro", line):
            cur = None
    return name_to_no


def parse_syscall_table(cap_values):
    """syscall number (row index) -> required CAP mask int. Untagged rows
    default to CAP_ALL, matching the SYSCALL_ENTRY macro default."""
    text = read(TABLE_INC)
    # Isolate the table body between `syscall_table:` and `syscall_table_end:`.
    body = re.search(r"^syscall_table:\s*$(.*?)^syscall_table_end:",
                     text, re.S | re.M)
    if not body:
        raise SystemExit("could not locate syscall_table in %s" % TABLE_INC)
    no_to_mask = {}
    idx = 0
    cap_all = cap_values.get("CAP_ALL", 0xFFFF)
    for raw in body.group(1).splitlines():
        line = strip_comment(raw, ";").strip()
        if not line.startswith("SYSCALL_ENTRY"):
            continue
        # SYSCALL_ENTRY handler, argc, kind [, caps [, arg_desc [, flags]]]
        # Split top-level commas (ignore commas inside parens).
        args = split_top_level(line[len("SYSCALL_ENTRY"):])
        if len(args) >= 4 and args[3].strip():
            try:
                mask = eval_mask_expr(args[3], cap_values)
            except Exception:
                mask = cap_all
        else:
            mask = cap_all
        no_to_mask[idx] = mask
        idx += 1
    return no_to_mask


def split_top_level(s):
    out, depth, cur = [], 0, []
    for c in s:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    out.append("".join(cur))
    return [a.strip() for a in out]


# ---------------------------------------------------------------------------
# .ghl call-graph analysis
# ---------------------------------------------------------------------------

FN_RE = re.compile(r"^\s*fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)
SYSCALL_CALL_RE = re.compile(r"syscall\s*\(\s*(SYS_[A-Za-z0-9_]+)")
CALL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def strip_ghl(text):
    # Drop `#` line comments, honouring string literals.
    return "\n".join(strip_comment(l, "#") for l in text.splitlines())


def parse_ghl_functions(text):
    """Return {fn_name: {'syscalls': set, 'callees': set}} for one .ghl file,
    plus a list of (syscalls, callees) for top-level (non-fn) code."""
    text = strip_ghl(text)
    fns = {}
    toplevel_sys, toplevel_calls = set(), set()
    i, n = 0, len(text)
    # Find each `fn name(` and capture its brace-balanced body.
    for m in FN_RE.finditer(text):
        name = m.group(1)
        # advance to the opening brace of the body
        j = text.find("{", m.end())
        if j < 0:
            continue
        depth, k = 0, j
        while k < n:
            if text[k] == "{":
                depth += 1
            elif text[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        body = text[j + 1:k]
        sysset = set(SYSCALL_CALL_RE.findall(body))
        callees = set(CALL_RE.findall(body)) - {"syscall"}
        fns[name] = {"syscalls": sysset, "callees": callees}
    # Top-level syscalls / calls (rare, but e.g. an inline entry).
    # Strip out fn bodies first to avoid double-counting.
    stripped = FN_RE.sub("", text)
    toplevel_sys = set(SYSCALL_CALL_RE.findall(stripped))
    return fns, toplevel_sys


def parse_use_directives(text):
    return re.findall(r"^\s*use\s+([A-Za-z0-9_.]+)", strip_ghl(text), re.M)


def parse_externs(text):
    # `extern render_rect;` declares a symbol resolved OUTSIDE the .ghl world -
    # the kernel-resident render primitives (render.asm: render_rect -> fill_rect)
    # and kernel-context renderers. These are DIRECT calls, NOT syscalls, so they
    # are never checked against the cap mask. We record which ones an app reaches
    # to explain why a draw-only app needs no GUI cap at the syscall gate.
    return set(re.findall(r"^\s*extern\s+([A-Za-z_][A-Za-z0-9_]*)", strip_ghl(text), re.M))


def lib_path(libname):
    # `use svg2.core` -> lib/svg2/core.ghl ; `use gui` -> lib/gui.ghl
    rel = libname.replace(".", os.sep) + ".ghl"
    return os.path.join(GHL_LIBS, rel)


def ghl_used_syscalls(app_rel):
    """Compute the set of SYS_* a .ghl app actually reaches via its own
    functions + the functions of the libraries it (transitively) `use`s."""
    app_path = os.path.join(USER_ROOT, app_rel)
    app_text = read(app_path)

    # Collect the transitive set of library files via `use`.
    lib_files = {}
    seen_libs = set()
    pending = list(parse_use_directives(app_text))
    while pending:
        lib = pending.pop()
        if lib in seen_libs:
            continue
        seen_libs.add(lib)
        p = lib_path(lib)
        if not os.path.isfile(p):
            continue
        t = read(p)
        lib_files[lib] = t
        pending.extend(parse_use_directives(t))

    # Build function tables. Resolution scope = app file + used libs.
    # app functions take precedence on name collisions; otherwise union over
    # libraries (a sound over-approximation bounded to the libs in scope).
    app_fns, app_top = parse_ghl_functions(app_text)
    lib_fn_tables = {lib: parse_ghl_functions(t)[0] for lib, t in lib_files.items()}

    # Symbols declared `extern` anywhere in scope resolve to non-gated code.
    externs = parse_externs(app_text)
    for t in lib_files.values():
        externs |= parse_externs(t)
    extern_reached = set()

    def resolve(name):
        defs = []
        if name in app_fns:
            return [app_fns[name]]
        for tbl in lib_fn_tables.values():
            if name in tbl:
                defs.append(tbl[name])
        if not defs and name in externs:
            extern_reached.add(name)
        return defs

    used = set(app_top)
    # Roots: every function defined in the app file (any may be a registered
    # draw fn / handler / entry), plus app top-level syscalls already in `used`.
    work = list(app_fns.keys())
    visited_fn = set()
    # represent a visited node as (scope, name); use the resolved def objects
    stack = [("app", k) for k in app_fns.keys()]
    seen = set()
    # Simpler worklist over def objects keyed by id.
    pending_defs = [app_fns[k] for k in app_fns]
    seen_def_ids = set(id(d) for d in pending_defs)
    while pending_defs:
        d = pending_defs.pop()
        used |= d["syscalls"]
        for callee in d["callees"]:
            for cd in resolve(callee):
                if id(cd) not in seen_def_ids:
                    seen_def_ids.add(id(cd))
                    pending_defs.append(cd)
    return used, extern_reached


def inc_used_syscalls(app_rel):
    """For raw-asm .inc apps: direct SYS_* macro tokens (comment-stripped)."""
    path = os.path.join(USER_ROOT, app_rel)
    text = read(path)
    text = "\n".join(strip_comment(l, ";") for l in text.splitlines())
    return set(re.findall(r"\bSYS_[A-Z0-9_]+\b", text))


def decompose(mask):
    return [c for c in ATOMIC_CAPS if mask & CAP_VALUES.get(c, 0)]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", default=os.path.join(os.path.dirname(__file__),
                    "cap_usage_matrix.json"))
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero if any app is over-granted (ex-CAP_CORE)")
    args = ap.parse_args()

    global CAP_VALUES
    CAP_VALUES, manifests = parse_caps_inc()
    name_to_no = parse_syscall_numbers()
    no_to_mask = parse_syscall_table(CAP_VALUES)

    def syscall_mask(sysname):
        no = name_to_no.get(sysname)
        if no is None:
            return 0, None
        return no_to_mask.get(no, 0), no

    results = []
    any_overgrant = False

    for app_id, label, manifest_name, sources in APPS:
        declared = manifests.get(manifest_name, 0)
        used_syscalls = set()
        extern_calls = set()
        for src in sources:
            if src.endswith(".ghl"):
                u, ext = ghl_used_syscalls(src)
                used_syscalls |= u
                extern_calls |= ext
            else:
                used_syscalls |= inc_used_syscalls(src)

        # Keep only tokens that are real syscall macros.
        per_syscall = {}
        used_mask = 0
        for s in sorted(used_syscalls):
            m, no = syscall_mask(s)
            if no is None:
                continue  # SYS_FS_ENTRY_INFO_SIZE etc. - not a syscall
            used_mask |= m
            per_syscall[s] = {"sysno": no, "caps": decompose(m)}

        overgrant = declared & ~used_mask
        # CAP_CORE is implicitly granted to every slot; an unused CAP_CORE is
        # not a meaningful over-grant.
        overgrant_real = overgrant & ~CAP_VALUES.get("CAP_CORE", 0)
        underdeclared = used_mask & ~declared  # used but NOT declared (a BUG)

        if overgrant_real:
            any_overgrant = True

        results.append({
            "app_id": app_id,
            "app": label,
            "manifest": manifest_name,
            "sources": sources,
            "declared_mask": declared,
            "declared_caps": decompose(declared),
            "used_mask": used_mask,
            "required_caps": decompose(used_mask),
            "syscalls": per_syscall,
            "over_grant": decompose(overgrant),
            "over_grant_significant": decompose(overgrant_real),
            "under_declared": decompose(underdeclared),
            "extern_primitives": sorted(extern_calls),
        })

    matrix = {
        "_about": "Per-app required-capability matrix derived from source. "
                  "required_caps = OR of the CAP tags of every syscall the app "
                  "reaches; over_grant = declared & ~required.",
        "atomic_caps": ATOMIC_CAPS,
        "cap_values": {k: CAP_VALUES[k] for k in CAP_VALUES},
        "apps": results,
    }
    with open(args.json, "w", encoding="utf-8") as f:
        json.dump(matrix, f, indent=2)

    print_table(results, args.json)

    if args.strict and any_overgrant:
        return 2
    return 0


def short(cap):
    return cap.replace("CAP_", "")


def print_table(results, json_path):
    print("Grit per-app capability usage matrix")
    print("=" * 78)
    for r in results:
        print("\n%s  (app_id %d, %s)" % (r["app"], r["app_id"], r["manifest"]))
        print("  sources : %s" % ", ".join(r["sources"]))
        print("  declared: %s" % " ".join(short(c) for c in r["declared_caps"]) or "(none)")
        print("  required: %s  (at the cap-gated syscall interface)"
              % (" ".join(short(c) for c in r["required_caps"]) or "(none)"))
        print("  syscalls: %s" % (" ".join(sorted(r["syscalls"])) or "(none found)"))
        if r.get("extern_primitives"):
            print("  non-gated: draws/acts via extern kernel primitives (not "
                  "syscalls): %s" % " ".join(r["extern_primitives"]))
        if r["over_grant_significant"]:
            print("  >> OVER-GRANT: %s  (declared but never used)"
                  % " ".join(short(c) for c in r["over_grant_significant"]))
        elif r["over_grant"]:
            print("  -- over-grant: %s  (CAP_CORE only - implicitly granted, OK)"
                  % " ".join(short(c) for c in r["over_grant"]))
        else:
            print("  -- least-privilege: declared == required")
        if r["under_declared"]:
            print("  !! UNDER-DECLARED (BUG - app uses caps not in manifest): %s"
                  % " ".join(short(c) for c in r["under_declared"]))

    over = [r for r in results if r["over_grant_significant"]]
    under = [r for r in results if r["under_declared"]]
    print("\n" + "=" * 78)
    print("Summary: %d/%d apps over-granted (declared caps unused at the gate)."
          % (len(over), len(results)))
    for r in over:
        print("  %-20s drop: %s" % (r["app"],
              " ".join(short(c) for c in r["over_grant_significant"])))
    if under:
        print("\n%d app(s) UNDER-declared (reach a syscall whose cap tag is not"
              " in their manifest -> the gate would REJECT that call):" % len(under))
        for r in under:
            print("  %-20s missing: %s" % (r["app"],
                  " ".join(short(c) for c in r["under_declared"])))
        print("  NOTE: FS_DELETE here is usually NOT an app bug but a tag-")
        print("  granularity issue - read-class FS syscalls (fs_count/entry/")
        print("  chdir/read/format_name/sync_root) are tagged with the umbrella")
        print("  CAP_FS (=READ|WRITE|DELETE), so the gate demands all three bits")
        print("  even for a read. Splitting those tags to CAP_FS_READ would let")
        print("  a true read-only/no-delete manifest pass. APP_CTRL/etc. missing")
        print("  from a manifest IS a real grant gap (or an un-sandboxed app).")
    print("\nJSON written to %s" % json_path)


if __name__ == "__main__":
    sys.exit(main())
