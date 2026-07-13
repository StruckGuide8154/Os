; ============================================================================
; syscall_dispatch_core.inc
; syscall_entry dispatch core: prologue, slot setup, dispatch jump, validate/cap/rate/invalid/print/exit
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
%ifndef SC_SLOT_FROM_RIP_DEFINED
%define SC_SLOT_FROM_RIP_DEFINED
; SC_SLOT_FROM_RIP <reg64>
;   reg <- the app slot index derived from the user return RIP in rcx (0 when
;   rcx is outside every app arena). Pure register arithmetic - touches no
;   memory but the two arena-bound globals - so it is safe to use while still
;   on the user stack, before any trusted kernel stack exists. Clobbers only
;   the named register and EFLAGS.
%macro SC_SLOT_FROM_RIP 1
    mov %1, rcx
    sub %1, [rel l3_app_arena_base_v]
    jc %%sc_slot_zero
    cmp %1, [rel l3_app_arena_size_v]
    jae %%sc_slot_zero
    shr %1, 21
    jmp %%sc_slot_done
%%sc_slot_zero:
    xor %1, %1
%%sc_slot_done:
%endmacro
%endif
    ; ------------------------------------------------------------------------
    ; SYSCALL lands at CPL0 with rsp STILL pointing at the user-controlled
    ; stack. The previous prologue preserved registers with `push` right here -
    ; but a hostile app picks rsp, so every such push was a kernel-mode store
    ; to an attacker-selected address (CWE-787 write-what-where / CWE-123). We
    ; now record the user context into this slot's L3 runtime record and switch
    ; to the trusted per-slot kernel syscall stack BEFORE the first push, so no
    ; CPL0 write ever lands on user-chosen memory. Do not use rbp as bootstrap
    ; scratch: generated GritHL code uses rbp as its frame pointer across syscall
    ; wrappers, and clobbering it makes the post-syscall function epilogue return
    ; through spilled argument values.
    ; ------------------------------------------------------------------------
    KPTI_SWITCH_TO_KERNEL_CR3 rbx        ; reach kernel CR3 before any kernel read
    SC_SLOT_FROM_RIP rbx                 ; rbx = slot id from user RIP (rcx)
    mov r15d, ebx                        ; r15 = slot id (live through dispatch)
    imul rbx, L3_RT_SIZE
    lea rbx, [rel l3_runtime + rbx]      ; rbx = &l3_runtime[slot]
    mov [rbx + L3_RT_USER_RSP], rsp
    mov [rbx + L3_RT_SLOT], r15d
    mov [rbx + L3_RT_USER_RIP], rcx
    mov [rbx + L3_RT_USER_RFLAGS], r11
    mov [rbx + L3_RT_SYSCALL_NUM], rax
    mov [rbx + L3_RT_ARG0], rdi
    mov [rbx + L3_RT_ARG1], rsi
    mov [rbx + L3_RT_USER_RDX], rdx
    mov [rbx + L3_RT_USER_R8], r8
    mov [rbx + L3_RT_USER_R9], r9
    mov [rbx + L3_RT_USER_R10], r10
    mov rsp, r15
    inc rsp                              ; rsp = slot + 1
    imul rsp, rsp, L3_SYSCALL_STACK_STRIDE
    mov rbx, L3_SYSCALL_STACK_ADDR       ; 64-bit base (slot re-derived below)
    add rsp, rbx                         ; top = base + (slot+1)*STRIDE
    and rsp, -16                         ; 16-byte ABI alignment; now on kernel stack

    ; Kernel-entry FS/GS sanitization (security_todo.md sec 3). Load kernel data
    ; selectors into ds/es/fs/gs so no user-controlled selector is in force
    ; while in ring 0; under -dENABLE_FSGS_MSR_SCRUB also zeroes the FS/GS base
    ; MSRs. Clobbers ax (and rcx/rdx under the MSR scrub), so the full user
    ; context is reloaded from l3_runtime below before PUSH_ALL.
    SANITIZE_SEG_KERNEL_ENTRY

    ; Syscall footer: [rsp+16]=alignment pad, [rsp+8]=stack canary, [rsp]=slot.
    ; The canary is checked at every syscall exit before SYSRET / app return; a
    ; mismatch traps to kernel_panic_canary. The slot id stays at [rsp] for all
    ; existing readers, while the pad keeps PUSH_ALL's frame 16-byte aligned.
    sub rsp, 8                                  ; alignment pad
    push qword [rel kernel_canary]              ; canary at [rsp + 8] (after slot push)
    push r15                                    ; Slot for validation and return.

    ; Reload the user context PUSH_ALL captures (SANITIZE_SEG and the optional
    ; MSR scrub may have clobbered ax/rcx/rdx). rbx is reload scratch.
    push rbx
    mov ebx, [rsp + 8]
    imul rbx, L3_RT_SIZE
    lea rdx, [rel l3_runtime]
    add rbx, rdx
    mov rcx, [rbx + L3_RT_USER_RIP]
    mov r11, [rbx + L3_RT_USER_RFLAGS]
    mov rax, [rbx + L3_RT_SYSCALL_NUM]
    mov rdi, [rbx + L3_RT_ARG0]
    mov rsi, [rbx + L3_RT_ARG1]
    mov rdx, [rbx + L3_RT_USER_RDX]
    mov r8,  [rbx + L3_RT_USER_R8]
    mov r9,  [rbx + L3_RT_USER_R9]
    mov r10, [rbx + L3_RT_USER_R10]
    pop rbx
    mov r15d, [rsp]

    cld
    PUSH_ALL

    ; Caller provenance is authoritative. An RCX outside every app arena is
    ; never mapped to slot/class 0: reject before tracing, permutation, cap
    ; checks, or handler dispatch can consume a default slot identity.
    mov rdx, rcx
    sub rdx, [rel l3_app_arena_base_v]
    jc .sc_invalid
    cmp rdx, [rel l3_app_arena_size_v]
    jae .sc_invalid

    ; Always-on per-syscall trace ring + per-slot histogram (security_todo.md
    ; §11). Promotes the old compile-gated ENABLE_TRACE serial logger to a cheap
    ; in-memory, slot-isolated record of the last SC_TRACE_RING_ENTRIES calls
    ; per slot, plus a per-slot syscall-number histogram. The ring gives a
    ; crash/panic the faulting slot's recent call sequence; the histogram is the
    ; data source the §11 anomaly detector (sc_anomaly_scan_all, run on the pit
    ; cadence) scans for a syscall mix that deviates from the app's profile.
    ; Inline (no CALL), a handful of instructions; clobbers only rax/rbx/rcx/
    ; rdx/r8, all reloaded from the saved PUSH_ALL frame before the handler runs.
    SC_TRACE_APPEND
    ; SC_TRACE_APPEND leaves rax = the user RIP (its last write, for the ring's
    ; forensic anchor). Everything below - the ENABLE_USER_DEBUG_SYSCALL 's'
    ; trace, the bounds check (cmp rax, syscall_table_count) and the per-slot
    ; permutation - keys off rax as the SYSCALL NUMBER, so reload it from the
    ; saved frame now. Without this, every syscall's number is replaced by its
    ; return RIP -> always out-of-range -> -1, and no app syscall ever dispatches
    ; (blank windows). The macro's "reloaded before the handler" note referred to
    ; the arg-register reloads at the dispatch tail, which are far too late.
    mov rax, [rsp + ALL_RAX]
    DBG_EVT EVT_SYSCALL_ENTER, r15, rax, rcx, 0, 0, 0, 0

%ifdef ENABLE_DEBUG_SERIAL
    ; No-progress / spin watchdog (FE/FH spam class). A slot wedged in a tight
    ; syscall loop that makes no progress - issuing the SAME syscall with the
    ; SAME (arg0,arg1) over and over (e.g. SYS_FS_ENTRY(0) always returning
    ; handle 0) - would otherwise just spin quietly, visible only as serial spam.
    ; Here we compare this call's (number,arg0,arg1) signature against the slot's
    ; last-issued one: identical -> bump a per-slot repeat counter; different ->
    ; reset it and store the new signature. When the counter crosses
    ; SC_PROGRESS_LIMIT we emit ONE structured diagnostic (slot, syscall number,
    ; args, faulting user RIP, repeat count) via the DBG_EVT ring and serial, then
    ; re-arm (counter back to 0) so a still-wedged loop logs again every N calls
    ; rather than flooding. Fail-soft: log only by default; -dENABLE_PROGRESS_WD_BREAK
    ; additionally breaks the loop by forcing this call to return -1. Generic over
    ; all slots, no per-app instrumentation. Whole block is absent in release.
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    mov rax, [rsp + 48 + ALL_RAX]       ; syscall number
    mov rcx, [rsp + 48 + ALL_RDI]       ; arg0
    mov rdx, [rsp + 48 + ALL_RSI]       ; arg1
    movzx ebx, r15b                     ; slot id (table index)
    lea r8, [rel sc_wd_last_num]
    cmp [r8 + rbx*8], rax
    jne .pwd_reset
    lea r8, [rel sc_wd_last_a0]
    cmp [r8 + rbx*8], rcx
    jne .pwd_reset
    lea r8, [rel sc_wd_last_a1]
    cmp [r8 + rbx*8], rdx
    jne .pwd_reset
    ; Same signature as last time for this slot -> bump the repeat counter.
    lea r8, [rel sc_wd_repeat]
    mov r9d, [r8 + rbx*4]
    inc r9d
    mov [r8 + rbx*4], r9d
    cmp r9d, SC_PROGRESS_LIMIT
    jb .pwd_done
    ; Threshold reached: this slot has made no progress for SC_PROGRESS_LIMIT
    ; identical calls. Emit a structured diagnostic, then re-arm.
    mov dword [r8 + rbx*4], 0
    mov r8, [rsp + 48 + ALL_RCX]        ; faulting user RIP
    DBG_EVT_IMPORTANT EVT_NOPROGRESS, r15, rax, rcx, rdx, r8, r9, 0
    ; Serial line: "NOPRG s<slot> n<num> a<arg0>/<arg1> r<rip> x<count>".
    push rdi                            ; ser_print_hex64 takes rdi, clobbers caller-saved
    SER 'N'
    SER 'O'
    SER 'P'
    SER 'R'
    SER 'G'
    SER ' '
    SER 's'
    movzx edi, r15b
    call ser_print_hex64
    SER ' '
    SER 'n'
    mov rdi, [rsp + 56 + ALL_RAX]       ; +8 for the pushed rdi
    call ser_print_hex64
    SER ' '
    SER 'a'
    mov rdi, [rsp + 56 + ALL_RDI]
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 56 + ALL_RSI]
    call ser_print_hex64
    SER ' '
    SER 'r'
    mov rdi, [rsp + 56 + ALL_RCX]
    call ser_print_hex64
    SER ' '
    SER 'x'
    mov edi, SC_PROGRESS_LIMIT
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
%ifdef ENABLE_PROGRESS_WD_BREAK
    ; Optional loop-break: force the wedged call to return -1 so the app's loop
    ; observes a changed result and can fall out of it. Unwind our scratch frame
    ; first, then set the saved return value and take the normal exit.
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    mov qword [rsp + ALL_RAX], -1
    jmp .done
%endif
    jmp .pwd_done
.pwd_reset:
    ; Different signature -> progress was made; store the new one and reset count.
    lea r8, [rel sc_wd_last_num]
    mov [r8 + rbx*8], rax
    lea r8, [rel sc_wd_last_a0]
    mov [r8 + rbx*8], rcx
    lea r8, [rel sc_wd_last_a1]
    mov [r8 + rbx*8], rdx
    lea r8, [rel sc_wd_repeat]
    mov dword [r8 + rbx*4], 0
.pwd_done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
%endif

%ifdef ENABLE_TRACE
    mov rdi, [rsp + ALL_RAX]
    mov esi, r15d
    mov rdx, [rsp + ALL_RDI]
    mov ecx, TRACE_FLAG_SYSCALL_ENTER
    call trace_syscall
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
%endif

    inc qword [syscall_count]
%ifdef ENABLE_USER_DEBUG_SYSCALL
    push rax
    SER 's'
    mov rdi, rax
    and edi, 0x3F
    add edi, '0'
    mov dx, 0x3F8
    mov ax, di
    out dx, al
    pop rax
    cmp qword [syscall_count], 8
    ja .dispatch
    push rax
    push rcx
    push rdi
    SER 'N'
    mov rdi, rax
    call ser_print_hex64
    SER '@'
    mov rdi, rcx
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    pop rcx
    pop rax
%endif

.dispatch:
%ifdef ENABLE_DEBUG_SERIAL
    ; Validator post-condition (§2, debug build only): clear this slot's
    ; snapshot-valid flag at the start of every dispatch so only a fully
    ; validated syscall (which re-sets it after sc_validate_from_table passes)
    ; is rechecked at return. Reject and non-validated paths leave it cleared,
    ; so .done skips them. rax holds the syscall number here - preserve it.
    push rax
    push rcx
    lea rcx, [rel sc_postcond_valid]
    movzx eax, r15b
    mov byte [rcx + rax], 0
    pop rcx
    pop rax
%endif
    cmp rax, syscall_table_count
    jae .sc_invalid
%ifdef ENABLE_SYSCALL_PERM
    ; Heterogeneous syscall numbering per slot (security_todo.md §12). rax holds
    ; the APP-VISIBLE syscall number (bounds-checked < syscall_table_count just
    ; above). Translate it to the REAL syscall_table row through this slot's
    ; inverse permutation, so a static exploit blob baked against one layout
    ; lands on the wrong handler in another launch. The forward permutation is
    ; what a (future) loader-side rewrite would apply to the app's SYS_*
    ; constants; sc_slot_perm_inv[] is the kernel's inverse, recovering the row.
    ;
    ; CONSTANT-TIME: a single indexed load, no data-dependent branch on the
    ; syscall number (consistent with the constant-time arg-loader, §2). The
    ; lfence-before-indirect-jmp Spectre-v2 barrier downstream is untouched.
    ;
    ; The permutation is generated AND baked into the slot's blob exactly once,
    ; by the loader (l3_copy_app_blob_to_slot -> sc_slot_perm_generate then
    ; sc_slot_perm_apply_blob), before the app can run. The dispatcher is a pure
    ; CONSUMER: it must never (re)generate here. A dispatch-path generate would
    ; reseed from a fresh RDTSC and produce an inverse that no longer matches the
    ; forward numbers already baked into the running blob -> a non-returning
    ; syscall (SYS_APP_DONE) misroutes to a returning one and the app #UDs on its
    ; trampoline `ud2`. We apply the inverse ONLY once the loader has COMMITTED
    ; this slot (sc_slot_perm_committed[slot]==1, published after every immediate
    ; is rewritten). Until then the blob holds RAW numbers, so identity (rax
    ; unchanged) is the correct mapping -- which is also exactly the slot-0 /
    ; never-baked case. OFF by default -> this whole block is absent.
    push rcx
    push rdx
    lea rdx, [rel sc_slot_perm_committed]
    movzx ecx, r15b
    cmp byte [rdx + rcx], 0
    je .sc_perm_done                    ; not committed -> raw blob -> identity
    movzx ecx, r15b
    imul ecx, ecx, syscall_table_count  ; slot's inverse-table base
    add rcx, rax                        ; + app-visible number = flat index
    lea rdx, [rel sc_slot_perm_inv]
    movzx eax, byte [rdx + rcx]         ; eax = real syscall_table row
.sc_perm_done:
    pop rdx
    pop rcx
    ; Re-publish the REAL number into the saved frame so every downstream gate
    ; (cap/allowlist bitmap, rate, strike, post-condition) keys off the real row,
    ; not the app-visible one. The trace ring (appended pre-dispatch) keeps the
    ; app-visible value, which is the number the app actually issued.
    mov [rsp + ALL_RAX], rax
%endif
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (click callback diagnosis): while a WM click callback is active,
    ; emit every syscall with the click context that caused it. This is aimed at
    ; quickly separating "bad GritHL callback/syscall args" from lower-level
    ; canary fallout without tracing the canary path itself.
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    cmp byte [rel click_debug_active], 0
    je .clk_sys_done
    SER 'C'
    SER 'L'
    SER 'K'
    SER 'S'
    SER ' '
    SER 'q'
    mov rdi, [rel click_debug_seq]
    call ser_print_hex64
    SER ' '
    SER 's'
    movzx edi, r15b
    call ser_print_hex64
    SER ' '
    SER 'n'
    mov rdi, [rsp + 64 + ALL_RAX]       ; real syscall number after permutation
    call ser_print_hex64
    SER ' '
    SER 'r'
    mov rdi, [rsp + 64 + ALL_RCX]       ; user RIP after SYSCALL
    call ser_print_hex64
    SER ' '
    SER 'a'
    mov rdi, [rsp + 64 + ALL_RDI]
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 64 + ALL_RSI]
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 64 + ALL_RDX]
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 64 + ALL_R8]
    call ser_print_hex64
    SER '/'
    mov rdi, [rsp + 64 + ALL_R9]
    call ser_print_hex64
    SER ' '
    SER 'c'
    mov rdi, [rel click_debug_client_x]
    call ser_print_hex64
    SER '/'
    mov rdi, [rel click_debug_client_y]
    call ser_print_hex64
    SER ' '
    SER 'w'
    mov rdi, [rel click_debug_win]
    call ser_print_hex64
    SER ' '
    SER 't'
    mov rdi, [rel click_debug_target]
    call ser_print_hex64
    SER 13
    SER 10
.clk_sys_done:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endif
    mov rbx, rax
    ; SYSCALL_ENTRY_SIZE == 24, so rbx *= 24 via (rbx + rbx*2) << 3.
    lea rbx, [rbx + rbx*2]
    shl rbx, 3
    lea r12, [rel syscall_table]
    add r12, rbx
    ; Capability gate: reject before argument validation so a sandboxed app
    ; can't even probe pointer behaviour of a forbidden syscall. R15 is the
    ; current slot id. slot_cap_mask[] is DEFAULT-DENY: every slot boots at
    ; CAP_CORE (syscall_data.ghl), and the loader narrows it to the app's
    ; manifest (or the CAP_CORE floor for an unknown app_id) BEFORE the app runs
    ; its first instruction - see kernel_apply_app_manifest / APPLY_MANIFEST.
    ; A slot never runs at CAP_ALL; manifest enforcement does not depend on the
    ; app voluntarily calling SYS_APP_DECLARE_MANIFEST.
    movzx eax, word [r12 + SYSCALL_CAP_OFF]   ; 16-bit required cap tag
    test ax, ax
    jz .sc_cap_reject               ; untagged entry = misconfiguration; deny
    ; Load this slot's 16-bit cap mask: low byte from slot_cap_mask, high byte
    ; from the parallel slot_cap_mask_hi (CAP_FS_READ/WRITE/DELETE live there).
    ; dx = full mask.
    movzx ecx, r15b
    lea rdx, [rel slot_cap_mask]
    movzx edx, byte [rdx + rcx]     ; mask low byte -> dl
    lea r8, [rel slot_cap_mask_hi]
    movzx r8d, byte [r8 + rcx]
    shl r8d, 8
    or edx, r8d                     ; dx = 16-bit mask (dh = high byte)
    ; Time-of-check authentication of the cap mask. slot_cap_mask[*] are plain
    ; kernel data; any kernel-write bug that flips a bit there would silently
    ; widen this slot's capabilities. Before trusting dx we call cap_mask_verify,
    ; which recomputes this slot's 128-bit MAC over (slot, full 16-bit mask)
    ; keyed by kernel_canary and compares ALL 16 stored bytes (was an 8-bit tag -
    ; only 256 values - which a repeatable corrupt-and-retry primitive could
    ; forge). We pass dx, the exact mask we are about to AND, so the value that
    ; is authenticated is the value that is consulted. A mismatch means the mask
    ; was tampered after its last legitimate write, so we kill only this slot on
    ; the CANARY path rather than dispatch on a forged mask. Done before the cap
    ; AND so a widened mask is never even consulted. cap_mask_verify preserves
    ; rcx/rdx (mask) and r12/r15; result in rax. rdi/rsi are free scratch here
    ; (the handler's arg regs are reloaded from the PUSH_ALL frame further down).
    movzx edi, r15b                 ; slot
    mov esi, edx                    ; full 16-bit mask (dl | dh<<8)
    call cap_mask_verify
    test eax, eax
    jz .sc_cap_tamper
    movzx eax, word [r12 + SYSCALL_CAP_OFF]   ; restore required cap word
    and dx, ax
    cmp dx, ax                      ; every required bit present in the mask?
    jne .sc_cap_reject
    ; Per-syscall allowlist gate (security_todo.md §2, "Manifest declares
    ; syscall set, not just cap bits"). The coarse cap mask above only proves
    ; this syscall's *domain* is granted; slot_syscall_allow[] is a finer
    ; per-slot bitmap (one bit per syscall number) so an app is confined to the
    ; exact call set its manifest implies - e.g. Notepad keeps CAP_FS but its
    ; bitmap clears SYS_FS_DELETE. Undeclared/legacy slots have an all-ones
    ; bitmap (BSS 0xFF fill), so this gate is a no-op until a manifest narrows
    ; it. Checked after the cap gate so a forbidden-domain call still rejects
    ; for the cap reason, but before rate/arg validation so a denied syscall
    ; can't probe pointer behaviour. r8/r9/rcx scratch here (rcx reloaded by
    ; the rate gate below); rax=cap bit and rdx=mask are dead past this point.
    mov r9, [rsp + ALL_RAX]             ; syscall number (validated < count above)
    mov r8, r9
    shr r8, 3                           ; byte index within the bitmap
    movzx ecx, r15b
    imul ecx, ecx, SC_ALLOW_BYTES       ; slot's bitmap base offset
    add r8, rcx
    lea rcx, [rel slot_syscall_allow]
    movzx r8d, byte [rcx + r8]          ; the bitmap byte holding this syscall's bit
    and r9d, 7                          ; bit position 0..7
    bt r8d, r9d
    jnc .sc_cap_reject                  ; bit clear == syscall not in slot's set
    ; Rate-limit gate: spend one token from this slot's per-tick bucket. The
    ; bucket is refilled to SC_BUDGET_PER_TICK by pit_handler each timer tick;
    ; a slot that has drained it this tick is throttled (deny -1) so a fuzzer
    ; can't issue millions of calls between ticks. Checked after the cap gate
    ; so a forbidden syscall is still rejected for the right reason, but before
    ; argument validation so a throttled slot can't probe pointer behaviour.
    ;
    ; GUI-heavy redraw paths use a separate per-frame/tick bucket. They no
    ; longer drain the general syscall budget, but they are bounded.
    test word [r12 + SYSCALL_CAP_OFF], CAP_GUI
    jz .sc_rate_non_gui
    movzx ecx, r15b
    lea rdx, [rel slot_gui_budget]
    movzx eax, word [rdx + rcx*2]
    test eax, eax
    jz .sc_rate_reject
    dec eax
    mov [rdx + rcx*2], ax
    jmp .sc_rate_ok
.sc_rate_non_gui:
    movzx ecx, r15b
    lea rdx, [rel slot_sc_budget]
    movzx eax, word [rdx + rcx*2]
    test eax, eax
    jz .sc_rate_reject
    dec eax
    mov [rdx + rcx*2], ax
.sc_rate_ok:
    call sc_validate_from_table
    test eax, eax
    jz .sc_validate_reject
%ifdef ENABLE_DEBUG_SERIAL
    ; Validator post-condition snapshot (§2, debug build only). The arg
    ; registers were validated above; copy the 6 saved arg qwords from the
    ; PUSH_ALL frame into this slot's snapshot buffer so the return path can
    ; detect a handler that scribbles its own saved-frame args (handler-side
    ; TOCTOU on the validated values). Done before the handler runs and before
    ; the arg-register reloads below, so it captures exactly what was validated.
    ; rax/rcx clobbered here are reloaded from the frame by the reloads below.
    movzx eax, r15b
    imul eax, eax, 48                    ; 6 qwords * 8 = 48 bytes per slot
    lea rcx, [rel sc_postcond_args]
    add rcx, rax
    mov rax, [rsp + ALL_RDI]
    mov [rcx + 0], rax
    mov rax, [rsp + ALL_RSI]
    mov [rcx + 8], rax
    mov rax, [rsp + ALL_RDX]
    mov [rcx + 16], rax
    mov rax, [rsp + ALL_R10]
    mov [rcx + 24], rax
    mov rax, [rsp + ALL_R8]
    mov [rcx + 32], rax
    mov rax, [rsp + ALL_R9]
    mov [rcx + 40], rax
    lea rcx, [rel sc_postcond_valid]
    movzx eax, r15b
    mov byte [rcx + rax], 1              ; arm the return-path recheck for this slot
%endif
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    mov r10, [rsp + ALL_R10]
    mov r8,  [rsp + ALL_R8]
    mov r9,  [rsp + ALL_R9]
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (blank-app diagnosis): log the *set* of syscalls each app slot (>=2)
    ; successfully dispatches, once per number, so we can see whether a blank app
    ; ever issues GUI draw calls at all. All arg regs preserved across the trace.
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov rax, [rsp + 64 + ALL_RAX]           ; syscall number (8 pushes = 64 bytes)
    cmp rax, 256
    jae .xdsp_done                          ; bitmap only covers 0..255
    mov rcx, rax
    shr rcx, 3                              ; byte index
    lea r9, [rel xdsp_seen_bitmap]
    movzx r8d, byte [r9 + rcx]
    mov edx, eax
    and edx, 7                             ; bit position
    bt r8d, edx
    jc .xdsp_done                          ; already logged this number
    bts r8d, edx
    mov [r9 + rcx], r8b
    SER 'X'
    SER 'D'
    SER 'S'
    SER 'P'
    SER ' '
    SER 's'
    movzx edi, r15b
    call ser_print_hex64                    ; slot
    SER ' '
    SER 'n'
    mov rdi, [rsp + 64 + ALL_RAX]           ; syscall number
    call ser_print_hex64
    SER 13
    SER 10
.xdsp_done:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
%endif
    lfence                                  ; Spectre-v2 barrier: serialize speculation before the dispatcher's indirect branch
    jmp qword [r12 + SYSCALL_HANDLER_OFF]

.sc_validate_reject:
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (blank-app diagnosis): an argument-validation reject also returns -1
    ; and silently drops a draw call -> white window. Same trace shape as XCAP
    ; (shares the 256-line cap counter): slot, syscall number, cap tag, mask.
    push rax
    push rcx
    push rdx
    push rdi
    mov eax, [rel xcap_log_count]
    cmp eax, 256
    jae .xval_skip
    inc dword [rel xcap_log_count]
    SER 'X'
    SER 'V'
    SER 'A'
    SER 'L'
    SER ' '
    SER 's'
    movzx edi, r15b
    call ser_print_hex64                 ; slot
    SER ' '
    SER 'n'
    mov rdi, [rsp + 32 + ALL_RAX]        ; syscall number (frame below our 4 pushes)
    call ser_print_hex64
    SER ' '
    SER 't'
    movzx edi, byte [r12 + SYSCALL_CAP_OFF]   ; this syscall's cap tag
    call ser_print_hex64
    SER ' '
    SER 'm'
    lea rcx, [rel slot_cap_mask]
    movzx edx, r15b
    movzx edi, byte [rcx + rdx]          ; slot's current cap mask
    call ser_print_hex64
    SER 13
    SER 10
.xval_skip:
    pop rdi
    pop rdx
    pop rcx
    pop rax
%endif
    call sc_record_strike                   ; §12: count this security reject; may kill the slot
%ifdef ENABLE_TRACE
    mov rdi, [rsp + ALL_RAX]
    mov esi, r15d
    mov rdx, [rsp + ALL_RDI]
    mov ecx, TRACE_FLAG_VALIDATE_FAIL
    call trace_syscall
%endif
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_cap_reject:
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (blank-app diagnosis): a denied draw/window syscall is what paints an
    ; app window blank/white. Log slot, syscall number, the syscall's required
    ; cap tag, and the slot's current mask so we can see GUI calls (tag=0x02)
    ; being rejected and why. Capped at 256 lines to avoid flooding. r12 still
    ; points at this syscall's table row; r15 = slot. Remove once white-window
    ; root cause is fixed.
    push rax
    push rcx
    push rdx
    push rdi
    mov eax, [rel xcap_log_count]
    cmp eax, 256
    jae .xcap_skip
    inc dword [rel xcap_log_count]
    SER 'X'
    SER 'C'
    SER 'A'
    SER 'P'
    SER ' '
    SER 's'
    movzx edi, r15b
    call ser_print_hex64                 ; slot
    SER ' '
    SER 'n'
    mov rdi, [rsp + 32 + ALL_RAX]        ; syscall number (frame below our 4 pushes)
    call ser_print_hex64
    SER ' '
    SER 't'
    movzx edi, byte [r12 + SYSCALL_CAP_OFF]   ; this syscall's required cap tag
    call ser_print_hex64
    SER ' '
    SER 'm'
    lea rcx, [rel slot_cap_mask]
    movzx edx, r15b
    movzx edi, byte [rcx + rdx]          ; slot's current cap mask
    call ser_print_hex64
    SER 13
    SER 10
.xcap_skip:
    pop rdi
    pop rdx
    pop rcx
    pop rax
%endif
    call sc_record_strike                   ; §12: count this security reject; may kill the slot
%ifdef ENABLE_TRACE
    mov rdi, [rsp + ALL_RAX]
    mov esi, r15d
    mov rdx, [rsp + ALL_RDI]
    mov ecx, TRACE_FLAG_VALIDATE_FAIL
    call trace_syscall
%endif
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; Cap-mask authenticator mismatch: slot_cap_mask[r15] no longer matches its
; HMAC, so the mask was corrupted after the last legitimate (re-stamped)
; write. This is a security-fatal condition (a deny is not enough - the mask
; the kernel can see is untrustworthy. This is ATTRIBUTABLE to the current slot
; (r15) on the syscall path, so instead of halting the whole machine via
; kernel_panic_canary (which would let one tenant DoS every tenant) we kill
; ONLY this slot and take the normal -1/.done exit. Fail-closed: the slot's
; window/handles are reclaimed so it can't continue on the forged mask.
.sc_cap_tamper:
    mov edx, 0x43415054                  ; CAPT: slot capability HMAC tamper
    call sc_slot_integrity_kill          ; per-slot teardown (not global halt)
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_rate_reject:
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, '#'
    out dx, al
    mov al, '0'
    add al, r15b
    out dx, al
    pop rdx
    pop rax
    call sc_record_strike                   ; §12: count this security reject; may kill the slot
%ifdef ENABLE_TRACE
    mov rdi, [rsp + ALL_RAX]
    mov esi, r15d
    mov rdx, [rsp + ALL_RDI]
    mov ecx, TRACE_FLAG_VALIDATE_FAIL
    call trace_syscall
%endif
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_invalid:
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (blank-app diagnosis): an out-of-range syscall number returns -1 here
    ; *before* any cap/validate trace, so a draw issued with a bad number silently
    ; drops -> blank window. Log slot + the FULL (unmasked) number so we can see
    ; if the app's compiled syscall numbers exceed syscall_table_count. Shares the
    ; 256-line cap counter. rax = the offending number here; r15 = slot.
    push rax
    push rcx
    push rdx
    push rdi
    mov ecx, [rel xcap_log_count]
    cmp ecx, 256
    jae .xinv_skip
    inc dword [rel xcap_log_count]
    SER 'X'
    SER 'I'
    SER 'N'
    SER 'V'
    SER ' '
    SER 's'
    movzx edi, r15b
    call ser_print_hex64                 ; slot (preserves rax)
    SER ' '
    SER 'n'
    mov rdi, rax                         ; full unmasked syscall number
    call ser_print_hex64
    SER ' '
    SER 'r'                               ; return RIP (rcx set by syscall) = site+2
    mov rdi, [rsp + 32 + ALL_RCX]        ; user rcx in saved frame (4 pushes above)
    call ser_print_hex64
    SER ' '
    SER 'b'                               ; 8 instr bytes ending just before the syscall
    mov rsi, [rsp + 32 + ALL_RCX]
    sub rsi, 10                          ; bytes [rip-10 .. rip-2): rax-load + syscall opcode
    mov rdi, [rsi]
    call ser_print_hex64
    SER 13
    SER 10
.xinv_skip:
    pop rdi
    pop rdx
    pop rcx
    pop rax
%endif
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_print:
%ifdef ENABLE_USER_DEBUG_SYSCALL
    mov rsi, SYSCALL_MAX_STR_LEN
    call sc_validate_user_cstring
    test eax, eax
    jz .sc_print_reject
    mov rsi, rdi
    call debug_print
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_print_reject:
%ifdef ENABLE_TRACE
    mov rdi, [rsp + ALL_RAX]
    mov esi, r15d
    mov rdx, [rsp + ALL_RDI]
    mov ecx, TRACE_FLAG_VALIDATE_FAIL
    call trace_syscall
%endif
    mov qword [rsp + ALL_RAX], -1
    jmp .done
%else
    mov qword [rsp + ALL_RAX], -1
    jmp .done
%endif

.sc_exit:
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done

