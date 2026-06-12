; ============================================================================
; Grit v3.0 - ACPI Table Setup
; Discovers and parses FACP, MADT, MCFG, DSDT/SSDT config
; ============================================================================
bits 64

%include "constants.inc"

extern rsdp_find
extern madt_init
extern acpi_pci_init
extern aml_init
extern aml_find_object
extern spi_base
extern touchpad_irq

section .text
global acpi_init

acpi_init:
    push rbx
    push rcx
    push rsi
    push rdi

    call rsdp_find
    test rax, rax
    jz .done            ; RSDP not found

    ; Extract XSDT pointer (offset 24) for ACPI 2.0+
    mov rsi, qword [rax + 24]
    test rsi, rsi
    jnz .got_xsdt
    
    ; Fallback to RSDT (offset 16) for legacy
    mov esi, dword [rax + 16]
    test rsi, rsi
    jz .done

.got_xsdt:
    ; Table Header:
    ; +0: Signature
    ; +4: Length (dword)
    ; Let's parse entries directly after header (length - 36)
    mov ecx, [rsi + 4]
    sub ecx, 36         ; Subtract header size to get entries length
    
    ; If it's XSDT, entries are 64-bit. If RSDT, 32-bit.
    mov eax, [rsi]
    cmp eax, 'XSDT'
    je .parse_xsdt

.parse_rsdt:
    shr ecx, 2          ; Divide by 4 (32-bit pointers)
    lea rbx, [rsi + 36]
    jmp .loop_tables

.parse_xsdt:
    shr ecx, 3          ; Divide by 8 (64-bit pointers)
    lea rbx, [rsi + 36]

.loop_tables:
    test ecx, ecx
    jz .done

    ; Load pointer (32 or 64 bit depending on table type)
    mov eax, [rsi]
    cmp eax, 'XSDT'
    je .load_xsdt_entry

.load_rsdt_entry:
    mov edi, dword [rbx]
    add rbx, 4
    jmp .handle_entry

.load_xsdt_entry:
    mov rdi, qword [rbx]
    add rbx, 8

.handle_entry:
    
    ; Check the table signature
    mov eax, dword [rdi]
    cmp eax, 'APIC'
    je .handle_madt
    cmp eax, 'MCFG'
    je .handle_mcfg
    cmp eax, 'FACP'
    je .handle_facp
    
.next_table:
    dec ecx
    jmp .loop_tables

.handle_madt:
    push rsi
    mov rsi, rdi
    call madt_init
    pop rsi
    jmp .next_table

.handle_mcfg:
    push rsi
    mov rsi, rdi
    call acpi_pci_init
    pop rsi
    jmp .next_table

.handle_facp:
    push rsi
    push rdi
    push rcx                ; preserve outer-loop counter across AML callees
    ; DSDT pointer is at FADT offset 40 (32-bit physical address)
    mov esi, [rdi + 40]
    test rsi, rsi
    jz .facp_done

    ; Setup AML parser bounds
    call aml_init

    ; Search for Touchpad: Try ELAN (Elantech)
    mov edi, 'ELAN'
    call aml_find_object
    test eax, eax
    jnz .found_touchpad

    ; Fallback: Try SYNA (Synaptics)
    mov edi, 'SYNA'
    call aml_find_object
    test eax, eax
    jnz .found_touchpad     ; SYNA found - use it (was previously discarded)

    ; Fallback: Try FTE (FocalTech)
    mov edi, 'FTE'
    call aml_find_object
    test eax, eax
    jz .facp_done
    
.found_touchpad:
    ; Search raw AML bytes near object for _CRS hardware descriptor packets
    mov rsi, rax
    mov rcx, 1024  ; Search window (generous size for trackpad components)
    
.scan_resources:
    test rcx, rcx
    jz .facp_done
    
    cmp byte [rsi], 0x86  ; Memory32Fixed Resource Descriptor (Length = 9)
    jne .check_irq
    
    ; Base address offset is 4
    mov edx, [rsi + 4]
    mov qword [spi_base], rdx  ; spi_base is DQ
    jmp .next_scan
    
.check_irq:
    cmp byte [rsi], 0x89  ; Extended Interrupt Resource Descriptor (Length >= 5)
    jne .next_scan
    
    ; IRQ offset is 5
    mov dx, [rsi + 5]
    mov word [touchpad_irq], dx  ; touchpad_irq is DW
    
.next_scan:
    inc rsi
    dec rcx
    jmp .scan_resources

.facp_done:
    pop rcx
    pop rdi
    pop rsi
    jmp .next_table

.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret
