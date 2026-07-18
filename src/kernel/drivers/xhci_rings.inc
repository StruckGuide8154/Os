; ============================================================================
; xhci_setup_scratchpad - Allocate scratchpad buffers if needed
; ============================================================================
xhci_setup_scratchpad:
    push rcx
    push rdi

    movzx ecx, word [xhci_scratchpad_count]
    test ecx, ecx
    jz .scratch_done              ; No scratchpads needed

    ; SECURITY: ecx is the controller-reported scratchpad count (HCSPARAMS2, an
    ; attacker-influenced value up to 0x3FF). The pointer array lives in the first
    ; page of the SCRATCH region (XHCI_SCRATCH_ADDR) and buffer i is placed at
    ; XHCI_SCRATCH_ADDR + 0x1000*(i+1). The SCRATCH region is exactly one 64 KiB
    ; window (XHCI_DEV_CTX_ADDR - XHCI_SCRATCH_ADDR = 0x10000), so only
    ; XHCI_SCRATCH_MAX (=15) 4 KiB buffers fit after the pointer page. The old cap
    ; (128) let a controller that reports many scratchpads be handed buffer
    ; pointers running to +0x80000 - well past DEV_CTX/INPUT_CTX/the rings - i.e.
    ; directing controller DMA on top of our own xHCI control structures. Clamp to
    ; XHCI_SCRATCH_MAX so every buffer stays inside the region (15 >= any real
    ; controller's request: typical 8-32 -> here bounded by the region, not 128).
    cmp ecx, XHCI_SCRATCH_MAX
    jle .scratch_ok
    mov ecx, XHCI_SCRATCH_MAX
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

    ; Interrupter 0: no moderation for now (the main loop batches event-ring
    ; drain work), clear any stale pending bit, and enable interrupt delivery.
    mov dword [rsi + XHCI_RT_IR0_IMOD], 0
    mov dword [rsi + XHCI_RT_IR0_IMAN], 3     ; IP W1C | IE

    pop rsi
    ret

; ============================================================================
; xhci_route_irq - Route firmware PCI INTx line to vector 51 when available.
; ============================================================================
global xhci_route_irq
xhci_route_irq:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi

    mov eax, [xhci_pci_addr]
    test eax, eax
    jz .route_done
    or eax, 0x3C
    call pci_read_conf_dword
    movzx edi, al                    ; Interrupt Line
    cmp edi, 0xFF
    je .route_done
    cmp edi, 0
    je .route_done
    mov esi, 51                      ; xHCI vector
    xor edx, edx                     ; BSP APIC id 0
    mov ecx, 0xA000                  ; PCI INTx: level-triggered, active-low
    call ioapic_set_irq

.route_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================================================
; xhci_irq_ack - Minimal ISR-side acknowledgement.
; The heavy event-ring drain stays in the main loop. This clears xHCI's pending
; interrupt latches so the level line can deassert before LAPIC EOI.
; ============================================================================
global xhci_irq_ack
xhci_irq_ack:
    push rax
    push rsi

    mov rsi, [xhci_rt_base]
    test rsi, rsi
    jz .ack_sts
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    mov eax, [rsi + XHCI_RT_IR0_IMAN]
    or eax, 3                        ; clear IP, keep IE set
    mov [rsi + XHCI_RT_IR0_IMAN], eax

.ack_sts:
    mov rsi, [xhci_op_base]
    test rsi, rsi
    jz .ack_done
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    mov dword [rsi + XHCI_OP_USBSTS], XHCI_STS_EINT

.ack_done:
    pop rsi
    pop rax
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
    SER 'C'

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
    SER 'v'

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
    SER 'Z'
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

    ; Serial: print completion code digit (debug-only)
%ifdef ENABLE_DEBUG_SERIAL
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
%endif

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
; Returns: EAX = completion code (0 if no event), EBX = dword3, ECX = dword0,
;          EDX = Transfer Event residual length (DW2 bits 23:0; zero otherwise)
; ============================================================================
global xhci_poll_event
xhci_poll_event:
    push rsi
    push rdi
    push r8                       ; steal-budget scratch (restored before return)

    ; Serialize access to the event ring. GRIT_ENABLE_RING3_AP can have CPU0
    ; in rtl8156_rx_once polling for a DHCP OFFER while CPU N is in
    ; usb_poll_mouse polling for HID reports - both call this function and
    ; race on xhci_evt_dequeue. Without this lock, one CPU reads a TRB whose
    ; cycle bit was JUST flipped by the other's dequeue advance, treats the
    ; old contents as a fresh event, and dispatches off a stale slot/type →
    ; observed as RIP=0 page fault during DHCP+mouse contention.
    ; BOUNDED acquire. The critical section is a few dozen instructions, so a
    ; legitimately-held lock clears almost immediately. A lock that is still held
    ; after a large spin budget means the holder is wedged or died mid-section
    ; (e.g. a faulted core, or an MMIO assert long-jumped out without releasing).
    ; Past the budget we STEAL it rather than spin forever - matches the
    ; bounded_lock.ghl liveness-over-exclusion policy and keeps this AP alive.
    ; The budget is iteration-based (tick-independent) so it holds even when
    ; tick_count is frozen; ~50M pause iterations is far longer than any real
    ; holder yet still terminates in well under a second on any CPU.
    mov r8d, 50000000             ; steal budget (spin iterations)
.evt_lock_acquire:
    mov eax, 1
    xchg eax, [rel xhci_evt_lock]
    test eax, eax
    jz .evt_have_lock             ; got it (old value 0)
    ; contended - back off without bus-locking, re-test
    dec r8d
    jz .evt_lock_steal
.evt_lock_spin:
    pause
    cmp dword [rel xhci_evt_lock], 0
    jne .evt_lock_recheck_budget
    jmp .evt_lock_acquire
.evt_lock_recheck_budget:
    dec r8d
    jnz .evt_lock_spin
.evt_lock_steal:
    ; Budget exhausted: presume wedged/dead holder and take the lock.
    mov dword [rel xhci_evt_lock], 1
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

    ; Preserve the Transfer Event residual length instead of discarding it.
    ; Consumers use queued_length-residual as the only trustworthy byte count.
    ; Other event types give EDX=0 because their DW2 low bits have other meaning.
    xor edx, edx
    mov r8d, ebx
    shr r8d, 10
    and r8d, 0x3F
    cmp r8d, 32
    jne .residual_done
    mov edx, [rsi + 8]
    and edx, 0x00FFFFFF
.residual_done:
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
    SER 'W'

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
    xor edx, edx

.evt_ret:
    mov dword [rel xhci_evt_lock], 0   ; release
    pop r8
    pop rdi
    pop rsi
    ret

; ============================================================================
; xhci_find_port - Find first port with a connected device
; Returns: EAX = 1 if found, 0 if not. Port number stored in xhci_port_num
; ============================================================================
global xhci_find_port
