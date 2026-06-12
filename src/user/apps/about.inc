; DEPRECATED: raw assembly About implementation.
;
; The active About app is now:
;   src/user/grithl/apps/about.ghl
;
; Launch wiring must use the generated callbacks:
;   app_hl_about_draw
;   app_hl_about_click
;   app_hl_about_key
;
; This file intentionally exports no app_about_* labels. If this include is
; reintroduced into the app blob, launch-time symbol resolution should fail
; instead of silently falling back to kernel-global state.
