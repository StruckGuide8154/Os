xhci_enable_slot:
    ; Submit Enable Slot TRB
    xor r8d, r8d                  ; DWord 0
    xor r9d, r9d                  ; DWord 1
    xor r10d, r10d                ; DWord 2
    mov r11d, TRB_ENABLE_SLOT     ; DWord 3: type=Enable Slot
    call xhci_submit_cmd

    ; Check completion code
    cmp eax, 1                    ; 1 = Success
    jne .slot_fail

    ; Slot ID in bits 31:24 of completion DWord3.
    ; SECURITY: this slot id is supplied by the controller's Enable-Slot
    ; completion event (device-controlled). It is used directly as an index into
    ; the DCBAA ([XHCI_DCBAA_ADDR + id*8], xhci_address_device/disable_slot) and
    ; the doorbell array ([xhci_db_base + id*4], xhci_ring_doorbell). MaxSlotsEn is
    ; programmed to at most XHCI_MAX_SLOT_ID, so a conforming controller only ever
    ; returns id in 1..XHCI_MAX_SLOT_ID; anything outside that is a malformed or
    ; hostile response. Reject fail-closed rather than trust it as an array index.
    ; The validated value is the exact byte stored in xhci_slot_id and reused at
    ; every downstream site (held in the global, never re-derived) => TOCTOU-free.
    mov eax, ebx
    shr eax, 24
    and eax, 0xFF
    test eax, eax
    jz .slot_fail                 ; id 0 is reserved for the host-controller doorbell
    cmp eax, XHCI_MAX_SLOT_ID
    ja .slot_fail                 ; out of programmed slot range -> drop
    mov [xhci_slot_id], al
    ret

.slot_fail:
    xor eax, eax
    ret

; ============================================================================
; xhci_disable_slot - Disable a previously enabled slot (release port binding)
; AL = slot ID. Returns: EAX = 1 on success, 0 on failure.
; ============================================================================
global xhci_disable_slot
xhci_disable_slot:
    push rcx
    push rdi
    push r12
    movzx ecx, al
    test ecx, ecx
    jz .ds_fail
    ; SECURITY (defence in depth): AL is the caller-supplied slot id used to clear
    ; the DCBAA entry below ([XHCI_DCBAA_ADDR + id*8]). Bound it to the same valid
    ; range as enable so a stray/oversized id cannot write outside the array.
    cmp ecx, XHCI_MAX_SLOT_ID
    ja .ds_fail
    mov r12d, ecx
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    shl ecx, 24
    or  ecx, TRB_DISABLE_SLOT
    mov r11d, ecx
    call xhci_submit_cmd
    cmp eax, 1
    jne .ds_fail
    ; Clear DCBAA entry for the slot so a future Enable Slot can reuse it
    ; cleanly without the controller seeing a stale device context pointer.
    mov rdi, XHCI_DCBAA_ADDR
    mov qword [rdi + r12 * 8], 0
    mov eax, 1
    jmp .ds_ret
.ds_fail:
    xor eax, eax
.ds_ret:
    pop r12
    pop rdi
    pop rcx
    ret

; ============================================================================
; xhci_address_device - Setup contexts and address device
; Returns: EAX = 1 on success, 0 on failure
; ============================================================================
global xhci_address_device
xhci_address_device:
    push rsi
    push rdi
    push rcx

    mov byte [xhci_dbg_adstage], 30  ; entered

    movzx eax, byte [xhci_ctx_size]
    mov [xhci_ctx_stride], eax    ; 32 or 64

    ; --- Setup Input Context at XHCI_INPUT_CTX_ADDR ---
    mov rdi, XHCI_INPUT_CTX_ADDR

    ; FIX: zero entire Input Context (control + slot + ep0) before writing
    ; fields. Prevents stale Drop Context Flags or stale EP fields from a
    ; previous slot/retry causing the controller to drop random contexts.
    push rdi
    push rcx
    push rax
    mov ecx, 32                   ; 32 qwords = 256 bytes (covers CSZ=64 + slot + EP0)
    xor eax, eax
    rep stosq
    pop rax
    pop rcx
    pop rdi

    mov byte [xhci_dbg_adstage], 31  ; input context zeroed

    ; Input Control Context (first context entry)
    ; DWord 1: Add Context Flags - A0=1 (Slot), A1=1 (EP0)
    movzx ecx, byte [xhci_ctx_stride]
    mov dword [rdi + 4], 0x03     ; A0 | A1

    ; --- Slot Context (context entry 1) ---
    lea rsi, [rdi + rcx]          ; Skip Input Control Context by ctx_stride

    ; DWord 0: Route String(19:0)=0, Speed(23:20), Context Entries(31:27)=1
    movzx eax, byte [xhci_port_speed]
    shl eax, 20                   ; Speed field
    or eax, (1 << 27)             ; Context Entries = 1 (only EP0)
    mov [rsi + 0], eax

    ; DWord 1: Root Hub Port Number (23:16)
    movzx eax, byte [xhci_port_num]
    shl eax, 16
    mov [rsi + 4], eax

    ; DWord 2-3: 0
    mov dword [rsi + 8], 0
    mov dword [rsi + 12], 0

    ; --- Endpoint 0 Context (context entry 2) ---
    lea rsi, [rsi + rcx]          ; Next context entry

    ; DWord 0: EP State = 0
    mov dword [rsi + 0], 0

    ; DWord 1: Max Packet Size, EP Type = Control Bidirectional (4), CErr=3
    ; Max Packet Size depends on speed:
    ;   Low Speed = 8, Full Speed = 64, High Speed = 64, Super Speed = 512
    movzx eax, byte [xhci_port_speed]
    cmp al, XHCI_SPEED_LOW
    je .mps_8
    cmp al, XHCI_SPEED_SUPER
    je .mps_512
    ; Full/High speed
    mov ecx, 64
    jmp .mps_set
.mps_8:
    mov ecx, 8
    jmp .mps_set
.mps_512:
    mov ecx, 512
.mps_set:
    mov [xhci_ep0_mps], cx

    ; DWord 1: CErr(2:1)=3, EP Type(5:3)=4(Control), MaxPacketSize(31:16)
    mov eax, (3 << 1)             ; CErr = 3
    or eax, (XHCI_EP_CONTROL << 3)  ; EP Type = Control
    shl ecx, 16
    or eax, ecx                   ; Max Packet Size
    mov [rsi + 4], eax

    ; DWord 2-3: TR Dequeue Pointer (64-bit) with DCS=1
    cmp byte [xhci_nic_mode], 1
    je .ep0_ring_nic
    cmp byte [xhci_slot2_mode], 1
    je .ep0_ring2
    mov dword [rsi + 8], XHCI_CTRL_RING_ADDR | 1
    jmp .ep0_ring_done
.ep0_ring2:
    mov dword [rsi + 8], XHCI_CTRL_RING2_ADDR | 1
    jmp .ep0_ring_done
.ep0_ring_nic:
    mov dword [rsi + 8], RTL8156_XHCI_CTRL_RING_ADDR | 1
.ep0_ring_done:
    mov dword [rsi + 12], 0

    ; DWord 4: Average TRB Length = 8 (for control)
    mov dword [rsi + 16], 8

    ; --- Set DCBAA entry for this slot ---
    movzx eax, byte [xhci_slot_id]
    mov rdi, XHCI_DCBAA_ADDR
    cmp byte [xhci_nic_mode], 1
    je .dcbaa_nic
    cmp byte [xhci_slot2_mode], 1
    je .dcbaa_slot2
    mov qword [rdi + rax * 8], XHCI_DEV_CTX_ADDR
    jmp .dcbaa_done
.dcbaa_slot2:
    mov qword [rdi + rax * 8], XHCI_DEV_CTX2_ADDR
    jmp .dcbaa_done
.dcbaa_nic:
    mov qword [rdi + rax * 8], RTL8156_XHCI_DEV_CTX_ADDR
.dcbaa_done:

    ; --- Init EP0 transfer ring (slot-specific) ---
    cmp byte [xhci_nic_mode], 1
    je .addr_ring_nic
    cmp byte [xhci_slot2_mode], 1
    je .addr_ring2
    mov rdi, XHCI_CTRL_RING_ADDR
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], XHCI_CTRL_RING_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC | TRB_CYCLE
    ; Zero the active area so stale slot1 TRBs don't pollute future slot reuse
    push rdi
    push rcx
    xor eax, eax
    mov ecx, (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE / 4
    rep stosd
    pop rcx
    pop rdi
    ; Restore link TRB (zeroed by rep stosd)
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], XHCI_CTRL_RING_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC | TRB_CYCLE
    mov dword [xhci_ctrl_enqueue], 0
    mov byte [xhci_ctrl_cycle], 1
    ; Also fix EP0 context to use correct ring
    ; (was written above in input context as CTRL_RING_ADDR)
    jmp .addr_ring_done
.addr_ring2:
    mov rdi, XHCI_CTRL_RING2_ADDR
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], XHCI_CTRL_RING2_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC | TRB_CYCLE
    mov dword [xhci_ctrl_enqueue], 0
    mov byte [xhci_ctrl_cycle], 1
    jmp .addr_ring_done
.addr_ring_nic:
    mov rdi, RTL8156_XHCI_CTRL_RING_ADDR
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], RTL8156_XHCI_CTRL_RING_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC | TRB_CYCLE
    mov dword [xhci_ctrl_enqueue], 0
    mov byte [xhci_ctrl_cycle], 1
.addr_ring_done:

    ; --- Submit Address Device (BSR=1 first) ---
    mov r8d, XHCI_INPUT_CTX_ADDR ; DWord 0: Input Context Pointer low
    xor r9d, r9d                  ; DWord 1: Input Context Pointer high
    xor r10d, r10d                ; DWord 2: 0
    movzx eax, byte [xhci_slot_id]
    shl eax, 24                   ; Slot ID in bits 31:24
    or eax, TRB_ADDRESS_DEV       ; Type
    or eax, TRB_BSR               ; Block Set Address Request
    mov r11d, eax
    mov byte [xhci_dbg_addrn], 1
    mov byte [xhci_dbg_adstage], 32   ; about to submit BSR=1

    ; Capture PORTSC just before address (debug)
    call xhci_capture_portsc_dbg

    call xhci_submit_cmd
    mov [xhci_dbg_addrcc], al
    mov [xhci_dbg_adcc1], al      ; BSR=1 completion code
    mov byte [xhci_dbg_adstage], 33   ; BSR=1 returned
    cmp eax, 1
    jne .addr_fail

    ; DEBUG: After BSR=1 the controller writes Slot State into the device
    ; context (slot context at offset 0). Read DWord3 bits 31:27.
    ; Expected: 1=Default, 2=Addressed (after BSR=0), 3=Configured.
    push rax
    push rdi
    mov rdi, XHCI_DEV_CTX_ADDR
    cmp byte [xhci_nic_mode], 1
    jne .ss_check_slot2
    mov rdi, RTL8156_XHCI_DEV_CTX_ADDR
    jmp .ss_use_ctx1
.ss_check_slot2:
    cmp byte [xhci_slot2_mode], 1
    jne .ss_use_ctx1
    mov rdi, XHCI_DEV_CTX2_ADDR
.ss_use_ctx1:
    mov eax, [rdi + 12]                ; DWord 3 of Slot Context
    shr eax, 27
    and eax, 0x1F
    mov [xhci_dbg_slotstate], al
    pop rdi
    pop rax

    ; --- Submit Address Device (BSR=0) ---
    mov r8d, XHCI_INPUT_CTX_ADDR
    xor r9d, r9d
    xor r10d, r10d
    movzx eax, byte [xhci_slot_id]
    shl eax, 24
    or eax, TRB_ADDRESS_DEV       ; No BSR this time
    mov r11d, eax
    mov byte [xhci_dbg_addrn], 2
    mov byte [xhci_dbg_adstage], 34   ; about to submit BSR=0

    ; Capture PORTSC again (may have changed between calls)
    call xhci_capture_portsc_dbg

    call xhci_submit_cmd
    mov [xhci_dbg_addrcc], al
    mov [xhci_dbg_adcc2], al      ; BSR=0 completion code
    mov byte [xhci_dbg_adstage], 35   ; BSR=0 returned
    cmp eax, 1
    jne .addr_fail
    mov byte [xhci_dbg_adstage], 36   ; success

    mov eax, 1
    jmp .addr_ret

.addr_fail:
    xor eax, eax
.addr_ret:
    pop rcx
    pop rdi
    pop rsi
    ret

; ============================================================================
; xhci_capture_portsc_dbg - Read PORTSC for the active port into debug field
; Clobbers eax, rdi, rsi
; ============================================================================
xhci_capture_portsc_dbg:
    push rax
    push rsi
    push rdi
    movzx eax, byte [xhci_port_num]
    test eax, eax
    jz .pc_done                   ; no port selected yet
    dec eax                        ; PORTSC array is 0-indexed
    shl eax, 4                     ; *16 bytes per port
    mov rsi, [xhci_op_base]
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400
    add rsi, rax
    mov eax, [rsi]                 ; PORTSC
    mov [xhci_dbg_portsc], eax
.pc_done:
    pop rdi
    pop rsi
    pop rax
    ret

; ============================================================================
; xhci_ring_doorbell - Ring a doorbell register
; EDI = slot ID (0 = host controller), ESI = target (EP index or 0)
; ============================================================================
global xhci_ring_doorbell