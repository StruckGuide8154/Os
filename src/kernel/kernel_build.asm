; ============================================================================
; NexusOS v3.0 - Monolithic Kernel Build Wrapper
; Combines all kernel components into a single binary
; ============================================================================
[bits 64]
[org 0x100000]

; Define macros to ignore extern/global directives in included files
%macro extern 1
%endmacro

%macro global 1
%endmacro

; --- Core Kernel Entry Point (MUST BE FIRST) ---
section .text
%include "src/kernel/entry.asm"
%include "src/kernel/main.asm"
%include "src/kernel/idt.asm"
%include "src/kernel/isr.asm"
%include "src/kernel/memory.asm"
%include "src/kernel/pic.asm"
%include "src/kernel/pit.asm"

; --- ACPI & APIC Core ---
%include "src/kernel/rsdp.asm"
%include "src/kernel/acpi.asm"
%include "src/kernel/madt.asm"
%include "src/kernel/aml_parser.asm"
%include "src/kernel/apic.asm"
%include "src/kernel/ioapic.asm"

; --- Drivers ---
%include "src/drivers/acpi_pci.asm"
%include "src/drivers/acpi_ec.asm"
%include "src/drivers/display.asm"
%include "src/drivers/keyboard.asm"
%include "src/drivers/mouse.asm"
%include "src/drivers/ata.asm"
%include "src/drivers/pci.asm"
%include "src/drivers/xhci.asm"
%include "src/drivers/usb_hid.asm"
%include "src/drivers/spi.asm"
%include "src/drivers/spi_hid.asm"
%include "src/drivers/i2c_hid.asm"
%include "src/drivers/hid_parser.asm"
%include "src/drivers/battery.asm"

; --- Filesystem ---
%include "src/kernel/fat16.asm"

; --- GUI System ---
%include "src/gui/render.asm"
%include "src/gui/window.asm"
%include "src/gui/taskbar.asm"
%include "src/gui/desktop.asm"
%include "src/gui/cursor.asm"
%include "src/gui/apps.asm"

; --- Libraries ---
section .text
%include "src/lib/string.asm"
%include "src/lib/font.asm"
%include "src/lib/math.asm"

; --- Helper Wrappers ---
fn_memcpy_wrapper:
    jmp fn_memcpy
fn_memset_wrapper:
    jmp fn_memset
fn_strlen_wrapper:
    jmp fn_strlen

; Resolve symbols used by other modules
memcpy equ fn_memcpy
memset equ fn_memset
strlen equ fn_strlen

; --- BSS Section ---
section .bss
align 16
_bss_start:
; NASM aggregates sections, so all .bss from included files will end up here.
_bss_end:
