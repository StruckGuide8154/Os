; ============================================================================
; GritOS driver diagnostics manager
; ----------------------------------------------------------------------------
; Central debug surface for hardware bring-up. The klog overlay calls
; driver_debug_render, and this file gathers concise state from whatever
; compiled-in drivers are present. Keep per-driver details behind small
; line-builder functions so the overlay does not grow device-specific branches.
; ============================================================================
bits 64

%include "constants.inc"
%include "net_driver.inc"

extern render_text
extern scr_width
extern net_nic_active
extern xhci_active, xhci_max_ports, xhci_port_num, xhci_port_speed, xhci_slot_id
extern usb_mouse_active, usb_slot1_id, usb_slot2_active
extern usb_dbg_stage, usb_dbg_stage_max, usb_dbg_evt, usb_dbg_rpt, usb_dbg_err, usb_dbg_errcode
extern i2c_hid_debug_dump_line
extern rtl8156_active, rtl8156_probed, rtl8156_dbg_stage
extern rtl8156_port, rtl8156_walk_port, rtl8156_slot_id
extern rtl8156_last_vid, rtl8156_last_pid, rtl8156_product, rtl8156_last_portsc
extern rtl8156_bulk_in_addr, rtl8156_bulk_out_addr, rtl8156_bulk_in_dci, rtl8156_bulk_out_dci
extern rtl8156_bulk_in_mps, rtl8156_bulk_out_mps, rtl8156_bulk_in_burst, rtl8156_bulk_out_burst
extern rtl8156_bulk_in_enqueue, rtl8156_bulk_out_enqueue, rtl8156_bulk_in_inflight
extern rtl8156_last_bmsr, rtl8156_dhcp_state, rtl8156_dhcp_bound, rtl8156_dhcp_offer_seen, rtl8156_dhcp_ack_seen
extern rtl8156_dhcp_ip, rtl8156_dhcp_router, rtl8156_dhcp_dns, rtl8156_rx_poll_count, rtl8156_ping_last_ttl
extern rtl_active, rtl_dhcp_bound, rtl_dhcp_state, rtl_io_base, rtl_pci_addr, rtl_rx_off, rtl_ping_last_ttl

section .text

; EDI = start Y. Returns EAX = next Y after rendered diagnostics.
global driver_debug_render
driver_debug_render:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12

    mov r12d, edi

    lea rdi, [drvdbg_buf]
    lea rsi, [s_mgr]
    call dd_puts
    call net_nic_active
    mov edx, eax
    call dd_hex8
    lea rsi, [s_scrw]
    call dd_puts
    mov edx, [scr_width]
    call dd_dec
    call dd_emit_header

    xor r10d, r10d
.provider_loop:
    cmp r10d, DRIVER_DEBUG_PROVIDER_COUNT
    jae .done
    mov eax, r10d
    imul eax, DRIVER_DEBUG_PROVIDER_SIZE
    lea r11, [driver_debug_providers]
    add r11, rax

    xor r9d, r9d
.line_loop:
    cmp r9d, DRIVER_DEBUG_LINES_PER_PROVIDER
    jae .next_provider
    lea rdi, [drvdbg_buf]
    mov rsi, [r11 + DD_PROVIDER_NAME]
    call dd_puts
    lea rsi, [s_colon_space]
    call dd_puts
    mov eax, r9d
    call qword [r11 + DD_PROVIDER_DUMP]
    cmp byte [drvdbg_buf], 0
    je .next_line
    call dd_emit_line
.next_line:
    inc r9d
    jmp .line_loop
.next_provider:
    inc r10d
    jmp .provider_loop

.done:
    mov eax, r12d
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

dd_emit_header:
    mov byte [rdi], 0
    mov edi, 8
    mov esi, r12d
    lea rdx, [drvdbg_buf]
    mov ecx, 0x00A8D8FF
    mov r8d, 0x00101820
    call render_text
    add r12d, 16
    ret

dd_emit_line:
    mov byte [rdi], 0
    mov edi, 8
    mov esi, r12d
    lea rdx, [drvdbg_buf]
    mov ecx, 0x00D8F8D8
    mov r8d, 0x00101820
    call render_text
    add r12d, 16
    ret

; Provider line builders.
; Input: RDI = output cursor after "name: ", EAX = provider-local line index.
dd_usb_line:
    test eax, eax
    jz .l0
    cmp eax, 1
    je .l1
    cmp eax, 2
    je .l2
    mov byte [rdi], 0
    ret
.l0:
    lea rsi, [s_xhci]
    call dd_puts
    movzx edx, byte [xhci_active]
    call dd_hex8
    lea rsi, [s_ports]
    call dd_puts
    movzx edx, byte [xhci_max_ports]
    call dd_hex8
    lea rsi, [s_cur]
    call dd_puts
    movzx edx, byte [xhci_port_num]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [xhci_port_speed]
    call dd_hex8
    lea rsi, [s_slot]
    call dd_puts
    movzx edx, byte [xhci_slot_id]
    call dd_hex8
    ret
.l1:
    lea rsi, [s_hid]
    call dd_puts
    movzx edx, byte [usb_mouse_active]
    call dd_hex8
    lea rsi, [s_slots]
    call dd_puts
    movzx edx, byte [usb_slot1_id]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [usb_slot2_active]
    call dd_hex8
    lea rsi, [s_stage]
    call dd_puts
    movzx edx, byte [usb_dbg_stage]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [usb_dbg_stage_max]
    call dd_hex8
    ret
.l2:
    lea rsi, [s_ev]
    call dd_puts
    mov edx, [usb_dbg_evt]
    call dd_hex32
    lea rsi, [s_rpt]
    call dd_puts
    mov edx, [usb_dbg_rpt]
    call dd_hex32
    lea rsi, [s_err]
    call dd_puts
    mov edx, [usb_dbg_err]
    call dd_hex32
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [usb_dbg_errcode]
    call dd_hex8
    ret

dd_i2c_line:
    cmp eax, 2
    jbe .go
    mov byte [rdi], 0
    ret
.go:
    call i2c_hid_debug_dump_line
    ret

dd_net_line:
    test eax, eax
    jz .l0
    cmp eax, 1
    je .l1
    cmp eax, 2
    je .l2
    cmp eax, 3
    je .l3
    cmp eax, 4
    je .l4
    cmp eax, 5
    je .l5
    mov byte [rdi], 0
    ret
.l0:
    lea rsi, [s_active_probe]
    call dd_puts
    movzx edx, byte [rtl8156_active]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_probed]
    call dd_hex8
    lea rsi, [s_stage]
    call dd_puts
    movzx edx, byte [rtl8156_dbg_stage]
    call dd_hex8
    lea rsi, [s_port]
    call dd_puts
    movzx edx, byte [rtl8156_port]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_walk_port]
    call dd_hex8
    lea rsi, [s_slot]
    call dd_puts
    movzx edx, byte [rtl8156_slot_id]
    call dd_hex8
    ret
.l1:
    lea rsi, [s_vidpid]
    call dd_puts
    movzx edx, word [rtl8156_last_vid]
    call dd_hex16
    mov byte [rdi], ':'
    inc rdi
    movzx edx, word [rtl8156_last_pid]
    call dd_hex16
    lea rsi, [s_product]
    call dd_puts
    movzx edx, word [rtl8156_product]
    call dd_hex16
    lea rsi, [s_portsc]
    call dd_puts
    mov edx, [rtl8156_last_portsc]
    call dd_hex32
    ret
.l2:
    lea rsi, [s_ep]
    call dd_puts
    movzx edx, byte [rtl8156_bulk_in_addr]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_bulk_out_addr]
    call dd_hex8
    lea rsi, [s_dci]
    call dd_puts
    movzx edx, byte [rtl8156_bulk_in_dci]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_bulk_out_dci]
    call dd_hex8
    lea rsi, [s_mps]
    call dd_puts
    movzx edx, word [rtl8156_bulk_in_mps]
    call dd_hex16
    mov byte [rdi], '/'
    inc rdi
    movzx edx, word [rtl8156_bulk_out_mps]
    call dd_hex16
    lea rsi, [s_burst]
    call dd_puts
    movzx edx, byte [rtl8156_bulk_in_burst]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_bulk_out_burst]
    call dd_hex8
    ret
.l3:
    lea rsi, [s_q]
    call dd_puts
    mov edx, [rtl8156_bulk_in_enqueue]
    call dd_hex16
    mov byte [rdi], '/'
    inc rdi
    mov edx, [rtl8156_bulk_out_enqueue]
    call dd_hex16
    lea rsi, [s_inflight]
    call dd_puts
    movzx edx, byte [rtl8156_bulk_in_inflight]
    call dd_hex8
    lea rsi, [s_bmsr]
    call dd_puts
    movzx edx, word [rtl8156_last_bmsr]
    call dd_hex16
    lea rsi, [s_rx]
    call dd_puts
    mov edx, [rtl8156_rx_poll_count]
    call dd_hex32
    ret
.l4:
    lea rsi, [s_dhcp]
    call dd_puts
    movzx edx, byte [rtl8156_dhcp_state]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_dhcp_bound]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_dhcp_offer_seen]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl8156_dhcp_ack_seen]
    call dd_hex8
    lea rsi, [s_ip]
    call dd_puts
    mov edx, [rtl8156_dhcp_ip]
    call dd_hex32
    lea rsi, [s_gw]
    call dd_puts
    mov edx, [rtl8156_dhcp_router]
    call dd_hex32
    ret
.l5:
    lea rsi, [s_answer]
    call dd_puts
    cmp byte [rtl8156_active], 1
    je .answer_active
    movzx edx, byte [rtl8156_dbg_stage]
    cmp dl, 0xA0
    je .ans_addr
    cmp dl, 0xA1
    je .ans_devdesc
    cmp dl, 0xA2
    je .ans_cfghead
    cmp dl, 0xA3
    je .ans_cfgbody
    cmp dl, 0xA4
    je .ans_ep
    cmp dl, 0xA5
    je .ans_setcfg
    cmp dl, 0xA6
    je .ans_ctx
    cmp dl, 0xA7
    je .ans_vendor
    cmp dl, 0xF0
    je .ans_none
    lea rsi, [s_ans_probe]
    call dd_puts
    ret
.ans_addr:
    lea rsi, [s_ans_addr]
    call dd_puts
    ret
.ans_devdesc:
    lea rsi, [s_ans_devdesc]
    call dd_puts
    ret
.ans_cfghead:
    lea rsi, [s_ans_cfghead]
    call dd_puts
    ret
.ans_cfgbody:
    lea rsi, [s_ans_cfgbody]
    call dd_puts
    ret
.ans_ep:
    lea rsi, [s_ans_ep]
    call dd_puts
    ret
.ans_setcfg:
    lea rsi, [s_ans_setcfg]
    call dd_puts
    ret
.ans_ctx:
    lea rsi, [s_ans_ctx]
    call dd_puts
    ret
.ans_vendor:
    lea rsi, [s_ans_vendor]
    call dd_puts
    ret
.ans_none:
    lea rsi, [s_ans_none]
    call dd_puts
    ret
.answer_active:
    test word [rtl8156_last_bmsr], 0x0004
    jnz .answer_link
    lea rsi, [s_ans_link]
    call dd_puts
    ret
.answer_link:
    cmp byte [rtl8156_dhcp_bound], 1
    je .answer_ready
    cmp byte [rtl8156_dhcp_state], 4
    je .answer_dhcp_fail
    cmp byte [rtl8156_dhcp_offer_seen], 1
    je .answer_dhcp_ack
    lea rsi, [s_ans_dhcp_offer]
    call dd_puts
    ret
.answer_dhcp_ack:
    lea rsi, [s_ans_dhcp_ack]
    call dd_puts
    ret
.answer_dhcp_fail:
    lea rsi, [s_ans_dhcp_fail]
    call dd_puts
    ret
.answer_ready:
    lea rsi, [s_ans_ready]
    call dd_puts
    ret

dd_pci_net_line:
    test eax, eax
    jz .l0
    cmp eax, 1
    je .l1
    mov byte [rdi], 0
    ret
.l0:
    lea rsi, [s_active_bound]
    call dd_puts
    movzx edx, byte [rtl_active]
    call dd_hex8
    mov byte [rdi], '/'
    inc rdi
    movzx edx, byte [rtl_dhcp_bound]
    call dd_hex8
    lea rsi, [s_state]
    call dd_puts
    movzx edx, byte [rtl_dhcp_state]
    call dd_hex8
    lea rsi, [s_io]
    call dd_puts
    movzx edx, word [rtl_io_base]
    call dd_hex16
    lea rsi, [s_pci]
    call dd_puts
    mov edx, [rtl_pci_addr]
    call dd_hex32
    ret
.l1:
    lea rsi, [s_rxoff]
    call dd_puts
    movzx edx, word [rtl_rx_off]
    call dd_hex16
    lea rsi, [s_ttl]
    call dd_puts
    movzx edx, byte [rtl_ping_last_ttl]
    call dd_hex8
    ret

; String/number helpers. These append and leave RDI at the cursor.
dd_puts:
    push rax
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .loop
.done:
    pop rax
    ret

dd_dec:
    push rax
    push rbx
    push rcx
    push rdx
    mov eax, edx
    lea rbx, [drvdbg_num + 15]
    mov byte [rbx], 0
    mov ecx, 10
    test eax, eax
    jnz .loop
    dec rbx
    mov byte [rbx], '0'
    jmp .copy
.loop:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rbx
    mov [rbx], dl
    test eax, eax
    jnz .loop
.copy:
    mov rsi, rbx
    call dd_puts
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

dd_hex8:
    push rdx
    mov eax, edx
    shr al, 4
    call dd_nib
    pop rdx
    mov eax, edx
    call dd_nib
    ret

dd_hex16:
    push rdx
    mov eax, edx
    shr eax, 8
    mov edx, eax
    call dd_hex8
    pop rdx
    call dd_hex8
    ret

dd_hex32:
    push rdx
    mov eax, edx
    shr eax, 16
    mov edx, eax
    call dd_hex16
    pop rdx
    call dd_hex16
    ret

dd_nib:
    and al, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .out
.digit:
    add al, '0'
.out:
    mov [rdi], al
    inc rdi
    ret

section .data

DD_PROVIDER_NAME equ 0
DD_PROVIDER_DUMP equ 8
DRIVER_DEBUG_PROVIDER_SIZE equ 16
DRIVER_DEBUG_LINES_PER_PROVIDER equ 6

driver_debug_providers:
    dq s_usb_name, dd_usb_line
    dq s_i2c_name, dd_i2c_line
    dq s_net_name, dd_net_line
    dq s_rtl8139_name, dd_pci_net_line
DRIVER_DEBUG_PROVIDER_COUNT equ (($ - driver_debug_providers) / DRIVER_DEBUG_PROVIDER_SIZE)

s_usb_name db "USB", 0
s_i2c_name db "I2C-HID", 0
s_net_name db "RTL815x", 0
s_rtl8139_name db "RTL8139", 0

s_mgr db "DRIVERS activeNic=", 0
s_scrw db " screenW=", 0
s_colon_space db ": ", 0
s_xhci db "xhci=", 0
s_ports db " ports=", 0
s_cur db " cur=", 0
s_slot db " slot=", 0
s_hid db "hidMouse=", 0
s_slots db " slots=", 0
s_stage db " stage=", 0
s_ev db "evt=", 0
s_rpt db " rpt=", 0
s_err db " err=", 0
s_active_probe db "active/probed=", 0
s_port db " port=", 0
s_vidpid db "vid:pid=", 0
s_product db " prod=", 0
s_portsc db " portsc=", 0
s_ep db " ep=", 0
s_dci db " dci=", 0
s_mps db " mps=", 0
s_burst db " burst=", 0
s_q db "q=", 0
s_inflight db " in=", 0
s_bmsr db " bmsr=", 0
s_rx db " rx=", 0
s_dhcp db "dhcp state/bound/offer/ack=", 0
s_ip db " ip=", 0
s_gw db " gw=", 0
s_answer db "answer=", 0
s_ans_probe db "probe running or not attempted", 0
s_ans_addr db "FAIL xHCI AddressDevice; check port reset/speed/slot", 0
s_ans_devdesc db "FAIL USB device descriptor; control EP0/event routing", 0
s_ans_cfghead db "FAIL config header; control transfer", 0
s_ans_cfgbody db "FAIL config body; descriptor length/transfer", 0
s_ans_ep db "FAIL no bulk IN/OUT endpoints parsed", 0
s_ans_setcfg db "FAIL SetConfiguration(1)", 0
s_ans_ctx db "FAIL xHCI bulk endpoint context", 0
s_ans_vendor db "FAIL Realtek vendor init/OCP", 0
s_ans_none db "FAIL no RTL815x VID:PID found on scanned ports", 0
s_ans_link db "USB NIC enumerated; PHY link down/no cable/autoneg", 0
s_ans_dhcp_offer db "link up; DHCP has no OFFER (TX/RX or network)", 0
s_ans_dhcp_ack db "DHCP OFFER seen; ACK missing, lease fallback expected", 0
s_ans_dhcp_fail db "link up; DHCP failed after timeout", 0
s_ans_ready db "ready: USB, link, DHCP bound", 0
s_active_bound db "active/bound=", 0
s_state db " state=", 0
s_io db " io=", 0
s_pci db " pci=", 0
s_rxoff db "rxoff=", 0
s_ttl db " ttl=", 0

drvdbg_buf times 160 db 0
drvdbg_num times 16 db 0
