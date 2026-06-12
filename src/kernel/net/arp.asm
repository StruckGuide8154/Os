; ============================================================================
; GritOS ARP protocol module
; ----------------------------------------------------------------------------
; Generic ARP resolver above net_nic_tx_frame/net_nic_poll_rx. Drivers only
; move Ethernet frames; ARP cache and packet format live here.
; ============================================================================
bits 64

%include "net_driver.inc"

extern net_info
extern net_nic_mac
extern net_nic_poll_rx
extern net_nic_tx_frame
extern tick_count

section .text

; EDI = IPv4 address as A.B.C.D packed. Returns EAX=1 and copies the resolved
; MAC to net_arp_resolved_mac. This is intentionally a one-entry cache for now.
global net_arp_resolve_ipv4
net_arp_resolve_ipv4:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov [rel net_arp_target_host], edi
    mov eax, edi
    bswap eax
    mov [rel net_arp_target_net], eax

    cmp byte [rel net_arp_cache_valid], 1
    jne .send
    cmp [rel net_arp_cache_ip], eax
    jne .send
    lea rsi, [rel net_arp_cache_mac]
    lea rdi, [rel net_arp_resolved_mac]
    mov ecx, 6
    rep movsb
    mov eax, 1
    jmp .done

.send:
    mov byte [rel net_arp_waiting], 1
    mov byte [rel net_arp_cache_valid], 0
    call net_arp_send_request
    test eax, eax
    jz .fail
    mov rbx, [tick_count]
    add rbx, 100                         ; 1 second at 100 Hz
.wait:
    call net_nic_poll_rx
    cmp byte [rel net_arp_cache_valid], 1
    je .resolved
    mov rax, [tick_count]
    cmp rax, rbx
    jae .fail
    pause
    jmp .wait
.resolved:
    lea rsi, [rel net_arp_cache_mac]
    lea rdi, [rel net_arp_resolved_mac]
    mov ecx, 6
    rep movsb
    mov byte [rel net_arp_waiting], 0
    mov eax, 1
    jmp .done
.fail:
    mov byte [rel net_arp_waiting], 0
    xor eax, eax
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Non-blocking variant. EDI = IPv4 (A.B.C.D packed). If the MAC is cached,
; copies it to net_arp_resolved_mac and returns EAX=1. Otherwise it fires ONE
; ARP request and returns EAX=0 IMMEDIATELY (no busy-wait). The caller is
; expected to retry on a later tick; the main loop's net_nic_poll_rx ->
; net_arp_rx_frame warms the cache in the background. This is the freeze fix:
; the DNS/UDP send path (net_udp_send_ipv4) used the blocking resolver above,
; which pinned the kernel for up to 1s on a cold next-hop MAC.
global net_arp_resolve_ipv4_try
net_arp_resolve_ipv4_try:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov [rel net_arp_target_host], edi
    mov eax, edi
    bswap eax
    mov [rel net_arp_target_net], eax

    cmp byte [rel net_arp_cache_valid], 1
    jne .miss
    cmp [rel net_arp_cache_ip], eax
    jne .miss
    lea rsi, [rel net_arp_cache_mac]
    lea rdi, [rel net_arp_resolved_mac]
    mov ecx, 6
    rep movsb
    mov eax, 1
    jmp .done
.miss:
    mov byte [rel net_arp_waiting], 1
    mov byte [rel net_arp_cache_valid], 0
    call net_arp_send_request            ; single non-blocking request
    xor eax, eax                         ; not resolved yet -> caller retries
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Returns RAX = pointer to the most recently resolved MAC.
global net_arp_resolved_mac_ptr
net_arp_resolved_mac_ptr:
    lea rax, [rel net_arp_resolved_mac]
    ret

net_arp_send_request:
    push rcx
    push rdi
    push rsi
    lea rdi, [rel net_arp_frame]
    mov ecx, 60
    xor eax, eax
    rep stosb

    lea rdi, [rel net_arp_frame]
    mov ecx, 6
    mov al, 0xFF
    rep stosb
    lea rdi, [rel net_arp_frame + 6]
    call net_nic_mac
    test eax, eax
    jz .fail
    mov word [rel net_arp_frame + 12], NET_ETH_TYPE_ARP
    mov word [rel net_arp_frame + 14], 0x0100
    mov word [rel net_arp_frame + 16], NET_ETH_TYPE_IPV4
    mov byte [rel net_arp_frame + 18], 6
    mov byte [rel net_arp_frame + 19], 4
    mov word [rel net_arp_frame + 20], 0x0100
    lea rdi, [rel net_arp_frame + 22]
    call net_nic_mac
    test eax, eax
    jz .fail
    mov rdi, 2                           ; NI_IP
    call net_info
    test eax, eax
    jz .fail
    bswap eax
    mov [rel net_arp_frame + 28], eax
    mov dword [rel net_arp_frame + 32], 0
    mov word [rel net_arp_frame + 36], 0
    mov eax, [rel net_arp_target_net]
    mov [rel net_arp_frame + 38], eax
    lea rdi, [rel net_arp_frame]
    mov ecx, 60
    call net_nic_tx_frame
    jmp .done
.fail:
    xor eax, eax
.done:
    pop rsi
    pop rdi
    pop rcx
    ret

; RDI = complete Ethernet frame, ECX = frame length. Returns EAX=1 if consumed.
global net_arp_rx_frame
net_arp_rx_frame:
    cmp ecx, 42
    jb .drop
    cmp word [rdi + 12], NET_ETH_TYPE_ARP
    jne .drop
    cmp word [rdi + 20], 0x0200          ; ARP reply
    jne .drop
    cmp byte [rel net_arp_waiting], 1
    jne .drop
    mov eax, [rel net_arp_target_net]
    cmp [rdi + 28], eax                  ; sender protocol address
    jne .drop
    mov [rel net_arp_cache_ip], eax
    lea rsi, [rdi + 22]                  ; sender hardware address
    lea rdi, [rel net_arp_cache_mac]
    mov ecx, 6
    rep movsb
    lea rsi, [rel net_arp_cache_mac]
    lea rdi, [rel net_arp_resolved_mac]
    mov ecx, 6
    rep movsb
    mov byte [rel net_arp_cache_valid], 1
    mov eax, 1
    ret
.drop:
    xor eax, eax
    ret

section .bss
alignb 16
net_arp_frame:        resb 60
net_arp_target_host:  resd 1
net_arp_target_net:   resd 1
net_arp_cache_ip:     resd 1
net_arp_cache_mac:    resb 6
net_arp_resolved_mac: resb 6
net_arp_cache_valid:  resb 1
net_arp_waiting:      resb 1
