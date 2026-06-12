# GritOS Invariant Registry

This page is normative. Update it with any change to fixed memory, L3 slot
layout, syscall numbers, callback entry, or process ownership.

## Fixed Memory

| Name | Value | Owner | Rule |
|---|---:|---|---|
| `APP_DATA_ADDR` | `0x2600000` | `boot_memory.inc`, paging, L3 | User-mapped app arena start. |
| `APP_SLOT_SIZE` | `0x200000` | L3, window manager | One private arena per window/process slot. |
| `L3_SYSCALL_STACK_ADDR` | `APPS_BLOB_ADDR + APPS_BLOB_MAX_SIZE` | L3 syscall path | Kernel-only syscall stack arena. |
| `MAX_WINDOWS` | `12` | GUI, L3, process table | Upper bound for window/app slots. Slot 0 is reserved, leaving 11 open app windows. |
| `L3_USER_STACK_SIZE` | `16384` | L3 callback path | Per-slot ring-3 callback stack. |
| `L3_SYSCALL_STACK_SIZE` | `4096` | syscall path | Per-slot kernel syscall stack. |

## L3 Runtime Frame

| Field | Offset | Rule |
|---|---:|---|
| `L3_RT_ENTRY` | `0` | Ring-3 target callback. |
| `L3_RT_ARG0..2` | `8..24` | Callback args mirrored per slot. |
| `L3_RT_KERNEL_RSP` | `32` | Return stack for `call_app_l3_return`. |
| `L3_RT_USER_RSP` | `48` | Saved user stack for syscall return. |
| `L3_RT_USER_RIP` | `56` | Saved syscall return RIP. |
| `L3_RT_APP_BASE` | `72` | Slot-local app arena base. |
| `L3_RT_SYSCALL_NUM` | `80` | Saved syscall number. |
| `L3_RT_SLOT` | `120` | Slot index for syscall validation and return. |
| `L3_RT_SIZE` | `128` | Runtime frame stride. |

## Syscall Range

Current public syscall numbers are `0..27`. New numbers require validation
docs, source guards, and a serial or source-level acceptance test.

## Callback Boundary

L3 callbacks enter through `call_app_l3`, return through
`call_app_l3_return`, and use slot-local runtime plus slot-local user/syscall
stacks. Kernel pointers must not be dereferenced by ring-3 app code.

## Window Layout

Window structure offsets live in `src/include/window_layout.inc`. GUI code must
include that file instead of repeating raw `WIN_OFF_*` constants.
