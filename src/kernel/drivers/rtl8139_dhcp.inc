; DHCP client
; ============================================================================
global rtl8139_dhcp_configure
rtl8139_dhcp_configure:
    push rbx
    push rcx
    push rdx
    push rsi
    lea rsi, [rel ser_dhcp_start_8139]
    call rtl_ser_puts
    mov byte [rtl_dhcp_bound], 0
    mov byte [rtl_dhcp_state], 1
    mov byte [rtl_dhcp_offer_seen], 0
    mov byte [rtl_dhcp_ack_seen], 0
    inc dword [rtl_dhcp_xid]
    cmp dword [rtl_dhcp_xid], 0
    jne .xid_ok
    mov dword [rtl_dhcp_xid], 0x47524448
.xid_ok:
    call rtl8139_send_dhcp_discover
    mov rbx, [tick_count]
    add rbx, 300
.offer_wait:
    call rtl8139_poll_selected
    cmp byte [rtl_dhcp_offer_seen], 1
    je .request
    mov rax, [tick_count]
    cmp rax, rbx
    jae .fail
    pause
    jmp .offer_wait
.request:
    lea rsi, [rel ser_dhcp_offer_8139]
    call rtl_ser_puts
    mov byte [rtl_dhcp_state], 2
    call rtl8139_send_dhcp_request
    mov rbx, [tick_count]
    add rbx, 200
.ack_wait:
    call rtl8139_poll_selected
    cmp byte [rtl_dhcp_ack_seen], 1
    je .ok
    mov rax, [tick_count]
    cmp rax, rbx
    jae .ack_timeout
    pause
    jmp .ack_wait
.ack_timeout:
    ; QEMU slirp sometimes does not ACK; treat OFFER as binding.
    cmp byte [rtl_dhcp_offer_seen], 1
    jne .fail
.ok:
    lea rsi, [rel ser_dhcp_ack_8139]
    call rtl_ser_puts
    mov byte [rtl_dhcp_bound], 1
    mov byte [rtl_dhcp_state], 3
    mov eax, 1
    jmp .done
.fail:
    lea rsi, [rel ser_dhcp_fail_8139]
    call rtl_ser_puts
    mov byte [rtl_dhcp_state], 4
    xor eax, eax
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

global rtl8139_send_dhcp_discover
rtl8139_send_dhcp_discover:
    push rax
    push rcx
    push rdi
    call rtl8139_build_dhcp_base
    mov rdi, RTL_TX_BUF_ADDR + 14 + 20 + 8 + 240
    mov byte [rdi + 0], 53
    mov byte [rdi + 1], 1
    mov byte [rdi + 2], 1                ; DISCOVER
    add rdi, 3
    mov byte [rdi + 0], 55
    mov byte [rdi + 1], 3
    mov byte [rdi + 2], 1
    mov byte [rdi + 3], 3
    mov byte [rdi + 4], 6
    add rdi, 5
    mov byte [rdi], 255
    mov rcx, rdi
    sub rcx, (RTL_TX_BUF_ADDR + 14 + 20 + 8)
    inc ecx
    call rtl8139_finish_dhcp_udp
    pop rdi
    pop rcx
    pop rax
    ret

global rtl8139_send_dhcp_request
rtl8139_send_dhcp_request:
    push rax
    push rcx
    push rdi
    call rtl8139_build_dhcp_base
    mov rdi, RTL_TX_BUF_ADDR + 14 + 20 + 8 + 240
    mov byte [rdi + 0], 53
    mov byte [rdi + 1], 1
    mov byte [rdi + 2], 3                ; REQUEST
    add rdi, 3
    mov byte [rdi + 0], 50
    mov byte [rdi + 1], 4
    mov eax, [rtl_dhcp_ip]
    mov [rdi + 2], eax
    add rdi, 6
    mov byte [rdi + 0], 54
    mov byte [rdi + 1], 4
    mov eax, [rtl_dhcp_server]
    mov [rdi + 2], eax
    add rdi, 6
    mov byte [rdi + 0], 55
    mov byte [rdi + 1], 3
    mov byte [rdi + 2], 1
    mov byte [rdi + 3], 3
    mov byte [rdi + 4], 6
    add rdi, 5
    mov byte [rdi], 255
    mov rcx, rdi
    sub rcx, (RTL_TX_BUF_ADDR + 14 + 20 + 8)
    inc ecx
    call rtl8139_finish_dhcp_udp
    pop rdi
    pop rcx
    pop rax
    ret

rtl8139_build_dhcp_base:
    push rax
    push rcx
    push rsi
    push rdi
    mov rdi, RTL_TX_BUF_ADDR
    mov ecx, 342
    xor eax, eax
    rep stosb
    mov rdi, RTL_TX_BUF_ADDR
    mov ecx, 6
    mov al, 0xFF
    rep stosb
    call net_nic_mac
    add rdi, 6
    mov word [rdi], 0x0008
    ; IPv4 header @ +14
    mov byte [abs RTL_TX_BUF_ADDR + 14], 0x45
    mov byte [abs RTL_TX_BUF_ADDR + 15], 0
    mov word [abs RTL_TX_BUF_ADDR + 18], 0x7856
    mov word [abs RTL_TX_BUF_ADDR + 20], 0
    mov byte [abs RTL_TX_BUF_ADDR + 22], 64
    mov byte [abs RTL_TX_BUF_ADDR + 23], 17
    mov word [abs RTL_TX_BUF_ADDR + 24], 0
    mov dword [abs RTL_TX_BUF_ADDR + 26], 0
    mov dword [abs RTL_TX_BUF_ADDR + 30], 0xFFFFFFFF
    ; UDP header @ +34
    mov word [abs RTL_TX_BUF_ADDR + 34], 0x4400  ; src 68
    mov word [abs RTL_TX_BUF_ADDR + 36], 0x4300  ; dst 67
    mov word [abs RTL_TX_BUF_ADDR + 40], 0       ; checksum 0 (optional)
    ; BOOTP @ +42
    mov rdi, RTL_TX_BUF_ADDR + 42
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 1
    mov byte [rdi + 2], 6
    mov byte [rdi + 3], 0
    mov eax, [rtl_dhcp_xid]
    mov [rdi + 4], eax
    mov word [rdi + 10], 0x0080              ; broadcast flag
    lea rdi, [rdi + 28]
    call net_nic_mac
    mov dword [abs RTL_TX_BUF_ADDR + 42 + 236], 0x63538263 ; magic cookie
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ECX = UDP payload length (DHCP message length from BOOTP start).
rtl8139_finish_dhcp_udp:
    push rax
    push rcx
    push rdi
    mov eax, ecx
    add eax, 8
    xchg al, ah
    mov [abs RTL_TX_BUF_ADDR + 38], ax       ; UDP length
    mov eax, ecx
    add eax, 8 + 20
    xchg al, ah
    mov [abs RTL_TX_BUF_ADDR + 16], ax       ; IP total length
    mov rdi, RTL_TX_BUF_ADDR + 14
    mov ecx, 20
    call net_checksum
    mov [abs RTL_TX_BUF_ADDR + 24], ax
    movzx ecx, word [abs RTL_TX_BUF_ADDR + 16]
    xchg cl, ch
    add ecx, 14
    cmp ecx, 60
    jae .len_ok
    mov ecx, 60
.len_ok:
    call rtl8139_tx_selected
    pop rdi
    pop rcx
    pop rax
    ret

; RDI = Ethernet frame, ECX = len.
rtl8139_handle_udp:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    cmp ecx, 282
    jb .done
    cmp word [rdi + 34], 0x4300              ; src port 67
    jne .done
    cmp word [rdi + 36], 0x4400              ; dst port 68
    jne .done
    mov eax, [rtl_dhcp_xid]
    cmp [rdi + 46], eax
    jne .done
    cmp dword [rdi + 278], 0x63538263
    jne .done
    mov eax, [rdi + 58]                      ; yiaddr
    mov [rtl_dhcp_candidate_ip], eax
    mov byte [rtl_dhcp_msg_type], 0
    mov dword [rtl_dhcp_candidate_server], 0
    mov dword [rtl_dhcp_candidate_router], 0
    mov dword [rtl_dhcp_candidate_dns], 0
    lea rsi, [rdi + 282]
    mov r8, rdi
    add r8, rcx
.opt_loop:
    cmp rsi, r8
    jae .classify
    mov al, [rsi]
    cmp al, 255
    je .classify
    cmp al, 0
    je .opt_pad
    ; SECURITY (GSEC net): the option LENGTH byte lives at [rsi+1]. The loop head
    ; only proved rsi < r8 (the type byte is in-frame); reading [rsi+1] when the
    ; type byte is the final frame byte (rsi == r8-1) over-reads 1 byte past the
    ; DHCP frame end. Bounded today (lands in the zeroed 16+1500 ring wrap pad
    ; cleared at init, so it decodes as len 0 and the r9>r8 check drops it) but a
    ; frame ending exactly at the ring's last mapped byte would #PF, and it
    ; violates the "never index past frame end" invariant. Fail-closed: a
    ; truncated option with no length byte terminates option parsing.
    lea rbx, [rsi + 1]                    ; rbx is caller-saved here, al preserved
    cmp rbx, r8
    jae .classify
    movzx edx, byte [rsi + 1]
    lea r9, [rsi + rdx + 2]
    cmp r9, r8
    ja .classify
    cmp al, 53
    je .msg_type
    cmp al, 54
    je .server_id
    cmp al, 3
    je .router
    cmp al, 6
    je .dns_server
    jmp .next_opt
.msg_type:
    cmp edx, 1
    jb .next_opt
    mov al, [rsi + 2]
    mov [rtl_dhcp_msg_type], al
    jmp .next_opt
.server_id:
    cmp edx, 4
    jb .next_opt
    mov eax, [rsi + 2]
    mov [rtl_dhcp_candidate_server], eax
    jmp .next_opt
.router:
    cmp edx, 4
    jb .next_opt
    mov eax, [rsi + 2]
    mov [rtl_dhcp_candidate_router], eax
    jmp .next_opt
.dns_server:
    cmp edx, 4
    jb .next_opt
    mov eax, [rsi + 2]
    mov [rtl_dhcp_candidate_dns], eax
.next_opt:
    mov rsi, r9
    jmp .opt_loop
.opt_pad:
    inc rsi
    jmp .opt_loop
.classify:
    cmp byte [rtl_dhcp_msg_type], 2
    je .offer
    cmp byte [rtl_dhcp_msg_type], 5
    je .ack
    jmp .done
.offer:
    mov eax, [rtl_dhcp_candidate_ip]
    test eax, eax
    jz .done
    mov [rtl_dhcp_ip], eax
    mov eax, [rtl_dhcp_candidate_server]
    mov [rtl_dhcp_server], eax
    mov eax, [rtl_dhcp_candidate_router]
    mov [rtl_dhcp_router], eax
    mov eax, [rtl_dhcp_candidate_dns]
    mov [rtl_dhcp_dns], eax
    mov byte [rtl_dhcp_offer_seen], 1
    jmp .done
.ack:
    mov eax, [rtl_dhcp_candidate_ip]
    test eax, eax
    jz .done
    mov [rtl_dhcp_ip], eax
    mov eax, [rtl_dhcp_candidate_server]
    test eax, eax
    jz .keep_server
    mov [rtl_dhcp_server], eax
.keep_server:
    mov eax, [rtl_dhcp_candidate_router]
    test eax, eax
    jz .keep_router
    mov [rtl_dhcp_router], eax
.keep_router:
    mov eax, [rtl_dhcp_candidate_dns]
    test eax, eax
    jz .keep_dns
    mov [rtl_dhcp_dns], eax
.keep_dns:
    mov byte [rtl_dhcp_ack_seen], 1
.done:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

rtl_ser_putc:
%ifdef RELEASE_BUILD
    ; Release images carry no debug serial. NIC bring-up markers
    ; ([RTL INIT]/[LINK WAIT]/[RTL READY]/...) funnel through this COM1 leaf;
    ; no-op it so they don't ship.
    ret
%endif
    push rax
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rax
    ret

rtl_ser_puts:
    push rax
    push rsi
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    call rtl_ser_putc
    inc rsi
    jmp .loop
.done:
    pop rsi
    pop rax
    ret
