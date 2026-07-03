---
name: rendering-pivot
description: "2026-05-25 pivot - leaving DMUB side quest, moving toward GPU-accelerated rendering instead of CPU framebuffer blits."
metadata: 
  node_type: memory
  type: project
  originSessionId: 780f13ff-57d6-48cd-9fde-01cb68641e66
---

# Rendering pivot - 2026-05-25

User goal restated: **iGPU should actually render things**, not "DMCUB
mailbox works." Today everything is CPU writes into the GOP
framebuffer (FBPERF WC landed gave ~10× speedup but is still CPU).

**Why:** DMUB does not draw pixels (see [[dmub-parked]]). The display
block scans out a framebuffer the CPU writes; the GFX block (GC 11.5
on Strix Point) is what people mean by "iGPU rendering" - separate
engine, separate firmware, separate MMIO range.

**How to apply:** When the user asks about performance, rendering,
graphics, or "the GPU," default to GFX/scanout-acceleration framing,
not DMUB. The realistic next milestones (in order) are:

1. **Faster CPU paths first** - SSE2/AVX2 memcpy for FB flips, dirty-
   rect tracking so we don't blit the whole screen every frame, async
   blit on AP cores. Buys 2-5× without new firmware. Low risk.
2. **DCN flip queue** - page-flip via the display controller instead
   of CPU copy. Still display block (not GFX) but removes the CPU
   from the per-frame critical path. Medium scope.
3. **GFX11 bring-up** - only if (1) and (2) aren't enough. Requires
   PSP front-door, GMC/MMHUB page tables, MEC/RLC firmware load, ring
   queues, then hand-written PM4 packets. Multi-month minimum.

The user has not yet picked between (1)/(2)/(3) - ask before scoping
the next work block.

## What CPU rendering currently does
- GOP framebuffer mapped WC via PAT slot 1 (FBPERF phases A-D).
- `display_flip` copies a backbuffer to FB. CPU-bound at ~60fps on
  real hardware (Acer ANV16, Ryzen AI 9 HX, Radeon 890M).
- No dirty-rect, no SIMD memcpy, no AP help.

## Don't repeat
- Do not chase DMUB/DCN firmware unless the task is specifically
  panel power / backlight / hotplug / PSR.
- Do not propose GFX as "the next step" without first asking the user
  if option (1) or (2) is enough.
