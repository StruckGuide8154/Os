
; ============================================================================
; rtl8139_init - Locate and start a QEMU RTL8139 NIC.
; Returns EAX=1 if active, EAX=0 otherwise.
; ============================================================================
global rtl8139_init
rtl8139_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov rsi, sz_net_start
    call debug_print
    lea rsi, [rel ser_net_init]
    call rtl_ser_puts

    call rtl8139_find
    test eax, eax
    jz .fail

    ; Power on, reset, and enable RX/TX.
    mov dx, [rtl_io_base]
    add dx, RTL_CONFIG1
    xor al, al
    out dx, al

    mov dx, [rtl_io_base]
    add dx, RTL_CR
    mov al, RTL_CR_RST
    out dx, al
    mov rbx, [tick_count]
    add rbx, 100
.rst_wait:
    in al, dx
    test al, RTL_CR_RST
    jz .rst_done
    mov rax, [tick_count]
    cmp rax, rbx
    jae .fail
    pause
    jmp .rst_wait
.rst_done:

    ; Read MAC address from IDR0..5.
    mov dx, [rtl_io_base]
    add dx, RTL_IDR0
    lea rdi, [rtl_mac]
    mov ecx, 6
.mac_loop:
    in al, dx
    mov [rdi], al
    inc dx
    inc rdi
    loop .mac_loop

    ; Clear DMA buffers.
    mov rdi, RTL_RX_BUF_ADDR
    mov ecx, (RTL_RX_BUF_LEN + 16 + 1500) / 8
    xor rax, rax
    rep stosq
    mov rdi, RTL_TX_BUF_ADDR
    mov ecx, 2048 / 8
    rep stosq

    ; RX buffer base.
    mov dx, [rtl_io_base]
    add dx, RTL_RBSTART
    mov eax, RTL_RX_BUF_ADDR
    out dx, eax

    ; Disable interrupts; this driver polls.
    mov dx, [rtl_io_base]
    add dx, RTL_IMR
    xor ax, ax
    out dx, ax
    mov dx, [rtl_io_base]
    add dx, RTL_ISR
    mov ax, 0xFFFF
    out dx, ax

    ; RCR: accept broadcast + physical-match packets, 8K ring, wrap.
    mov dx, [rtl_io_base]
    add dx, RTL_RCR
    mov eax, 0x0000F00E
    out dx, eax

    ; TCR: QEMU default-safe transmit config.
    mov dx, [rtl_io_base]
    add dx, RTL_TCR
    mov eax, 0x03000700
    out dx, eax

    mov dx, [rtl_io_base]
    add dx, RTL_CR
    mov al, RTL_CR_RE | RTL_CR_TE
    out dx, al

    ; Kick PHY auto-negotiation and wait for link.
    mov dx, [rtl_io_base]
    add dx, RTL_BMCR
    mov ax, RTL_BMCR_ANE | RTL_BMCR_RAN
    out dx, ax

    lea rsi, [rel ser_link_wait]
    call rtl_ser_puts
    mov rbx, [tick_count]
    add rbx, 500                         ; up to 5 s for link
.link_wait:
    mov dx, [rtl_io_base]
    add dx, RTL_MSR
    in al, dx
    test al, RTL_MSR_LINKB
    jz .link_up
    mov rax, [tick_count]
    cmp rax, rbx
    jae .link_timeout
    pause
    jmp .link_wait
.link_timeout:
    lea rsi, [rel ser_link_timeout]
    call rtl_ser_puts
    jmp .link_done
.link_up:
    lea rsi, [rel ser_link_up]
    call rtl_ser_puts
    ; Wait briefly for auto-neg complete bit too (best-effort).
    mov rbx, [tick_count]
    add rbx, 100
.anc_wait:
    mov dx, [rtl_io_base]
    add dx, RTL_BMSR
    in ax, dx
    test ax, RTL_BMSR_ANC
    jnz .link_done
    mov rax, [tick_count]
    cmp rax, rbx
    jae .link_done
    pause
    jmp .anc_wait
.link_done:

    mov word [rtl_rx_off], 0
    mov byte [rtl_active], 1
    mov rsi, sz_net_ready
    call debug_print
    lea rsi, [rel ser_net_ready]
    call rtl_ser_puts
    mov eax, 1
    jmp .done

.fail:
    mov byte [rtl_active], 0
    mov rsi, sz_net_fail
    call debug_print
    lea rsi, [rel ser_net_init_fail]
    call rtl_ser_puts
    xor eax, eax
.done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; rtl8139_icmp_ping_gateway - ARP 10.0.2.2 then send ICMP echo.
; Returns EAX=1 on echo reply, EAX=0 on failure/timeout.
; ============================================================================
global rtl8139_icmp_ping_gateway
rtl8139_icmp_ping_gateway:
    mov dword [rtl_guest_ip], 0x0F02000A       ; 10.0.2.15
    mov dword [rtl_next_hop_ip], 0x0202000A    ; 10.0.2.2
    mov dword [rtl_target_ip], 0x0202000A      ; 10.0.2.2
    jmp rtl8139_icmp_ping_current

global rtl8139_icmp_ping_ics
rtl8139_icmp_ping_ics:
    mov dword [rtl_guest_ip], 0x3289A8C0       ; 192.168.137.50
    mov dword [rtl_next_hop_ip], 0x0189A8C0    ; 192.168.137.1
    mov dword [rtl_target_ip], 0x0189A8C0      ; 192.168.137.1
    jmp rtl8139_icmp_ping_current

; EDI = IPv4 address in host-order dotted-quad packing (A.B.C.D = 0xAABBCCDD).
; Runs DHCP first to obtain a real lease (works on QEMU user-net and any real
; DHCP-capable network); falls back to QEMU-static config if DHCP fails.
global rtl8139_icmp_ping_ipv4
rtl8139_icmp_ping_ipv4:
    push rdi
    cmp byte [rtl_active], 1
    je .have_nic
    call rtl8139_init
    test eax, eax
    jz .skip_dhcp
.have_nic:
    cmp byte [rtl_dhcp_bound], 1
    je .skip_dhcp
    call rtl8139_dhcp_configure
.skip_dhcp:
    pop rdi
    cmp byte [rtl_dhcp_bound], 1
    jne .static_cfg
    mov eax, [rtl_dhcp_ip]
    mov [rtl_guest_ip], eax
    mov eax, [rtl_dhcp_router]
    test eax, eax
    jnz .gw_ok
    mov eax, [rtl_dhcp_server]
.gw_ok:
    mov [rtl_next_hop_ip], eax
    jmp .set_target
.static_cfg:
    mov dword [rtl_guest_ip], 0x0F02000A       ; 10.0.2.15
    mov dword [rtl_next_hop_ip], 0x0202000A    ; 10.0.2.2
.set_target:
    mov eax, edi
    bswap eax
    mov [rtl_target_ip], eax
    jmp rtl8139_icmp_ping_current

rtl8139_icmp_ping_current:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12

    cmp byte [rtl_active], 1
    je .active
    call rtl8139_init
    test eax, eax
    jz .fail
.active:
    mov rax, [tick_count]
    mov [rtl_ping_start_tick], rax
    mov byte [rtl_have_gw_mac], 0
    lea rsi, [rel ser_arp_send]
    call rtl_ser_puts
    call rtl8139_send_arp_gateway
    mov rbx, [tick_count]
    add rbx, 200
.arp_wait:
    call rtl8139_poll_rx
    cmp byte [rtl_have_gw_mac], 1
    je .got_arp
    mov rax, [tick_count]
    cmp rax, rbx
    jae .fail
    pause
    jmp .arp_wait
.got_arp:
    mov byte [rtl_ping_reply], 0
    lea rsi, [rel ser_icmp_send]
    call rtl_ser_puts
    call rtl8139_send_icmp_gateway
    mov rbx, [tick_count]
    add rbx, 200
.icmp_wait:
    call rtl8139_poll_rx
    cmp byte [rtl_ping_reply], 1
    je .ok
    mov rax, [tick_count]
    cmp rax, rbx
    jae .fail
    pause
    jmp .icmp_wait
.ok:
    mov rsi, sz_ping_ok
    call debug_print
    lea rsi, [rel ser_icmp_ok]
    call rtl_ser_puts
    mov eax, 1
    jmp .done
.fail:
    mov rsi, sz_ping_fail
    call debug_print
    lea rsi, [rel ser_icmp_fail]
    call rtl_ser_puts
    xor eax, eax
.done:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

rtl8139_find:
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    xor r12d, r12d
.bus:
    cmp r12d, 256
    jae .nf
    xor r13d, r13d
.dev:
    cmp r13d, 32
    jae .next_bus
    xor r14d, r14d
.fn:
    cmp r14d, 8
    jae .next_dev
    mov eax, r12d
    shl eax, 16
    mov ebx, r13d
    shl ebx, 11
    or eax, ebx
    mov ebx, r14d
    shl ebx, 8
    or eax, ebx
    mov [rtl_pci_addr], eax
    call pci_read_conf_dword
    cmp ax, RTL_VENDOR
    jne .next_fn
    shr eax, 16
    cmp ax, RTL_DEVICE
    jne .next_fn

    ; Enable I/O space + bus mastering.
    mov eax, [rtl_pci_addr]
    or eax, 0x04
    call pci_read_conf_dword
    or eax, 0x0005
    mov ecx, eax
    mov eax, [rtl_pci_addr]
    or eax, 0x04
    call pci_write_conf_dword

    ; BAR0 is I/O space for rtl8139.
    mov eax, [rtl_pci_addr]
    or eax, 0x10
    call pci_read_conf_dword
    and eax, 0xFFFFFFFC
    mov [rtl_io_base], ax
    mov eax, 1
    jmp .done
.next_fn:
    inc r14d
    jmp .fn
.next_dev:
    inc r13d
    jmp .dev
.next_bus:
    inc r12d
    jmp .bus
.nf:
    xor eax, eax
.done:
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret
