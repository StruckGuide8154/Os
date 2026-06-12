# GritOS theme pack standard

A theme pack is a self-contained bundle that controls the visual surface of
GritHL apps: the color palette, the desktop background, and the system icon
set. Apps that draw through `gui.ghl` widgets pick up the active theme
automatically. Apps that want their own look opt out by drawing with raw
colors / icons instead of going through the theme API.

## Directory layout

```
assets/themes/
    ACTIVE                  # one-line text file: name of the active pack
    <name>/
        theme.xml           # metadata + palette (required)
        background.svg      # desktop wallpaper (required)
        icons/              # logical icon names → image files (optional)
            file.svg
            folder.svg
            app.svg
            ...
```

Pack name maps 1:1 to the directory name. The on-disk store is FAT16, so the
directory name must fit 8.3 (e.g. `LIGHT`, `DARK`, `NEON`).

## theme.xml

Single root `<theme>` element. Children:

- `<meta>` - `name`, `display`, `author` attributes
- `<palette>` - one `<color>` per palette slot

```xml
<theme>
  <meta name="light" display="Light" author="GritOS" />
  <palette>
    <color name="bg_base"     value="0xF5F6FA" />
    <color name="surface"     value="0xFFFFFF" />
    <color name="surface_2"   value="0xECEFF4" />
    <color name="border"      value="0xD8DDE3" />
    <color name="border_2"    value="0xC4CBD3" />
    <color name="accent"      value="0x2A6FFF" />
    <color name="focus"       value="0x2A6FFF" />
    <color name="error"       value="0xE5474D" />
    <color name="warning"     value="0xF7B52C" />
    <color name="success"     value="0x2EB56E" />
    <color name="text"        value="0x0F141E" />
    <color name="text_muted"  value="0x4B5563" />
    <color name="text_invert" value="0xFFFFFF" />
    <color name="menu"        value="0xECEFF4" />
    <color name="dropdown"    value="0xFFFFFF" />
  </palette>
</theme>
```

Color values are 24-bit hex `0xRRGGBB`. A pack MUST define every slot - the
runtime does not fall back to baked-in defaults if a slot is missing (no
"preset rubbish": the pack is the source of truth).

The 15 slot names are stable; their indices (`TC_*` constants in `theme.ghl`)
are the runtime contract. Adding a new slot is a versioned change: bump the
`<theme version="...">` attribute (omitted = v1).

## Backgrounds

`background.svg` is mandatory. SVG is the only format guaranteed today;
`image.ghl` dispatches by extension so `background.bmp` is accepted, and a
future `background.png` is a one-line dispatcher patch (see
`docs/media-formats.md` for the image-format contract).

## Icons

Optional `icons/<logical-name>.<ext>` files. Apps request icons by logical
name - `icon_render("file", x, y, size)` - and the helper resolves to
`assets/themes/<active>/icons/file.<svg|bmp|...>`. Missing icons fall through
to a "no-icon" outline so apps don't crash on a partial pack.

Reserved logical names (apps may use any name, but these are populated by
shipped packs): `file`, `folder`, `app`, `disk`, `back`, `close`, `min`,
`max`, `check`, `error`, `warn`.

## App opt-in / opt-out

- **Default (themed):** call `gui.ghl` widgets - `ui_button`, `ui_status_bar`,
  `ui_section_title`, etc. They resolve colors through `theme_col()` and
  follow the active pack without any app code change.
- **Custom (per-element):** pass raw `0xRRGGBB` values to the `color` /
  `bg` / `fg` parameters that `ui_*` widgets accept. The widget uses what
  the caller passed.
- **Custom (whole app):** ignore `theme.ghl` entirely and draw with
  `render_rect` / `render_text` plus app-local color constants. The app
  becomes immune to theme changes.
- **Per-process override:** `theme_override(TC_ACCENT, 0xFF00AA)` patches
  the slot for the current app only. Other apps are unaffected.

## Active pack

`assets/themes/ACTIVE` holds the active pack name (uppercase, 8.3 fits).
Switching themes today is a manual edit + reboot; a `theme_set_active(name)`
helper that persists the change and broadcasts a re-init event is a
follow-up once the IPC story for app notifications lands.

## Adding a new image format

`image.ghl` is the single point of dispatch. To support PNG (or any future
format) across every app at once, only `image.ghl` changes:

1. Add a decoder lib `png.ghl` exposing `png_render(buf, len, x, y, w, h)`.
2. Add one `if ext_is(p, "PNG")` branch to `image_render`.
3. Every app and every theme pack picks it up automatically - icons and
   backgrounds can both use the new format with no per-app work.

The decoder contract is intentionally minimal: render-to-framebuffer given a
byte buffer and a target rect. That keeps the standard portable across SVG,
BMP, and future raster/vector formats.

## Shipped packs

- `light/` - bright surface; accent `#2A6FFF`; bloom-style pastel SVG
  background.
- `dark/` - inverted surface; accent `#4FACFE`; ribbons-style SVG background.

These ship as the only two packs. They are not "presets" baked into the
library - they're regular packs that happen to live in `assets/themes/`,
authored against the same standard a third-party pack would use.
