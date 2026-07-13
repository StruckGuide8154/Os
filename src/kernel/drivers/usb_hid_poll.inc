; ============================================================================
; usb_poll_mouse - Check for mouse updates
; Called from kernel main loop
; ============================================================================
FN_BEGIN usb_poll_mouse, 0, 0, FN_RET_SCALAR
    cmp byte [usb_mouse_active], 1
    je .loop

.normal_inactive:
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
    inc dword [usb_dbg_evt]   ; DEBUG: count transfer events delivered

    ; It's a transfer event. Check completion code
    ; We already have EAX = Completion Code from xhci_poll_event

    cmp eax, 1     ; Success
    je .process_data
    cmp eax, 13    ; Short Packet (Success with less data)
    je .process_data

    ; If not Success or Short Packet, it's an error
    ; This likely means the endpoint is halted or there's a transaction error.
    ; We must recover aggressively.

    ; Debug: Print error code (logless in release: gated like SER, but al holds
    ; the runtime completion code so it can't use the immediate-only SER macro)
%ifdef ENABLE_DEBUG_SERIAL
    push rax
    push rdx
    mov dx, 0x3F8
    add al, '0' ; Convert low nibble to char (rough)
    out dx, al
    pop rdx
    pop rax
%endif
    inc dword [usb_dbg_err]   ; DEBUG: count error completion codes
    mov [usb_dbg_errcode], al

    jmp .critical_error

.process_data:
    ; Route to correct slot based on event's slot ID (EBX bits 31:24).
    mov edx, ebx
    shr edx, 24
    and edx, 0xFF

    ; NIC slot? Hand the event to rtl8156_consume_event, which runs
    ; handle_frame + requeues the bulk-IN. This is the single consumer of NIC
    ; RX events - DHCP / ARP / ICMP all derive their state from frames the
    ; consume_event path delivers, no per-syscall xHCI polling.
    extern rtl8156_active, rtl8156_slot_id, rtl8156_consume_event
    cmp byte [rtl8156_active], 1
    jne .not_nic_event
    movzx r8d, byte [rtl8156_slot_id]
    cmp edx, r8d
    jne .not_nic_event
    ; EAX/EBX/ECX still hold the popped event from xhci_poll_event.
    call rtl8156_consume_event
    jmp .loop
.not_nic_event:

    cmp byte [usb_slot2_active], 1
    jne .is_slot1_data
    movzx ecx, byte [usb_slot2_id]
    cmp edx, ecx
    je .process_slot2_loop

.is_slot1_data:
    ; Process Mouse Data at XHCI_MOUSE_BUF_ADDR (slot1)
    mov rsi, XHCI_MOUSE_BUF_ADDR

    ; DEBUG: snapshot first 4 report bytes + bump report counter
    push rax
    mov eax, [rsi]
    mov [usb_dbg_report], eax
    inc dword [usb_dbg_rpt]
    pop rax

    ; If HID report descriptor was parsed, use it for accurate field extraction
    cmp byte [usb_use_parsed], 1
    jne .process_fixed_format

    ; Skip report ID if present
    cmp byte [hid_parsed_has_report_id], 1
    jne .parsed_no_skip
    mov al, [rsi]
    cmp al, [hid_parsed_report_id]
    jne .parsed_report_id_mismatch
    inc rsi
.parsed_no_skip:
    movzx ecx, word [usb_ep_mps]
    ; Fail-closed clamp on the parser extent: never walk more than a buffer's
    ; worth regardless of the device-claimed mps (defence in depth vs the GHL mask).
    cmp ecx, XHCI_HID_REPORT_MAX
    jbe .parsed_len_ok
    mov ecx, XHCI_HID_REPORT_MAX
.parsed_len_ok:
    call hid_process_touchpad_report
    mov byte [mouse_moved], 1
    call usb_queue_mouse_read
    jmp .loop

.parsed_report_id_mismatch:
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
    test ecx, ecx
    jz .done_movement
    div ecx
    mov [mouse_x], eax

    movzx eax, word [rsi + 3]
    mov ecx, [scr_height]
    mul ecx
    mov ecx, 0x7FFF
    test ecx, ecx
    jz .done_movement
    div ecx
    mov [mouse_y], eax
    jmp .done_movement

.process_relative:
    ; Update X
    movsx eax, byte [rsi + 1]
    call mouse_apply_sense_x
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
    call mouse_apply_sense_y
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
    call mouse_apply_sense_x
    add [mouse_x], eax
    movsx eax, byte [rsi + 2]
    call mouse_apply_sense_y
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

    ; Ack the PORTSC change bits for the affected port so the controller
    ; stops re-firing the same PSCE on every poll. Per xHCI spec, PSCE
    ; event TRB DW0 bits 31:24 carry the 1-based port number; ecx holds DW0.
    push rax
    push rbx
    push rsi
    mov eax, ecx
    shr eax, 24
    and eax, 0xFF
    test eax, eax
    jz .psc_no_ack
    cmp al, [xhci_max_ports]
    ja .psc_no_ack
    dec eax                              ; 0-based index
    shl eax, 4                           ; * 16 bytes per port
    mov rsi, [xhci_op_base]
    USBHID_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400
    mov ebx, [rsi + rax + XHCI_PORTSC]
    and ebx, ~XHCI_PORTSC_PED            ; PED is RW1C - don't disable port
    ; Change bits are RW1C: reading them as 1 and writing back 1 clears them.
    mov [rsi + rax + XHCI_PORTSC], ebx
.psc_no_ack:
    pop rsi
    pop rbx
    pop rax

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
    ; XHCI completion error on a Transfer Event.
    ; Code 6 = STALL (endpoint halted) is the common case. Per xHCI spec
    ; 4.6.8 it can be cleared with a Reset Endpoint command + Set TR Dequeue
    ; Pointer; no need to nuke the whole controller. Linux usbhid does the
    ; same dance. Slot1 only - slot2 falls through to full re-init.
    cmp byte [usb_dbg_errcode], 6
    jne .full_reinit
    ; Only attempt lightweight recovery if slot1 is active and the failing
    ; event was on slot1 (avoid stepping on slot2 / NIC slot during recovery).
    cmp byte [usb_mouse_active], 1
    jne .full_reinit
    call usb_recover_stall_slot1
    test eax, eax
    jz .full_reinit
    jmp .loop                ; recovery succeeded - drain more events
.full_reinit:
    jmp .retry_init  ; Use the retry logic from above

.transfer_fail:
    jmp .critical_error

; ============================================================================
; usb_hid_requeue_slot1_reads - Re-prime the mouse interrupt ring after some
; other driver (rtl8156 NIC init) clobbered xhci_slot_id / xhci_int_ep_dci
; AND drained pending Transfer Events with xhci_flush_events. Without this
; the 4 reads queued in usb_hid_init complete, get flushed before
; usb_poll_mouse sees them, and no new reads ever get queued → mouse dies.
; Safe to call when usb_mouse_active==0 (no-op).
; ============================================================================
global usb_hid_requeue_slot1_reads
usb_hid_requeue_slot1_reads:
    cmp byte [usb_mouse_active], 1
    jne .done
    mov al, [usb_slot1_id]
    mov [xhci_slot_id], al
    mov al, [usb_int_ep1_dci]
    mov [xhci_int_ep_dci], al
    call usb_queue_mouse_read
    call usb_queue_mouse_read
    call usb_queue_mouse_read
    call usb_queue_mouse_read
.done:
    ret

; ============================================================================
; usb_hid_requeue_slot1_one - Queue a SINGLE mouse interrupt read. Called from
; rtl8156_wait_completion every time it drops a HID Transfer Event so the
; mouse ring stays primed during long DHCP/ping waits without flooding.
; ============================================================================
global usb_hid_requeue_slot1_one
usb_hid_requeue_slot1_one:
    cmp byte [usb_mouse_active], 1
    jne .done1
    mov al, [usb_slot1_id]
    mov [xhci_slot_id], al
    mov al, [usb_int_ep1_dci]
    mov [xhci_int_ep_dci], al
    call usb_queue_mouse_read
.done1:
    ret

; ============================================================================
; usb_recover_stall_slot1 - Lightweight STALL recovery for slot1's interrupt
; endpoint, per xHCI spec 4.6.8 + USB 2.0 9.4.5:
;   1. Reset Endpoint command (xHCI side: EP halt → Stopped)
;   2. CLEAR_FEATURE(ENDPOINT_HALT) on default pipe (device side: data toggle
;      reset & un-halt; required by USB spec even if xHCI half already cleared)
;   3. Zero the interrupt transfer ring and reset enqueue/cycle
;   4. Set TR Dequeue Pointer command (xHCI side: arm ring at our new start)
;   5. Requeue interrupt reads & doorbell - endpoint resumes Running
; Returns EAX=1 on success, 0 on failure (caller should fall back to full
; re-init). Slot1 must be active before calling.
; ============================================================================
global usb_recover_stall_slot1
usb_recover_stall_slot1:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11

    cmp byte [usb_mouse_active], 1
    jne .rs_fail

    ; Restore slot1 ctx so shared xHCI helpers operate on the right slot/EP.
    mov al, [usb_slot1_id]
    mov [xhci_slot_id], al
    mov al, [usb_int_ep1_dci]
    mov [xhci_int_ep_dci], al

    ; --- 1. xHCI Reset Endpoint command ---
    ; DW0=0, DW1=0, DW2=0
    ; DW3 = TRB_RESET_ENDPOINT | (SlotID << 24) | (EpID << 16)
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    movzx eax, byte [xhci_slot_id]
    shl eax, 24
    movzx edx, byte [xhci_int_ep_dci]
    shl edx, 16
    or eax, edx
    or eax, TRB_RESET_ENDPOINT
    mov r11d, eax
    call xhci_submit_cmd
    cmp eax, 1
    jne .rs_fail

    ; --- 2. CLEAR_FEATURE(ENDPOINT_HALT) on device ---
    ; Setup packet (low dword) : bmRequestType=0x02, bRequest=0x01 (CLEAR_FEATURE),
    ;                            wValue=0 (ENDPOINT_HALT) → 0x00000102
    ; Setup packet (high dword): wIndex=ep_addr (e.g. 0x81), wLength=0
    mov r8d, 0x00000102
    movzx r9d, byte [usb_ep_addr]
    call usb_control_transfer_nodata
    ; Non-fatal: device may have already recovered; the xHCI Reset Endpoint
    ; above is what un-halts the controller-side state machine.

    ; --- 3. Reset the slot1 interrupt transfer ring ---
    mov rdi, XHCI_INT_RING_ADDR
    mov ecx, XHCI_RING_SIZE * XHCI_TRB_SIZE / 8
    xor rax, rax
    rep stosq
    mov dword [xhci_int_enqueue], 0
    mov byte [xhci_int_cycle], 1

    ; --- 4. Set TR Dequeue Pointer command ---
    ; DW0 = ring_addr_lo | DCS=1 (next TRB has cycle 1 → matches xhci_int_cycle)
    ; DW1 = ring_addr_hi (0 - ring lives below 4G)
    ; DW2 = StreamID:0 / SCT:0 (mouse EP isn't streaming)
    ; DW3 = TRB_SET_TR_DEQUEUE | (SlotID << 24) | (EpID << 16)
    mov r8d, XHCI_INT_RING_ADDR
    or r8d, 1                              ; DCS = 1
    xor r9d, r9d
    xor r10d, r10d
    movzx eax, byte [xhci_slot_id]
    shl eax, 24
    movzx edx, byte [xhci_int_ep_dci]
    shl edx, 16
    or eax, edx
    or eax, TRB_SET_TR_DEQUEUE
    mov r11d, eax
    call xhci_submit_cmd
    cmp eax, 1
    jne .rs_fail

    ; --- 5. Re-prime the interrupt ring ---
    call usb_queue_mouse_read
    call usb_queue_mouse_read

    inc dword [usb_dbg_stall_recov]
    mov eax, 1
    jmp .rs_ret
.rs_fail:
    xor eax, eax
.rs_ret:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; usb_queue_mouse_read - Queue an interrupt transfer
; ============================================================================
usb_queue_mouse_read:
    ; Slot1 can be polled after slot2/NIC code has changed the shared xHCI
    ; globals. Always restore the saved slot1 context before queueing/ringing.
    cmp byte [usb_slot1_id], 0
    je .slot1_context_ready
    mov al, [usb_slot1_id]
    mov [xhci_slot_id], al
    mov al, [usb_int_ep1_dci]
    mov [xhci_int_ep_dci], al
.slot1_context_ready:
    ; Normal TRB for data transfer
    ; DWord 0, 1: Buffer Address
    mov r8d, XHCI_MOUSE_BUF_ADDR
    xor r9d, r9d

    ; DWord 2: Length (Transfer Length)
    movzx r10d, word [usb_ep_mps]
    ; Fail-closed clamp on the controller DMA length: cap at the buffer slack so
    ; an over-large mps can never DMA past XHCI_MOUSE_BUF_ADDR's region.
    cmp r10d, XHCI_HID_REPORT_MAX
    jbe .q1_len_ok
    mov r10d, XHCI_HID_REPORT_MAX
.q1_len_ok:
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
    cmp r10d, XHCI_HID_REPORT_MAX
    jbe .q2_len_ok
    mov r10d, XHCI_HID_REPORT_MAX
.q2_len_ok:
    mov r11d, TRB_NORMAL | TRB_IOC | (1 << 2)
    call xhci_queue_int_trb2
    movzx edi, byte [usb_slot2_id]
    movzx esi, byte [usb_int_ep2_dci]
    call xhci_ring_doorbell
    ret
