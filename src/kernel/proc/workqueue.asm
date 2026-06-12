; ============================================================================
; GritOS v3.0 - SMP Work Queue (worker-core offload)
; ----------------------------------------------------------------------------
; PURPOSE
;   Keeps the GUI responsive when an app does something expensive (SVG
;   rasterisation, image decode, layout). The boot CPU (BSP) hands such work
;   to the Application Processors (APs) as "jobs". The BSP keeps rendering at
;   full speed while an AP crunches the job on another core.
;
;   After bring-up an AP jumps into smp_worker_loop. When there is no work it
;   halts until the BSP publishes a job and sends a local-APIC wake IPI.
;
; CONCURRENCY MODEL
;   * One producer  : the BSP - calls workqueue_submit / reap / wait.
;   * N consumers    : the APs - each runs smp_worker_loop.
;   * A job slot is claimed lock-free with `lock cmpxchg` on its status word,
;     so there is NO global lock: a slow or dead AP can never stall the BSP,
;     and two APs can never run the same job.
;   * Each slot is its own 64-byte cache line, so cores claiming different
;     slots do not ping-pong a shared line (no false sharing).
;
; JOB CONTRACT - a function submitted as a job MUST:
;   * Be trusted kernel code. Jobs are never submitted from usermode, so the
;     function pointer is always a kernel address - never make this a syscall.
;   * Take exactly one argument in RDI and return a scalar result in RAX.
;   * Follow the SysV ABI: preserve RBX, RBP, R12-R15 (the worker loop relies
;     on this to keep its bookkeeping registers across the call).
;   * Do bounded work. APs receive no timer IRQs, so a job runs to completion;
;     a job that loops forever permanently consumes one AP - but never the BSP,
;     so the GUI keeps running regardless. Job PRIORITY (WQ_PRIO_* below) exists
;     so a flood of cheap app jobs cannot starve system-critical jobs: workers
;     always claim the highest-priority PENDING job first.
;
; SHARED STATE - a job MAY touch state shared with the BSP, provided every
; accessor (the BSP side included) holds the matching lock. This replaces the
; old "jobs must be self-contained" rule, which was an un-enforceable honour
; system. Use wq_lock / wq_unlock with one of the named locks:
;     wq_alloc_lock   - the physical page allocator (page_alloc / page_free).
;     wq_fb_lock      - the shared framebuffer.
;     wq_driver_lock  - shared driver state.
; A lock only protects if BOTH sides take it; page_alloc / page_free already
; do. Lock-free, self-contained jobs remain the simplest option - a job that
; only reads read-only data and writes its own output buffer needs no lock.
;
; STATUS LIFECYCLE (status word at offset 0 of every slot):
;       FREE -> BUILDING -> PENDING -> RUNNING -> DONE -> FREE
;   BSP : FREE->BUILDING (atomic claim), BUILDING->PENDING (publish),
;         DONE->FREE (reap). Also BUILDING->RUNNING->DONE on the inline path.
;   AP  : PENDING->RUNNING (atomic claim), RUNNING->DONE (publish result).
;
; BSP API
;   workqueue_init                  - zero the queue, allow workers to run.
;   workqueue_submit(rdi=func,       - queue a job. Returns a handle (0..N-1)
;                    rsi=arg,          in RAX, or WQ_INVALID (-1) if full.
;                    rdx=priority)     priority is WQ_PRIO_LOW/NORMAL/HIGH.
;                          -> rax     If no AP is available the job runs
;                                     inline so callers stay correct on
;                                     single-core builds.
;   workqueue_done(rdi=handle) -> rax - 1 if the job finished, else 0.
;   workqueue_reap(rdi=handle) -> rax - result of a finished job; frees slot.
;   workqueue_wait(rdi=handle) -> rax - spin until done, return result + free.
;   workqueue_selftest               - submit known jobs, verify, print "WQ:".
;
; SHARED-STATE LOCK API
;   wq_lock(rdi=lock word ptr)        - spin until the lock is acquired.
;   wq_unlock(rdi=lock word ptr)      - release a lock held by this core.
;     Both preserve every register except RDI's pointee. Named locks live in
;     .data: wq_alloc_lock, wq_fb_lock, wq_driver_lock.
;
; TYPICAL ASYNC USE (keeps the render loop alive):
;       mov rdi, my_heavy_func
;       mov rsi, my_arg
;       mov rdx, WQ_PRIO_NORMAL
;       call workqueue_submit
;       mov [job], eax            ; stash handle, keep rendering frames...
;   ... later, once per frame ...
;       mov edi, [job]
;       call workqueue_done
;       test eax, eax
;       jz  .still_running
;       mov edi, [job]
;       call workqueue_reap       ; result in rax
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

extern serial_puts
extern serial_crlf
extern ser_print_hex64
extern smp_alive_cores              ; defined in arch/apic.asm (.data)
extern tick_count
extern cpu_tsc_per_tick
extern apic_wake_workers

; SMP_CORE_STATE offsets used by Task Manager:
;   +24 dd current utilization percent
;   +28 dd current MHz
;   +32 dq busy-cycle accumulator
;   +40 dq idle/scan-cycle accumulator
;   +48 dq last TSC mark
;   +56 dq last published tick
;   +64 dq previous APERF
;   +72 dq previous MPERF

; --- Job slot layout: 64 bytes, one cache line -----------------------------
WQ_OFF_STATUS  equ 0                ; dd  - lifecycle state (WQ_* below)
WQ_OFF_FUNC    equ 8                ; dq  - job entry point
WQ_OFF_ARG     equ 16               ; dq  - single argument, passed in RDI
WQ_OFF_RESULT  equ 24               ; dq  - RAX returned by the job
WQ_OFF_RUNS    equ 32               ; dd  - diagnostics: 1 once a worker ran it
WQ_OFF_PRIO    equ 36               ; dd  - job priority (WQ_PRIO_* below)
; Stage 2a: optional per-job placement + accounting fields.
;   target_core: -1 means "any AP can run it" (the legacy behaviour).
;                A non-negative value means only that core's worker may claim
;                the slot. Used so app-bound work lands on the app's home core.
;   proc_id    : 0 means "do not bill" (kernel-internal job). A non-zero value
;                names a process_t.id; the worker that runs the job lock-adds
;                its TSC delta into PROCESS_POOL[proc_id].cpu_time_cycles.
WQ_OFF_TARGET  equ 40               ; dd  - target core index, or -1 = any
WQ_OFF_PROC    equ 44               ; dd  - process id to bill, or 0 = none
WQ_JOB_SIZE    equ 64
WQ_MAX_JOBS    equ 32

WQ_TARGET_ANY  equ -1               ; submit_to "no preference"

; PCB layout we touch from the worker (must track process_t in structs.inc).
WQ_PCB_STRIDE    equ 512
WQ_PCB_TIME_OFF  equ 0xC8            ; process_t.cpu_time_cycles

; --- status word values ---
WQ_FREE        equ 0                ; slot unused
WQ_PENDING     equ 1                ; published, waiting for a worker
WQ_RUNNING     equ 2                ; a core is executing it
WQ_DONE        equ 3                ; finished, result is valid
WQ_BUILDING    equ 4                ; BSP is filling in func/arg (not yet visible)

; --- job priority values (higher number = claimed first by workers) ---
WQ_PRIO_LOW    equ 0                ; background app work; may be starved
WQ_PRIO_NORMAL equ 1                ; default
WQ_PRIO_HIGH   equ 2                ; system-critical; never starved by apps

WQ_INVALID     equ -1               ; workqueue_submit return value when full

WQ_SELFTEST_N  equ 8                ; number of jobs the self-test submits

section .text

; ----------------------------------------------------------------------------
; workqueue_init - reset every slot to FREE and release the workers.
%include "src/kernel/proc/workqueue_api.inc"
%include "src/kernel/proc/workqueue_worker.inc"
