; DEPRECATED: raw assembly Settings implementation.
;
; The active Settings app is now:
;   src/user/grithl/apps/settings.ghl
;
; Launch wiring must use the generated callbacks:
;   app_hl_settings_draw
;   app_hl_settings_click
;   app_hl_settings_key
;
; This file intentionally exports no app_settings_* labels. If this include is
; reintroduced into the app blob, launch-time symbol resolution should fail
; instead of silently falling back to kernel-global state.
