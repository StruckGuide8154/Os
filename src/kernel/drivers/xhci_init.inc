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
    call xhci_dbg_initlog_new

    mov rsi, szXhciFound
    call debug_print

    ; Serial: '1' (found)
    mov dx, 0x3F8
    mov al, '1'
    out dx, al

    ; --- Read capability registers ---
    call xhci_read_caps
    mov al, 2
    call xhci_dbg_initlog_stage

    ; --- Take ownership from BIOS ---
    call xhci_take_ownership
    mov al, 3
    call xhci_dbg_initlog_stage

    ; Serial: '2' (ownership taken)
    mov dx, 0x3F8
    mov al, '2'
    out dx, al

    ; --- Reset controller ---
    call xhci_reset
    test eax, eax
    jz .fail
    mov al, 4
    call xhci_dbg_initlog_stage

    ; Serial: 'S' (setup start)
    mov dx, 0x3F8
    mov al, 'S'
    out dx, al

    ; --- Setup data structures ---
    call xhci_setup_scratchpad
    call xhci_setup_dcbaa
    call xhci_setup_cmd_ring
    call xhci_setup_event_ring
    mov al, 5
    call xhci_dbg_initlog_stage

    ; Serial: 'R' (rings set up)
    mov dx, 0x3F8
    mov al, 'R'
    out dx, al

    ; --- Program registers ---
    mov rsi, [xhci_op_base]
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW

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

    ; Set MaxSlotsEn = max(controller-supported, 16). One slot is not enough
    ; when usb_hid_init brings up slot1 (mouse) + slot2 (kbd) AND rtl8156_init
    ; tries to enable a third slot for the NIC. QEMU accepts oversize values
    ; up to HCSPARAMS1.MaxSlots; clamp to 16 as a sane upper bound.
    movzx eax, byte [xhci_max_slots]
    test eax, eax
    jnz .config_slots_set
    mov eax, 16
.config_slots_set:
    cmp eax, 16
    jbe .config_slots_write
    mov eax, 16
.config_slots_write:
    mov dword [rsi + XHCI_OP_CONFIG], eax

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
.wait_run:
    mov eax, [rsi + XHCI_OP_USBSTS]
    test eax, XHCI_STS_HCH
    jz .running

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
    mov al, 6
    call xhci_dbg_initlog_stage
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
    and ebx, 0x3FF                ; 10-bit field per spec
    mov [xhci_scratchpad_count], bx
    mov [xhci_scratchpad_req], bx ; Raw uncapped count for debug

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

    ; Register the xHCI BAR in the MMIO bounds registry NOW, at probe-commit -
    ; the moment op_base/rt_base/db_base are resolved - not deferred to the
    ; kmain-level mmio_drv_caps_init. usb_hid_init's own port pokes, i2c_hid,
    ; and rtl8156_init all touch this BAR (through XHCI_MMIO_ASSERT) BEFORE that
    ; late call runs, so without registering here the very first assert finds no
    ; region and false-panics (same early-IRQ trap LAPIC avoids by registering
    ; inside apic_init). mmio_drv_caps_init is idempotent, so the late call is a
    ; no-op. Reads [xhci_mmio_base] internally; all rsi uses above are done.
    extern mmio_drv_caps_init
    call mmio_drv_caps_init

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
.wait_bios:
    mov eax, [rsi]
    test eax, (1 << 16)
    jz .own_done_pop
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
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW

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
.wait_halt:
    mov eax, [rsi + XHCI_OP_USBSTS]
    test eax, XHCI_STS_HCH
    jnz .halted
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
.wait_rst:
    mov eax, [rsi + XHCI_OP_USBCMD]
    test eax, XHCI_CMD_HCRST
    jz .rst_done
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
.wait_cnr:
    mov eax, [rsi + XHCI_OP_USBSTS]
    test eax, XHCI_STS_CNR
    jz .reset_ok
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
