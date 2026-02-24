; ============================================================================
; NexusOS v3.0 - Local APIC Driver
; Used for handling hardware interrupts on modern systems
; ============================================================================
bits 64

%include "constants.inc"

section .data
lapic_base dq 0xFEE00000

section .text
global apic_init
global apic_eoi

; --- Initialize Local APIC ---
apic_init:
    ; Read APIC base from MSR 0x1B
    mov ecx, 0x1B
    rdmsr
    
    ; Ensure APIC is enabled (bit 11)
    bts eax, 11
    wrmsr

    ; Map the APIC base (mask out lower 12 bits)
    and eax, 0xFFFFF000
    mov [lapic_base], rax

    ; Spurious Interrupt Vector Register (SIVR)
    ; Enable APIC (bit 8) and set vector to 255
    mov rdi, [lapic_base]
    mov dword [rdi + 0x0F0], 0x1FF
    
    ret

; --- Send End of Interrupt (EOI) ---
apic_eoi:
    mov rdi, [lapic_base]
    mov dword [rdi + 0x0B0], 0
    ret
