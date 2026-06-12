; ============================================================================
; usermode_callbacks.inc - MIGRATED TO ZERO-ASM GritHLK.
;
; The packed callback thunk (call_app_l3_packed), the ring-3 callback entry
; (call_app_l3), the kernel-resume path (call_app_l3_return), the kernel-resident
; ring-3 app-done trampoline (call_app_l3_app_done), the L3 self-test proc
; (test_usermode_proc) and the L3 test blob were ported, byte-faithfully and with
; zero assembly, to:
;
;     src/kernel/grithlk/usermode_callbacks.ghl
;       -> build/ghl/usermode_callbacks.asm  (%include'd by kernel_build.asm)
;
; This file no longer defines those live-path symbols - keeping the %include in
; usermode.asm a harmless no-op and avoiding a duplicate-symbol clash with the
; generated GritHLK module. See the directive in MEMORY
; (feedback_no_asm_shims_full_zero_asm): GritHLK must be FULLY zero-asm, even
; boot-/privilege-critical code.
;
; RETAINED (scoped out of the callback/trampoline port): the L3 demo test blob
; below. It is a dev-only fixture COPIED byte-for-byte into a slot by
; l3_prepare_test_callback (usermode_entry.inc, itself still asm and out of this
; task's scope), which depends on the l3_test_blob / l3_test_blob_end label pair
; and the raw blob layout. It is NOT part of the live ring-3 callback/app-done
; path that was ported. Like the ported call_app_l3_app_done, its syscall number
; is RAW (slot-0 identity): the blob runs in ring 3 at a kernel VA outside the
; per-slot copied app blob, so its immediate is never rewritten by the loader.
; ============================================================================

; --- Dummy usermode code for testing ---
l3_test_blob:
    lea rdi, [rel .msg]
    ; RAW syscall number (NOT APP_SYSNO): dummy kernel-resident test blob, not
    ; part of the per-slot copied app blob, so its immediate must stay raw
    ; (slot-0 identity path). See call_app_l3_app_done in the GritHLK module.
    mov eax, 0                           ; SYS_PRINT
    syscall
    ret
.msg:
    db "L3 test callback ok", 0
l3_test_blob_end:
