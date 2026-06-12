; ============================================================================
; GritOS active NIC dispatcher
; ----------------------------------------------------------------------------
; Stable kernel-facing network surface used by syscalls/apps and protocol
; modules. Backends register a small ops record, and the dispatcher picks the
; highest-priority active NIC.
;
; Backend contract for new drivers:
;   see src/include/net_driver.inc
;
; Protocol bodies are being lifted out incrementally. Until ARP/DHCP/ICMP are
; fully shared, drivers provide those routines behind this dispatcher so apps
; and syscalls do not depend on a concrete NIC.
; ============================================================================
bits 64

%include "net_driver.inc"

extern rtl8139_icmp_ping_ipv4
extern rtl8139_init
extern rtl8139_dhcp_configure
extern rtl8139_net_tx_frame
extern rtl8139_net_poll_rx
extern rtl8139_net_mac
extern rtl8139_net_info
extern rtl8156_icmp_ping_ipv4
extern rtl8156_init
extern rtl8156_dhcp_configure
extern rtl8156_dhcp_start
extern rtl8156_net_tx_frame
extern rtl8156_net_poll_rx
extern rtl8156_net_mac
extern rtl8156_net_info
extern rtl8156_ping_start_tsc
extern rtl8156_ping_reply_tsc
extern rtl8156_active
extern rtl8156_dhcp_bound
extern rtl8156_dhcp_state
extern rtl8156_ping_last_ttl
extern rtl_ping_last_ttl
extern rtl8156_dhcp_ip
extern rtl8156_dhcp_router
extern rtl8156_dhcp_server
extern rtl8156_dhcp_dns
extern rtl8156_guest_ip
extern rtl8156_next_hop_ip
extern rtl_active
extern rtl_dhcp_bound
extern rtl_dhcp_state
extern rtl_dhcp_ip
extern rtl_dhcp_router
extern rtl_dhcp_server
extern rtl_dhcp_dns
extern rtl_guest_ip
extern rtl_next_hop_ip
extern cpu_tsc_per_tick

section .text

; Register every compiled-in NIC here. New drivers add one ops table and one
; pointer in this list; protocols keep calling the generic net_nic_* surface.
section .data
net_driver_rtl8156_name db "rtl8156", 0
net_driver_rtl8139_name db "rtl8139", 0

align 8
net_driver_rtl8156_ops:
    dq net_driver_rtl8156_name
    dd NET_NIC_RTL8156
    dd 200
    dq rtl8156_init
    dq rtl8156_active
    dq rtl8156_net_mac
    dq rtl8156_net_tx_frame
    dq rtl8156_net_poll_rx
    dq rtl8156_icmp_ping_ipv4
    dq rtl8156_dhcp_configure
    dq rtl8156_dhcp_start
    dq rtl8156_net_info

net_driver_rtl8139_ops:
    dq net_driver_rtl8139_name
    dd NET_NIC_RTL8139
    dd 100
    dq rtl8139_init
    dq rtl_active
    dq rtl8139_net_mac
    dq rtl8139_net_tx_frame
    dq rtl8139_net_poll_rx
    dq rtl8139_icmp_ping_ipv4
    dq rtl8139_dhcp_configure
    dq 0
    dq rtl8139_net_info

net_driver_table:
    dq net_driver_rtl8156_ops
    dq net_driver_rtl8139_ops
net_driver_table_end:

section .text

; Returns RAX = selected ops table, or 0.
global net_nic_select
net_nic_select:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor ebx, ebx                         ; best ops
    xor edx, edx                         ; best priority
    lea rsi, [rel net_driver_table]
    lea rdi, [rel net_driver_table_end]
.loop:
    cmp rsi, rdi
    jae .done
    mov rax, [rsi]
    add rsi, 8
    mov rcx, [rax + NET_NIC_OP_ACTIVE_PTR]
    cmp byte [rcx], 1
    jne .loop
.candidate:
    mov ecx, [rax + NET_NIC_OP_PRIORITY]
    cmp ecx, edx
    jbe .loop
    mov edx, ecx
    mov rbx, rax
    jmp .loop
.done:
    mov rax, rbx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Returns EAX = active backend ID.
global net_nic_active
net_nic_active:
    call net_nic_select
    test rax, rax
    jz .none
    mov eax, [rax + NET_NIC_OP_ID]
    ret
.none:
    xor eax, eax
    ret

; RDI = Ethernet frame, ECX = frame length. Returns EAX=1 if sent/queued.
global net_nic_tx_frame
net_nic_tx_frame:
    push rbx
    push rcx
    push rdi
    call net_nic_select
    test rax, rax
    jz .fail
    mov rbx, [rax + NET_NIC_OP_TX_FRAME]
    test rbx, rbx
    jz .fail
    pop rdi
    pop rcx
    call rbx
    pop rbx
    ret
.fail:
    pop rdi
    pop rcx
    xor eax, eax
    pop rbx
    ret

; Non-blocking RX pump for the selected NIC. Returns EAX=1 if work was done.
global net_nic_poll_rx
net_nic_poll_rx:
    push rbx
    call net_nic_select
    test rax, rax
    jz .fail
    mov rbx, [rax + NET_NIC_OP_POLL_RX]
    test rbx, rbx
    jz .fail
    call rbx
    pop rbx
    ret
.fail:
    xor eax, eax
    pop rbx
    ret

; RDI = six-byte destination. Returns EAX=1 when an active MAC was copied.
global net_nic_mac
net_nic_mac:
    push rcx
    push rsi
    push rdi
    call net_nic_select
    test rax, rax
    jz .fail
    mov rsi, [rax + NET_NIC_OP_MAC_PTR]
    test rsi, rsi
    jz .fail
    mov ecx, 6
    rep movsb
    mov eax, 1
    jmp .done
.fail:
    xor eax, eax
.done:
    pop rdi
    pop rsi
    pop rcx
    ret

; RDI = NI_* selector used by SYS_NET_INFO.
; Returns EAX in userspace format: IPv4 values are A.B.C.D packed order.
global net_info
net_info:
    push rbx
    call net_nic_active
    mov ebx, eax
    cmp ebx, NET_NIC_RTL8156
    je .rtl8156
    cmp ebx, NET_NIC_RTL8139
    je .rtl8139
    xor eax, eax
    cmp rdi, 7
    jne .done
    mov eax, 4                     ; no active NIC => DHCP failed
    jmp .done
.rtl8156:
    cmp rdi, 0
    je .active
    cmp rdi, 1
    je .r8156_bound
    cmp rdi, 2
    je .r8156_ip
    cmp rdi, 3
    je .r8156_router
    cmp rdi, 4
    je .r8156_server
    cmp rdi, 5
    je .r8156_guest
    cmp rdi, 6
    je .r8156_next_hop
    cmp rdi, 7
    je .r8156_state
    cmp rdi, 8
    je .r8156_last_ttl
    cmp rdi, 9
    je .r8156_dns
    xor eax, eax
    jmp .done
.active:
    mov eax, 1
    jmp .done
.r8156_bound:
    movzx eax, byte [rtl8156_dhcp_bound]
    jmp .done
.r8156_ip:
    mov eax, [rtl8156_dhcp_ip]
    bswap eax
    jmp .done
.r8156_router:
    mov eax, [rtl8156_dhcp_router]
    bswap eax
    jmp .done
.r8156_server:
    mov eax, [rtl8156_dhcp_server]
    bswap eax
    jmp .done
.r8156_guest:
    mov eax, [rtl8156_guest_ip]
    bswap eax
    jmp .done
.r8156_next_hop:
    mov eax, [rtl8156_next_hop_ip]
    bswap eax
    jmp .done
.r8156_state:
    movzx eax, byte [rtl8156_dhcp_state]
    jmp .done
.r8156_last_ttl:
    movzx eax, byte [rtl8156_ping_last_ttl]
    jmp .done
.r8156_dns:
    mov eax, [rtl8156_dhcp_dns]
    test eax, eax
    jnz .r8156_dns_swap
    mov eax, [rtl8156_dhcp_server]
.r8156_dns_swap:
    bswap eax
    jmp .done
.rtl8139:
    cmp rdi, 0
    je .active
    cmp rdi, 1
    je .r8139_bound
    cmp rdi, 2
    je .r8139_ip
    cmp rdi, 3
    je .r8139_router
    cmp rdi, 4
    je .r8139_server
    cmp rdi, 5
    je .r8139_guest
    cmp rdi, 6
    je .r8139_next_hop
    cmp rdi, 7
    je .r8139_state
    cmp rdi, 8
    je .r8139_last_ttl
    cmp rdi, 9
    je .r8139_dns
    xor eax, eax
    jmp .done
.r8139_bound:
    movzx eax, byte [rtl_dhcp_bound]
    jmp .done
.r8139_ip:
    mov eax, [rtl_dhcp_ip]
    bswap eax
    jmp .done
.r8139_router:
    mov eax, [rtl_dhcp_router]
    bswap eax
    jmp .done
.r8139_server:
    mov eax, [rtl_dhcp_server]
    bswap eax
    jmp .done
.r8139_guest:
    mov eax, [rtl_guest_ip]
    bswap eax
    jmp .done
.r8139_next_hop:
    mov eax, [rtl_next_hop_ip]
    bswap eax
    jmp .done
.r8139_state:
    movzx eax, byte [rtl_dhcp_state]
    jmp .done
.r8139_last_ttl:
    movzx eax, byte [rtl_ping_last_ttl]
    jmp .done
.r8139_dns:
    mov eax, [rtl_dhcp_dns]
    test eax, eax
    jnz .r8139_dns_swap
    mov eax, [rtl_dhcp_server]
.r8139_dns_swap:
    bswap eax
.done:
    pop rbx
    ret

; net_dhcp_configure (synchronous lease acquisition, EAX=1 when bound) and
; net_dhcp_start (async kick, EAX=1 if a backend accepted) were ported to the
; zero-asm GHLK module src/kernel/grithlk/net_dhcp_dispatch.ghl. net_dhcp_start
; there is fully non-blocking (the renew button no longer freezes the UI) and
; forces a fresh DISCOVER even on an already-bound lease. Both remain externs
; here; the symbols resolve at link/include time from the GHLK module.

; EDI = IPv4 address in A.B.C.D packed order, e.g. 8.8.8.8 = 0x08080808.
; Returns RAX = approximate RTT in microseconds, or -1 on timeout/failure.
global net_ping_ipv4
net_ping_ipv4:
    push rbx
    push rdi
    cmp byte [rtl8156_active], 1
    je .try_rtl8156
    cmp byte [rtl_active], 1
    je .try_rtl8139
.try_rtl8156:
    call rtl8156_icmp_ping_ipv4
    test eax, eax
    jz .rtl8156_failed
    mov rbx, [rtl8156_ping_start_tsc]
    mov rax, [rtl8156_ping_reply_tsc]
    call net_tsc_span_to_us
    pop rdi
    pop rbx
    ret
.rtl8156_failed:
.try_rtl8139:
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rbx, rax
    mov rdi, [rsp]
    call rtl8139_icmp_ping_ipv4
    test eax, eax
    jz .fail
    call net_tsc_delta_to_us
    pop rdi
    pop rbx
    ret
.fail:
    pop rdi
    mov rax, -1
    pop rbx
    ret

; Async-tick variant. EDI = IPv4 target (A.B.C.D-packed).
; Returns RAX > 0 (RTT in us), 0 (still pending), -1 (timeout/no link),
; or -2 (busy with a different target). Only the rtl8156 path supports
; async; rtl8139 stays synchronous and returns -1 here so userspace can
; fall back to the legacy SYS_NET_PING4 if needed.
extern rtl8156_ping4_tick
global net_ping4_tick
net_ping4_tick:
    cmp byte [rtl8156_active], 1
    jne .nope
    jmp rtl8156_ping4_tick
.nope:
    mov rax, -1
    ret

; RAX = end TSC, RBX = start TSC. Returns RAX = elapsed microseconds. Used by the
; ping path so the RTT is measured against the TSC captured WHEN the ICMP reply was
; parsed (rtl8156_ping_reply_tsc), not the rdtsc at the moment userspace happens to
; poll net_ping4_tick - otherwise the reported time tracks the app's frame/poll
; cadence instead of the actual round-trip.
global net_tsc_span_to_us
net_tsc_span_to_us:
    push rcx
    push rdx
    push r8
    sub rax, rbx
    jmp net_tsc_us_finish

; RBX = start TSC (end = now). Returns RAX = elapsed microseconds.
net_tsc_delta_to_us:
    push rcx
    push rdx
    push r8
    rdtsc
    shl rdx, 32
    or rax, rdx
    sub rax, rbx
net_tsc_us_finish:
    mov rcx, [cpu_tsc_per_tick]
    test rcx, rcx
    jz .no_calib
    xor edx, edx
    mov r8, 10000
    mul r8
    div rcx
    jmp .done
.no_calib:
    xor eax, eax
.done:
    pop r8
    pop rdx
    pop rcx
    ret
