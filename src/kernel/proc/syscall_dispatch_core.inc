; ============================================================================
; syscall_dispatch_core.inc
; syscall_entry dispatch core: prologue, slot setup, dispatch jump, validate/cap/rate/invalid/print/exit
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
    ; SYSCALL enters CPL0 on the user stack. KPTI must switch to the kernel CR3
    ; before touching kernel data, but this preamble still uses the user stack
    ; to save state, so keep SMAP open until those saves are restored.
    USER_ACCESS_BEGIN
    push rax
    KPTI_SWITCH_TO_KERNEL_CR3 rax
    pop rax
    ; Save critical SYSCALL state into the active slot runtime before any
    ; helper calls.
    push rbx
    push rdx
    push r10
    mov rdx, rcx
    sub rdx, [rel l3_app_arena_base_v]
    jc .slot_from_global
    cmp rdx, [rel l3_app_arena_size_v]
    jae .slot_from_global
    shr rdx, 21
    mov ebx, edx
    jmp .slot_ok_entry
.slot_from_global:
    xor ebx, ebx
    jmp .slot_ok_entry
.slot_ok_entry:
    mov r10d, ebx
    imul rbx, L3_RT_SIZE
    lea rdx, [rel l3_runtime]
    add rbx, rdx
    mov [rbx + L3_RT_SLOT], r10d
    mov [rbx + L3_RT_USER_RIP], rcx
    mov [rbx + L3_RT_USER_RFLAGS], r11
    mov rdx, rsp
    add rdx, 24
    mov [rbx + L3_RT_USER_RSP], rdx
    mov [rbx + L3_RT_SYSCALL_NUM], rax
    mov [rbx + L3_RT_ARG0], rdi
    mov [rbx + L3_RT_ARG1], rsi
    mov rdx, [rsp + 8]
    mov [rbx + L3_RT_USER_RDX], rdx
    mov [rbx + L3_RT_USER_R8], r8
    mov [rbx + L3_RT_USER_R9], r9
    mov rdx, [rsp]
    mov [rbx + L3_RT_USER_R10], rdx
    pop r10
    pop rdx
    pop rbx
    USER_ACCESS_END
    ; Kernel-entry FS/GS sanitization (security_todo.md §3). Load kernel data
    ; selectors into ds/es/fs/gs so no user-controlled selector is in force
    ; while in ring 0; under -dENABLE_FSGS_MSR_SCRUB also zeroes the FS/GS base
    ; MSRs (no-op in the flat model, deterministic if FSGSBASE is ever enabled).
    ; Clobbers ax only — rcx (user RIP) and the rest of the live state survive.
    SANITIZE_SEG_KERNEL_ENTRY

    ; Switch to syscall stack without calling out while we're still on the
    ; user stack. A normal CALL would push a return address to user memory.
    mov rax, rcx
    sub rax, [rel l3_app_arena_base_v]
    jc .slot_zero_stack
    cmp rax, [rel l3_app_arena_size_v]
    jae .slot_zero_stack
    shr rax, 21
    jmp .slot_ok_stack
.slot_zero_stack:
    xor eax, eax
.slot_ok_stack:
    mov r8d, eax
    imul rax, L3_SYSCALL_STACK_STRIDE
    mov rdx, L3_SYSCALL_STACK_ADDR
    add rax, rdx
    add rax, L3_SYSCALL_STACK_STRIDE        ; top of slot i = base + (i+1)*STRIDE
    and rax, -16
    
    mov rsp, rax             ; Now on Kernel Syscall Stack
    ; Stack canary: push a 16-byte canary frame (canary + 8-byte alignment
    ; pad) before the slot id so the slot stays at [rsp] for all existing
    ; readers, while keeping PUSH_ALL's frame 16-byte aligned for callee ABI.
    ; The canary is checked at every syscall exit path before SYSRET / app
    ; return; a mismatch traps to kernel_panic_canary.
    sub rsp, 8                                  ; alignment pad
    push qword [rel kernel_canary]              ; canary at [rsp + 8] (after slot push)
    push r8                                     ; Slot for validation and return.
    
    ; Push usermode context manually so PUSH_ALL has it
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
    ; forensic anchor). Everything below — the ENABLE_USER_DEBUG_SYSCALL 's'
    ; trace, the bounds check (cmp rax, syscall_table_count) and the per-slot
    ; permutation — keys off rax as the SYSCALL NUMBER, so reload it from the
    ; saved frame now. Without this, every syscall's number is replaced by its
    ; return RIP -> always out-of-range -> -1, and no app syscall ever dispatches
    ; (blank windows). The macro's "reloaded before the handler" note referred to
    ; the arg-register reloads at the dispatch tail, which are far too late.
    mov rax, [rsp + ALL_RAX]

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
    ; so .done skips them. rax holds the syscall number here — preserve it.
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
    mov rbx, rax
    ; SYSCALL_ENTRY_SIZE == 24, so rbx *= 24 via (rbx + rbx*2) << 3.
    lea rbx, [rbx + rbx*2]
    shl rbx, 3
    lea r12, [rel syscall_table]
    add r12, rbx
    ; Capability gate: reject before argument validation so a sandboxed app
    ; can't even probe pointer behaviour of a forbidden syscall. R15 is the
    ; current slot id; slot_cap_mask[] defaults to CAP_ALL for every slot
    ; until the app declares its manifest.
    movzx eax, byte [r12 + SYSCALL_CAP_OFF]
    test al, al
    jz .sc_cap_reject               ; untagged entry = misconfiguration; deny
    lea rcx, [rel slot_cap_mask]
    movzx edx, r15b
    mov dl, [rcx + rdx]
    ; Time-of-check authentication of the cap mask. slot_cap_mask[] is plain
    ; kernel data; any kernel-write bug that flips a bit there would silently
    ; widen this slot's capabilities. Before trusting dl we recompute the
    ; per-slot HMAC (low8(kernel_canary ^ slot ^ mask ^ KDOM_CAP_MASK)) and
    ; compare it against the authenticator stamped alongside the mask. A
    ; mismatch means the mask was tampered with after the last legitimate
    ; write, so we panic on the same CANARY path as CPI corruption rather than
    ; dispatch on a forged mask. Done before the cap AND so a widened mask is
    ; never even consulted. Clobbers r8/r9 only (rax=cap bit, rcx/rdx live).
    movzx r8d, r15b                 ; slot id
    movzx eax, dl                   ; claimed mask byte (rax scratch, reloaded below)
    ; low8(kernel_canary ^ slot ^ mask ^ KDOM_CAP_MASK); same primitive and same
    ; domain (0x5C) as cap_mask_sign, so the comparison stays value-identical (§13).
    KHMAC_TAG r9, r9d, r9b, r8, rax, KDOM_CAP_MASK
    lea r8, [rel slot_cap_hmac]
    movzx eax, r15b                 ; reload slot into a scratch index reg
    add r8, rax
    movzx eax, byte [r8]            ; stored authenticator for this slot
    cmp r9b, al
    jne .sc_cap_tamper
    movzx eax, byte [r12 + SYSCALL_CAP_OFF]   ; restore cap bit (al was scratch)
    and dl, al
    cmp dl, al
    jne .sc_cap_reject
    ; Per-syscall allowlist gate (security_todo.md §2, "Manifest declares
    ; syscall set, not just cap bits"). The coarse cap mask above only proves
    ; this syscall's *domain* is granted; slot_syscall_allow[] is a finer
    ; per-slot bitmap (one bit per syscall number) so an app is confined to the
    ; exact call set its manifest implies — e.g. Notepad keeps CAP_FS but its
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
    ; GUI rendering syscalls are exempt from the budget. A single desktop/window
    ; redraw issues thousands of draw calls, and continuous content (video
    ; playback) redraws every frame, so charging them drains the bucket and the
    ; rejected draw calls leave the window painted as a blank/white frame. GUI
    ; calls are not the fuzzing/side-channel oracle the budget defends against
    ; (those are the FS/probe/WX surfaces) — their worst-case abuse is spamming
    ; the screen, which is visible and vsync-bounded, not a hidden oracle. See
    ; security_todo.md §2.
    test byte [r12 + SYSCALL_CAP_OFF], CAP_GUI
    jnz .sc_rate_ok
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
; write. This is a security-fatal condition (a deny is not enough — the mask
; the kernel can see is untrustworthy), so route it to the existing CANARY
; panic path. rdi = observed (unauthenticated) mask byte, rsi = detection RIP.
.sc_cap_tamper:
    movzx edi, dl
    lea rsi, [rel .sc_cap_tamper]
    jmp kernel_panic_canary

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

