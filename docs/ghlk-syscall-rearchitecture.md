# GHLK-native syscall re-architecture (future-proof plan)

Status: **blueprint / agreed direction (2026-06-02)**
Goal: author the kernel syscall path in safe, traceable, bounds-checked GritHL
(zero `asm{}`), by **re-architecting** it to fit the language - NOT transliterating
the existing register-exact assembly.

## Why transliteration fails (settled)
Two independent agents + direct analysis confirmed: `syscall.asm` is one giant
function where ~70 handlers share live physical registers (`r12`=table row,
`r15`=slot) and a single `PUSH_ALL` frame, reading args at fixed `[rsp+ALL_*]`
offsets, dispatched by `jmp [r12+off]`, falling through to one shared epilogue.
GHLK is the opposite by design: an `rax`-accumulator machine, one owned frame per
`fn`, no register naming, no `rsp`-relative access. A 1:1 port would require
adding register-read/write, `rsp`-relative access, and tail-jump dispatch - which
would **turn GHLK back into assembly** and destroy the safety properties. So we
re-architect instead.

## Target architecture (GHLK-native)
- **Entry trampoline** - one `naked` fn `syscall_entry` (the `LSTAR` target).
  Uses intrinsics only (zero `asm{}`): `smap_open()`, KPTI `write_cr3()`, save the
  user GP regs + RCX(rip)/R11(flags) into a per-slot frame (`push_val`/`read_rsp`
  or a `data` frame buffer), switch to the kernel syscall stack (`write_rsp`),
  then `call sc_dispatch(num, slot, a0..a5)` (System-V), store the result, restore,
  `sysretq()`. This is the only low-level module; everything below is structured.
- **Dispatcher** - `fn sc_dispatch(num, slot, a0..a5) -> result`: validates `num`,
  runs the capability/rate/permutation checks (structured fns over `data` arrays,
  bounds-checked), then `call_table(syscall_handlers, num)` - a **bounded** indirect
  call into the fixed handler set.
- **Handlers** - each a normal `fn sc_xxx(slot, a0..a5) -> result`. Args arrive as
  parameters (no shared-register contract); the result is returned (no shared
  epilogue / `jmp .done`). Calls into fat16/wm/render/etc. stay normal `call`s.
- **Validator / caps / permutation / HMAC** - structured fns over `data`/`state`
  buffers; all buffer access bounds-checked (#UD on OOB).
- **Data section** - `data NAME: count [x width] = init;` (+ `align`, strings,
  `NAME_count`) reproduces every array with its exact name/size/width/init.

## Compiler support (all shipped + verified, byte-identical, on refactor/syscall-split)
1. Privileged intrinsics - `sysretq/cli/sti/wrmsr/rdmsr/write_cr3/invlpg/stac/clac/
   rdtsc/rdrand/inb/outb/cpuid_*` etc. (zero `asm{}`).
2. Source-line provenance - every instruction `; file:line` (zero machine-code cost).
3. Bounds-checked `state`/`data` indexing - OOB ⇒ `ud2`.
4. `data` decls - exact names, widths (db/dw/dd/dq), strings, `align`, derived sizes.
5. `table` + `call_table` - bounded indirect dispatch (safe replacement for `jmp [reg]`).
6. `FN_BEGIN` signatures for exported fns - satisfies `tools/check_coverage.py`.
7. `naked` fn + `read_rsp/write_rsp/push_val/pop_val` - for the entry trampoline.

## Staged migration (each stage builds green + QEMU-boot-verified; NOT byte-identical except stage 1)
1. **Data section** → `syscall_data.ghl` emitting the identical data symbols;
   remove those defs from `syscall_data.inc`. Target: data bytes byte-identical.
2. **Leaf helpers** (caps, HMAC, validator, strike/anomaly, panic pads) → `.ghl`
   fns with the same globals; remove from the `.inc`s. Boot-verify.
3. **Permutation + manifest** (`syscall_perm`) → `.ghl`. Boot-verify.
4. **Handlers** → batches of `fn sc_xxx(slot,a0..) -> result`; build the
   `syscall_handlers` table. Re-point the dispatcher to `call_table`. Boot-verify
   each batch (serial diff vs baseline on the deterministic `-NoMemRandom` path).
5. **Dispatcher + entry trampoline** → structured `sc_dispatch` + `naked`
   `syscall_entry`. Retire `syscall.asm` + remaining `.inc`. Update
   `tools/check_coverage.py`'s file list to the generated modules. Final boot-verify.

## Risks / fidelity watch-list
- Exact ordering of SMAP/KPTI/shadow-stack (`KPROLOGUE/KEPILOGUE`) vs stack switch.
- Heterogeneous per-slot syscall permutation (security_todo §12) - must wrap the
  `call_table` index.
- `SC_TRACE_APPEND` clobbers rax (see memory `feedback_sc_trace_append_clobbers_rax`).
- Capability/CPI callback verification at every dispatch site.
- Handle-table W^X carveout; shadow-stack stride.
- Verify by **serial diff** on `-NoMemRandom -NoKaslr`, not a hash.

## Not the compiler's job
Hypervisor-enforced isolation (kernel-below-hypervisor, EPT/SLAT) is runtime/HW.
The compiler's role is region/ownership manifests the loader + a thin hypervisor
enforce. Separate track; see `nested_kernel_monitor`.
