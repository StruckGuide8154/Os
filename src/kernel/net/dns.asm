; ============================================================================
; NexusOS DNS protocol module
; ----------------------------------------------------------------------------
; Small synchronous A-record resolver. DNS owns message construction/parsing;
; UDP owns transport and ARP/IPv4 framing. Public callers pass a C-string host
; name and receive one IPv4 address in NexusOS A.B.C.D scalar order.
;
; Strategy: try the DHCP-provided DNS server first. If it times out (server
; unreachable or filtered), retry once with 8.8.8.8 as a known-good fallback.
; ============================================================================
bits 64

%include "net_driver.inc"

extern net_info
extern net_nic_poll_rx
extern net_udp_send_ipv4
extern tick_count

DNS_PORT        equ 53
DNS_SRC_PORT    equ 49153
DNS_PORT_NET    equ 0x3500
DNS_SRC_PORT_NET equ 0x01C0
DNS_MAX_NAME    equ 253
DNS_QUERY_CAP   equ 512

; Per-slot destination policy (security_todo.md §7). Provides
; sec_net_check_suffix, consulted below after the LDH/length kill-switch.
%include "net_slot_policy.inc"
; 8.8.8.8 public fallback resolver; defined in net_driver.inc as
; NET_DNS_FALLBACK_IP (header is the source of the name, maintainability §4.2).

section .text

; RDI = hostname C-string. Returns EAX = IPv4 A.B.C.D, or 0 on failure.
global net_dns_query_a
net_dns_query_a:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov [rel net_dns_name_ptr], rdi

    ; Kill switch: reject pathological host names BEFORE touching the wire.
    ; Fail closed (return 0) on a name over DNS_MAX_NAME (253) bytes or
    ; containing any non-LDH byte (anything outside letters/digits/hyphen/dot).
    ; net_dns_build_query enforces the same rules per label, but this explicit
    ; up-front gate keeps the policy auditable in one place and guarantees no
    ; query is constructed for a hostile name.
    mov rdi, [rel net_dns_name_ptr]
    call net_dns_validate_name
    test eax, eax
    jz .fail

    ; Per-slot DNS-suffix allowlist (security_todo.md §7). If the calling slot
    ; opted into a suffix policy, the hostname must end (on a label boundary)
    ; with the slot's allowed suffix; otherwise this is a no-op (allow). Fails
    ; closed: a hostname outside the allowlist resolves to no query at all.
    mov rdi, [rel net_dns_name_ptr]
    call sec_net_check_suffix
    test eax, eax
    jz .fail

    ; Build the query once; reuse for both attempts.
    mov rdi, [rel net_dns_name_ptr]
    call net_dns_build_query
    test eax, eax
    jz .fail
    mov [rel net_dns_query_len], eax

    ; Attempt 1: DHCP-provided DNS server. Short timeout so a non-responsive
    ; LAN resolver falls through to the public fallback quickly.
    mov rdi, 9                           ; NI_DNS_SERVER
    call net_info
    test eax, eax
    jz .try_fallback
    mov [rel net_dns_server_ip], eax
    mov dword [rel net_dns_wait_ticks], 30   ; 300ms
    call net_dns_send_and_wait
    test eax, eax
    jnz .done

.try_fallback:
    ; Attempt 2: public DNS fallback (8.8.8.8) — longer window since this is
    ; the last chance to resolve before reporting failure.
    mov dword [rel net_dns_server_ip], NET_DNS_FALLBACK_IP
    mov dword [rel net_dns_wait_ticks], 100  ; 1s
    call net_dns_send_and_wait
    test eax, eax
    jnz .done
.fail:
    xor eax, eax
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI = hostname C-string. Returns EAX=1 if the name is acceptable, 0 if it is
; over DNS_MAX_NAME bytes, empty/NULL, or contains a non-LDH byte. Pure scan —
; no wire I/O. LDH = letters (A-Z/a-z), digits (0-9), hyphen, plus the label
; separator dot. Fails closed.
net_dns_validate_name:
    push rcx
    push rdi
    test rdi, rdi
    jz .vbad                             ; NULL pointer
    xor ecx, ecx                         ; byte count
.vloop:
    mov al, [rdi]
    test al, al
    jz .vend
    cmp ecx, DNS_MAX_NAME
    jae .vbad                            ; would exceed 253 bytes
    cmp al, '.'
    je .vok
    cmp al, '-'
    je .vok
    cmp al, '0'
    jb .vbad
    cmp al, '9'
    jbe .vok
    cmp al, 'A'
    jb .vbad
    cmp al, 'Z'
    jbe .vok
    cmp al, 'a'
    jb .vbad
    cmp al, 'z'
    ja .vbad
.vok:
    inc rdi
    inc ecx
    jmp .vloop
.vend:
    test ecx, ecx
    jz .vbad                             ; empty name
    mov eax, 1
    jmp .vret
.vbad:
    xor eax, eax
.vret:
    pop rdi
    pop rcx
    ret

; Sends the prebuilt query in net_dns_query_buf to net_dns_server_ip and waits
; up to 2 seconds for a response. Returns EAX = resolved IP, or 0 on timeout.
net_dns_send_and_wait:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8

    ; Refresh txid so retries don't accept a stale earlier reply.
    inc word [rel net_dns_txid]
    cmp word [rel net_dns_txid], 0
    jne .txid_ok
    inc word [rel net_dns_txid]
.txid_ok:
    ; Patch the new txid into the prebuilt query buffer.
    mov ax, [rel net_dns_txid]
    xchg al, ah
    mov [rel net_dns_query_buf + 0], ax

    mov dword [rel net_dns_result_ip], 0
    mov byte [rel net_dns_waiting], 1

    mov edi, [rel net_dns_server_ip]
    mov si, DNS_PORT
    mov dx, DNS_SRC_PORT
    lea r8, [rel net_dns_query_buf]
    mov ecx, [rel net_dns_query_len]
    call net_udp_send_ipv4
    test eax, eax
    jz .saw_fail

    mov rbx, [tick_count]
    mov eax, [rel net_dns_wait_ticks]
    add rbx, rax
.wait:
    call net_nic_poll_rx
    mov eax, [rel net_dns_result_ip]
    test eax, eax
    jnz .saw_done
    mov rax, [tick_count]
    cmp rax, rbx
    jae .saw_fail
    pause
    jmp .wait
.saw_fail:
    mov byte [rel net_dns_waiting], 0
    xor eax, eax
    jmp .saw_ret
.saw_done:
    mov byte [rel net_dns_waiting], 0
.saw_ret:
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI = hostname C-string. Returns EAX = query length, or 0 on invalid name.
net_dns_build_query:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea rdi, [rel net_dns_query_buf]
    mov ecx, DNS_QUERY_CAP
    xor eax, eax
    rep stosb

    ; txid placeholder — patched per-attempt in net_dns_send_and_wait.
    mov word [rel net_dns_query_buf + 0], 0
    mov word [rel net_dns_query_buf + 2], 0x0001 ; recursion desired
    mov word [rel net_dns_query_buf + 4], 0x0100 ; QDCOUNT = 1

    mov rsi, [rsp + 16]                  ; saved caller RDI = hostname
    lea rdi, [rel net_dns_query_buf + 12]
    mov rbx, rdi                         ; current label length byte
    inc rdi
    xor ecx, ecx                         ; current label length
    xor r8d, r8d                         ; total name bytes consumed
.name_loop:
    mov al, [rsi]
    test al, al
    jz .name_end
    cmp r8d, DNS_MAX_NAME
    jae .bad_name
    cmp al, '.'
    je .dot
    cmp al, '-'
    je .char_ok
    cmp al, '0'
    jb .bad_name
    cmp al, '9'
    jbe .char_ok
    cmp al, 'A'
    jb .bad_name
    cmp al, 'Z'
    jbe .char_ok
    cmp al, 'a'
    jb .bad_name
    cmp al, 'z'
    ja .bad_name
.char_ok:
    cmp ecx, 63
    jae .bad_name
    mov [rdi], al
    inc rdi
    inc rsi
    inc ecx
    inc r8d
    jmp .name_loop
.dot:
    test ecx, ecx
    jz .bad_name
    mov [rbx], cl
    mov rbx, rdi
    inc rdi
    xor ecx, ecx
    inc rsi
    inc r8d
    jmp .name_loop
.name_end:
    test ecx, ecx
    jz .bad_name
    mov [rbx], cl
    mov byte [rdi], 0
    inc rdi
    mov word [rdi], 0x0100               ; QTYPE A
    mov word [rdi + 2], 0x0100           ; QCLASS IN
    add rdi, 4                           ; length must include QTYPE+QCLASS
    lea rax, [rel net_dns_query_buf]
    sub rdi, rax
    mov rax, rdi
    jmp .done
.bad_name:
    xor eax, eax
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI = UDP payload, ECX = payload length. Returns EAX=1 when consumed.
; SI/DX are source/destination UDP ports in on-wire byte order.
global net_dns_rx_udp
net_dns_rx_udp:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cmp byte [rel net_dns_waiting], 1
    jne .drop
    cmp si, DNS_PORT_NET
    jne .drop
    cmp dx, DNS_SRC_PORT_NET
    jne .drop
    cmp ecx, 12
    jb .drop
    mov ax, [rel net_dns_txid]
    xchg al, ah
    cmp [rdi + 0], ax
    jne .drop
    mov ax, [rdi + 2]
    test ax, 0x0080                      ; QR response bit in network bytes.
    jz .drop
    test ax, 0x0F00                      ; RCODE must be 0.
    jnz .drop

    mov ax, [rdi + 4]                    ; QDCOUNT
    xchg al, ah
    movzx r10d, ax
    mov ax, [rdi + 6]                    ; ANCOUNT
    xchg al, ah
    movzx r11d, ax
    test r11d, r11d
    jz .drop
    mov rsi, rdi
    add rsi, rcx                         ; packet end
    lea rbx, [rdi + 12]                  ; cursor
.question_loop:
    test r10d, r10d
    jz .answers
    mov rdi, rbx
    call net_dns_skip_name
    test rax, rax
    jz .drop
    lea rbx, [rax + 4]
    cmp rbx, rsi
    ja .drop
    dec r10d
    jmp .question_loop
.answers:
    test r11d, r11d
    jz .drop
    mov rdi, rbx
    call net_dns_skip_name
    test rax, rax
    jz .drop
    lea rbx, [rax + 10]
    cmp rbx, rsi
    ja .drop
    cmp word [rax + 0], 0x0100           ; TYPE A
    jne .next_answer
    cmp word [rax + 2], 0x0100           ; CLASS IN
    jne .next_answer
    cmp word [rax + 8], 0x0400           ; RDLENGTH = 4
    jne .next_answer
    lea rbx, [rax + 14]
    cmp rbx, rsi
    ja .drop
    mov eax, [rax + 10]
    bswap eax
    mov [rel net_dns_result_ip], eax
    mov eax, 1
    jmp .done
.next_answer:
    movzx edx, word [rax + 8]
    xchg dl, dh
    lea rbx, [rax + 10 + rdx]
    cmp rbx, rsi
    ja .drop
    dec r11d
    jmp .answers
.drop:
    xor eax, eax
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI = encoded domain name cursor, RSI = packet end. Returns RAX = first byte
; after the encoded name, or 0 for malformed compression/length.
net_dns_skip_name:
    push rcx
    push rdx
    mov rcx, 128
.loop:
    cmp rdi, rsi
    jae .bad
    movzx edx, byte [rdi]
    test dl, dl
    jz .root
    mov al, dl
    and al, 0xC0
    cmp al, 0xC0
    je .compressed
    test al, al
    jnz .bad
    inc rdi
    add rdi, rdx
    cmp rdi, rsi
    ja .bad
    loop .loop
    jmp .bad
.compressed:
    lea rax, [rdi + 2]
    cmp rax, rsi
    ja .bad
    jmp .done
.root:
    lea rax, [rdi + 1]
    jmp .done
.bad:
    xor eax, eax
.done:
    pop rdx
    pop rcx
    ret

section .bss
alignb 16
net_dns_query_buf: resb DNS_QUERY_CAP
net_dns_txid:      resw 1
net_dns_waiting:   resb 1
alignb 4
net_dns_query_len: resd 1
net_dns_result_ip: resd 1
net_dns_server_ip: resd 1
net_dns_wait_ticks: resd 1
net_dns_name_ptr:  resq 1
