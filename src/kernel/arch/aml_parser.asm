; ============================================================================
; Grit v3.0 - AML Bytecode Interpreter
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

; aml_init
; In:  RSI = DSDT pointer (ACPI SDT: 36-byte header then AML body)
; Out: aml_dsdt_base / aml_dsdt_end define the AML scan window [base,end)
; Contract: caller guarantees the 36-byte header at RSI is mapped/readable.
; Security: table length at offset 4 is firmware/attacker-controlled. We REQUIRE
; length >= 36 (the header itself), otherwise end would land below base and the
; window would be ill-formed. A short/corrupt table yields an empty window so
; aml_find_object never scans. Fail-closed, logless.
aml_init:
    mov ecx, [rsi + 4]          ; ACPI table length (offset 4, 32-bit -> zero-extends RCX)
    cmp ecx, 36                 ; must at least cover the SDT header
    jb  .bad

    lea rax, [rsi + 36]         ; AML body begins after the 36-byte header
    mov [aml_dsdt_base], rax

    add rcx, rsi                ; end = table_base + length  (>= base, since length >= 36)
    mov [aml_dsdt_end], rcx
    ret

.bad:
    ; Corrupt/short table: install an empty window (base == end == 0).
    ; aml_find_object then computes available == 0 and returns "not found".
    xor eax, eax
    mov [aml_dsdt_base], rax
    mov [aml_dsdt_end], rax
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

    ; A match consumes 5 bytes: NameOp(1) + NameString(4) at [r8 .. r8+4].
    ; Reject windows that cannot hold one (closes both the short-table and the
    ; end<=base cases from a corrupt aml_init).  available = end - base.
    mov rax, r9
    sub rax, r8                 ; available bytes (unsigned)
    jbe .not_found              ; end <= base  -> empty / corrupt window
    cmp rax, 5
    jb  .not_found              ; < 5 bytes -> no complete NameOp+NameString fits

    ; Inclusive scan limit: largest r8 for which [r8 .. r8+4] stays in-bounds.
    ; Proven safe (end >= base+5), so this cannot underflow below base.
    sub r9, 5                   ; r9 = end - 5

    mov eax, edi                ; search pattern (zero-extended into RAX)

.scan_loop:
    cmp r8, r9
    ja .not_found               ; r8 > end-5 -> 5-byte read would pass end

    ; NameOp is 0x08 in AML.  In-bounds: r8 <= end-5 < end.
    cmp byte [r8], 0x08
    jne .next_byte

    ; Matches NameString?  In-bounds: r8+1..r8+4 <= end-1.
    mov ebx, dword [r8 + 1]
    cmp ebx, eax
    je .found

.next_byte:
    inc r8
    jmp .scan_loop

.found:
    ; Return the pointer to the DataRefObject following the NameString.
    ; r8 <= end-5  =>  r8+5 <= end, so the returned pointer is within [base,end].
    ; NOTE: bounds of the object *at* that pointer are the caller's contract
    ; (see acpi.asm _CRS window scan) -- tracked as a cross-file residual.
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
