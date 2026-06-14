; ---------------------------------------------------------------------------
; cb_run_guarded(rdi=fn, rsi=win, rdx=arg1, rcx=arg2) -> rax = ret (or -1)
;
; The only place call_app_l3 is invoked from dispatch_app_callback's inline
; BSP path. Wraps it with:
;   (B) a reentrancy guard (cb_in_callback): if a callback is already in
;       flight for the BSP, refuse and return -1 instead of double-running
;       (which would clobber the shared cb_rt global + per-slot kernel RSP).
;   (A) a deadman: capture a longjmp landing pad + start tick, arm it, run
;       the callback, disarm on normal return. The PIT IRQ calls
;       cb_deadman_check; on budget overrun it restores rsp/rbx/rbp and jmps
;       to .deadman_land here, marks the slot TERMINATED, returns -1.
;
; BSP-only by construction: dispatch_app_callback only runs the inline path on
; the BSP (the AP-routing path goes through the work queue), so the single
; global landing pad is race-free.
global cb_run_guarded
cb_run_guarded:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; (B) reentrancy guard ---------------------------------------------------
    cmp dword [rel cb_in_callback], 0
    jne .reenter_refuse
    mov dword [rel cb_in_callback], 1

    mov r12, rdi                       ; fn
    mov r13, rsi                       ; win
    mov r14, rdx                       ; arg1
    mov r15, rcx                       ; arg2

    ; resolve pid for the slot (best-effort; 0 if none) so the deadman can
    ; mark it TERMINATED on a runaway. Reuses process_find_by_window.
    xor ebx, ebx
    test r13, r13
    jz .pid_done
    mov edi, [r13 + WIN_OFF_ID]
    call process_find_by_window
    mov ebx, eax                       ; pid (0 if not found)
.pid_done:
    mov [rel cb_deadman_pid], ebx

    ; (A) arm the deadman: save landing pad + start tick.
    lea rax, [rel .deadman_land]
    mov [rel cb_deadman_jmp_rip], rax
    mov [rel cb_deadman_jmp_rsp], rsp
    mov [rel cb_deadman_jmp_rbx], rbx
    mov [rel cb_deadman_jmp_rbp], rbp
    mov rax, [rel tick_count]
    mov [rel cb_deadman_start_tick], rax
    mov dword [rel cb_deadman_armed], 1

    ; run the callback inline on the BSP.
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call call_app_l3

    ; normal return: disarm + clear reentrancy lock.
    mov dword [rel cb_deadman_armed], 0
    mov dword [rel cb_in_callback], 0
    jmp .done

.deadman_land:
    ; Reached via cb_deadman_check's jmp after rsp/rbx/rbp were restored to the
    ; values saved above. The runaway callback's stack frame is abandoned.
    mov dword [rel cb_deadman_armed], 0
    ; mark the offending slot's process TERMINATED so it stops being scheduled.
    mov ebx, [rel cb_deadman_pid]
    test ebx, ebx
    jz .land_unlock
    mov eax, ebx
    imul rax, 512
    add rax, PROCESS_POOL
    mov dword [rax + process_t.state], 4   ; TERMINATED
.land_unlock:
    mov dword [rel cb_in_callback], 0
    mov rax, -1                         ; report failure to the main loop
    jmp .done

.reenter_refuse:
    mov rax, -1
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------------------------------------------------------------------------
; cb_deadman_check() -> eax = 1 if a runaway-callback abort is requested, else 0
;
; Called from the timer IRQ handler (isr.asm .irq_timer) AFTER the LAPIC/PIC
; EOI and ONLY when the interrupted CS shows the IRQ came from ring 3. This is
; pure, NON-destructive DETECTION: if a callback is armed and has exceeded its
; tick budget, it marks the slot's PCB TERMINATED, disarms, and returns eax=1 so
; the caller can perform the clean call_app_l3_return unwind on the IRQ frame.
; It must NOT longjmp from interrupt context (that would strand the IRQ stub
; before EOI/iretq). Returns eax=0 (no abort) otherwise. Clobbers rax/rbx.
; The longjmp pad below is kept for reference but is NOT taken here.
global cb_deadman_check
cb_deadman_check:
    xor eax, eax
    cmp dword [rel cb_deadman_armed], 0
    je .nofire
    mov rax, [rel tick_count]
    sub rax, [rel cb_deadman_start_tick]
    cmp eax, [rel cb_deadman_budget]
    jb .no_overrun
    ; over budget: disarm (so we fire once) and mark the runaway slot TERMINATED
    ; so it stops being scheduled. Mirrors .deadman_land's slot->PCB math.
    mov dword [rel cb_deadman_armed], 0
    mov ebx, [rel cb_deadman_pid]
    test ebx, ebx
    jz .request_abort
    mov eax, ebx
    imul rax, 512
    add rax, PROCESS_POOL
    mov dword [rax + process_t.state], 4   ; TERMINATED
.request_abort:
    mov eax, 1                              ; abort requested
    ret
.no_overrun:
    xor eax, eax
.nofire:
    ret

; --- reference-only longjmp path (NOT reachable from IRQ context) ------------
; The original raw `mov rsp; jmp pad` longjmp lived here. It is unsafe from the
; timer IRQ (abandons the stub before EOI+iretq), so the deadman now detects and
; the IRQ stub performs the clean call_app_l3_return unwind instead.
cb_deadman_longjmp_ref:
    mov rbx, [rel cb_deadman_jmp_rbx]
    mov rbp, [rel cb_deadman_jmp_rbp]
    mov rsp, [rel cb_deadman_jmp_rsp]
    jmp [rel cb_deadman_jmp_rip]

extern wq_unlock
extern smp_alive_cores

WIN_OFF_ID equ 0                       ; matches src/include/window_layout.inc

%ifndef GRIT_ENABLE_RING3_AP
; --- NON-AP BUILD: pass-through to call_app_l3 ------------------------------
; Apps run inline on the BSP when AP routing is not compiled in.
global dispatch_app_callback
dispatch_app_callback:
    jmp cb_run_guarded                 ; deadman + reentrancy-guarded inline run
%else
; --- AP-ROUTING BUILD: route ring-3 callbacks to APs ------------------------
; The AP "presumed dead" wait budget is derived from the inline deadman budget so
; there is ONE timescale knob (cb_deadman_budget). Kept a large multiple, NOT 1x:
; legit synchronous callbacks (~12 s DHCP) must complete on the AP and not get
; misclassified as a dead AP + re-run inline. 60 * ~25 ticks ~= 1500 ticks ~= 15 s.
CB_AP_DEADMAN_MULT equ 60
extern workqueue_wait_timeout
global ring3_ap_enabled
section .data
ring3_ap_enabled: dd 1
section .text

global dispatch_app_callback
dispatch_app_callback:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12, rdi                       ; target function
    mov r13, rsi                       ; window ptr
    mov r14, rdx                       ; arg1
    mov r15, rcx                       ; arg2
    DBG_EVT EVT_CALLBACK_DISPATCH, 0, r12, r13, r14, r15, 0, 0

    ; Full-quality wallpaper SVG rasterization owns the global ring-3 callback
    ; lock because slot isolation still rewrites shared page tables. Never spin
    ; the BSP on that lock: the compositor has a wallpaper-busy present path,
    ; and Settings exposes the busy state. Returning here keeps cursor/input,
    ; timers and kernel work alive while the AP finishes and publishes its cache.
    cmp byte [wallpaper_render_active], 0
    jne .busy_return

    cmp dword [ring3_ap_enabled], 0
    je .inline
    test r13, r13
    jz .inline

    mov edi, [r13 + WIN_OFF_ID]
    call process_find_by_window
    test eax, eax
    jz .inline
    mov ebx, eax                       ; pid

    mov eax, ebx
    imul rax, 512
    add rax, PROCESS_POOL
    mov ecx, [rax + process_t.home_core]
    test ecx, ecx
    jz .inline

    mov eax, [smp_alive_cores]
    cmp eax, 2
    jb .inline

    lea rdi, [rel app_callback_lock]
    call wq_lock

    lea rdi, [rel app_callback_pack]
    mov [rdi + 0],  r12
    mov [rdi + 8],  r13
    mov [rdi + 16], r14
    mov [rdi + 24], r15

    mov edi, ebx
    lea rsi, [rel call_app_l3_packed]
    lea rdx, [rel app_callback_pack]
    mov r8d, 1
    call process_submit_job
    cmp eax, -1
    je .submit_fail

    mov edi, eax
    ; Wait budget = "is the AP dead?", NOT "is the callback slow?". The old
    ; 200 ms budget misclassified legitimately-slow callbacks (a DHCP click runs
    ; the synchronous rtl8156_dhcp_configure, which blocks for SECONDS waiting on
    ; OFFER/ACK + tick timeouts) as a dead AP, then re-ran the SAME callback
    ; inline on the BSP via .timed_out while the AP was STILL executing it. Two
    ; concurrent call_app_l3 invocations for one slot clobber the shared cb_rt
    ; global + the per-slot saved kernel RSP, so the ring-3 return restored a
    ; smashed RSP and #PF'd at a stale RIP (the '!T' -> RIP=0x170 / RSP in the
    ; trampoline-stack region crash). Budget must stay large enough that any real
    ; callback (incl. worst-case ~12 s sync DHCP) completes on the AP and takes
    ; the safe normal return below; only a genuinely hung AP reaches the inline
    ; fallback, where double execution can't happen because the AP is gone.
    ;
    ; This budget is DELIBERATELY NOT the deadman budget: a 250 ms slam here would
    ; re-introduce the double-run/RSP-smash bug for slow-but-valid callbacks. So we
    ; derive it as a large multiple of cb_deadman_budget (CB_AP_DEADMAN_MULT) - the
    ; relationship is now explicit (one knob, cb_deadman_budget) instead of a magic
    ; 1500 - while still landing near ~15 s. The ACTUAL runaway protection comes
    ; from the deadman + reentrancy guard on the inline re-run at .inline (which
    ; goes through cb_run_guarded), so a hung AP callback is killed on the ~250 ms
    ; deadman timescale once it falls back, not after a bare 15 s.
    mov esi, [rel cb_deadman_budget]   ; ~25 ticks
    imul esi, esi, CB_AP_DEADMAN_MULT  ; 60x -> ~1500 ticks (~15 s) "AP dead" budget
    call workqueue_wait_timeout
    test edx, edx
    jnz .timed_out

    push rax
    lea rdi, [rel app_callback_lock]
    call wq_unlock
    pop rax
    jmp .ret

.timed_out:
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, '!'
    out dx, al
    mov al, 'T'
    out dx, al
    pop rdx
    pop rax
    mov dword [ring3_ap_enabled], 0    ; auto-disable for the rest of the boot
    lea rdi, [rel app_callback_lock]
    call wq_unlock
    ; The AP that owns this job is presumed dead (a draw/click callback should
    ; never take >200 ms), so it will not double-run the stale job. Run the
    ; callback inline now instead of returning without drawing - otherwise the
    ; window paints only its blank background (a white window) for this frame.
    jmp .inline

.submit_fail:
    lea rdi, [rel app_callback_lock]
    call wq_unlock

.inline:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call cb_run_guarded                ; deadman + reentrancy-guarded inline run
    DBG_EVT EVT_CALLBACK_RETURN, 0, rax, r12, r13, r14, r15, 0
%ifdef ENABLE_DEBUG_SERIAL
    push rax
    push rcx
    push rdx
    push rdi
    SER 'D'
    SER 'R'
    SER 'E'
    SER 'T'
    SER ' '
    SER 'a'
    mov rdi, [rsp + 24]                 ; callback return value
    call ser_print_hex64
    SER ' '
    SER 'p'
    lea rdi, [rsp + 32]                 ; dispatch_app_callback rsp before pushes
    call ser_print_hex64
    SER ' '
    SER 'b'
    mov rdi, rbp
    call ser_print_hex64
    SER ' '
    SER 'c'
    mov rdi, [rsp + 32]                 ; local pad / frame low qword
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 40]                 ; saved r15
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 48]                 ; saved r14
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 56]                 ; saved r13
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 64]                 ; saved r12
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 72]                 ; saved rbx
    call ser_print_hex64
    SER ' '
    SER 'r'
    mov rdi, r12
    call ser_print_hex64
    SER '/'
    mov rdi, r13
    call ser_print_hex64
    SER '/'
    mov rdi, r14
    call ser_print_hex64
    SER '/'
    mov rdi, r15
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    pop rdx
    pop rcx
    pop rax
%endif

.ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.busy_return:
    xor eax, eax
    jmp .ret
%endif

; --- media_draw_dispatch ------------------------------------------------------
; Route the kernel-side Media Player draw fn (app_media_draw) onto the owning
; app's home_core AP instead of running it inline on the BSP. Without this the
; video blit always runs on core 0, and two playing videos saturate the BSP and
; freeze the GUI.
;
; app_media_draw is NOT a ring-3 callback (it runs in kernel context and writes
; the shared backbuffer directly), so it cannot go through dispatch_app_callback
; / call_app_l3. Instead we submit it as a kernel work-queue job pinned to the
; process's home_core and block until it completes. The BSP is idle during the
; wait, so only one core ever writes the backbuffer at a time and no fb lock is
; needed. A 200 ms timeout falls back to inline (and disables AP routing for the
; rest of the boot) so a wedged AP can never freeze the OS.
;
; Input:  RDI = window struct ptr
; Output: none (drop-in replacement for the inline `call app_media_draw`)
extern app_media_draw
%ifndef GRIT_ENABLE_RING3_AP
global media_draw_dispatch
media_draw_dispatch:
    jmp app_media_draw
%else
global media_draw_dispatch
media_draw_dispatch:
    push rbp
    mov rbp, rsp
    push rbx
    push r12                           ; 3 pushes -> rsp 16-aligned at calls
    mov r12, rdi                       ; window ptr

    cmp dword [ring3_ap_enabled], 0
    je .inline
    mov eax, [smp_alive_cores]
    cmp eax, 2
    jb .inline

    mov edi, [r12 + WIN_OFF_ID]
    call process_find_by_window
    test eax, eax
    jz .inline
    mov ebx, eax                       ; pid

    mov eax, ebx
    imul rax, 512
    add rax, PROCESS_POOL
    mov ecx, [rax + process_t.home_core]
    test ecx, ecx
    jz .inline

    mov edi, ebx                       ; pid
    mov rsi, app_media_draw            ; func
    mov rdx, r12                       ; arg = window ptr
    mov r8d, 1                         ; WQ_PRIO_NORMAL
    call process_submit_job
    cmp eax, -1
    je .inline
    mov edi, eax
    ; Same "slow != dead" fix as the generic dispatch path above: a 200 ms budget
    ; misreads a legitimately-slow AP draw as a dead AP and re-runs it inline while
    ; the AP is still executing it (double call_app_l3 -> kernel-RSP smash). Wait
    ; long enough that only a genuinely hung AP trips the inline fallback.
    mov esi, 1500                      ; 1500 ticks = ~15 s "AP presumed dead" budget
    call workqueue_wait_timeout
    test edx, edx
    jnz .timed_out
    jmp .ret

.timed_out:
    mov dword [ring3_ap_enabled], 0    ; auto-disable AP routing this boot
    ; The AP owning this job is presumed dead (a draw should never take 200 ms),
    ; so it will not double-run; draw inline now so the frame still paints.
.inline:
    mov rdi, r12
    call app_media_draw
.ret:
    pop r12
    pop rbx
    pop rbp
    ret
%endif

; --- app_callback_lock --------------------------------------------------------
; Global spinlock that Stage 2d will hold around any cross-core ring-3 callback
; dispatch. Defined in .data below; declared global so usermode.asm and any
; future routing site can take it via wq_lock / wq_unlock.

; --- process_get_affinity -----------------------------------------------------
; Input:  EDI = PID
; Output: EAX = affinity mask (0 if PID invalid)
global process_get_affinity
process_get_affinity:
    cmp edi, MAX_PROCESSES
    jae .bad
    mov eax, edi
    imul rax, 512
    add rax, PROCESS_POOL
    cmp dword [rax + process_t.state], 0
    je .bad
    mov eax, [rax + process_t.affinity_mask]
    ret
.bad:
    xor eax, eax
    ret

