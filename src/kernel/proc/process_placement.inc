; --- process_auto_pick_core ---------------------------------------------------
; Input:  EDI = requested affinity mask (bit i set => core i permitted)
; Output: RAX = chosen core index, or 0 if no core in mask is alive
;
; Strategy: among cores that are (a) alive, (b) permitted by the masked-down
; affinity, pick the one with the lowest currently-published utilization
; (smp_core_states + offset 24). Ties go to the lowest core index. The mask is
; pre-filtered against SMP_SYSTEM_CORE_MASK so cores 0/1 are never returned
; for app placement; if the request was system-only, fall back to core 0.
process_auto_pick_core:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov esi, edi                       ; esi = raw requested mask
    and esi, ~SMP_SYSTEM_CORE_MASK     ; strip system cores for app placement
    jnz .mask_ok
    ; Caller asked for only system cores (or empty mask): hand back core 0.
    xor eax, eax
    jmp .ret

.mask_ok:
    mov ecx, [smp_alive_cores]
    test ecx, ecx
    jnz .have_cores
    xor eax, eax                       ; SMP not up; fall back to BSP
    jmp .ret

.have_cores:
    cmp ecx, SMP_MAX_CORES
    jbe .cores_capped
    mov ecx, SMP_MAX_CORES
.cores_capped:
    xor edi, edi                       ; edi = scan index
    mov eax, -1                        ; eax = best core (-1 = none)
    mov edx, 0x7FFFFFFF                ; edx = best util seen

.scan:
    cmp edi, ecx
    jae .scan_done
    ; Permitted by mask? bit = 1 << edi
    push rcx
    mov ecx, edi
    mov ebx, 1
    shl ebx, cl
    pop rcx
    test ebx, esi
    jz .next
    ; Look up this core's utilization in smp_core_states.
    mov r9d, edi
    imul r9d, SMP_CORE_STATE_SIZE
    mov r10d, [smp_core_states + r9 + 24]
    cmp r10d, edx
    jae .next
    mov edx, r10d
    mov eax, edi
.next:
    inc edi
    jmp .scan

.scan_done:
    cmp eax, -1
    jne .ret
    ; No alive core in mask (e.g. only core 0 alive, app mask excluded it).
    ; Pick the lowest mask bit anyway; Stage 2 will redirect if impossible.
    bsf eax, esi
    jnc .ret
    xor eax, eax

.ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; --- process_set_affinity -----------------------------------------------------
; Input:  EDI = PID, ESI = requested mask
; Output: RAX = applied mask, or -1 if PID invalid / dead
;
; The applied mask is the request AND-ed with NOT(SMP_SYSTEM_CORE_MASK): apps
; can broaden across worker cores but can never request a system core. If
; this masks to zero, the call is rejected (-1) instead of silently leaving
; the process unrunnable.
global process_set_affinity
process_set_affinity:
    push rbx
    cmp edi, MAX_PROCESSES
    jae .bad
    mov eax, edi
    imul rax, 512
    add rax, PROCESS_POOL
    mov rbx, rax
    cmp dword [rbx + process_t.state], 0  ; EMPTY?
    je .bad
    mov eax, esi
    and eax, ~SMP_SYSTEM_CORE_MASK
    test eax, eax
    jz .bad
    mov [rbx + process_t.affinity_mask], eax
    ; Re-pick a home core inside the new mask.
    push rdi
    mov edi, eax
    call process_auto_pick_core
    pop rdi
    mov [rbx + process_t.home_core], eax
    mov eax, [rbx + process_t.affinity_mask]
    pop rbx
    ret
.bad:
    mov rax, -1
    pop rbx
    ret

; --- process_submit_job -------------------------------------------------------
; Input:  EDI = PID, RSI = job ID (wq_job_table index), RDX = arg, R8d = priority
; Output: RAX = WQ handle (or WQ_INVALID == -1)
;
; The work queue is a secure job-ID allow-list (grithlk/workqueue.ghl): a slot
; holds a wq_job_table index, never a function pointer, so callers pass a JOB ID
; here, not an address. workqueue_submit_to is now GHLK and uses the SysV ABI
; (jobid=rdi, arg=rsi, prio=rdx, target=rcx, proc=r8).
;
; Pin a kernel job to a process. The job is queued with target_core =
; PCB.home_core and proc_id = PID, so when the matching AP picks it up the
; cycles it spends will be billed to PROCESS_POOL[PID].cpu_time_cycles. This
; is the path Stage 2c will use to route app-callback execution onto a
; specific AP without anything in this kernel having to know which core is
; "the app core" - that decision was already made when the process was
; created (or last did process_set_affinity).
;
; A PID of 0 (the kernel process) submits with WQ_TARGET_ANY and no billing -
; same semantics as the legacy workqueue_submit.
global process_submit_job
extern workqueue_submit_to
process_submit_job:
    push rbx
    cmp edi, MAX_PROCESSES
    jae .bad
    test edi, edi
    jnz .have_app
    ; PID 0: route as a generic any-core job (no billing). Stash jobid/arg in
    ; scratch regs (r10/r11) first so reshuffling the arg registers can't clobber
    ; an input that has not been consumed yet.
    mov r10, rsi                    ; r10 = job ID
    mov r11, rdx                    ; r11 = arg
    mov edx, r8d                    ; arg3 = priority
    mov ecx, -1                     ; arg4 = WQ_TARGET_ANY
    xor r8d, r8d                    ; arg5 = no billing
    mov rdi, r10                    ; arg1 = job ID
    mov rsi, r11                    ; arg2 = arg
    call workqueue_submit_to
    pop rbx
    ret
.have_app:
    mov eax, edi
    imul rax, 512
    add rax, PROCESS_POOL
    mov rbx, rax
    cmp dword [rbx + process_t.state], 0
    je .bad
    mov r10, rsi                    ; r10 = job ID
    mov r11, rdx                    ; r11 = arg
    mov edx, r8d                    ; arg3 = priority (read r8 before it is reused)
    mov ecx, [rbx + process_t.home_core] ; arg4 = target_core
    mov r8d, edi                    ; arg5 = proc_id to bill
    mov rdi, r10                    ; arg1 = job ID
    mov rsi, r11                    ; arg2 = arg
    call workqueue_submit_to
    pop rbx
    ret
.bad:
    mov rax, -1
    pop rbx
    ret

; --- process_get_cpu_time -----------------------------------------------------
; Input:  EDI = PID
; Output: RAX = cpu_time_cycles, or 0 if PID invalid / empty
global process_get_cpu_time
process_get_cpu_time:
    cmp edi, MAX_PROCESSES
    jae .bad
    mov eax, edi
    imul rax, 512
    add rax, PROCESS_POOL
    cmp dword [rax + process_t.state], 0
    je .bad
    mov rax, [rax + process_t.cpu_time_cycles]
    ret
.bad:
    xor eax, eax
    ret

; --- process_find_by_window ---------------------------------------------------
; Input:  EDI = window id
; Output: EAX = PID (>=1) of the process owning that window, or 0 if none
;
; Scans the PCB pool for a non-empty entry with .win_id == edi. The global
; symbol has been declared since v3.0 but the body was previously empty; Stage 2c needs
; it to look up an app's PCB (and thus its home_core / cpu_time_cycles) from
; the window event being delivered.
process_find_by_window:
    push rbx
    push rcx
    mov ecx, 1                         ; PID 0 is the kernel; skip it
.scan:
    cmp ecx, MAX_PROCESSES
    jae .none
    mov eax, ecx
    imul rax, 512
    add rax, PROCESS_POOL
    mov rbx, rax
    cmp dword [rbx + process_t.state], 0
    je .next
    cmp dword [rbx + process_t.win_id], edi
    jne .next
    mov eax, ecx
    pop rcx
    pop rbx
    ret
.next:
    inc ecx
    jmp .scan
.none:
    xor eax, eax
    pop rcx
    pop rbx
    ret

; --- dispatch_app_callback ---------------------------------------------------
;
; Stage 2d is active whenever the build defines `GRIT_ENABLE_RING3_AP`.
; Profiles that start AP workers define it so app callbacks run on each
; process home_core instead of tail-calling call_app_l3 on the BSP.
;
; The active path below looks up the PCB, takes the global
; app_callback_lock, submit the packed thunk to the PCB's home_core, wait
; with a 200 ms budget. On timeout the ring3_ap_enabled flag is cleared and
; every subsequent callback this boot goes straight to inline - at most one
; callback ever suffers the timeout penalty.
;
; The compile-time fallback remains for single-core/non-AP profiles.
; Input:  RDI = target function, RSI = window pointer (or 0 = no window),
;         RDX = arg1, RCX = arg2
; Output: RAX = callback return value
;
; Decision tree:
;   * no window, no PCB, home_core == 0 (BSP), or no APs alive
;       -> run call_app_l3 inline on the BSP (legacy behavior).
;   * else
;       -> acquire the global app_callback_lock,
;          pack args into app_callback_pack,
;          submit the packed thunk via process_submit_job(pid, ...),
;          workqueue_wait for it,
;          release the lock.
;
; The lock serialises ring-3 callbacks system-wide because call_app_l3 calls
; l3_apply_slot_isolation which rewrites the shared arena PTEs and flushes
; CR3. Two cores doing that concurrently for different slots would race the
; shared page table. With the lock there is at most one ring-3 callback in
; flight, so the AP can rewrite PTEs and self-flush its TLB safely. The
; throughput cost is real (no concurrent app code across cores) and will be
; recovered in a future stage by moving to per-CPU CR3 or static isolation.
;
; If workqueue_submit returns WQ_INVALID (queue full), we release the lock
; and fall back to the inline path so the callback still runs.
extern call_app_l3
extern call_app_l3_packed
extern ser_print_hex64
extern wq_lock
