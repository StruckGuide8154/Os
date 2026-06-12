# GritHL Compiler Security Model

GritHL/GritHLK security is fail-closed at the compiler boundary.

## Safe By Default

- User apps cannot emit privileged instructions.
- Boot modules cannot use `asm {}`.
- Kernel/boot bounded arrays trap on out-of-range indexing with `ud2`.
- `call_table()` bounds-checks indirect dispatch against a declared table.
- Normal generated app code uses syscall wrappers instead of kernel labels.

## Explicit Unsafe Capabilities

Operations that can cross an authority boundary require a top-level declaration:

- `unsafe raw_mem;` for raw `lb/lw/lq/sb/sw/sq` in kernel/boot targets.
- `unsafe implicit_extern;` for taking an undeclared symbol address.
- `unsafe boot_call;` for boot calls to undeclared labels.
- `unsafe boot_int;` for BIOS/software interrupts in boot code.
- `unsafe boot_io;` for boot port I/O.
- `unsafe boot_lgdt;` for boot GDT loads.
- `unsafe kernel_priv;` for privileged kernel intrinsics.
- `unsafe kernel_io;` for kernel port I/O.
- `unsafe kernel_int;` for kernel software interrupts.

Builds can pass `--deny-unsafe` to reject all unsafe declarations.

## Per-intrinsic rationale (boot target)

The principle: each hardware-touching primitive is a *named* intrinsic gated by
a *narrow* capability, so a compromised boot leaf can reach only the authority it
declared at the top of its own module - never the full machine. `--deny-unsafe`
is the default posture for any module that is not a deliberately-audited
hardware boundary.

- **`inb`/`outb` (`unsafe boot_io`)** - port-space reads/writes only; cannot
  touch memory, control registers, or descriptor tables. First user:
  `src/boot/ghl/a20_wait.ghl` (8042 polls + fast-A20). The module declares
  `unsafe boot_io` and nothing else, so even if its logic were subverted it
  cannot escalate beyond the I/O ports it issues. `--deny-unsafe` rejects it,
  which is correct: it is an audited I/O boundary, not general code.
- **`intn(vec)` (`unsafe boot_int`)** - vector must be a compile-time constant
  in `0..255`; no computed-vector dispatch. Confines BIOS-service authority to
  the explicit vector list visible in source.

### Features on the conversion ladder (rationale fixed BEFORE they are built)

When the Phase 3 ladder (`docs/grithl-boot-conversion.md`) lands these, the
capability gate is chosen so the blast radius of a compromised module stays
minimal:

- **`seg_load8`/`seg_store8` (proposed `unsafe seg_mem`)** - segment-override
  byte access. Gated separately from `raw_mem` so a module that only needs the
  A20 wrap-test (`check_a20`) cannot also perform flat 64-bit memory writes.
- **`pushf`/`popf`** - FLAGS only; no capability needed (cannot change privilege,
  paging, or memory). Pure caller-state preservation.
- **`uefi_call(fn,...)` (proposed)** - lays down the MS-x64 ABI (rcx/rdx/r8/r9 +
  32-byte shadow space) for firmware BootServices/protocol calls. The callee
  pointer is a value, not a label, so this does not grant arbitrary-label call
  authority; it is the UEFI analogue of `boot_call` and will carry its own
  `unsafe uefi_call` capability.
- **`pe_image { ... }` typed record** - emits the PE/COFF header from *named*
  fields (no magic literals), so the security-relevant fields (image base,
  section permissions, entry point) are reviewable rather than opaque `dd`s.

## What The Compiler Cannot Prove

The compiler cannot by itself stop a compromised kernel, malicious firmware, or
bad hardware from violating memory isolation. Runtime controls still matter:
page-table permissions, SMAP/SMEP/KPTI, W^X, syscall validation, app-blob
signatures, measured boot, and hardware privilege checks.
