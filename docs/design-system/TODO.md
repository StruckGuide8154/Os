# Grit Design System → OS — Full Implementation TODO

> Source kit: [`Grit-Design-System.zip`](./Grit-Design-System.zip) (in this dir).
> Extract to inspect `tokens/`, `components/`, `gui2/`, `guidelines/`, `showcase/`.
> Goal (verbatim from the user): implement the Design System **1:1** — exact
> Hanken Grotesk font, non-jagged (anti-aliased) edges/corners, real blurs and
> layered shadows — and make it render **faster** than the current UI.

Locked decisions:
- **Font:** bake the real Hanken Grotesk TTF into an anti-aliased glyph atlas in
  the kernel (the kit ships no font binary; substitutes are flagged).
- **Theme:** dark-first muted-gold is the **default** boot look; light is opt-in.
  Both palettes come from the kit's `tokens/colors.css`.
- **Sequencing:** land incrementally, each stage building green.
- **Verification:** user verifies chrome interactively (real mouse / GUI run);
  CI / build-green + compile checks gate each landing.

---

## Status at a glance

| Stage | Scope | State |
|------|-------|-------|
| 1 | Palette + tokens flip (dark + gold default) | ✅ DONE, UEFI build green, dark bg visually confirmed |
| 2 | AA rounded corners + soft drop shadows + chrome rewrite | ✅ DONE, build green, drag trail-fix landed (interactive visual pending user) |
| 3 | Glass blur on titlebar / dock / menus | ⬜ TODO |
| 4 | Hanken Grotesk AA font atlas (exact font) | ⬜ TODO |
| 5 | gui2 reconcile + DS motion | ⬜ TODO |
| — | Per-component 1:1 pass (buttons, inputs, switches, tabs, cards…) | ⬜ TODO |
| — | Cleanup / follow-ups (shadow cache, BIOS size cap, etc.) | ⬜ TODO |

Plan file (machine): `~/.claude/plans/frolicking-napping-mist.md`.
Memory note: `design_system_impl.md`.

---

## Design tokens — single source of truth (from the kit)

### Colors — DARK (`:root`, the default)
| Token | Hex | Use |
|-------|-----|-----|
| void | `#0E1013` | desktop backdrop (not pure black) |
| bg | `#131519` | app canvas |
| surface-1 | `#181A1F` | window body |
| surface-2 | `#1E2127` | panels, sidebars |
| surface-3 | `#262A31` | inputs, raised, hover |
| surface-4 | `#30343D` | active / pressed |
| border-1 | `#24272E` | hairline divider |
| border-2 | `#31353E` | control border |
| border-3 | `#424753` | strong / focus-adjacent |
| text-1 | `#ECEDEF` | primary / headings |
| text-2 | `#A8ACB4` | body / secondary |
| text-3 | `#71757E` | muted / captions |
| text-4 | `#4D515B` | faint / disabled |
| text-invert | `#17150F` | warm near-black on gold |
| **gold-base** | `#C9A26A` | **accent (default)** |
| gold-bright | `#DCBA84` | hover lift |
| gold-deep | `#A8854F` | pressed |
| success | `#6FB894` | |
| warning | `#D6A444` | |
| error | `#CF6F66` | |
| info / slate | `#7C879B` | |

Accent theme packs (swap via `[data-accent]`): copper `#C17A57`, sage `#79A98C`,
slate `#7C879B`. **TODO:** expose accent-pack switching in Settings.

### Colors — LIGHT (`[data-theme="light"]`, opt-in)
void `#E7E4DD`, bg `#F4F2EC`, surface-1 `#FBFAF6`, surface-2 `#F0EEE7`,
surface-3 `#E7E4DB`, border-1 `#E0DCD1`, border-2 `#CDC8BA`, text-1 `#1B1A16`,
text-2 `#45433C`, gold `#9A7637`/bright `#B08C4C`/deep `#7E5F28`,
success `#3F9B72`, warning `#B8822A`, error `#BC4F46`.

### Typography
- UI: **Hanken Grotesk** (`300/400/500/600/700/800`). Mono: **Geist Mono**.
- Scale (px): micro 11, xs 12, sm 13, base 14, md 15, lg 17, xl 20, 2xl 26,
  3xl 34, display 48.
- Line heights: tight 1.15, snug 1.3, normal 1.5, relaxed 1.65.
- Letter spacing: tight −0.02em, wide 0.04em, **label 0.18em** (tracked
  uppercase micro-label — signature chrome detail).
- Roles: window-title 600/17, app-header 600/26, section 600/20,
  control 500/13, body 400/14, code 400/13 mono.

### Spacing / radii / sizing
- Spacing (4px grid): 0,2,4,6,8,12,16,20,24,32,40,48,64,80.
- Radii: xs 5, sm 7, md 9, lg 13, **xl 16 (windows)**, 2xl 22 (dock), pill 999.
- Control heights: sm 28, md 34, lg 42. Titlebar 40. Dock 64.

### Elevation / glass / motion
- Shadows: xs/sm/md/lg + `--shadow-window: 0 28px 70px -14px rgba(0,0,0,.62), 0 8px 22px rgba(0,0,0,.42)`.
- `--edge-light: inset 0 1px 0 rgba(255,255,255,.05)` (lit top rim).
- Glass: `--blur-glass: blur(22px) saturate(130%)`, `--blur-thin: blur(12px)`,
  tints `rgba(22,24,29,.66)` / `rgba(28,31,37,.74)`.
- Motion: durations 90/150/240/400ms; ease-out `cubic-bezier(.22,.8,.3,1)`,
  ease-in-out `(.65,0,.35,1)`, spring `(.34,1.56,.64,1)`.

These are mirrored in `src/include/constants.inc` as `DS_R_*`, `DS_CTL_H_*`,
`DS_TITLEBAR_H`, `DS_DOCK_H`, `DS_BLUR_GLASS/THIN`, `DS_GLASS_TINT[_2]`,
`DS_EDGE_LIGHT`, `DS_SHADOW_WIN_*`/`DS_SHADOW_MD_*`, `DS_DUR_*`, `DS_EASE_*`.

---

## Stage 1 — Palette + tokens flip ✅ DONE

Whole-OS warm-light and dark-gold packs now live only in
`assets/themes/theme-spec.json`. `tools/theme_tool.py` validates contrast and
deterministically emits kernel constants, GritHL seed tables, and NPL1
resources. The source guard rejects stale output, and raw RGB values are never
guessed to be semantic theme roles.

Done sub-items: ✅ dark default ✅ light pack ✅ kernel COLOR_* ✅ 3-way sync
✅ DS geometry/elevation/motion token constants.

TODO leftovers under Stage 1 umbrella:
- [ ] A future runtime switch must publish one kernel-owned atomic palette
      generation and invalidate every app; per-process switching is forbidden.
- [ ] Accent packs should extend the canonical spec and use the same global
      generation contract.

---

## Stage 2 — AA rounded corners + soft shadows ✅ DONE (visual pending)

New zero-asm GHL primitives in `src/kernel/grithlk/render.ghl`:
- `render_round_rect(x,y,w,h,r,color)` — AA rounded fill; interior is solid
  `fill_rect` spans, corners are 4×4-supersampled coverage via `blend_pixel`.
- `render_round_rect_top(...)` — rounds only the top two corners (titlebars).
- `render_drop_shadow(x,y,w,h,r)` — soft shadow via rounded-rect SDF + octagonal
  length approx + linear alpha falloff; fringe-only (skips window-covered px).
- `render_hline_blend(x,y,w,argb)` — alpha hairline for the lit top edge.
- Helpers: `rr_corner`, `rr_clamp_radius`, `rr_abs`.

Chrome rewrite in `src/kernel/gui/window_draw.inc`: shadow → 16px AA rounded
body → rounded-top titlebar → lit top edge → gold focus accent line →
AA-rounded close/min buttons. VGA bevel deleted.

Trail fix in `src/kernel/grithlk/wm_helpers.ghl`: `wm_handle_title_drag` now
calls `render_mark_full()` so a dragged window's old shadow is cleared each
frame (no smears).

TODO leftovers under Stage 2:
- [ ] **Interactive visual sign-off** by user (rounded corners, soft shadow,
      gold focus line, clean drag).
- [ ] **Shadow cache** (perf): stamp the rounded-shadow into a size-keyed
      scratch buffer and blit at offset instead of recomputing the SDF each
      frame. Only needed if drag feels heavy.
- [ ] Apply AA rounded fills + shadows to **menus** (radius 9) and **dropdowns**
      and any kernel-drawn popovers (`render_round_rect`, `--shadow-pop`).
- [ ] 1px AA hairline **border** option on the window body (`border-1`) if the
      shadow alone reads too soft on light theme.
- [ ] Titlebar height: kit says 40px; OS keeps `TITLEBAR_HEIGHT=24` to avoid
      shifting every app's client origin. Decide whether to raise it (touches
      `ui_*` client offsets app-wide).

---

## Shell chrome — flat-primitive restyle REVERTED (deprecated 2026-06-23)

A draw-only gshell restyle (gold accent headers, surface-2 sidebar, brand band,
dock-style taskbar) was prototyped then reverted at user request — flat-primitive
approximations are the wrong direction. The real-time **retained CPU
tile-compositor + AA font atlas** is the path; until the ring-3 draw ABI exposes
rounded/blended/AA-text/icon primitives, the shell stays as-is.
Preserved for future work: `deprecated-shell-restyle/` (gshell.restyle.ghl +
NOTES.md). `gshell.ghl` is restored to its known-working bare Start/Desktop list.

## Stage 3 — Glass blur on chrome ⬜ TODO

The only place transparency is used: titlebars, the dock, menus.
- [ ] `backdrop_blur_region(x,y,w,h,radius,tint)` in the render layer: copy the
      back-buffer rect → separable box blur → composite `--glass-tint` →
      clip to the rounded silhouette (Stage 2). **Reuse** the existing O(1)
      3-pass box blur `box_blur_axis` / `blur_build_kernel` in
      `src/user/grithl/lib/svg2/filter_blur.ghl` (port/share into the kernel
      render path).
- [ ] Map radius from `--blur-glass` (22px) and `--blur-thin` (12px).
- [ ] Apply to: focused titlebar band, the dock surface, dropdown menus.
- [ ] **Perf guardrails (must stay faster than current):**
  - [ ] Blur only the **damaged sub-rect** (gui2 `damage.ghl`).
  - [ ] Reuse the WC-mapped framebuffer (FBPERF WC already landed).
  - [ ] **Cache** static-region blur between frames — idle desktop must do
        **zero** blur recompute (cache-hit path).
- [ ] Saturate(130%) approximation (optional; box blur alone is acceptable v1).

---

## Stage 4 — Hanken Grotesk AA font atlas ⬜ TODO (the exact-font requirement)

Today the kernel uses an 8×16 aliased bitmap (`src/kernel/grithlk/font.ghl`).
- [ ] Vendor the OFL **Hanken Grotesk** TTF (+ license) under `assets/fonts/`.
      Also **Geist Mono** for terminal/telemetry.
- [ ] Build-time tool `tools/fonts/bake_font_atlas.py`: rasterize weights
      400/500/600/700 at the DS sizes (11–20 core + 26/34/48 display) into 8-bit
      grayscale coverage atlases; emit a kernel `data` table + per-glyph metrics
      (advance, bearing, uv) as `src/kernel/grithlk/font_atlas.ghl`. Keep it in
      `.data`/embedded like `font.ghl` (real bytes, not `.bss`).
- [ ] Kernel glyph blitter `draw_glyph_aa` / `draw_string_aa`: look up coverage,
      alpha-blend fg over bg per pixel (`blend_pixel`), advance by **real
      proportional metrics** (not fixed 8px).
- [ ] Route all `draw_string` / `render_text` callers through the AA path
      (window titles, widgets). Terminal stays monospaced via the Geist Mono
      atlas.
- [ ] `.grit-label` style: tracked uppercase micro-label (`letter-spacing 0.18em`,
      11px, semibold, `text-muted`) for chrome micro-labels.
- [ ] Carry weight + size through the text syscall path
      (`syscall_support.inc` / gui2 text op).
- [ ] Host unit check: atlas round-trips (glyph count, monotone metrics, dims).
- [ ] Add atlas + new modules to the integrity manifest
      (`docs/per-app-integrity-manifest.md`) and the legacy-asm inventory /
      source-guard lists (`tools/security/legacy_asm_inventory.txt`,
      `scripts/test/test_source_guards.ps1`) — or Track-1 guards fail.

---

## Stage 5 — gui2 reconcile + motion ⬜ TODO

- [ ] Diff the kit `gui2/*.ghl` against `src/user/grithl/lib/gui2*`; port the DS
      deltas (G2_RADIUS 7, gold metrics, atlas hooks) so the retained widget
      vocabulary matches the kit. Port `monitor2.ghl` showcase.
- [ ] Wire DS motion tokens (90/150/240/400ms; ease-out/in-out/spring) into:
  - [ ] window open / close (scale + fade ~240ms ease-out).
  - [ ] hover / toggle (~150ms).
  - [ ] dock item hover / launch bounce (spring).
- [ ] Ride the existing async-flip / pacer so animation adds **no** extra
      syscalls per frame.
- [ ] Port reference screens from the kit `ui_kits/desktop/` + `showcase/`
      (Desktop, dock, Files/Settings chrome) as the visual acceptance target;
      diff against `showcase/grit-os.html`.

---

## Per-component 1:1 pass ⬜ TODO

Map each kit component (`components/**`) to the OS widget and match exactly
(radius, padding, font, states, focus ring, hover/active, disabled).

- [ ] **Button** (`buttons/Button.jsx`): radius sm 7, height md 34, weight 500,
      gold fill / soft / ghost variants; focus = 3px gold ring; press = gold-deep.
- [ ] **IconButton**: square, radius sm, the close/min/window controls.
- [ ] **Input** (`forms/Input.jsx`): surface-3 fill, border-2, radius sm, focus
      ring, placeholder text-3.
- [ ] **Checkbox** / **Switch** / **Slider**: pill track (radius 999), gold
      thumb/fill, 150ms transition.
- [ ] **Tabs** (`navigation/Tabs.jsx`): underline / segmented; active = gold.
- [ ] **Card** (`data/Card.jsx`): surface-1/2, radius lg 13, `--shadow-md`,
      lit edge.
- [ ] **Badge** / **Avatar** / **ProgressBar**: pill, gold/semantic fills.
- [ ] **Menu** (`os/Menu.jsx`): radius md 9, glass + `--shadow-pop`, separators
      = border-1, hover = surface-3.
- [ ] **Dock** (`os/Dock.jsx`): radius 2xl 22, height 64, glass blur,
      hover-magnify (spring), running-dot indicator.
- [ ] **Window** (`os/Window.jsx`): already Stage 2; verify against kit pixel-
      for-pixel (corner 16, shadow, titlebar, traffic-light controls).
- [ ] **Logo / wordmark**: `assets/logo-grit-*.svg` for boot / about / lock.
- [ ] **Wallpapers** (`assets/wallpapers.css`, `.gdx` delta-field animated
      variants) — 3D-depth dark backdrops; ensure they read under the palette.
- [ ] **Icons**: kit uses **Lucide** line icons (repo ships none) — bake a
      Lucide-geometry line-icon atlas (or SVG2 paths) matching the redesign.

---

## Known issues / cross-cutting follow-ups ⬜

- [x] **BIOS size cap:** raised the shared loader reservation from 2 MiB to
      4 MiB (8192 sectors). The UEFI DATA.IMG builder now reads the shared
      assembly constants instead of duplicating `64 + 4096`, preventing the
      FAT partition offset from drifting when the reservation changes.
- [x] **Pre-existing madt break (fixed):** `madt.asm` had wrapped
      `madt_lapic_ids` in `%ifdef GRIT_SMP` but `apic.asm` reads it on every
      build → undefined symbol. Un-wrapped (always allocate).
- [x] **Boot-to-desktop stall:** fixed by the user.
- [ ] **Temp debug traces:** confirm none of the DS-debugging `serdbg`/`SER`
      probes remain (kernel_lifecycle.ghl loop tracers, window_desktop.ghl
      `wds_traced`/`wds_shell_seen`/`GS`/`Gd`). Currently verified removed.
- [ ] **Shadow dirty-rect for live-refresh apps:** taskmgr/ping/media partial
      refresh paths repaint only the window rect; they're stationary so the
      shadow doesn't smear, but if any starts moving on refresh, include the
      shadow margin.
- [ ] **Source guards:** a pre-existing L3-callback assertion throws early in
      `test_source_guards.ps1` (before the theme section); the theme 3-way sync
      anchors all pass. Unrelated to DS, but it blocks a clean full guard run.
- [ ] **Light-theme shadow tuning:** kit ships separate light shadow specs
      (softer, blue-tinted) — apply when light is exercised.

---

## File map (what changed / what to change)

Changed (DS, landed):
- `assets/themes/theme-spec.json` — sole palette authoring source.
- `tools/theme_tool.py` — validator and deterministic compiler.
- `src/user/grithl/lib/theme.ghl` — generated tables + bounded lookup.
- `src/user/grithl/lib/gui.ghl` — explicit semantic handles only.
- `src/include/constants.inc` — generated kernel `COLOR_*` block.
- `scripts/test/test_source_guards.ps1` — exact generated-output check.
- `src/kernel/grithlk/render.ghl` — AA rounded-rect + shadow + hline-blend.
- `src/kernel/gui/window_draw.inc` — DS chrome.
- `src/kernel/grithlk/wm_helpers.ghl` — drag full-redraw (shadow trail fix).
- `src/kernel/arch/madt.asm` — `madt_lapic_ids` always-allocate (build fix).

To change (remaining stages):
- NEW `tools/fonts/bake_font_atlas.py`, `src/kernel/grithlk/font_atlas.ghl`,
  `assets/fonts/` (Stage 4).
- Render layer `backdrop_blur_region` + reuse `lib/svg2/filter_blur.ghl`
  (Stage 3).
- `src/user/grithl/lib/gui2*` reconcile + motion wiring (Stage 5).
- Settings app: theme + accent switch (Stage 1 leftovers).

---

## Verification checklist (per stage)

- [ ] `scripts/build/build_uefi.ps1` green (real target).
- [ ] `scripts/build/build_ghl.ps1` green (all units).
- [ ] `scripts/test/test_source_guards.ps1` (palette 3-way sync, no-asm, caps).
- [ ] QEMU GUI boot (`scripts/run/run_uefi.ps1 -NoPassthrough`), real mouse:
      open + drag a window, open a menu, check the dock — eyeball vs
      `showcase/grit-os.html`.
- [ ] Respect the NO-FREEZE invariant (input stays alive).
- [ ] Perf: FPS overlay — idle desktop does **zero** blur recompute; drag is
      smooth vs the pre-DS baseline.

> Screenshot harness (headless, for color/no-fault checks only — note the main
> loop / desktop fully exercises in the **GUI** run, not headless):
> `run_uefi.ps1 -Headless -NoPassthrough` → wait ~25s → telnet `127.0.0.1:4444`
> send `screendump build/shot.ppm` → convert with PIL (PowerShell `python`).
