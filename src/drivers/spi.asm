; ============================================================================
; NexusOS v3.0 - SPI Controller Driver
; Supports:
;   - AMD FCH GSPI (fixed MMIO 0xFEC00000)
;   - AMD Sensor Fusion Hub (PCI 0x1022:0x15E4, BAR0)
;   - Intel GSPI (PCI 0x8086:various, BAR0 = DW SPI MMIO)
; ============================================================================
bits 64

%include "constants.inc"

extern pci_read_conf_dword
extern debug_print

; DesignWare SPI register offsets
%define DW_SPI_CTRLR0     0x00   ; Control 0
%define DW_SPI_CTRLR1     0x04   ; Control 1 (NDF-1 for receive-only)
%define DW_SPI_SSIENR     0x08   ; Enable (1=enabled)
%define DW_SPI_SER        0x10   ; Slave enable register
%define DW_SPI_BAUDR      0x14   ; Baud rate (div = ssi_clk / SCLK)
%define DW_SPI_TXFTLR     0x18   ; TX FIFO threshold
%define DW_SPI_RXFTLR     0x1C   ; RX FIFO threshold
%define DW_SPI_TXFLR      0x20   ; TX FIFO level
%define DW_SPI_RXFLR      0x24   ; RX FIFO level
%define DW_SPI_SR         0x28   ; Status (bit0=busy, bit1=TFNF, bit2=TFE, bit3=RFNE)
%define DW_SPI_DR         0x60   ; Data register (FIFO read/write)

; CTRLR0 fields: DFS[3:0]=7 (8-bit), TMOD[9:8]=0 (TX+RX), SCPOL=0, SCPH=0
%define SPI_CTRLR0_8BIT   0x00000007
; AMD FCH GSPI fixed base
%define AMD_FCH_GSPI_BASE  0xFEC00000

; Intel GSPI PCI vendor/device
%define INTEL_VENDOR       0x8086
; AMD Sensor Fusion Hub PCI ID
%define AMD_VENDOR         0x1022
%define AMD_SFH_DEVID      0x15E4

section .text
global spi_init
global spi_transfer
global spi_type

; ============================================================================
; spi_init - Detect and initialize SPI controller
; Returns: EAX = 1 success, 0 fail
; Sets spi_base and spi_type
; ============================================================================
spi_init:
    push rbx
    push rcx
    push rdx
    push rdi
    push r13
    push r14
    push r15

    mov byte [spi_type], 0
    mov qword [spi_base], 0

    ; === Phase 1: Try AMD FCH GSPI at fixed MMIO ===
    ; NOTE: 0xFEC00000 is also the IOAPIC base in QEMU - must verify DW SPI signature.
    ; A real idle DW SPI SR has TFE(bit2)+TFNF(bit1) set = bits [2:1] = 0x06.
    ; The IOAPIC at this address returns values without this pattern.
    mov r15, AMD_FCH_GSPI_BASE
    mov eax, [r15 + DW_SPI_SR]
    cmp eax, 0xFFFFFFFF
    je .try_pci
    ; Verify DW SPI idle signature: bits [2:1] must be set (TFE+TFNF)
    mov ecx, eax
    and ecx, 0x06
    cmp ecx, 0x06
    jne .try_pci

    ; Confirmed DW SPI - init it
    mov [spi_base], r15
    mov byte [spi_type], SPI_TYPE_AMD_FCH
    jmp .init_dw_spi

.try_pci:
    ; === Phase 2: PCI scan for AMD SFH and Intel GSPI ===
    xor r13d, r13d          ; bus
.pci_bus:
    cmp r13d, 256
    jge .fail
    xor r14d, r14d          ; device
.pci_dev:
    cmp r14d, 32
    jge .next_bus
    ; Read vendor/device at func 0
    mov eax, r13d
    shl eax, 16
    mov ecx, r14d
    shl ecx, 11
    or eax, ecx
    ; reg 0 = vendorID:deviceID
    push rax
    call pci_read_conf_dword
    cmp eax, 0xFFFFFFFF
    je .pci_next

    ; Check AMD SFH
    mov ecx, eax
    and ecx, 0xFFFF         ; vendor
    cmp ecx, AMD_VENDOR
    jne .check_intel
    shr eax, 16             ; device ID
    cmp eax, AMD_SFH_DEVID
    jne .pci_next
    ; Found AMD SFH - get BAR0
    pop rax
    push rax
    or eax, 0x10            ; BAR0 register
    call pci_read_conf_dword
    and eax, 0xFFFFFFF0
    test eax, eax
    jz .pci_next
    mov r15d, eax          ; BAR0 as 32-bit (< 4GB)
    mov [spi_base], r15
    mov byte [spi_type], SPI_TYPE_AMD_SFH
    pop rax
    jmp .init_dw_spi

.check_intel:
    ; Check Intel GSPI: vendor 0x8086, class 0x0C80 or specific device IDs
    and eax, 0xFFFF         ; restore vendor
    cmp eax, INTEL_VENDOR
    jne .pci_next
    ; Read class code
    pop rax
    push rax
    or eax, 0x08
    call pci_read_conf_dword
    shr eax, 8              ; class:subclass:prog_if
    and eax, 0xFFFF
    cmp eax, 0x0C80         ; Serial Bus / Other
    je .intel_spi_candidate
    ; Also accept class 0x0C00 SPI
    cmp eax, 0x0C00
    jne .pci_next
.intel_spi_candidate:
    ; Read BAR0
    pop rax
    push rax
    or eax, 0x10
    call pci_read_conf_dword
    and eax, 0xFFFFFFF0
    test eax, eax
    jz .pci_next
    ; Verify DW SPI signature: SR should read 0x00000006 when idle (TFE+TFNF)
    mov r15d, eax
    mov ecx, [r15 + DW_SPI_SR]
    and ecx, 0x06
    cmp ecx, 0x06
    jne .pci_next
    mov [spi_base], r15
    mov byte [spi_type], SPI_TYPE_INTEL_GSPI
    pop rax
    jmp .init_dw_spi

.pci_next:
    pop rax
    inc r14d
    jmp .pci_dev
.next_bus:
    inc r13d
    jmp .pci_bus

.fail:
    xor eax, eax
    jmp .ret

.init_dw_spi:
    ; Disable SPI controller
    mov r15, [spi_base]
    mov dword [r15 + DW_SPI_SSIENR], 0

    ; Configure: 8-bit, master, Motorola mode 0 (CPOL=0, CPHA=0)
    mov dword [r15 + DW_SPI_CTRLR0], SPI_CTRLR0_8BIT

    ; Baud rate: safe slow rate for init (div=64)
    mov dword [r15 + DW_SPI_BAUDR], 64

    ; Slave select: CS0
    mov dword [r15 + DW_SPI_SER], 1

    ; FIFO thresholds
    mov dword [r15 + DW_SPI_TXFTLR], 0
    mov dword [r15 + DW_SPI_RXFTLR], 0

    ; Enable
    mov dword [r15 + DW_SPI_SSIENR], 1

    ; Verify not frozen
    mov eax, [r15 + DW_SPI_SR]
    cmp eax, 0xFFFFFFFF
    je .fail

    mov eax, 1
.ret:
    pop r15
    pop r14
    pop r13
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; spi_transfer - Full-duplex SPI transfer (polled)
; RDI = TX buffer (or NULL for dummy TX)
; RSI = TX length
; RDX = RX buffer (or NULL to discard)
; RCX = RX length
; Returns: EAX = 1 success, 0 fail
; ============================================================================
spi_transfer:
    push rbx
    push r8
    push r9
    push r10
    push r11
    push r12

    mov r8, [spi_base]
    test r8, r8
    jz .fail_xfer

    ; Total bytes = max(TX, RX)
    mov r11, rsi
    cmp rcx, rsi
    jle .tx_start
    mov r11, rcx

.tx_start:
    xor r9, r9              ; TX index
    xor r10, r10            ; RX index

.xfer_loop:
    cmp r10, r11
    jae .xfer_done

    ; --- TX: write byte if TX FIFO not full ---
    mov eax, [r8 + DW_SPI_SR]
    test eax, 0x02          ; TFNF (TX FIFO not full)
    jz .try_rx

    cmp r9, r11
    jae .try_rx             ; Nothing more to send

    ; Pick byte: from TX buffer or dummy 0
    xor eax, eax
    test rdi, rdi
    jz .send_dummy
    cmp r9, rsi
    jae .send_dummy
    mov al, byte [rdi + r9]
    jmp .do_tx
.send_dummy:
    xor eax, eax
.do_tx:
    mov [r8 + DW_SPI_DR], eax
    inc r9

.try_rx:
    ; --- RX: read byte if RX FIFO not empty ---
    ; Use timeout to avoid infinite loop when hardware is stuck or missing
    mov r12d, 10000 ; Skip if no data after reasonable spin
.wait_rx:
    mov eax, [r8 + DW_SPI_SR]
    test eax, 0x08          ; RFNE (RX FIFO not empty)
    jnz .do_rx
    dec r12d
    jnz .wait_rx
    ; Timeout: count this as a missed byte (0) so loop terminates
    inc r10
    jmp .xfer_loop

.do_rx:
    mov eax, [r8 + DW_SPI_DR]
    test rdx, rdx
    jz .skip_store
    cmp r10, rcx
    jae .skip_store
    mov byte [rdx + r10], al
.skip_store:
    inc r10
    jmp .xfer_loop

.xfer_done:
    ; Wait for not-busy
    mov r12d, 100000
.wait_idle:
    mov eax, [r8 + DW_SPI_SR]
    test eax, 0x01          ; BSY
    jz .xfer_ok
    dec r12d
    jnz .wait_idle
.xfer_ok:
    mov eax, 1
    jmp .xfer_ret
.fail_xfer:
    xor eax, eax
.xfer_ret:
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

section .data
global spi_base
global spi_type

; SPI type constants
SPI_TYPE_AMD_FCH    equ 1
SPI_TYPE_AMD_SFH    equ 2
SPI_TYPE_INTEL_GSPI equ 3

spi_base:   dq 0            ; MMIO base address of active SPI controller
spi_type:   db 0            ; SPI_TYPE_* above
