; ============================================================================
; GritOS v3.0 - Framebuffer performance instrumentation + WC plan
; ----------------------------------------------------------------------------
; Tracks per-flip TSC timing, byte volume, and full-vs-rect ratio. Reads
; IA32_PAT, IA32_MTRRCAP, IA32_MTRR_DEF_TYPE, all variable MTRRs, and walks the
; active page tables to report the caching attribute the framebuffer is
; actually mapped with.
;
; Computes the *plan* for turning the framebuffer mapping into Write-Combining
; (PAT reprogram + page-table patch) but does NOT execute it. The activation
; routine `fbperf_wc_activate` exists fully but is gated by `fbperf_wc_armed`
; (default 0) so a future session can flip the bit once the serial dump on
; real hardware confirms the plan is sane.
;
; Selectors via SYS_SYSINFO (range 100..199):
;   100 flips_total       110 dirty_rect_sum     120 pat_msr_lo
;   101 full_flips        111 full_bytes_lo      121 pat_msr_hi
;   102 rect_flips        112 full_bytes_hi      122 mtrr_def_type
;   103 bytes_total_lo    113 rect_bytes_lo      123 mtrr_var_count
;   104 bytes_total_hi    114 rect_bytes_hi      124 fb_pte_lo
;   105 tsc_total_lo      115 cr0_lo             125 fb_pte_hi
;   106 tsc_total_hi      116 cr3_lo             126 fb_pte_level
;   107 tsc_min           117 cr4_lo             127 fb_caching_type
;   108 tsc_max           118 cpuid_pat_supported 128 wc_plan_pat_lo
;   109 tsc_last          119 mtrrcap_lo        129 wc_plan_pat_hi
;                                                  130 wc_armed
;                                                  131 wc_activated
;                                                  132 fb_addr_lo
;                                                  133 fb_addr_hi
;                                                  134 init_done
;   199 -> trigger fbperf_serial_dump (returns 0)
;
; Memory types (PAT/MTRR encoding): 0=UC 1=WC 4=WT 5=WP 6=WB 7=UC-
; ============================================================================
bits 64

extern serial_puts
extern serial_crlf
extern serial_putc
extern fb_addr
extern bb_addr
extern scr_width
extern scr_height
extern scr_pitch
extern scr_pitch_q
extern klog_write
extern tick_count

section .text

global fbperf_init
global fbperf_get
global fbperf_serial_dump
global fbperf_flip_full_begin
global fbperf_flip_full_end
global fbperf_flip_rect_begin
global fbperf_flip_rect_end
global fbperf_wc_activate
global fbperf_arm_wc
global fbperf_note_dirty_count

; ---------------------------------------------------------------------------
; rdtsc -> rax (64-bit)
%include "src/kernel/drivers/fbperf_trace.inc"
%include "src/kernel/drivers/fbperf_init.inc"
%include "src/kernel/drivers/fbperf_get.inc"
%include "src/kernel/drivers/fbperf_data.inc"
