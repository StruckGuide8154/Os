# SVG Advanced Features - Design Document

Status: **in-progress.** Stage 1a (`feOffset`), Stage 2a (rect clipPath),
and Stage 3b/3c (text layout) landed and wired into the render loop. Buffered
filter primitives (blur/colorMatrix), geometry-stencil clips, masks, and the
TTF glyph path remain scaffolded - see the migration checklist below.

This document captures the architecture decisions for implementing SVG filters,
masks/clipping, and full text layout in the GritHL static SVG renderer
(`src/user/grithl/lib/svg2/`). It exists so that future contributors don't
need to re-derive the tradeoffs.

---

## Goals & non-goals

**Goals.** Render typical UI/icon SVG with `<filter>` (Offset / GaussianBlur /
ColorMatrix), `<mask>`, `<clipPath>`, `<tspan>`, `<textPath>`, `text-anchor`,
and real glyph metrics from an embedded TrueType font.

**Non-goals.** SMIL animation, full CSS, foreign objects, scripting, advanced
filter primitives (feMorphology, feTurbulence, feDisplacementMap, lighting),
bidi text, complex shaping (ligatures, contextual forms), variable fonts.

---

## Architecture: how filters integrate with the rasterizer

### The render-target problem

Today all rasterization goes through kernel syscalls (40-44 in
`src/user/grithl/lib/svg.ghl`). The kernel writes pixels directly to the
back buffer. Filters require rendering a subtree into an **intermediate ARGB
buffer**, transforming the pixels (convolve, color-multiply, offset), then
compositing back.

### Decision: user-mode ARGB canvas, no new kernel syscalls (chosen)

Filter intermediates live in a GritHL `state {}` buffer (BSS in the SVG
renderer's app slot). User-mode code rasterizes into the canvas with direct
`sw()` writes - no kernel round-trip per pixel. To composite the filtered
result back, we loop over canvas pixels and call the existing
`sc_blend_pixel` syscall. This is O(region_pixels) syscalls per filter
application - fine for typical icon-sized regions (≤ 128² = 16 K pixels),
and a future `sc_gui_blit_argb` syscall can replace the loop without
changing any caller.

Memory cap: two 128×128 ARGB canvases (128 KB total) in the renderer's
slot. Larger filter regions clip to 128² with a one-time debug print. SVG
icons are small; UI illustrations rarely need more.

### Decision: kernel grows three bounded buffer-write syscalls (deferred)

Numbering tentative; reserve in `src/include/syscall_user.inc`:

| # | Name | Args | Purpose |
|---|------|------|---------|
| TBD | `SYS_GUI_BUF_BLEND_PIXEL` | buf, pitch, w, h, x, y, argb | Source-over blend into a user-owned ARGB buffer |
| 51 | `SYS_GUI_BUF_READ_PIXEL` | buf, pitch, w, h, x, y | Read one ARGB pixel |
| 52 | `SYS_GUI_BLIT_ARGB` | dst_x, dst_y, src_buf, src_w, src_h, src_pitch | Composite a user buffer onto the back buffer |

**Security model.** The kernel never trusts the user-supplied buffer pointer
without bounds-checking against the calling process's writable address range
(`APP_DATA_ADDR + slot * APP_SLOT_SIZE` ± slot size). Existing PCID/CR3 isolation
already prevents cross-app reads; these syscalls add bounds validation per
call. Pitch is required to be `>= w * 4` and `<= APP_SLOT_SIZE / h` to prevent
integer overflow in offset computation.

### Decision: render context threaded through callsites

`raster.ghl` gains a small **render context** struct (target buffer, pitch,
w, h, clip rect). All shape renderers accept a `ctx` handle. The default
context wraps the back buffer (syscalls 40-44). Filter code allocates an
intermediate context, redirects the subtree render, then runs filter passes
read/writing through the new buffer syscalls.

Rationale: matches Skia/Cairo's `SkCanvas`/`cairo_t` pattern; future features
(window-local layers, hit-testing buffers, PDF export) reuse the same
abstraction.

### Decision: filter-region-bounded buffers

`<filter x y width height>` defines the region; default `-10% -10% 120% 120%`
of the filtered element's bounding box. We compute the region in device
space, clip it to a hard maximum of **1024×1024 px** (4 MiB per buffer), and
allocate two ping-pong buffers from a per-render scratch arena.

Scratch arena: 8 MiB at `APP_SLOT_TOP - 0x800000` for the SVG-renderer slot.
Allocator is bump-only and resets on each `svg_render()` call - filters can't
outlive a render call. This rules out a whole class of UAF bugs by
construction.

---

## Filter primitives

Each primitive reads from one or two named inputs (`SourceGraphic`,
`SourceAlpha`, or a previous primitive's `result`) and writes to its
`result` (default: pipeline-implicit).

### `feOffset`
Trivial: copy src to dst at offset `(dx, dy)`. **Special case when filter
chain is just feOffset on SourceGraphic with no further consumers**: skip
the buffer dance entirely and just push a `mat_translate(dx, dy)` onto the
matrix stack. This is what's implemented today.

### `feGaussianBlur`
Two-pass separable convolution. Kernel computed once: `G(x) = exp(-x² /
2σ²) / Z`. σ comes from `stdDeviation`; kernel radius = `ceil(3σ)`.

- `exp` and division-by-Z computed in fixed-point. We can pre-tabulate the
  kernel into a 64-entry array (max σ = 20 → radius = 60 → store half-kernel
  since symmetric).
- Horizontal pass: src → tmp. Vertical pass: tmp → dst.
- Edges: clamp (replicate edge pixel).

### `feColorMatrix`
4×5 matrix multiply per pixel (RGBA in, RGBA out, plus bias column). Modes:
`matrix`, `saturate`, `hueRotate`, `luminanceToAlpha` (all expressible as a
4×5 matrix, parsed into one canonical form).

### Filter graph evaluation
Parse `<filter>` children once into a primitive list. Each primitive has
`in1`, `in2`, `result`. Maintain a string-keyed result map (small - most
filters are 1-4 primitives). Evaluate top-to-bottom. Last primitive's output
is composited back to the original render target inside the filter region.

---

## Masks & clipPath

### `<clipPath>`
Easier than masks. Two cases:

1. **Axis-aligned rect clip** → push onto the existing scanline clip rect in
   `raster.ghl`. Fast path.
2. **Arbitrary geometry clip** → rasterize the clipPath's contents to a 1-bit
   stencil buffer over the bounding box. Scanline filler ANDs with the
   stencil before emitting each span.

### `<mask>`
Always full-fidelity:
1. Rasterize mask contents to an 8-bit alpha buffer using
   `mask_content_units` ("userSpaceOnUse" or "objectBoundingBox").
2. Render the masked subtree to an ARGB intermediate.
3. Per-pixel multiply ARGB.alpha by mask.alpha, composite to original target.

Mask alpha comes from SVG2 default `luminance` (R·0.2125 + G·0.7154 +
B·0.0721, then ×A) or `alpha` (just A) per `mask-type`.

---

## Text layout

### Decision: minimal TrueType subset, embedded font

We embed **one** TTF (DejaVu Sans Book, ~700 KB) into the SVG2 lib as
`lib/svg2/font_data.ghl` (generated from the `.ttf` via a build-time
PowerShell script). Parsed tables we need:

| Table | Purpose | Skip if missing |
|-------|---------|-----------------|
| `head` | unitsPerEm, indexToLocFormat | required |
| `cmap` format 4 (BMP) + format 12 (full Unicode) | codepoint → glyph id | required |
| `hhea` | ascent, descent, lineGap | required |
| `hmtx` | per-glyph advance width, lsb | required |
| `maxp` | numGlyphs | required |
| `loca` | glyph offset table | required |
| `glyf` | glyph outlines (simple + composite) | required |
| `kern` format 0 | pair kerning | optional, off when absent |

**Glyph rendering**: outlines flattened with the existing Bezier subdivider
(`flatten.ghl`) into the polygon buffer; filled with the scanline rasterizer.
Glyph advance and metrics from `hmtx`.

**No hinting.** No subpixel rendering. No GPOS/GSUB. No script shaping.

### Layout features

- `text-anchor`: start / middle / end - adjust x by 0, -width/2, -width.
- `<tspan>` with absolute `x`/`y` or relative `dx`/`dy`: chains positioning;
  each tspan is an independent sub-run.
- `<textPath>`: walk along the referenced path using flatten.ghl, advancing
  by each glyph's hmtx width, computing tangent angle for rotation.
- `kerning="auto"` (default): apply `kern` table; `kerning="0"` disables.

---

## Module layout (target)

```
lib/svg2/
  filter.ghl         # filter graph parse + dispatch
  filter_offset.ghl  # feOffset
  filter_blur.ghl    # feGaussianBlur (separable conv)
  filter_color.ghl   # feColorMatrix
  filter_ctx.ghl     # intermediate-buffer scratch arena + ARGB ops
  mask.ghl           # <mask> + <clipPath>
  ttf.ghl            # TrueType parser
  font_data.ghl      # embedded DejaVu Sans bytes
  text_layout.ghl    # tspan, textPath, text-anchor, kerning
```

Each module < 400 lines. Independent test paths (one minimal SVG per
feature in `build/test_svg/`).

---

## Migration plan & current status

- [x] **Stage 0**: design doc (this file).
- [x] **Stage 1a**: `feOffset` standalone (matrix-translate shortcut). Lands
      in `filter.ghl` today.
- [ ] **Stage 1b**: kernel syscalls 50/51/52 + bounds validation tests.
- [ ] **Stage 1c**: filter_ctx.ghl (scratch arena + intermediate buffers).
- [ ] **Stage 1d**: filter graph parser (`<feFoo in="" result="">` resolution).
- [ ] **Stage 1e**: feGaussianBlur (separable conv).
- [ ] **Stage 1f**: feColorMatrix.
- [x] **Stage 2a**: clipPath (rect fast path). `clip.ghl` wired into
      `svg2.ghl:svg_render_node` - clip rect saved to render-loop locals
      (nesting-safe) and intersected for `clip-path="url(#id)"` nodes.
- [ ] **Stage 2b**: clipPath (geometry stencil).
- [ ] **Stage 2c**: mask.
- [ ] **Stage 3a**: TTF parser + glyph outline → polygon.
- [x] **Stage 3b/3c**: hmtx-driven advance + text-anchor + tspan positioning.
      `text_layout.ghl` wired into `render_dispatch` (replaces the legacy
      `shapes.ghl:svg_draw_text`). Bitmap-font metrics until 3a lands.
- [x] **Stage 3d**: textPath along arbitrary path.
- [ ] **Stage 3e**: kern table application.

### Compiler prerequisite (landed)

The svg2 advanced modules need functions with >6 parameters (`flatten_cubic`,
`flatten_arc`, `pp_emit_arc`) and wide local-variable frames. `gritc.py` was
extended accordingly:

- Params 7+ are passed on the stack per System V - caller pushes them
  right-to-left, callee reads them at `[rbp+16]`, `[rbp+24]`, ... Recursion-safe
  because stack args live in the caller frame.
- Per-function frame sizing: the prologue's `sub rsp` is sized from a
  `let`-count pre-pass instead of a fixed 512-byte cap, so wide functions
  compile while recursive functions keep small frames.

Each stage compiles and boots on its own. Never check in a stage that
doesn't pass `scripts/build/build_uefi.ps1` and `scripts/test/test_verify_all.ps1`.

---

## Open questions for future work

1. **Mask/filter under animation?** Current code re-renders the whole SVG on
   every `svg_render()` call, so dynamic filters are free. If we ever add
   incremental rendering, filter caching becomes load-bearing.
2. **Per-process scratch arena**: today carved from APP_SLOT. If SVG
   rendering moves into the kernel (for performance), allocate from
   GUI_LLC_ARENA instead.
3. **Glyph cache.** Re-rasterizing common ASCII glyphs every paint is
   wasteful. A 96-entry × 16×16-pixel ARGB cache (24 KiB) would cover the
   printable range. Defer until profiling proves it matters.
