; ============================================================================
; NexusOS v3.0 - AML Bytecode Interpreter
; Evaluates basic ACPI Machine Language objects like _HID, _CRS
; ============================================================================
bits 64

%include "constants.inc"

section .data
global aml_dsdt_base
global aml_dsdt_end
aml_dsdt_base dq 0
aml_dsdt_end  dq 0

section .text
global aml_init
global aml_find_object
global aml_evaluate

; RSI = DSDT pointer (beginning with "DSDT", length, etc)
aml_init:
    ; Table length is at offset 4
    mov ecx, [rsi + 4]
    
    ; The actual AML code starts at offset 36
    lea rax, [rsi + 36]
    mov [aml_dsdt_base], rax
    
    add rcx, rsi
    mov [aml_dsdt_end], rcx
    ret

; ============================================================================
; aml_find_object
; Scans DSDT for a 4-byte ACPI NameString (e.g. "_HID" or "_CRS")
; RDI = exact 4-byte string (padded with spaces if shorter)
; Returns EAX = pointer to object in memory, or 0 if not found
; ============================================================================
aml_find_object:
    push rbx
    push rcx
    push rdi
    push r8
    push r9
    
    mov r8, [aml_dsdt_base]
    mov r9, [aml_dsdt_end]
    mov eax, edi ; Search pattern

.scan_loop:
    cmp r8, r9
    jae .not_found
    
    ; NameOp is 0x08 in AML
    cmp byte [r8], 0x08
    jne .next_byte
    
    ; Matches NameString?
    mov ebx, dword [r8 + 1]
    cmp ebx, eax
    je .found
    
.next_byte:
    inc r8
    jmp .scan_loop

.found:
    ; Return the pointer to the DataRefObject following the NameString
    lea rax, [r8 + 5]
    jmp .done
    
.not_found:
    xor eax, eax

.done:
    pop r9
    pop r8
    pop rdi
    pop rcx
    pop rbx
    ret

; Legacy evaluate stub
aml_evaluate:
    xor eax, eax
    ret
