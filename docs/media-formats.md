# Grit Media Formats and Player Architecture

This document defines the native image and video container formats used
by Grit, the dispatch model the Media Player uses to render them, and
the layered library structure that lets future apps reuse the timeline
widget without rewriting any pixel-pushing code.

## Scope and explicit non-goals

Grit targets widely-compatible interfaces. The Media Player follows
the same rule:

- **Framebuffer only.** All blitting goes through the UEFI GOP linear
  framebuffer (`bb_addr`, `scr_pitch`). No iGPU acceleration, no
  vendor-specific MMIO. The 780M DCN/DMUB bring-up path was retired in
  May 2026 (see `deprecated/780M_IGPU/`).
- **Pure scalar code.** The scaler in `media_viewer.inc` is portable
  scalar x86-64 with no SSE/AVX. The framebuffer is WC-mapped already,
  so a `mov [bb_addr+...], eax` per pixel is already a fast write. A
  SIMD rewrite is sketched as a future-work TODO but blocked on the WM
  preserving xmm across draw callbacks.
- **No worker threads.** Frames advance once per WM tick from inside
  the window's draw callback. There is no decode-ahead worker pool;
  there is also no kernel scheduler primitive user apps can spawn
  against. The current path keeps idle CPU low because the per-frame
  work is just a single nearest-neighbor pass - well under a millisecond
  on the machines Grit boots on.
- **No audio.** Out of scope until the kernel has a mixer.

## Container formats

### NIC1 - Grit Image (static)

Used by `src/resources/design-system/icons/*.nic` and by Media Player
for any single-frame image.

| Offset | Size  | Field    | Notes                                    |
|-------:|------:|----------|------------------------------------------|
| 0      | 4     | magic    | `'NIC1'` = `0x3143494E` little-endian    |
| 4      | 2     | width    | uint16, pixels                           |
| 6      | 2     | height   | uint16, pixels                           |
| 8      | 1     | bpp      | 32 (only supported value)                |
| 9      | 7     | reserved | zero-filled                              |
| 16     | w·h·4 | pixels   | row-major top-down BGRA, alpha 0 = skip  |

### NBA1 - Grit Animation (video)

Used by `/BOOTANIM.NBA`. Frame sequence, no audio. Frames are top-down
BGRA, identical pitch to NIC1.

| Offset | Size    | Field       | Notes                                |
|-------:|--------:|-------------|--------------------------------------|
| 0      | 4       | magic       | `'NBA1'` = `0x3141424E`              |
| 4      | 4       | width       | uint32 pixels                        |
| 8      | 4       | height      | uint32 pixels                        |
| 12     | 4       | frame_count | uint32                               |
| 16     | 4       | fps         | uint32                               |
| 20     | w·h·4·N | frames      | concatenated BGRA frames             |

Playback is driven by the 100 Hz PIT `tick_count`. The renderer keeps
per-window state - current frame, pause flag, last-tick snapshot,
pending seek, loop mode - in the app slot via the GritHL `state { }`
block declared in `src/user/grithl/apps/media.ghl`.

### BMP (24/32bpp)

Media Player accepts uncompressed BI_RGB `.BMP` files at 24bpp and
32bpp. The renderer decodes rows into slot-local top-down BGRA scratch
and routes through the shared scaler, so BMP stills get the same
fit-to-window letterboxing as NIC images.

The standalone legacy BMP viewer still uses `app_bmp_draw`.

### SVG (subset)

Detected by either `'<svg'` at offset 0 or `'<?'` (`<?xml ...?>`)
followed by a later `<svg`. The rasteriser currently letterboxes the
client area and prints a "preview pending" placeholder; the parsing
work is in §6 of `media_viewer.inc` and the planned subset is:

- `<rect x y width height fill="#rrggbb">`
- `<circle cx cy r fill="#rrggbb">`
- `<line x1 y1 x2 y2 stroke="#rrggbb">`
- `viewBox="x y w h"` *or* `width`/`height` attrs
- Solid fills only - no gradients, filters, text, transforms, CSS.

This subset is the "fast rasterised low-res SVG" appropriate for icons
and simple diagrams. Full SVG is intentionally out of scope.

### XML (text view)

Any file beginning with '<?' that isn't recognised as SVG is shown as
plain top-aligned text. Useful as a quick viewer for config files and
manifests without launching Notepad. Keyboard scrolling is scaffolded
through the GritHL Media Player state (`mp_text_scroll_line`) and
Up/Down/PageUp/PageDown update that requested first visible line for
XML/text previews. The current kernel-side XML renderer still owns the
line walk and draw origin; the remaining renderer step is to consume that
state while drawing.

## Architecture: where each piece lives

```
+--------------------------------------------------------------+
|  src/user/grithl/apps/media.ghl                             |
|  Thin app shell. State block + click/key delegate to lib.    |
+----+-----------------+--------------------------------------+
     |                 |
     v                 v
+---------+   +-----------------------+
| media   |   | media_player          |   src/user/grithl/lib/
| (lib)   |   | (lib)                 |
+---------+   +-----------------------+
| codec   |   | layout consts         |
| probe   |   | hit-test              |
| header  |   | scrub math            |
| readers |   | seek state machine    |
| time fmt|   | click/key dispatch    |
+---------+   +-----------------------+
                          |
                          | reads/writes slot state by name
                          v
+--------------------------------------------------------------+
|  src/user/apps/media_viewer.inc  (kernel asm)                |
|  §1 magics      §5 NBA + frame advance (timer)              |
|  §2 dispatch    §6 SVG/XML stubs                            |
|  §3 scaler      §7 control-bar drawing                      |
|  §4 NIC/BMP     §8 future-work notes                        |
+--------------------------------------------------------------+
```

Drawing currently happens kernel-side because it needs `bb_addr` and
`tick_count`. The control-bar drawing also lives kernel-side so the two
redraw paths can't drift. The lib `media_player` is therefore render-
free today - it owns layout constants, hit-testing, and the state
machine. A future `SYS_MEDIA_BLIT_SCALED` syscall would let the lib
take over drawing too; the public function names will not change.

## Adding a new codec - checklist

1. **Pick a magic.** 4 ASCII bytes, suffix the format version (`NIM2`,
   `NRI1`, ...) for fixed-header binary formats; a recognisable byte
   prefix for text-based formats.
2. **Document the layout** in a new heading above.
3. **Add the kernel blitter.** Write `nx_media_blit_<fmt>(rdi=file,
   rsi=window)` in `src/user/apps/media_viewer.inc` §4-§6.
4. **Register dispatch.** Add one `cmp eax, <MAGIC> / je .blit_<fmt>`
   row in §2 and the `.blit_<fmt>:` thunk.
5. **Route the extension.** Add a 3-byte compare in `app_open_file`
   (`src/user/apps/launch.inc`) that jumps to `app_open_file_in_media`.
6. **(Optional) Header readers.** Add a row to the user-mode table in
   `src/user/grithl/lib/media.ghl` so explorer thumbnails and property
   dialogs can read header fields without involving the kernel.

No other file should need editing.

## Reusing the timeline widget in another app

Any future app with playback semantics (slideshow, screen recorder
preview, animation editor) can embed the same control bar by:

```
use gui
use media
use media_player

state {
    mp_paused: 4;
    mp_frame: 4;
    mp_last_tick: 8;
    mp_no_loop: 4;
    mp_seek_to: 4;
    mp_dragging: 4;
    mp_text_scroll_line: 4;
}

fn click(win, cx, cy) {
    let app_base = lq(win + WIN_APPDATA);
    let file = app_base + APP_SLOT_BMP_FILE_OFF;
    mp_handle_click(win, cx, cy, file,
                    &mp_paused, &mp_frame, &mp_no_loop,
                    &mp_seek_to, &mp_dragging);
}
```

`mp_handle_click` returns 1 if it consumed the click. An app that wants
extra buttons can call `mp_hit_test_controls` directly and fall through
to its own handling.

## Roadmap (recorded in `media_viewer.inc` §8)

- **SIMD scaler.** Inner-loop SSE2 form - needs WM xmm save/restore.
- **Dirty-rect awareness.** Skip the blit on no-frame-change ticks.
- ~~**BMP through the shared scaler.**~~ **Landed.** Media Player now
  decodes uncompressed 24/32bpp BI_RGB BMP rows into slot-local BGRA
  scratch and passes them through the same scaler used by NIC.
- **SVG subset rasteriser.** Wire `<rect>`, `<circle>`, `<line>`.
- ~~**`SYS_MEDIA_BLIT_SCALED` syscall.**~~ **Landed (syscall #66).** The
  kernel-side stub in `syscall.asm → .sc_media_blit_scaled` validates
  the source buffer range, both dimensions, the (w·h·4) byte count
  against an explicit cap, the window id, and the reserve-bottom /
  alpha-key inputs. Exposed to GritHL as `media_blit_scaled(...)` in
  `lib/media.ghl`. The remaining step is moving codec dispatch out of
  `app_media_draw` (kernel asm) into user-mode ghl and retiring the
  asm guard in `window.asm`.
