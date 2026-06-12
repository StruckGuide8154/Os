# Grit Source Layout

This tree is organized by responsibility first, then by implementation detail.
The goal is to keep ring-0 kernel code, ring-3 app code, boot code, and shared
headers clearly separated so the OS can grow without turning into a grab bag.

## Top level

`src/boot`
Bootloaders, stage transitions, paging setup, BIOS/UEFI entry code, and early
boot support files.

`src/include`
Shared NASM headers, constants, syscall definitions, and macros.

`src/kernel`
Ring-0 kernel code only. Subdirectories map to kernel responsibilities.

`src/user`
Built-in ring-3 apps, user-facing experiments, and usermode PoCs/regression
probes.

## Kernel layout

`src/kernel/core`
Kernel entry, main init flow, IDT/ISR, memory, PIC/PIT, and TSS.

`src/kernel/arch`
ACPI/APIC/IOAPIC/RSDP/MADT/AML parsing and platform discovery code.

`src/kernel/proc`
Process, usermode, syscall dispatch, and syscall validation boundary code.

`src/kernel/fs`
Filesystem implementations and FS-facing kernel support.

`src/kernel/drivers`
Hardware drivers only.

`src/kernel/gui`
Kernel-resident window manager, desktop, render, cursor, and taskbar code.

`src/kernel/lib`
Kernel helper libraries used by the monolithic build.

## User layout

`src/user/apps.asm`
Thin wrapper that includes the split built-in user app tree.

`src/user/apps`
Per-app and shared usermode source modules. Keep new built-in app code split by
responsibility instead of growing `apps.asm` again.

`src/user/lib`
Shared app-side includes and the future home for userland helper code.

`src/user/grithl`
GritHL SDK sources: compiler, standard library, and `.ghl` apps compiled into
`build/ghl/generated_apps.inc` before kernel assembly.

`src/user/templates`
Small GritHL templates for new user callbacks and app experiments. Legacy raw
assembly templates may remain only for ABI/debug work that cannot use GritHL.

`src/user/poc`
Security regression probes and PoCs that should stay isolated from normal app
code.

## Script layout

`scripts/build`
Build entrypoints for BIOS, UEFI, and GritHL-generated app output.

`scripts/run`
QEMU launch entrypoints for BIOS and UEFI profiles.

`scripts/test`
Verification and smoke-test entrypoints.

`tools/build`
Build internals used by the script entrypoints.

`tools/debug`
Ad hoc debugging helpers, serial capture tools, and one-off inspection scripts.

## Build entrypoint

`src/kernel/kernel_build.asm`
The monolithic include wrapper. This file is the authoritative map of what gets
built into `KERNEL.BIN`.

## Safe edit workflow

1. Make a small move or code change.
2. Run `powershell -ExecutionPolicy Bypass -File .\scripts\test\test_verify_all.ps1`
3. Check `build/smoke_uefi_serial.log` if the UEFI smoke gate fails.
4. Only stack the next structural change after the verification pass.

`scripts/test/test_source_guards.ps1` is part of the verification chain and protects the
current syscall/window/Explorer regressions plus the split app layout markers.

## Current rule of thumb

If code runs in ring 0, it belongs somewhere under `src/kernel`.
If code is ring 3 or app-facing, it belongs under `src/user`.
If a file does not fit cleanly, create a clearer subdirectory instead of
dropping it into a catch-all folder.
