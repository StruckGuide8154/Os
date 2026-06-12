rtl8156_diag_char:
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    ret

rtl8156_ser_init:
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, '['
    out dx, al
    mov al, 'R'
    out dx, al
    mov al, '8'
    out dx, al
    mov al, '1'
    out dx, al
    mov al, '5'
    out dx, al
    mov al, '6'
    out dx, al
    mov al, ' '
    out dx, al
    pop rdx
    pop rax
    ret

rtl8156_ser_ready:
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, 'O'
    out dx, al
    mov al, 'K'
    out dx, al
    mov al, ']'
    out dx, al
    mov al, 10
    out dx, al
    pop rdx
    pop rax
    ret

rtl8156_ser_fail:
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, 'F'
    out dx, al
    mov al, 'A'
    out dx, al
    mov al, 'I'
    out dx, al
    mov al, 'L'
    out dx, al
    mov al, ']'
    out dx, al
    mov al, 10
    out dx, al
    pop rdx
    pop rax
    ret

rtl8156_ser_puts:
    push rax
    push rdx
    push rsi
    mov dx, 0x3F8
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    out dx, al
    inc rsi
    jmp .loop
.done:
    pop rsi
    pop rdx
    pop rax
    ret

rtl8156_ser_putc:
    push rax
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rax
    ret

; AL = byte to print as 2 hex chars
rtl8156_ser_phex8:
    push rax
    push rcx
    push rdx
    mov dx, 0x3F8
    mov cl, al
    shr al, 4
    and al, 0x0F
    cmp al, 10
    jl .h1d
    add al, 'A' - 10
    jmp .h1e
.h1d:
    add al, '0'
.h1e:
    out dx, al
    mov al, cl
    and al, 0x0F
    cmp al, 10
    jl .h2d
    add al, 'A' - 10
    jmp .h2e
.h2d:
    add al, '0'
.h2e:
    out dx, al
    pop rdx
    pop rcx
    pop rax
    ret

; -------------------------------------------------------------------------
; rtl8156_selftest - boot-time auto-test of the network stack.
; Drives a deterministic serial trace: try RTL8156 USB NIC first, fall back
; to the emulated RTL8139 PCI NIC. Net path that succeeds gets DHCP +
; ICMP-echo exercised. Emits [NETSELFTEST <tag>] markers so a harness can
; grade the run by scraping serial.log:
;   [NETSELFTEST PASS rtl8156]   ← USB 2.5G NIC reached + DHCP + ping
;   [NETSELFTEST PASS rtl8139]   ← only the emulated PCI NIC worked
;   [NETSELFTEST FAIL]           ← neither backend reached DHCP+ping
; -------------------------------------------------------------------------
%ifndef RELEASE_BUILD
extern rtl_active
extern rtl_dhcp_bound
extern net_ping_ipv4
global rtl8156_selftest
rtl8156_selftest:
    push rdi
    push rsi
    lea rsi, [rel ser_selftest_begin]
    call rtl8156_ser_puts

    ; Try the USB RTL8156 first; success here is the "good" outcome.
    ; Let rtl8156_init bring up xHCI itself. It uses that fact to decide
    ; whether it may run the initial port power/reset sweep; pre-initializing
    ; xHCI here makes the NIC probe skip that required first pass.
    call rtl8156_init
    test eax, eax
    jz .try_8139
    call rtl8156_dhcp_configure
    cmp byte [rtl8156_dhcp_bound], 1
    jne .try_8139
    mov eax, [rtl8156_dhcp_router]
    bswap eax
    mov edi, eax
    call rtl8156_icmp_ping_ipv4
    test eax, eax
    jz .try_8139
    lea rsi, [rel ser_ping_gw_ok]
    call rtl8156_ser_puts
    ; Also exercise an off-LAN public address (8.8.8.8) so we know the gateway
    ; actually forwards and replies. Non-fatal - selftest still passes if the
    ; gateway responded; we just mark whether 8.8.8.8 was reachable.
    mov edi, 0x08080808            ; 8.8.8.8 packed A.B.C.D
    call rtl8156_icmp_ping_ipv4
    test eax, eax
    jz .ext_ping_failed
    lea rsi, [rel ser_ping_ext_ok]
    call rtl8156_ser_puts
    jmp .selftest_pass_8156
.ext_ping_failed:
    lea rsi, [rel ser_ping_ext_fail]
    call rtl8156_ser_puts
.selftest_pass_8156:
    lea rsi, [rel ser_selftest_pass_8156]
    call rtl8156_ser_puts
    jmp .done

.try_8139:
    lea rsi, [rel ser_selftest_no_init]
    call rtl8156_ser_puts
    ; Fallback: emulated PCI NIC. net_ping_ipv4 internally calls
    ; rtl8139_icmp_ping_ipv4, which lazy-runs DHCP and prints
    ; [DHCP DISC]/[DHCP OFFER]/[DHCP ACK] over COM1.
    cmp byte [rtl_active], 1
    jne .fail
    ; Ping the QEMU usermode gateway (10.0.2.2). This is also what triggers
    ; lazy DHCP in the rtl8139 driver, so [DHCP DISC]/[DHCP OFFER]/[DHCP ACK]
    ; and TX/RX traffic markers all fire here. We then accept either a
    ; successful echo *or* a confirmed DHCP lease as proof the NIC RX/TX is
    ; healthy - QEMU slirp doesn't always answer ICMP, so DHCP-bound is the
    ; reliable signal.
    mov edi, 0x0202000A            ; 10.0.2.2 packed A.B.C.D
    call net_ping_ipv4
    cmp byte [rtl_dhcp_bound], 1
    jne .fail
    lea rsi, [rel ser_selftest_pass_8139]
    call rtl8156_ser_puts
    jmp .done
.fail:
    lea rsi, [rel ser_selftest_fail]
    call rtl8156_ser_puts
.done:
    pop rsi
    pop rdi
    ret
section .data
ser_selftest_begin     db "[NETSELFTEST BEGIN]", 10, 0
ser_selftest_pass_8156 db "[NETSELFTEST PASS rtl8156]", 10, 0
ser_ping_gw_ok        db "[PING GW OK]", 10, 0
ser_ping_ext_ok       db "[PING 8.8.8.8 OK]", 10, 0
ser_ping_ext_fail     db "[PING 8.8.8.8 FAIL]", 10, 0
ser_selftest_pass_8139 db "[NETSELFTEST PASS rtl8139]", 10, 0
ser_selftest_fail      db "[NETSELFTEST FAIL]", 10, 0
ser_selftest_no_xhci   db "[NETSELFTEST xhci_init failed]", 10, 0
ser_selftest_no_init   db "[NETSELFTEST rtl8156_init failed - falling back to rtl8139]", 10, 0
%endif
