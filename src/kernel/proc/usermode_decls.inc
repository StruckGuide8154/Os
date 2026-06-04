%include "constants.inc"
%include "macros.inc"
%include "syscall_user.inc"
%include "l3_runtime.inc"
%include "smap.inc"
%include "kpti.inc"

extern ser_print_hex64
; Terminal is now a pure-NexusHL app (src/user/nexushl/apps/terminal.nxh); its
; former app_terminal_* / app_terminal_kernel_* / blob_end symbols no longer
; exist. Its draw/click/key are the generated app_hl_terminal_* symbols.
; NOTE: app_blob_start/app_blob_end symbols still exist in kernel.bin (labels
; left after post-build byte-strip), but their contents are zeros. All kernel
; code now resolves the live blob through the loaded pointer at VBE_INFO+0x20.
extern app_blob_start
extern app_blob_end
extern app_l3_done_trampoline
extern app_syscall_fixups_start
extern app_syscall_fixups_end
extern handle_table_clear
extern kernel_canary
; Nested-kernel monitor (nk_monitor.asm): every page-table write below is
; bracketed by a WP-off window so it keeps working once nk_protect_page_tables
; (Phase 2) maps the page tables read-only.
extern nk_pt_window_begin
extern nk_pt_window_end
; Variables moved to the end of file to avoid segment clobbering in monolithic build.

L3_APP_CODE_OFF      equ 512
L3_SHADOW_WIN_OFF    equ (APP_SLOT_SIZE - 512)
L3_APP_BLOB_COPY_CAP equ L3_SHADOW_WIN_OFF
; Ceiling for actual blob *placement* (base + slide + blob_size). Must stay at
; or below the non-present user-stack guard page so a slid blob never overlaps
; the guard page or the user stack/shadow-window tail above it. The slide range
; and the copy-length clamp both use this, NOT L3_APP_BLOB_COPY_CAP ??? that one
; only marks the shadow-window boundary.
L3_APP_BLOB_PLACE_CAP equ L3_SLOT_USER_STACK_GUARD_OFF
L3_SLOT_META_OFF     equ 0
L3_SLOT_MAGIC_OFF    equ 0
L3_SLOT_TERM_CTX_OFF equ 160
L3_SLOT_USER_STACK_TOP equ (L3_SHADOW_WIN_OFF - 16)
; Per-slot user-stack-top randomization bounds (in-slot offset).
; HIGH = legacy fixed top (just below shadow window, 16B-aligned).
; LOW  = guard-floor invariant: lowest reachable byte (top - L3_USER_STACK_SIZE)
;        must stay >= L3_SLOT_USER_STACK_GUARD_OFF + 0x1000, so the fixed guard
;        PTE at page 0x1FA always sits one page below the live stack. At
;        LOW = 0x1FF000 the lowest byte is exactly 0x1FB000, one page above
;        the guard ??? do not lower LOW without also moving the guard PTE.
L3_SLOT_USTACK_TOP_HIGH equ L3_SLOT_USER_STACK_TOP
L3_SLOT_USTACK_TOP_LOW  equ (L3_SLOT_USER_STACK_GUARD_OFF + 0x1000 + L3_USER_STACK_SIZE)
L3_SLOT_USTACK_TOP_RANGE equ (L3_SLOT_USTACK_TOP_HIGH - L3_SLOT_USTACK_TOP_LOW)
TERM_CTX_X           equ 160
TERM_CTX_Y           equ 168
TERM_CTX_W           equ 176
TERM_CTX_H           equ 184
L3_SLOT_MAGIC        equ 0x30544F4C5358414E
l3_syscall_stacks    equ L3_SYSCALL_STACK_ADDR

%if L3_APP_BLOB_COPY_CAP > L3_SHADOW_WIN_OFF
%error "L3 app blob copy cap must stay below the shadow/window/stack area"
%endif
%if L3_APP_BLOB_PLACE_CAP > L3_SLOT_USER_STACK_GUARD_OFF
%error "L3 app blob placement cap must stay at/below the user-stack guard page"
%endif

section .text

; auto-wrapped (FN_BEGIN emits global): global enter_usermode
; auto-wrapped (FN_BEGIN emits global): global call_app_l3
; auto-wrapped (FN_BEGIN emits global): global call_app_l3_return
; auto-wrapped (FN_BEGIN emits global): global call_app_l3_packed
; auto-wrapped (FN_BEGIN emits global): global l3_prepare_test_callback
; auto-wrapped (FN_BEGIN emits global): global l3_runtime_ptr
; auto-wrapped (FN_BEGIN emits global): global l3_slot_base
; auto-wrapped (FN_BEGIN emits global): global l3_user_stack_top
; auto-wrapped (FN_BEGIN emits global): global l3_syscall_stack_top
; auto-wrapped (FN_BEGIN emits global): global l3_install_app_done_trampoline
; auto-wrapped (FN_BEGIN emits global): global l3_translate_target
; auto-wrapped (FN_BEGIN emits global): global l3_copy_app_blob_to_slot
; auto-wrapped (FN_BEGIN emits global): global l3_slot_resolve_app_ptr
; auto-wrapped (FN_BEGIN emits global): global app_blob_init
global app_blob_base_v
global app_blob_end_v
global app_blob_size_v
global l3_app_arena_base_v
global l3_app_arena_size_v
