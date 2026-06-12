; ============================================================================
; GritOS UDP protocol module
; ----------------------------------------------------------------------------
; Generic IPv4/UDP transport above net_nic_tx_frame. Callers provide payloads
; and ports; this module handles next-hop ARP resolution and UDP framing.
; ============================================================================
bits 64

%include "net_driver.inc"

extern net_arp_resolve_ipv4_try
extern net_arp_resolved_mac_ptr
extern net_dns_rx_udp
extern net_info
extern net_ipv4_tx_proto

section .text

; EDI = destination IPv4 as A.B.C.D packed, SI = destination port,
; DX = source port, R8 = payload pointer, ECX = payload length.
; Returns EAX=1 if the datagram was queued/sent.
global net_udp_send_ipv4
net_udp_send_ipv4:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    cmp ecx, 1472
    ja .fail
    mov [rel net_udp_dst_ip], edi
    mov [rel net_udp_dst_port], si
    mov [rel net_udp_src_port], dx
    mov [rel net_udp_payload_ptr], r8
    mov [rel net_udp_payload_len], ecx

    mov rdi, 6                           ; NI_NEXT_HOP
    call net_info
    test eax, eax
    jnz .have_hop
    mov rdi, 3                           ; NI_ROUTER
    call net_info
    test eax, eax
    jnz .have_hop
    mov eax, [rel net_udp_dst_ip]
.have_hop:
    mov edi, eax
    ; Non-blocking: if the next-hop MAC isn't cached yet this fires one ARP
    ; request and returns 0 (datagram not sent). The DNS FSM retries on a later
    ; tick once the main loop's poll_rx has warmed the cache - no kernel freeze.
    call net_arp_resolve_ipv4_try
    test eax, eax
    jz .fail
    call net_arp_resolved_mac_ptr
    mov [rel net_udp_next_hop_mac_ptr], rax

    lea rdi, [rel net_udp_segment]
    mov ecx, [rel net_udp_payload_len]
    add ecx, 8
    xor eax, eax
    rep stosb
    mov ax, [rel net_udp_src_port]
    xchg al, ah
    mov [rel net_udp_segment + 0], ax
    mov ax, [rel net_udp_dst_port]
    xchg al, ah
    mov [rel net_udp_segment + 2], ax
    mov ax, [rel net_udp_payload_len]
    add ax, 8
    xchg al, ah
    mov [rel net_udp_segment + 4], ax
    mov word [rel net_udp_segment + 6], 0 ; IPv4 UDP checksum is optional.

    mov rsi, [rel net_udp_payload_ptr]
    lea rdi, [rel net_udp_segment + 8]
    mov ecx, [rel net_udp_payload_len]
    rep movsb

    lea rdi, [rel net_udp_segment]
    mov ecx, [rel net_udp_payload_len]
    add ecx, 8
    mov esi, [rel net_udp_dst_ip]
    mov rdx, [rel net_udp_next_hop_mac_ptr]
    mov al, NET_IP_PROTO_UDP
    call net_ipv4_tx_proto
    jmp .done
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

; RDI = IPv4 packet, ECX = IPv4 packet length. Returns EAX=1 if consumed.
global net_udp_rx_ipv4
net_udp_rx_ipv4:
    push rcx
    push rdx
    push rdi
    push rsi
    cmp ecx, 28
    jb .drop
    movzx eax, byte [rdi]
    and eax, 0x0F
    shl eax, 2
    cmp eax, 20
    jb .drop
    cmp ecx, eax
    jbe .drop
    add rdi, rax
    sub ecx, eax
    cmp ecx, 8
    jb .drop
    mov si, [rdi + 0]
    mov dx, [rdi + 2]
    movzx eax, word [rdi + 4]
    xchg al, ah
    cmp eax, 8
    jb .drop
    cmp eax, ecx
    ja .drop
    sub eax, 8
    lea rdi, [rdi + 8]
    mov ecx, eax
    call net_dns_rx_udp
    jmp .done
.drop:
    xor eax, eax
.done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

section .bss
alignb 16
net_udp_segment: resb 1480
net_udp_dst_ip:  resd 1
net_udp_dst_port: resw 1
net_udp_src_port: resw 1
net_udp_payload_ptr: resq 1
net_udp_payload_len: resd 1
net_udp_next_hop_mac_ptr: resq 1
