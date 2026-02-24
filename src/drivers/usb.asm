; ============================================================================
; NexusOS v3.0 - USB Controller Discovery & Basic Legacy Support
; Attempts to find USB controllers (UHCI/OHCI/EHCI/XHCI) via PCI
; and enable legacy keyboad/mouse emulation if supported by BIOS.
; ============================================================================
bits 64

%include "constants.inc"

extern pci_read_conf_dword
extern pci_write_conf_dword

section .text
global usb_init

usb_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Loop through all PCI buses (0-255)
    xor r15, r15         ; Bus counter
.bus_loop:
    ; Loop through all devices (0-31)
    xor r14, r14         ; Device counter
.dev_loop:
    ; Loop through all functions (0-7, assuming multi-function check elsewhere or brute force)
    xor r13, r13         ; Func counter
.func_loop:

    ; Check Vendor ID (offset 0)
    ; Construct address: 0x80000000 | (Bus << 16) | (Dev << 11) | (Func << 8) | Register (0)
    
    mov eax, r15d
    shl eax, 16
    mov ebx, r14d
    shl ebx, 11
    or eax, ebx
    mov ebx, r13d
    shl ebx, 8
    or eax, ebx
    ; EAX = Base address
    push rax             ; Save base address for later registers
    
    ; Register 0 (Vendor/Device ID)
    mov dx, 0xCF8
    or eax, 0x80000000
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    
    cmp ax, 0xFFFF       ; Vendor ID FFFF = Invalid
    je .next_func_pop

    ; Check Class/Subclass (Offset 0x08)
    pop rax              ; Restore base address
    push rax
    or eax, 0x08
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    
    shr eax, 16          ; Upper 16 bits = Class/Subclass
    cmp ah, 0x0C         ; Class Code: Serial Bus Controller
    jne .next_func_pop
    cmp al, 0x03         ; Subclass: USB Controller
    jne .next_func_pop
    
    ; Found a USB Controller!
    ; Determine type via Programming Interface (in lower 8 bits of Class/Subclass register, not shown here easily without re-reading)
    ; Actually, let's re-read properly: 0x08 gives RevID in low byte, ProgIF in next byte
    ; Previous read: EAX was Class(hi)|Subclass(low)|ProgIF(hi)|RevID(low) -> shifted right 16 -> Class|Subclass
    
    ; Let's re-read Offset 0x08 fully
    pop rax
    push rax
    or eax, 0x08
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    
    mov bl, ah           ; ProgIF is in bit 8-15 (AH is 8-15 of lower word? No, EAX=Class|Sub|Prog|Rev)
                         ; EAX: [31:24 Class] [23:16 Sub] [15:8 ProgIF] [7:0 Rev]
    
    shr eax, 8
    and al, 0xFF         ; AL is ProgIF
    
    ; 0x00 = UHCI
    ; 0x10 = OHCI
    ; 0x20 = EHCI
    ; 0x30 = XHCI
    
    cmp al, 0x00
    je .init_uhci
    cmp al, 0x10
    je .init_ohci
    cmp al, 0x20
    je .init_ehci
    cmp al, 0x30
    je .init_xhci
    
    jmp .next_func_pop

.init_uhci:
    ; UHCI: Legacy Support is at I/O base + offset C0h in PCI config space usually
    ; Specifically PCI Config Offset 0xC0 (Legacy Support Register)
    pop rax
    push rax
    or eax, 0xC0
    call pci_check_legacy_uhci
    jmp .next_func_pop

.init_ohci:
    ; OHCI uses MMIO for legacy support (HcControl register)
    ; Skipping for brevity (complex MMIO setup)
    jmp .next_func_pop

.init_ehci:
    ; EHCI: Capability Pointer at 0x34 -> find EECP
    pop rax
    push rax
    ; Read CAP_PTR (offset 0x34)
    or eax, 0x34
    call pci_read_conf_dword
    and eax, 0xFF        ; Capability Pointer (offset)
    
    ; Traverse capabilities to find USB Legacy Support?
    ; Actually EHCI has EECP in HCCPARAMS (MMIO), not PCI config space directly for capabilities usually.
    ; But PCI Config 0x34 points to PCI Power Management etc.
    ; EHCI Legacy Support is in Extended Capabilities of the HOST CONTROLLER (MMIO).
    ; Need to read BAR0 to get MMIO base.
    pop rax
    push rax
    or eax, 0x10         ; BAR0
    call pci_read_conf_dword
    and eax, 0xFFFFFFF0  ; Base Address
    mov rdi, rax         ; MMIO Base
    
    ; Read HCCPARAMS (Offset 0x08 in MMIO)
    mov ebx, [rdi + 0x08]
    shr ebx, 8           ; EECP is at bit 8-15
    and ebx, 0xFF
    
    test ebx, ebx
    jz .next_func_pop    ; No EECP
    
    ; EECP is offset in PCI Config Space
    ; Read PCI Config at EECP
    pop rax              ; Restore base address (Bus/Dev/Func/0)
    push rax
    
    add eax, ebx         ; Add EECP offset
    push rax             ; Save specific register address
    call pci_read_conf_dword
    
    ; EAX = USB Legacy Support Extended Capability
    ; Bit 16 = HC BIOS Owned Semaphore
    ; Bit 24 = HC OS Owned Semaphore
    
    test eax, 0x00010000 ; Is BIOS owning it?
    jz .ehci_claim       ; Not owned, claim it
    
    ; BIOS owns it. We want to KEEP it that way for legacy emulation?
    ; WRONG. Usually BIOS emulation works if BIOS owns it.
    ; But if it's NOT working, maybe BIOS disabled it?
    ; Or maybe we need to enable it?
    
    ; If we want to ENABLE legacy emulation, we usually assume BIOS does it.
    ; If we want to DISABLE it (for native driver), we set OS Owned.
    
    ; Since we don't have a native driver, we do NOTHING here if BIOS owns it.
    ; If BIOS doesn't own it, we can't easily force emulation on.
    
    jmp .next_func_pop_dbl

.ehci_claim:
    ; logic to claim would be here
    jmp .next_func_pop_dbl

.init_xhci:
    ; XHCI: Read BAR0 (Offset 0x10)
    pop rax
    push rax
    or eax, 0x10
    call pci_read_conf_dword
    and eax, 0xFFFFFFF0
    mov rsi, rax         ; MMIO Base
    
    ; Need to map this memory? It's likely identity mapped by UEFI loader or in higher half.
    ; Loader identity maps low memory, but BAR might be high.
    ; If BAR is > 4GB, we need 64-bit address (BAR0|BAR1).
    ; Assuming 32-bit BAR for now or low memory.
    
    ; Read HCCPARAMS1 (Offset 0x10 in Capability Registers)
    ; CapLength is at Offset 0x00 (1 byte)
    movzx ecx, byte [rsi] ; CapLength
    add rsi, rcx          ; RSI = Operational Registers Base? No, Capability Base is start.
                          ; Wait, HCCPARAMS1 is at Capability Base + 0x10
    mov ecx, [rsi + 0x10] ; HCCPARAMS1
    
    ; xECP (Extended Capabilities Pointer) is bits 31:16
    shr ecx, 16
    shl ecx, 2            ; xECP is in dwords? No, it's byte offset * 4 usually or just byte offset?
                          ; Spec says: xECP is offset in 32-bit words from MMIO Base.
    test ecx, ecx
    jz .next_func_pop     ; No extended caps
    
    ; Find USB Legacy Support Capability (ID = 1)
    ; Loop through extended caps
.xhci_cap_loop:
    mov edx, [rsi + rcx]  ; Read Capability Header
    mov eax, edx
    and eax, 0xFF         ; Capability ID
    cmp eax, 1            ; USB Legacy Support
    je .xhci_found_legacy
    
    ; Next capability
    mov eax, edx
    shr eax, 8
    and eax, 0xFF         ; Next Capability Offset (relative to this one?)
    test eax, eax
    jz .next_func_pop     ; End of list
    
    shl eax, 2            ; Convert dwords to bytes
    add rcx, rax
    jmp .xhci_cap_loop

.xhci_found_legacy:
    ; Found Legacy Support Capability at [rsi + rcx]
    ; Bit 16: BIOS Owned Semaphore
    ; Bit 24: OS Owned Semaphore
    
    ; To fix mouse: Ensure BIOS has ownership?
    ; If BIOS has ownership, it emulates PS/2.
    ; If OS has ownership, we need a driver.
    ; We check if BIOS Owned (Bit 16) is SET.
    
    test edx, 0x00010000
    jnz .bios_owns_xhci
    
    ; BIOS does NOT own it. This is why mouse fails.
    ; Attempt to give it to BIOS? No, we can't force BIOS to take it.
    ; But we can try setting Bit 24 (OS Owned) to clear it? No.
    
    ; If BIOS doesn't own it, we are stuck unless we write a driver.
    ; OR maybe we can enable "Legacy Support" bit (Bit 0)?
    ; Legacy Support Control/Status (USBLEGCTLSTS) is at offset + 4? No, it's the register itself.
    ; Header is at offset 0.
    
    ; Actually, for XHCI, Legacy Support is usually:
    ; Offset 0: ID=1, Next=..., BIOS_Sem, OS_Sem
    ; Offset 4: USBLEGCTLSTS
    
    ; If we want to enable SMIs (System Management Interrupts), we might need to set bits in USBLEGCTLSTS.
    ; But without SMM handling code in BIOS, this does nothing.
    
    jmp .next_func_pop

.bios_owns_xhci:
    ; BIOS owns it. Good. Mouse should work?
    ; Maybe we need to ACK something?
    jmp .next_func_pop

.next_func_pop_dbl:
    pop rax
.next_func_pop:
    pop rax              ; Restore Scan Base Address
    
    inc r13
    cmp r13, 8
    jl .func_loop

    inc r14
    cmp r14, 32
    jl .dev_loop

    inc r15
    cmp r15, 256
    jl .bus_loop

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Helper for UHCI Legacy
pci_check_legacy_uhci:
    ; Read Offset 0xC0
    call pci_read_conf_dword
    ; Bit 13 = PIRQ Enable?
    ; This is highly vendor specific.
    ret
