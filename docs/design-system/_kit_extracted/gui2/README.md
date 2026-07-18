# GritHL GUI v2 (`gui2`)

A retained-mode, batched replacement for the immediate-mode `lib/gui.ghl`.
Same drawing contract (the WM owns the titlebar/border; client coordinates
match click callbacks), dramatically less work per frame.

## Why it's faster than v1

`lib/gui.ghl` is immediate-mode: every `ui_rect`/`ui_text` is its own
syscall, and the whole client area is redrawn from app state every frame.
A modest window is hundreds of ring transitions per frame.

`gui2` keeps the widget tree alive and does five things v1 can't:

| File | Technique | What it removes |
|------|-----------|-----------------|
| `batch.ghl` | **Batched draw lists** — record fixed 64-byte primitives into a user-memory arena, cross the ring **once** with `SYS_GUI_BATCH`. | hundreds of syscalls/frame → one |
| `retained.ghl` | **Retained tree + content hashing** — re-stamp content; unchanged nodes emit nothing. | redrawing static widgets |
| `damage.ghl` | **Dirty-rect + async present** — repaint only the union of changed rects, cooperating with the compositor's vblank flip. | full-screen repaints |
| `layout.ghl` | **Measured/cached layout** — measure once, arrange skips clean subtrees on an epoch check. | recomputing positions every frame |
| `atlas.ghl` | **Glyph atlas** — rasterize each glyph once, blit cached cells. | re-rasterizing every glyph every frame |

A frame where nothing changed crosses the ring **once** (an empty present)
and draws **zero** primitives.

## Using it

```
use gui2
```

Build the tree once, keep the handles, re-stamp only what changed, then call
`g2_frame(root)` per frame. See `gui2/apps/monitor2.ghl` for a worked port.

## Proposed kernel syscalls

v2 adds four syscalls alongside the existing immediate ones (which stay for
v1 compatibility):

- `SYS_GUI_BATCH (30)` — walk a command buffer in one ring crossing.
- `SYS_GUI_PRESENT (31)` — queue a damage union; async flip on next vblank.
- `SYS_GUI_GLYPH_BAKE (32)` — rasterize one glyph into the atlas, return its cell.

The immediate `SYS_GUI_RECT`/`SYS_GUI_TEXT` remain as the fallback path for
uncached glyphs and for v1 apps.
