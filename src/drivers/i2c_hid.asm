; ============================================================================
; NexusOS v3.0 - I2C HID Touchpad Driver (Complete)
;
; Supports:
;   - AMD FCH DesignWare I2C (fixed MMIO: FEDC2000-FEDC5000)
;   - Intel LPSS I2C (PCI BAR0, DesignWare compatible)
;   - Full HID report descriptor parsing (via hid_parser.asm)
;   - Absolute and relative touchpad modes
;   - Variable-length report reading
;   - Multi-touch contact tracking
;   - Gesture detection: tap-to-click, two-finger scroll
;   - Non-blocking state machine polling
;   - Error recovery with bus reset and re-init
;
; AMD FCH I2C controllers at FEDCX000 (X = 2,3,4,5 for I2C0-3)
; Intel LPSS I2C: PCI class 0x0C80, BAR0 = DesignWare I2C MMIO
; ============================================================================
bits 64

%include "constants.inc"
extern debug_print
extern pci_read_conf_dword

extern mouse_x, mouse_y, mouse_buttons, mouse_moved
extern mouse_scroll_y
extern scr_width, scr_height
extern tick_count

; HID parser
extern hid_parse_report_desc
extern hid_process_touchpad_report
extern hid_parsed_report_id, hid_parsed_has_report_id
extern hid_parsed_is_absolute, hid_parsed_report_bytes
extern hid_parsed_is_touchpad

; --- AMD DesignWare I2C register offsets ---
DW_IC_CON           equ 0x00    ; Control
DW_IC_TAR           equ 0x04    ; Target address
DW_IC_DATA_CMD      equ 0x10    ; Data / Command register
DW_IC_SS_SCL_HCNT   equ 0x14    ; Standard speed SCL high count
DW_IC_SS_SCL_LCNT   equ 0x18    ; Standard speed SCL low count
DW_IC_FS_SCL_HCNT   equ 0x1C    ; Fast speed SCL high count
DW_IC_FS_SCL_LCNT   equ 0x20    ; Fast speed SCL low count
DW_IC_INTR_STAT     equ 0x2C    ; Interrupt status
DW_IC_INTR_MASK     equ 0x30    ; Interrupt mask
DW_IC_RAW_INTR_STAT equ 0x34    ; Raw interrupt status
DW_IC_RX_TL         equ 0x38    ; RX FIFO threshold
DW_IC_TX_TL         equ 0x3C    ; TX FIFO threshold
DW_IC_CLR_INTR      equ 0x40    ; Clear interrupts
DW_IC_CLR_TX_ABRT   equ 0x54    ; Clear TX abort
DW_IC_ENABLE        equ 0x6C    ; Enable
DW_IC_STATUS        equ 0x70    ; Status
DW_IC_TXFLR         equ 0x74    ; TX FIFO level
DW_IC_RXFLR         equ 0x78    ; RX FIFO level
DW_IC_SDA_HOLD      equ 0x7C    ; SDA hold time
DW_IC_TX_ABRT_SRC   equ 0x80    ; TX abort source
DW_IC_ENABLE_STATUS equ 0x9C    ; Enable status
DW_IC_COMP_PARAM_1  equ 0xF4    ; Component parameters

; DW_IC_CON bits
IC_CON_MASTER_MODE  equ (1 << 0)
IC_CON_SPEED_STD    equ (1 << 1)  ; Standard (100kHz)
IC_CON_SPEED_FAST   equ (2 << 1)  ; Fast (400kHz)
IC_CON_10BIT_ADDR   equ (1 << 3)
IC_CON_RESTART_EN   equ (1 << 5)
IC_CON_SLAVE_DISABLE equ (1 << 6)

; DW_IC_STATUS bits
IC_STATUS_ACTIVITY  equ (1 << 0)
IC_STATUS_TFNF      equ (1 << 1)  ; TX FIFO not full
IC_STATUS_TFE       equ (1 << 2)  ; TX FIFO empty
IC_STATUS_RFNE      equ (1 << 3)  ; RX FIFO not empty

; DW_IC_DATA_CMD bits
IC_CMD_READ         equ (1 << 8)
IC_CMD_STOP         equ (1 << 9)
IC_CMD_RESTART      equ (1 << 10)

; Known AMD FCH I2C base addresses
I2C_BASE_0  equ 0xFEDC2000
I2C_BASE_1  equ 0xFEDC3000
I2C_BASE_2  equ 0xFEDC5000   ; was 0xFEDC4000 (nonexistent); real HW has 0xFEDC5000
I2C_BASE_3  equ 0xFEDC6000   ; was 0xFEDC5000; real HW also has 0xFEDC6000
I2C_BASE_4  equ 0xFEDC0000   ; additional block seen on Strix Point

; Touchpad HID addresses to probe
TP_ADDR_ELAN        equ 0x15
TP_ADDR_SYNAPTICS   equ 0x2C

section .text

global i2c_hid_init
global i2c_hid_poll

; ============================================================================
; i2c_hid_init - Find and initialize I2C HID touchpad
; Probes AMD FCH fixed MMIO + Intel LPSS PCI controllers
; Returns: EAX = 1 if found, 0 if not found
; ============================================================================
i2c_hid_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    mov byte [i2c_hid_active], 0
    mov byte [i2c_poll_state], 0
    mov dword [i2c_error_count], 0

    ; Serial: 'T' (touchpad init)
    mov dx, 0x3F8
    mov al, 'T'
    out dx, al

    mov rsi, szI2cScan
    call debug_print

    ; === Phase 1: Try AMD FCH fixed MMIO bases ===
    lea r12, [i2c_amd_bases]
    xor r13d, r13d              ; Controller index

.try_amd_controller:
    cmp r13d, 5
    jge .try_intel

    mov rsi, [r12 + r13 * 8]   ; Load base address
    test rsi, rsi
    jz .next_amd_ctrl

    ; Sanity check: DW_IC_COMP_PARAM_1 must be non-zero and not 0xFFFFFFFF
    mov eax, [rsi + DW_IC_COMP_PARAM_1]
    test eax, eax
    jz .next_amd_ctrl
    cmp eax, 0xFFFFFFFF
    je .next_amd_ctrl

    mov [i2c_base_addr], rsi

    push rsi
    mov rsi, szI2cProbing
    call debug_print
    pop rsi

    ; Try each touchpad address on this controller
    call i2c_try_all_addresses
    test eax, eax
    jnz .found

.next_amd_ctrl:
    inc r13d
    jmp .try_amd_controller

    ; === Phase 2: Try Intel LPSS I2C via PCI ===
.try_intel:
    mov rsi, szI2cIntel
    call debug_print

    ; Scan PCI for Intel LPSS I2C controllers
    ; Look for: vendor=0x8086, class code byte 0x0C (Serial Bus), subclass 0x80
    xor r13d, r13d              ; PCI bus
    xor r14d, r14d              ; PCI device
    xor r15d, r15d              ; PCI function

.pci_scan:
    ; Build PCI address: bus<<16 | dev<<11 | func<<8 | reg
    mov eax, r13d
    shl eax, 16
    mov ecx, r14d
    shl ecx, 11
    or eax, ecx
    mov ecx, r15d
    shl ecx, 8
    or eax, ecx
    ; Read vendor/device (reg 0x00)
    push rax
    call pci_read_conf_dword
    cmp eax, 0xFFFFFFFF
    jne .pci_check_vendor
    pop rax                     ; balance push before jumping
    jmp .pci_next
.pci_check_vendor:
    ; Check vendor = 0x8086 (Intel) or 0x1022 (AMD)
    cmp ax, 0x8086
    je .pci_check_class
    cmp ax, 0x1022
    jne .pci_next_pop
    ; AMD: skip class check - different Strix/Hawk Point I2C IDs use varied classes.
    ; Instead rely on BAR0 validity + DW I2C comp_param_1 signature below.
    jmp .pci_read_bar0

.pci_check_class:
    ; Read class code (reg 0x08)
    pop rax
    push rax
    or eax, 0x08                ; Register 0x08
    call pci_read_conf_dword
    ; Class code is in bits 31:8
    shr eax, 8
    ; Check class=0x0C (Serial Bus), subclass=0x80 (Other)
    ; EAX high 16 bits = class:subclass
    shr eax, 8
    cmp ax, 0x0C80
    jne .pci_next_pop

    ; Found Intel LPSS / AMD I2C controller!
.pci_read_bar0:
    ; Read BAR0 (reg 0x10)
    pop rax
    push rax
    or eax, 0x10
    call pci_read_conf_dword
    ; BAR0 is memory-mapped, mask off type bits
    and eax, 0xFFFFF000
    test eax, eax
    jz .pci_next_pop

    ; Verify it's a DesignWare I2C by reading IC_COMP_PARAM_1
    mov rsi, rax                ; RSI = I2C MMIO base (zero-extended ok for < 4GB)
    mov esi, eax                ; zero-extend to 64-bit via 32-bit write
    mov ecx, [rsi + DW_IC_COMP_PARAM_1]
    test ecx, ecx
    jz .pci_next_pop
    cmp ecx, 0xFFFFFFFF
    je .pci_next_pop

    mov [i2c_base_addr], rsi
    mov byte [i2c_is_intel], 1

    push rsi
    mov rsi, szI2cIntelFound
    call debug_print
    pop rsi

    ; Try touchpad addresses on this Intel I2C controller
    call i2c_try_all_addresses
    test eax, eax
    jnz .found_pop

.pci_next_pop:
    pop rax
.pci_next:
    ; Advance PCI scan
    inc r15d
    cmp r15d, 8
    jl .pci_scan
    xor r15d, r15d
    inc r14d
    cmp r14d, 32
    jl .pci_scan
    xor r14d, r14d
    inc r13d
    cmp r13d, 256
    jl .pci_scan

    ; Nothing found
    jmp .not_found

.found_pop:
    add rsp, 8                  ; pop saved rax
.found:
    mov byte [i2c_hid_active], 1

    ; Serial: 'TK' (touchpad OK)
    mov dx, 0x3F8
    mov al, 'K'
    out dx, al

    mov rsi, szI2cSuccess
    call debug_print

    mov eax, 1
    jmp .ret

.not_found:
    ; Serial: 'TF'
    mov dx, 0x3F8
    mov al, 'F'
    out dx, al

    mov rsi, szI2cFail
    call debug_print

    xor eax, eax

.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; i2c_try_all_addresses - Try all known touchpad I2C addresses
; RSI = I2C controller base
; Returns: EAX = 1 if found, 0 if not
; ============================================================================
i2c_try_all_addresses:
    push rcx
    push rdi
    push r14

    lea r14, [i2c_tp_addrs]
    xor ecx, ecx

.try_addr:
    cmp ecx, I2C_TP_ADDR_COUNT
    jge .addr_fail

    movzx edi, byte [r14 + rcx]
    push rcx

    ; Initialize this I2C controller with target address
    call i2c_init_controller
    test eax, eax
    jz .next_addr

    ; Try to read I2C-HID descriptor
    call i2c_hid_get_descriptor
    test eax, eax
    jz .next_addr

    ; Found! Store device address and configure
    mov byte [i2c_dev_addr], dil

    ; Send reset command
    call i2c_hid_reset

    ; Send power-on command
    call i2c_hid_set_power_on

    ; Read HID report descriptor (for smart parsing)
    call i2c_hid_read_report_desc

    pop rcx
    mov eax, 1
    jmp .addr_ret

.next_addr:
    pop rcx
    inc ecx
    jmp .try_addr

.addr_fail:
    xor eax, eax

.addr_ret:
    pop r14
    pop rdi
    pop rcx
    ret

; ============================================================================
; i2c_init_controller - Initialize DesignWare I2C controller
; RSI = controller base address, EDI = 7-bit device address
; Returns: EAX = 1 success, 0 fail
; ============================================================================
i2c_init_controller:
    push rcx

    ; Disable controller first
    mov dword [rsi + DW_IC_ENABLE], 0

    ; Wait for disabled (activity bit clear)
    mov ecx, 5000
.wait_dis:
    mov eax, [rsi + DW_IC_ENABLE_STATUS]
    test eax, 1                 ; IC_EN bit
    jz .dis_ok
    dec ecx
    jnz .wait_dis
    xor eax, eax
    pop rcx
    ret
.dis_ok:

    ; Preserve firmware IC_CON speed/timing bits - UEFI already set correct
    ; values for this platform's I2C clock. Only enforce master mode flags.
    mov eax, [rsi + DW_IC_CON]
    or eax, IC_CON_MASTER_MODE | IC_CON_RESTART_EN | IC_CON_SLAVE_DISABLE
    mov [rsi + DW_IC_CON], eax

    ; Set target address
    mov [rsi + DW_IC_TAR], edi

    ; Do NOT overwrite SCL HCNT/LCNT/SDA_HOLD - firmware values are correct
    ; for this platform's FCH I2C clock (varies: 100/133/150MHz by platform)

    ; Mask all interrupts (we poll)
    mov dword [rsi + DW_IC_INTR_MASK], 0

    ; Set RX threshold to 0 (notify on any byte)
    mov dword [rsi + DW_IC_RX_TL], 0

    ; Clear any pending interrupts/aborts
    mov eax, [rsi + DW_IC_CLR_INTR]
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]

    ; Enable controller
    mov dword [rsi + DW_IC_ENABLE], 1

    ; Wait for enabled
    mov ecx, 5000
.wait_en:
    mov eax, [rsi + DW_IC_ENABLE_STATUS]
    test eax, 1
    jnz .en_ok
    dec ecx
    jnz .wait_en
    xor eax, eax
    pop rcx
    ret
.en_ok:

    mov eax, 1
    pop rcx
    ret

; ============================================================================
; i2c_write_byte / i2c_write_byte_stop - Write to I2C bus
; ============================================================================
i2c_write_byte:
    movzx eax, al
    mov [rsi + DW_IC_DATA_CMD], eax
    ret

i2c_write_byte_stop:
    movzx eax, al
    or eax, IC_CMD_STOP
    mov [rsi + DW_IC_DATA_CMD], eax
    ret

; ============================================================================
; i2c_wait_tx_empty - Wait for TX FIFO empty
; Returns CF=0 ok, CF=1 timeout
; ============================================================================
i2c_wait_tx_empty:
    push rcx
    mov ecx, 100000
.loop:
    mov eax, [rsi + DW_IC_STATUS]
    test eax, IC_STATUS_TFE
    jnz .ok
    ; Check for abort
    mov eax, [rsi + DW_IC_RAW_INTR_STAT]
    test eax, (1 << 6)         ; TX_ABRT
    jnz .abort
    dec ecx
    jnz .loop
    pop rcx
    stc
    ret
.abort:
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]
    pop rcx
    stc
    ret
.ok:
    pop rcx
    clc
    ret

; ============================================================================
; i2c_wait_rx_avail - Wait for N bytes in RX FIFO
; ECX = count to wait for
; Returns CF=0 ok, CF=1 timeout
; ============================================================================
i2c_wait_rx_avail:
    push rcx
    push rdx
    mov edx, ecx               ; Save wanted count
    mov ecx, 100000
.loop:
    mov eax, [rsi + DW_IC_RXFLR]
    cmp eax, edx
    jge .ok
    ; Check abort
    mov eax, [rsi + DW_IC_RAW_INTR_STAT]
    test eax, (1 << 6)
    jnz .abort
    dec ecx
    jnz .loop
    pop rdx
    pop rcx
    stc
    ret
.abort:
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]
    pop rdx
    pop rcx
    stc
    ret
.ok:
    pop rdx
    pop rcx
    clc
    ret

; ============================================================================
; i2c_flush_rx - Drain all bytes from RX FIFO
; ============================================================================
i2c_flush_rx:
    push rcx
    mov ecx, 256
.loop:
    mov eax, [rsi + DW_IC_RXFLR]
    test eax, eax
    jz .done
    mov eax, [rsi + DW_IC_DATA_CMD]
    dec ecx
    jnz .loop
.done:
    pop rcx
    ret

; ============================================================================
; i2c_hid_get_descriptor - Read HID descriptor from device
; RSI = I2C base, EDI = device address
; Returns: EAX = 1 if valid HID descriptor, 0 otherwise
; ============================================================================
i2c_hid_get_descriptor:
    push rcx
    push rbx
    push rdi

    ; Clear any pending state
    mov eax, [rsi + DW_IC_CLR_INTR]
    call i2c_flush_rx

    ; Write: register address 0x0001 (HID descriptor register)
    ; No STOP - use RESTART on first read for atomic write+read transaction
    mov al, 0x01
    call i2c_write_byte
    mov al, 0x00
    call i2c_write_byte

    ; Wait for TX done
    call i2c_wait_tx_empty
    jc .fail

    ; Small delay for device to prepare
    mov ecx, 50000
.dly: dec ecx
    jnz .dly

    ; Issue 30 read commands (HID descriptor is 30 bytes)
    mov eax, IC_CMD_READ | IC_CMD_RESTART
    mov [rsi + DW_IC_DATA_CMD], eax
    mov ecx, 28
.queue_reads:
    mov eax, IC_CMD_READ
    mov [rsi + DW_IC_DATA_CMD], eax
    dec ecx
    jnz .queue_reads
    mov eax, IC_CMD_READ | IC_CMD_STOP
    mov [rsi + DW_IC_DATA_CMD], eax

    ; Wait for 30 bytes
    mov ecx, 30
    call i2c_wait_rx_avail
    jc .fail

    ; Read 30 bytes into i2c_desc_buf
    lea rdi, [i2c_desc_buf]
    mov ecx, 30
.read_desc:
    mov eax, [rsi + DW_IC_DATA_CMD]
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .read_desc

    ; Parse HID descriptor
    ; [0:1]  wHIDDescLength
    ; [2:3]  bcdVersion
    ; [4:5]  wReportDescLength
    ; [6:7]  wReportDescRegister
    ; [8:9]  wInputRegister
    ; [10:11] wMaxInputLength
    ; [12:13] wOutputRegister
    ; [14:15] wMaxOutputLength
    ; [16:17] wCommandRegister
    ; [18:19] wDataRegister
    ; [20:21] wVendorID
    ; [22:23] wProductID
    ; [24:25] wVersionID
    lea rbx, [i2c_desc_buf]

    ; Validate wHIDDescLength
    movzx ecx, word [rbx]
    cmp ecx, 4
    jl .fail
    cmp ecx, 64
    jg .fail
    mov [i2c_hid_desc_len], cx

    ; Extract wReportDescLength [4:5]
    movzx eax, word [rbx + 4]
    mov [i2c_report_desc_len], ax

    ; Extract wReportDescRegister [6:7]
    movzx eax, word [rbx + 6]
    mov [i2c_report_desc_reg], ax

    ; Extract wInputRegister [8:9]
    movzx eax, word [rbx + 8]
    test eax, eax
    jz .keep_input_default
    mov [i2c_hid_input_reg], ax
.keep_input_default:

    ; Extract wMaxInputLength [10:11]
    movzx eax, word [rbx + 10]
    test eax, eax
    jz .keep_maxinput_default
    cmp eax, 256
    jg .keep_maxinput_default
    mov [i2c_max_input_len], ax
.keep_maxinput_default:

    ; Extract wCommandRegister [16:17]
    movzx eax, word [rbx + 16]
    test eax, eax
    jz .keep_cmd_default
    mov [i2c_hid_cmd_reg], ax
.keep_cmd_default:

    ; Extract wDataRegister [18:19]
    movzx eax, word [rbx + 18]
    test eax, eax
    jz .keep_data_default
    mov [i2c_hid_data_reg], ax
.keep_data_default:

    mov eax, 1
    jmp .desc_ret

.fail:
    xor eax, eax
.desc_ret:
    pop rdi
    pop rbx
    pop rcx
    ret

; ============================================================================
; i2c_hid_read_report_desc - Read and parse HID report descriptor
; Must be called after i2c_hid_get_descriptor (which populates register/length)
; ============================================================================
i2c_hid_read_report_desc:
    push rcx
    push rdx
    push rdi
    push rbx

    movzx ecx, word [i2c_report_desc_len]
    test ecx, ecx
    jz .rdesc_done
    cmp ecx, I2C_RDESC_BUF_SIZE
    jg .rdesc_done              ; Too large for our buffer

    mov [i2c_rdesc_read_len], cx

    ; Clear RX FIFO
    call i2c_flush_rx

    ; Write report descriptor register address (2 bytes)
    ; No STOP - RESTART on first read for atomic write+read transaction
    movzx eax, word [i2c_report_desc_reg]
    push rax
    and al, 0xFF                ; Low byte
    call i2c_write_byte
    pop rax
    shr eax, 8
    call i2c_write_byte

    call i2c_wait_tx_empty
    jc .rdesc_done

    ; Delay
    mov ecx, 100000
.rdesc_dly: dec ecx
    jnz .rdesc_dly

    ; Issue N read commands
    movzx ecx, word [i2c_rdesc_read_len]
    test ecx, ecx
    jz .rdesc_done

    ; First with RESTART
    mov eax, IC_CMD_READ | IC_CMD_RESTART
    mov [rsi + DW_IC_DATA_CMD], eax
    dec ecx
    test ecx, ecx
    jz .rdesc_last_done

    ; Middle reads
.rdesc_queue:
    cmp ecx, 1
    je .rdesc_last
    mov eax, IC_CMD_READ
    mov [rsi + DW_IC_DATA_CMD], eax
    dec ecx
    jmp .rdesc_queue

.rdesc_last:
    ; Last with STOP
    mov eax, IC_CMD_READ | IC_CMD_STOP
    mov [rsi + DW_IC_DATA_CMD], eax
.rdesc_last_done:

    ; Wait for all bytes - use multiple waits since FIFO depth may be limited
    movzx ecx, word [i2c_rdesc_read_len]
    lea rdi, [i2c_rdesc_buf]
    xor ebx, ebx                ; bytes read so far

.rdesc_read_loop:
    cmp ebx, ecx
    jge .rdesc_read_done

    ; Wait for at least 1 byte
    push rcx
    mov ecx, 1
    call i2c_wait_rx_avail
    pop rcx
    jc .rdesc_read_done

    ; Read available bytes
    mov eax, [rsi + DW_IC_RXFLR]
.rdesc_drain:
    test eax, eax
    jz .rdesc_read_loop
    cmp ebx, ecx
    jge .rdesc_read_done
    push rax
    mov eax, [rsi + DW_IC_DATA_CMD]
    mov [rdi + rbx], al
    inc ebx
    pop rax
    dec eax
    jmp .rdesc_drain

.rdesc_read_done:
    ; Parse the report descriptor
    push rsi
    lea rsi, [i2c_rdesc_buf]
    mov ecx, ebx               ; actual bytes read
    call hid_parse_report_desc
    pop rsi
    ; EAX = 1 if parsed successfully

    ; If parsing succeeded, we know the report layout
    test eax, eax
    jz .rdesc_done
    mov byte [i2c_use_parsed], 1

.rdesc_done:
    pop rbx
    pop rdi
    pop rdx
    pop rcx
    ret

; ============================================================================
; i2c_hid_reset - Send HID reset command
; ============================================================================
i2c_hid_reset:
    push rcx

    ; Write to wCommandRegister: reset command
    ; Format: [cmd_reg_low, cmd_reg_high, 0x00, 0x01]
    movzx eax, word [i2c_hid_cmd_reg]
    call i2c_write_byte
    movzx eax, word [i2c_hid_cmd_reg]
    shr eax, 8
    call i2c_write_byte
    mov al, 0x00                ; reportType=0, reportID=0
    call i2c_write_byte
    mov al, 0x01                ; opcode = RESET (0x01)
    call i2c_write_byte_stop

    call i2c_wait_tx_empty

    ; Wait for reset to complete (~10ms)
    mov ecx, 1000000
.rst_wait:
    dec ecx
    jnz .rst_wait

    ; Drain any reset response
    call i2c_flush_rx

    pop rcx
    ret

; ============================================================================
; i2c_hid_set_power_on - Send SET_POWER(ON) command
; ============================================================================
i2c_hid_set_power_on:
    ; Write to commandReg: opcode=SET_POWER(8), powerState=ON(0)
    movzx eax, word [i2c_hid_cmd_reg]
    call i2c_write_byte
    movzx eax, word [i2c_hid_cmd_reg]
    shr eax, 8
    call i2c_write_byte
    mov al, 0x00                ; powerState = ON
    call i2c_write_byte
    mov al, 0x08                ; SET_POWER opcode
    call i2c_write_byte_stop

    call i2c_wait_tx_empty
    ret

; ============================================================================
; i2c_hid_bus_reset - Emergency bus reset on repeated errors
; Disables and re-enables the I2C controller
; ============================================================================
i2c_hid_bus_reset:
    push rcx

    ; Disable controller
    mov dword [rsi + DW_IC_ENABLE], 0
    mov ecx, 10000
.dis_wait:
    dec ecx
    jnz .dis_wait

    ; Clear all interrupt/abort state
    mov eax, [rsi + DW_IC_CLR_INTR]
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]

    ; Re-enable
    mov dword [rsi + DW_IC_ENABLE], 1
    mov ecx, 10000
.en_wait:
    dec ecx
    jnz .en_wait

    ; Reset poll state
    mov byte [i2c_poll_state], 0
    mov dword [i2c_error_count], 0

    pop rcx
    ret

; ============================================================================
; i2c_hid_poll - Non-blocking touchpad poll (called from main loop)
;
; State machine (3 states for variable-length reports):
;   State 0: Issue wInputRegister address + queue header reads (2 bytes)
;            -> set state=1
;   State 1: Check if 2 header bytes available. Read length.
;            If length > 0, queue remaining reads. -> state=2
;            If length == 0, -> state=0 (no data)
;   State 2: Check if all data bytes available. Process report. -> state=0
; ============================================================================
i2c_hid_poll:
    cmp byte [i2c_hid_active], 1
    jne .poll_ret

    mov rsi, [i2c_base_addr]

    ; Check for TX abort (non-blocking)
    mov eax, [rsi + DW_IC_RAW_INTR_STAT]
    test eax, (1 << 6)
    jz .no_abort
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]
    inc dword [i2c_error_count]
    cmp dword [i2c_error_count], 50
    jge .do_bus_reset
    mov byte [i2c_poll_state], 0
    ret
.no_abort:

    movzx eax, byte [i2c_poll_state]
    cmp eax, 1
    je .state1
    cmp eax, 2
    je .state2

    ; === STATE 0: Issue read request ===
.state0:
    ; Drain any stale RX data
    mov eax, [rsi + DW_IC_RXFLR]
    test eax, eax
    jz .state0_no_drain
    call i2c_flush_rx
.state0_no_drain:

    ; Write wInputRegister address (2 bytes, no STOP - RESTART on read)
    movzx eax, word [i2c_hid_input_reg]
    call i2c_write_byte
    movzx eax, word [i2c_hid_input_reg]
    shr eax, 8
    call i2c_write_byte

    ; Queue reads for the 2-byte length header
    mov eax, IC_CMD_READ | IC_CMD_RESTART
    mov [rsi + DW_IC_DATA_CMD], eax
    mov eax, IC_CMD_READ | IC_CMD_STOP
    mov [rsi + DW_IC_DATA_CMD], eax

    mov byte [i2c_poll_state], 1
    ret

    ; === STATE 1: Read length header ===
.state1:
    mov eax, [rsi + DW_IC_RXFLR]
    cmp eax, 2
    jl .poll_ret                ; Not ready yet

    ; Read 2-byte length (LE)
    mov eax, [rsi + DW_IC_DATA_CMD]
    movzx ecx, al
    mov eax, [rsi + DW_IC_DATA_CMD]
    movzx eax, al
    shl eax, 8
    or ecx, eax                 ; ECX = packet length (including 2-byte header)

    ; Validate length
    cmp ecx, 2
    jle .state1_no_data         ; Length 0-2 = no data
    cmp ecx, 0xFFFF
    je .state1_no_data
    cmp ecx, 256
    jg .state1_no_data          ; Sanity check

    ; Data length = packet length - 2 (header already read)
    sub ecx, 2
    mov [i2c_pending_len], cx

    ; Queue reads for remaining data bytes
    ; First with RESTART
    push rcx
    movzx eax, word [i2c_hid_input_reg]
    call i2c_write_byte
    movzx eax, word [i2c_hid_input_reg]
    shr eax, 8
    call i2c_write_byte         ; No STOP - RESTART on first read
    pop rcx

    ; FIX: device re-sends full report (packet_length bytes) on the second transaction,
    ; including the 2-byte length header. Queue packet_length = data_bytes + 2 reads.
    add ecx, 2

    push rcx
    ; Queue reads: first with restart
    mov eax, IC_CMD_READ | IC_CMD_RESTART
    mov [rsi + DW_IC_DATA_CMD], eax
    dec ecx

    ; Middle reads
.state1_queue:
    cmp ecx, 1
    jle .state1_last
    mov eax, IC_CMD_READ
    mov [rsi + DW_IC_DATA_CMD], eax
    dec ecx
    jmp .state1_queue

.state1_last:
    ; Last with STOP
    test ecx, ecx
    jz .state1_queue_done
    mov eax, IC_CMD_READ | IC_CMD_STOP
    mov [rsi + DW_IC_DATA_CMD], eax

.state1_queue_done:
    pop rcx
    ; ECX = packet_length (data_bytes + 2); i2c_pending_len already accounts for header
    mov [i2c_pending_len], cx

    mov byte [i2c_poll_state], 2
    ret

.state1_no_data:
    mov byte [i2c_poll_state], 0
    ret

    ; === STATE 2: Read data payload ===
.state2:
    movzx ecx, word [i2c_pending_len]
    mov eax, [rsi + DW_IC_RXFLR]
    cmp eax, ecx
    jl .poll_ret                ; Not all bytes ready yet

    ; Read all bytes into report buffer
    lea rdi, [i2c_report_buf]
    xor ebx, ebx
.state2_read:
    cmp ebx, ecx
    jge .state2_process
    mov eax, [rsi + DW_IC_DATA_CMD]
    mov [rdi + rbx], al
    inc ebx
    jmp .state2_read

.state2_process:
    mov byte [i2c_poll_state], 0
    mov dword [i2c_error_count], 0  ; Reset error count on success

    ; Parse the report
    ; First 2 bytes are length header (skip them)
    ; Byte 2 = Report ID (if has_report_id)
    lea rdi, [i2c_report_buf]
    movzx ecx, word [rdi]       ; packet length from header
    sub ecx, 2                   ; data length after header
    cmp ecx, 1
    jl .poll_ret                 ; No useful data
    add rdi, 2                   ; skip length header

    ; Check if we have parsed report descriptor
    cmp byte [i2c_use_parsed], 1
    je .use_parsed_report

    ; === Fallback: legacy 6-byte fixed-format report ===
    ; [ReportID] [Buttons] [Xlow] [Xhi] [Ylow] [Yhi]
    movzx eax, byte [rdi]       ; Report ID
    inc rdi
    dec ecx

    movzx eax, byte [rdi]       ; Buttons
    and al, 0x07
    mov [mouse_buttons], al

    ; X delta (16-bit signed LE)
    movzx eax, byte [rdi + 1]
    movzx ebx, byte [rdi + 2]
    shl ebx, 8
    or eax, ebx
    movsx eax, ax
    sar eax, 1                   ; sensitivity scaling
    add [mouse_x], eax

    ; Y delta (16-bit signed LE)
    movzx eax, byte [rdi + 3]
    movzx ebx, byte [rdi + 4]
    shl ebx, 8
    or eax, ebx
    movsx eax, ax
    sar eax, 1
    add [mouse_y], eax

    ; Scroll wheel byte (byte 5, 8-bit signed, optional)
    cmp ecx, 6
    jl .no_legacy_scroll
    movsx eax, byte [rdi + 5]
    test eax, eax
    jz .no_legacy_scroll
    mov [mouse_scroll_y], eax
.no_legacy_scroll:

    ; Clamp
    jmp .poll_clamp

.use_parsed_report:
    ; Skip report ID byte if present
    push rcx
    cmp byte [hid_parsed_has_report_id], 1
    jne .no_skip_id
    inc rdi
    dec ecx
.no_skip_id:

    ; Use parsed layout to process report
    mov rsi, rdi                 ; report data pointer
    ; ECX = data length
    call hid_process_touchpad_report
    pop rcx
    mov byte [mouse_moved], 1   ; mark moved so cursor updates
    jmp .poll_ret

.poll_clamp:
    ; Clamp coordinates
    cmp dword [mouse_x], 0
    jge .cx_ok
    mov dword [mouse_x], 0
.cx_ok:
    mov eax, [scr_width]
    dec eax
    cmp [mouse_x], eax
    jle .cx_max_ok
    mov [mouse_x], eax
.cx_max_ok:
    cmp dword [mouse_y], 0
    jge .cy_ok
    mov dword [mouse_y], 0
.cy_ok:
    mov eax, [scr_height]
    dec eax
    cmp [mouse_y], eax
    jle .cy_max_ok
    mov [mouse_y], eax
.cy_max_ok:
    mov byte [mouse_moved], 1

.poll_ret:
    ret

.do_bus_reset:
    call i2c_hid_bus_reset
    ret

; ============================================================================
; i2c_hid_debug_dump - Dump I2C state to buffer
; RDI = buffer pointer
; ============================================================================
global i2c_hid_debug_dump
i2c_hid_debug_dump:
    push rdi
    push rsi
    push rax
    push rbx
    push rcx
    push rdx

    mov rbx, rdi

    lea rsi, [.hdr]
    call .copystr

    ; Active
    lea rsi, [.s_active]
    call .copystr
    movzx eax, byte [i2c_hid_active]
    call .writehex8

    ; Base/Addr
    lea rsi, [.s_base]
    call .copystr
    mov rax, [i2c_base_addr]
    call .writehex32
    mov byte [rbx], '/'
    inc rbx
    movzx eax, byte [i2c_dev_addr]
    call .writehex8

    ; Intel?
    cmp byte [i2c_is_intel], 1
    jne .not_intel_dbg
    lea rsi, [.s_intel]
    call .copystr
.not_intel_dbg:

    ; Parsed?
    cmp byte [i2c_use_parsed], 1
    jne .not_parsed_dbg
    lea rsi, [.s_parsed]
    call .copystr
    cmp byte [hid_parsed_is_absolute], 1
    jne .parsed_rel
    lea rsi, [.s_abs]
    call .copystr
    jmp .parsed_done_dbg
.parsed_rel:
    lea rsi, [.s_rel]
    call .copystr
.parsed_done_dbg:
.not_parsed_dbg:

    ; Error count
    lea rsi, [.s_err]
    call .copystr
    mov eax, [i2c_error_count]
    call .writehex32

    ; Null terminate
    mov byte [rbx], 0

    pop rdx
    pop rcx
    pop rbx
    pop rax
    pop rsi
    pop rdi
    ret

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
    shr eax, 20
    and al, 0xF
    call .nib
    pop rax
    push rax
    shr eax, 16
    and al, 0xF
    call .nib
    pop rax
    push rax
    shr eax, 12
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

.hdr        db " -- I2C Debug --", 0
.s_active   db " Active:", 0
.s_base     db " Base:", 0
.s_intel    db " [Intel]", 0
.s_parsed   db " Parsed:", 0
.s_abs      db "Abs", 0
.s_rel      db "Rel", 0
.s_err      db " Err:", 0

; ============================================================================
; Data Section
; ============================================================================
section .data

; AMD FCH I2C base addresses - all blocks seen on Strix Point real hardware
; Order: higher indices first (I2CD = instance 3 likely at 0xFEDC5000 or 0xFEDC6000)
i2c_amd_bases:
    dq I2C_BASE_2               ; 0xFEDC5000 - most likely I2CD on Strix Point
    dq I2C_BASE_3               ; 0xFEDC6000 - fallback I2CD candidate
    dq I2C_BASE_1               ; 0xFEDC3000 - I2CB
    dq I2C_BASE_0               ; 0xFEDC2000 - I2CA
    dq I2C_BASE_4               ; 0xFEDC0000 - additional FCH block

; Touchpad I2C addresses to probe (most-common first)
i2c_tp_addrs:
    db 0x15             ; ELAN primary (Acer Nitro / AMD Ryzen)
    db 0x17             ; ELAN variant (Nitro V16 AI / Strix Point)
    db 0x2C             ; Synaptics / ALPS
    db 0x38             ; ELAN variant
    db 0x10             ; ELAN alt
    db 0x14             ; Goodix
    db 0x5D             ; Goodix alternate
    db 0x2A             ; Synaptics secondary
    db 0x3C             ; ALPS I2C-HID
    db 0x20             ; Pixart
    db 0x34             ; FocalTech
    db 0x16             ; ELAN variant 2
    db 0x2D             ; Synaptics variant
I2C_TP_ADDR_COUNT   equ ($ - i2c_tp_addrs)

; I2C-HID state
i2c_hid_active:     db 0
i2c_dev_addr:       db 0
i2c_poll_state:     db 0        ; 0=issue, 1=read header, 2=read data
i2c_is_intel:       db 0        ; 1 if controller found via PCI (Intel LPSS)
i2c_use_parsed:     db 0        ; 1 if HID report descriptor was parsed successfully
i2c_base_addr:      dq 0
i2c_hid_desc_len:   dw 0
i2c_error_count:    dd 0        ; consecutive error counter for bus reset
i2c_pending_len:    dw 0        ; bytes pending in state 2

; I2C-HID register addresses (from HID descriptor, with defaults)
i2c_hid_cmd_reg:    dw 0x0005
i2c_hid_input_reg:  dw 0x0003
i2c_hid_data_reg:   dw 0x0007
i2c_max_input_len:  dw 64       ; wMaxInputLength from descriptor

; Report descriptor info
i2c_report_desc_len:    dw 0    ; wReportDescLength
i2c_report_desc_reg:    dw 0    ; wReportDescRegister
i2c_rdesc_read_len:     dw 0    ; actual bytes to read

; Buffers
i2c_desc_buf:       times 32 db 0   ; Raw HID descriptor (30 bytes)
i2c_report_buf:     times 256 db 0  ; Input report buffer (variable length)

I2C_RDESC_BUF_SIZE  equ 512
i2c_rdesc_buf:      times I2C_RDESC_BUF_SIZE db 0  ; Report descriptor buffer

; Strings
szI2cScan       db "I2C: Scanning AMD+Intel...", 0
szI2cProbing    db "I2C: Probing Controller...", 0
szI2cIntel      db "I2C: Scanning Intel LPSS PCI...", 0
szI2cIntelFound db "I2C: Intel LPSS Found!", 0
szI2cSuccess    db "I2C: Touchpad Found!", 0
szI2cFail       db "I2C: Not Found.", 0
