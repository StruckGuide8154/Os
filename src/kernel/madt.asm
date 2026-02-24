; ============================================================================
; NexusOS v3.0 - MADT Parser
; Used for parsing ACPI Multiple APIC Description Table
; ============================================================================
bits 64

%include "constants.inc"

extern ioapic_base
extern debug_print

section .text
global madt_init

; RSI = pointer to MADT table (starts with signature "APIC", length, revision...)
madt_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    
    ; MADT Header size is 44 bytes
    ; +0: Signature (4)
    ; +4: Length (4)
    ; ...
    ; +36: Local APIC Address (4)
    ; +40: Flags (4)
    
    mov ecx, [rsi + 4]      ; Total table length
    
    lea rbx, [rsi + 44]     ; First entry
    add rcx, rsi            ; End of table
    
.scan_loop:
    cmp rbx, rcx
    jae .done
    
    movzx eax, byte [rbx]   ; Type
    movzx edx, byte [rbx + 1] ; Length
    
    cmp eax, 0              ; Type 0: Local APIC
    je .next
    cmp eax, 1              ; Type 1: I/O APIC
    je .found_ioapic
    cmp eax, 2              ; Type 2: Interrupt Source Override
    je .found_iso
    
    jmp .next

.found_ioapic:
    ; +2: I/O APIC ID
    ; +3: Reserved
    ; +4: I/O APIC Address (4 bytes)
    ; +8: Global System Interrupt Base (4 bytes)
    mov eax, [rbx + 4]
    mov [ioapic_base], rax
    jmp .next

.found_iso:
    ; +2: Bus Source (usually 0 = ISA)
    ; +3: IRQ Source
    ; +4: Global System Interrupt (4 bytes)
    ; +8: Flags (2 bytes)
    ; Save these overrides for routing later
    jmp .next

.next:
    add rbx, rdx            ; Advance to next entry
    jmp .scan_loop

.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
