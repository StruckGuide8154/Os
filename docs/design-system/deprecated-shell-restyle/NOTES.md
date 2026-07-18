# Deprecated shell restyle (kept for future work)

Reverted 2026-06-23 at user request — the draw-only gshell restyle was deprecated
in favour of the future real-time retained-compositor direction (AA font atlas +
rounded/blended app primitives), not these flat-primitive approximations.

`gshell.restyle.ghl` here is the full restyled shell as it stood when reverted.
The live `src/user/grithl/apps/gshell.ghl` was restored to its pre-restyle,
known-working content (bare Start/Desktop list + plain taskbar).

## What the restyle contained (1.1 + 1.2)
- **1.1** — Start column as a surface-2 sidebar panel; "START"/"DESKTOP" headers
  as gold-accent uppercase labels over an accent underline (kit `.grit-label`
  approximation — bitmap font can't letter-track); taskbar restyled as a
  dock-style surface-2 band with a lit accent top rule + accent-left-edge
  running-app chips. Draw-only; no geometry/click changes.
- **1.2** — top brand band across the shell (menu surface + hairline rule) with
  the "Grit" wordmark in gold + "secure desktop" subtitle (kit top bar). Column
  headers shifted below it via a shared `SH_HDR_Y` offset so click hit-testing
  stayed in sync. Live clock was deferred (no user-space wall-clock selector).

## GHL gotchas learned
- `const A = B + C` is rejected — a `const` must be a numeric literal
  (`SH_HDR_Y` had to be inlined to `42`, not `SH_PAD + SH_BRAND_H`).

## Why it could only get so close (why we stopped)
The ring-3 draw ABI is flat-only (`ui_rect` + 8×16 bitmap `ui_text`). Rounded /
blended / AA-text / icon work is not exposed to apps — those primitives exist in
the kernel (`render_round_rect`, `blend_pixel`, `render_drop_shadow`) but aren't
wired out as CAP_GUI syscalls. The real path forward is the retained CPU
tile-compositor + AA font atlas, not more flat-primitive shell tweaks.
