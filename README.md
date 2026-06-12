# Grit

A hobbyist 64-bit x86-64 operating system with a graphical desktop, a ring-3
app runtime, and a security architecture that aims past conventional zero
trust. The kernel began as pure assembly and is being migrated module-by-module
to **GritHL** (`.ghl`), a zero-asm high-level kernel language compiled by
`src/user/grithl/compiler/gritc.py` with bounds-checked state access, source-line traceability,
and a lossless function-level optimizer.

## Highlights

- **UEFI GOP framebuffer** (plus a legacy BIOS path) - no per-vendor GPU
  bring-up; widely compatible interfaces only.
- **Hardened syscall boundary** - per-app capability manifests, validator
  descriptors, kernel shadow stack, kernel-stack-first entry, CPI-signed
  callbacks, W^X / NX / SMAP enforcement, KASLR.
- **Nested-kernel monitor** - portable MMU+WP page-table protection; PTE
  writers must go through an explicit write window.
- **Signed-everything (Track 2)** - in-kernel signed-artifact envelope reader
  with real Ed25519 threshold/quorum verification, a 25-case executable reject
  matrix, fuzz + differential decoder suites, and dual-approval quorum
  ratcheting.
- **Proven invariants (Track 3)** - 12 seL4-style security invariants backed
  by exhaustive vector checks (`scripts/test/eval_invariants.py`).
- **RAM-only / anti-forensic memory (Track 4)** - volatile-by-default RAM with
  secure zeroize on shutdown/panic/tamper, plus a data-egress vs. elevation
  barrier matrix.
- **Defense-in-depth roadmap (Tracks 5-6)** - hardware-residual hypervisor
  monitor and a compartmentalized software "-1" monitor
  (see `docs/architecture-defense-in-depth.md`).

One verification entry point runs the security guard suite:

```powershell
.\scripts\test\test_ghl_security_guards.ps1
```

## Prerequisites

| Tool | Version | Path |
|------|---------|------|
| [NASM](https://nasm.us/) | 2.16+ | `C:\Tools\nasm-2.16.03\nasm.exe` |
| [QEMU](https://www.qemu.org/download/) | Any recent | `C:\Program Files\qemu\` |
| OVMF firmware | Required for UEFI | Place `OVMF.fd` in `build\` |

## Build

### UEFI

```powershell
.\scripts\build\build_uefi.ps1
```

Outputs:

- `build\esp\EFI\BOOT\BOOTX64.EFI`
- `build\esp\EFI\BOOT\KERNEL.BIN`
- `build\data.img`

### BIOS

```powershell
.\scripts\build\build_bios.ps1
```

Outputs:

- `build\mbr.bin`
- `build\stage2.bin`
- `build\kernel.bin`
- `build\Grit.img`

## Verification

Use this before and after structural changes:

```powershell
.\scripts\test\test_verify_all.ps1
```

That runs:

- BIOS build
- UEFI build
- UEFI smoke boot with serial capture

UEFI smoke output is written to `build\smoke_uefi_serial.log`.

## Run

### UEFI

```powershell
.\scripts\run\run_uefi.ps1
```

This launches QEMU with:

- OVMF firmware
- 512 MB RAM by default (`.\scripts\run\run_uefi.ps1 -GuestMemory 256M` to override)
- standard VGA
- xHCI USB controller with mouse and keyboard
- serial on `tcp:127.0.0.1:5555`
- QEMU monitor on `telnet://127.0.0.1:4444`

Cache-first performance profile:

```powershell
.\scripts\build\build_uefi.ps1 -PerfProfile Cache32Max
.\scripts\run\run_uefi.ps1 -PerfProfile Cache32Max
```

This uses the 8-core QEMU topology. BIOS uses the strict 32 MB guest target;
UEFI uses a 36 MB OVMF floor while keeping the same kernel profile. See
`docs\cache32max-performance.md`.

### BIOS

```powershell
.\scripts\run\run_bios.ps1
```

BIOS also defaults to 512 MB RAM. Use `.\scripts\run\run_bios.ps1 -GuestMemory 256M`
to override.

## Source Layout

```text
src/
  boot/         BIOS MBR, Stage 2, UEFI loader, paging, early boot helpers
  include/      shared headers, constants, macros, syscall wrappers
  kernel/
    core/       entry, init flow, IDT/ISR, memory, PIC/PIT, TSS
    arch/       ACPI, APIC, IOAPIC, MADT, RSDP, AML parsing
    proc/       process, usermode trampoline, syscall boundary
    fs/         FAT16
    drivers/    hardware drivers
    gui/        kernel-resident WM, render, desktop, cursor, taskbar
    lib/        kernel helper libraries
  user/
    apps.asm    built-in ring-3 app code
    lib/        app-side include surface
    templates/  starter callback templates
    poc/        regression probes and security tests

docs/
  reference-index.md
  source-layout.md
  syscalls.md
  app-authoring.md
  architecture.md
  app-loader-format.md
  boot-reference.md
  usermode-reference.md
  kernel-function-reference.md
  memory-map-reference.md
  data-layout-reference.md
  state-machine-reference.md

scripts\build\build_uefi.ps1
scripts\build\build_bios.ps1
scripts\run\run_uefi.ps1
scripts\run\run_bios.ps1
scripts\test\test_smoke_uefi.ps1
scripts\test\test_verify_all.ps1
```

## App Development

The repo now has a small userland-facing include surface:

- `src/user/lib/grit_app.inc`
- `src/user/templates/hello_callback.asm`

For the current syscall and callback ABI, see:

- `docs/syscalls.md`
- `docs/reference-index.md`
- `docs/app-authoring.md`
- `docs/source-layout.md`
- `docs/architecture.md`
- `docs/app-loader-format.md`
- `docs/boot-reference.md`
- `docs/usermode-reference.md`
- `docs/kernel-function-reference.md`
- `docs/memory-map-reference.md`
- `docs/data-layout-reference.md`
- `docs/state-machine-reference.md`

## Notes

- All userspace apps are GritHL (`.ghl`); the raw-asm app migration is
  complete. `security_probe` intentionally stays raw asm as a fault-injection
  regression harness.
- `docs/TODO-INDEX.md` is the single entry point for the spec/TODO doc set;
  `docs/STATUS.md` holds detailed status and milestones.
- See `SECURITY.md` for the vulnerability disclosure policy.
- The private QRNG seed (`tools/quantum/seed.bin` and derived files) is a
  build secret and is never committed or published; releases ship only the
  folded boot image.
