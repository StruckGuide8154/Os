# Unified theme system

Grit themes are semantic, deterministic, CPU-only, and generated from one
authoring file. A palette edit changes kernel chrome and GritHL applications
together or the build fails.

## Source of truth

Edit only [`assets/themes/theme-spec.json`](../assets/themes/theme-spec.json).
Do not edit color constants in `constants.inc`, seed tables in `theme.ghl`, the
`ACTIVE` file, or `.npl` files: those are generated outputs.

After editing:

```powershell
python tools/theme_tool.py validate
python tools/theme_tool.py generate
python tools/theme_tool.py check
```

`build_ghl.ps1` and the source-guard suite run `check` automatically. A stale,
partial, malformed, low-contrast, or mismatched theme cannot silently build.

Useful inspection command:

```powershell
python tools/theme_tool.py show
```

For safe one-token edits or build-wide selection, use:

```powershell
python tools/theme_tool.py set light taskbar_bg "#ECE8DE"
python tools/theme_tool.py activate dark
```

Both commands validate first, update files atomically, and regenerate all
consumers. A contrast-breaking edit is rejected without changing the source.
Selection is deliberately build-wide: a per-process switch would make
applications disagree with the kernel-owned taskbar and window chrome.

## Runtime cost

There is no runtime JSON or XML parser, filesystem traversal, allocation,
decompression, shader, or GPU dependency.

- Kernel chrome colors compile to NASM immediates.
- Each GritHL app seeds a fixed 512-byte table once.
- `theme_col(TC_*)` is a bounds check plus one qword load.
- Generated `.npl` resources are an eight-byte header followed by RGB triples;
  they are suitable for direct memory mapping if a future global runtime theme
  service is added.

Changing the palette does not change frame complexity.

## Semantic tokens

Token order is an ABI. Append new tokens; do not reorder or rename existing
ones without a schema-version migration.

| Token | Intended use |
|---|---|
| `bg_base` | desktop/app canvas |
| `surface`, `surface_2` | window/control surfaces |
| `border`, `border_2` | normal and strong borders |
| `accent`, `accent_hover`, `accent_pressed` | primary action states |
| `focus` | keyboard/pointer focus indication |
| `error`, `warning`, `success` | semantic status colors |
| `text`, `text_muted`, `text_tertiary` | text hierarchy |
| `text_invert` | text placed on the accent |
| `menu`, `dropdown` | menu surfaces |
| `taskbar_bg`, `taskbar_surface` | taskbar base and controls |
| `titlebar_active`, `titlebar_inactive` | window titlebar states |
| `titlebar_text_active`, `titlebar_text_inactive` | matching title text |
| `close_hover` | destructive hover state |
| `cursor` | pointer/caret color |

Use the most specific semantic token. For example, changing `taskbar_bg`
changes the taskbar without unexpectedly recoloring app canvases.

## Developer API

GritHL UI code should pass `UI_COL_*` handles or call `theme_col(TC_*)`.
Positive `0x00RRGGBB` values are always literal and are never guessed to be a
theme token. This is important for Paint palettes, media, SVG content, charts,
and application branding.

```text
ui_rect_at(win, x, y, w, h, UI_COL_SURFACE)
ui_text_at(win, x, y, label, UI_COL_TEXT, UI_COL_SURFACE)
theme_col(TC_TASKBAR_BG)
```

`theme_override()` exists only for an intentional app-local accent. It masks
input to 24-bit RGB and bounds-checks the token index. It must not be used to
imitate a global theme change.

Kernel code uses generated `COLOR_*` aliases. Chrome-specific aliases map to
specific tokens, rather than sharing one generic surface constant.

## Authoring and validation rules

The compiler accepts a deliberately small JSON schema:

- ASCII only and at most 128 KiB;
- schema version exactly `1`;
- at most 16 themes and 64 unique tokens;
- lowercase bounded identifiers;
- exactly one value for every token in every theme;
- uppercase `#RRGGBB` colors only;
- no unknown fields, duplicate JSON keys, references, paths, or executable
  expressions;
- declared contrast pairs checked for every theme.

Generated writes are atomic. Generated files include a SHA-256 digest of the
canonicalized specification, and `check` compares the complete expected bytes.
The digest is an integrity/drift marker, not a signature or trust anchor.

## Generated outputs

- `src/include/constants.inc` generated theme block: kernel chrome colors.
- `src/user/grithl/lib/theme.ghl` generated block: token indices and seed tables.
- `assets/themes/ACTIVE`: compatibility marker.
- `assets/themes/<name>/palette.npl`: packaged zero-pass palette.
- `src/resources/design-system/palette_<name>.npl`: embedded resource copy.

All copies are deterministic products of the same source and are verified by
the build. The old `theme.xml` files and manually maintained palette includes
were removed because they created multiple authorities.

## Security boundary

Theme data is untrusted authoring input until the build-time compiler validates
it. It cannot add code, name files, allocate runtime memory, or influence array
bounds. Release signing and artifact admission happen after generation, so the
resolved palette is covered by the same integrity process as the kernel/apps.

A future user-installable runtime theme service must preserve the same model:
validate a bounded NPL palette in a privileged broker, publish one immutable
generation to kernel and apps, broadcast invalidation, and roll back atomically
on failure. Loading theme-specific executable code or parsing XML inside every
application is explicitly outside this specification.
