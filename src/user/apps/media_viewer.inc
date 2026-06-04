; ============================================================================
; NexusOS Media Player — kernel-side renderer & timeline driver.
;
; This file lives inside the user app blob (apps.asm) but its main entry
; point `app_media_draw` is registered as a window draw fn, which means
; the window manager invokes it in kernel context. That is what lets us
; read `bb_addr`, `scr_pitch`, `scr_height`, and `tick_count` directly —
; those symbols would not be reachable from a Ring-3 slot copy.
;
; Surface area, kept small and documented
; ---------------------------------------
;   Pixel I/O   : direct writes to `[bb_addr + y*pitch + x*4]` (UEFI GOP
;                 framebuffer, BGRA). No iGPU acceleration, no SIMD —
;                 plain scalar code that is portable across every machine
;                 NexusOS boots on. See docs/media-formats.md → "Scope".
;   Timing      : the global 100 Hz PIT `tick_count`. Per-window state
;                 stored slot-local (see media.nxh `state { ... }`) so
;                 two players can coexist.
;   Scaling     : nearest-neighbor with a 16.16 fixed-point step, aspect
;                 preserved, letterboxed inside the client area. Shared
;                 by every BGRA-source codec via `nx_media_blit_scaled`.
;   Codecs      : one cmp/je ladder in `app_media_draw`. Adding a codec
;                 = new magic + new blitter that ultimately tail-calls
;                 `nx_media_blit_scaled` (or draws directly, for vector
;                 codecs like SVG).
;
; File map
; --------
;   §1  Magic & layout constants
;   §2  Codec dispatch                       (app_media_draw)
;   §3  Generic helpers                      (fill_rect, scaler, fit)
;   §4  Image codecs                         (NIC, BMP)
;   §5  Video codecs                         (NBA + timeline advance)
;   §6  Vector codecs                        (SVG subset, XML text)
;   §7  Control bar UI                       (play / ±10s / scrubber)
;   §8  Future-work notes
;
; Adding a codec — checklist
; --------------------------
;   1. Pick a 32-bit magic and constant in §1.
;   2. Add one `cmp eax, <MAGIC>` row in §2.
;   3. Implement `nx_media_blit_<fmt>(rdi=file, rsi=window)` in §4–§6.
;   4. (Optional) Extend media.nxh `media_probe` so user-mode tools can
;      recognise it for thumbnails / property dialogs.
;   5. Update docs/media-formats.md.
; ============================================================================

; Implementation is split by dependency order. These includes are kept
; explicit so the renderer still assembles as one contiguous app blob.
%include "src/user/apps/media_viewer_core.inc"
%include "src/user/apps/media_viewer_scaler.inc"
%include "src/user/apps/media_viewer_images.inc"
%include "src/user/apps/media_viewer_video.inc"
%include "src/user/apps/media_viewer_vector.inc"
%include "src/user/apps/media_viewer_controls.inc"
