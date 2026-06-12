# Trace 10 - `app_launch(app_id)` → User-Mode `iretq` → First User Instruction

## Entry

Kernel-mode caller (e.g. taskbar click handler) → `call app_launch(rdi=app_id)`.

## Step 1: app_launch (`kernel/proc/usermode.asm`)

| # | Action |
|---|---|
| 1 | look up `app_table[app_id]` → entry contains: app blob load address, entry offset, L3 arena base/size |
| 2 | allocate next process slot in `process_table[]`; assign PID |
| 3 | copy app blob into L3 arena (or map already-loaded app); zero BSS |
| 4 | initialize syscall stack `l3_syscall_stacks[pid]` (4 KB) |
| 5 | set process `cr3` (currently identity-mapped - flat AS, all rings share) |
| 6 | mark process WF_RUNNING; enqueue in scheduler |
| 7 | `call call_app_l3(rdi=entry_addr, rsi=app_arg)` |

## Step 2: call_app_l3 (`usermode.asm`)

| # | File:Line | Action |
|---|---|---|
| 8 | usermode.asm | `push rbp/rbx/r12-r15` (callee-saved) |
| 9 | | save current kernel rsp into `[l3_kernel_rsp_save]` for syscall return path |
| 10 | | build IRETQ frame on stack: |
|    | | `push USER_DATA_SEG | 3` (SS, RPL 3) |
|    | | `push user_rsp` (top of L3 arena) |
|    | | `push 0x202` (RFLAGS: IF=1, reserved bit 1) |
|    | | `push USER_CODE_SEG | 3` (CS, RPL 3) |
|    | | `push entry_addr` (RIP) |
| 11 | | `mov rdi, rsi` (pass arg) ; clear all caller-saved regs to avoid leaking kernel state |
| 12 | | `swapgs` (if used; this kernel doesn't use GS-base swapping) |
| 13 | | `iretq` - CPU pops RIP/CS/RFLAGS/RSP/SS, switches to ring 3 with new RFLAGS |

CPU is now executing the user app's first instruction at `entry_addr` with stack at `user_rsp`.

## Step 3: app runs, eventually issues syscall

User app: `mov rax, syscall_num; mov rdi, ...; syscall`. CPU action:
- saves RIP→RCX, RFLAGS→R11
- loads RIP from MSR LSTAR (`syscall_entry`)
- loads CS/SS from MSR STAR
- masks RFLAGS by MSR SFMASK (clears IF, etc.)

## Step 4: syscall_entry (`kernel/proc/syscall.asm`)

| # | Action |
|---|---|
| 14 | switch to per-process kernel stack `l3_syscall_stacks[current_pid]` |
| 15 | save user GPRs onto stack frame |
| 16 | dispatch on `eax` syscall number |
| 17 | execute handler |
| 18 | restore user GPRs |
| 19 | `sysretq` - restore user RIP/CS/RFLAGS/RSP, return to ring 3 |

## Step 5: app exits via SYS_APP_EXIT (rax=10)

`syscall.asm`:
- mark process WF_EXITED
- `call call_app_l3_return` (usermode.asm) - restores kernel rsp from `[l3_kernel_rsp_save]`, pops r15/r14/r13/r12/rbx/rbp, returns from `call_app_l3` to original kernel caller.

## Audit-pass guarantees

- IRETQ frame ordering verified clean (Round 2): SS/RSP/RFLAGS/CS/RIP, all with RPL 3 selectors.
- All callee-saved regs preserved across kernel↔user transitions (`call_app_l3` saves rbp/rbx/r12-r15 on entry; `call_app_l3_return` pops them).
- L3 arena bounds enforced by `sc_validate_user_io_range` and `sc_validate_callback_target` on every syscall that takes a pointer or callback.

## Failure modes

- App jumps to invalid address → page fault → `isr_pf` → process killed (no recovery).
- Syscall with invalid pointer → -1 returned, app continues.
- App exhausts L3 stack → page fault as above.

## Invariants

- User code/data segments always have RPL=3 in IRETQ frame.
- Kernel rsp in `[l3_kernel_rsp_save]` matches the rsp-at-call_app_l3-entry exactly (so call_app_l3_return restores cleanly).
- Per-PID syscall stack is never shared.
- `current_pid` matches scheduler-selected process at every syscall entry.
