; ============================================================================
; syscall_security.inc
; syscall security helpers: CPI sign/verify, cap mask sign/store, cap audit, slot-cap HMAC, strike/anomaly scan, trace dump, panic/shadow-stack pads
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
; ----------------------------------------------------------------------------
; CPI-lite — sign/verify the callback pointers stored in window structs at
; WIN_OFF_CLICKFN / WIN_OFF_KEYFN / WIN_OFF_DRAGFN / WIN_OFF_RCLICKFN. Same
; trick already used for WIN_OFF_USER_ARG (see .sc_wm_set_user_arg above),
; generalised so a forged callback pointer is rejected at dispatch time.
;
; Tag = low16(kernel_canary ^ &window ^ field_offset), stamped into the
; high 16 bits of the stored qword (callback pointers are kernel-image VAs
; whose top half is zero, so the room is free). Binding the offset means a
; value forged for CLICKFN can't be relocated to KEYFN, and binding &window
; means a tag captured from window A is useless in window B. An attacker
; must leak both kernel_canary and the window VA before they can forge a
; usable entry — significantly stronger than "raw write hits a code ptr".
;
; A stored qword of exactly 0 is the explicit "no handler / detach"
; sentinel: stamping a tag onto 0 would either force detach to use a magic
; token or force readers to special-case the tag-of-zero, so signing 0
; just yields 0. Real handlers should never be 0.
; ----------------------------------------------------------------------------

; cpi_sign_callback(rdi=raw_fn, rsi=&window, rdx=field_offset) -> rax=stamped.
; Clobbers only rax (rcx saved/restored internally).
global cpi_sign_callback
FN_BEGIN cpi_sign_callback, 3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), FN_RET_SCALAR
    test rdi, rdi
    jz .csc_zero
    push rcx
    mov rax, rdi
    mov rcx, 0x0000FFFFFFFFFFFF
    and rax, rcx                      ; mask the would-be tag bits
    ; tag = low16(kernel_canary ^ &window ^ field_offset) — KDOM_CPI is 0 so
    ; this is byte-identical to the former hand-written sequence (see §13).
    KHMAC_TAG rcx, ecx, cx, rsi, rdx, KDOM_CPI
    shl rcx, 48
    or rax, rcx
    pop rcx
    FN_END cpi_sign_callback
    ret
.csc_zero:
    xor eax, eax
    FN_END cpi_sign_callback
    ret

; cpi_verify_callback(rdi=stored, rsi=&window, rdx=field_offset)
;   returns rax = raw_fn pointer (top 16 bits cleared) on success,
;   or rax = 0 if stored was 0 (handler detached / never installed).
; A non-zero stored value whose tag does NOT match is a CPI violation:
; we jump to kernel_panic_canary so corruption never reaches dispatch.
; Clobbers only rax (rcx, r8 saved/restored internally) on the success path.
global cpi_verify_callback
FN_BEGIN cpi_verify_callback, 3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), FN_RET_SCALAR
    test rdi, rdi
    jz .cvc_zero
    push rcx
    push r8
    KHMAC_TAG rcx, ecx, cx, rsi, rdx, KDOM_CPI
    shl rcx, 48                       ; expected tag bits
    mov rax, rdi
    mov r8, 0xFFFF000000000000
    and rax, r8
    cmp rax, rcx
    jne .cvc_bad
    mov rax, rdi
    mov r8, 0x0000FFFFFFFFFFFF
    and rax, r8
    pop r8
    pop rcx
    FN_END cpi_verify_callback
    ret
.cvc_zero:
    xor eax, eax
    FN_END cpi_verify_callback
    ret
.cvc_bad:
    ; Pointer corruption detected. Hand the forged value to the existing
    ; canary panic path so the operator sees the same CANARY <bad> @<rip>
    ; serial trace. rdi already holds the observed bad stored qword.
    pop r8
    pop rcx
    lea rsi, [rel .cvc_bad]
    jmp kernel_panic_canary

; ----------------------------------------------------------------------------
; Cap-mask authenticator — the data-side counterpart to CPI-lite. The same
; kernel_canary key authenticates each slot's capability mask so a stray
; kernel write that widens slot_cap_mask[slot] is caught at the next dispatch
; instead of silently granting privileges. Tag = low8(kernel_canary ^ slot ^
; mask ^ KDOM_CAP_MASK); 8 bits is all the room a 1-byte mask alongside a
; 1-byte authenticator affords, but it still forces an attacker to leak the
; canary before they can forge a matching pair. The dispatcher verifies inline
; (hot path); these helpers are the single source of truth for the write side.
; ----------------------------------------------------------------------------

; cap_mask_sign(rdi=slot, rsi=mask) -> rax = authenticator byte (0..255).
; Pure function of the inputs and kernel_canary; clobbers only rax (rcx saved).
global cap_mask_sign
FN_BEGIN cap_mask_sign, 2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), FN_RET_SCALAR
    push rcx
    push r8
    movzx eax, dil                    ; slot id (low byte)
    movzx r8d, sil                    ; mask byte
    ; tag = low8(kernel_canary ^ slot ^ mask ^ KDOM_CAP_MASK). KDOM_CAP_MASK is
    ; the former CAP_HMAC_DOMAIN (0x5C) so the byte is unchanged (see §13).
    KHMAC_TAG rcx, ecx, cl, rax, r8, KDOM_CAP_MASK
    mov eax, ecx                      ; authenticator byte -> result reg
    pop r8
    pop rcx
    FN_END cap_mask_sign
    ret

; cap_mask_store(rdi=slot, rsi=mask): write slot_cap_mask[slot]=mask AND its
; authenticator slot_cap_hmac[slot] together, so the pair is always consistent.
; The single place mask writes should go through. Clobbers rax, rcx, r8.
; Caller must have already range-checked slot < MAX_WINDOWS.
global cap_mask_store
FN_BEGIN cap_mask_store, 2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), FN_RET_VOID
    call cap_mask_sign                ; rax = authenticator for (slot, mask)
    movzx r8d, dil                    ; slot index
    lea rcx, [rel slot_cap_mask]
    mov [rcx + r8], sil               ; mask byte
    lea rcx, [rel slot_cap_hmac]
    mov [rcx + r8], al                ; matching authenticator
    FN_END cap_mask_store
    ret

; ----------------------------------------------------------------------------
; cap_audit_log(dil=slot, sil=old_mask, dl=new_mask, cl=reason, r8d=app_id)
;
; Append one capability-transition record to the kernel-only audit ring
; (security_todo.md §4, "Capability transitions logged + auditable"). Called
; from every legitimate cap-mask write site (declare_manifest narrowing,
; kernel_apply_app_manifest, slot recycle) so a failure to narrow — or any
; unexpected widening — leaves a forensic trail instead of being silent.
;
; The ring is fixed-size (CAP_AUDIT_ENTRIES records of CAP_AUDIT_ENT_SIZE
; bytes); cap_audit_head is the running event count and (head & IDX_MASK) is
; the next write slot, so the ring overwrites oldest-first. Kernel-only: no
; ring-3 reader yet. Self-contained — preserves every register a caller could
; rely on so it can be dropped into any write site without clobber surprises.
FN_BEGIN cap_audit_log, 5, 0, FN_RET_VOID
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; rbx = byte offset of this record = (head & IDX_MASK) * CAP_AUDIT_ENT_SIZE
    mov eax, [rel cap_audit_head]
    mov r9d, eax                      ; r9d = seq for this record
    and eax, CAP_AUDIT_IDX_MASK
    imul ebx, eax, CAP_AUDIT_ENT_SIZE
    lea r9, [rel cap_audit_ring]
    add rbx, r9                       ; rbx -> record base
    ; reload the (clobbered) seq for the +0 field
    mov eax, [rel cap_audit_head]
    mov [rbx + 0], eax                ; +0 seq
    mov [rbx + 4], dil                ; +4 slot
    mov [rbx + 5], sil                ; +5 old_mask
    mov [rbx + 6], dl                 ; +6 new_mask
    mov [rbx + 7], cl                 ; +7 reason
    mov [rbx + 8], r8d                ; +8 app_id
    mov dword [rbx + 12], 0           ; +12 reserved
    inc dword [rel cap_audit_head]    ; advance event counter (wraps at 2^32)
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    FN_END cap_audit_log
    ret

; slot_cap_hmac_init(): stamp every slot's authenticator to match the current
; (static CAP_ALL) mask, using the now-final kernel_canary. Called once from
; kernel_main right after kernel_canary_init, before any syscall can dispatch.
; Clobbers rax, rcx, rdx, rsi, rdi, r8.
global slot_cap_hmac_init
FN_BEGIN slot_cap_hmac_init, 0, 0, FN_RET_VOID
    xor edx, edx                      ; slot index
.schi_loop:
    cmp edx, MAX_WINDOWS
    jae .schi_done
    lea rcx, [rel slot_cap_mask]
    movzx esi, byte [rcx + rdx]       ; current mask for this slot
    mov rdi, rdx                      ; slot id
    push rdx
    call cap_mask_sign                ; rax = authenticator (saves/restores rcx)
    pop rdx
    lea rcx, [rel slot_cap_hmac]
    mov [rcx + rdx], al
    inc edx
    jmp .schi_loop
.schi_done:
    FN_END slot_cap_hmac_init
    ret

; ----------------------------------------------------------------------------
; sc_record_strike - slot teardown on suspect syscall return (security_todo.md
; §12). Called from each dispatcher security-reject label (.sc_cap_reject,
; .sc_validate_reject, .sc_rate_reject) when a syscall is denied for a security
; reason. Increments this slot's strike counter; once it reaches
; SC_STRIKE_LIMIT the slot is auto-killed (the existing window/slot teardown
; path) and a CAP_AUDIT_STRIKE record is appended to the cap-transition audit
; ring, so repeated probing/fuzzing is no longer silent and cost-free.
;
; In:  r15 = current slot id (set by syscall_entry before dispatch).
; Out: nothing. The caller still sets rax=-1 and falls through to .done; if the
;      slot was killed, .done's W^X scrub + SYSRET land back in (now-recycled)
;      slot state, which is exactly the close-window outcome.
; Clobbers rax, rcx, rdx, rsi, rdi, r8 (all dead at the reject labels — they
; reload from the saved frame or set constants afterward). r15 preserved.
; ----------------------------------------------------------------------------
sc_record_strike:
    movzx ecx, r15b
    cmp ecx, MAX_WINDOWS
    jae .srs_ret                        ; defensive: never index past the array
    lea rdx, [rel slot_sc_strikes]
    movzx eax, word [rdx + rcx*2]
    inc eax
    mov [rdx + rcx*2], ax
    cmp eax, SC_STRIKE_LIMIT
    jb .srs_ret
    ; Strike limit reached. Reset the counter first so a recycled slot starts
    ; clean, then audit and tear the slot down.
    mov word [rdx + rcx*2], 0
    ; Audit the kill: old_mask = this slot's current cap mask, new_mask = 0
    ; (caps gone), reason = CAP_AUDIT_STRIKE, app_id = 0. cap_audit_log
    ; preserves every register.
    movzx edi, r15b                     ; dil = slot
    lea rcx, [rel slot_cap_mask]
    movzx eax, r15b
    mov sil, [rcx + rax]                ; sil = old_mask
    xor edx, edx                        ; dl  = new_mask = 0
    mov cl, CAP_AUDIT_STRIKE            ; cl  = reason
    xor r8d, r8d                        ; r8d = app_id = 0
    call cap_audit_log
    ; Kill the slot via the existing teardown path. For app slots the window id
    ; equals the slot id (enforced by .sc_wm_close / .sc_wm_close ownership
    ; checks), so closing window r15 reclaims this slot. wm_close_window range-
    ; checks its argument and is a no-op for an already-closed window.
    movzx edi, r15b
    call wm_close_window
.srs_ret:
    ret

; ----------------------------------------------------------------------------
; sc_anomaly_scan_all - behavioral anomaly detector on the dispatcher
; (security_todo.md §11, "Anomaly detector on the dispatcher"). Pure-software
; behavioral sandbox: it never touches the hot dispatch path. pit_handler calls
; it once every ANOMALY_SCAN_PERIOD ticks (the same coarse-cadence pattern as
; l3_code_hash_verify_all), so the per-syscall cost of the §11 machinery stays
; in the cheap inline SC_TRACE_APPEND only.
;
; It consumes the per-slot syscall histogram (sc_trace_hist[], the data source
; built by the trace ring) — NOT the ring records — so the scan is just a few
; counter reads per slot. For every LIVE slot it sums that slot's accumulated
; count over the high-risk syscall set (the CAP_WX W^X/JIT trio + SYS_FS_DELETE)
; and compares it against a per-slot budget chosen by whether the slot's manifest
; actually grants the matching capability:
;   * slot lacks the cap  -> expected rate is ZERO, so budget = ANOMALY_HIRISK_
;     DENY_BUDGET (tiny). Because SC_TRACE_APPEND bumps the histogram at dispatch
;     entry *before* the cap gate, a sandboxed Notepad slot probing SYS_WX_JIT_
;     ALIAS is counted even though every call is cap-rejected — this is the
;     "Notepad slot suddenly hammering SYS_WX_JIT_ALIAS" signal from the doc.
;   * slot holds the cap  -> budget = ANOMALY_HIRISK_HOLD_BUDGET (a real JIT app
;     may legitimately use the surface, but a flood far above sane warm-up is
;     still throttled).
; A slot over budget is driven through the EXISTING §12 strike path
; (sc_record_strike) — so excessive high-risk behaviour throttles toward the
; same SC_STRIKE_LIMIT slot-kill, with no new teardown path invented. A
; CAP_AUDIT_ANOMALY record is appended at the flagging moment so the forensic
; trail shows what tripped it, then the slot's high-risk histogram buckets are
; reset so each scan window is judged on fresh behaviour (and a slow legitimate
; app never accretes a false positive across many windows).
;
; In:  none.  Out: none.  r15 must equal the scanned slot id for the duration of
; each sc_record_strike call (it keys off r15); we set it per slot and restore
; the caller's r15 at the end. Preserves all caller regs (called from the ISR
; landing pad). Internal helper — plain label, no FN_BEGIN (matches
; sc_build_allow_bitmap). Exported so pit.asm can drive it (FN_BEGIN, which
; emits the global, matching cap_audit_log — the coverage tool requires every
; global to carry a signature).
; ----------------------------------------------------------------------------
FN_BEGIN sc_anomaly_scan_all, 0, 0, FN_RET_VOID
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r15                             ; preserve caller's slot id
    xor r10d, r10d                       ; r10d = slot index
.asa_slot:
    cmp r10d, MAX_WINDOWS
    jae .asa_done
    ; Only scan live slots — a recycled/empty slot has no tenant to judge and
    ; its histogram is stale until the next tenant repopulates it.
    lea rax, [rel l3_slot_live]
    cmp qword [rax + r10*8], 0
    je .asa_next
    ; r11 = this slot's histogram base = sc_trace_hist + slot*SC_TRACE_HIST_SLOTS*2
    imul eax, r10d, SC_TRACE_HIST_SLOTS * 2
    lea r11, [rel sc_trace_hist]
    add r11, rax
    ; Sum the high-risk buckets. SC_HIRISK_TABLE is a NUL(0xFFFF)-terminated
    ; list of syscall numbers; r9d accumulates the total (u16s, can't overflow
    ; a dword across the short list).
    xor r9d, r9d
    lea rbx, [rel sc_hirisk_table]
.asa_sum:
    movzx ecx, word [rbx]
    cmp ecx, SC_TRACE_REC_INVALID        ; 0xFFFF terminator
    je .asa_sum_done
    movzx eax, word [r11 + rcx*2]        ; this slot's count for that syscall
    add r9d, eax
    add rbx, 2
    jmp .asa_sum
.asa_sum_done:
    ; Pick the budget by whether this slot's (authenticated) cap mask grants
    ; CAP_WX. Reading slot_cap_mask raw is fine here: a tampered mask is caught
    ; by the dispatcher's HMAC gate on the next syscall; the worst this scan can
    ; do with a forged-wide mask is apply the more generous HOLD budget, which
    ; only delays — never suppresses — a strike, and the dispatcher would panic
    ; on that mask anyway.
    lea rax, [rel slot_cap_mask]
    movzx eax, byte [rax + r10]
    test al, CAP_WX
    jnz .asa_hold_budget
    mov edx, ANOMALY_HIRISK_DENY_BUDGET
    jmp .asa_have_budget
.asa_hold_budget:
    mov edx, ANOMALY_HIRISK_HOLD_BUDGET
.asa_have_budget:
    cmp r9d, edx
    jbe .asa_reset_window                ; within profile — just roll the window
    ; --- Anomaly: this slot's high-risk mix is over budget for its class. -----
    ; Audit the flag (old_mask = current cap mask, new_mask = the over-budget
    ; count truncated to a byte for the record, reason = CAP_AUDIT_ANOMALY).
    ; cap_audit_log preserves all caller regs.
    lea rax, [rel slot_cap_mask]
    movzx esi, byte [rax + r10]          ; sil = old_mask (current caps)
    movzx edi, r10b                      ; dil = slot
    mov edx, r9d                         ; dl  = observed high-risk count (low8)
    mov ecx, CAP_AUDIT_ANOMALY           ; cl  = reason
    xor r8d, r8d                         ; r8d = app_id (unknown at scan time)
    call cap_audit_log
    ; Drive the slot through the existing §12 strike path. sc_record_strike
    ; keys off r15, so point r15 at the flagged slot for the call. It increments
    ; the strike counter and, at SC_STRIKE_LIMIT, kills the slot via the same
    ; wm_close_window teardown the §12 path uses. r10 (loop index) survives the
    ; call (sc_record_strike clobbers rax/rcx/rdx/rsi/rdi/r8 only).
    movzx r15d, r10b
    call sc_record_strike
.asa_reset_window:
    ; Reset this slot's high-risk buckets so each scan window judges fresh
    ; behaviour. Non-high-risk buckets are left to keep accreting (cheap, and
    ; the detector only reads the high-risk ones). r11 still = histogram base.
    lea rbx, [rel sc_hirisk_table]
.asa_reset:
    movzx ecx, word [rbx]
    cmp ecx, SC_TRACE_REC_INVALID
    je .asa_next
    mov word [r11 + rcx*2], 0
    add rbx, 2
    jmp .asa_reset
.asa_next:
    inc r10d
    jmp .asa_slot
.asa_done:
    pop r15
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    FN_END sc_anomaly_scan_all
    ret

; ----------------------------------------------------------------------------
; sc_trace_dump(rdi = slot) - ship a slot's per-syscall trace ring on serial
; (security_todo.md §11, "Crashes ship the last N syscalls"). Called from the
; syscall-path panic handlers with the faulting slot in rdi. Walks the slot's
; ring oldest-first and prints one line per record: "Tn <seq> <sysno> <arg0>
; <rip>". Best-effort forensic aid; preserves all caller regs (the panic banner
; reads its own rdi/rsi afterward).
; ----------------------------------------------------------------------------
sc_trace_dump:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    movzx ecx, dil
    cmp ecx, MAX_WINDOWS
    jae .std_done                        ; bad slot id — nothing to dump
    SER 'T'
    SER 'R'
    SER 'C'
    SER ' '
    mov edi, ecx
    add edi, '0'
    cmp edi, '9'
    jbe .std_slot_digit
    add edi, ('A' - '9' - 1)             ; slots >9 print as A.. (MAX_WINDOWS small)
.std_slot_digit:
    mov dx, 0x3F8
    mov eax, edi
    out dx, al
    call serial_crlf
    ; r8 = ring base for this slot; ebx = head event counter (low16).
    imul eax, ecx, SC_TRACE_SLOT_BYTES
    lea r8, [rel sc_trace_ring]
    add r8, rax
    lea rax, [rel sc_trace_head]
    movzx ebx, word [rax + rcx*2]
    ; Walk the SC_TRACE_RING_ENTRIES records in chronological order. If the ring
    ; has wrapped (head >= ENTRIES) the oldest live record is (head - ENTRIES);
    ; otherwise records [0, head) are valid. Either way iterate index =
    ; (head - ENTRIES .. head-1) & IDX_MASK, skipping not-yet-written slots.
    mov r9d, SC_TRACE_RING_ENTRIES       ; remaining to consider
    mov ecx, ebx
    sub ecx, SC_TRACE_RING_ENTRIES       ; oldest candidate seq
.std_rec:
    test r9d, r9d
    jz .std_done
    cmp ebx, SC_TRACE_RING_ENTRIES
    jae .std_rec_live                    ; full ring: every slot is live
    cmp ecx, 0
    jl .std_rec_skip                     ; not-yet-written (seq < 0): skip
.std_rec_live:
    mov edx, ecx
    and edx, SC_TRACE_IDX_MASK
    imul edx, edx, SC_TRACE_ENT_SIZE
    push r8
    add r8, rdx                          ; r8 -> record
    movzx edi, word [r8 + 2]             ; sysno
    push rcx
    push r8
    mov dx, 0x3F8
    mov al, ' '
    out dx, al
    pop r8
    mov rdi, [r8 + 8]                    ; user_rip — the most useful field
    call ser_print_hex64
    pop rcx
    pop r8
    call serial_crlf
.std_rec_skip:
    inc ecx
    dec r9d
    jmp .std_rec
.std_done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; High-risk syscall set the §11 anomaly detector watches. NUL-terminated with
; SC_TRACE_REC_INVALID (0xFFFF). The CAP_WX W^X/JIT-alias trio (install_manifest
; / mprotect_wx / jit_alias) are the classic code-injection surface; SYS_FS_DELETE
; rounds out a destructive op a doc-style "Notepad" should essentially never
; touch in bulk. Numbers must track the syscall_table order (see SC_SYS_FS_DELETE
; in syscall_caps.inc and the SYS_WX_* macros in syscall_user.inc).
align 2
sc_hirisk_table:
    dw 67                                ; SYS_WX_INSTALL_MANIFEST
    dw 68                                ; SYS_MPROTECT_WX
    dw 69                                ; SYS_WX_JIT_ALIAS
    dw SC_SYS_FS_DELETE                  ; SYS_FS_DELETE (=19)
    dw SC_TRACE_REC_INVALID              ; terminator

; ----------------------------------------------------------------------------
; kernel_panic_canary - reached only from the syscall exit paths when the
; saved canary slot does not match kernel_canary. rdi = observed bad value,
; rsi = approximate kernel RIP at detection. Serial-logs and halts; never
; returns.
; ----------------------------------------------------------------------------
global kernel_panic_canary
kernel_panic_canary:
    cli
    ; §11: a kernel-integrity panic on the syscall path means *this* slot's last
    ; few syscalls are the prime forensic evidence. Ship them on serial before
    ; halting (r15 still holds the faulting slot id here). Save rdi/rsi — the
    ; dumper preserves them but the explicit push documents the contract that
    ; the panic banner below still reads the original args.
    push rdi
    push rsi
    movzx edi, r15b
    call sc_trace_dump
    pop rsi
    pop rdi
    SER 'C'
    SER 'A'
    SER 'N'
    SER 'A'
    SER 'R'
    SER 'Y'
    SER ' '
    call ser_print_hex64                ; rdi = bad canary
    SER ' '
    SER '@'
    mov rdi, rsi
    call ser_print_hex64                ; rsi = detection RIP
    SER 13
    SER 10
%ifdef ENABLE_DEBUG_SERIAL
    ; Extended forensics (debug builds only) for the intermittent boot canary
    ; panic. The banner above shows rdi (observed/bad) and rsi (detection RIP or
    ; per-caller context). These extra lines disambiguate the root cause:
    ;   K=<kernel_canary>  the live global canary. If this is 0 the seed never
    ;                      ran; if nonzero the *saved* copy was clobbered.
    ;   s=<r15>            faulting slot id (valid on the syscall-return paths).
    ;   x=<r10>            secondary context (e.g. expected baseline on the
    ;                      code-hash path, which sets r10 before jumping here).
    ; r10/r15 are not touched between entry and here, and ser_print_hex64 saves
    ; rax-rdi (never r8-r15), so these reads see the values as of the panic.
    SER 'K'
    SER '='
    mov rdi, [rel kernel_canary]
    call ser_print_hex64
    SER ' '
    SER 's'
    SER '='
    movzx edi, r15b
    call ser_print_hex64
    SER ' '
    SER 'x'
    SER '='
    mov rdi, r10
    call ser_print_hex64
    SER 13
    SER 10
%endif
.kpc_halt:
    cli
    hlt
    jmp .kpc_halt

; kernel_panic_shadow - reached only from KEPILOGUE when a shadow-protected
; function's saved return address no longer matches its parallel-page mirror
; (see src/include/shadow_stack.inc). rdi = observed (corrupted) return
; address, rsi = expected return address from the shadow page. Serial-logs
; and halts; never returns.
; ----------------------------------------------------------------------------
global kernel_panic_shadow
kernel_panic_shadow:
    cli
    SER 'S'
    SER 'H'
    SER 'A'
    SER 'D'
    SER 'O'
    SER 'W'
    SER ' '
    call ser_print_hex64                ; rdi = observed (bad) return address
    SER ' '
    SER '!'
    mov rdi, rsi
    call ser_print_hex64                ; rsi = expected (shadow) return address
    SER 13
    SER 10
.kps_halt:
    cli
    hlt
    jmp .kps_halt

%ifdef ENABLE_SHADOW_STACK_POC
; ----------------------------------------------------------------------------
; shadow_stack_poc_run - build-gated proof harness for the kernel shadow stack.
; Called once from kmain after l3_install_syscall_stack_pt (so the slot-0
; syscall stack and its parallel shadow page are mapped). It switches RSP onto
; slot 0's syscall stack, calls a shadow-protected stub that deliberately
; smashes its own saved return address, and confirms KEPILOGUE traps to
; kernel_panic_shadow. Serial output:
;   "POCS"            harness started
;   "SHADOW <bad> ! <expected>" + halt   -> guard working (expected outcome)
;   "POCF"            corruption NOT caught -> guard broken (regression)
; Never compiled into release builds (see build_uefi.ps1 -ShadowStackPoc).
; ----------------------------------------------------------------------------
extern l3_syscall_stack_top
global shadow_stack_poc_run
shadow_stack_poc_run:
    SER 'P'
    SER 'O'
    SER 'C'
    SER 'S'
    SER 13
    SER 10
    mov [rel shadow_poc_saved_rsp], rsp
    xor edi, edi
    call l3_syscall_stack_top           ; rax = slot 0 syscall stack top (mapped)
    mov rsp, rax
    call shadow_poc_trip                ; expected: never returns (panics)
    ; Reached only if the shadow check FAILED to fire.
    mov rsp, [rel shadow_poc_saved_rsp]
    SER 'P'
    SER 'O'
    SER 'C'
    SER 'F'
    SER 13
    SER 10
    ret

; Shadow-protected frame: KPROLOGUE mirrors the true return address into the
; parallel shadow page, we then overwrite the on-stack copy, and KEPILOGUE
; must detect the divergence before returning.
shadow_poc_trip:
    KPROLOGUE
    mov rax, 0xDEADBEEFCAFEBABE
    mov [rsp], rax                      ; smash the saved return address
    KEPILOGUE                           ; -> kernel_panic_shadow on mismatch
%endif

