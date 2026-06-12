# GritHL GUI Library

`src/user/grithl/lib/gui.ghl` is the supported UI layer for GritHL apps.
Use it before drawing custom rectangles/text directly. If a common control
looks wrong, fix `gui.ghl`; if an app bypasses the helper, the app owns that
behavior.

## Model

GritHL GUI is immediate-mode, React-like in the way apps describe the UI from
current state on every draw callback:

1. State lives in app-owned memory or kernel-provided app state.
2. `draw(win)` renders a deterministic view from that state.
3. `click(win, x, y)` and `key(win, k)` update state.
4. The window manager calls `draw` again when the scene is dirty.

There is no heap, virtual DOM, retained widget tree, or hidden event queue.
That is intentional for ring-3 OS apps: widgets are plain functions.

## Import

```ghl
use gui
```

`gui.ghl` imports `core.ghl`, so apps do not need both unless they want to be
explicit.

## Coordinates

`ui_rect` and `ui_text` take absolute screen coordinates.

`ui_rect_at`, `ui_text_at`, menus, dropdowns, carets, and inputs take
client-area coordinates: `(0, 0)` is inside the window border and below the
titlebar, the same coordinate space passed to `click(win, x, y)`.

## Window Helpers

```ghl
ui_win_x(win)
ui_win_y(win)
ui_win_w(win)
ui_win_h(win)
```

These read the shadow window struct provided to ring-3 callbacks. Use them
when building custom layouts.

## Drawing Primitives

```ghl
ui_rect(x, y, w, h, color)
ui_text(x, y, text, fg, bg)
ui_rect_at(win, x, y, w, h, color)
ui_text_at(win, x, y, text, fg, bg)
ui_fill_client_below(win, top, color)
```

Colors are `0x00RRGGBB`. The library defines standard colors like
`UI_COL_TEXT`, `UI_COL_SURFACE`, `UI_COL_MENU`, `UI_COL_DROPDOWN`, and
`UI_COL_BORDER`.

## Menus

```ghl
ui_menu_bar(win)
ui_menu_label(win, x, text)
ui_dropdown(win, x, y, w, item_count)
ui_dropdown_item(win, x, y, index, text)
```

Menu labels and item labels should usually be string literals:

```ghl
ui_menu_bar(win);
ui_menu_label(win, 6, "File");
ui_menu_label(win, 54, "Edit");
```

String literals compile into the app blob, so they are valid ring-3 strings
after the app is copied into its L3 slot. Avoid using old shared kernel string
externs for GUI text in GritHL apps.

## Carets And Inputs

```ghl
ui_caret(win, x, y)
ui_caret_blink(win, x, y)
ui_input(win, x, y, w, text, cursor_col)
```

`ui_caret_blink` uses `SYS_TICKS`; the compositor marks the scene dirty when
the blink phase changes so the caret actually flashes. Use this for editor and
input insertion points.

## Timing

```ghl
ui_ticks()
```

Returns the kernel PIT tick count through `SYS_TICKS`. It is currently exposed
for UI animation only; do not build persistence or file-format behavior from
raw tick values.

## Ownership Rule

For new GritHL GUI work:

- Use `gui.ghl` for menus, dropdowns, inputs, carets, and basic text/rects.
- Add missing common controls to `gui.ghl`, then use them from apps.
- Keep app code responsible for domain state and hit testing.
- Keep library code responsible for shared rendering metrics, colors, and
  widget visuals.
