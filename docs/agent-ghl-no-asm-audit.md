# Agent 1 GHL No-Asm Audit

Scope: audit only. No source code was edited. The requested target is a
max-security GritHL/GHL-only architecture with strict zero assembly:
no `.asm`, no `.inc`, no inline `asm`, and no generated assembly includes.

## Current Assembly/Include Surface

Active source still has a large NASM surface. Read-only inventory from
`src/` and `tests/` found 179 assembly-family files: 87 `.asm` and 92 `.inc`.
Deprecated GPU code adds another 18 assembly-family files under
`deprecated/780M_IGPU/`.

Largest active surfaces by area:

- `src/boot`: 30 `.asm`/`.inc` files, including BIOS boot, UEFI loader, paging,
  GDT, VESA, MBR, and stage2 code.
- `src/kernel/proc`: 25 files, including `syscall.asm`, `usermode.asm`,
  process/workqueue code, syscall handler includes, usermode includes, and
  handle-table support.
- `src/include`: 25 shared `.inc` headers. These are not just constants; they
  include macros, syscall ABI, KPTI/SMAP/CET/shadow-stack helpers, tracing,
  MMIO bounds, and security-capability tables.
- `src/kernel/drivers`: 21 files, including display, USB/xHCI/HID, PCI, disk,
  network adapters, framebuffer perf, battery, SPI/I2C, and input drivers.
- `src/kernel/core`: 15 files for entry/runtime state, IDT/ISR, PIT/PIC/TSS,
  memory, lockdown, monitor, tracing, logging, and security status.
- `src/user`: 28 files, including `src/user/apps.asm`, legacy user app `.inc`
  files, user library includes, exploit/security PoCs, and the callback
  template assembly.
- Other active areas: `src/kernel/net` has 9 files, `src/kernel/gui` has 6,
  `src/kernel/lib` and `src/kernel/arch` remain assembly-backed, and
  `src/resources/design-system` still ships generated/font/palette `.inc` files
  plus `parser_example.asm`.

The build still explicitly depends on NASM translation units. Examples:

- `scripts/build/build_uefi.ps1` assembles `src/boot/uefi_loader.asm` and
  `src/kernel/kernel_build.asm` with NASM.
- `scripts/build/build_bios.ps1` assembles `mbr.asm`, `stage2.asm`, and
  `kernel_build.asm`.
- `src/kernel/kernel_build.asm` is the active monolithic include wrapper. It
  `%include`s both source `.asm` files and generated GritHLK `.asm` files.
- `src/user/apps.asm` is the built-in app wrapper and includes legacy app
  `.inc` files plus `build/ghl/generated_apps.inc`.
- `tools/build_sig_registry.py`, coverage scripts, source guards, and security
  probe tests all inspect assembly names or generated `.asm` outputs.

## Current GritHL/GHL Surface

GritHL/GHLK is present but currently lowers to NASM, so it does not yet satisfy
the strict architecture.

Current `.ghl` inventory in active/test areas:

- `src/user/grithl/apps`: 11 user apps.
- `src/user/grithl/lib`: 39 user-mode library modules, including GUI, FS,
  media, XML, theme, SVG, and SVG2 split modules.
- `src/kernel/grithlk`: 19 kernel-side modules, including console/lifecycle,
  input dispatch, frame presentation, boot animation, diagnostics, crypto,
  syscall validation/security/data, WM helpers, USB HID helpers, and usermode
  callback helpers.
- `src/boot/ghl`: 1 boot leaf, `a20_wait.ghl`.
- Tests: 7 boot fixtures, 3 user fixture modules, and 2 kernel security
  fixtures.

Current enforcement is partial:

- `gritc.py` accepts `--forbid-asm`, `--deny-unsafe`, and target modes.
- `scripts/test/test_gritc_security.ps1` rejects inline `asm` under
  `--forbid-asm` and under `--target boot`, and rejects unsafe capability
  declarations under `--deny-unsafe`.
- `scripts/build/build_uefi.ps1` compiles kernel GritHLK modules with
  `--target kernel --forbid-asm`.
- `scripts/build/build_ghl.ps1` compiles user apps to `build/ghl/*.asm` and
  writes `build/ghl/generated_apps.inc`.

Current blockers for the strict rule:

- GritHL/GHLK output is still `.asm`; the compiler banner and CLI describe
  `.ghl -> NASM .asm`.
- Kernel and user integration use generated `.asm` through `%include`.
- Existing tests intentionally assemble generated `.asm` fixtures with NASM.
- Existing source guards require `generated_apps.inc` and inspect
  `build/ghl/explorer.asm`.

## Migration Phases

1. Freeze and inventory legacy assembly
   - Add a repo-wide manifest of allowed legacy `.asm`/`.inc` files, with
     owner, subsystem, and migration status.
   - Block new `.asm`, `.inc`, `.s`, `%include "*.asm"`, and `%include "*.inc"`
     additions outside the manifest.
   - Treat `deprecated/` as archival only and exclude it from active build and
     active guardrail exceptions.

2. Remove inline assembly authority from GHL/GritHL
   - Make `--forbid-asm` the default for every target.
   - Keep hardware authority only as typed, target-gated intrinsics with
     explicit capabilities, and make `--deny-unsafe` mandatory for all
     non-boundary modules.
   - Add negative fixtures for `asm`, `asm {}`, string-escaped asm attempts,
     imported unsafe capabilities, and accidental raw register text.

3. Replace generated assembly includes
   - Stop emitting `build/ghl/*.asm` and `build/ghl/generated_apps.inc` for the
     new architecture.
   - Pick a non-assembly compiler artifact for GHL output: direct binary object,
     linkable object, verified IR, or packed app/kernel blob.
   - Replace `kernel_build.asm` and `apps.asm` include wiring with a non-NASM
     build graph that consumes those artifacts directly.

4. Port shared include semantics
   - Convert constants/layouts/macros in `src/include/*.inc` into typed GHL
     modules or generated non-assembly metadata.
   - Preserve ABI-critical layouts with byte/offset tests rather than NASM
     include reuse.
   - Prioritize syscall ABI, app slot layout, boot memory, KPTI/SMAP/CET,
     tracing, and security capability tables.

5. Port boot and privileged boundaries
   - Continue from `src/boot/ghl/a20_wait.ghl`, then migrate A20 check,
     VESA/BIOS int paths, paging/GDT, stage2, MBR, and UEFI loader data/PE
     structures.
   - Each port needs byte parity when layout is fixed, or deterministic serial
     milestone parity when instruction identity is expected to change.
   - Hardware operations must stay behind narrow intrinsics such as port I/O,
     CRx/MSR writes, descriptor loads, interrupt calls, and segment-memory
     access.

6. Port kernel by dependency layer
   - Start with data-only and leaf helper modules already represented in
     `src/kernel/grithlk`.
   - Then port syscall validators/security/data, usermode callbacks, WM helpers,
     USB HID helpers, core runtime helpers, net leaf routines, GUI, FS, and
     drivers.
   - Defer large hardware drivers such as xHCI/USB HID/HID parser and display
     until the intrinsic and layout model is proven.

7. Retire NASM from active builds
   - Remove active NASM invocations from BIOS/UEFI builds.
   - Delete or archive generated `.asm` outputs from `build/ghl`.
   - Make active build/test failure immediate if any new architecture path
     consumes `.asm`, `.inc`, `%include`, or NASM.

## Required Guardrail Tests

Add these as explicit tests before implementation work starts:

- Source extension guard: fail on tracked active-tree `.asm`, `.inc`, or `.s`
  files not listed in the legacy manifest; fail on any such file under the new
  architecture path.
- Generated artifact guard: fail if `build/ghl/**/*.asm` or
  `build/ghl/generated_apps.inc` is produced by a new-architecture build.
- Include syntax guard: fail on `%include`, `include "*.inc"`,
  `include "*.asm"`, `nasm`, and `-f bin` in new-architecture build scripts.
- Compiler default guard: compile representative kernel, user, and boot `.ghl`
  modules without passing `--forbid-asm`; inline `asm` must still be rejected.
- Unsafe guard: compile all non-boundary GHL modules with `--deny-unsafe`;
  audited boundary fixtures must fail under `--deny-unsafe` and pass only under
  an explicit boundary allowlist.
- Negative parser fixtures: reject `asm "..."`, `asm { ... }`, comments or
  strings attempting to smuggle emitted instructions, imported raw asm helper
  modules, and any inline register-text escape.
- Build graph guard: assert new BIOS/UEFI/kernel/app builds do not invoke NASM
  and do not read `kernel_build.asm`, `apps.asm`, or generated `.inc` wrappers.
- Artifact type guard: assert GHL compiler outputs are the approved non-assembly
  artifact type only, and that manifests do not reference `.asm` paths.
- Layout parity guard: for each converted `.inc` layout, compare generated
  offsets/sizes/constant values against a golden JSON or binary layout fixture.
- Boot parity guard: preserve existing boot-sector size/signature, UEFI image
  structure, and serial milestones without assembling any NASM fixture.
- Active/deprecated boundary guard: fail if anything under `deprecated/` is
  imported, included, compiled, linked, or used as an allowlist source.
- CI dirty-output guard: after new-architecture tests, fail if new `.asm`,
  `.inc`, or `.s` files appear in `build/`, `dist/`, or active source paths.

## Near-Term High-Risk Areas

- `kernel_build.asm` is the central blocker because it is both the kernel entry
  aggregator and the generated GritHLK include point.
- `src/include/*.inc` is the second blocker because shared constants and macros
  are deeply coupled to NASM preprocessing.
- User apps are partly migrated to GritHL, but `build_ghl.ps1` and
  `src/user/apps.asm` still make generated assembly the integration mechanism.
- Boot conversion is the most security-sensitive path. It already has useful
  fixtures, but the current verification still assembles generated `.asm` with
  NASM and therefore does not satisfy the strict rule.
- Existing source guards are valuable but currently enforce the old architecture
  shape. They must be split into legacy-maintenance guards and new-architecture
  no-asm guards so the new path cannot inherit assembly assumptions.
