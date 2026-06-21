
; --- scheduler_init ---
FN_BEGIN scheduler_init, 0, 0, FN_RET_SCALAR
    push rdi
    push rcx
    push rax
    push rbx
    
    ; Clear process pool
    mov rdi, PROCESS_POOL
    xor eax, eax
    mov ecx, (MAX_PROCESSES * 512) / 4
    rep stosd
    
    ; Initialize Kernel Process (PID 0)
    mov rbx, PROCESS_POOL
    mov dword [rbx + process_t.id], 0
    mov dword [rbx + process_t.state], 2 ; RUNNING
    mov qword [rbx + process_t.rflags], 0x202
    mov qword [rbx + process_t.cs], GDT64_CODE_SEG
    mov qword [rbx + process_t.ss], GDT64_DATA_SEG
    mov qword [rbx + process_t.kernel_rsp], 0x200000
    ; Kernel may run on any core; pinned to core 0 in practice (the BSP).
    mov dword [rbx + process_t.affinity_mask], 0xFFFFFFFF
    mov dword [rbx + process_t.home_core], 0
    mov qword [rbx + process_t.cpu_time_cycles], 0
    ; Priority manager: the kernel main loop (PID 0) runs at PRIO_KERNEL so it is
    ; never starved by an app, but stays below PRIO_REALTIME.
    mov dword [rbx + process_t.priority], PRIO_KERNEL
    mov dword [rbx + process_t.base_priority], PRIO_KERNEL
    mov dword [rbx + process_t.quantum_left], QUANTUM_TICKS_HIGH
    mov dword [rbx + process_t.strikes], 0

    mov dword [current_process_id], 0
    mov dword [next_pid], 1
    
    pop rbx
    pop rax
    pop rcx
    pop rdi
    ret

; --- process_create ---
; RDI = Entry Point (RIP)
; RSI = Slot (App Arena / Stack index)
; RDX = Window ID
; Returns: RAX = Process ID or -1
FN_BEGIN process_create, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13
    push r14
    
    mov r12, rdi        ; entry
    mov r13, rsi        ; slot
    mov r14, rdx        ; win_id

    cmp r13, MAX_WINDOWS
    jae .invalid_args
    cmp r14, MAX_WINDOWS
    jae .invalid_args
    
    ; Find free slot in process pool
    mov rbx, PROCESS_POOL
    xor ecx, ecx
.find_loop:
    cmp dword [rbx + process_t.state], 0 ; EMPTY = 0
    je .found
    add rbx, 512
    inc ecx
    cmp ecx, MAX_PROCESSES
    jl .find_loop
    mov rax, -1
    jmp .done
    
.found:
    ; Initialize PCB
    mov eax, [next_pid]
    inc dword [next_pid]
    mov [rbx + process_t.id], eax
    mov [rbx + process_t.state], dword 1 ; READY = 1
    mov [rbx + process_t.rip], r12
    mov [rbx + process_t.slot], r13d
    mov [rbx + process_t.win_id], r14d
    
    ; Setup Stacks
    mov edi, r13d
    call l3_user_stack_top
    sub rax, 8
    extern call_app_l3_app_done
    lea rdx, [rel call_app_l3_app_done]
    USER_ACCESS_BEGIN
    mov qword [rax], rdx          ; IRET trampoline onto the slot's user stack (PTE.U=1)
    USER_ACCESS_END
    mov [rbx + process_t.rsp], rax
    
    mov edi, r13d
    call l3_syscall_stack_top
    mov [rbx + process_t.kernel_rsp], rax
    
    ; Setup Selectors and RFLAGS
    mov qword [rbx + process_t.cs], GDT64_USER_CODE
    mov qword [rbx + process_t.ss], GDT64_USER_DATA
    mov qword [rbx + process_t.rflags], 0x202

    ; Default affinity: any non-system core. Stage 1 only records this;
    ; Stage 2 will honor it when dispatching to APs. Pick a home core now
    ; via the auto-placer so task manager has something stable to display.
    mov dword [rbx + process_t.affinity_mask], SMP_APP_CORE_MASK
    mov qword [rbx + process_t.cpu_time_cycles], 0
    ; Priority manager: new apps launch at PRIO_NORMAL with a full quantum and a
    ; clean strike count. Task Manager can raise/lower this via SYS_PROC_SETPRIO;
    ; the budget/strike engine demotes it toward PRIO_IDLE on abuse.
    mov dword [rbx + process_t.priority], PRIO_NORMAL
    mov dword [rbx + process_t.base_priority], PRIO_NORMAL
    mov dword [rbx + process_t.quantum_left], QUANTUM_TICKS_NORMAL
    mov dword [rbx + process_t.strikes], 0
    push rdi
    mov edi, SMP_APP_CORE_MASK
    call process_auto_pick_core        ; RAX = chosen core index
    pop rdi
    mov [rbx + process_t.home_core], eax

    mov rax, [rbx + process_t.id]

.done:
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

.invalid_args:
    mov rax, -1
    jmp .done


; --- current_process_ptr ---
; Returns: RAX = pointer to current process PCB
current_process_ptr:
    mov eax, [current_process_id]
    cmp eax, -1
    je .no_proc
    imul rax, rax, 512
    add rax, PROCESS_POOL
    ret
.no_proc:
    xor rax, rax
    ret

; --- process_save_context ---
; RDI = pointer to PUSH_ALL frame (RSP after PUSH_ALL)
FN_BEGIN process_save_context, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    
    call current_process_ptr
    test rax, rax
    jz .done
    
    mov rbx, rax    ; rbx = PCB
    
    ; Save GP registers from stack frame
    mov rcx, [rdi + ALL_RAX]
    mov [rbx + process_t.rax], rcx
    mov rcx, [rdi + ALL_RBX]
    mov [rbx + process_t.rbx], rcx
    mov rcx, [rdi + ALL_RCX]
    mov [rbx + process_t.rcx], rcx
    mov rcx, [rdi + ALL_RDX]
    mov [rbx + process_t.rdx], rcx
    mov rcx, [rdi + ALL_RSI]
    mov [rbx + process_t.rsi], rcx
    mov rcx, [rdi + ALL_RDI]
    mov [rbx + process_t.rdi], rcx
    mov rcx, [rdi + ALL_RBP]
    mov [rbx + process_t.rbp], rcx
    mov rcx, [rdi + ALL_R8]
    mov [rbx + process_t.r8], rcx
    mov rcx, [rdi + ALL_R9]
    mov [rbx + process_t.r9], rcx
    mov rcx, [rdi + ALL_R10]
    mov [rbx + process_t.r10], rcx
    mov rcx, [rdi + ALL_R11]
    mov [rbx + process_t.r11], rcx
    mov rcx, [rdi + ALL_R12]
    mov [rbx + process_t.r12], rcx
    mov rcx, [rdi + ALL_R13]
    mov [rbx + process_t.r13], rcx
    mov rcx, [rdi + ALL_R14]
    mov [rbx + process_t.r14], rcx
    mov rcx, [rdi + ALL_R15]
    mov [rbx + process_t.r15], rcx
    
    ; Save RIP, CS, RFLAGS, RSP, SS from interrupt frame
    mov rcx, [rdi + 136] ; RIP
    mov [rbx + process_t.rip], rcx
    mov rcx, [rdi + 144] ; CS
    mov [rbx + process_t.cs], rcx
    mov rcx, [rdi + 152] ; RFLAGS
    mov [rbx + process_t.rflags], rcx
    mov rcx, [rdi + 160] ; RSP
    mov [rbx + process_t.rsp], rcx
    mov rcx, [rdi + 168] ; SS
    mov [rbx + process_t.ss], rcx
    
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; --- process_restore_context ---
; RDI = pointer to PUSH_ALL frame to OVERWRITE
FN_BEGIN process_restore_context, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    
    call current_process_ptr
    test rax, rax
    jz .done
    
    mov rbx, rax ; PCB
    
    ; Restore GP registers to stack frame
    mov rcx, [rbx + process_t.rax]
    mov [rdi + ALL_RAX], rcx
    mov rcx, [rbx + process_t.rbx]
    mov [rdi + ALL_RBX], rcx
    mov rcx, [rbx + process_t.rcx]
    mov [rdi + ALL_RCX], rcx
    mov rcx, [rbx + process_t.rdx]
    mov [rdi + ALL_RDX], rcx
    mov rcx, [rbx + process_t.rsi]
    mov [rdi + ALL_RSI], rcx
    mov rcx, [rbx + process_t.rdi]
    mov [rdi + ALL_RDI], rcx
    mov rcx, [rbx + process_t.rbp]
    mov [rdi + ALL_RBP], rcx
    mov rcx, [rbx + process_t.r8]
    mov [rdi + ALL_R8], rcx
    mov rcx, [rbx + process_t.r9]
    mov [rdi + ALL_R9], rcx
    mov rcx, [rbx + process_t.r10]
    mov [rdi + ALL_R10], rcx
    mov rcx, [rbx + process_t.r11]
    mov [rdi + ALL_R11], rcx
    mov rcx, [rbx + process_t.r12]
    mov [rdi + ALL_R12], rcx
    mov rcx, [rbx + process_t.r13]
    mov [rdi + ALL_R13], rcx
    mov rcx, [rbx + process_t.r14]
    mov [rdi + ALL_R14], rcx
    mov rcx, [rbx + process_t.r15]
    mov [rdi + ALL_R15], rcx
    
    ; Restore interrupt frame
    mov rcx, [rbx + process_t.rip]
    mov [rdi + 136], rcx
    mov rcx, [rbx + process_t.cs]
    mov [rdi + 144], rcx
    mov rcx, [rbx + process_t.rflags]
    mov [rdi + 152], rcx
    mov rcx, [rbx + process_t.rsp]
    mov [rdi + 160], rcx
    mov rcx, [rbx + process_t.ss]
    mov [rdi + 168], rcx

    ; Update TSS.RSP0
    lea rcx, [tss64]
    mov rdx, [rbx + process_t.kernel_rsp]
    mov [rcx + 4], rdx
    mov rdx, [rbx + process_t.cr3]
    test rdx, rdx
    jz .skip_cr3
    mov cr3, rdx
.skip_cr3:
    
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; --- process_schedule ---
; Priority-aware scheduler (Stage 0 of the priority manager).
; Picks the highest-priority READY process; round-robins within a priority level
; by scanning candidates in rotation order starting just after the current PID
; and keeping the FIRST (earliest-in-rotation) process at the maximum priority.
; The currently-RUNNING process is also a candidate (so a lone running proc keeps
; running, and an equal-or-lower-priority newcomer does not needlessly preempt).
; Returns: RAX = chosen PID, or -1 if nothing is runnable.
;
; NOTE: replaces the old round-robin which masked with (MAX_PROCESSES-1); that is
; only correct for a power-of-two pool and MAX_PROCESSES is 12. This version uses
; a real modulo (subtract-wrap) so every slot is considered.
FN_BEGIN process_schedule, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov r8d, [current_process_id]   ; r8d = current pid (-1 if none)
    mov r9d, -1                     ; r9d = best pid found
    mov esi, -1                     ; esi = best priority (signed; PRIO_MIN=0)

    xor ecx, ecx                    ; ecx = rotation offset 0..MAX_PROCESSES-1
.ps_loop:
    cmp ecx, MAX_PROCESSES
    jge .ps_decide

    ; candidate index edx = (current + 1 + offset) mod MAX_PROCESSES.
    ; When there is no current process, scan plain 0..N-1.
    cmp r8d, -1
    je .ps_no_cur
    lea edx, [r8d + 1]
    add edx, ecx
    jmp .ps_wrap
.ps_no_cur:
    mov edx, ecx
.ps_wrap:
    cmp edx, MAX_PROCESSES
    jl .ps_idx_ready
    sub edx, MAX_PROCESSES
    jmp .ps_wrap
.ps_idx_ready:
    mov eax, edx
    imul rax, rax, 512
    add rax, PROCESS_POOL           ; rax = candidate PCB
    mov edi, [rax + process_t.state]
    cmp edi, 1                      ; READY -> eligible
    je .ps_eligible
    cmp edi, 2                      ; RUNNING -> eligible only if it is current
    jne .ps_next
    cmp edx, r8d
    jne .ps_next
.ps_eligible:
    mov edi, [rax + process_t.priority]
    cmp edi, esi
    jle .ps_next                    ; strictly-greater wins -> keeps round-robin
    mov esi, edi
    mov r9d, edx
.ps_next:
    inc ecx
    jmp .ps_loop

.ps_decide:
    cmp r9d, -1
    je .ps_none

    ; Mark the outgoing process READY if it was RUNNING and is being switched out.
    cmp r8d, -1
    je .ps_set_new
    cmp r8d, r9d
    je .ps_set_new                  ; same proc keeps running; no state churn
    mov eax, r8d
    imul rax, rax, 512
    add rax, PROCESS_POOL
    cmp dword [rax + process_t.state], 2
    jne .ps_set_new
    mov dword [rax + process_t.state], 1
.ps_set_new:
    mov [current_process_id], r9d
    mov eax, r9d
    imul rax, rax, 512
    add rax, PROCESS_POOL
    mov dword [rax + process_t.state], 2   ; chosen -> RUNNING
    mov eax, r9d
    jmp .ps_done
.ps_none:
    mov eax, -1
.ps_done:
    movsxd rax, eax
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

FN_BEGIN proc_is_active, 0, 0, FN_RET_SCALAR
    ; EDI = PID
    push rbx
    mov rax, rdi
    imul rax, 512
    add rax, PROCESS_POOL
    mov eax, [rax + process_t.state]
    cmp eax, 0 ; EMPTY
    setne al
    movzx eax, al
    pop rbx
    ret

FN_BEGIN process_kill_window, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    xor ecx, ecx
.pkw_loop:
    cmp ecx, MAX_PROCESSES
    jge .pkw_done
    imul rbx, rcx, 512
    add rbx, PROCESS_POOL
    cmp dword [rbx + process_t.state], 0
    je .pkw_next
    cmp dword [rbx + process_t.win_id], edi
    jne .pkw_next
    mov dword [rbx + process_t.state], 4
    cmp dword [current_process_id], ecx
    jne .pkw_done
    mov dword [current_process_id], 0
    mov dword [abs PROCESS_POOL + process_t.state], 2
    jmp .pkw_done
.pkw_next:
    inc ecx
    jmp .pkw_loop
.pkw_done:
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Stage 1 SMP placement helpers
; ============================================================================
; These manage *which core* a process is permitted to run on, and pick a good
; home core from a given mask. They do not (yet) move execution between cores;
; dispatching is added in Stage 2. Until then `home_core` is informational and
; surfaces in task manager so we can see the placer's intent.
;
; Mask convention: bit i set <=> core i permitted. System cores (mask
; SMP_SYSTEM_CORE_MASK) are stripped from any app mask before placement so a
; misbehaving app can never request core 0 or 1.
; ============================================================================

extern smp_alive_cores
