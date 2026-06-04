; ============================================================================
; NexusOS v3.0 - Usermode Transition
; Clean L3 callback path for app draw/click/key handlers.
; ============================================================================
bits 64


; Public surface and dependency order:
; 1. usermode_decls.inc: includes, externs, constants, and exported state labels.
; 2. usermode_entry.inc: app blob init, ring-3 entry, runtime/stack helpers.
; 3. usermode_paging.inc: syscall stack PT install, slot isolation, W^X policy.
; 4. usermode_integrity.inc: code-range hash install and verification.
; 5. usermode_slot_state.inc: app trampoline, code slide, and slot key state.
; 6. usermode_slot_install.inc: app blob copy/install and per-slot setup.
; 7. usermode_translate.inc: kernel/blob/slot target pointer translation.
; 8. usermode_callbacks.inc: packed callback thunk, ring-3 callback path, test blob.
; 9. usermode_storage.inc: data/BSS storage owned by this subsystem.
%include "src/kernel/proc/usermode_decls.inc"
%include "src/kernel/proc/usermode_entry.inc"
%include "src/kernel/proc/usermode_paging.inc"
%include "src/kernel/proc/usermode_integrity.inc"
%include "src/kernel/proc/usermode_slot_state.inc"
%include "src/kernel/proc/usermode_slot_install.inc"
%include "src/kernel/proc/usermode_translate.inc"
%include "src/kernel/proc/usermode_callbacks.inc"
%include "src/kernel/proc/usermode_storage.inc"
