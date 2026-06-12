# GritHL - Safe Higher-Level Assembly Language

GritHL (`.ghl`) is the supported SDK path for Grit ring-3 apps. It targets
the existing callback/syscall ABI so larger apps can be written, read, and
refactored without hand-tracking registers, while every emitted instruction
stays inside the syscall boundary documented in `docs/syscalls.md`.

The toolchain is entirely host-side. The compiler emits plain NASM that the
existing `scripts/build/build_uefi.ps1` pipeline assembles. There is no runtime, no heap,
no interpreter, no dynamic loader - so there is no new attack surface on the
running kernel.

## Quick start

```powershell
powershell -NoProfile -File scripts\build\build_ghl.ps1     # compile apps and generate SDK include/manifest
powershell -NoProfile -File scripts\run\run_uefi.ps1      # boot VM
python src/user/grithl/compiler/gritdbg.py    # tail serial, highlights [ghll] lines
```

## File layout

```
src/user/grithl/
  compiler/
    gritc.py          # compiler: .ghl -> .asm
    gritdbg.py        # serial debugger, TCP 127.0.0.1:5555
  lib/
    core.ghl         # syscall numbers, window offsets, colors, keys
    gui.ghl          # immediate-mode GUI helpers and shared widget metrics
    svg.ghl          # lightweight SVG wallpaper IDs and raster primitives
    svg2.ghl         # static SVG2 subset renderer for apps that need it
    xml.ghl          # XML DOM parser syscall bindings
  apps/
    hello.ghl        # smoke app, emits [ghll] markers on every callback
    notepad.ghl      # shipped Notepad implementation
build/ghl/
  <name>.asm         # generated NASM (do not edit)
  generated_apps.inc # generated include consumed by src/user/apps.asm
  manifest.json      # generated SDK metadata for compiled apps/callback names
```

## Language reference

### Top level
```
use <lib>                              # pulls in a .ghl from src/user/grithl/lib
app "<Name>" { stack = <N>; }          # app metadata (reserved for future loader)
str <name> = "...";                    # static zero-terminated string in .rodata
const <NAME> = <int>;                  # compile-time integer
extern <symbol>;                       # declare an external NASM symbol
state { <name>: <bytes>; }             # zeroed per-slot static storage
fn <name>(a, b, c) { ... }             # function with up to 6 params
```

`state` fields compile to labels inside the generated app blob:

```ghl
state {
  selected_tab: 4;
  scratch_name: 64;
}
```

Use `&selected_tab` with `lb`/`lw`/`lq` and `sb`/`sw`/`sq`. The loader copies
the app blob into each app slot before callbacks run, so these labels behave
like slot-local statics without kernel externs or shared global storage.

### Statements
```
let x = <expr>;                        # new stack-local i64
x = <expr>;                            # assign to an existing local
if <cond> { ... } else { ... }         # else-if chains allowed
while <cond> { ... }                   # break; continue; allowed inside
return [<expr>];                       # early exit
syscall(<num>, <arg>, ...);            # kernel call, up to 6 args
call name(<arg>, ...);                 # raw NASM `call` to an extern
asm "<raw nasm line>";                 # unsafe escape hatch (discouraged)
```

### Expressions
- Integer literals: `123`, `0xFF`
- Booleans: `true`, `false`
- String literal `"..."` evaluates to its address (same as `&name` for a `str`)
- `&name` - address of a `str` declared at top level
- Operators: `+ - * / % & | ^ << >> == != < > <= >= && || !`
- Function-call syntax only on identifiers (`foo(x)`), no raw pointers yet
- Array index `a[i]` reserved for future use

### Callbacks
A `.ghl` app typically exposes the three callback names the window manager
expects. Param names are arbitrary; what matters is their position:

```
fn draw(win)          { ... }          # win = shadow window pointer
fn click(win, x, y)   { ... }          # x,y are client-area mouse coords
fn key(win, k)        { ... }          # k is the translated key value
```

Params are spilled to stack at entry, so you can call `syscall(...)` freely
without worrying about `rdi`/`rsi`/`rdx` being clobbered.

### What GritHL refuses
- Direct register names (no `mov rax, ...` unless wrapped in `asm "..."`)
- Raw memory dereference (`[rax+8]`, etc.)
- Pointer arithmetic
- Hidden allocation - mutable storage must be explicit `state` or stack locals
- Inline asm without the explicit `asm "..."` block (and each one is a lint)
- Undeclared identifiers

## Safety model

1. **No runtime** - compiler runs on the host only. A malicious `.ghl` cannot
   run without first being assembled into the kernel image you build.
2. **ABI-locked syscalls** - `syscall(n, ...)` is the *only* way to talk to
   the kernel, and the numbers live in `lib/core.ghl` which mirrors
   `src/include/syscall_user.inc`. Change either, change both.
3. **Callee-saved spills** - every param is copied to a stack slot before
   any user code runs, so argument registers are always free for syscalls.
4. **No pointer arithmetic** - strings are opaque addresses; array indexing
   (when added) will emit compile-time bounds checks.
5. **Byte-for-byte reviewable output** - every `.ghl` has a matching
   `.asm` under `build/ghl/` that you can read, diff, and disassemble.

## Compiler internals

`gritc.py` is a single file: lexer → recursive-descent parser → one-pass
codegen. The only register convention in emitted code:

- Expression result lives in `rax`
- Binary-op RHS lives in `rcx`
- Callee frame uses `rbp`, locals at `[rbp - N]`
- Syscall args are pushed in order, then popped into
  `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`
- `rbx` and `r12` are saved at entry (available for future use)

128 bytes of locals per function (16 `let` slots). Bump in `gen_fn` when we
hit that limit.

## Debugging a HL app

1. Instrument with `syscall(SYS_PRINT, &marker_string)` at every branch of
   interest. Prefix markers with `[ghll]` so `gritdbg.py --grep '\[ghll\]'`
   filters them out of the kernel trace.
2. Build + boot: `scripts\build\build_ghl.ps1; scripts\build\build_uefi.ps1; scripts\run\run_uefi.ps1`.
3. Attach the debugger: `python src/user/grithl/compiler/gritdbg.py`.
4. Stop the VM: `taskkill /F /IM qemu-system-x86_64.exe`.

## Integration with `apps.asm`

`scripts/build/build_ghl.ps1` is the SDK integration point. It compiles every app under
`src/user/grithl/apps`, then writes `build/ghl/generated_apps.inc` and
`build/ghl/manifest.json`.

`src/user/apps.asm` includes the generated include inside the user app blob.
Launch code should install the generated callback labels:

```asm
mov r9, app_hl_notepad_draw
mov r10, app_hl_notepad_click
mov r11, app_hl_notepad_key
```

The current shipped Notepad is generated from
`src/user/grithl/apps/notepad.ghl`. The old hand-written Notepad include is
kept only as historical/reference source and is guarded from re-entering the
active app blob by `scripts/test/test_source_guards.ps1`.

## GUI Library

Use `src/user/grithl/lib/gui.ghl` for app UI. It provides the shared
immediate-mode drawing layer for menus, dropdowns, inputs, and blinking carets.
The full contract is documented in `docs/grithl-gui.md`.

Use `src/user/grithl/lib/svg.ghl` when selecting SVG-backed assets from apps
or calling the low-level raster primitives. `svg.ghl` must stay small and must
not import the heavier renderer. Use `src/user/grithl/lib/svg2.ghl` only when
an app needs to parse and rasterize a static SVG document; `svg2.ghl` can grow
as the opt-in SVG implementation until GritHL has better module boundaries.
The SVG2 support matrix and maintenance rules are documented in
`docs/grithl-svg.md`.

The Settings app is generated from `src/user/grithl/apps/settings.ghl`. It is
the reference app for `state {}` and for display-control syscalls
`SYS_DISPLAY_FLAGS` / `SYS_DISPLAY_SET_FLAGS`.

Use `src/user/grithl/lib/xml.ghl` for XML DOM parsing. The support matrix and
parser maintenance rules are documented in `docs/grithl-xml.md`.

## Roadmap (post file-explorer port)

- Structs + typed struct field access (emits validated offsets)
- Bounded arrays with compile-time range checks (`[N]T`)
- Multi-module projects with a real module resolver (transitive `use`)
- Stricter types (`i32` vs `i64`, `str` vs `ptr<u8>`)
- External-app binary output matching the `GRSAPP64` header in
  `docs/app-loader-format.md`
