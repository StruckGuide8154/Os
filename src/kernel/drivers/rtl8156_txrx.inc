; DHCP/ARP transmit builders moved to zero-asm GritHLK:
;   rtl8156_send_dhcp_discover / rtl8156_send_dhcp_request /
;   rtl8156_build_dhcp_base / rtl8156_finish_dhcp_udp -> rtl8156_dhcp_build.ghl
;   rtl8156_send_arp_gateway -> rtl8156_arp.ghl
;   (src/kernel/grithlk/, %included via kernel_build.asm before this file).
rtl8156_send_icmp_gateway:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    lea rdi, [abs RTL8156_TX_BUF_ADDR + 8]
    mov ecx, 60
    xor eax, eax
    rep stosb
    lea rdi, [abs RTL8156_TX_BUF_ADDR + 8]
    lea rsi, [rtl8156_gw_mac]
    mov ecx, 6
    rep movsb
    lea rsi, [rtl8156_mac]
    mov ecx, 6
    rep movsb
    mov word [rdi], 0x0008
    mov byte [abs RTL8156_TX_BUF_ADDR + 8 + 14], 0x45
    mov word [abs RTL8156_TX_BUF_ADDR + 8 + 16], 0x1C00
    mov word [abs RTL8156_TX_BUF_ADDR + 8 + 18], 0x5634
    mov byte [abs RTL8156_TX_BUF_ADDR + 8 + 22], 64
    mov byte [abs RTL8156_TX_BUF_ADDR + 8 + 23], 1
    mov word [abs RTL8156_TX_BUF_ADDR + 8 + 24], 0
    mov eax, [rtl8156_guest_ip]
    mov dword [abs RTL8156_TX_BUF_ADDR + 8 + 26], eax
    mov eax, [rtl8156_target_ip]
    mov dword [abs RTL8156_TX_BUF_ADDR + 8 + 30], eax
    lea rdi, [abs RTL8156_TX_BUF_ADDR + 8 + 14]
    mov ecx, 20
    call net_checksum
    mov [abs RTL8156_TX_BUF_ADDR + 8 + 24], ax
    mov byte [abs RTL8156_TX_BUF_ADDR + 8 + 34], 8
    mov byte [abs RTL8156_TX_BUF_ADDR + 8 + 35], 0
    mov word [abs RTL8156_TX_BUF_ADDR + 8 + 36], 0
    mov word [abs RTL8156_TX_BUF_ADDR + 8 + 38], 0xBEEF
    inc word [rtl8156_ping_seq]
    mov ax, [rtl8156_ping_seq]
    xchg al, ah
    mov [abs RTL8156_TX_BUF_ADDR + 8 + 40], ax
    lea rdi, [abs RTL8156_TX_BUF_ADDR + 8 + 34]
    mov ecx, 8
    call net_checksum
    mov [abs RTL8156_TX_BUF_ADDR + 8 + 36], ax
    mov ecx, 60
    call rtl8156_tx_frame
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ECX = Ethernet frame length at RTL8156_TX_BUF_ADDR+8.
rtl8156_tx_frame:
    push rax
    push rcx
    push rdx
    push rsi
    lea rsi, [rel ser_tx_tag]
    call rtl8156_ser_puts
    mov al, cl
    call rtl8156_ser_phex8
    mov al, 10
    mov dx, 0x3F8
    out dx, al
    pop rsi
    pop rdx
    mov eax, ecx
    or eax, RTL8156_TX_FS | RTL8156_TX_LS
    mov [abs RTL8156_TX_BUF_ADDR], eax
    mov dword [abs RTL8156_TX_BUF_ADDR + 4], 0
    add ecx, 8
    mov edi, RTL8156_TX_BUF_ADDR
    call rtl8156_bulk_out
    push rdx
    push rsi
    lea rsi, [rel ser_tx_done]
    call rtl8156_ser_puts
    mov al, al            ; just to avoid empty
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; Generic NIC ABI wrapper. RDI = complete Ethernet frame, ECX = length.
global rtl8156_net_tx_frame
rtl8156_net_tx_frame:
    push rcx
    push rsi
    push rdi
    push r8
    ; SECURITY (GSEC net): bound the caller length before the rep movsb below,
    ; which copies ecx bytes into the fixed RTL8156_TX_BUF_ADDR+8 DMA buffer.
    ; Without this an oversized length overruns into the adjacent scratch region
    ; (guard-page PoC confirmed). Defence in depth alongside net_nic_tx_frame.
    cmp ecx, NET_ETH_FRAME_MAX
    ja .reject
    cmp ecx, NET_ETH_FRAME_MIN
    jb .reject
    cmp byte [rtl8156_active], 1
    je .active
    call rtl8156_init
    test eax, eax
    jz .fail
.active:
    mov r8d, ecx
    mov rsi, rdi
    mov rdi, RTL8156_TX_BUF_ADDR + 8
    cld
    rep movsb
    mov ecx, r8d
    call rtl8156_tx_frame
    mov eax, 1
    jmp .done
.reject:
%ifndef RELEASE_BUILD
    ; Debug builds surface a rejected TX length loudly instead of copying it.
    push rsi
    mov rsi, ser_tx_len_reject_8156
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

; rtl8156_rx_once - non-blocking RX pump. Pulls at most one transfer event
; off the shared xHCI event ring and dispatches it via consume_event (NIC) or
; the HID requeue path. Used at boot (before usb_poll_mouse is running) and
; redundantly from DHCP/ICMP wait loops - both paths just call this; whoever
; pops the event from the ring wins, and either flows into handle_frame the
; same way through rtl8156_consume_event.
rtl8156_rx_once:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call rtl8156_arm_rx
    call xhci_poll_event
    test eax, eax
    jz .done
    mov ecx, ebx
    shr ecx, 10
    and ecx, 0x3F
    cmp ecx, 32
    jne .done
    mov edx, ebx
    shr edx, 24
    and edx, 0xFF
    movzx ecx, byte [rtl8156_slot_id]
    cmp edx, ecx
    je .nic_event
    ; Other slot - re-prime HID so its mouse ring stays armed.
    extern usb_hid_requeue_slot1_one
    call usb_hid_requeue_slot1_one
    jmp .done
.nic_event:
    call rtl8156_consume_event
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

global rtl8156_net_poll_rx
rtl8156_net_poll_rx:
    cmp byte [rtl8156_active], 1
    jne .no_work
    call rtl8156_rx_once
    mov eax, 1
    ret
.no_work:
    xor eax, eax
    ret
