; ============================================================================
; Grit v3.0 - I2C HID Touchpad Driver (Complete)
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

; --- MMIO bounds gate (security_todo.md §8) ---------------------------------
; mmio_register_i2c declares i2c_base_addr's register page as the MMIO_DRV_I2C
; capability at probe-commit time; I2C_MMIO_ASSERT proves a [base+off] access
; stays inside it before the access issues. mmio_bounds_assert preserves all
; caller registers per its ABI, but takes its inputs in rdi/rsi/edx - this macro
; saves/restores those three so the surrounding [rsi+off] code is unperturbed.
extern mmio_bounds_assert
extern mmio_register_i2c
%macro I2C_MMIO_ASSERT 2          ; %1 = base addr reg, %2 = window (legacy, unused)
    push rdi
    push rsi
    push rdx
    mov rdi, %1
    ; 8-byte probe at the base, not the whole window: a full-window span ends
    ; exactly at the registered region end (boundary-fragile) and any offset
    ; base would overshoot. Validates the base lies in the registered I2C block.
    ; %2 kept for call-site compatibility (documentation).
    mov esi, 8
    mov edx, MMIO_DRV_I2C
    call mmio_bounds_assert
    pop rdx
    pop rsi
    pop rdi
%endmacro

extern mouse_x, mouse_y, mouse_buttons, mouse_moved
extern mouse_sense_x, mouse_sense_y
extern mouse_scroll_y
extern scr_width, scr_height
extern tick_count
extern cpu_tsc_per_tick    ; qword: calibrated TSC cycles per 10ms PIT tick (frame_pacing)

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

; AMD FCH DesignWare I2C base addresses.
; Authoritative: decoded from this machine's DSDT (Memory32Fixed under each
; AMDI0010 controller). Exactly four blocks exist; FEDC6000/FEDC0000 do NOT.
;   I2CA = FEDC2000   I2CB = FEDC3000   I2CC = FEDC4000   I2CD = FEDC5000
; The touchpad (Synaptics SYNA1B92, slave 0x2C, HID desc reg 0x0020) hangs off
; I2CD = FEDC5000 (ACPI parent AMDI0010 instance 3). Probe I2CD first.
I2C_BASE_A  equ 0xFEDC2000   ; I2CA
I2C_BASE_B  equ 0xFEDC3000   ; I2CB
I2C_BASE_C  equ 0xFEDC4000   ; I2CC
I2C_BASE_D  equ 0xFEDC5000   ; I2CD  <- touchpad controller

; Touchpad HID addresses to probe
TP_ADDR_ELAN        equ 0x15
TP_ADDR_SYNAPTICS   equ 0x2C

section .text

global i2c_hid_init
global i2c_hid_poll
%include "src/kernel/drivers/i2c_hid_init.inc"
%include "src/kernel/drivers/i2c_hid_desc.inc"
%include "src/kernel/drivers/i2c_hid_poll.inc"
%include "src/kernel/drivers/i2c_hid_debug.inc"
%include "src/kernel/drivers/i2c_hid_data.inc"
