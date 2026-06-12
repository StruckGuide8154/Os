; ============================================================================
; GritOS v3.0 - Process Management & Scheduler
; ============================================================================
bits 64

%include "constants.inc"
%include "structs.inc"
%include "macros.inc"
%include "smap.inc"

; MAX_PROCESSES and PROCESS_POOL now live in constants.inc so workqueue.asm
; can bill cycles into the same PCB table without redefining them.

GDT64_CODE_SEG    equ 0x08
GDT64_DATA_SEG    equ 0x10
GDT64_USER_DATA   equ 0x23
GDT64_USER_CODE   equ 0x2B

section .text

; auto-wrapped (FN_BEGIN emits global): global scheduler_init
; auto-wrapped (FN_BEGIN emits global): global process_create
; auto-wrapped (FN_BEGIN emits global): global process_schedule
global current_process_id
; auto-wrapped (FN_BEGIN emits global): global proc_is_active
; auto-wrapped (FN_BEGIN emits global): global process_save_context
; auto-wrapped (FN_BEGIN emits global): global process_restore_context
; auto-wrapped (FN_BEGIN emits global): global process_kill_window
global process_find_by_window

extern l3_user_stack_top
extern l3_syscall_stack_top
extern tss64
extern tick_count
%include "src/kernel/proc/process_core.inc"
%include "src/kernel/proc/process_placement.inc"
%include "src/kernel/proc/process_callbacks.inc"
%include "src/kernel/proc/process_data.inc"
