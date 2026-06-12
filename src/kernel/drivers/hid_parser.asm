; ============================================================================
; GritOS v3.0 - HID Report Descriptor Parser & Gesture Engine
; Parses HID report descriptors to extract field layouts (X, Y, buttons,
; contact count, tip switch) and provides gesture detection (tap-to-click,
; two-finger scroll).
;
; Shared between USB HID, I2C HID, and SPI HID drivers.
; ============================================================================
bits 64

%include "constants.inc"

extern tick_count
extern mouse_buttons, mouse_moved

section .text

; ============================================================================
; HID Item Tag constants (byte & 0xFC to mask off bSize)
; ============================================================================
HID_USAGE_PAGE      equ 0x04    ; Global: Usage Page
HID_LOGICAL_MIN     equ 0x14    ; Global: Logical Minimum
HID_LOGICAL_MAX     equ 0x24    ; Global: Logical Maximum
HID_PHYSICAL_MIN    equ 0x34    ; Global: Physical Minimum
HID_PHYSICAL_MAX    equ 0x44    ; Global: Physical Maximum
HID_REPORT_SIZE     equ 0x74    ; Global: Report Size (bits per field)
HID_REPORT_ID       equ 0x84    ; Global: Report ID
HID_REPORT_COUNT    equ 0x94    ; Global: Report Count (number of fields)
HID_USAGE           equ 0x08    ; Local: Usage
HID_USAGE_MIN       equ 0x18    ; Local: Usage Minimum
HID_USAGE_MAX       equ 0x28    ; Local: Usage Maximum
HID_INPUT           equ 0x80    ; Main: Input
HID_COLLECTION      equ 0xA0   ; Main: Collection
HID_END_COLLECTION  equ 0xC0   ; Main: End Collection

; Usage Pages
UP_GENERIC_DESKTOP  equ 0x01
UP_BUTTON           equ 0x09
UP_DIGITIZER        equ 0x0D

; Usages (Generic Desktop)
USAGE_X             equ 0x30
USAGE_Y             equ 0x31

; Usages (Digitizer)
USAGE_TIP_SWITCH    equ 0x42
USAGE_CONTACT_ID    equ 0x51
USAGE_CONTACT_COUNT equ 0x54
USAGE_FINGER        equ 0x22
USAGE_TOUCHPAD      equ 0x05
USAGE_CONFIDENCE    equ 0x47    ; Digitizer Confidence (palm rejection)

; Input item flags
HID_INPUT_CONSTANT  equ (1 << 0)   ; 0=Data, 1=Constant
HID_INPUT_VARIABLE  equ (1 << 1)   ; 0=Array, 1=Variable
HID_INPUT_RELATIVE  equ (1 << 2)   ; 0=Absolute, 1=Relative
HID_MAX_REPORT_BITS equ (MOUSE_BUFFER_SIZE * 8)

%include "src/kernel/drivers/hid_parser_parse.inc"
%include "src/kernel/drivers/hid_parser_extract.inc"
%include "src/kernel/drivers/hid_parser_report.inc"
%include "src/kernel/drivers/hid_parser_gesture.inc"
