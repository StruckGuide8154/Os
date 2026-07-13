; ============================================================================
; Grit - Per-slot network destination policy (security_todo.md §7)
; ----------------------------------------------------------------------------
; CAP_NET is binary: a slot either may touch the network or may not. This
; module layers an OPT-IN, per-app destination allowlist on top of CAP_NET,
; modelled on iOS App Transport Security:
;
;   * a DNS-suffix allowlist  - net_dns_query_a rejects a hostname whose suffix
;                               is not the slot's allowed suffix
;   * a port-range allowlist  - net_tcp_connect_ipv4 rejects a destination port
;                               outside the slot's allowed [lo, hi] range
;
; Storage model (mirrors slot_cap_mask[] / slot_handle_quota[]): parallel
; per-slot arrays in KERNEL BSS - OUTSIDE the ring-3 app arena - so a slot
; cannot widen its own destination policy with a slot-memory write bug. The
; arrays are indexed by slot id (0..APP_SLOT_COUNT-1).
;
; DEFAULT (BSS-zero) = NO RESTRICTION. A slot with no declared policy behaves
; exactly as today: CAP_NET alone gates it. A manifest opts a slot IN to the
; tighter policy by setting the matching active bit via the setters below. This
; keeps the change non-breaking for the existing apps while making the tighter
; policy available - "opt-in ATS". Within an active policy the enforcement is
; FAIL CLOSED: an active suffix/range that does not match the destination
; rejects the operation (return 0 / -1 as the surrounding net code does).
;
; --------------------------------------------------------------------------
; CURRENT-SLOT CONTEXT (deferred dispatcher wiring)
; --------------------------------------------------------------------------
; Enforcement must know which slot is making the call. The syscall dispatcher
; holds that in r15; the wiring is now LANDED - both enforced net paths publish
; the calling slot before invoking the gated function:
;
;       mov   [rel sec_net_active_slot], r15b
;
; at the top of .sc_net_tcp_connect4 (→ net_tcp_connect_ipv4 port check) and
; .sc_net_dns_a (→ net_dns_query_a suffix check) in
; syscall_handlers_wx_net.inc. STILL DEFERRED: a manifest-setter syscall (e.g.
; SYS_NET_SET_POLICY) that calls sec_net_set_port_range / sec_net_set_suffix to
; declare a slot's policy - until that lands, no slot has an active policy, so
; sec_net_active_slot is now set correctly but every slot's policy is still the
; BSS-zero no-restriction default and the net paths behave exactly as before.
; The gate is wired and inert, ready to enforce the instant a policy is declared.
; The KERNEL-SIDE primitives (storage + setters + the two enforcement checks)
; all land here and in dns.asm/tcp.asm.
; ============================================================================

%ifndef NET_SLOT_POLICY_INC
%define NET_SLOT_POLICY_INC

%include "boot_memory.inc"        ; APP_SLOT_COUNT

; Policy active-flag bits (sec_net_policy_flags[slot]).
SEC_NET_POLICY_PORTS   equ 0x01   ; port-range allowlist active for this slot
SEC_NET_POLICY_SUFFIX  equ 0x02   ; DNS-suffix allowlist active for this slot

; Max stored suffix length (bytes, excluding the NUL). 63 + NUL fits the
; widest single DNS label and the common "example.com"-class suffixes; longer
; suffixes are clamped/rejected by the setter.
SEC_NET_SUFFIX_MAX     equ 63
SEC_NET_SUFFIX_STRIDE  equ (SEC_NET_SUFFIX_MAX + 1)   ; 64, NUL-terminated slot

; Upper bound on a hostname presentation scan (matches dns.asm's DNS_MAX_NAME).
; Defined here (guarded) so this include is self-contained whether pulled by
; dns.asm (which also defines DNS_MAX_NAME = 253) or tcp.asm (which does not).
%ifndef DNS_MAX_NAME
DNS_MAX_NAME    equ 253
%endif

section .text

; ---------------------------------------------------------------------------
; sec_net_active_slot_id - load the current slot id, clamped to a valid index.
; Returns: EAX = slot id in [0, APP_SLOT_COUNT-1]. Clobbers EAX only.
; ---------------------------------------------------------------------------
sec_net_active_slot_id:
    movzx eax, byte [rel sec_net_active_slot]
    cmp eax, APP_SLOT_COUNT
    jb .ok
    xor eax, eax                       ; fail safe to slot 0 (no-policy default)
.ok:
    ret

; ---------------------------------------------------------------------------
; sec_net_set_port_range - opt a slot into the TCP destination port allowlist.
;   EDI = slot id
;   SI  = low port (inclusive)
;   DX  = high port (inclusive)
; A range with lo > hi is normalized (swapped). Stored in kernel BSS. Marks the
; SEC_NET_POLICY_PORTS bit. Out-of-range slot id is ignored. Clobbers RAX.
; Intended call site: a future manifest-apply / SYS_NET_SET_POLICY in the
; (contended) dispatcher - see header note.
; ---------------------------------------------------------------------------
global sec_net_set_port_range
sec_net_set_port_range:
    cmp edi, APP_SLOT_COUNT
    jae .spr_done
    cmp si, dx
    jbe .spr_ordered
    xchg si, dx                        ; normalize lo <= hi
.spr_ordered:
    mov eax, edi
    mov [abs sec_net_port_lo + rax*2], si
    mov [abs sec_net_port_hi + rax*2], dx
    or byte [abs sec_net_policy_flags + rax], SEC_NET_POLICY_PORTS
.spr_done:
    ret

; ---------------------------------------------------------------------------
; sec_net_set_suffix - opt a slot into the DNS-suffix allowlist.
;   EDI = slot id
;   RSI = pointer to an allowed-suffix C-string (e.g. "example.com")
; The suffix is copied (lowercased) into the slot's kernel-BSS slot, truncated
; to SEC_NET_SUFFIX_MAX. An empty/NULL suffix clears the SUFFIX bit (no
; restriction). Marks the SEC_NET_POLICY_SUFFIX bit otherwise. Clobbers RAX,
; RCX, R8. Preserves RDI/RSI.
; ---------------------------------------------------------------------------
global sec_net_set_suffix
sec_net_set_suffix:
    cmp edi, APP_SLOT_COUNT
    jae .ssfx_done
    push rdi
    push rsi
    push rcx
    push r8
    mov eax, edi
    imul eax, SEC_NET_SUFFIX_STRIDE
    lea r8, [rel sec_net_suffix]
    add r8, rax                        ; r8 = dest slot
    xor ecx, ecx                       ; copied length
    test rsi, rsi
    jz .ssfx_terminate
.ssfx_copy:
    cmp ecx, SEC_NET_SUFFIX_MAX
    jae .ssfx_terminate
    mov al, [rsi]
    test al, al
    jz .ssfx_terminate
    ; ASCII lowercase so the suffix compare is case-insensitive.
    cmp al, 'A'
    jb .ssfx_store
    cmp al, 'Z'
    ja .ssfx_store
    add al, 0x20
.ssfx_store:
    mov [r8 + rcx], al
    inc rsi
    inc ecx
    jmp .ssfx_copy
.ssfx_terminate:
    mov byte [r8 + rcx], 0
    ; flags: set SUFFIX bit iff non-empty, else clear it.
    mov eax, [rsp + 24]                ; saved EDI (slot id) - 4 pushes deep
    movzx eax, al
    test ecx, ecx
    jz .ssfx_clear
    or byte [abs sec_net_policy_flags + rax], SEC_NET_POLICY_SUFFIX
    jmp .ssfx_restore
.ssfx_clear:
    and byte [abs sec_net_policy_flags + rax], ~SEC_NET_POLICY_SUFFIX & 0xFF
.ssfx_restore:
    pop r8
    pop rcx
    pop rsi
    pop rdi
.ssfx_done:
    ret

; ---------------------------------------------------------------------------
; sec_net_check_port - enforce the port-range allowlist for the active slot.
;   DX = destination port (host order)
; Returns: EAX = 1 if allowed (no active policy, or port within [lo,hi]),
;          EAX = 0 if an active range rejects the port. FAIL CLOSED.
; Clobbers RAX, RCX. Preserves DX.
; ---------------------------------------------------------------------------
global sec_net_check_port
sec_net_check_port:
    push rcx
    call sec_net_active_slot_id        ; EAX = slot
    mov ecx, eax
    test byte [abs sec_net_policy_flags + rcx], SEC_NET_POLICY_PORTS
    jz .scp_allow                      ; no port policy -> allow
    cmp dx, [abs sec_net_port_lo + rcx*2]
    jb .scp_deny
    cmp dx, [abs sec_net_port_hi + rcx*2]
    ja .scp_deny
.scp_allow:
    mov eax, 1
    pop rcx
    ret
.scp_deny:
    xor eax, eax
    pop rcx
    ret

; ---------------------------------------------------------------------------
; sec_net_check_suffix - enforce the DNS-suffix allowlist for the active slot.
;   RDI = hostname C-string (already validated LDH/length by the caller)
; Returns: EAX = 1 if allowed (no active policy, or hostname ends with the
;          slot's allowed suffix on a label boundary), EAX = 0 otherwise.
;          FAIL CLOSED.
; "Suffix on a label boundary" means the suffix matches the tail of the name
; AND is either the whole name or is preceded by a '.', so "evil-example.com"
; does NOT satisfy a suffix of "example.com" (only "example.com" or
; "*.example.com" do). Case-insensitive (the stored suffix is lowercased; the
; hostname is restricted to LDH so we lowercase per-byte on compare).
; Clobbers RAX, RCX, RDX, R8, R9, R10. Preserves RDI.
; ---------------------------------------------------------------------------
global sec_net_check_suffix
sec_net_check_suffix:
    push rcx
    push rdx
    push r8
    push r9
    push r10
    call sec_net_active_slot_id        ; EAX = slot
    mov ecx, eax
    test byte [abs sec_net_policy_flags + rcx], SEC_NET_POLICY_SUFFIX
    jz .scs_allow                      ; no suffix policy -> allow

    ; r8 = stored suffix base for this slot
    mov eax, ecx
    imul eax, SEC_NET_SUFFIX_STRIDE
    lea r8, [rel sec_net_suffix]
    add r8, rax

    ; Measure hostname length -> r9
    xor r9d, r9d
.scs_hlen:
    cmp byte [rdi + r9], 0
    je .scs_hlen_done
    inc r9d
    cmp r9d, DNS_MAX_NAME
    jbe .scs_hlen
    jmp .scs_deny                      ; pathological (caller should have caught)
.scs_hlen_done:
    ; Measure suffix length -> r10
    xor r10d, r10d
.scs_slen:
    cmp byte [r8 + r10], 0
    je .scs_slen_done
    inc r10d
    cmp r10d, SEC_NET_SUFFIX_MAX
    jbe .scs_slen
.scs_slen_done:
    test r10d, r10d
    jz .scs_allow                      ; empty stored suffix -> no restriction
    cmp r10d, r9d
    ja .scs_deny                       ; suffix longer than name -> no match

    ; Compare the last r10 bytes of the hostname against the suffix, case-fold.
    mov edx, r9d
    sub edx, r10d                      ; edx = start offset of tail in hostname
    ; Label-boundary check: tail must be at offset 0, or preceded by '.'.
    test edx, edx
    jz .scs_cmp
    mov al, [rdi + rdx - 1]
    cmp al, '.'
    jne .scs_deny
.scs_cmp:
    xor ecx, ecx                       ; index into suffix
.scs_cmp_loop:
    cmp ecx, r10d
    jae .scs_allow                     ; all suffix bytes matched
    mov al, [rdi + rdx]                ; hostname byte (host index = edx)
    cmp al, 'A'
    jb .scs_nofold
    cmp al, 'Z'
    ja .scs_nofold
    add al, 0x20                       ; lowercase the hostname byte
.scs_nofold:
    cmp al, [r8 + rcx]                 ; stored suffix already lowercased
    jne .scs_deny
    inc edx
    inc ecx
    jmp .scs_cmp_loop
.scs_allow:
    mov eax, 1
    jmp .scs_ret
.scs_deny:
    xor eax, eax
.scs_ret:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; ============================================================================
; Per-slot policy storage - KERNEL BSS, OUTSIDE the ring-3 app arena.
; BSS-zero => no policy active for any slot (the non-breaking default).
; ============================================================================
section .bss
alignb 16
sec_net_active_slot:   resb 1          ; current slot id (deferred dispatcher set)
alignb 16
sec_net_policy_flags:  resb APP_SLOT_COUNT
alignb 4
sec_net_port_lo:       resw APP_SLOT_COUNT
sec_net_port_hi:       resw APP_SLOT_COUNT
alignb 16
sec_net_suffix:        resb (SEC_NET_SUFFIX_STRIDE * APP_SLOT_COUNT)

section .text

%endif ; NET_SLOT_POLICY_INC
