; ============================================================================
; xhci_setup_scratchpad - Allocate scratchpad buffers if needed
; ============================================================================
xhci_setup_scratchpad:
    push rcx
    push rdi

    movzx ecx, word [xhci_scratchpad_count]
    test ecx, ecx
    jz .scratch_done              ; No scratchpads needed

    ; XHCI region 0x1740000..0x17F0000 = 0xB0000 (720 KB). First page holds
    ; the pointer array (max 512 entries fits in 4 KB); buffers start at
    ; +0x1000. That leaves 0xAF000/0x1000 = 175 4K-buffer slots. Cap at 64
    ; - way above what any real controller asks for (typical: 8-32) and
    ; far enough below the limit to be safe. Real AMD FCH/Promontory
    ; report >4 here, and silently dropping them gives undefined DMA
    ; targets on first device address - a likely "QEMU works, HW fails"
    ; failure mode.
    cmp ecx, 128
    jle .scratch_ok
    mov ecx, 128
.scratch_ok:

    ; Scratchpad array at XHCI_SCRATCH_ADDR
    ; Buffers at XHCI_SCRATCH_ADDR + 0x1000, +0x2000, etc.
    mov rdi, XHCI_SCRATCH_ADDR
    xor edx, edx
.scratch_loop:
    cmp edx, ecx
    jge .scratch_set_dcbaa
    ; Buffer address = XHCI_SCRATCH_ADDR + 0x1000 * (edx + 1)
    mov eax, edx
    inc eax
    shl eax, 12                   ; * 4096
    add eax, XHCI_SCRATCH_ADDR
    mov [rdi + rdx * 8], rax      ; Write 64-bit pointer to array
    inc edx
    jmp .scratch_loop

.scratch_set_dcbaa:
    ; DCBAA[0] = scratchpad array pointer
    mov rdi, XHCI_DCBAA_ADDR
    mov qword [rdi], XHCI_SCRATCH_ADDR

.scratch_done:
    pop rdi
    pop rcx
    ret

; ============================================================================
; xhci_setup_dcbaa - Setup Device Context Base Address Array
; ============================================================================
xhci_setup_dcbaa:
    ; DCBAA already zeroed. Scratchpad pointer set if needed.
    ; Slot 1 device context will be set during address_device.
    ret

; ============================================================================
; xhci_setup_cmd_ring - Initialize Command Ring
; ============================================================================
xhci_setup_cmd_ring:
    push rdi

    ; Command Ring at XHCI_CMD_RING_ADDR, already zeroed
    ; Set last TRB as Link TRB pointing back to start
    mov rdi, XHCI_CMD_RING_ADDR
    ; Link TRB at entry 255 (offset 255 * 16)
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    ; DWord 0-1: Ring Segment Pointer (64-bit) = start of ring
    mov qword [rax], XHCI_CMD_RING_ADDR
    ; DWord 2: 0 (Interrupter Target)
    mov dword [rax + 8], 0
    ; DWord 3: Type=Link (6), TC=1 (Toggle Cycle), Cycle=1
    mov dword [rax + 12], TRB_LINK | TRB_TC | TRB_CYCLE

    ; Initialize cmd ring state
    mov dword [xhci_cmd_enqueue], 0
    mov byte [xhci_cmd_cycle], 1

    pop rdi
    ret

; ============================================================================
; xhci_setup_event_ring - Initialize Event Ring and ERST
; ============================================================================
xhci_setup_event_ring:
    push rsi

    ; ERST entry 0: base = event ring address, size = 256
    mov rdi, XHCI_ERST_ADDR
    mov qword [rdi + 0], XHCI_EVT_RING_ADDR    ; Ring Segment Base Address
    mov dword [rdi + 8], XHCI_RING_SIZE         ; Ring Segment Size
    mov dword [rdi + 12], 0                      ; Reserved

    ; Initialize event ring state
    mov dword [xhci_evt_dequeue], 0
    mov byte [xhci_evt_cycle], 1

    ; Program Runtime Registers for Interrupter 0
    mov rsi, [xhci_rt_base]
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW

    ; ERSTSZ = 1
    mov dword [rsi + XHCI_RT_IR0_ERSTSZ], 1

    ; ERDP = event ring start
    mov dword [rsi + XHCI_RT_IR0_ERDP_LO], XHCI_EVT_RING_ADDR
    mov dword [rsi + XHCI_RT_IR0_ERDP_HI], 0

    ; ERSTBA = ERST address (must be written AFTER ERSTSZ)
    mov dword [rsi + XHCI_RT_IR0_ERSTBA_LO], XHCI_ERST_ADDR
    mov dword [rsi + XHCI_RT_IR0_ERSTBA_HI], 0

    pop rsi
    ret

; ============================================================================
; xhci_submit_cmd - Submit a TRB to command ring and wait for completion
; Input: R8 = dword0, R9 = dword1, R10 = dword2, R11 = dword3 (type|flags, no cycle)
; Returns: EAX = completion code (1=success), 0 on timeout
;          RBX = completion TRB dword3 (contains slot ID etc)
; ============================================================================
global xhci_submit_cmd
xhci_submit_cmd:
    ; NOTE: RBX is a return value (DWord3 of completion event) - do NOT save/restore it
    push rcx
    push rdx
    push rsi
    push rdi

    ; Get enqueue pointer
    mov edi, [xhci_cmd_enqueue]

    ; Check for Link TRB (entry 255)
    cmp edi, XHCI_RING_SIZE - 1
    jl .no_wrap

    ; We hit the Link TRB - toggle cycle and wrap
    
    ; Debug: 'C'
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, 'C'
    out dx, al
    pop rdx
    pop rax
    
    ; Update Link TRB cycle bit
    mov rsi, XHCI_CMD_RING_ADDR
    lea rax, [rsi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov ecx, [rax + 12]
    ; Set/clear cycle bit based on current cmd_cycle
    and ecx, ~1                   ; Clear cycle
    movzx edx, byte [xhci_cmd_cycle]
    or ecx, edx
    mov [rax + 12], ecx

    ; Toggle cycle
    xor byte [xhci_cmd_cycle], 1
    mov dword [xhci_cmd_enqueue], 0
    xor edi, edi

.no_wrap:
    ; Write TRB at enqueue position
    mov rsi, XHCI_CMD_RING_ADDR
    imul eax, edi, XHCI_TRB_SIZE
    add rsi, rax

    mov [rsi + 0], r8d            ; DWord 0
    mov [rsi + 4], r9d            ; DWord 1
    mov [rsi + 8], r10d           ; DWord 2
    ; DWord 3: OR in cycle bit
    mov eax, r11d
    movzx ecx, byte [xhci_cmd_cycle]
    or eax, ecx
    mov [rsi + 12], eax

    ; Advance enqueue
    inc edi
    mov [xhci_cmd_enqueue], edi

    ; Ring doorbell 0 (host controller command)
    mov rsi, [xhci_db_base]
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    mov dword [rsi], 0

    ; Serial: 'v' = doorbell rung
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, 'v'
    out dx, al
    pop rdx
    pop rax

    ; Poll event ring for Command Completion (PIT-based 2-second timeout + spin fallback)
    mov rax, [tick_count]
    add rax, 200                  ; 200 ticks = 2 seconds at 100Hz
    mov [xhci_cmd_deadline], rax  ; store deadline (not rbx - rbx is return value)
.poll:
    call xhci_poll_event
    test eax, eax
    jnz .got_event

    mov rax, [tick_count]
    cmp rax, [xhci_cmd_deadline]
    jl .poll

    ; PIT timeout
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, 'Z'
    out dx, al
    pop rdx
    pop rax
    jmp .cmd_fail

.cmd_fail:
    ; Timeout
    xor eax, eax
    jmp .cmd_ret

.got_event:
    ; EAX = completion code, EBX = dword3
    ; Check TRB type in dword3 - should be CMD_COMPLETION
    mov ecx, ebx
    and ecx, (0x3F << 10)         ; Type mask
    cmp ecx, TRB_CMD_COMPLETION
    jne .poll                     ; Not our event, keep polling

    ; Serial: print completion code digit
    push rax
    push rdx
    mov dx, 0x3F8
    push rax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jle .cc_ok
    add al, 7
.cc_ok:
    out dx, al
    pop rax
    pop rdx
    pop rax

    ; Return completion code
    ; (already in EAX from xhci_poll_event)

.cmd_ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ; NOTE: rbx is NOT restored - it holds the return value (DWord3 of completion event)
    ret

; ============================================================================
; xhci_poll_event - Check event ring for one event
; Returns: EAX = completion code (0 if no event), EBX = dword3, ECX = dword0
; ============================================================================
global xhci_poll_event
xhci_poll_event:
    push rsi
    push rdi

    ; Serialize access to the event ring. GRIT_ENABLE_RING3_AP can have CPU0
    ; in rtl8156_rx_once polling for a DHCP OFFER while CPU N is in
    ; usb_poll_mouse polling for HID reports - both call this function and
    ; race on xhci_evt_dequeue. Without this lock, one CPU reads a TRB whose
    ; cycle bit was JUST flipped by the other's dequeue advance, treats the
    ; old contents as a fresh event, and dispatches off a stale slot/type →
    ; observed as RIP=0 page fault during DHCP+mouse contention.
.evt_lock_acquire:
    mov eax, 1
    xchg eax, [rel xhci_evt_lock]
    test eax, eax
    jnz .evt_lock_spin
    jmp .evt_have_lock
.evt_lock_spin:
    pause
    cmp dword [rel xhci_evt_lock], 0
    jne .evt_lock_spin
    jmp .evt_lock_acquire
.evt_have_lock:

    mov edi, [xhci_evt_dequeue]
    mov rsi, XHCI_EVT_RING_ADDR
    imul eax, edi, XHCI_TRB_SIZE
    add rsi, rax

    ; Check cycle bit
    mov eax, [rsi + 12]
    mov ebx, eax
    and eax, 1                    ; Cycle bit of TRB
    movzx ecx, byte [xhci_evt_cycle]
    cmp eax, ecx
    jne .no_event                 ; Cycle doesn't match, no new event

    ; We have an event!
    mov ecx, [rsi + 0]            ; DWord 0 (TRB pointer low or slot-specific)
    mov ebx, [rsi + 12]           ; DWord 3 (type, slot ID, etc.)

    ; Completion code from DWord 2, bits 31:24
    mov eax, [rsi + 8]
    shr eax, 24                   ; Completion code

    ; Advance dequeue
    inc edi
    cmp edi, XHCI_RING_SIZE
    jl .no_evt_wrap
    xor edi, edi
    xor byte [xhci_evt_cycle], 1  ; Toggle cycle on wrap
    
    ; Debug: 'W' (Event Wrap)
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, 'W'
    out dx, al
    pop rdx
    pop rax

.no_evt_wrap:
    mov [xhci_evt_dequeue], edi

    ; Update ERDP
    push rax
    push rbx
    mov rsi, [xhci_rt_base]
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    ; ERDP = address of next TRB to process
    mov eax, edi
    shl eax, 4                    ; * 16
    add eax, XHCI_EVT_RING_ADDR
    or eax, (1 << 3)             ; EHB (Event Handler Busy) clear
    mov [rsi + XHCI_RT_IR0_ERDP_LO], eax
    mov dword [rsi + XHCI_RT_IR0_ERDP_HI], 0
    pop rbx
    pop rax

    jmp .evt_ret

.no_event:
    xor eax, eax
    xor ebx, ebx
    xor ecx, ecx

.evt_ret:
    mov dword [rel xhci_evt_lock], 0   ; release
    pop rdi
    pop rsi
    ret

; ============================================================================
; xhci_find_port - Find first port with a connected device
; Returns: EAX = 1 if found, 0 if not. Port number stored in xhci_port_num
; ============================================================================
global xhci_find_port