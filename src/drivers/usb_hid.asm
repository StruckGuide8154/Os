; ============================================================================
; NexusOS v3.0 - USB HID Mouse Driver
; Implements USB HID protocol over XHCI
; ============================================================================
bits 64

%include "constants.inc"

extern xhci_init
extern xhci_queue_ctrl_trb
extern xhci_queue_int_trb
extern xhci_queue_int_trb2
extern xhci_ring_doorbell
extern xhci_poll_event
extern xhci_find_port
extern xhci_find_port_next
extern xhci_enable_slot
extern xhci_address_device
extern xhci_flush_events
extern xhci_pci_search_start
extern xhci_pci_this_start
extern xhci_slot_id
extern xhci_slot2_mode
extern xhci_int_ep_dci
extern xhci_slot2_id
extern xhci_int_ep2_dci
extern xhci_int_enqueue2
extern xhci_int_cycle2
extern xhci_port_num
extern xhci_port_speed
extern xhci_op_base
extern xhci_max_ports
extern xhci_port1_num
extern debug_print
extern hid_parse_report_desc
extern hid_process_touchpad_report
extern hid_parsed_report_bytes
extern hid_parsed_has_report_id

extern mouse_x
extern mouse_y
extern mouse_buttons
extern mouse_moved
extern mouse_scroll_y
extern scr_width, scr_height
extern tick_count

section .text
global usb_hid_init
global usb_hid_init_same_ctrl
global usb_hid_init_slot2
global usb_poll_mouse

; ============================================================================
; usb_hid_init_same_ctrl - Re-enumerate on the currently active XHCI controller
; Used for hot-plug: device was unplugged and re-plugged on the same port/controller
; ============================================================================
usb_hid_init_same_ctrl:
    ; Restore xhci_pci_search_start to the position of the current controller
    ; so xhci_pci_find will re-find the same one
    mov eax, [xhci_pci_this_start]
    mov [xhci_pci_search_start], eax
    jmp usb_hid_init_body

; ============================================================================
; usb_hid_init - Initialize USB HID Mouse (full scan from controller 0)
; ============================================================================
usb_hid_init:
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
    mov byte [usb_use_parsed], 0

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
.tport_wait_prc:
    movzx eax, byte [xhci_port_num]
    dec eax
    shl eax, 4
    mov rsi, [xhci_op_base]
    add rsi, 0x400
    mov edx, [rsi + rax + XHCI_PORTSC]
    test edx, XHCI_PORTSC_PRC
    jnz .tport_reset_done
    mov rax, [tick_count]
    cmp rax, rbx
    jge .tport_reset_done               ; timeout - proceed anyway
    pause
    jmp .tport_wait_prc
.tport_reset_done:
    ; Clear PRC
    movzx eax, byte [xhci_port_num]
    dec eax
    shl eax, 4
    mov rsi, [xhci_op_base]
    add rsi, 0x400
    mov ebx, [rsi + rax + XHCI_PORTSC]
    and ebx, ~XHCI_PORTSC_CHANGE_BITS
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

    call xhci_init
    test eax, eax
    jz .no_hw                   ; No more XHCI controllers found (PCI scan exhausted)

    ; Wait for device to settle after port reset.
    ; USB spec: 100ms, but 50ms is enough for QEMU/most real devices.
    mov ecx, 50
    call usb_delay

    mov rsi, szUsbFindPort
    call debug_print

    ; --- 1. Find Port with Device ---
    call xhci_find_port
    test eax, eax
    jz .try_next_controller

.do_enable_slot:
    mov rsi, szUsbEnableSlot
    call debug_print

    ; --- 2. Enable Slot ---
    call xhci_enable_slot
    test eax, eax
    jz .try_next_controller

    mov rsi, szUsbAddress
    call debug_print

    ; --- 3. Address Device ---
    call xhci_address_device
    test eax, eax
    jz .try_next_controller

    mov rsi, szUsbGetDesc
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
    jz .try_next_controller  ; Failed to get descriptor - try next

    ; Serial: 'D' (Descriptor)
    mov dx, 0x3F8
    mov al, 'D'
    out dx, al
    
    mov rsi, szUsbConfig
    call debug_print

    ; 5. Get Configuration Descriptor (first 9 bytes to get total length)
    ; Request: 80 06 00 02 00 00 09 00
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 9
    mov r8d, 0x02000680
    mov r9d, 0x00090000
    call usb_control_transfer_in
    test eax, eax
    jz .try_next_controller
    
    ; Read TotalLength from offset 2
    movzx ecx, word [XHCI_CTRL_BUF_ADDR + 2]
    
    ; 6. Get Full Configuration Descriptor
    mov rdi, XHCI_CTRL_BUF_ADDR
    ; rcx is already len
    mov r8d, 0x02000680
    mov r9d, ecx
    shl r9d, 16              ; Len in upper word
    call usb_control_transfer_in
    test eax, eax
    jz .try_next_controller

    ; 7. Parse Configuration Descriptor to find Interrupt Endpoint
    call usb_find_endpoint
    test eax, eax
    jz .try_next_port           ; Not a HID mouse - try next port on same controller

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
    mov r9d, 0x00000000
    call usb_control_transfer_nodata
    
    ; 8. Set Idle (Value = 0 for infinite duration)
    ; Request: 21 0A 00 00 00 00 00 00 (SET_IDLE)
    mov r8d, 0x00000A21
    mov r9d, 0x00000000
    call usb_control_transfer_nodata

.skip_set_protocol:

    ; 8b. Fetch HID Report Descriptor (type 0x22) for precise field layout
    ; GET_DESCRIPTOR: bmRequestType=0x81, bRequest=0x06, wValue=0x2200
    ; wIndex=0, wLength=512
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 512
    mov r8d, 0x22000681         ; bmRequestType=0x81, GET_DESCRIPTOR, wValue=0x2200
    mov r9d, 0x02000000         ; wIndex=0, wLength=512
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

    ; Serial: 'O' (OK)
    mov dx, 0x3F8
    mov al, 'O'
    out dx, al

    ; 10. Flush any pending events (like Port Status Changes from init)
    ; Do this BEFORE queuing mouse transfers so we don't flush their completion events!
    call xhci_flush_events

    mov byte [usb_mouse_active], 1

    ; Save slot1 info before possibly init-ing slot2
    mov al, [xhci_slot_id]
    mov [usb_slot1_id], al
    mov al, [xhci_int_ep_dci]
    mov [usb_int_ep1_dci], al

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
    ; Serial: 'X' (Fail)
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
; usb_delay - PIT-based delay (accurate on real hardware AND QEMU)
; Input: ECX = milliseconds (rounded up to 10ms PIT tick granularity)
; Uses tick_count from PIT IRQ0 (100Hz = 10ms/tick)
; ============================================================================
usb_delay:
    push rax
    push rbx
    push rcx

    ; Convert ms -> ticks (ceiling division by 10, minimum 1 tick)
    ; ticks = (ms + 9) / 10
    add ecx, 9
    mov eax, ecx
    xor edx, edx
    mov ecx, 10
    div ecx              ; EAX = ticks needed
    test eax, eax
    jnz .start
    mov eax, 1           ; At least 1 tick

.start:
    mov rbx, rax         ; RBX = ticks to wait (zero-extended)
    mov rax, [tick_count]
    add rbx, rax         ; RBX = target tick count

.wait:
    mov rax, [tick_count]
    cmp rax, rbx
    jge .done
    ; Spin (PIT ISR updates tick_count)
    pause
    jmp .wait

.done:
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; usb_poll_mouse - Check for mouse updates
; Called from kernel main loop
; ============================================================================
usb_poll_mouse:
    cmp byte [usb_mouse_active], 1
    je .loop

    ; Not active.
    ; First: check if the XHCI controller is running and has a PSC event
    ; (handles hot-plug: mouse plugged in after boot)
    cmp byte [xhci_active], 1
    jne .inactive_counter         ; Controller not even init'd - fall through to counter

    ; Controller is running but no mouse. Poll event ring for PSC (hot-plug).
.inactive_poll:
    call xhci_poll_event
    test eax, eax
    jz .inactive_counter          ; No events - fall through to counter

    ; Got an event - check if PSC (Type 34)
    mov edx, ebx
    shr edx, 10
    and edx, 0x3F
    cmp edx, 34
    jne .inactive_poll            ; Not PSC - drain and keep polling

    ; PSC event = device connected/disconnected on a port
    ; Immediately try to enumerate (don't wait for counter)
    mov dword [init_retry_counter], 0
    ; Don't reset xhci_pci_search_start - stay on this controller
    ; Call xhci_init directly (skips PCI rescan, reuses current controller)
    call usb_hid_init_same_ctrl
    ret

.inactive_counter:
    ; No hot-plug event - counter-based retry only if a controller was found before.
    ; If no XHCI hardware exists at all, don't retry (saves CPU).
    cmp byte [usb_no_xhci], 1
    je .ret                           ; No XHCI hardware - don't waste time

    inc dword [init_retry_counter]
    cmp dword [init_retry_counter], 30000  ; ~3 seconds at typical loop rates
    jl .ret

    ; Reset counter and try full init (scans all controllers)
    mov dword [init_retry_counter], 0
    call usb_hid_init
    ret

.loop:
    ; Check if transfer completed
    call xhci_poll_event
    test eax, eax
    jz .ret        ; No more events

    ; Event found! EAX=Code, EBX=Type/Slot, ECX=TRB Pointer (or DW0)
    ; Check if it's a Transfer Event (Type 32)
    mov edx, ebx
    shr edx, 10
    and edx, 0x3F
    cmp edx, 32    ; TRB_TRANSFER_EVT
    jne .check_psc ; Check Port Status Change

    ; It's a transfer event. Check completion code
    ; We already have EAX = Completion Code from xhci_poll_event
    
    cmp eax, 1     ; Success
    je .process_data
    cmp eax, 13    ; Short Packet (Success with less data)
    je .process_data
    
    ; If not Success or Short Packet, it's an error
    ; This likely means the endpoint is halted or there's a transaction error.
    ; We must recover aggressively.
    
    ; Debug: Print error code
    push rax
    mov dx, 0x3F8
    add al, '0' ; Convert low nibble to char (rough)
    out dx, al
    pop rax
    
    jmp .critical_error

.process_data:
    ; Route to correct slot based on event's slot ID (EBX bits 31:24)
    cmp byte [usb_slot2_active], 1
    jne .is_slot1_data
    mov edx, ebx
    shr edx, 24
    and edx, 0xFF
    movzx ecx, byte [usb_slot2_id]
    cmp edx, ecx
    je .process_slot2_loop

.is_slot1_data:
    ; Process Mouse Data at XHCI_MOUSE_BUF_ADDR (slot1)
    mov rsi, XHCI_MOUSE_BUF_ADDR

    ; If HID report descriptor was parsed, use it for accurate field extraction
    cmp byte [usb_use_parsed], 1
    jne .process_fixed_format

    ; Skip report ID if present
    cmp byte [hid_parsed_has_report_id], 1
    jne .parsed_no_skip
    inc rsi
.parsed_no_skip:
    movzx ecx, word [usb_ep_mps]
    call hid_process_touchpad_report
    mov byte [mouse_moved], 1
    call usb_queue_mouse_read
    jmp .loop

.process_fixed_format:
    ; Keyboard boot protocol: pass entire 8-byte report to parser, no mouse update
    cmp byte [usb_hid_protocol], 1
    je .process_keyboard_report

    ; Update Buttons (mouse/touchpad)
    mov al, [rsi]
    mov [mouse_buttons], al

    ; Protocol 2 = mouse boot protocol = relative
    ; Protocol 0 = report protocol; if we are here, usb_use_parsed was not set
    ;   (hid_parsed_is_absolute=0), so treat as relative (boot-compat format).
    cmp byte [usb_hid_protocol], 2
    je .process_relative
    cmp byte [usb_hid_protocol], 0
    je .process_relative

.process_absolute:
    ; Tablet format:
    ; Byte 1-2: X, 3-4: Y (0 to 0x7FFF)
    movzx eax, word [rsi + 1]
    mov ecx, [scr_width]
    mul ecx
    mov ecx, 0x7FFF
    div ecx
    mov [mouse_x], eax
    
    movzx eax, word [rsi + 3]
    mov ecx, [scr_height]
    mul ecx
    mov ecx, 0x7FFF
    div ecx
    mov [mouse_y], eax
    jmp .done_movement

.process_relative:
    ; Update X
    movsx eax, byte [rsi + 1]
    add [mouse_x], eax

    ; Clamp X
    cmp dword [mouse_x], 0
    jge .x_ge_0
    mov dword [mouse_x], 0
.x_ge_0:
    mov eax, [scr_width]
    dec eax
    cmp [mouse_x], eax
    jle .x_le_max
    mov [mouse_x], eax
.x_le_max:

    ; Update Y
    movsx eax, byte [rsi + 2]
    add [mouse_y], eax

    ; Scroll wheel: byte 3 present when MPS >= 4
    movzx ecx, word [usb_ep_mps]
    cmp ecx, 4
    jl .no_usb_scroll
    movsx eax, byte [rsi + 3]
    test eax, eax
    jz .no_usb_scroll
    mov [mouse_scroll_y], eax
.no_usb_scroll:

    ; Clamp Y
    cmp dword [mouse_y], 0
    jge .y_ge_0
    mov dword [mouse_y], 0
.y_ge_0:
    mov eax, [scr_height]
    dec eax
    cmp [mouse_y], eax
    jle .y_le_max
    mov [mouse_y], eax
.y_le_max:

.done_movement:
    ; Set moved flag
    mov byte [mouse_moved], 1

    ; Re-queue transfer
    call usb_queue_mouse_read
    jmp .loop

.process_keyboard_report:
    ; RSI = 8-byte USB HID boot keyboard report
    call usb_parse_keyboard_report
    call usb_queue_mouse_read
    jmp .loop

.process_slot2_loop:
    ; Slot2 transfer event inline handler (routes back to .loop)
    cmp byte [usb_hid_protocol2], 1
    je .s2l_keyboard
    ; Relative mouse: buf = XHCI_MOUSE_BUF2_ADDR
    mov rsi, XHCI_MOUSE_BUF2_ADDR
    mov al, [rsi]
    mov [mouse_buttons], al
    movsx eax, byte [rsi + 1]
    add [mouse_x], eax
    movsx eax, byte [rsi + 2]
    add [mouse_y], eax
    ; Clamp X
    cmp dword [mouse_x], 0
    jge .s2l_x_ok
    mov dword [mouse_x], 0
.s2l_x_ok:
    mov eax, [scr_width]
    dec eax
    cmp [mouse_x], eax
    jle .s2l_y_check
    mov [mouse_x], eax
.s2l_y_check:
    ; Clamp Y
    cmp dword [mouse_y], 0
    jge .s2l_y_ok
    mov dword [mouse_y], 0
.s2l_y_ok:
    mov eax, [scr_height]
    dec eax
    cmp [mouse_y], eax
    jle .s2l_moved
    mov [mouse_y], eax
.s2l_moved:
    mov byte [mouse_moved], 1
    call usb_queue_mouse_read2
    jmp .loop
.s2l_keyboard:
    mov rsi, XHCI_MOUSE_BUF2_ADDR
    call usb_parse_keyboard_report
    call usb_queue_mouse_read2
    jmp .loop

.check_psc:
    ; Port Status Change Event (Type 34)
    cmp edx, 34
    jne .loop

    ; Device connected or disconnected on this controller's port.
    ; Re-enumerate on the SAME controller (don't PCI-rescan).
.retry_init:
    call usb_hid_init_same_ctrl
    test eax, eax
    jz .retry_delay
    jmp .ret

.retry_delay:
    mov dword [init_retry_counter], 0
    ret

.ret:
    ; ---- Poll slot 2 (second USB device) ----
    cmp byte [usb_slot2_active], 1
    jne .ret2

    ; Swap in slot2 context for xhci_poll_event to match
    ; (xhci_poll_event checks event ring which is shared - filter by slot2_id)
    call xhci_poll_event
    test eax, eax
    jz .ret2

    ; Check event type
    mov edx, ebx
    shr edx, 10
    and edx, 0x3F
    cmp edx, 32                 ; Transfer event?
    jne .ret2

    ; Filter: verify slot ID matches slot2 (not a stray slot1 event)
    push rax
    mov edx, ebx
    shr edx, 24
    and edx, 0xFF
    movzx ecx, byte [usb_slot2_id]
    cmp edx, ecx
    pop rax
    jne .ret2

    cmp eax, 1
    je .slot2_data
    cmp eax, 13
    jne .ret2                   ; Error - ignore for now

.slot2_data:
    mov rsi, XHCI_MOUSE_BUF2_ADDR
    ; If slot2 is a keyboard, parse keyboard report
    cmp byte [usb_hid_protocol2], 1
    je .slot2_keyboard_parse
    ; Process slot2 mouse data
    mov al, [rsi]
    mov [mouse_buttons], al

    movsx eax, byte [rsi + 1]
    add [mouse_x], eax
    movsx eax, byte [rsi + 2]
    add [mouse_y], eax

    ; Clamp X
    cmp dword [mouse_x], 0
    jge .s2_x_ok
    mov dword [mouse_x], 0
.s2_x_ok:
    mov eax, [scr_width]
    dec eax
    cmp [mouse_x], eax
    jle .s2_y_check
    mov [mouse_x], eax
.s2_y_check:
    cmp dword [mouse_y], 0
    jge .s2_y_ok
    mov dword [mouse_y], 0
.s2_y_ok:
    mov eax, [scr_height]
    dec eax
    cmp [mouse_y], eax
    jle .s2_moved
    mov [mouse_y], eax
.s2_moved:
    mov byte [mouse_moved], 1
    call usb_queue_mouse_read2
    jmp .ret2

.slot2_keyboard_parse:
    call usb_parse_keyboard_report
    call usb_queue_mouse_read2

.ret2:
    ret

.critical_error:
    ; Critical XHCI error (e.g. Endpoint Halted, Babble, Transaction Error)
    ; Trigger full re-initialization to reset controller and endpoints
    jmp .retry_init  ; Use the retry logic from above

.transfer_fail:
    jmp .critical_error

; ============================================================================
; usb_queue_mouse_read - Queue an interrupt transfer
; ============================================================================
usb_queue_mouse_read:
    ; Normal TRB for data transfer
    ; DWord 0, 1: Buffer Address
    mov r8d, XHCI_MOUSE_BUF_ADDR
    xor r9d, r9d
    
    ; DWord 2: Length (Transfer Length)
    movzx r10d, word [usb_ep_mps]
    ; TD Size = 0, Interrupter = 0
    
    ; DWord 3: Flags
    ; IOC (Interrupt On Completion) | ISP (Interrupt on Short Packet) | Setup? No, Normal TRB (1)
    mov r11d, TRB_NORMAL | TRB_IOC | (1 << 2) ; ISP
    
    call xhci_queue_int_trb

    ; Ring Doorbell for endpoint
    movzx edi, byte [xhci_slot_id]
    movzx esi, byte [xhci_int_ep_dci]
    call xhci_ring_doorbell
    ret

; ============================================================================
; usb_queue_mouse_read2 - Queue interrupt transfer for slot 2
; ============================================================================
usb_queue_mouse_read2:
    mov r8d, XHCI_MOUSE_BUF2_ADDR
    xor r9d, r9d
    movzx r10d, word [usb_ep2_mps]
    mov r11d, TRB_NORMAL | TRB_IOC | (1 << 2)
    call xhci_queue_int_trb2
    movzx edi, byte [usb_slot2_id]
    movzx esi, byte [usb_int_ep2_dci]
    call xhci_ring_doorbell
    ret

; ============================================================================
; usb_hid_init_slot2 - Enumerate second USB HID device on next available port
; Non-fatal: returns 0 if no second device found
; ============================================================================
usb_hid_init_slot2:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp

    mov byte [usb_slot2_active], 0

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

    movzx ecx, word [XHCI_CTRL_BUF_ADDR + 2]
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

    call usb_find_endpoint
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

    ; Restore slot1 ep vars
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
    ; Serial: ']' = slot2 init failed
    mov dx, 0x3F8
    mov al, ']'
    out dx, al
    xor eax, eax
    jmp .slot2_ret

.slot2_ok:
    ; Serial: ')' = slot2 init OK
    mov dx, 0x3F8
    mov al, ')'
    out dx, al
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
    ; PIT-based 1-second timeout. CPU-loops fail on fast real hardware.
    push rbx
    mov rbx, [tick_count]
    add rbx, 100                 ; 100 ticks = 1 second at 100Hz
.poll:
    call xhci_poll_event
    test eax, eax
    jnz .done
    mov rax, [tick_count]
    cmp rax, rbx
    jl .poll
    xor eax, eax
    pop rbx
    ret
.done:
    pop rbx
    ; Check if it was success
    cmp eax, 1
    jne .fail
    mov eax, 1
    ret
.fail:
    xor eax, eax
    ret

; ============================================================================
; usb_find_endpoint - Parse Config Descriptor at XHCI_CTRL_BUF_ADDR
; Returns: EAX=1 found, updates usb_ep_addr, usb_ep_mps
; ============================================================================
usb_find_endpoint:
    mov rsi, XHCI_CTRL_BUF_ADDR
    movzx ecx, word [rsi + 2]  ; wTotalLength
    
    ; Parse loop state
    xor edx, edx             ; Offset in buffer
    xor ebx, ebx             ; Flag: found mouse interface (0=no, 1=yes)
    
.parse:
    cmp edx, ecx
    jge .not_found
    
    ; Read bLength (offset + 0)
    movzx eax, byte [rsi + rdx]
    test eax, eax
    jz .not_found            ; Zero length descriptor? Abort to avoid infinite loop
    
    ; Read bDescriptorType (offset + 1)
    mov al, [rsi + rdx + 1]
    
    cmp al, USB_DESC_INTERFACE
    je .check_interface
    
    cmp al, USB_DESC_ENDPOINT
    je .check_endpoint
    
    jmp .next_desc

.check_interface:
    ; Found an interface descriptor!
    ; Accept: Class=3 (HID) with ANY protocol:
    ;   Protocol=0 = Report Protocol (touchpads, composite HID)
    ;   Protocol=1 = Keyboard boot protocol  (skip)
    ;   Protocol=2 = Mouse boot protocol     (accept)
    ; We accept 0 or 2 - any HID with an interrupt IN endpoint will work.

    cmp byte [rsi + rdx + 5], 3  ; bInterfaceClass = HID?
    jne .not_hid_interface

    ; Accept: Keyboard (1), Mouse (2), Report Protocol (0)
    mov al, [rsi + rdx + 7]
    mov [usb_hid_protocol], al
    mov ebx, 1                   ; Set "found HID" flag - look for interrupt IN next
    jmp .next_desc

.not_hid_interface:
    mov ebx, 0                   ; Not a usable HID interface
    jmp .next_desc

.check_endpoint:
    ; Found an endpoint descriptor
    ; Only care if we are currently inside a valid Mouse Interface
    test ebx, ebx
    jz .next_desc
    
    ; Check Attributes (offset + 3) -> bits 1:0 = Transfer Type
    mov al, [rsi + rdx + 3]
    and al, 0x03
    cmp al, USB_EP_INTERRUPT
    jne .next_desc
    
    ; Check Direction (offset + 2) -> bit 7 (1=IN)
    mov al, [rsi + rdx + 2]
    test al, 0x80
    jz .next_desc
    
    ; Found Interrupt IN endpoint for a HID device (mouse or touchpad)!

    ; Save Endpoint Address (bEndpointAddress, offset +2)
    mov al, [rsi + rdx + 2]
    mov [usb_ep_addr], al

    ; Save Max Packet Size (wMaxPacketSize, offset +4, LE word)
    mov ax, [rsi + rdx + 4]
    and ax, 0x07FF               ; Bits 10:0 only (USB 2.0 HS can have bigger in high bits)
    test ax, ax
    jnz .mps_ok
    mov ax, 8                    ; Fallback: 8 bytes (minimum HID boot-mouse packet)
.mps_ok:
    mov [usb_ep_mps], ax

    ; Save Interval (bInterval, offset +6)
    mov al, [rsi + rdx + 6]
    mov [usb_ep_interval], al

    ; Success!
    mov eax, 1
    ret

.next_desc:
    ; Advance by bLength
    movzx eax, byte [rsi + rdx]
    add edx, eax
    jmp .parse

.not_found:
    xor eax, eax
    ret

section .data
usb_mouse_active: db 0
usb_no_xhci:      db 0           ; 1 = no XHCI hardware found, stop retrying
usb_hid_protocol: db 0
usb_ep_addr:      db 0
usb_ep_mps:       dw 0
usb_ep_interval:  db 0
init_retry_counter: dd 0
usb_ctrl_attempts: db 0          ; Number of XHCI controllers tried this init cycle

; Slot 1 saved state (used when init-ing slot 2)
usb_slot1_id:     db 0
usb_int_ep1_dci:  db 0

usb_use_parsed:   db 0           ; 1 = HID report descriptor parsed

; Slot 2 device info
usb_slot2_active: db 0
usb_slot2_id:     db 0
usb_int_ep2_dci:  db 0
usb_ep2_addr:     db 0
usb_ep2_mps:      dw 0
usb_ep2_interval: db 0
usb_hid_protocol2: db 0

; USB keyboard state
usb_kb_prev_mods: db 0

; USB HID keycode -> PS/2 scancode translation table (256 bytes)
; Maps USB HID boot protocol keycodes to PS/2 scancode set 1 equivalents.
; Extended PS/2 scancodes (arrows, nav keys) stored with bit7 set (e.g. 0xC8=Up).
usb_hid_to_ps2:
    ; 0x00-0x03: no key, error, post fail
    db 0, 0, 0, 0
    ; 0x04-0x1D: a-z (USB alphabetical order -> PS/2 scancodes)
    db 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23  ; a b c d e f g h
    db 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19  ; i j k l m n o p
    db 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D  ; q r s t u v w x
    db 0x15, 0x2C                                        ; y z
    ; 0x1E-0x27: 1-9, 0
    db 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B
    ; 0x28-0x2C: Enter, Esc, Backspace, Tab, Space
    db 0x1C, 0x01, 0x0E, 0x0F, 0x39
    ; 0x2D-0x38: - = [ ] \ (non-US) ; ' ` , . /
    db 0x0C, 0x0D, 0x1A, 0x1B, 0x2B, 0x00, 0x27, 0x28, 0x29, 0x33, 0x34, 0x35
    ; 0x39: CapsLock
    db 0x3A
    ; 0x3A-0x45: F1-F12
    db 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58
    ; 0x46-0x48: PrintScreen, ScrollLock, Pause
    db 0, 0, 0
    ; 0x49-0x4E: Insert, Home, PageUp, Delete, End, PageDown
    db 0xD2, 0xC7, 0xC9, 0xD3, 0xCF, 0xD1
    ; 0x4F-0x52: Right, Left, Down, Up (extended PS/2)
    db 0xCD, 0xCB, 0xD0, 0xC8
    ; 0x53: NumLock, 0x54-0x63: numpad / * - + Enter 1-9 0 .
    db 0x45, 0xB5, 0x37, 0x4A, 0x9C, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49, 0x52, 0x53
    ; 0x64-0xFF: fill rest with 0
    times (256 - 0x64) db 0

section .bss
usb_kb_prev_keys: resb 6

section .text
; ============================================================================
; usb_parse_keyboard_report - Parse USB HID boot keyboard report, push to kb_buffer
; RSI = 8-byte report: [modifier, reserved, key0..key5]
; ============================================================================
usb_parse_keyboard_report:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10

    ; 1. Map USB HID modifier byte to KMOD_* and update kb_modifiers
    movzx r9d, byte [rsi]       ; r9 = current modifier byte
    mov bl, 0
    test r9b, 0x02              ; LShift
    jz .no_ls
    or bl, KMOD_SHIFT
.no_ls:
    test r9b, 0x20              ; RShift
    jz .no_rs
    or bl, KMOD_SHIFT
.no_rs:
    test r9b, 0x01              ; LCtrl
    jz .no_lc
    or bl, KMOD_CTRL
.no_lc:
    test r9b, 0x10              ; RCtrl
    jz .no_rc
    or bl, KMOD_CTRL
.no_rc:
    test r9b, 0x04              ; LAlt
    jz .no_la
    or bl, KMOD_ALT
.no_la:
    test r9b, 0x40              ; RAlt
    jz .no_ra
    or bl, KMOD_ALT
.no_ra:
    mov [kb_modifiers], bl
    mov [usb_kb_prev_mods], r9b

    ; 2. For each of the 6 keycode slots, push new presses to kb_buffer
    mov r10d, 0                 ; slot index 0..5
.key_loop:
    cmp r10d, 6
    jge .keys_done

    movzx eax, byte [rsi + r10 + 2]  ; current keycode
    inc r10d
    cmp al, 1
    jle .key_loop               ; skip 0 (no key) and 1 (error)

    ; Check if this keycode was in the previous report (held = skip)
    mov r8d, 0                  ; prev-key search index
.find_prev:
    cmp r8d, 6
    jge .is_new_press
    cmp al, [usb_kb_prev_keys + r8]
    je .key_loop                ; found in prev -> already held, skip
    inc r8d
    jmp .find_prev

.is_new_press:
    ; Translate USB HID keycode to PS/2 scancode
    movzx ecx, al               ; USB HID keycode
    movzx ecx, byte [usb_hid_to_ps2 + ecx]
    test ecx, ecx
    jz .key_loop                ; no mapping

    ; Get ASCII from PS/2 scancode tables
    cmp ecx, 128
    jge .push_ext_key           ; extended scancode (arrows etc.) -> ASCII=0

    test byte [kb_modifiers], KMOD_SHIFT
    jz .use_normal
    movzx edx, byte [scancode_shifted + ecx]
    jmp .push_event
.use_normal:
    movzx edx, byte [scancode_normal + ecx]

.push_event:
    ; Push [scancode, ascii, modifiers, pressed=1] to kb_buffer
    push rcx
    push rdx
    mov r8d, [kb_tail]
    mov r9d, r8d
    shl r9d, 2
    lea rdi, [kb_buffer + r9]
    mov [rdi], cl               ; PS/2 scancode
    mov [rdi + 1], dl           ; ASCII
    mov dl, [kb_modifiers]
    mov [rdi + 2], dl           ; modifiers
    mov byte [rdi + 3], 1       ; pressed
    inc r8d
    and r8d, (KB_BUFFER_SIZE - 1)
    mov [kb_tail], r8d
    pop rdx
    pop rcx
    jmp .key_loop

.push_ext_key:
    xor edx, edx                ; ASCII=0 for extended keys
    jmp .push_event

.keys_done:
    ; Copy current keycodes to prev_keys
    mov r8d, 0
.copy_loop:
    cmp r8d, 6
    jge .copy_done
    movzx eax, byte [rsi + r8 + 2]
    mov [usb_kb_prev_keys + r8], al
    inc r8d
    jmp .copy_loop
.copy_done:

    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

szUsbFindPort   db "USB: Finding Port...", 0
szUsbEnableSlot db "USB: Enabling Slot...", 0
szUsbAddress    db "USB: Addressing Device...", 0
szUsbGetDesc    db "USB: Getting Descriptor...", 0
szUsbConfig     db "USB: Getting Config...", 0
