; ============================================================================
; NexusOS v3.0 - ACPI RSDP Locator
; Locates the Root System Description Pointer from memory/UEFI
; ============================================================================
bits 64

%include "constants.inc"

section .text
global rsdp_find

; Returns RAX = pointer to RSDP, or 0 if not found
rsdp_find:
    push rbx
    push rcx
    push rsi
    push rdi

    ; Range 1: E0000h to FFFFFh
    mov rsi, 0xE0000
    mov rcx, 0x1FFFF / 16
.scan1:
    cmp dword [rsi], 'RSD '
    jne .next1
    cmp dword [rsi+4], 'PTR '
    je .found
.next1:
    add rsi, 16
    dec rcx
    jnz .scan1

    ; Range 2: EBDA (find base first)
    ; In UEFI we usually get ACPI table from EFI System Table instead.
    ; But for fallback standard memory scanning:
    movzx rsi, word [0x040E] ; EBDA segment
    shl rsi, 4
    test rsi, rsi
    jz .fail
    mov rcx, 1024 / 16       ; Scam 1KB
.scan2:
    cmp dword [rsi], 'RSD '
    jne .next2
    cmp dword [rsi+4], 'PTR '
    je .found
.next2:
    add rsi, 16
    dec rcx
    jnz .scan2

.fail:
    xor eax, eax
    jmp .done

.found:
    mov rax, rsi
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret
