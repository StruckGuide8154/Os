rtl8139_send_arp_gateway:
    push rax
    push rcx
    push rsi
    push rdi
    mov rdi, RTL_TX_BUF_ADDR
    mov ecx, 60
    xor eax, eax
    rep stosb
    mov rdi, RTL_TX_BUF_ADDR
    mov ecx, 6
    mov al, 0xFF
    rep stosb
    lea rsi, [rtl_mac]
    mov ecx, 6
    rep movsb
    mov word [rdi], 0x0608             ; ethertype ARP
    add rdi, 2
    mov word [rdi], 0x0100             ; Ethernet
    mov word [rdi + 2], 0x0008         ; IPv4
    mov byte [rdi + 4], 6
    mov byte [rdi + 5], 4
    mov word [rdi + 6], 0x0100         ; request
    lea rsi, [rtl_mac]
    mov rdi, RTL_TX_BUF_ADDR + 22
    mov ecx, 6
    rep movsb
    mov eax, [rtl_guest_ip]
    mov dword [abs RTL_TX_BUF_ADDR + 28], eax
    mov qword [abs RTL_TX_BUF_ADDR + 32], 0
    mov eax, [rtl_next_hop_ip]
    mov dword [abs RTL_TX_BUF_ADDR + 38], eax
    mov ecx, 60
    call rtl8139_tx
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

rtl8139_send_icmp_gateway:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov rdi, RTL_TX_BUF_ADDR
    mov ecx, 60
    xor eax, eax
    rep stosb
    mov rdi, RTL_TX_BUF_ADDR
    lea rsi, [rtl_gw_mac]
    mov ecx, 6
    rep movsb
    lea rsi, [rtl_mac]
    mov ecx, 6
    rep movsb
    mov word [rdi], 0x0008             ; ethertype IPv4
    add rdi, 2
    ; IPv4 header at +14
    mov byte [abs RTL_TX_BUF_ADDR + 14], 0x45
    mov byte [abs RTL_TX_BUF_ADDR + 15], 0
    mov word [abs RTL_TX_BUF_ADDR + 16], 0x1C00 ; 28 bytes
    mov word [abs RTL_TX_BUF_ADDR + 18], 0x3412
    mov word [abs RTL_TX_BUF_ADDR + 20], 0
    mov byte [abs RTL_TX_BUF_ADDR + 22], 64
    mov byte [abs RTL_TX_BUF_ADDR + 23], 1      ; ICMP
    mov word [abs RTL_TX_BUF_ADDR + 24], 0
    mov eax, [rtl_guest_ip]
    mov dword [abs RTL_TX_BUF_ADDR + 26], eax
    mov eax, [rtl_target_ip]
    mov dword [abs RTL_TX_BUF_ADDR + 30], eax
    mov rdi, RTL_TX_BUF_ADDR + 14
    mov ecx, 20
    call net_checksum
    mov [abs RTL_TX_BUF_ADDR + 24], ax
    ; ICMP header at +34
    mov byte [abs RTL_TX_BUF_ADDR + 34], 8
    mov byte [abs RTL_TX_BUF_ADDR + 35], 0
    mov word [abs RTL_TX_BUF_ADDR + 36], 0
    mov word [abs RTL_TX_BUF_ADDR + 38], 0xBEEF
    inc word [rtl_ping_seq]
    mov ax, [rtl_ping_seq]
    xchg al, ah
    mov [abs RTL_TX_BUF_ADDR + 40], ax
    mov rdi, RTL_TX_BUF_ADDR + 34
    mov ecx, 8
    call net_checksum
    mov [abs RTL_TX_BUF_ADDR + 36], ax
    mov ecx, 60
    call rtl8139_tx
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ECX = frame length, frame at RTL_TX_BUF_ADDR.
rtl8139_tx:
    push rax
    push rbx
    push rdx
    mov dx, [rtl_io_base]
    add dx, RTL_TSAD0
    mov eax, RTL_TX_BUF_ADDR
    out dx, eax
    mov dx, [rtl_io_base]
    add dx, RTL_TSD0
    mov eax, ecx
    out dx, eax
    mov rbx, [tick_count]
    add rbx, 100
.wait:
    in eax, dx
    test eax, 0x00008000
    jnz .done
    mov rax, [tick_count]
    cmp rax, rbx
    jae .done
    pause
    jmp .wait
.done:
    pop rdx
    pop rbx
    pop rax
    ret

; Generic NIC ABI wrapper. RDI = complete Ethernet frame, ECX = length.
global rtl8139_net_tx_frame
rtl8139_net_tx_frame:
    push rcx
    push rsi
    push rdi
    push r8
    ; SECURITY (GSEC net): bound the caller length before the rep movsb below,
    ; which copies ecx bytes into the fixed RTL_TX_BUF_ADDR DMA buffer. Without
    ; this, an oversized length overruns into adjacent kernel memory (guard-page
    ; PoC confirmed). Defence in depth: net_nic_tx_frame already checks, but this
    ; wrapper is 'global' and reachable directly, so it must not trust callers.
    cmp ecx, NET_ETH_FRAME_MAX
    ja .reject
    cmp ecx, NET_ETH_FRAME_MIN
    jb .reject
    cmp byte [rtl_active], 1
    je .active
    call rtl8139_init
    test eax, eax
    jz .fail
.active:
    mov r8d, ecx
    mov rsi, rdi
    mov rdi, RTL_TX_BUF_ADDR
    cld
    rep movsb
    mov ecx, r8d
    call rtl8139_tx
    mov eax, 1
    jmp .done
.reject:
%ifndef RELEASE_BUILD
    ; Debug builds surface a rejected TX length loudly instead of copying it.
    push rsi
    mov rsi, ser_tx_len_reject
    call debug_print
    pop rsi
%endif
.fail:
    xor eax, eax
.done:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret

global rtl8139_net_poll_rx
rtl8139_net_poll_rx:
    cmp byte [rtl_active], 1
    jne .no_work
    call rtl8139_poll_rx
    mov eax, 1
    ret
.no_work:
    xor eax, eax
    ret

rtl8139_poll_rx:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    cmp byte [rtl_active], 1
    jne .done
.loop:
    mov dx, [rtl_io_base]
    add dx, RTL_CR
    in al, dx
    test al, RTL_CR_BUFE
    jnz .done
    movzx ebx, word [rtl_rx_off]
    lea rsi, [RTL_RX_BUF_ADDR + rbx]
    mov ax, [rsi]
    test ax, 1
    jz .advance
    movzx ecx, word [rsi + 2]            ; device-reported RX frame length
    ; SECURITY (GSEC net): the RTL8139 RX-status length word is device-supplied
    ; and MUST NOT be trusted as an in-bounds length. Clamp it to the bytes that
    ; physically remain in the 8 KiB ring from this frame's payload start, so a
    ; corrupt / oversized descriptor length can never drive net_rx_frame -> IP/TCP
    ; to read past RTL_RX_BUF_ADDR + RTL_RX_BUF_LEN. This upholds the ecx = "true
    ; buffer length" contract that net_tcp_rx_ipv4's memory-safety proof depends on
    ; (docs/security/proof-net-tcp-rx.md). avail = (RTL_RX_BUF_LEN-4) - rx_off;
    ; the subtract borrows (CF=1) iff rx_off > RTL_RX_BUF_LEN-4 -> corrupt, drop.
    mov eax, RTL_RX_BUF_LEN - 4
    sub eax, ebx                         ; ebx = rtl_rx_off (frame header offset)
    jc .advance                          ; rx_off past ring -> fail-closed
    cmp ecx, eax
    jbe .len_ok
    mov ecx, eax                         ; clamp to ring-remaining bytes
.len_ok:
    cmp ecx, 14
    jb .advance
    lea rdi, [rsi + 4]
    call rtl8139_handle_frame
.advance:
    movzx eax, word [rsi + 2]
    add eax, 4
    add eax, 3
    and eax, 0xFFFFFFFC
    add ax, [rtl_rx_off]
    and ax, RTL_RX_BUF_LEN - 1
    mov [rtl_rx_off], ax
    mov dx, [rtl_io_base]
    add dx, RTL_CAPR
    sub ax, 16
    out dx, ax
    jmp .loop
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; RDI = Ethernet frame, ECX = frame length.
rtl8139_handle_frame:
    push rax
    push rcx
    push rsi
    push rdi
    push rcx
    call net_rx_frame
    pop rcx
    pop rdi
    cmp word [rdi + 12], 0x0608
    je .arp
    cmp word [rdi + 12], 0x0008
    je .ip
    jmp .done
.arp:
    cmp ecx, 42
    jb .done
    cmp word [rdi + 20], 0x0200        ; reply
    jne .done
    mov eax, [rtl_next_hop_ip]
    cmp dword [rdi + 28], eax
    jne .done
    lea rsi, [rdi + 22]
    lea rdi, [rtl_gw_mac]
    mov ecx, 6
    rep movsb
    mov byte [rtl_have_gw_mac], 1
    mov rsi, sz_arp_ok
    call debug_print
    lea rsi, [rel ser_arp_ok]
    call rtl_ser_puts
    jmp .done
.ip:
    cmp ecx, 42
    jb .done
    cmp byte [rdi + 23], 1             ; ICMP
    je .icmp
    cmp byte [rdi + 23], 17            ; UDP
    je .udp
    jmp .done
.icmp:
    mov eax, [rtl_target_ip]
    cmp dword [rdi + 26], eax
    jne .done
    mov eax, [rtl_guest_ip]
    cmp dword [rdi + 30], eax
    jne .done
    cmp byte [rdi + 34], 0             ; echo reply
    jne .done
    ; Capture TTL (IPv4 header offset 8 == frame+22) for net_info(NI_PING_LAST_TTL).
    mov al, [rdi + 22]
    mov [rtl_ping_last_ttl], al
    mov byte [rtl_ping_reply], 1
    jmp .done
.udp:
    call rtl8139_handle_udp
.done:
    pop rsi
    pop rcx
    pop rax
    ret

; ============================================================================