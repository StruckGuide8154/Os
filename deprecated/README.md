# Deprecated Subsystems

This folder preserves source code, documentation, firmware, and research notes
for GritOS subsystems that have been retired from the active build.

The goals are:

1. **Don't lose work.** Drivers and notes here represent real research effort.
   Future contributors should be able to read them and understand what was
   tried, what worked, and what didn't.
2. **Don't accidentally re-enable them.** Nothing in this folder is referenced
   by `src/kernel/kernel_build.asm`, the build scripts, or any active include
   path.
3. **Document the why.** Each deprecation entry must state why it was retired
   and what (if anything) replaced it.

---

## Structure (required)

Every deprecation lives in its own subfolder, named after the hardware,
subsystem, or feature being retired. Use SCREAMING_SNAKE_CASE for hardware
codenames (e.g. `780M_IGPU`), lowercase-with-underscores for software
features (e.g. `legacy_aml_parser`).

A deprecation folder MUST contain:

```
deprecated/<name>/
├── README.md           # mandatory - see template below
├── code/               # source files exactly as they were (preserve subtree shape)
├── docs/               # design notes, status docs, resume notes
├── memory/             # any auto-memory entries from .claude/projects/...
└── (optional) firmware/, tools/, assets/  # supporting artifacts
```

Preserve the original directory shape inside `code/` so future readers can
see where each file *used* to live. Example:

```
deprecated/780M_IGPU/code/
├── drivers/amd_dcn.asm                 (was src/kernel/drivers/amd_dcn.asm)
├── drivers/gpu/amd_gfx.asm             (was src/kernel/drivers/gpu/amd_gfx.asm)
└── include/amdgpu_regs.inc             (was src/include/amdgpu_regs.inc)
```

---

## README.md template

Each `deprecated/<name>/README.md` must include these sections, in order:

```markdown
# <Subsystem name>

## What this was
One paragraph: what hardware/feature this targeted and what problem it solved.

## Status when retired
- Date retired: YYYY-MM-DD
- Last working state: e.g. "Phase 1 probe + UC mapping landed; DMUB mailbox
  brought up to read-only diag; firmware load not attempted."
- Was it ever shipped in a working build? yes/no

## Why retired
Plain reason. Examples: "Too platform-specific - only worked on AMD Phoenix
780M and we are switching to widely compatible interfaces only."
"Replaced by <new subsystem>." "Vendor stopped supporting the API."

## What replaced it (if anything)
Pointer to the active subsystem, or "(nothing - feature dropped)".

## Files preserved
Bullet list mapping new paths to original paths. Same info as the directory
listing, but explicit so a search for the old path lands here.

## Notes for future revisitors
What hurt the most, what to avoid, what worked. Honest postmortem.
```

---

## How to deprecate something

1. Create `deprecated/<name>/` with the structure above.
2. **Move, don't copy.** Use `git mv` for tracked files so history follows.
   For untracked files, plain filesystem move is fine.
3. Remove all `%include` lines, build-script switches, and `extern` references
   that pull the deprecated code into the active build.
4. Move any related memory files out of the active `memory/` folder into
   `deprecated/<name>/memory/`. Update the active `MEMORY.md` index.
5. Write the README.md from the template above. Be honest in the "why" and
   "notes" sections - future-you will thank present-you.
6. Build once with no flags. The default build must succeed without any of
   the deprecated symbols.
7. Commit as a single change with message `deprecate: <name>`.

---

## Current deprecations

- [`780M_IGPU/`](780M_IGPU/) - AMD Phoenix 780M iGPU bring-up
  (DCN 3.5 / DMUB / GFX11 / IMU / PSP). Retired 2026-05-26.
