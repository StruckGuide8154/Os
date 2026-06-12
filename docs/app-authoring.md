# GritOS App Authoring

This repo still ships built-in apps inside the monolithic kernel image, but
GritHL is now the supported SDK path for app code that should be maintained
above raw assembly. The source tree treats user-facing code as a separate layer
under `C:\Users\user\Documents\new\src\user`.

## What belongs in `src/user`

- Built-in ring-3 app logic
- callback implementations for draw, click, and key handling
- user-facing experiments and regression probes
- small app-side helper includes and templates

## Minimum app surface

For new SDK-authored apps, start from:

- `C:\Users\user\Documents\new\src\user\grithl\lib\core.ghl`
- `C:\Users\user\Documents\new\src\user\grithl\apps\hello.ghl`
- `C:\Users\user\Documents\new\src\user\templates\hello_callback.ghl`
- `C:\Users\user\Documents\new\scripts\build\build_ghl.ps1`

`scripts/build/build_ghl.ps1` compiles all `.ghl` apps and generates
`C:\Users\user\Documents\new\build\ghl\generated_apps.inc`, which is included
by `src/user/apps.asm`.

For legacy raw assembly app work, start from:

- `C:\Users\user\Documents\new\src\user\lib\grit_app.inc`
- `C:\Users\user\Documents\new\src\user\lib\grit_fs.inc`
- `C:\Users\user\Documents\new\src\user\lib\grit_window.inc`
- `C:\Users\user\Documents\new\src\user\templates\hello_callback.asm`

`grit_app.inc` gives you:

- shared constants
- syscall wrapper macros
- filesystem helper wiring
- the callback ABI notes in one place

`grit_fs.inc` gives you:

- FAT16 directory-entry offsets safe for user apps to inspect
- `NFS_NAME83` / `nfs_name83` for converting typed names into the 11-byte,
  space-padded FAT 8.3 format used by create, rename, and mkdir syscalls

`grit_window.inc` gives you:

- window-struct offsets used by current callbacks
- built-in app ids
- shared scratch-buffer constants used by the current built-ins

## Callback ABI

Handlers run in ring 3 through the trampoline in
`C:\Users\user\Documents\new\src\kernel\proc\usermode.asm`.

- Draw handler:
  `RDI` points to the shadow window struct in the app slot arena.
- Click handler:
  `RDI` is the shadow window pointer, `RSI` is mouse X, `RDX` is mouse Y.
- Right-click handler:
  `RDI` is the shadow window pointer, `RSI` is mouse X, `RDX` is mouse Y.
  The WM dispatches it once on right-button-down in the client area. Apps use
  it for context menus or any other secondary action; there is no global
  fallback menu.
- Drag handler:
  `RDI` is the shadow window pointer, `RSI` is mouse X, `RDX` is mouse Y.
  The WM dispatches it while the left button is held after an initial client
  press, only when the cursor position changes.
- Key handler:
  `RDI` is the shadow window pointer, `RSI` is the key value.

The window pointer is a shadow copy, not the live kernel window object. That is
intentional. User apps should treat it as read-mostly metadata and avoid
assuming kernel-only fields are writable.

## Filesystem ABI

User apps should use the syscall surface rather than direct kernel FAT16 calls.
The supported operations are:

| Operation | Call |
|---|---|
| Count visible entries | `SYS_FS_COUNT` |
| Fetch entry handle/copy | `SYS_FS_ENTRY index` |
| Read file data | `SYS_FS_READ entry, buffer, buffer_size` |
| Write or create file | `SYS_FS_WRITE name83, buffer, byte_count` |
| Create directory | `SYS_FS_MKDIR name83` |
| Rename entry | `SYS_FS_RENAME entry, name83` |
| Delete file or empty directory | `SYS_FS_DELETE entry` |
| Change directory | `SYS_FS_CHDIR cluster_or_0` |

Directory entries returned by `SYS_FS_ENTRY` are opaque handles backed by a
slot-local copy. Apps can inspect the copied 32-byte entry for display, but
metadata changes must go through `SYS_FS_DELETE`, `SYS_FS_RENAME`, or
`SYS_FS_MKDIR` so the kernel updates the real current-directory cache and disk
state.

GritHL apps that need mutable private data should declare it with a top-level
`state {}` block. Each field becomes a zeroed label inside the copied app blob,
so `&field` points at storage private to the active app slot. This is the
preferred replacement for app code reaching into kernel globals.

Example name conversion:

```asm
lea rdi, [name83_buf]
lea rsi, [typed_name]
call nfs_name83
SYS_FS_MKDIR name83_buf
```

Current FAT16 limits still apply: names are 8.3, entry handles are valid only
for the current directory view, and delete intentionally rejects non-empty
directories.

Display settings are exposed through syscalls, not kernel externs:

| Operation | Call |
|---|---|
| Read display flags | `SYS_DISPLAY_FLAGS` |
| Set display flags | `SYS_DISPLAY_SET_FLAGS flags` |
| Change display mode | `SYS_DISPLAY_SET_MODE width, height, 32` |
| Reinitialize cursor after a mode switch | `SYS_CURSOR_INIT` |
| Read desktop background theme | `SYS_DESKTOP_BG` |
| Set desktop background theme | `SYS_DESKTOP_SET_BG theme_id` |

## Launching apps with parameters

Any app can spawn another app - and pass it a string - through `SYS_APP_OPEN`
(syscall 23). The command line is parsed as `"<app> <params>"`:

- `<app>` is matched (case-insensitive) against the name table in
  `app_command_name_to_id` (`launch.inc`). Current names: `explorer`,
  `terminal`, `notepad`, `settings`, `paint`, `about`, `security` /
  `securityprobe`, `ping`.
- Everything after the first whitespace/comma is copied verbatim (up to
  `APP_SLOT_PARAM_SZ - 1` = 255 bytes) into the new window's L3 slot at
  `slot_base + APP_SLOT_PARAM_OFF` (`0x17C000`).

Notepad gets special treatment: if a param is present it is treated as a FAT16
path and the file is loaded. Every other app receives the raw string.

The terminal accepts an optional `open ` prefix, so `open ping 8.8.8.8` and
`ping 8.8.8.8` are equivalent at the shell.

### Reading params from a GritHL app

The launched window's `WIN_APPDATA` pointer gives you the slot base; params
live 0x17C000 bytes in. Seed your input field once, on first init only, so
later user edits aren't clobbered. Example from `ping.ghl`:

```
fn seed_ip_from_launch_params(win) {
    let app_base = lq(win + WIN_APPDATA);
    if app_base == 0 { return 0; }
    let p = app_base + 0x17C000;       # APP_SLOT_PARAM_OFF
    if lb(p) == 0 { return 0; }
    # ...validate + copy into ip_buf...
}
```

Gate the seed behind an `ip_init` flag (or equivalent) in your `state {}`
block - `draw()` and `key()` fire many times per second; you only want to
consume the param once.

## Recommended workflow

1. Add or edit app code under `src/user`.
2. Keep kernel-facing interfaces behind wrapper includes instead of hardcoding
   raw syscall numbers in app files.
3. Run `powershell -ExecutionPolicy Bypass -File .\scripts\test\test_verify_all.ps1`
4. If the smoke gate fails, inspect
   `C:\Users\user\Documents\new\build\smoke_uefi_serial.log`

## Design Rule

Even before apps become independently loadable binaries, write them as if they
already are:

- no direct references to kernel-only files
- no reliance on kernel virtual addresses
- no raw pokes into internal window-pool layout
- keep app-side helpers inside `src/user`

That keeps the path open for a future external app packer without another big
tree rewrite.

For the proposed external binary format and loader contract, see
`C:\Users\user\Documents\new\docs\app-loader-format.md`.
