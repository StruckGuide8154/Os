xhci_ring_doorbell:
    push rax
    mov rax, [xhci_db_base]
    XHCI_MMIO_ASSERT rax, MMIO_XHCI_WINDOW
    mov [rax + rdi * 4], esi
    pop rax
    ret

; ============================================================================
; xhci_queue_ctrl_trb - Queue one TRB on EP0 control transfer ring
; R8=dw0, R9=dw1, R10=dw2, R11=dw3 (no cycle bit)
; ============================================================================
global xhci_queue_ctrl_trb
xhci_queue_ctrl_trb:
    push rsi
    push rdi
    push rax
    push rcx

    mov edi, [xhci_ctrl_enqueue]

    ; Check for Link TRB
    cmp edi, XHCI_RING_SIZE - 1
    jl .ctrl_no_wrap

    ; Update Link TRB cycle bit (slot-specific ring)
    cmp byte [xhci_nic_mode], 1
    je .ctrl_wrap_nic
    cmp byte [xhci_slot2_mode], 1
    je .ctrl_wrap2
    mov rsi, XHCI_CTRL_RING_ADDR
    jmp .ctrl_wrap_go
.ctrl_wrap2:
    mov rsi, XHCI_CTRL_RING2_ADDR
    jmp .ctrl_wrap_go
.ctrl_wrap_nic:
    mov rsi, RTL8156_XHCI_CTRL_RING_ADDR
.ctrl_wrap_go:
    lea rax, [rsi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov ecx, [rax + 12]
    and ecx, ~1
    movzx edx, byte [xhci_ctrl_cycle]
    or ecx, edx
    mov [rax + 12], ecx

    xor byte [xhci_ctrl_cycle], 1
    mov dword [xhci_ctrl_enqueue], 0
    xor edi, edi

.ctrl_no_wrap:
    cmp byte [xhci_nic_mode], 1
    je .ctrl_ring_nic
    cmp byte [xhci_slot2_mode], 1
    je .ctrl_ring2
    mov rsi, XHCI_CTRL_RING_ADDR
    jmp .ctrl_ring_go
.ctrl_ring2:
    mov rsi, XHCI_CTRL_RING2_ADDR
    jmp .ctrl_ring_go
.ctrl_ring_nic:
    mov rsi, RTL8156_XHCI_CTRL_RING_ADDR
.ctrl_ring_go:
    imul eax, edi, XHCI_TRB_SIZE
    add rsi, rax

    mov [rsi + 0], r8d
    mov [rsi + 4], r9d
    mov [rsi + 8], r10d
    ; OR in cycle bit
    mov eax, r11d
    movzx ecx, byte [xhci_ctrl_cycle]
    or eax, ecx
    mov [rsi + 12], eax

    inc edi
    mov [xhci_ctrl_enqueue], edi

    pop rcx
    pop rax
    pop rdi
    pop rsi
    ret

; ============================================================================
; xhci_queue_int_trb - Queue one TRB on interrupt IN transfer ring
; R8=dw0, R9=dw1, R10=dw2, R11=dw3 (no cycle bit)
; ============================================================================
global xhci_queue_int_trb
xhci_queue_int_trb:
    push rsi
    push rdi
    push rax
    push rcx

    mov edi, [xhci_int_enqueue]

    cmp edi, XHCI_RING_SIZE - 1
    jl .int_no_wrap

    mov rsi, XHCI_INT_RING_ADDR
    lea rax, [rsi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov ecx, [rax + 12]
    and ecx, ~1
    movzx edx, byte [xhci_int_cycle]
    or ecx, edx
    mov [rax + 12], ecx

    xor byte [xhci_int_cycle], 1
    mov dword [xhci_int_enqueue], 0
    xor edi, edi

    ; Debug: 'w' (Int Wrap)
    SER 'w'

.int_no_wrap:
    mov rsi, XHCI_INT_RING_ADDR
    imul eax, edi, XHCI_TRB_SIZE
    add rsi, rax

    mov [rsi + 0], r8d
    mov [rsi + 4], r9d
    mov [rsi + 8], r10d
    mov eax, r11d
    movzx ecx, byte [xhci_int_cycle]
    or eax, ecx
    mov [rsi + 12], eax

    inc edi
    mov [xhci_int_enqueue], edi

    pop rcx
    pop rax
    pop rdi
    pop rsi
    ret

; ============================================================================
; xhci_queue_int_trb2 - Queue one TRB on slot 2 interrupt IN transfer ring
; R8=dw0, R9=dw1, R10=dw2, R11=dw3 (no cycle bit)
; ============================================================================
global xhci_queue_int_trb2
xhci_queue_int_trb2:
    push rsi
    push rdi
    push rax
    push rcx

    mov edi, [xhci_int_enqueue2]

    cmp edi, XHCI_RING_SIZE - 1
    jl .int2_no_wrap

    mov rsi, XHCI_INT_RING2_ADDR
    lea rax, [rsi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov ecx, [rax + 12]
    and ecx, ~1
    movzx edx, byte [xhci_int_cycle2]
    or ecx, edx
    mov [rax + 12], ecx

    xor byte [xhci_int_cycle2], 1
    mov dword [xhci_int_enqueue2], 0
    xor edi, edi

.int2_no_wrap:
    mov rsi, XHCI_INT_RING2_ADDR
    imul eax, edi, XHCI_TRB_SIZE
    add rsi, rax

    mov [rsi + 0], r8d
    mov [rsi + 4], r9d
    mov [rsi + 8], r10d
    mov eax, r11d
    movzx ecx, byte [xhci_int_cycle2]
    or eax, ecx
    mov [rsi + 12], eax

    inc edi
    mov [xhci_int_enqueue2], edi

    pop rcx
    pop rax
    pop rdi
    pop rsi
    ret

; ============================================================================
; xhci_configure_endpoint - Add interrupt IN endpoint to device
; EDI = endpoint number (1-15), ESI = max packet size, EDX = interval
; Returns: EAX = 1 on success
; ============================================================================
global xhci_configure_endpoint
xhci_configure_endpoint:
    push rbx
    push rcx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14

    ; Save args
    mov r12d, edi                 ; EP number
    mov r13d, esi                 ; Max packet size
    mov r14d, edx                 ; Interval

    ; EP DCI (Device Context Index) for IN endpoint = EP_num * 2 + 1
    mov eax, r12d
    shl eax, 1
    inc eax
    mov [xhci_int_ep_dci], al

    ; --- Build Input Context ---
    mov rdi, XHCI_INPUT_CTX_ADDR
    ; Zero it first
    push rdi
    mov rcx, 4096 / 8
    xor rax, rax
    rep stosq
    pop rdi

    movzx ecx, byte [xhci_ctx_stride]

    ; Input Control Context
    ; Add Context Flags: A0 (slot) and endpoint DCI bit
    movzx eax, byte [xhci_int_ep_dci]
    mov ebx, 1
    shl ebx, cl                   ; Wrong - should use eax not ecx
    ; Actually: flag bit = (1 << DCI)
    mov ecx, eax
    mov ebx, 1
    shl ebx, cl                   ; BIT for this endpoint
    or ebx, 1                     ; A0 (slot context)
    mov [rdi + 4], ebx            ; Add Context Flags

    movzx ecx, byte [xhci_ctx_stride]

    ; Slot Context (entry 1) - copy from output context
    lea rsi, [rdi + rcx]          ; Input Slot Context
    cmp byte [xhci_slot2_mode], 1
    je .cfg_ctx2
    mov rbx, XHCI_DEV_CTX_ADDR
    jmp .cfg_ctx_done
.cfg_ctx2:
    mov rbx, XHCI_DEV_CTX2_ADDR
.cfg_ctx_done:                    ; Output context
    ; Copy slot context
    push rcx
    mov ecx, [rbx + 0]
    ; Update Context Entries to include new endpoint
    and ecx, ~(0x1F << 27)       ; Clear Context Entries
    movzx eax, byte [xhci_int_ep_dci]
    shl eax, 27
    or ecx, eax                   ; Set to DCI value
    mov [rsi + 0], ecx
    mov ecx, [rbx + 4]
    mov [rsi + 4], ecx
    mov ecx, [rbx + 8]
    mov [rsi + 8], ecx
    mov ecx, [rbx + 12]
    mov [rsi + 12], ecx
    pop rcx

    ; Endpoint Context (entry at DCI)
    movzx eax, byte [xhci_int_ep_dci]
    imul eax, ecx                 ; Offset = DCI * ctx_stride
    lea rsi, [rdi + rax]          ; Base of slot
    add rsi, rcx                  ; Add Input Control Context offset (ctx_stride)

    ; Wait, Input Context layout:
    ; [Input Control Context] [Slot Context] [EP0 Context] [EP1 IN Context] ...
    ; Offset = (DCI + 1) * ctx_stride (because entry 0 = Input Control)
    movzx eax, byte [xhci_int_ep_dci]
    inc eax                       ; +1 for Input Control Context
    imul eax, ecx
    lea rsi, [rdi + rax]

    ; DWord 0: Interval (bits 23:16). Use 6 (8ms) as a robust default for HID mice.
    mov eax, (6 << 16)
    mov dword [rsi + 0], eax

    ; DWord 1: CErr=3, EP Type=Interrupt IN(7), Max Packet Size
    mov eax, (3 << 1)             ; CErr = 3
    or eax, (XHCI_EP_INT_IN << 3) ; EP Type = 7
    mov ecx, r13d                 ; Max Packet Size
    shl ecx, 16
    or eax, ecx
    mov [rsi + 4], eax

    ; DWord 2-3: TR Dequeue Pointer with DCS=1
    cmp byte [xhci_slot2_mode], 1
    je .cfg_intring2
    mov dword [rsi + 8], XHCI_INT_RING_ADDR | 1
    jmp .cfg_intring_done
.cfg_intring2:
    mov dword [rsi + 8], XHCI_INT_RING2_ADDR | 1
.cfg_intring_done:
    mov dword [rsi + 12], 0

    ; DWord 4: Average TRB Length = 8 (mouse packets are small)
    ; Max ESIT Payload (bits 31:16) = max packet size
    mov eax, 8
    mov ecx, r13d                 ; Max Packet Size
    shl ecx, 16
    or eax, ecx
    mov [rsi + 16], eax

    ; --- Init interrupt transfer ring ---
    cmp byte [xhci_slot2_mode], 1
    je .cfg_ring2_init
    mov rdi, XHCI_INT_RING_ADDR
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], XHCI_INT_RING_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC
    mov dword [xhci_int_enqueue], 0
    mov byte [xhci_int_cycle], 1
    jmp .cfg_ring_init_done
.cfg_ring2_init:
    mov rdi, XHCI_INT_RING2_ADDR
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], XHCI_INT_RING2_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC
    mov dword [xhci_int_enqueue2], 0
    mov byte [xhci_int_cycle2], 1
.cfg_ring_init_done:

    ; --- Submit Configure Endpoint command ---
    mov r8d, XHCI_INPUT_CTX_ADDR
    xor r9d, r9d
    xor r10d, r10d
    movzx eax, byte [xhci_slot_id]
    shl eax, 24
    or eax, TRB_CONFIG_EP
    mov r11d, eax
    call xhci_submit_cmd
    cmp eax, 1
    jne .cfg_fail

    mov eax, 1
    jmp .cfg_ret

.cfg_fail:
    xor eax, eax
.cfg_ret:
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; ============================================================================
; xhci_flush_events - Consume and discard all pending events
; ============================================================================
global xhci_flush_events
xhci_flush_events:
    push rax
    push rbx
    push rcx
    push rdx
    ; BOUNDED drain. The legitimate number of pending events is at most the
    ; event-ring size (256). If xhci_poll_event keeps returning "event" past
    ; that - e.g. on real HW where a misprogrammed ERDP / cycle-bit mismatch
    ; makes every stale TRB look fresh - an uncapped loop would hang this AP
    ; forever (tick-independent). Cap at 4096 (16x the ring) so a runaway
    ; controller fails-soft instead of wedging the device-enum core.
    mov ecx, 4096
.flush_loop:
    call xhci_poll_event
    test eax, eax
    jz .flush_done   ; no more events
    dec ecx
    jnz .flush_loop  ; keep checking until no more events or budget exhausted
.flush_done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; serial_hex32 - Print EAX as 8 hex digits to COM1 (DX = 0x3F8 on entry)
; Clobbers: nothing (saves/restores all used regs)
; ============================================================================
serial_hex32:
%ifndef ENABLE_DEBUG_SERIAL
    ret                   ; release: no COM1 egress, inert leaf (all callers gated)
%else
    push rax
    push rbx
    push rcx
    push rdx
    mov ebx, eax          ; save value
    mov ecx, 8            ; 8 hex digits
.sh32_loop:
    rol ebx, 4            ; rotate high nibble to low
    mov al, bl
    and al, 0x0F
    cmp al, 10
    jl .sh32_digit
    add al, 'A' - 10
    jmp .sh32_out
.sh32_digit:
    add al, '0'
.sh32_out:
    mov dx, 0x3F8
    out dx, al
    dec ecx
    jnz .sh32_loop
    ; print space separator
    mov al, ' '
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
%endif
