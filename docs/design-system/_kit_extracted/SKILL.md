---
name: grit-design
description: Use this skill to generate well-branded interfaces and assets for Grit (the GritHL OS desktop), either for production or throwaway prototypes/mocks/etc. Contains essential design guidelines, colors, type, fonts, assets, the gui2 GritHL library, and UI kit components for prototyping.
user-invocable: true
---

Read the README.md file within this skill, and explore the other available files.
If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out and create static HTML files for the user to view. If working on production code, you can copy assets and read the rules here to become an expert in designing with this brand.
If the user invokes this skill without any other guidance, ask them what they want to build or design, ask some questions, and act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

Quick orientation:
- `styles.css` is the single CSS entry point — link it and you get all tokens, fonts and wallpapers.
- Tokens live in `tokens/` (colors, typography, spacing/shadow/motion). Consume the **semantic aliases** (`--surface-window`, `--text-heading`, `--accent`, …), not raw ramps, where possible.
- Accent is a **muted gold** by default and is swappable: set `data-accent="copper" | "sage" | "slate"` on a root element to re-theme the whole system. No neon.
- Components are React (`components/<group>/<Name>.jsx`), exposed at `window.NexusOSDesignSystem_497743` (the compiler-assigned namespace). See each `<Name>.prompt.md` for usage.
- The GritHL **GUI v2 library** is in `gui2/` (real `.ghl` source: batched draw lists, retained tree, dirty-rect present, cached layout, glyph atlas). `gui2/README.md` explains it; `showcase/` has HTML renderings of what it produces.
- The full redesigned desktop lives in `ui_kits/desktop/` and `showcase/grit-os.html` — good references for composing the shell (Window + Dock + Menu + apps).
- Wallpapers: add class `grit-wall grit-wall-depth` (or `-dune` / `-studio` / `-mono`) to a full-bleed element.
- Dark-first; add `data-theme="light"` on a root element for the light theme.
- Icons: Lucide via CDN (`<i data-lucide="name">` + `lucide.createIcons()`). No emoji.
