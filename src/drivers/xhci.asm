; ============================================================================
; NexusOS v3.0 - USB XHCI Host Controller Driver
; PCI discovery, controller init, ring management, port/device enumeration
; ============================================================================
bits 64

%include "constants.inc"

extern pci_read_conf_dword
extern pci_write_conf_dword
extern tick_count
extern debug_print

section .text

; ============================================================================
; xhci_init - Find and initialize XHCI controller
; Returns: EAX = 1 on success, 0 on failure
; ============================================================================
global xhci_init
xhci_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r12
    push r13
    push r14
    push r15
    
    mov rsi, szXhciStart
    call debug_print

    ; Serial: 'U' start
    mov dx, 0x3F8
    mov al, 'U'
    out dx, al

    ; --- Zero XHCI memory region ---
    mov rdi, XHCI_DCBAA_ADDR
    mov rcx, (XHCI_MEM_END - XHCI_DCBAA_ADDR) / 8
    xor rax, rax
    rep stosq

    ; --- PCI scan for next XHCI controller (resumes from last found position) ---
    call xhci_pci_find
    test eax, eax
    jz .fail
    
    mov rsi, szXhciFound
    call debug_print

    ; Serial: '1' (found)
    mov dx, 0x3F8
    mov al, '1'
    out dx, al

    ; --- Read capability registers ---
    call xhci_read_caps

    ; --- Take ownership from BIOS ---
    call xhci_take_ownership

    ; Serial: '2' (ownership taken)
    mov dx, 0x3F8
    mov al, '2'
    out dx, al

    ; --- Reset controller ---
    call xhci_reset
    test eax, eax
    jz .fail

    ; Serial: 'S' (setup start)
    mov dx, 0x3F8
    mov al, 'S'
    out dx, al

    ; --- Setup data structures ---
    call xhci_setup_scratchpad
    call xhci_setup_dcbaa
    call xhci_setup_cmd_ring
    call xhci_setup_event_ring

    ; Serial: 'R' (rings set up)
    mov dx, 0x3F8
    mov al, 'R'
    out dx, al

    ; --- Program registers ---
    mov rsi, [xhci_op_base]

    ; Write DCBAAP
    mov eax, XHCI_DCBAA_ADDR
    mov [rsi + XHCI_OP_DCBAAP_LO], eax
    xor eax, eax
    mov [rsi + XHCI_OP_DCBAAP_HI], eax

    ; Write CRCR (Command Ring Control Register)
    mov eax, XHCI_CMD_RING_ADDR
    or eax, 1                     ; RCS = 1 (Ring Cycle State)
    mov [rsi + XHCI_OP_CRCR_LO], eax
    xor eax, eax
    mov [rsi + XHCI_OP_CRCR_HI], eax

    ; Set MaxSlotsEn = 1
    mov dword [rsi + XHCI_OP_CONFIG], 1

    ; Serial: '3' (regs programmed)
    mov dx, 0x3F8
    mov al, '3'
    out dx, al

    ; --- Start controller ---
    mov eax, [rsi + XHCI_OP_USBCMD]
    or eax, XHCI_CMD_RS           ; Run/Stop = 1
    mov [rsi + XHCI_OP_USBCMD], eax

    ; Wait for HCH = 0 (controller running) - up to 500ms
    mov rbx, [tick_count]
    add rbx, 50              ; 50 ticks = 500ms
    mov ecx, 10000000        ; 10M spins fallback
.wait_run:
    mov eax, [rsi + XHCI_OP_USBSTS]
    test eax, XHCI_STS_HCH
    jz .running
    
    dec ecx
    jz .fail
    
    mov rax, [tick_count]
    cmp rax, rbx
    jge .fail
    pause
    jmp .wait_run
.running:

    ; Serial: '4' (running)
    mov dx, 0x3F8
    mov al, '4'
    out dx, al

    ; Controller is running. Return success. 
    ; Port enumeration is now handled by the caller (usb_hid.asm)
    mov byte [xhci_active], 1
    mov eax, 1
    jmp .ret

.fail:
    ; Serial: '!'
    mov dx, 0x3F8
    mov al, '!'
    out dx, al

    mov rsi, szXhciFail
    call debug_print

    mov byte [xhci_active], 0
    xor eax, eax

.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; xhci_pci_find - Scan ALL PCI buses for XHCI controller
; Starts search from xhci_pci_search_start (so we can retry with next controller)
; Returns: EAX = 1 if found, 0 if not
; Sets xhci_pci_addr, xhci_mmio_base
; ============================================================================
xhci_pci_find:
    push rbx
    push rcx
    push rdx

    ; Load search start position to skip already-tried controllers
    ; xhci_pci_search_start: bus<<16 | dev<<8 | func (packed)
    mov ebx, [xhci_pci_search_start]

    ; Unpack: bus = bits 23:16, dev = bits 12:8, func = bits 2:0
    mov eax, ebx
    shr eax, 16
    and eax, 0xFF
    mov r12d, eax                ; Starting bus

    mov eax, ebx
    shr eax, 8
    and eax, 0xFF
    mov r14d, eax                ; Starting dev

    mov eax, ebx
    and eax, 0xFF
    mov r13d, eax                ; Starting func

.bus_loop:
    cmp r12d, 256
    jge .not_found

.dev_loop:
    cmp r14d, 32
    jge .next_bus

.func_loop:
    cmp r13d, 8
    jge .next_dev

    ; Build PCI config address: 1<<31 | bus<<16 | dev<<11 | func<<8 | reg
    mov eax, 0x80000000
    mov ebx, r12d
    shl ebx, 16
    or eax, ebx
    mov ebx, r14d
    shl ebx, 11
    or eax, ebx
    mov ebx, r13d
    shl ebx, 8
    or eax, ebx
    ; reg=0 for Vendor/Device
    push rax
    call pci_read_conf_dword
    cmp ax, 0xFFFF
    je .next_func_pop

    ; Read class at offset 0x08
    pop rax
    push rax
    or eax, 0x08
    call pci_read_conf_dword
    mov ebx, eax
    shr ebx, 24
    cmp bl, 0x0C
    jne .next_func_pop
    mov ecx, eax
    shr ecx, 16
    and ecx, 0xFF
    cmp ecx, 0x03
    jne .next_func_pop
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    cmp edx, 0x30
    jne .next_func_pop

    ; Found XHCI!
    pop rax                       ; discard saved PCI addr

    ; Pack bus/dev/func into a dword: bus<<16 | dev<<8 | func
    mov ecx, r12d
    shl ecx, 16
    mov eax, r14d
    shl eax, 8
    or ecx, eax
    mov eax, r13d
    or ecx, eax

    ; Save THIS position so usb_hid_init_same_ctrl can re-find this controller
    mov [xhci_pci_this_start], ecx

    ; Save NEXT position (func+1) to advance past this controller next search
    lea edx, [ecx + 1]            ; func+1 (func is in low byte, safe if func < 7)
    mov [xhci_pci_search_start], edx

    ; Build PCI base addr for register access: 0x80000000 | bus<<16 | dev<<11 | func<<8
    mov eax, 0x80000000
    mov ebx, r12d
    shl ebx, 16
    or eax, ebx
    mov ebx, r14d
    shl ebx, 11
    or eax, ebx
    mov ebx, r13d
    shl ebx, 8
    or eax, ebx
    mov [xhci_pci_addr], eax

    ; Read BAR0 (offset 0x10)
    mov eax, [xhci_pci_addr]
    or eax, 0x10
    call pci_read_conf_dword
    mov ebx, eax
    and ebx, 0x06
    mov ecx, eax
    and ecx, 0xFFFFFFF0
    mov [xhci_mmio_base], rcx

    cmp bl, 0x04
    jne .bar_done
    mov eax, [xhci_pci_addr]
    or eax, 0x14
    call pci_read_conf_dword
    shl rax, 32
    or [xhci_mmio_base], rax

.bar_done:
    ; Enable bus mastering + memory space
    mov eax, [xhci_pci_addr]
    or eax, 0x04
    call pci_read_conf_dword
    or eax, 0x06
    mov ecx, eax
    mov eax, [xhci_pci_addr]
    or eax, 0x04
    call pci_write_conf_dword

    ; Print MMIO base low 32 bits to serial for debug
    push rax
    push rdx
    mov eax, [xhci_mmio_base]
    mov dx, 0x3F8
    call serial_hex32
    pop rdx
    pop rax

    mov eax, 1
    jmp .pci_ret

.next_func_pop:
    pop rax
    inc r13d
    jmp .func_loop

.next_dev:
    inc r14d
    xor r13d, r13d
    jmp .dev_loop

.next_bus:
    inc r12d
    xor r14d, r14d
    xor r13d, r13d
    jmp .bus_loop

.not_found:
    ; Reset search start for next full scan
    mov dword [xhci_pci_search_start], 0
    xor eax, eax
.pci_ret:
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; xhci_probe - Find XHCI controller via PCI and read capabilities.
; Does NOT reset or initialise the controller.
; Sets xhci_op_base and xhci_max_ports so port registers can be polled.
; Returns: EAX = 1 found, 0 not found.
; ============================================================================
global xhci_probe
xhci_probe:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov dword [xhci_pci_search_start], 0
    call xhci_pci_find
    test eax, eax
    jz .not_found
    call xhci_read_caps
    mov eax, 1
    jmp .done
.not_found:
    xor eax, eax
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; xhci_read_caps - Read capability registers
; ============================================================================
xhci_read_caps:
    push rsi

    mov rsi, [xhci_mmio_base]

    ; CAPLENGTH (byte at offset 0)
    movzx eax, byte [rsi + XHCI_CAP_CAPLENGTH]
    mov [xhci_cap_length], al

    ; OpBase = MMIO + CAPLENGTH
    movzx rax, byte [xhci_cap_length]
    add rax, rsi
    mov [xhci_op_base], rax

    ; HCSPARAMS1
    mov eax, [rsi + XHCI_CAP_HCSPARAMS1]
    mov [xhci_hcsparams1], eax
    and eax, 0xFF                 ; MaxSlots (bits 0-7)
    mov [xhci_max_slots], al
    mov eax, [xhci_hcsparams1]
    shr eax, 24                   ; MaxPorts (bits 24-31)
    mov [xhci_max_ports], al

    ; HCSPARAMS2
    mov eax, [rsi + XHCI_CAP_HCSPARAMS2]
    mov [xhci_hcsparams2], eax
    ; Scratchpad count = (bits 25-31) << 5 | (bits 21-25)
    mov ebx, eax
    shr ebx, 27                   ; High 5 bits (bits 31-27)
    mov ecx, eax
    shr ecx, 21
    and ecx, 0x1F                 ; Low 5 bits (bits 25-21)
    shl ebx, 5
    or ebx, ecx
    mov [xhci_scratchpad_count], bl

    ; HCCPARAMS1
    mov eax, [rsi + XHCI_CAP_HCCPARAMS1]
    mov [xhci_hccparams1], eax
    ; Context size: bit 2 = CSZ (0=32 bytes, 1=64 bytes)
    test eax, 0x04
    jz .ctx_32
    mov byte [xhci_ctx_size], 64
    jmp .ctx_done
.ctx_32:
    mov byte [xhci_ctx_size], 32
.ctx_done:

    ; DBOFF
    mov eax, [rsi + XHCI_CAP_DBOFF]
    and eax, ~0x03                ; Clear low 2 bits
    add rax, rsi
    mov [xhci_db_base], rax

    ; RTSOFF
    mov eax, [rsi + XHCI_CAP_RTSOFF]
    and eax, ~0x1F                ; Clear low 5 bits
    add rax, rsi
    mov [xhci_rt_base], rax

    pop rsi
    ret

; ============================================================================
; xhci_take_ownership - Take XHCI from BIOS via Legacy Support capability
; ============================================================================
xhci_take_ownership:
    push rsi
    push rcx
    push rax

    mov rsi, [xhci_mmio_base]
    mov eax, [xhci_hccparams1]
    shr eax, 16                   ; xECP offset in dwords
    shl eax, 2                    ; Convert to bytes
    test eax, eax
    jz .own_done                  ; No extended capabilities

    add rsi, rax                  ; RSI = first extended cap

.cap_loop:
    mov eax, [rsi]
    mov ecx, eax
    and ecx, 0xFF                 ; Capability ID
    cmp ecx, 1                    ; USB Legacy Support
    je .found_legacy

    ; Next capability
    shr eax, 8
    and eax, 0xFF                 ; Next offset (in dwords)
    test eax, eax
    jz .own_done                  ; End of list
    shl eax, 2
    add rsi, rax
    jmp .cap_loop

.found_legacy:
    ; Check if BIOS owns it
    mov eax, [rsi]
    test eax, (1 << 16)          ; BIOS Owned Semaphore
    jz .own_done                  ; BIOS doesn't own it

    ; Set OS Owned Semaphore (bit 24)
    or eax, (1 << 24)
    mov [rsi], eax

    ; Wait for BIOS to release (bit 16 = 0) - up to 100ms
    push rdx
    push rcx
    mov rdx, [tick_count]
    add rdx, 10              ; 10 ticks = 100ms
    mov ecx, 2000000
.wait_bios:
    mov eax, [rsi]
    test eax, (1 << 16)
    jz .own_done_pop
    dec ecx
    jz .bios_timeout
    mov rax, [tick_count]
    cmp rax, rdx
    jge .bios_timeout
    pause
    jmp .wait_bios
.bios_timeout:
    ; Timeout - force release
    mov eax, [rsi]
    and eax, ~(1 << 16)
    or eax, (1 << 24)
    mov [rsi], eax
.own_done_pop:
    pop rcx
    pop rdx

.own_done:
    pop rax
    pop rcx
    pop rsi
    ret

; ============================================================================
; xhci_reset - Reset the XHCI controller
; Returns: EAX = 1 on success, 0 on timeout
; Uses PIT-based timeouts so they work on any CPU speed.
; ============================================================================
xhci_reset:
    push rsi
    push rcx
    push rbx

    mov rsi, [xhci_op_base]

    ; Stop controller: clear Run/Stop
    mov eax, [rsi + XHCI_OP_USBCMD]
    and eax, ~XHCI_CMD_RS
    mov [rsi + XHCI_OP_USBCMD], eax

    ; Serial: 'a' (wait halt start)
    push rdx
    mov dx, 0x3F8
    mov al, 'a'
    out dx, al
    pop rdx

    ; Wait for HCH = 1 (halted) - up to 100ms
    mov rbx, [tick_count]
    add rbx, 10              ; 10 PIT ticks = 100ms
    mov ecx, 2000000
.wait_halt:
    mov eax, [rsi + XHCI_OP_USBSTS]
    test eax, XHCI_STS_HCH
    jnz .halted
    dec ecx
    jz .reset_fail
    mov rax, [tick_count]
    cmp rax, rbx
    jge .reset_fail          ; Timeout
    pause
    jmp .wait_halt
.halted:

    ; Serial: 'b' (halted)
    push rdx
    mov dx, 0x3F8
    mov al, 'b'
    out dx, al
    pop rdx

    ; Set HCRST
    mov eax, [rsi + XHCI_OP_USBCMD]
    or eax, XHCI_CMD_HCRST
    mov [rsi + XHCI_OP_USBCMD], eax

    ; Wait for HCRST to clear - up to 1 second
    mov rbx, [tick_count]
    add rbx, 100             ; 100 PIT ticks = 1 second
    mov ecx, 20000000
.wait_rst:
    mov eax, [rsi + XHCI_OP_USBCMD]
    test eax, XHCI_CMD_HCRST
    jz .rst_done
    dec ecx
    jz .reset_fail
    mov rax, [tick_count]
    cmp rax, rbx
    jge .reset_fail          ; Timeout
    pause
    jmp .wait_rst
.rst_done:

    ; Serial: 'c' (reset done)
    push rdx
    mov dx, 0x3F8
    mov al, 'c'
    out dx, al
    pop rdx

    ; Wait for CNR = 0 - up to 1 second
    mov rbx, [tick_count]
    add rbx, 100
    mov ecx, 20000000
.wait_cnr:
    mov eax, [rsi + XHCI_OP_USBSTS]
    test eax, XHCI_STS_CNR
    jz .reset_ok
    dec ecx
    jz .reset_fail
    mov rax, [tick_count]
    cmp rax, rbx
    jge .reset_fail
    pause
    jmp .wait_cnr

.reset_ok:
    ; Serial: 'd' (CNR clear)
    push rdx
    mov dx, 0x3F8
    mov al, 'd'
    out dx, al
    pop rdx
    mov eax, 1
    jmp .reset_ret
.reset_fail:
    ; Serial: 'e' (reset fail)
    push rdx
    mov dx, 0x3F8
    mov al, 'e'
    out dx, al
    pop rdx
    xor eax, eax
.reset_ret:
    pop rbx
    pop rcx
    pop rsi
    ret

; ============================================================================
; xhci_setup_scratchpad - Allocate scratchpad buffers if needed
; ============================================================================
xhci_setup_scratchpad:
    push rcx
    push rdi

    movzx ecx, byte [xhci_scratchpad_count]
    test ecx, ecx
    jz .scratch_done              ; No scratchpads needed

    ; Cap at 4 (we have space for 4 buffer pages)
    cmp ecx, 4
    jle .scratch_ok
    mov ecx, 4
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
    push rbx
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
    mov dword [rsi], 0

    ; Poll event ring for Command Completion (PIT-based 2-second timeout + spin fallback)
    mov rbx, [tick_count]
    add rbx, 200                  ; 200 ticks = 2 seconds at 100Hz
    mov ecx, 40000000             ; ~20M iterations spin fallback
.poll:
    push rcx
    call xhci_poll_event
    pop rcx
    test eax, eax
    jnz .got_event
    
    dec ecx
    jz .cmd_fail
    
    mov rax, [tick_count]
    cmp rax, rbx
    jl .poll

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

    ; Return completion code
    ; (already in EAX from xhci_poll_event)

.cmd_ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; xhci_poll_event - Check event ring for one event
; Returns: EAX = completion code (0 if no event), EBX = dword3, ECX = dword0
; ============================================================================
global xhci_poll_event
xhci_poll_event:
    push rsi
    push rdi

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
    pop rdi
    pop rsi
    ret

; ============================================================================
; xhci_find_port - Find first port with a connected device
; Returns: EAX = 1 if found, 0 if not. Port number stored in xhci_port_num
; ============================================================================
global xhci_find_port
xhci_find_port:
    push rsi
    push rcx
    push rdx
    push rbx

    mov rsi, [xhci_op_base]
    add rsi, 0x400                ; Port register base

    movzx ecx, byte [xhci_max_ports]
    xor edx, edx                  ; Port index 0-based

    ; Serial: 'P' + max_ports hex byte
    push rax
    push rdx
    mov al, 'P'
    mov dx, 0x3F8
    out dx, al
    movzx eax, byte [xhci_max_ports]
    call serial_hex32
    pop rdx
    pop rax

.port_loop:
    cmp edx, ecx
    jge .no_port

    ; Read PORTSC for this port
    mov eax, edx
    shl eax, 4                    ; * 16 bytes per port
    mov ebx, [rsi + rax + XHCI_PORTSC]

    ; Serial: print PORTSC for each port
    push rax
    push rdx
    mov eax, ebx
    mov dx, 0x3F8
    call serial_hex32
    pop rdx
    pop rax

    ; Check CCS (Current Connect Status)
    test ebx, XHCI_PORTSC_CCS
    jnz .found_port

    inc edx
    jmp .port_loop

.found_port:
    ; Store 1-based port number
    lea eax, [edx + 1]
    mov [xhci_port_num], al

    ; Serial: 'F' + port number
    push rax
    push rdx
    mov al, 'F'
    mov dx, 0x3F8
    out dx, al
    movzx eax, byte [xhci_port_num]
    call serial_hex32
    pop rdx
    pop rax

    ; Re-read speed to check if it's USB 3.0+
    mov ecx, ebx
    shr ecx, XHCI_PORTSC_SPEED_SHIFT
    and ecx, 0x0F
    mov [xhci_port_speed], cl

    ; Power port if not powered
    test ebx, XHCI_PORTSC_PP
    jnz .port_powered
    ; Set PP, preserve CCS, clear change bits
    mov eax, ebx
    and eax, ~XHCI_PORTSC_CHANGE_BITS  ; Don't clear change bits
    or eax, XHCI_PORTSC_PP
    mov edx, [xhci_port_num]
    dec edx
    shl edx, 4
    mov [rsi + rdx + XHCI_PORTSC], eax
    ; Wait 30ms for port power (PIT-based, CPU-loops are calibrated for QEMU not real HW)
    push rax
    push rdx
    push rcx
    mov rdx, [tick_count]
    add rdx, 3                    ; 3 ticks = 30ms at 100Hz
    mov ecx, 600000
.power_wait:
    mov rax, [tick_count]
    cmp rax, rdx
    jge .pwdone
    dec ecx
    jz .pwdone
    jmp .power_wait
.pwdone:
    pop rcx
    pop rdx
    pop rax
.port_powered:

    ; Reset port
    movzx edx, byte [xhci_port_num]
    dec edx
    shl rdx, 4
    mov eax, [rsi + rdx + XHCI_PORTSC]
    and eax, ~XHCI_PORTSC_CHANGE_BITS  ; Preserve change bits
    and eax, ~XHCI_PORTSC_PED          ; Don't accidentally disable
    
    ; USB 3.0+ (Speed 4+) might need Warm Reset
    movzx ecx, byte [xhci_port_speed]
    cmp ecx, 4
    jge .do_warm_reset
    
    ; Normal Reset
    or eax, XHCI_PORTSC_PR             ; Set Port Reset
    jmp .apply_reset
    
.do_warm_reset:
    ; SuperSpeed Warm Reset
    ; WPR is bit 31
    or eax, (1 << 31)                  ; XHCI_PORTSC_WPR
    
.apply_reset:
    mov [rsi + rdx + XHCI_PORTSC], eax

    ; Wait for reset complete: PRC (Port Reset Change) = 1 or WRC (Warm Reset Change = 1<<19)
    mov rbx, [tick_count]
    add rbx, 50
    mov ecx, 10000000
.wait_reset:
    mov eax, [rsi + rdx + XHCI_PORTSC]
    test eax, XHCI_PORTSC_PRC
    jnz .reset_done
    test eax, (1 << 19)                ; WRC bit
    jnz .reset_done
    dec ecx
    jz .no_port
    mov rax, [tick_count]
    cmp rax, rbx
    jge .no_port                  ; Reset timeout
    pause
    jmp .wait_reset
.reset_done:

    ; Clear PRC and WRC by writing 1 to them
    mov eax, [rsi + rdx + XHCI_PORTSC]
    and eax, ~XHCI_PORTSC_CHANGE_BITS
    or eax, XHCI_PORTSC_PRC          ; Write 1 to clear
    or eax, (1 << 19)                ; WRC
    mov [rsi + rdx + XHCI_PORTSC], eax

    ; Re-read speed after reset (may change)
    mov eax, [rsi + rdx + XHCI_PORTSC]
    shr eax, XHCI_PORTSC_SPEED_SHIFT
    and eax, 0x0F
    mov [xhci_port_speed], al

    ; Wait 10ms after reset before enumeration (USB spec)
    push rbx
    mov rbx, [tick_count]
    add rbx, 1               ; 1 tick = 10ms at 100Hz
.post_reset_wait:
    mov rax, [tick_count]
    cmp rax, rbx
    jge .port_ready
    pause
    jmp .post_reset_wait
.port_ready:
    pop rbx

    ; Check PED (port enabled after reset) - give it extra time if needed
    mov eax, [rsi + rdx + XHCI_PORTSC]
    test eax, XHCI_PORTSC_PED
    jnz .ped_ok
    ; PED not set - try a bit longer (up to 50ms)
    push rbx
    mov rbx, [tick_count]
    add rbx, 5
.wait_ped:
    mov eax, [rsi + rdx + XHCI_PORTSC]
    test eax, XHCI_PORTSC_PED
    jnz .ped_wait_done
    mov rax, [tick_count]
    cmp rax, rbx
    jge .ped_wait_done       ; Don't fail - just proceed anyway
    pause
    jmp .wait_ped
.ped_wait_done:
    pop rbx
    ; Read final speed
    mov eax, [rsi + rdx + XHCI_PORTSC]
    shr eax, XHCI_PORTSC_SPEED_SHIFT
    and eax, 0x0F
    mov [xhci_port_speed], al
.ped_ok:

    mov eax, 1
    jmp .port_ret

.no_port:
    xor eax, eax
.port_ret:
    pop rbx
    pop rdx
    pop rcx
    pop rsi
    ret

; ============================================================================
; xhci_find_port_next - Find next port with device, starting AFTER xhci_port_num
; Scans from (xhci_port_num) 0-based onward (skips current port)
; Returns: EAX = 1 found (xhci_port_num updated), 0 = none
; ============================================================================
global xhci_find_port_next
xhci_find_port_next:
    push rsi
    push rcx
    push rdx
    push rbx

    mov rsi, [xhci_op_base]
    add rsi, 0x400

    movzx ecx, byte [xhci_max_ports]
    ; Start from current port (0-based = xhci_port_num, already used)
    movzx edx, byte [xhci_port_num]  ; 1-based -> skip it, start at [xhci_port_num] 0-based
    ; edx is already the 0-based index of the next port to check

.next_loop:
    cmp edx, ecx
    jge .next_none

    mov eax, edx
    shl eax, 4
    mov ebx, [rsi + rax + XHCI_PORTSC]
    test ebx, XHCI_PORTSC_CCS
    jnz .next_found

    inc edx
    jmp .next_loop

.next_found:
    ; Temporarily save port1 and set port_num to this new port for reset sequence
    movzx eax, byte [xhci_port_num]
    mov [xhci_port1_num], al          ; save slot1 port
    lea eax, [edx + 1]
    mov [xhci_port_num], al           ; 1-based

    ; Reset and enable this port (reuse same reset logic inline)
    mov ecx, ebx
    shr ecx, XHCI_PORTSC_SPEED_SHIFT
    and ecx, 0x0F
    mov [xhci_port_speed], cl

    ; Power port if needed
    test ebx, XHCI_PORTSC_PP
    jnz .next_powered
    mov eax, ebx
    and eax, ~XHCI_PORTSC_CHANGE_BITS
    or eax, XHCI_PORTSC_PP
    movzx ecx, byte [xhci_port_num]
    dec ecx
    shl ecx, 4
    mov [rsi + rcx + XHCI_PORTSC], eax
.next_powered:

    ; Issue port reset (PR bit)
    movzx ecx, byte [xhci_port_num]
    dec ecx
    shl ecx, 4
    mov eax, [rsi + rcx + XHCI_PORTSC]
    and eax, ~XHCI_PORTSC_CHANGE_BITS
    and eax, ~XHCI_PORTSC_PED
    or eax, XHCI_PORTSC_PR
    mov [rsi + rcx + XHCI_PORTSC], eax

    ; Wait for reset complete (PRC bit) - PIT-based 500ms timeout
    push rdx
    push r8
    mov rdx, [tick_count]
    add rdx, 50                   ; 50 ticks = 500ms at 100Hz
    mov r8d, 10000000
.next_rst_wait:
    mov eax, [rsi + rcx + XHCI_PORTSC]
    test eax, XHCI_PORTSC_PRC
    jnz .next_rst_pop_done
    
    dec r8d
    jz .next_rst_pop_done
    
    push rax
    mov rax, [tick_count]
    cmp rax, rdx
    pop rax
    jl .next_rst_wait
.next_rst_pop_done:
    pop r8
    pop rdx
.next_rst_done:
    ; Clear PRC
    or eax, XHCI_PORTSC_PRC
    and eax, ~XHCI_PORTSC_CHANGE_BITS
    mov [rsi + rcx + XHCI_PORTSC], eax

    mov eax, 1
    jmp .next_ret

.next_none:
    xor eax, eax
.next_ret:
    pop rbx
    pop rdx
    pop rcx
    pop rsi
    ret

; ============================================================================
; xhci_enable_slot - Send Enable Slot command
; Returns: EAX = slot ID (1+), 0 on failure
; ============================================================================
global xhci_enable_slot
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

    ; Slot ID in bits 31:24 of completion DWord3
    mov eax, ebx
    shr eax, 24
    and eax, 0xFF
    mov [xhci_slot_id], al
    ret

.slot_fail:
    xor eax, eax
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

    movzx eax, byte [xhci_ctx_size]
    mov [xhci_ctx_stride], eax    ; 32 or 64

    ; --- Setup Input Context at XHCI_INPUT_CTX_ADDR ---
    mov rdi, XHCI_INPUT_CTX_ADDR

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
    cmp byte [xhci_slot2_mode], 1
    je .ep0_ring2
    mov dword [rsi + 8], XHCI_CTRL_RING_ADDR | 1
    jmp .ep0_ring_done
.ep0_ring2:
    mov dword [rsi + 8], XHCI_CTRL_RING2_ADDR | 1
.ep0_ring_done:
    mov dword [rsi + 12], 0

    ; DWord 4: Average TRB Length = 8 (for control)
    mov dword [rsi + 16], 8

    ; --- Set DCBAA entry for this slot ---
    movzx eax, byte [xhci_slot_id]
    mov rdi, XHCI_DCBAA_ADDR
    cmp byte [xhci_slot2_mode], 1
    je .dcbaa_slot2
    mov qword [rdi + rax * 8], XHCI_DEV_CTX_ADDR
    jmp .dcbaa_done
.dcbaa_slot2:
    mov qword [rdi + rax * 8], XHCI_DEV_CTX2_ADDR
.dcbaa_done:

    ; --- Init EP0 transfer ring (slot-specific) ---
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
    call xhci_submit_cmd
    cmp eax, 1
    jne .addr_fail

    ; --- Submit Address Device (BSR=0) ---
    mov r8d, XHCI_INPUT_CTX_ADDR
    xor r9d, r9d
    xor r10d, r10d
    movzx eax, byte [xhci_slot_id]
    shl eax, 24
    or eax, TRB_ADDRESS_DEV       ; No BSR this time
    mov r11d, eax
    call xhci_submit_cmd
    cmp eax, 1
    jne .addr_fail

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
; xhci_ring_doorbell - Ring a doorbell register
; EDI = slot ID (0 = host controller), ESI = target (EP index or 0)
; ============================================================================
global xhci_ring_doorbell
xhci_ring_doorbell:
    push rax
    mov rax, [xhci_db_base]
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
    cmp byte [xhci_slot2_mode], 1
    je .ctrl_wrap2
    mov rsi, XHCI_CTRL_RING_ADDR
    jmp .ctrl_wrap_go
.ctrl_wrap2:
    mov rsi, XHCI_CTRL_RING2_ADDR
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
    cmp byte [xhci_slot2_mode], 1
    je .ctrl_ring2
    mov rsi, XHCI_CTRL_RING_ADDR
    jmp .ctrl_ring_go
.ctrl_ring2:
    mov rsi, XHCI_CTRL_RING2_ADDR
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
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, 'w'
    out dx, al
    pop rdx
    pop rax

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
.flush_loop:
    call xhci_poll_event
    test eax, eax
    jnz .flush_loop  ; Keep checking until no more events
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

; ============================================================================
; Data
; ============================================================================
section .data

global xhci_active
xhci_active:        db 0          ; 1 if XHCI initialized and mouse configured

xhci_pci_addr:      dd 0          ; PCI bus/dev/func address
global xhci_pci_search_start
xhci_pci_search_start: dd 0      ; Where to continue PCI scan from (for multi-controller)
global xhci_pci_this_start
xhci_pci_this_start:   dd 0      ; Start position of currently active controller (for re-init)
xhci_mmio_base:     dq 0          ; MMIO base address
global xhci_op_base
xhci_op_base:       dq 0          ; Operational registers base
xhci_db_base:       dq 0          ; Doorbell array base
xhci_rt_base:       dq 0          ; Runtime registers base

; Slot2 mode: when 1, address_device/configure_endpoint use slot2 addresses
global xhci_slot2_mode
xhci_slot2_mode:    db 0

xhci_cap_length:    db 0
xhci_max_slots:     db 0
global xhci_max_ports
xhci_max_ports:     db 0
xhci_scratchpad_count: db 0
xhci_ctx_size:      db 32         ; 32 or 64 bytes per context entry
xhci_ctx_stride:    dd 32

xhci_hcsparams1:    dd 0
xhci_hcsparams2:    dd 0
xhci_hccparams1:    dd 0

; Command ring state
xhci_cmd_enqueue:   dd 0
xhci_cmd_cycle:     db 1

; Event ring state
xhci_evt_dequeue:   dd 0
xhci_evt_cycle:     db 1

; Control EP0 ring state
xhci_ctrl_enqueue:  dd 0
xhci_ctrl_cycle:    db 1

; Interrupt IN ring state
global xhci_int_enqueue, xhci_int_cycle
xhci_int_enqueue:   dd 0
xhci_int_cycle:     db 1

; Port/device info
global xhci_port_num, xhci_port_speed, xhci_slot_id
xhci_port_num:      db 0          ; 1-based port number (current / slot1)
xhci_port1_num:     db 0          ; saved slot1 port (when slot2 is being init'd)
xhci_port_speed:    db 0          ; XHCI speed code
xhci_slot_id:       db 0          ; Assigned slot ID (slot 1 during init, then saved)
xhci_ep0_mps:       dw 64         ; EP0 max packet size
global xhci_int_ep_dci
xhci_int_ep_dci:    db 0          ; Interrupt endpoint DCI (slot 1)

; Slot 2 device state
global xhci_slot2_id, xhci_int_ep2_dci, xhci_int_enqueue2, xhci_int_cycle2
xhci_slot2_id:      db 0          ; Slot ID for second USB device
xhci_int_ep2_dci:   db 0          ; Interrupt endpoint DCI (slot 2)
xhci_int_enqueue2:  dd 0          ; Interrupt ring enqueue pointer (slot 2)
xhci_int_cycle2:    db 1          ; Interrupt ring cycle bit (slot 2)

; ============================================================================
; xhci_debug_dump - Dump XHCI state to buffer
; ============================================================================
global xhci_debug_dump
xhci_debug_dump:
    push rdi
    push rsi
    push rax
    push rbx
    push rcx
    push rdx

    mov rbx, rdi              ; RBX = write pointer

    ; Header
    lea rsi, [.hdr]
    call .copystr

    ; Active
    lea rsi, [.s_active]
    call .copystr
    movzx eax, byte [xhci_active]
    call .writehex8

    ; PCI Addr
    lea rsi, [.s_pci]
    call .copystr
    mov eax, [xhci_pci_addr]
    call .writehex32

    ; XHCI Operations
    lea rsi, [.s_op]
    call .copystr
    mov rsi, [xhci_op_base]
    test rsi, rsi
    jz .no_op
    
    ; USBCMD
    mov eax, [rsi + XHCI_OP_USBCMD]
    call .writehex32
    mov byte [rbx], ','
    inc rbx
    ; USBSTS
    mov eax, [rsi + XHCI_OP_USBSTS]
    call .writehex32
    jmp .op_done
.no_op:
    lea rsi, [.s_null]
    call .copystr
.op_done:

    ; Slot/Port
    lea rsi, [.s_slot]
    call .copystr
    movzx eax, byte [xhci_slot_id]
    call .writehex8
    mov byte [rbx], '/'
    inc rbx
    movzx eax, byte [xhci_port_num]
    call .writehex8

    ; Endpoint DCI
    lea rsi, [.s_ep]
    call .copystr
    movzx eax, byte [xhci_int_ep_dci]
    call .writehex8

    ; CMD Ring
    lea rsi, [.s_cmd]
    call .copystr
    mov eax, [xhci_cmd_enqueue]
    call .writehex8
    mov byte [rbx], ':'
    inc rbx
    movzx eax, byte [xhci_cmd_cycle]
    call .writehex8

    ; EVT Ring
    lea rsi, [.s_evt]
    call .copystr
    mov eax, [xhci_evt_dequeue]
    call .writehex8
    mov byte [rbx], ':'
    inc rbx
    movzx eax, byte [xhci_evt_cycle]
    call .writehex8

    ; INT Ring
    lea rsi, [.s_int]
    call .copystr
    mov eax, [xhci_int_enqueue]
    call .writehex8
    mov byte [rbx], ':'
    inc rbx
    movzx eax, byte [xhci_int_cycle]
    call .writehex8

    ; Null terminate
    mov byte [rbx], 0

    pop rdx
    pop rcx
    pop rbx
    pop rax
    pop rsi
    pop rdi
    ret

; -- internal helpers --
.copystr:
    lodsb
    test al, al
    jz .cs_done
    mov [rbx], al
    inc rbx
    jmp .copystr
.cs_done:
    ret

.writehex8:
    push rax
    shr al, 4
    call .nib
    pop rax
    push rax
    and al, 0x0F
    call .nib
    pop rax
    ret

.writehex32:
    push rax
    shr eax, 24
    call .nib
    pop rax
    push rax
    shr eax, 16
    and al, 0xF
    call .nib
    pop rax
    push rax
    shr eax, 8
    and al, 0xF
    call .nib
    pop rax
    push rax
    shr al, 4
    call .nib
    pop rax
    push rax
    and al, 0xF
    call .nib
    pop rax
    ret
    
.nib:
    cmp al, 10
    jb .nib_digit
    add al, 'A' - 10
    jmp .nib_out
.nib_digit:
    add al, '0'
.nib_out:
    mov [rbx], al
    inc rbx
    ret

.hdr      db " -- XHCI Debug --", 0
.s_active db " Active:", 0
.s_pci    db " PCI:", 0
.s_op     db " CMD/STS:", 0
.s_null   db " NULL", 0
.s_slot   db " S/P:", 0
.s_ep     db " EP:", 0
.s_cmd    db " C:", 0
.s_evt    db " E:", 0
.s_int    db " I:", 0

szXhciStart db "XHCI: Scanning...", 0
szXhciFound db "XHCI: Controller Found.", 0
szXhciFail  db "XHCI: Init Failed!", 0
