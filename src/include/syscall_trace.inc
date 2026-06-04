%ifndef SYSCALL_TRACE_INC
%define SYSCALL_TRACE_INC
; ============================================================================
; Always-on per-syscall trace ring + per-slot syscall histograms.
; security_todo.md §11 ("Observability that aids defense").
;
; WHY (vs the existing ENABLE_TRACE serial mechanism)
;   The old ENABLE_TRACE path (trace.inc / trace_syscall) is a heavyweight,
;   compile-gated *serial logger*: it calls out on every enter/exit/reject and
;   prints, so it is far too expensive to leave on in a shipping build and the
;   evidence only exists on a wire nobody is watching at crash time. This is
;   the §11 promotion of that idea to something cheap enough to be ALWAYS ON:
;   a slot-isolated in-memory ring of the last N syscalls plus a per-slot
;   histogram, so a crash/panic can ship the last N calls for the faulting slot
;   and the §11 anomaly detector has a per-slot syscall-mix to scan.
;
; DATA LAYOUT (all in syscall.asm kernel BSS, OUTSIDE the ring-3 slot arena)
;   sc_trace_ring[]   — per slot, SC_TRACE_RING_ENTRIES records of
;                       SC_TRACE_ENT_SIZE bytes, written oldest-first. One slot's
;                       ring never aliases another's (slot-isolated): the byte
;                       base for slot s is s * SC_TRACE_SLOT_BYTES.
;   sc_trace_head[]   — per slot, a running u16 event counter; (head &
;                       SC_TRACE_IDX_MASK) is the next record index, so the ring
;                       overwrites oldest-first once it fills.
;   sc_trace_hist[]   — per slot, SC_TRACE_HIST_SLOTS u16 counters indexed by
;                       syscall number. THIS is the data source the anomaly
;                       detector (sc_anomaly_scan_all) consumes: it never walks
;                       the ring records, only these cheap counters. Saturating
;                       so a fuzzer can't wrap a counter back under threshold.
;
; HOT PATH BUDGET
;   The append (SC_TRACE_APPEND macro, inlined at dispatch entry) is a handful
;   of instructions — index math, one 16-byte record store, one saturating
;   histogram bump — with no CALL and no serial I/O. The §11 doc stresses the
;   hot path stays cheap; the detector itself runs on a coarse pit cadence.
;
; Each record (SC_TRACE_ENT_SIZE = 16 bytes):
;   +0  u16 seq      (low 16 bits of this slot's head at write time)
;   +2  u16 sysno    (syscall number; 0xFFFF == out-of-range/invalid)
;   +4  u32 arg0_lo  (low 32 bits of the first user arg — cheap forensic hint)
;   +8  u64 user_rip (faulting/return RIP for this call, for crash triage)
; ============================================================================

; Ring depth per slot (power of two so head masking is a single AND). 16 calls
; is enough post-mortem context without bloating BSS (16 * 16 B = 256 B/slot).
SC_TRACE_RING_ENTRIES equ 16
SC_TRACE_IDX_MASK     equ (SC_TRACE_RING_ENTRIES - 1)
SC_TRACE_ENT_SIZE     equ 16
SC_TRACE_SLOT_BYTES   equ (SC_TRACE_RING_ENTRIES * SC_TRACE_ENT_SIZE)
SC_TRACE_REC_INVALID  equ 0xFFFF        ; sysno sentinel for an out-of-range call

; Per-slot histogram width. One u16 counter per syscall number. 128 covers the
; current table (~73 rows) with headroom; any sysno >= this is folded into the
; last bucket so the bump never indexes out of the slot's row.
SC_TRACE_HIST_SLOTS   equ 128
SC_TRACE_HIST_MAX     equ 0xFFFF        ; saturation ceiling (u16)

; ----------------------------------------------------------------------------
; SC_TRACE_APPEND — inline, always-on. Record one syscall into the active
; slot's ring and bump its histogram. Called at the top of dispatch, after r15
; (slot id) and the PUSH_ALL frame are established.
;
; In : r15b  = current slot id (validated < MAX_WINDOWS by the caller's flow;
;              this macro re-clamps defensively so it can never index past the
;              per-slot arrays).
;      rsp   = PUSH_ALL frame ([rsp+ALL_RAX]=sysno, [rsp+ALL_RDI]=arg0).
;      l3_runtime[slot].L3_RT_USER_RIP holds the user RIP for this call.
; Clobbers rax, rbx, rcx, rdx, r8. r15 and the saved PUSH_ALL frame are
; preserved. IMPORTANT: on exit rax holds the user RIP (the macro's last store
; is the ring's +8 forensic RIP anchor), NOT the syscall number. The caller MUST
; `mov rax, [rsp + ALL_RAX]` before using rax as the syscall number again (the
; bounds check / per-slot permutation key off it). The arg-register reloads at
; the dispatch tail are far too late for that. (Regression fixed 2026-05-31:
; without the reload every syscall number became its return RIP -> out-of-range
; -> -1 -> all app windows painted blank. See docs/STATUS.md.)
; ----------------------------------------------------------------------------
%macro SC_TRACE_APPEND 0
    movzx ecx, r15b
    cmp ecx, MAX_WINDOWS
    jb %%slot_ok
    xor ecx, ecx                        ; clamp stray slot id to 0 (global)
%%slot_ok:
    ; --- histogram bump (the detector's data source) -------------------------
    mov rax, [rsp + ALL_RAX]            ; syscall number
    mov edx, eax
    cmp edx, SC_TRACE_HIST_SLOTS
    jb %%hist_idx_ok
    mov edx, SC_TRACE_HIST_SLOTS - 1    ; fold over-range numbers into last bucket
%%hist_idx_ok:
    imul ebx, ecx, SC_TRACE_HIST_SLOTS * 2   ; slot's histogram base (u16 each)
    lea r8, [rel sc_trace_hist]
    add rbx, r8
    movzx r8d, word [rbx + rdx*2]
    cmp r8d, SC_TRACE_HIST_MAX
    jae %%hist_done                     ; saturate — never wrap under threshold
    inc r8d
    mov [rbx + rdx*2], r8w
%%hist_done:
    ; --- ring record ---------------------------------------------------------
    lea r8, [rel sc_trace_head]
    movzx ebx, word [r8 + rcx*2]        ; this slot's head (event counter)
    mov edx, ebx
    and edx, SC_TRACE_IDX_MASK          ; next record index
    imul edx, edx, SC_TRACE_ENT_SIZE
    imul eax, ecx, SC_TRACE_SLOT_BYTES  ; slot's ring base
    add edx, eax
    lea r8, [rel sc_trace_ring]
    add r8, rdx                         ; r8 -> record base
    mov [r8 + 0], bx                    ; +0 seq (low16 of head)
    mov rax, [rsp + ALL_RAX]            ; sysno again (rax was reused)
    cmp eax, syscall_table_count
    jb %%sysno_ok
    mov eax, SC_TRACE_REC_INVALID
%%sysno_ok:
    mov [r8 + 2], ax                    ; +2 sysno
    mov rax, [rsp + ALL_RDI]
    mov [r8 + 4], eax                   ; +4 arg0_lo
    ; user RIP from this slot's runtime block (cheap forensic anchor)
    imul eax, ecx, L3_RT_SIZE
    lea rdx, [rel l3_runtime]
    add rdx, rax
    mov rax, [rdx + L3_RT_USER_RIP]
    mov [r8 + 8], rax                   ; +8 user_rip
    ; advance this slot's head (wraps at 2^16; only the low bits index the ring)
    lea r8, [rel sc_trace_head]
    inc bx
    mov [r8 + rcx*2], bx
%endmacro

%endif ; SYSCALL_TRACE_INC
