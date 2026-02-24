; ============================================================================
; NexusOS v3.0 - PCI Driver
; Basic mechanism to read/write PCI configuration space
; ============================================================================
bits 64

section .text

; --- Read 32-bit word from PCI Config Space ---
; Arguments:
;   RBX = Bus (8 bits) | Device (5 bits) | Function (3 bits) | Register (8 bits, must be dword aligned)
;         Format: 0000:bbbb:bbbb:dddd:dfff:rrrr:rr00
;         Actually standard format is:
;         Bit 31: Enable (1)
;         Bit 30-24: Reserved
;         Bit 23-16: Bus
;         Bit 15-11: Device
;         Bit 10-8: Function
;         Bit 7-2: Register (00- FC)
;
;   We'll take a packed address in EAX or separate args?
;   Let's use a simpler signature:
;   EAX = Packed Address (Bus << 16 | Dev << 11 | Func << 8 | Reg)
; Returns:
;   EAX = Value
global pci_read_conf_dword
pci_read_conf_dword:
    push rdx
    
    or eax, 0x80000000       ; Set Enable bit
    mov dx, 0xCF8
    out dx, eax
    
    mov dx, 0xCFC
    in eax, dx
    
    pop rdx
    ret

; --- Write 32-bit word to PCI Config Space ---
; Arguments:
;   EAX = Packed Address
;   ECX = Value
global pci_write_conf_dword
pci_write_conf_dword:
    push rdx
    
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    
    mov dx, 0xCFC
    mov eax, ecx
    out dx, eax
    
    pop rdx
    ret
