; ============================================================================
; NexusOS v3.0 - ACPI PCI Enumerator (MCFG)
; Dynamically lists PCIe MMIO assignments using ACPI MCFG table
; ============================================================================
bits 64

%include "constants.inc"

section .data
global mcfg_base
mcfg_base dq 0

section .text
global acpi_pci_init

; RSI = pointer to MCFG table
acpi_pci_init:
    push rbx
    push rcx
    push rdx
    
    ; TableLength is at offset 4
    mov ecx, [rsi + 4]
    
    ; Base of Configuration space allocation structures is at offset 44
    lea rbx, [rsi + 44]
    add rcx, rsi    ; End of table
    
.scan:
    cmp rbx, rcx
    jae .done
    
    ; struct size = 16 bytes
    ; +0: Base address (8 bytes)
    ; +8: PCI Segment Group Number (2 bytes)
    ; +10: Start Bus Number (1 byte)
    ; +11: End Bus Number (1 byte)
    ; +12: Reserved (4 bytes)
    
    mov rax, [rbx]
    ; just store the first one for now (Segment 0)
    mov [mcfg_base], rax
    
    add rbx, 16
    jmp .scan

.done:
    pop rdx
    pop rcx
    pop rbx
    ret
