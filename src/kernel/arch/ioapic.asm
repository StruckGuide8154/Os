; ============================================================================
; NexusOS v3.0 - I/O APIC Driver
; Used for routing hardware interrupts from advanced controllers
; ============================================================================
bits 64

%include "constants.inc"
%include "arch_regs.inc"

section .data
global ioapic_base
global touchpad_irq
ioapic_base dq IOAPIC_DEFAULT_BASE
touchpad_irq dw 18

section .text
global ioapic_init
global ioapic_set_irq

; --- Initialize I/O APIC ---
ioapic_init:
    ; Base address is obtained from MADT, but we configure essential routes now
    push rbx
    push rdi
    push rsi
    push rdx
    push rcx

    ; 1. Route all first 16 GSIs (ISA range) to standard vectors (32-47)
    ; This covers PIT on GSI 0 or 2, Keyboard on GSI 1, Mouse on GSI 12, etc.
    ; rbx is callee-saved (preserved across ioapic_set_irq's internal r8 clobber).
    xor ebx, ebx
.loop_gsis:
    mov rdi, rbx            ; GSI
    lea rsi, [rbx + 32]     ; Vector (32, 33, ...)
    mov rdx, 0              ; Destination: CPU 0
    mov rcx, 0              ; Flags: Edge, High, Physical
    call ioapic_set_irq
    inc rbx
    cmp rbx, 16
    jl .loop_gsis

    ; 2. Route PS/2 Mouse specifically to Vector 44 (GSI 12) - redundancy
    mov rdi, 12
    mov rsi, 44
    mov rdx, 0
    mov rcx, 0      ; Edge, High
    call ioapic_set_irq

    ; 3. Route SPI Touchpad specifically to Vector 50
    movzx edi, word [touchpad_irq]
    mov rsi, 50
    mov rdx, 0
    mov rcx, 0xA000 ; Level, Low
    call ioapic_set_irq
    
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbx
    ret

; --- ioapic_read ---
; rdi = index
ioapic_read:
    mov r8, [ioapic_base]
    mov dword [r8], edi
    mov eax, [r8 + 0x10]
    ret

; --- ioapic_write ---
; rdi = index, rsi = value
ioapic_write:
    mov r8, [ioapic_base]
    mov dword [r8], edi
    mov dword [r8 + 0x10], esi
    ret

; --- Route IRQ ---
; rdi = IRQ number
; rsi = Vector
; rdx = CPU APIC ID
; rcx = Flags (0 = Edge High, 0x8000 = Level High, 0x2000 = Edge Low, 0xA000 = Level Low)
ioapic_set_irq:
    push rbx
    
    ; Register offset = 0x10 + (IRQ * 2)
    mov rbx, rdi
    shl rbx, 1
    add rbx, 0x10
    
    ; Lower DWORD (Vector + Masks + Trigger Mode)
    mov rdi, rbx
    
    ; Combine Vector (rsi) and Flags (rcx)
    ; Bit 13 = Polarity (0=High, 1=Low)
    ; Bit 15 = Trigger Mode (0=Edge, 1=Level)
    ; Bit 16 = Mask (0=Unmasked, 1=Masked)
    push rsi
    or rsi, rcx
    call ioapic_write

    ; Upper DWORD (Destination CPU APIC ID)
    mov rdi, rbx
    inc rdi
    mov rsi, rdx
    shl rsi, 24
    call ioapic_write
    
    pop rsi
    pop rbx
    ret
