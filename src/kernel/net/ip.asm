; ============================================================================
; GritOS IPv4 protocol module
; ----------------------------------------------------------------------------
; Generic packet construction above the selected NIC. Drivers must not build IP
; packets; they only transmit complete Ethernet frames through net_nic_tx_frame.
; ============================================================================
bits 64

%include "net_driver.inc"

extern net_checksum
extern net_arp_rx_frame
extern net_info
extern net_nic_mac
extern net_nic_tx_frame
extern net_tcp_rx_ipv4
extern net_udp_rx_ipv4

section .text

; RDI = payload, ECX = payload length, ESI = dst IPv4 as A.B.C.D packed,
; RDX = destination MAC, AL = protocol. Returns EAX=1 on queued/sent.
global net_ipv4_tx_proto
net_ipv4_tx_proto:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp ecx, 1480
    ja .fail
    mov [rel net_ipv4_payload_ptr], rdi
    mov [rel net_ipv4_payload_len], ecx
    mov [rel net_ipv4_dst_ip], esi
    mov [rel net_ipv4_proto], al

    ; Ethernet header.
    mov rsi, rdx
    lea rdi, [rel net_ipv4_frame]
    mov ecx, 6
    rep movsb
    lea rdi, [rel net_ipv4_frame + 6]
    call net_nic_mac
    test eax, eax
    jz .fail
    mov word [rel net_ipv4_frame + 12], NET_ETH_TYPE_IPV4

    ; IPv4 header.
    lea rdi, [rel net_ipv4_frame + 14]
    mov ecx, 20
    xor eax, eax
    rep stosb
    mov byte [rel net_ipv4_frame + 14], 0x45
    mov byte [rel net_ipv4_frame + 15], 0
    mov eax, [rel net_ipv4_payload_len]
    add eax, 20
    xchg al, ah
    mov [rel net_ipv4_frame + 16], ax
    inc word [rel net_ipv4_id]
    mov ax, [rel net_ipv4_id]
    xchg al, ah
    mov [rel net_ipv4_frame + 18], ax
    mov word [rel net_ipv4_frame + 20], 0
    mov byte [rel net_ipv4_frame + 22], 64
    mov al, [rel net_ipv4_proto]
    mov [rel net_ipv4_frame + 23], al
    mov word [rel net_ipv4_frame + 24], 0
    mov rdi, 2                           ; NI_IP from SYS_NET_INFO
    call net_info
    test eax, eax
    jz .fail
    bswap eax
    mov [rel net_ipv4_frame + 26], eax
    mov eax, [rel net_ipv4_dst_ip]
    bswap eax
    mov [rel net_ipv4_frame + 30], eax
    lea rdi, [rel net_ipv4_frame + 14]
    mov ecx, 20
    call net_checksum
    mov [rel net_ipv4_frame + 24], ax

    ; Payload.
    mov ecx, [rel net_ipv4_payload_len]
    mov rsi, [rel net_ipv4_payload_ptr]
    lea rdi, [rel net_ipv4_frame + 34]
    rep movsb
    mov ecx, [rel net_ipv4_payload_len]
    add ecx, 34
    lea rdi, [rel net_ipv4_frame]
    call net_nic_tx_frame
    jmp .done
.fail:
    xor eax, eax
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI = complete Ethernet frame, ECX = frame length. Called by drivers as RX is
; lifted out of the legacy paths.
global net_rx_frame
net_rx_frame:
    push rcx
    push rdi
    call net_arp_rx_frame
    test eax, eax
    pop rdi
    pop rcx
    jnz .consumed
    cmp ecx, 34
    jb .drop
    cmp word [rdi + 12], NET_ETH_TYPE_IPV4
    jne .drop
    lea rdi, [rdi + 14]
    sub ecx, 14
    jmp net_ipv4_rx_packet
.drop:
    xor eax, eax
    ret
.consumed:
    mov eax, 1
    ret

; RDI = IPv4 packet, ECX = packet length.
global net_ipv4_rx_packet
net_ipv4_rx_packet:
    cmp ecx, 20
    jb .drop
    mov al, [rdi]
    and al, 0xF0
    cmp al, 0x40
    jne .drop
    mov al, [rdi + 9]
    cmp al, NET_IP_PROTO_TCP
    je .tcp
    cmp al, NET_IP_PROTO_UDP
    je .udp
    xor eax, eax
    ret
.tcp:
    call net_tcp_rx_ipv4
    ret
.udp:
    call net_udp_rx_ipv4
    ret
.drop:
    xor eax, eax
    ret

section .bss
alignb 16
net_ipv4_frame: resb 1518
net_ipv4_id:    resw 1
net_ipv4_payload_ptr: resq 1
net_ipv4_payload_len: resd 1
net_ipv4_dst_ip:      resd 1
net_ipv4_proto:       resb 1
