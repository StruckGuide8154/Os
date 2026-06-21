# Grit Usermode Reference

This document covers the ring-3 callback path, the user app layout, and the
main exported usermode-facing entrypoints.

## Ownership

### Kernel-side usermode boundary

- `src/kernel/proc/usermode.asm`
  Ring-3 trampoline, slot/runtime handling, and callback return path.
- `src/kernel/proc/syscall.asm`
  Syscall entry, stack switch, dispatch, and return.
- `src/kernel/proc/syscall_validation.inc`
  User range, callback target, and directory-entry handle validation helpers.
- `src/include/l3_runtime.inc`
  Shared L3 runtime-frame offsets used by syscall and callback code.
- `src/kernel/proc/process.asm`
  Process records and scheduler-facing state.

### User-side code

- `src/user/apps.asm`
  Thin wrapper that includes the built-in app tree and defines
  `app_blob_start` / `app_blob_end`.
- `src/user/apps/*.inc`
  Split built-in app source.
- `src/user/grithl/apps/*.ghl`
  GritHL SDK app sources. `scripts/build/build_ghl.ps1` compiles these to `build/ghl/*.asm`
  and emits `build/ghl/generated_apps.inc`, which `src/user/apps.asm` includes
  inside the app blob.
- `src/user/lib/grit_app.inc`
  Stable syscall wrapper include.
- `src/user/lib/grit_window.inc`
  Shared user-visible window/app constants.

## Runtime Model

Each active user callback runs inside a per-slot arena:

- `APP_DATA_ADDR + slot * APP_SLOT_SIZE`

Normal app windows use slots `1..MAX_WINDOWS-1`; slot 0 is reserved for the
hidden wallpaper runtime. In randomized builds the window allocator starts its
free-slot scan at a fresh RDTSC/RDRAND-derived slot and wraps once, so a new
app launch does not predictably land at the lowest free user VA. `-NoMemRandom`
keeps the old deterministic slot order for diagnostics.

The automated serial gate for this path is `scripts/test/test_l3_app_markers.ps1`.

That slot holds:

- app-owned code/data copied or referenced by the trampoline
- a shadow copy of the current window struct
- per-slot user stack with a randomized top offset
- per-slot syscall stack
- per-slot runtime frame (`l3_runtime`)

The copied app blob is page-slid within the slot (`l3_slot_code_slide[]`) before
callbacks are translated. Strict W^X manifests are stored after applying that
slide, so executable page permissions and code hashing cover the relocated code
range rather than the unslid build-time offsets.

## Ring-3 Callback Flow

1. Kernel GUI code stores draw/click/key callbacks on a window.
2. `src/kernel/gui/window.asm` decides a callback should run.
3. `call_app_l3` in `src/kernel/proc/usermode.asm`:
   - picks the slot from `WIN_OFF_APPDATA`
   - records arguments and kernel return state in `l3_runtime`
   - mirrors the live window into the slot arena
   - optionally copies the terminal blob into the slot arena
   - enters ring 3 with `iretq`
4. User callback runs and may issue syscalls.
5. `src/kernel/proc/syscall.asm` services syscalls on the per-slot syscall
   stack.
6. Returning via `SYS_APP_DONE` lands in `call_app_l3_return`, which restores
   the saved kernel state.

## Exported Kernel Usermode Functions

### `src/kernel/proc/usermode.asm`

`enter_usermode`
- Generic helper to enter ring 3 at a supplied RIP.

`call_app_l3`
- Main callback trampoline from kernel GUI/process code into ring 3.

`call_app_l3_return`
- Restores the saved kernel stack/flags and returns to the caller after a ring-3
  callback.

`l3_prepare_test_callback`
- Copies a demo ring-3 payload into an app slot arena.

`l3_runtime_ptr`
- Converts slot id to runtime-frame pointer.

`l3_user_stack_top`
- Converts slot id to user-stack top address.

`l3_syscall_stack_top`
- Converts slot id to syscall-stack top address.

`l3_install_app_done_trampoline`
- Installs the slot-local trampoline used by `SYS_APP_DONE`.

`l3_translate_target`
- Maps kernel callback targets to slot-local user targets when needed.

State globals:
- `l3_current_slot`
- `l3_runtime`
- `l3_user_stacks`
- `l3_syscall_stacks`
- `l3_tmp_user_*`

### `src/kernel/proc/process.asm`

`scheduler_init`
- Clears and initializes the process table.

`process_create`
- Creates a process record tied to a slot/window pair.

`process_schedule`
- Scheduler entrypoint.

`proc_is_active`
- Tests whether a process is active.

`process_save_context`
- Saves a process context from a `PUSH_ALL` frame.

`process_restore_context`
- Restores a process context into a `PUSH_ALL` frame.

`process_kill_window`
- Kills the process owning a given window.

`process_find_by_window`
- Finds process state from a window id.

State globals:
- `current_process_id`

### `src/kernel/proc/syscall.asm`

See `syscalls.md` for the actual ABI table. Important kernel-side entrypoints:

`syscall_init`
- Programs the SYSCALL MSRs.

`syscall_entry`
- Common long-mode syscall entrypoint.

Validation helpers in this file own the user/kernel trust boundary for:
- user strings
- user buffers
- callback targets
- opaque FAT16 entry handles

## Exported User-Side Symbols

### `src/user/apps.asm`

`app_blob_start`
- Start marker for the built-in user blob used by syscall validation and some
  usermode target translation logic.

`app_blob_end`
- End marker for the built-in user blob.

### `src/user/apps/common.inc`

Shared built-in user helpers and test callbacks:

`app_l3_test_draw`
- Simple draw callback used by the L3 test/about path.

`app_l3_test_click`
- Simple click callback used by the L3 test/about path.

`app_l3_test_key`
- Simple key callback used by the L3 test/about path.

`app_terminal_kernel_draw`
- Kernel-visible alias/jump for terminal draw logic.

`app_terminal_kernel_key`
- Kernel-visible alias/jump for terminal key logic.

### `src/user/apps/launch.inc`

`app_launch`
- Central built-in app launcher by app id.

`app_open_file`
- Routes files to the right built-in app by type.

`app_open_file_in_notepad`
- Opens a file into Notepad.

### `src/user/apps/explorer.inc`

`app_explorer_draw`
- Explorer draw callback.

`app_explorer_click`
- Explorer click callback.

`app_explorer_key`
- Explorer key callback.

### `src/user/apps/terminal.inc`

`app_terminal_blob_start`
- Start of the terminal blob used by the trampoline.

`app_terminal_draw`
- Terminal draw callback.

`app_terminal_click`
- Terminal click callback.

`app_terminal_key`
- Terminal key callback.

`app_terminal_blob_end`
- End of the terminal blob.

### `src/user/grithl/apps/notepad.ghl`

Compiled active Notepad callbacks:

- `app_hl_notepad_draw`
- `app_hl_notepad_click`
- `app_hl_notepad_key`

These are installed by `src/user/apps/launch.inc`.

### `src/user/grithl/apps/settings.ghl`

Compiled active Settings callbacks:

- `app_hl_settings_draw`
- `app_hl_settings_click`
- `app_hl_settings_key`

These are installed by `src/user/apps/launch.inc`. The old
`src/user/apps/settings.inc` assembly implementation is deprecated and exports
no active callbacks.

### `src/user/apps/about.inc`

`app_about_draw`
- About dialog draw callback.

### `src/user/apps/shell.inc`

`app_show_context_menu`
- Shared Explorer context-menu popup helper.

`ctx_menu_visible`
- Shared context-menu visible flag.

### `src/user/apps/paint.inc`

`app_paint_draw`
- Paint draw callback.

`app_paint_click`
- Paint click callback.

`app_paint_key`
- Paint key callback.

## User Includes

### `src/user/lib/grit_app.inc`

Owns:
- syscall wrapper includes
- callback ABI notes
- filesystem helper include wiring

### `src/user/lib/grit_fs.inc`

Owns:
- FAT16 entry offset constants for user apps
- `NFS_NAME83` / `nfs_name83`, the documented app-side helper for converting
  UI filenames into the 11-byte FAT 8.3 names used by `SYS_FS_WRITE`,
  `SYS_FS_RENAME`, and `SYS_FS_MKDIR`

### `src/user/lib/grit_window.inc`

Owns:
- user-visible window offsets
- built-in app ids
- shared scratch-buffer constants used by the current built-ins

## When Debugging Usermode

- Bad callback target / wrong handler install:
  inspect `src/kernel/gui/window.asm`, `src/kernel/proc/usermode.asm`,
  `src/kernel/proc/syscall.asm`
- Wrong syscall return or validation reject:
  inspect `syscalls.md` and `src/kernel/proc/syscall.asm`
- Wrong per-app state / stale slot data:
  inspect `src/kernel/proc/usermode.asm` and `src/user/apps/state.inc`
- Built-in app bug:
  start in the corresponding `src/user/apps/*.inc`
