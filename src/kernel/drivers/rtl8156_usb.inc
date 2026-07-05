; RDI = Ethernet frame, ECX = len.
; rtl8156_handle_frame / rtl8156_handle_udp moved to zero-asm GritHLK:
;   src/kernel/grithlk/rtl8156_dhcp_parse.ghl (RX dispatch + bounds-checked
;   DHCP option parser). %included via kernel_build.asm before this file.
; RDI=OCP value/register, ESI=wIndex/type, EDX=len, RCX=buffer.
rtl8156_ocp_read:
    mov r8d, edi
    shl r8d, 16
    or r8d, (RTL8156_REQ_REGS << 8) | RTL8156_REQT_READ
    mov r9d, edx
    shl r9d, 16
    or r9d, esi
    mov rdi, rcx
    mov rcx, rdx
    call rtl8156_control_in
    ret

; RDI=OCP value/register, ESI=wIndex/type|byteen, EDX=len, RCX=buffer.
rtl8156_ocp_write:
    mov r8d, edi
    shl r8d, 16
    or r8d, (RTL8156_REQ_REGS << 8) | RTL8156_REQT_WRITE
    mov r9d, edx
    shl r9d, 16
    or r9d, esi
    mov rdi, rcx
    mov rcx, rdx
    call rtl8156_control_out
    ret

; R8/R9 setup, RDI buffer, RCX length.
rtl8156_control_in:
    push rcx
    push rdi
    mov r10d, 8
    mov r11d, TRB_SETUP | TRB_IDT | TRB_TRT_IN
    call xhci_queue_ctrl_trb
    pop rdi
    pop rcx
    mov r8d, edi
    xor r9d, r9d
    mov r10d, ecx
    mov r11d, TRB_DATA | TRB_DIR_IN
    call xhci_queue_ctrl_trb
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, TRB_STATUS | TRB_DIR_OUT | TRB_IOC
    call xhci_queue_ctrl_trb
    movzx edi, byte [xhci_slot_id]
    mov esi, 1
    call xhci_ring_doorbell
    call rtl8156_wait_completion
    ret

; R8/R9 setup, RDI buffer, RCX length.
rtl8156_control_out:
    push rcx
    push rdi
    mov r10d, 8
    mov r11d, TRB_SETUP | TRB_IDT | TRB_TRT_OUT
    call xhci_queue_ctrl_trb
    pop rdi
    pop rcx
    mov r8d, edi
    xor r9d, r9d
    mov r10d, ecx
    mov r11d, TRB_DATA | TRB_DIR_OUT
    call xhci_queue_ctrl_trb
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, TRB_STATUS | TRB_DIR_IN | TRB_IOC
    call xhci_queue_ctrl_trb
    movzx edi, byte [xhci_slot_id]
    mov esi, 1
    call xhci_ring_doorbell
    call rtl8156_wait_completion
    ret

rtl8156_control_nodata:
    mov r10d, 8
    mov r11d, TRB_SETUP | TRB_IDT | TRB_TRT_NO_DATA
    call xhci_queue_ctrl_trb
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, TRB_STATUS | TRB_DIR_IN | TRB_IOC
    call xhci_queue_ctrl_trb
    movzx edi, byte [xhci_slot_id]
    mov esi, 1
    call xhci_ring_doorbell
    call rtl8156_wait_completion
    ret

rtl8156_bulk_in:
    push rcx
    push rdi
    mov r8d, edi
    xor r9d, r9d
    mov r10d, ecx
    mov r11d, TRB_NORMAL | TRB_IOC | (1 << 2)
    mov rdi, RTL8156_BULK_IN_RING_ADDR
    lea rsi, [rel rtl8156_bulk_in_enqueue]
    lea rdx, [rel rtl8156_bulk_in_cycle]
    call rtl8156_queue_bulk_trb
    ; Doorbell the NIC's own slot, NOT the shared xhci_slot_id - that global
    ; gets clobbered by usb_hid / re-enumeration after rtl8156 init returns.
    movzx edi, byte [rtl8156_slot_id]
    movzx esi, byte [rtl8156_bulk_in_dci]
    call xhci_ring_doorbell
    call rtl8156_wait_completion
    pop rdi
    pop rcx
    ret

; ----------------------------------------------------------------------------
; rtl8156_consume_event - driven from the SINGLE shared USB event-ring poller
; (currently usb_poll_mouse) once it has decided that the popped transfer
; event belongs to our NIC slot. Caller passes the completion code in EAX and
; the DW0/DW1 fields in EBX/ECX (matching xhci_poll_event's return ABI). We
; mark the in-flight bulk-IN as cleared, run handle_frame on the RX buffer
; if the event was Success/Short, then queue a fresh bulk-IN so a continuous
; RX stream is maintained without any per-syscall polling.
;
; This is the layering pivot point - DHCP / ICMP / ARP all consume RX data
; through handle_frame, which is fed exclusively from here. No syscall path
; ever touches xhci_poll_event directly anymore.
; ----------------------------------------------------------------------------
global rtl8156_consume_event
rtl8156_consume_event:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    ; Endpoint DCI lives in EBX (DW3) bits 20:16.
    mov edx, ebx
    shr edx, 16
    and edx, 0x1F
    movzx ecx, byte [rtl8156_bulk_in_dci]
    cmp edx, ecx
    je .rx_completion
    movzx ecx, byte [rtl8156_bulk_out_dci]
    cmp edx, ecx
    je .tx_completion
    ; Unknown endpoint - drop.
    jmp .out

.tx_completion:
    ; TX event - record completion code so a parallel rtl8156_wait_completion
    ; (called from bulk_out) can pick it up via the mailbox.
    mov [rel rtl8156_tx_done_code], eax
    mov byte [rel rtl8156_tx_done_set], 1
    jmp .out

.rx_completion:
    mov byte [rtl8156_bulk_in_inflight], 0
    ; Only Success(1) and Short(13) carry valid RX data.
    cmp eax, 1
    je .have_rx
    cmp eax, 13
    je .have_rx
    jmp .requeue
.have_rx:
    mov eax, [abs RTL8156_RX_BUF_ADDR]
    and eax, RTL8156_RX_LEN_MASK
    cmp eax, 18 + 14
    jb .requeue
    ; SECURITY (GSEC G1 - device-reported length OOB, same class as rtl8139):
    ; the length field is fully device-controlled (masked to 0x7FFF => up to
    ; 32767) but only RTL8156_RX_DMA_LEN bytes were DMA'd into the single RX
    ; buffer, with the frame body starting after the 24-byte rx_desc. A
    ; descriptor claiming more than fits would make handle_frame read stale or
    ; unmapped memory past the buffer. Reject fail-closed (a real Ethernet frame
    ; is <=1518, far under this cap; a legit large frame is truncated by the
    ; 4096-byte TRB anyway, so an over-claim can only be corrupt/hostile).
    cmp eax, RTL8156_RX_MAX_FRAME
    ja .requeue
    sub eax, 4
    lea rdi, [abs RTL8156_RX_BUF_ADDR + RTL8156_RX_DESC_LEN]
    mov ecx, eax
    call rtl8156_handle_frame
.requeue:
    ; Queue the next bulk-IN TRB so the next frame can arrive.
    mov r8d, RTL8156_RX_BUF_ADDR
    xor r9d, r9d
    mov r10d, RTL8156_RX_DMA_LEN
    mov r11d, TRB_NORMAL | TRB_IOC | (1 << 2)
    mov rdi, RTL8156_BULK_IN_RING_ADDR
    lea rsi, [rel rtl8156_bulk_in_enqueue]
    lea rdx, [rel rtl8156_bulk_in_cycle]
    call rtl8156_queue_bulk_trb
    movzx edi, byte [rtl8156_slot_id]
    movzx esi, byte [rtl8156_bulk_in_dci]
    call xhci_ring_doorbell
    mov byte [rtl8156_bulk_in_inflight], 1
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; rtl8156_arm_rx - queue an initial bulk-IN TRB so the next NIC frame will
; surface on the xHCI event ring. Call once after rtl8156_init succeeds so
; the consume_event loop has something to be waiting for. Idempotent.
; ----------------------------------------------------------------------------
global rtl8156_arm_rx
rtl8156_arm_rx:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cmp byte [rtl8156_bulk_in_inflight], 1
    je .out
    mov r8d, RTL8156_RX_BUF_ADDR
    xor r9d, r9d
    mov r10d, RTL8156_RX_DMA_LEN
    mov r11d, TRB_NORMAL | TRB_IOC | (1 << 2)
    mov rdi, RTL8156_BULK_IN_RING_ADDR
    lea rsi, [rel rtl8156_bulk_in_enqueue]
    lea rdx, [rel rtl8156_bulk_in_cycle]
    call rtl8156_queue_bulk_trb
    movzx edi, byte [rtl8156_slot_id]
    movzx esi, byte [rtl8156_bulk_in_dci]
    call xhci_ring_doorbell
    mov byte [rtl8156_bulk_in_inflight], 1
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; EDI = buf addr, ECX = max len. Returns EAX=1 if a NIC bulk-IN transfer
; event completed this call (data is in [edi]), EAX=0 otherwise. Never
; blocks: at most one xhci_poll_event call and at most one new TRB queued.
global rtl8156_bulk_in_nonblocking
rtl8156_bulk_in_nonblocking:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    ; Queue a fresh bulk-IN TRB if none is currently in flight.
    cmp byte [rtl8156_bulk_in_inflight], 1
    je .poll
    mov r8d, edi
    xor r9d, r9d
    mov r10d, ecx
    mov r11d, TRB_NORMAL | TRB_IOC | (1 << 2)
    mov rdi, RTL8156_BULK_IN_RING_ADDR
    lea rsi, [rel rtl8156_bulk_in_enqueue]
    lea rdx, [rel rtl8156_bulk_in_cycle]
    call rtl8156_queue_bulk_trb
    movzx edi, byte [rtl8156_slot_id]
    movzx esi, byte [rtl8156_bulk_in_dci]
    call xhci_ring_doorbell
    mov byte [rtl8156_bulk_in_inflight], 1
.poll:
    call xhci_poll_event
    test eax, eax
    jz .no_event
    ; Only care about Transfer Events (TRB type 32 in DWord3 bits 15:10).
    mov ecx, ebx
    shr ecx, 10
    and ecx, 0x3F
    cmp ecx, 32
    jne .no_event
    ; Check slot ID.
    mov edx, ebx
    shr edx, 24
    and edx, 0xFF
    movzx ecx, byte [rtl8156_slot_id]
    cmp edx, ecx
    jne .other_slot
    ; Our event. Mark in-flight cleared.
    mov byte [rtl8156_bulk_in_inflight], 0
    ; Accept Success(1) and Short Packet(13) as data.
    cmp eax, 1
    je .ok
    cmp eax, 13
    je .ok
    xor eax, eax
    jmp .out
.ok:
    mov eax, 1
    jmp .out
.other_slot:
    ; HID Transfer Event - re-prime its ring and report "no data" to caller.
    extern usb_hid_requeue_slot1_one
    call usb_hid_requeue_slot1_one
    xor eax, eax
    jmp .out
.no_event:
    xor eax, eax
.out:
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

rtl8156_bulk_out:
    push rcx
    push rdi
    mov r8d, edi
    xor r9d, r9d
    mov r10d, ecx
    mov r11d, TRB_NORMAL | TRB_IOC
    mov rdi, RTL8156_BULK_OUT_RING_ADDR
    lea rsi, [rel rtl8156_bulk_out_enqueue]
    lea rdx, [rel rtl8156_bulk_out_cycle]
    call rtl8156_queue_bulk_trb
    movzx edi, byte [rtl8156_slot_id]
    movzx esi, byte [rtl8156_bulk_out_dci]
    call xhci_ring_doorbell
    call rtl8156_wait_completion
    pop rdi
    pop rcx
    ret

; RDI=ring, RSI=&enqueue, RDX=&cycle, R8-R11=TRB.
rtl8156_queue_bulk_trb:
    push rax
    push rbx
    push rcx
    mov ebx, [rsi]
    cmp ebx, XHCI_RING_SIZE - 1
    jl .no_wrap
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov ecx, [rax + 12]
    and ecx, ~1
    movzx eax, byte [rdx]
    or ecx, eax
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov [rax + 12], ecx
    xor byte [rdx], 1
    mov dword [rsi], 0
    xor ebx, ebx
.no_wrap:
    imul eax, ebx, XHCI_TRB_SIZE
    add rdi, rax
    mov [rdi + 0], r8d
    mov [rdi + 4], r9d
    mov [rdi + 8], r10d
    mov eax, r11d
    movzx ecx, byte [rdx]
    or eax, ecx
    mov [rdi + 12], eax
    inc ebx
    mov [rsi], ebx
    pop rcx
    pop rbx
    pop rax
    ret

rtl8156_wait_completion:
    push rbx
    push rcx
    push rdx
    push rsi
    mov rsi, [tick_count]
    add rsi, 200
.poll:
    ; TX-completion mailbox first - if usb_poll_mouse already popped our
    ; bulk-OUT transfer event from the shared ring, it's been stashed here.
    cmp byte [rel rtl8156_tx_done_set], 1
    jne .ring_poll
    mov byte [rel rtl8156_tx_done_set], 0
    mov eax, [rel rtl8156_tx_done_code]
    cmp eax, 1
    je .ok
    cmp eax, 13
    je .ok
    jmp .fail
.ring_poll:
    call xhci_poll_event
    test eax, eax
    jz .check_time
    mov ecx, ebx
    shr ecx, 10
    and ecx, 0x3F
    cmp ecx, 32
    je .ours_check
    cmp ecx, 33
    je .event
    jmp .poll
.ours_check:
    ; Transfer Event - first check the slot ID.
    mov edx, ebx
    shr edx, 24
    and edx, 0xFF
    movzx ecx, byte [rtl8156_slot_id]
    cmp edx, ecx
    je .nic_ep_check
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    extern usb_hid_requeue_slot1_one
    call usb_hid_requeue_slot1_one
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    jmp .poll

.nic_ep_check:
    ; NIC slot - bulk-IN events should NOT terminate this wait (we are
    ; waiting on a TX completion). Hand bulk-IN events to consume_event so
    ; the RX path still progresses, then keep polling. Bulk-OUT events ARE
    ; the TX completion we are after.
    push rax
    push rbx
    push rcx
    push rdx
    mov edx, ebx
    shr edx, 16
    and edx, 0x1F
    movzx ecx, byte [rtl8156_bulk_out_dci]
    test ecx, ecx
    jz .nic_ep_is_completion
    cmp edx, 1
    je .nic_ep_is_completion
    cmp edx, ecx
    pop rdx
    pop rcx
    pop rbx
    pop rax
    je .event
    ; Not bulk-OUT - it's bulk-IN (or interrupt). Route via consume_event.
    call rtl8156_consume_event
    jmp .poll
.nic_ep_is_completion:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    jmp .event

.event:
    ; Accept: 1 = Success, 13 = Short Packet (valid data, device sent less
    ; than the TRB length - normal for bulk IN of variable-size frames).
    ; THIS WAS THE RX BUG: only accepting 1 made every IN look like a fail.
    cmp eax, 1
    je .ok
    cmp eax, 13
    je .ok
    jmp .fail
.ok:
    mov eax, 1
    jmp .done
.check_time:
    mov rax, [tick_count]
    cmp rax, rsi
    jl .poll
.fail:
    xor eax, eax
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
