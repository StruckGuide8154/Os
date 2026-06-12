# GritHL SVG Support

GritOS has two SVG-facing GritHL libraries:

- `svg.ghl`: lightweight wallpaper IDs and raster primitive wrappers. Use this
  from normal apps that only need desktop background controls or direct line,
  circle, and triangle drawing.
- `svg2.ghl`: static SVG2 subset renderer. Use this only from apps that need to
  parse and rasterize SVG documents; it intentionally pulls in more code.
  It is a facade over concern libraries in `lib/svg2/`: `core`, `style`,
  `transform`, `shapes`, `path`, `paint`, `filter`, `mask`, `clip`, and
  `text_layout`.

The renderer is not a browser engine. It targets static OS icons and simple
illustrations that can be drawn into the back buffer through the current raster
syscalls.

## Static SVG2 Renderer

Entry point:

```ghl
svg_render(svg_buf, svg_len, x, y, w, h)
```

The renderer parses one SVG document through the kernel XML DOM, maps the root
`viewBox` to the destination rectangle, walks the tree, and draws directly into
the back buffer.

Hard limits:

- Maximum SVG input is bounded by the XML parser arena: 8192 nodes, 8192
  attributes, 256 KB decoded text/attribute storage, 1024 interned names, and
  depth 64.
- Individual `style` and `points` attributes are read through 256-byte scratch
  buffers.
- Individual path `d` attributes are read through a 512-byte scratch buffer.
  Longer paths are truncated by the XML copy API and should be split into
  simpler shapes.
- Individual text payloads are copied through a 256-byte scratch buffer and
  NUL-terminated before passing to the GUI text syscall.

## Support Matrix

| Area | Status | Notes |
| --- | --- | --- |
| XML element tree | Supported | Uses the kernel XML parser's single live document. |
| `version="2"` | Accepted | Version is not required for dispatch. |
| `viewBox` | Supported | Integer min-x/min-y/width/height, with `preserveAspectRatio` meet/slice/none alignment. |
| `fill`, `stroke`, `stroke-width` | Supported | Presentation attributes, inline `style`, and simple `<style>` selectors. |
| Inheritance | Supported | `fill`, `stroke`, `stroke-width`, and simple transforms inherit through nested nodes. |
| Colors | Supported subset | `#RGB`, `#RRGGBB`, `rgb(r,g,b)`, `none`, `transparent`, and basic named colors used by tests. |
| `style="..."` and `<style>` | Supported subset | Inline declarations plus simple tag, `.class`, and `#id` selector rules for fill/stroke. |
| `transform` | Supported subset | Common affine transforms are parsed by `svg2.transform`; geometry paths use the current matrix. |
| `<g>` | Supported | Used for inherited style/transform only. |
| `<rect>` | Supported | Rounded corners are ignored. |
| `<circle>` | Supported | Filled circles use kernel scanline rasterization. |
| `<ellipse>` | Approximate | Flattened to a 48-vertex polygon. |
| `<line>` | Supported | Routed through polygon stroke geometry. |
| `<polygon>` | Supported | Filled by scanline rasterization; strokes use polygon stroker. |
| `<polyline>` | Supported | Stroke path; open-shape fill remains intentionally limited. |
| `<path>` | Supported subset | `M/L/H/V/C/S/Q/T/A/Z`, absolute and relative; curves and arcs flatten before scanline fill/stroke. |
| `<use>` / `<symbol>` | Supported subset | Resolves `href`/`xlink:href` to `id` and renders the referenced subtree with `x`/`y` translation. |
| Gradients and paint servers | Supported subset | Solid, linear, radial, stops, spreadMethod, `gradientTransform`, bounded `objectBoundingBox`, and solid-color pattern resolution. |
| Opacity/alpha/compositing | Supported subset | Fill/stroke opacity, node opacity, ARGB filter/mask buffers, and source-over compositing. |
| Filters | Supported subset | Multi-primitive graph with `in`/`in2`/`result`, `feOffset`, `feGaussianBlur`, `feColorMatrix`, `feFlood`, `feMerge`, `feBlend`, `feComposite`, `feTurbulence` (Perlin fractal/turbulence noise), and `feDropShadow`. Evaluated tile-by-tile so a filter region larger than the arena still renders full-screen; a region that would tile finer than `FILTER_TILE_CAP` renders unfiltered. |
| SMIL animation | Static t=0 sample | `<animate>` on `opacity`/`stop-opacity` is sampled at its first keyframe. `<animateTransform>` is the identity at t=0. No timeline/playback. |
| Masks and clip paths | Supported subset | `<mask>` luminance/alpha compositing with mask region attributes, plus `clipPath` rect fast path and nested geometry stencils. |
| Text in SVG | Supported subset | `<text>`/`<tspan>` layout, anchor, letter/word spacing, rotated textPath placement, bounded `ttf.ghl` metrics/kerning, and polygon vector glyph drawing. |
| Embedded images | Supported subset | In-document `href="#id"` reuse and hex RGB raster data URI decoding; unsupported external URLs fall back to deterministic placeholder rectangles. |
| Scripting/DOM/events | Not implemented | Out of scope for kernel/user static raster path. |
| Anti-aliasing | Supported | Scanline filler samples 4 sub-scanlines per row and accumulates fractional pixel coverage; edges and curves are smoothed. Affects SVG rasterization only, not the desktop compositor. |

## Maintenance Rules

- Keep `svg.ghl` small. Do not import `svg2.ghl` from `svg.ghl`.
- `svg.ghl` is owned as a stable, low-size wallpaper/raster API. `svg2.ghl` can
  grow because it is opt-in and should hold heavier parsing, transform, shape,
  and path renderer code until GritHL has stronger module boundaries.
- Keep `svg2.ghl` compile-tested and runtime-marker-tested by
  `tests/ghl/svg_render_smoke.ghl`.
- Keep the visual regression descriptor in
  `tests/svg/svg_render_smoke.baseline.txt` aligned with the smoke fixture.
- Do not add browser-only features without deciding where their backing storage
  lives. New filters, masks, blend modes, gradients, and font features must fit
  the bounded arena/scratch model.
- When adding a new SVG feature, update this matrix and the smoke fixture in the
  same change.
- Avoid adding kernel syscalls unless the feature cannot be reasonably expressed
  through existing raster primitives.

## Known Accuracy Gaps

The biggest visual gaps are vector text scan conversion from parsed TrueType
glyph outlines, external raster image decoding, full multi-color pattern tiles,
and exact round caps/joins. Those are renderer-quality issues, not XML/parser
issues. They should be implemented behind focused helpers instead of making
`svg_render_node` or `svg_draw_path` larger.
