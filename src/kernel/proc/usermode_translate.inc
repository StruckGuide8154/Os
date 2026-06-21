; ============================================================================
; usermode_translate.inc - MIGRATED TO ZERO-ASM GritHLK.
;
; l3_slot_resolve_app_ptr and l3_translate_target (kernel/blob/slot callback
; target pointer translation, including the fail-closed sentinel-0 path that is
; the KASLR background-click freeze fix) were ported, byte-faithfully and with
; zero assembly, to:
;
;     src/kernel/grithlk/usermode_translate.ghl
;       -> build/ghl/usermode_translate.asm  (%include'd by kernel_build.asm)
;
; This file no longer defines those symbols - keeping the %include in
; usermode.asm a harmless no-op and avoiding a duplicate-symbol clash with the
; generated GritHLK module. See the directive in MEMORY
; (feedback_no_asm_shims_full_zero_asm): GritHLK must be FULLY zero-asm, even
; privilege-critical ring-3 transition code.
;
; The call_app_l3_packed thunk documented at the foot of the old file lives in
; the GritHLK callback module (usermode_callbacks.ghl), not here.
; ============================================================================
