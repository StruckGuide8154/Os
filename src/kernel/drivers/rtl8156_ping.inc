; EDI = IPv4 address in A.B.C.D packed order. Returns EAX=1 on reply.
global rtl8156_icmp_ping_ipv4
rtl8156_icmp_ping_ipv4:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    cmp byte [rtl8156_active], 1
    je .active
    ; If we already walked the bus once and found nothing, don't re-walk -
    ; that path stomps over other USB devices' xHCI slot contexts.
    cmp byte [rtl8156_probed], 1
    je .fail
    call rtl8156_init
    test eax, eax
    jz .fail
.active:
    mov eax, edi
    bswap eax
    mov [rtl8156_target_ip], eax

    cmp byte [rtl8156_dhcp_bound], 1
    je .lease_ready
    ; Don't trigger a synchronous dhcp_configure from inside a ping syscall -
    ; on a flaky USB link this re-runs DISCOVER over a half-initialised endpoint
    ; and has been observed to triple-fault the kernel. Just report no reply
    ; and let userspace press DHCP explicitly.
    jmp .fail
.lease_ready:
    cmp byte [rtl8156_dhcp_bound], 1
    jne .fail
    mov eax, [rtl8156_dhcp_ip]
    mov [rtl8156_guest_ip], eax
    mov eax, [rtl8156_dhcp_router]
    test eax, eax
    jnz .lease_gateway_ok
    mov eax, [rtl8156_dhcp_server]
.lease_gateway_ok:
    mov [rtl8156_next_hop_ip], eax
    mov r13d, 3
    jmp .ping_current_profile

.static_profiles:
    lea r12, [rel rtl8156_ip_profiles]
    mov r13d, RTL8156_IP_PROFILE_COUNT
.profile_loop:
    mov eax, [r12]
    mov [rtl8156_guest_ip], eax
    mov eax, [r12 + 4]
    mov [rtl8156_next_hop_ip], eax

.ping_current_profile:
    mov rax, [tick_count]
    mov [rtl8156_ping_start_tick], rax
    ; Reuse cached gateway MAC across calls - Windows ping caches ARP, so
    ; should we. Without this, every syscall ping adds ~1ms of fresh ARP
    ; round-trip on top of the actual ICMP RTT.
    cmp byte [rtl8156_have_gw_mac], 1
    je .got_arp
    call rtl8156_send_arp_gateway
    mov rbx, [tick_count]
    add rbx, 200                    ; 2s, matching SYS_NET_PING4 contract
.arp_wait:
    call rtl8156_rx_once
    cmp byte [rtl8156_have_gw_mac], 1
    je .got_arp
    mov rax, [tick_count]
    cmp rax, rbx
    jae .next_profile
    pause
    jmp .arp_wait
.got_arp:
    mov byte [rtl8156_ping_reply], 0
    ; Stamp the start TSC AFTER send_icmp_gateway returns. That call blocks on
    ; the bulk-OUT TX completion (tx_frame -> bulk_out -> wait_completion), so it
    ; returns the instant the packet is actually on the wire. Stamping here - not
    ; before the send - excludes the host-side USB-OUT submit/complete plumbing
    ; from the reported RTT. That leg is emulation-only overhead under QEMU
    ; usb-host (on real HW the controller completes via the event ring in us); it
    ; is NOT part of the ICMP round-trip, and counting it inflated the number
    ; (~20ms vs the true wire+RX leg). Still excludes any prior ARP exchange,
    ; matching what `ping` on Linux/Windows reports. Lossless: packet behavior
    ; is unchanged, this only corrects what window the RTT measures.
    call rtl8156_send_icmp_gateway
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [rtl8156_ping_start_tsc], rax
    mov rbx, [tick_count]
    add rbx, 200                    ; 2s, matching SYS_NET_PING4 contract
.icmp_wait:
    call rtl8156_rx_once
    cmp byte [rtl8156_ping_reply], 1
    je .ok
    mov rax, [tick_count]
    cmp rax, rbx
    jae .next_profile
    pause
    jmp .icmp_wait
.ok:
    mov eax, 1
    jmp .done
.next_profile:
    cmp byte [rtl8156_dhcp_bound], 1
    jne .next_static_profile
    dec r13d
    jz .fail
    ; A userspace ping can race background RX/HID event traffic and miss one
    ; reply window even though the link is healthy. Refresh gateway ARP and
    ; retry before reporting "no reply" to the app.
    mov byte [rtl8156_have_gw_mac], 0
    jmp .ping_current_profile
.next_static_profile:
    add r12, 8
    dec r13d
    jnz .profile_loop
.fail:
    lea rsi, [rel ser_r8156_ping_fail]
    call rtl8156_ser_puts
    xor eax, eax
.done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ----------------------------------------------------------------------------
; Async ICMP ping. RDI = target IP (A.B.C.D-packed). Each call advances the
; state machine by one short step and returns immediately:
;   RAX > 0  -> RTT in microseconds, request complete
;   RAX = 0  -> still in flight, call again next frame
;   RAX = -1 -> timeout / no link / send failed
;   RAX = -2 -> another ping (different target) is in flight; try again later
; The GUI stays live because no syscall ever spins for more than the time of
; one rx_once + one frame send. State persists across calls in BSS.
; ----------------------------------------------------------------------------
global rtl8156_ping4_tick
rtl8156_ping4_tick:
    push rbx
    push rcx
    push rdx
    push rdi

    cmp byte [rtl8156_active], 1
    jne .fail
    cmp byte [rtl8156_dhcp_bound], 1
    jne .fail


    mov eax, edi
    bswap eax                       ; A.B.C.D-packed -> network order
    mov edi, eax                    ; stash in EDI for compares

    cmp byte [rtl8156_ping_async_state], 0
    je .start
    cmp edi, [rtl8156_target_ip]
    jne .busy

    ; In-flight: pump RX once and inspect progress.
    call rtl8156_rx_once
    cmp byte [rtl8156_ping_async_state], 1
    je .check_arp
    cmp byte [rtl8156_ping_async_state], 2
    je .check_icmp
    jmp .timeout

.check_arp:
    cmp byte [rtl8156_have_gw_mac], 1
    je .send_icmp
    mov rcx, [tick_count]
    cmp rcx, [rel rtl8156_ping_async_deadline]
    jae .timeout
    xor eax, eax
    jmp .ret

.send_icmp:
    mov byte [rtl8156_ping_reply], 0
    ; Stamp start TSC AFTER the (TX-completion-blocking) send so the host USB-OUT
    ; plumbing leg is excluded from the RTT - see the comment in the sync path.
    call rtl8156_send_icmp_gateway
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [rtl8156_ping_start_tsc], rax
    mov byte [rtl8156_ping_async_state], 2
    mov rcx, [tick_count]
    add rcx, 200
    mov [rel rtl8156_ping_async_deadline], rcx
    jmp .icmp_busy_poll

.check_icmp:
    cmp byte [rtl8156_ping_reply], 1
    je .reply_got
    mov rcx, [tick_count]
    cmp rcx, [rel rtl8156_ping_async_deadline]
    jae .timeout
    xor eax, eax
    jmp .ret

.reply_got:
    mov byte [rtl8156_ping_async_state], 0
    mov byte [rel rtl8156_ping_async_retries], 0
    ; RTT = (TSC captured when the reply was PARSED) - (TSC at ICMP send). Using
    ; the captured rtl8156_ping_reply_tsc instead of rdtsc-now means the reported
    ; time is the real round-trip, not the delay until userspace next polls this
    ; tick (which fires on app frame/UI events).
    mov rbx, [rtl8156_ping_start_tsc]
    mov rax, [rtl8156_ping_reply_tsc]
    extern net_tsc_span_to_us
    call net_tsc_span_to_us
    jmp .ret

.start:
    ; Same target as the in-flight session => retry start (keep retry count).
    ; Different target => fresh session (reset retries).
    cmp edi, [rtl8156_target_ip]
    je .start_keep_retries
    mov [rtl8156_target_ip], edi
    mov byte [rel rtl8156_ping_async_retries], 0
.start_keep_retries:
    mov eax, [rtl8156_dhcp_router]
    test eax, eax
    jnz .have_router
    mov eax, [rtl8156_dhcp_server]
.have_router:
    mov [rtl8156_next_hop_ip], eax
    cmp byte [rtl8156_have_gw_mac], 1
    je .send_icmp_initial
    call rtl8156_send_arp_gateway
    mov byte [rtl8156_ping_async_state], 1
    mov rcx, [tick_count]
    add rcx, 200
    mov [rel rtl8156_ping_async_deadline], rcx
    xor eax, eax
    jmp .ret

.send_icmp_initial:
    mov byte [rtl8156_ping_reply], 0
    ; Stamp start TSC AFTER the (TX-completion-blocking) send so the host USB-OUT
    ; plumbing leg is excluded from the RTT - see the comment in the sync path.
    call rtl8156_send_icmp_gateway
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [rtl8156_ping_start_tsc], rax
    mov byte [rtl8156_ping_async_state], 2
    mov rcx, [tick_count]
    add rcx, 200
    mov [rel rtl8156_ping_async_deadline], rcx
    ; fall through into the in-line reply busy-poll

; Busy-poll the ICMP reply leg for a short TSC budget right after the echo is
; sent. Over a LAN/Internet hop the reply lands in a few ms; catching it in this
; same tick (rather than waiting for the next once-per-UI-frame rx_once) makes the
; reported RTT the true round trip instead of one inflated by the poll cadence.
; If the budget expires the FSM stays in state 2 and the slow/lost-reply case is
; handled by the existing per-frame tick + tick_count deadline (returns pending).
.icmp_busy_poll:
    mov rbx, [cpu_tsc_per_tick]
    test rbx, rbx
    jz .icmp_poll_pending          ; no TSC calibration -> pure async fallback
    lea rbx, [rbx + rbx*4]         ; ~5 PIT ticks (~50ms) cap
    rdtsc
    shl rdx, 32
    or rax, rdx
    add rbx, rax                   ; rbx = deadline TSC (rx_once preserves rbx)
.icmp_poll_loop:
    call rtl8156_rx_once
    cmp byte [rtl8156_ping_reply], 1
    je .reply_got
    rdtsc
    shl rdx, 32
    or rax, rdx
    cmp rax, rbx
    jae .icmp_poll_pending
    pause
    jmp .icmp_poll_loop
.icmp_poll_pending:
    xor eax, eax
    jmp .ret

.timeout:
    ; Retry the cycle a couple of times with a fresh ARP before reporting
    ; failure. Matches what the legacy sync ping does internally and absorbs
    ; the transient "cold xHCI" misses we see right after the link comes up.
    cmp byte [rel rtl8156_ping_async_retries], 3
    jae .real_timeout
    inc byte [rel rtl8156_ping_async_retries]
    mov byte [rtl8156_have_gw_mac], 0
    call rtl8156_send_arp_gateway
    mov byte [rtl8156_ping_async_state], 1
    mov rcx, [tick_count]
    add rcx, 200
    mov [rel rtl8156_ping_async_deadline], rcx
    xor eax, eax
    jmp .ret
.real_timeout:
    mov byte [rtl8156_ping_async_state], 0
    mov byte [rel rtl8156_ping_async_retries], 0
    mov byte [rtl8156_have_gw_mac], 0
    mov rax, -1
    jmp .ret

.fail:
    mov byte [rtl8156_ping_async_state], 0
    mov rax, -1
    jmp .ret

.busy:
    mov rax, -2
.ret:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
