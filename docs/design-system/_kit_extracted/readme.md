# Grit — Design System

A modern UI design system for **Grit**, a security-minded hobbyist x86-64
operating system with a UEFI graphical desktop. This is a ground-up redesign
of the desktop shell — replacing the kernel-framebuffer "Windows 7 × Linux"
look with a fast, clean, dark-first interface: glass window chrome, a
floating dock, soft layered shadows, gentle rounding, and a single **muted
gold** accent. The look is macOS-smooth and quietly premium — calm depth,
real motion, no neon.

> **Source repository** — everything here is grounded in
> **`grit` / GritHL**: <https://github.com/StruckGuide8154/grit>
> Useful paths: `assets/themes/{dark,light}/theme.xml` (the original color
> intent), `src/user/grithl/lib/*.ghl` (the v1 GUI library + kernel libs),
> `README.md` / `TODO.MD` (product context). Explore the repo to recreate
> screens with higher fidelity.

---

## What Grit is

Grit is a from-scratch x86-64 operating system: a zero-assembly **GritHL**
kernel with signed/verified modules, a UEFI GOP graphical desktop, and
built-in apps (Files, Terminal, Settings, a system monitor). The product
personality is **technical, precise, and quietly confident** — "built on
grit." The redesign keeps that engineering soul but makes it feel fast,
smooth and contemporary.

The current (pre-redesign) UI is rendered directly by the kernel into the
framebuffer, which is why it reads as dated. This system defines the
**target** look: what the desktop *should* become, expressed as real,
reusable web components so designs can be prototyped quickly.

### GritHL GUI v2 (`gui2`)

This system ships a real, redesigned GUI library written in GritHL —
**`gui2/`** — a retained-mode, batched replacement for the immediate-mode
`lib/gui.ghl`. It is the engine the redesign is meant to render on:

- **Batched draw lists** (`batch.ghl`) — record primitives into user memory,
  cross the kernel ring **once** per frame (`SYS_GUI_BATCH`) instead of one
  syscall per primitive.
- **Retained tree + content hashing** (`retained.ghl`) — re-stamp content;
  unchanged widgets emit nothing.
- **Dirty-rect + async present** (`damage.ghl`) — repaint only the union of
  changed rects, cooperating with the compositor's vblank flip.
- **Measured/cached layout** (`layout.ghl`) — measure once; arrange skips
  clean subtrees on an epoch check.
- **Glyph atlas** (`atlas.ghl`) — rasterize each glyph once, blit cached cells.

A still frame crosses the ring **once** and draws **zero** primitives.
`gui2/README.md` has the full rationale and a worked app port
(`gui2/apps/monitor2.ghl`). The showcases in `showcase/` are HTML renderings
of what `gui2` produces.

---

## Content fundamentals

How Grit writes copy:

- **Voice:** terse, technical, lowercase-friendly. It reads like a competent
  CLI, not a consumer app. Prefer **system nouns and verbs**: "module
  verified", "secure-boot OK", "desktop-shell running".
- **Casing:** Product/app names are Title Case (*System Monitor*, *Files*).
  Micro-labels in chrome are **UPPERCASE, wide-tracked** (`SYSTEM STATUS`,
  `PLACES`). Body and menus are sentence case.
- **Person:** Mostly impersonal/system-voiced ("Connected", "4.9 / 8.0 GB").
  When addressing the user, use **you** sparingly and plainly ("Use the dark
  surface ramp system-wide.").
- **Numbers & telemetry:** shown in **monospace**: versions (`0.5.0`), sizes
  (`186 MB`), temps (`52 °C`), hashes (`0x9F2A…E1`).
- **No emoji.** Status is communicated with color + dot badges and icons,
  never emoji. No exclamation-heavy marketing tone.
- **Vibe:** confident, secure, fast. Think "developer tools meet a clean OS"
  — never playful, never cluttered.

Examples:
- Button: `Launch`, `New`, `Delete` (imperative, one word where possible).
- Status: `Running` · `Degraded` · `Halted` (single-word state).
- Terminal: `grit@grit:~$ modprobe grithl --secure`.

---

## Visual foundations

**Color.** Dark-first, soft **cool-neutral** near-blacks (`--grit-void
#0E1013` → `--grit-surface-4 #30343D`, never pure OLED black so the
3D-depth wallpapers read) under a single brand accent: **muted gold**,
`#C9A26A` (hover `#DCBA84`, press `#A8854F`). The accent is used **sparingly**
— primary action, focus, active dock item, selection. Semantic status is a
muted green/amber/red with matching 14% soft fills. The accent is a **theme
pack**: the default is gold; `[data-accent="copper" | "sage" | "slate"]`
re-points the whole system at runtime (for a future Settings → Appearance).
A `[data-theme="light"]` scope mirrors everything for the light theme.

**Type.** **Hanken Grotesk** for UI, **Geist Mono** for code/telemetry. (See
font caveat below.) Headings are tight-tracked and semibold/bold; body is
14px; the signature flourish is the **wide-tracked (0.18em) uppercase 11px
micro-label** used across chrome (`.grit-label`).

**Backgrounds.** Clean **3D-depth** wallpapers (`assets/wallpapers.css`),
pure-CSS and GPU-cheap: *Depth* (the signature soft volumetric top-light on a
gently curved surface), *Dune* (warmer layered ridges), *Studio* (single
overhead spotlight), *Mono* (near-flat, content-first). All are layered
radial gradients — no filters, no images, crisp at any resolution. The kernel
ships animated variants through the **`.gdx` delta-field format** (see
`showcase/delta-format.html`): a prerendered depth field where only changed
tiles are stored/sent, losslessly — a still desktop costs ≈0 bytes/frame.

**Elevation & corners.** Soft, **layered** shadows tuned for dark
(`--shadow-sm/md/lg/window`), plus an inner top **lit edge** (`--edge-light`).
Gentle rounding: controls 7px, cards/panels 13px, **windows 16px**, dock 22px,
pills full.

**Glass & blur.** Window titlebars, the dock and menus use **backdrop blur**
(`--blur-glass`) over a translucent tint — the only place transparency is
used. Content surfaces stay opaque for legibility.

**Motion.** Quick and physical, macOS-smooth. Hovers/toggles 150ms;
window/panel motion ~240ms; gentle ease-out by default. The brand moment is
the **Apple-style boot reveal** (`showcase/boot.html`): a 3D gold *Grit*
wordmark racks from blurred into sharp, then deblurs into the desktop. No
infinite decorative loops; respect reduced-motion in production.

**States.**
- *Hover:* surfaces lighten one step on the ramp / show accent tint; dock
  tiles **lift ~7px and scale 1.06**.
- *Press:* controls **scale down** (~0.92–0.98); no color flash needed.
- *Focus:* a quiet accent **focus ring** (`--focus-ring`) — no glow spam.
- *Selected/active:* accent soft-fill + accent edge.

**Imagery vibe.** Calm, warm-neutral, dark. Real depth and soft light over
gradient banding; premium and restrained rather than flashy.

---

## Iconography

- **Primary icon set: [Lucide](https://lucide.dev)** — clean 2px-stroke,
  rounded line icons that match the redesign's geometry. The original repo
  ships no icon font, so Lucide is the chosen system set (loaded from CDN:
  `https://unpkg.com/lucide@latest`). Render with `<i data-lucide="name">`
  then `lucide.createIcons()`. Stroke icons sit at ~16–18px in controls.
- **No emoji, ever** — status uses colored dot `Badge`s and Lucide glyphs.
- **Brand mark:** `assets/logo-grit-mark.svg` (a gold chip with a knocked-out
  *G*) and `assets/logo-grit-lockup.svg` (mark + `Grit` wordmark + `GRITHL ·
  x86-64` tagline). Both use the gold gradient.

> If you need a fully self-contained build, swap the Lucide CDN link for a
> vendored copy of the icons you use.

---

## ⚠ Caveats & substitutions

- **Fonts are substitutes.** The grit repo ships **no font binaries** (the
  kernel uses a built-in bitmap font). **Hanken Grotesk / Geist Mono** were
  chosen as the closest modern match and are loaded from Google Fonts.
  **Please supply the intended UI/mono fonts if different** and I'll swap them.
- **Icons are Lucide** (CDN), chosen as the closest match since the repo has
  no icon assets. Happy to switch sets.
- The redesign is an **interpretation** of the brand direction, not a 1:1
  copy of the current framebuffer UI (which is the thing being replaced).

---

## Index — what's in here

**Foundations**
- `styles.css` — the single entry point consumers link (`@import` manifest).
- `tokens/colors.css` · `typography.css` · `spacing.css` · `fonts.css`
- `assets/wallpapers.css` — the four 3D-depth CSS wallpapers.
- `assets/logo-grit-mark.svg` · `logo-grit-lockup.svg`

**GritHL GUI v2** (`gui2/`)
- `batch.ghl` · `damage.ghl` · `atlas.ghl` · `layout.ghl` · `retained.ghl`
  · `gui2.ghl` (public API) · `apps/monitor2.ghl` (worked port) · `README.md`

**Components** (`window.NexusOSDesignSystem_497743` — the compiler namespace)
- Buttons — `Button`, `IconButton`
- Forms — `Input`, `Switch`, `Checkbox`, `Slider`
- Data — `Card`, `Badge`, `Avatar`, `ProgressBar`
- Navigation — `Tabs`
- OS chrome — `Window`, `Dock`, `Menu`

**Showcases** (`showcase/`)
- `grit-os.html` — the flagship: a Grit desktop rendered by the `gui2`
  retained engine, with a live performance HUD and runtime accent switching.
- `boot.html` — the Apple-style 3D gold *Grit* boot reveal → desktop.
- `delta-format.html` — the `.gdx` delta-encoded depth-wallpaper format.

**UI kits**
- `ui_kits/desktop/` — the redesigned, interactive **Grit Desktop**:
  top menu bar, draggable windows, floating dock, and four built-in apps
  (Files, Terminal, System Settings, System Monitor).

**Specimen cards** populate the Design System tab (Colors, Type, Spacing,
Brand, Components, Desktop). Each component directory also has a
`<Name>.prompt.md` with a usage snippet.
