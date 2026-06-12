
; ============================================================================
; usb_hid_init_same_ctrl - Re-enumerate on the currently active XHCI controller
; Used for hot-plug: device was unplugged and re-plugged on the same port/controller
; ============================================================================
FN_BEGIN usb_hid_init_same_ctrl, 0, 0, FN_RET_SCALAR
    ; Restore xhci_pci_search_start to the position of the current controller
    ; so xhci_pci_find will re-find the same one
    mov eax, [xhci_pci_this_start]
    mov [xhci_pci_search_start], eax
    jmp usb_hid_init_body

; ============================================================================
; usb_hid_init - Initialize USB HID Mouse (full scan from controller 0)
; ============================================================================
FN_BEGIN usb_hid_init, 0, 0, FN_RET_SCALAR
    ; Reset PCI search to beginning so we scan all controllers fresh
    mov dword [xhci_pci_search_start], 0

usb_hid_init_body:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp

    ; Reset active flag
    mov byte [usb_mouse_active], 0
    mov byte [usb_dbg_stage], 0
    mov byte [usb_use_parsed], 0
    mov byte [usb_interface_num], 0
    mov byte [usb_accept_keyboard], 0
    mov byte [usb_primary_keyboard_fallback], 0
    mov word [usb_device_vid], 0
    mov word [usb_device_pid], 0
    mov dword [usb_log_len], 0
    lea rsi, [rel szUsbLogHeader]
    call usb_log_str
    call usb_log_crlf
    lea rsi, [rel szUsbExpectedMouse]
    call usb_log_str
    call usb_log_crlf

    ; 1. Try XHCI controllers until one succeeds with a HID endpoint
    ;    xhci_pci_find continues from where it left off each call
    mov byte [usb_ctrl_attempts], 0
    mov byte [usb_no_xhci], 0   ; Assume XHCI might exist until proven otherwise
    jmp .try_next_controller

.try_next_port:
    ; Not HID on current port. Scan remaining ports on same controller
    ; before giving up and calling xhci_init for the next controller.
    ; This handles the case where a boot USB drive is on port 0 and
    ; the mouse is on a subsequent port of the same xHCI controller.
    mov rsi, [xhci_op_base]
    USBHID_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400                      ; Port register base
    movzx ecx, byte [xhci_max_ports]
    movzx edx, byte [xhci_port_num]     ; 1-based last tried → 0-based next to check
.tport_scan:
    cmp edx, ecx
    jge .try_next_controller            ; No more ports on this controller
    mov eax, edx
    shl eax, 4
    mov ebx, [rsi + rax + XHCI_PORTSC]
    test ebx, XHCI_PORTSC_CCS
    jz .tport_next
    ; Skip the rtl8156 NIC's port if it's bound.
    extern rtl8156_active, rtl8156_port
    cmp byte [rtl8156_active], 1
    jne .tport_not_nic
    movzx r10d, byte [rtl8156_port]
    lea r11d, [edx + 1]
    cmp r10d, r11d
    je .tport_next
.tport_not_nic:
    ; Found a port with a connected device
    lea ecx, [edx + 1]
    mov [xhci_port_num], cl             ; Save 1-based port number
    ; Save speed
    shr ebx, XHCI_PORTSC_SPEED_SHIFT
    and ebx, 0x0F
    mov [xhci_port_speed], bl
    ; Reset the port so device can be enumerated
    push rax                            ; save port byte offset across reload
    mov rsi, [xhci_op_base]
    USBHID_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400
    pop rax
    mov ebx, [rsi + rax + XHCI_PORTSC]
    and ebx, ~XHCI_PORTSC_CHANGE_BITS
    and ebx, ~XHCI_PORTSC_PED
    or  ebx, XHCI_PORTSC_PR
    mov [rsi + rax + XHCI_PORTSC], ebx
    ; Wait for PRC (Port Reset Change) with 50-tick timeout
    ; Recompute port offset each iteration from xhci_port_num
    mov rbx, [tick_count]
    add rbx, 50
    mov r9d, 10000000
.tport_wait_prc:
    movzx eax, byte [xhci_port_num]
    dec eax
    shl eax, 4
    mov rsi, [xhci_op_base]
    USBHID_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400
    mov edx, [rsi + rax + XHCI_PORTSC]
    test edx, XHCI_PORTSC_PRC
    jnz .tport_reset_done
    
    dec r9d
    jz .tport_reset_done
    
    mov rax, [tick_count]
    cmp rax, rbx
    jge .tport_reset_done               ; timeout - proceed anyway
    pause
    jmp .tport_wait_prc
.tport_reset_done:
    ; Clear PRC. PED is RW1C on xHCI PORTSC, so writing back PED=1 disables
    ; the port on real hardware. Mask it out and only write the change bit.
    movzx eax, byte [xhci_port_num]
    dec eax
    shl eax, 4
    mov rsi, [xhci_op_base]
    USBHID_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400
    mov ebx, [rsi + rax + XHCI_PORTSC]
    and ebx, ~XHCI_PORTSC_CHANGE_BITS
    and ebx, ~XHCI_PORTSC_PED
    or  ebx, XHCI_PORTSC_PRC
    mov [rsi + rax + XHCI_PORTSC], ebx
    ; Read updated speed after reset
    mov ebx, [rsi + rax + XHCI_PORTSC]
    shr ebx, XHCI_PORTSC_SPEED_SHIFT
    and ebx, 0x0F
    mov [xhci_port_speed], bl
    jmp .do_enable_slot
.tport_next:
    inc edx
    jmp .tport_scan

.try_next_controller:
    inc byte [usb_ctrl_attempts]
    cmp byte [usb_ctrl_attempts], 4    ; Max 4 XHCI controllers to try
    jg .fail

    ; On the FIRST attempt only, reuse an already-active controller (e.g. one
    ; brought up by rtl8156 before us) instead of resetting it. On subsequent
    ; attempts we have already exhausted that controller's ports without
    ; finding a HID device, so force a fresh xhci_init - this advances the
    ; PCI scan (xhci_pci_search_start) to the NEXT controller. AMD Strix
    ; Point and similar platforms expose multiple xHCI PCI functions; the
    ; mouse may live on the second or third one.
    cmp byte [usb_ctrl_attempts], 1
    jne .force_init
    cmp byte [xhci_active], 1
    je .xhci_ok
.force_init:
    mov byte [xhci_active], 0          ; allow xhci_init to take fresh ctrl
    call xhci_init
    test eax, eax
    jnz .xhci_ok
    lea rsi, [rel szUsbLogNoXhci]
    call usb_log_str
    call usb_log_crlf
    jmp .no_hw                  ; No more XHCI controllers found (PCI scan exhausted)
.xhci_ok:
    STAGE 1
    lea rsi, [rel szUsbLogXhciOk]
    call usb_log_str
    call usb_log_crlf

    ; Wait briefly for device settle. Release boot is marker-budgeted; the
    ; xhci_find_port reset path below still performs the required port waits.
%ifdef RELEASE_BUILD
    mov ecx, 1
%else
    ; USB spec: 100ms, but 50ms is enough for QEMU/most real devices.
    mov ecx, 50
%endif
    call usb_delay

    mov rsi, szUsbFindPort
    call usb_log_str
    call usb_log_crlf
    call debug_print

    ; --- 1. Find Port with Device ---
    call xhci_find_port
    test eax, eax
    jnz .port_ok
    lea rsi, [rel szUsbLogNoPort]
    call usb_log_str
    call usb_log_crlf
    jmp .try_next_controller
.port_ok:
    STAGE 2
    lea rsi, [rel szUsbLogPort]
    movzx ebx, byte [xhci_port_num]
    call usb_log_kv8
    lea rsi, [rel szUsbLogSpeed]
    movzx ebx, byte [xhci_port_speed]
    call usb_log_kv8

.do_enable_slot:
    mov rsi, szUsbEnableSlot
    call usb_log_str
    call usb_log_crlf
    call debug_print

    ; --- 2. Enable Slot ---
    call xhci_enable_slot
    test eax, eax
    jz .try_next_port
    STAGE 3
    lea rsi, [rel szUsbLogSlot]
    movzx ebx, byte [xhci_slot_id]
    call usb_log_kv8

    mov rsi, szUsbAddress
    call usb_log_str
    call usb_log_crlf
    call debug_print

    ; --- 3. Address Device ---
    call xhci_address_device
    test eax, eax
    jz .release_slot_try_next_port
    STAGE 4

    mov rsi, szUsbGetDesc
    call usb_log_str
    call usb_log_crlf
    call debug_print

    ; Serial: 'H' (HID Init)
    mov dx, 0x3F8
    mov al, 'H'
    out dx, al

    ; 4. Get Device Descriptor (to verify it's a mouse? or just to debug)
    ; Request: 80 06 00 01 00 00 12 00 (Get Descriptor Device, len 18)
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 18
    mov r8d, 0x01000680      ; Low dword of setup packet (GetDesc Device)
    mov r9d, 0x00120000      ; High dword (Len 18)
    call usb_control_transfer_in
    test eax, eax
    jz .release_slot_try_next_port  ; Failed to get descriptor - try next port
    STAGE 5
    movzx ebx, word [abs XHCI_CTRL_BUF_ADDR + 8]
    mov [usb_device_vid], bx
    lea rsi, [rel szUsbLogVid]
    movzx ebx, word [usb_device_vid]
    call usb_log_kv16
    movzx ebx, word [abs XHCI_CTRL_BUF_ADDR + 10]
    mov [usb_device_pid], bx
    lea rsi, [rel szUsbLogPid]
    movzx ebx, word [usb_device_pid]
    call usb_log_kv16

    ; Serial: 'D' (Descriptor)
    mov dx, 0x3F8
    mov al, 'D'
    out dx, al
    
    mov rsi, szUsbConfig
    call usb_log_str
    call usb_log_crlf
    call debug_print

    ; 5. Get Configuration Descriptor (first 9 bytes to get total length)
    ; Request: 80 06 00 02 00 00 09 00
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 9
    mov r8d, 0x02000680
    mov r9d, 0x00090000
    call usb_control_transfer_in
    test eax, eax
    jz .release_slot_try_next_port
    
    ; Read TotalLength from offset 2
    movzx ecx, word [abs XHCI_CTRL_BUF_ADDR + 2]
    
    ; 6. Get Full Configuration Descriptor
    mov rdi, XHCI_CTRL_BUF_ADDR
    ; rcx is already len
    mov r8d, 0x02000680
    mov r9d, ecx
    shl r9d, 16              ; Len in upper word
    call usb_control_transfer_in
    test eax, eax
    jz .release_slot_try_next_port
    STAGE 6

    ; 7. Parse Configuration Descriptor to find Interrupt Endpoint.
    ; Prefer boot-mouse protocol first; generic report-HID is a fallback so
    ; composite vendor/control interfaces do not mask the real mouse.
    mov byte [usb_find_report_hid], 0
    call usb_find_endpoint
    test eax, eax
    jnz .endpoint_ok
    mov byte [usb_find_report_hid], 1
    call usb_find_endpoint
    test eax, eax
    jnz .endpoint_ok
    call usb_try_known_mouse_endpoint
    test eax, eax
    jnz .endpoint_ok
    ; Not a HID device on this port. The slot is still enabled+addressed and
    ; the port is bound to it. Release the slot so a later driver (rtl8156)
    ; can address the same port without TRB Error.
    mov al, [xhci_slot_id]
    call xhci_disable_slot
    jmp .try_next_port

.release_slot_try_next_port:
    mov al, [xhci_slot_id]
    call xhci_disable_slot
    jmp .try_next_port
.endpoint_ok:
    STAGE 7
    lea rsi, [rel szUsbLogProto]
    movzx ebx, byte [usb_hid_protocol]
    call usb_log_kv8
    lea rsi, [rel szUsbLogEp]
    movzx ebx, byte [usb_ep_addr]
    call usb_log_kv8
    lea rsi, [rel szUsbLogMps]
    movzx ebx, word [usb_ep_mps]
    call usb_log_kv16
    lea rsi, [rel szUsbLogInterval]
    movzx ebx, byte [usb_ep_interval]
    call usb_log_kv8

    ; Serial: 'E' (Endpoint Found)
    mov dx, 0x3F8
    mov al, 'E'
    out dx, al

    ; 6. Set Configuration (Value = 1)
    ; Request: 00 09 01 00 00 00 00 00
    mov r8d, 0x00010900
    mov r9d, 0x00000000
    call usb_control_transfer_nodata
    test eax, eax
    jz .fail
    STAGE 8
    lea rsi, [rel szUsbLogConfigured]
    call usb_log_str
    call usb_log_crlf

    ; Serial: 'C' (Config Set)
    mov dx, 0x3F8
    mov al, 'C'
    out dx, al

    ; Set boot protocol for keyboard (1) and mouse (2); skip for report protocol (0)
    cmp byte [usb_hid_protocol], 0
    je .skip_set_protocol

    ; 7. Set Protocol (Value = 0 for Boot Protocol)
    ; Request: 21 0B 00 00 00 00 00 00 (SET_PROTOCOL)
    mov r8d, 0x00000B21
    movzx r9d, byte [usb_interface_num]
    call usb_control_transfer_nodata
    
    ; 8. Set Idle (Value = 0 for infinite duration)
    ; Request: 21 0A 00 00 00 00 00 00 (SET_IDLE)
    mov r8d, 0x00000A21
    movzx r9d, byte [usb_interface_num]
    call usb_control_transfer_nodata

.skip_set_protocol:

    ; 8b. Fetch HID Report Descriptor (type 0x22) for precise field layout
    ; GET_DESCRIPTOR: bmRequestType=0x81, bRequest=0x06, wValue=0x2200
    ; wIndex=matched interface, wLength=512
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 512
    mov r8d, 0x22000681         ; bmRequestType=0x81, GET_DESCRIPTOR, wValue=0x2200
    movzx r9d, byte [usb_interface_num]
    or r9d, 0x02000000          ; wIndex=matched interface, wLength=512
    call usb_control_transfer_in
    test eax, eax
    jz .skip_hid_parse          ; If it fails, fall through to boot protocol

    ; Parse the HID report descriptor
    mov rsi, XHCI_CTRL_BUF_ADDR
    mov ecx, 512
    call hid_parse_report_desc
    test eax, eax
    jz .skip_hid_parse
    ; Only use touchpad path for absolute digitizer (touchpad) devices.
    ; Simple mice, tablets, and keyboards use fixed-format paths.
    cmp byte [hid_parsed_is_absolute], 1
    jne .skip_hid_parse
    mov byte [usb_use_parsed], 1

.skip_hid_parse:

    ; 9. Configure Endpoint in XHCI
    ; EDI = EP num, ESI = MPS, EDX = Interval
    movzx edi, byte [usb_ep_addr]
    and edi, 0x7F            ; Clear direction bit (0x81 -> 1)
    movzx esi, word [usb_ep_mps]
    movzx edx, byte [usb_ep_interval]
    
    ; Debug: log EP, MPS, Interval
    ; ...
    
    call xhci_configure_endpoint
    test eax, eax
    jz .fail
    STAGE 9

    ; Serial: 'O' (OK)
    mov dx, 0x3F8
    mov al, 'O'
    out dx, al

    ; 10. Flush any pending events (like Port Status Changes from init)
    ; Do this BEFORE queuing mouse transfers so we don't flush their completion events!
    call xhci_flush_events

    mov byte [usb_mouse_active], 1
    STAGE 10
    lea rsi, [rel szUsbLogActive]
    call usb_log_str
    call usb_log_crlf

    ; Save slot1 info before possibly init-ing slot2
    mov al, [xhci_slot_id]
    mov [usb_slot1_id], al
    mov al, [xhci_int_ep_dci]
    mov [usb_int_ep1_dci], al
    mov al, [xhci_port_num]
    mov [usb_slot1_port], al

    ; Try to find and init a second USB HID device on a different port.
    ; IMPORTANT: do this BEFORE queuing slot1 reads so that slot2 control
    ; transfers don't race with slot1 Transfer Events in usb_wait_completion.
    call usb_hid_init_slot2     ; non-fatal - ignore return value

    ; 11. Queue initial interrupt transfers for slot1 (fill pipeline)
    ; Done after slot2 init so slot2 control transfers see a clean event ring.
    call usb_queue_mouse_read
    call usb_queue_mouse_read
    call usb_queue_mouse_read
    call usb_queue_mouse_read

    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov eax, 1
    ret

    ret

.no_hw:
    ; xhci_init returned 0 = no XHCI controller found in PCI scan.
    ; Mark as no hardware so usb_poll_mouse stops retrying.
    mov byte [usb_no_xhci], 1

.fail:
    ; Primary probing prefers pointer HID so a keyboard on an earlier port does
    ; not hide the mouse. If no pointer was usable, retry once accepting a boot
    ; keyboard as slot1; keyboard-only and keyboard-first hardware still needs
    ; an interrupt ring so usb_poll_mouse can feed the keyboard parser.
    cmp byte [usb_no_xhci], 1
    je .fail_final
    cmp byte [usb_primary_keyboard_fallback], 0
    jne .fail_final
    mov byte [usb_primary_keyboard_fallback], 1
    mov byte [usb_accept_keyboard], 1
    mov byte [usb_ctrl_attempts], 0
    mov dword [xhci_pci_search_start], 0
    jmp .try_next_controller

.fail_final:
    ; Serial: 'X' (Fail)
    lea rsi, [rel szUsbLogFail]
    call usb_log_str
    call usb_log_crlf
    mov dx, 0x3F8
    mov al, 'X'
    out dx, al

    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    xor eax, eax
    ret

; ============================================================================
; usb_delay - Hybrid PIT/Spin delay (safe against PIT timer freezes)
; Input: ECX = milliseconds
; ============================================================================
usb_delay:
    push rax
    push rbx
    push rcx
    push rdx

    ; Calculate PIT target (1 tick = 10ms)
    mov eax, ecx
    add eax, 9
    xor edx, edx
    mov ebx, 10
    div ebx
    test eax, eax
    jnz .start
    mov eax, 1

.start:
    mov rbx, rax
    mov rax, [tick_count]
    add rbx, rax         ; Target tick_count

    ; Calculate spin timeout (fallback)
    ; Keep this bounded so pre-STI delays do not look like a hard lock
    ; when tick_count is not advancing yet.
    mov rdx, 50000
    imul rdx, rcx        ; RDX = max spin iterations

.wait:
    mov rax, [tick_count]
    cmp rax, rbx
    jge .done

    dec rdx
    jz .done

    pause
    jmp .wait

.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
