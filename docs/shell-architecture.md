# Desktop shell architecture (ring-3 `gshell`)

The Grit desktop shell — the taskbar, the desktop ("homescreen") icons, and the
Start menu — is a ring-3 GritHL application (`src/user/grithl/apps/gshell.ghl`)
driven by a data-driven content model (`src/user/grithl/lib/shell_config.ghl`).
It replaces the legacy kernel-asm shell (`src/kernel/gui/desktop.asm` +
`src/kernel/gui/taskbar.asm` + the `menu_entries` table in
`src/kernel/gui/taskbar_data.inc`).

Moving the shell out of ring 0 is a security win: a shell compromise can no
longer reach the kernel address space, the filesystem, the network, or W^X — it
runs in an ordinary sandboxed app slot under the same syscall capability gate as
every other app.

## Components

| File | Role |
|------|------|
| `src/user/grithl/apps/gshell.ghl`       | The shell process: renders the menu/desktop/taskbar and routes clicks. Privilege `APP_SHELL` (12). |
| `src/user/grithl/lib/shell_config.ghl`  | Single source of truth for shell *content*: the app catalog and the desktop / pin / Start-menu surfaces. |
| `src/include/constants.inc`             | `WM_LIST_REC` / `WM_LIST_TITLE_OFF` layout for `SYS_WM_LIST`. |
| `src/user/lib/grit_window.inc`          | Canonical `APP_*` id enum (mirrored by `shell_config.ghl`). |

### Capabilities

`gshell` launches on `MANIFEST_SHELL` with the minimum it needs:

* `CAP_GUI`       — draw its surfaces,
* `CAP_WM_QUERY`  — enumerate open windows (`SYS_WM_LIST`) for the taskbar,
* `CAP_APP_CTRL`  — launch apps from icons / menu entries.

Deliberately **no** `CAP_FS`, `CAP_NET`, or `CAP_WX`.

### Content model (`shell_config.ghl`)

A fixed-stride **catalog** holds one row per app (id, logical icon name, label,
default geometry, catalog/menu flags). Three **surfaces** are derived from it:

* **Desktop** ("homescreen") — an ordered, mutable list of app ids. Only apps
  flagged `CF_DESKTOP_OK` (and never `CF_HIDDEN`) may be placed here; this is the
  gate that stops a theme/config from putting an unlaunchable or dev-only entry
  on the homescreen.
* **Taskbar pin strip** — an ordered, mutable list of pinned launchers; the rest
  of the taskbar shows live windows from `SYS_WM_LIST`.
* **Start menu** — derived from the catalog: every `CF_MENU` row, in catalog
  order, so a single ordering source drives both.

The seed tables are the interim source. When the disk-backed loader lands they
are replaced by a parse of `assets/themes/<active>/shell.xml`; the public API
(`shell_cfg_init` + the enumerate/mutate fns) is already what that loader will
expose, so no shell-side change is required then.

## App-id drift contract

`APP_SHELL = 12` (and every other shell-surface app id) is duplicated in four
places that MUST stay in lockstep:

1. `src/user/lib/grit_window.inc`        — the canonical `APP_*` enum,
2. `src/user/grithl/lib/shell_config.ghl`— the GHL shell's mirror of the enum,
3. `src/user/apps/launch_dispatch.inc`   — the launch switch (`.launch_shell`),
4. `src/user/apps.asm`                    — the per-app integrity-manifest entry.

(4) is load-bearing: `app_segment_verify(APP_SHELL)` is the launch integrity
gate, and it returns 0 (fail-closed → the shell cannot open) without an entry.
`scripts/test/test_source_guards.ps1` cross-checks all four in the
"ring-3 shell (gshell) app-id chain" guard block.

## Per-app integrity

`gshell` is a normal manifested segment. The GritHL build wraps its bytes in
`app_seg_gshell_start/_end` (`build/ghl/generated_apps.inc`), and
`src/user/apps.asm` emits an `APP_MANIFEST_ENTRY APP_SHELL, app_seg_gshell_start,
app_seg_gshell_end`. The build tool (`tools/build/gen_app_manifest.py`) fills the
SHA-256, and `app_segment_verify` re-hashes the slot copy before first exec.
See `docs/per-app-integrity-manifest.md`.

## Migration staging

* **Stage 1–2 (done):** `gshell` + `shell_config` land; `APP_SHELL` launches as
  an *ordinary* window so the full render + `SYS_WM_LIST` + config pipeline can
  be QEMU-verified with zero boot-path risk. The legacy kernel shell stays
  authoritative; a temporary Start-menu row ("Grit Shell (new)") launches it.
* **Stage 3 (mount + route):** promote `gshell` to the authoritative
  full-screen shell slot — auto-launched at boot as a borderless, bottom-of-
  z-order desktop window. The compositor draws it in place of the kernel desktop
  icons (`desktop_draw_icons`) and kernel taskbar (`tb_draw`), and desktop
  input routes to it instead of `desktop_handle_click` / `tb_handle_click`.
  *No shell-side rewrite — just a different mount + input route.*
* **Stage 4 (this change):** the `gshell` per-app integrity entry, this doc, and
  the app-id source guard.

Because Stage 3 rewires the boot compositor (a black-screen-on-regression path
that the in-tree toolchain cannot QEMU-verify on every host), it is staged
behind a runtime feature toggle so a regression reverts to the proven kernel
shell instead of bricking the desktop — consistent with the BOOTCFG.TXT
feature-toggle pattern used for other compositor-class changes.
