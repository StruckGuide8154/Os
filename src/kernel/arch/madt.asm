; ============================================================================
; GritOS v3.0 - MADT Parser
; Used for parsing ACPI Multiple APIC Description Table
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

; Serial char macro for debugging


extern ioapic_base
extern debug_print

section .text
global madt_init
global madt_lapic_count
global madt_enabled_cpu_count
global madt_lapic_ids

; RSI = pointer to MADT table (starts with signature "APIC", length, revision...)
madt_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    SER 'M'
    mov dword [madt_lapic_count], 0
    mov dword [madt_enabled_cpu_count], 0
    
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
    je .found_lapic
    cmp eax, 9              ; Type 9: x2APIC
    je .found_x2apic
    cmp eax, 1              ; Type 1: I/O APIC
    je .found_ioapic
    cmp eax, 2              ; Type 2: Interrupt Source Override
    je .found_iso
    
    jmp .next

.found_lapic:
    inc dword [madt_lapic_count]
    movzx eax, byte [rbx + 4] ; Flags
    test eax, 1             ; Processor enabled
    jnz .lapic_enabled
    test eax, 8             ; Online-capable
    jz .next
.lapic_enabled:
%ifdef GRIT_SMP
    ; rcx holds the table-end pointer; use rdi for the count to avoid clobber.
    mov edi, [madt_enabled_cpu_count]
    cmp edi, SMP_MAX_CORES
    jae .skip_store_lapic
    mov al, [rbx + 3]
    mov [madt_lapic_ids + rdi], al
.skip_store_lapic:
%endif
    inc dword [madt_enabled_cpu_count]
    jmp .next

.found_x2apic:
    inc dword [madt_lapic_count]
    mov eax, [rbx + 12]
    test eax, 1
    jnz .x2_enabled
    test eax, 8
    jz .next
.x2_enabled:
%ifdef GRIT_SMP
    mov edi, [madt_enabled_cpu_count]
    cmp edi, SMP_MAX_CORES
    jae .skip_store_x2
    mov eax, [rbx + 4]
    mov [madt_lapic_ids + rdi], al
.skip_store_x2:
%endif
    inc dword [madt_enabled_cpu_count]
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
    ; If IRQ Source is 0 (Timer), log the Global System Interrupt
    cmp byte [rbx + 3], 0
    jne .next
    
    ; Found Timer ISO
    SER 'I'
    SER 'S'
    SER 'O'
    mov eax, [rbx + 4]
    add al, '0'
    mov edx, 0x3F8
    out dx, al
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

section .data
align 4
madt_lapic_count: dd 0
madt_enabled_cpu_count: dd 0
%ifdef GRIT_SMP
align 8
madt_lapic_ids: times SMP_MAX_CORES db 0
%endif
