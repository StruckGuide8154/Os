; ============================================================================
; usb_hid_init_slot2 - Enumerate second USB HID device on next available port
; Non-fatal: returns 0 if no second device found
; ============================================================================
FN_BEGIN usb_hid_init_slot2, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp

    mov byte [usb_slot2_active], 0
    mov byte [usb_accept_keyboard], 1

    ; Switch xhci_address_device and xhci_configure_endpoint to slot2 buffers
    mov byte [xhci_slot2_mode], 1

    ; Serial: '[' = slot2 init starting
    mov dx, 0x3F8
    mov al, '['
    out dx, al

    ; Look for another port with a device (past the current port)
    call xhci_find_port_next
    test eax, eax
    jz .slot2_fail

    ; Serial: 'p' = port found for slot2
    mov dx, 0x3F8
    mov al, 'p'
    out dx, al

    ; Enable slot for second device
    call xhci_enable_slot
    test eax, eax
    jz .slot2_fail

    ; Serial: 's' = slot enabled for slot2
    mov dx, 0x3F8
    mov al, 's'
    out dx, al

    ; Address device (uses xhci_slot_id which now = slot2)
    call xhci_address_device
    test eax, eax
    jz .slot2_fail

    ; Serial: 'a' = address device ok for slot2
    mov dx, 0x3F8
    mov al, 'a'
    out dx, al

    ; Get device descriptor
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 18
    mov r8d, 0x01000680
    mov r9d, 0x00120000
    call usb_control_transfer_in
    test eax, eax
    jz .slot2_fail

    ; Get config descriptor (9 bytes)
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 9
    mov r8d, 0x02000680
    mov r9d, 0x00090000
    call usb_control_transfer_in
    test eax, eax
    jz .slot2_fail

    movzx ecx, word [abs XHCI_CTRL_BUF_ADDR + 2]
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov r8d, 0x02000680
    mov r9d, ecx
    shl r9d, 16
    call usb_control_transfer_in
    test eax, eax
    jz .slot2_fail

    ; Parse endpoints - save current ep vars, parse, store slot2 ep vars
    ; Save slot1 endpoint info on stack
    movzx eax, byte [usb_ep_addr]
    push rax
    movzx eax, word [usb_ep_mps]
    push rax
    movzx eax, byte [usb_ep_interval]
    push rax
    movzx eax, byte [usb_hid_protocol]
    push rax
    movzx eax, byte [usb_interface_num]
    push rax

    mov byte [usb_find_report_hid], 0
    call usb_find_endpoint
    test eax, eax
    jnz .slot2_endpoint_ok
    mov byte [usb_find_report_hid], 1
    call usb_find_endpoint
.slot2_endpoint_ok:
    test eax, eax
    je .slot2_restore_fail

    ; Serial: 'e' = endpoint found for slot2
    mov dx, 0x3F8
    mov al, 'e'
    out dx, al

    ; Save slot2 endpoint info
    mov al, [usb_ep_addr]
    mov [usb_ep2_addr], al
    mov ax, [usb_ep_mps]
    mov [usb_ep2_mps], ax
    mov al, [usb_ep_interval]
    mov [usb_ep2_interval], al
    mov al, [usb_hid_protocol]
    mov [usb_hid_protocol2], al
    mov al, [usb_interface_num]
    mov [usb_interface2_num], al

    ; Restore slot1 ep vars
    pop rax
    mov [usb_interface_num], al
    pop rax
    mov [usb_hid_protocol], al
    pop rax
    mov [usb_ep_interval], al
    pop rax
    mov [usb_ep_mps], ax
    pop rax
    mov [usb_ep_addr], al

    ; Set configuration for slot2
    mov r8d, 0x00010900
    mov r9d, 0x00000000
    call usb_control_transfer_nodata

    ; Mirror slot1 init: force boot protocol on keyboards/mice that advertise
    ; a boot HID protocol, then disable idle repeat throttling.
    cmp byte [usb_hid_protocol2], 0
    je .slot2_skip_set_protocol

    ; SET_PROTOCOL(Value=0 => Boot Protocol)
    mov r8d, 0x00000B21
    movzx r9d, byte [usb_interface2_num]
    call usb_control_transfer_nodata

    ; SET_IDLE(Value=0 => infinite duration)
    mov r8d, 0x00000A21
    movzx r9d, byte [usb_interface2_num]
    call usb_control_transfer_nodata

.slot2_skip_set_protocol:

    ; Configure endpoint for slot2
    movzx edi, byte [usb_ep2_addr]
    and edi, 0x7F
    movzx esi, word [usb_ep2_mps]
    movzx edx, byte [usb_ep2_interval]
    call xhci_configure_endpoint
    test eax, eax
    jz .slot2_ep_restore_fail2

    ; Save slot2 slot/ep info (xhci_configure_endpoint updated xhci_int_ep_dci)
    mov al, [xhci_slot_id]
    mov [usb_slot2_id], al
    mov al, [xhci_int_ep_dci]
    mov [usb_int_ep2_dci], al
    mov al, [xhci_port_num]
    mov [usb_slot2_port], al

    ; Restore slot1 XHCI state
    mov al, [usb_slot1_id]
    mov [xhci_slot_id], al
    mov al, [usb_int_ep1_dci]
    mov [xhci_int_ep_dci], al

    ; Restore port1
    mov al, [xhci_port1_num]
    mov [xhci_port_num], al

    mov byte [usb_slot2_active], 1

    ; Queue initial transfers for slot2
    call usb_queue_mouse_read2
    call usb_queue_mouse_read2

    jmp .slot2_ok

.slot2_restore_fail:
    pop rax
    mov [usb_interface_num], al
    pop rax
    mov [usb_hid_protocol], al
    pop rax
    mov [usb_ep_interval], al
    pop rax
    mov [usb_ep_mps], ax
    pop rax
    mov [usb_ep_addr], al
    jmp .slot2_fail

.slot2_ep_restore_fail2:
    ; Restore slot1 state even on failure
    mov al, [usb_slot1_id]
    mov [xhci_slot_id], al
    mov al, [usb_int_ep1_dci]
    mov [xhci_int_ep_dci], al
    mov al, [xhci_port1_num]
    mov [xhci_port_num], al
    jmp .slot2_fail

.slot2_fail:
    ; Slot2 probing is non-fatal, but it reuses shared xHCI globals while
    ; enumerating.  Always restore slot1 state before returning to polling.
    mov al, [usb_slot1_id]
    mov [xhci_slot_id], al
    mov al, [usb_int_ep1_dci]
    mov [xhci_int_ep_dci], al
    mov al, [xhci_port1_num]
    mov [xhci_port_num], al
    mov byte [usb_slot2_active], 0

    ; Serial: ']' = slot2 init failed
    mov dx, 0x3F8
    mov al, ']'
    out dx, al
    mov byte [usb_accept_keyboard], 0
    xor eax, eax
    jmp .slot2_ret

.slot2_ok:
    ; Serial: ')' = slot2 init OK
    mov dx, 0x3F8
    mov al, ')'
    out dx, al
    mov byte [usb_accept_keyboard], 0
    mov eax, 1
.slot2_ret:
    ; Restore slot1 mode for xhci functions
    mov byte [xhci_slot2_mode], 0
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; usb_control_transfer_in - Perform Control Transfer (Data IN)
; R8 = Setup DWord 0, R9 = Setup DWord 1, RCX = Length, RDI = Buffer
; Returns: EAX = 1 on success
; ============================================================================
usb_control_transfer_in:
    ; 1. Setup Stage
    push rcx
    push rdi
    
    ; Setup TRB:
    ; DW0, DW1: Setup Data (R8, R9) -> TRB has IDT (Immediate Data)
    ; But XHCI spec says Setup TRB uses Immediate Data for the 8 setup bytes.
    ; DW0: RequestType | Request | Value
    ; DW1: Index | Length
    
    ; Note: R8/R9 passed by caller are the content of the 8 bytes.
    ; TRB fields:
    ; DW0 = R8
    ; DW1 = R9
    ; DW2 = 8 (Length of immediate data always 8)
    ; DW3 = TRB_SETUP | TRB_IDT | TRB_TRT_IN
    
    mov r10d, 8
    mov r11d, TRB_SETUP | TRB_IDT | TRB_TRT_IN
    call xhci_queue_ctrl_trb
    
    ; 2. Data Stage
    pop rdi
    pop rcx
    
    cmp rcx, 0
    je .no_data
    
    ; Data TRB
    mov r8d, edi             ; Buffer low
    xor r9d, r9d             ; Buffer high
    mov r10d, ecx            ; Length
    mov r11d, TRB_DATA | TRB_DIR_IN
    call xhci_queue_ctrl_trb
    
.no_data:
    ; 3. Status Stage (OUT)
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, TRB_STATUS | TRB_DIR_OUT | TRB_IOC
    call xhci_queue_ctrl_trb
    
    ; 4. Ring Doorbell (Slot 1, EP1=Control)
    movzx edi, byte [xhci_slot_id]
    mov esi, 1               ; EP 1 = Control
    call xhci_ring_doorbell
    
    ; 5. Wait for completion
    call usb_wait_completion
    ret

; ============================================================================
; usb_control_transfer_nodata - Perform Control Transfer (No Data)
; R8 = Setup DWord 0, R9 = Setup DWord 1
; ============================================================================
usb_control_transfer_nodata:
    ; 1. Setup Stage
    mov r10d, 8
    mov r11d, TRB_SETUP | TRB_IDT | TRB_TRT_NO_DATA
    call xhci_queue_ctrl_trb
    
    ; 2. Status Stage (IN)
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, TRB_STATUS | TRB_DIR_IN | TRB_IOC
    call xhci_queue_ctrl_trb
    
    ; 3. Ring Doorbell
    movzx edi, byte [xhci_slot_id]
    mov esi, 1
    call xhci_ring_doorbell
    
    ; 4. Wait
    call usb_wait_completion
    ret

; ============================================================================
; usb_wait_completion - Wait for status stage completion
; ============================================================================
usb_wait_completion:
    ; PIT-based 1-second timeout (tick-only: CPU-spin fallbacks fire far too
    ; early on fast real silicon and cause false control-transfer timeouts)
    ; Use rsi for deadline - xhci_poll_event saves/restores rsi internally
    push rbx
    push rcx
    push rsi
    mov rsi, [tick_count]
    add rsi, 100                 ; 100 ticks = 1 second at 100Hz
.poll:
    call xhci_poll_event         ; rsi preserved by xhci_poll_event (push/pop rsi inside)
    test eax, eax
    jnz .done

    mov rax, [tick_count]
    cmp rax, rsi                 ; rsi = deadline (not corrupted by xhci_poll_event)
    jl .poll

.fail_timeout:
    xor eax, eax
    pop rsi
    pop rcx
    pop rbx
    ret

.done:
    pop rsi
    pop rcx
    pop rbx
    ; Check if it was success
    cmp eax, 1
    jne .fail
    mov eax, 1
    ret
.fail:
    xor eax, eax
    ret

; usb_find_endpoint and usb_try_known_mouse_endpoint were migrated to zero-asm
; GritHLK - see src/kernel/grithlk/usb_hid_helpers.ghl. Same global names +
; ABI (config-descriptor walk at XHCI_CTRL_BUF_ADDR -> EAX=1/0, fills
; usb_ep_addr / usb_ep_mps / usb_ep_interval / usb_hid_protocol /
; usb_interface_num). The structured port keeps the EXACT original bounds
; checks (header >= 4 bytes, wTotalLength clamped to [4,512], per-descriptor
; bLength >= 2 and off+bLength <= wTotalLength, iface >= 8 / ep >= 7).
