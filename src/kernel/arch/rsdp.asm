; ============================================================================
; Grit v3.0 - ACPI RSDP Locator
; Locates the Root System Description Pointer from memory/UEFI
; ============================================================================
; SECURITY (GSEC 2026-06-22): rsdp_find is the ROOT OF TRUST for the entire ACPI
; table chain. acpi_init dereferences [rsdp+24] (XsdtAddress) / [rsdp+16]
; (RsdtAddress) as the *base* of its SDT walk. acpi.asm bounds the SDT *length*
; but not that base, so accepting a forged/garbage RSDP hands the walker an
; attacker-chosen pointer (-> wild MADT IRQ / MCFG-PCI base / spi_base poisoning).
; A bare 8-byte "RSD PTR " signature match is NOT sufficient: the ACPI spec
; mandates a checksum. We now require the spec checksum(s) before returning a
; candidate, and we never let a checksum read run past the scanned region.
; Fail-closed + logless (no attacker bytes recorded).
; ============================================================================
bits 64

%include "constants.inc"
%include "arch_regs.inc"

section .text
global rsdp_find

; Returns RAX = pointer to a CHECKSUM-VALID RSDP, or 0 if not found
rsdp_find:
    push rbx
    push rcx
    push rsi
    push rdi

    ; Range 1: E0000h to FFFFFh
    mov rsi, RSDP_BIOS_SCAN_BASE
    mov rcx, RSDP_BIOS_SCAN_LEN / 16   ; 8192 paragraphs covers 0xE0000..0xFFFFF inclusive
    mov r11, RSDP_BIOS_SCAN_BASE + RSDP_BIOS_SCAN_LEN   ; region end (exclusive) = 0x100000
.scan1:
    cmp dword [rsi], 'RSD '
    jne .next1
    cmp dword [rsi+4], 'PTR '
    jne .next1
    call rsdp_validate          ; rsi=cand, r11=region end -> rax = cand or 0
    test rax, rax
    jnz .done                   ; rax already = validated pointer
.next1:
    add rsi, 16
    dec rcx
    jnz .scan1

    ; Range 2: EBDA (find base first)
    ; In UEFI we usually get ACPI table from EFI System Table instead.
    ; But for fallback standard memory scanning:
    movzx rsi, word [abs 0x040E] ; EBDA segment
    shl rsi, 4
    test rsi, rsi
    jz .fail
    lea r11, [rsi + 1024]        ; region end (exclusive) for the 1KB EBDA scan
    mov rcx, 1024 / 16           ; scan 1KB
.scan2:
    cmp dword [rsi], 'RSD '
    jne .next2
    cmp dword [rsi+4], 'PTR '
    jne .next2
    call rsdp_validate          ; rsi=cand, r11=region end -> rax = cand or 0
    test rax, rax
    jnz .done
.next2:
    add rsi, 16
    dec rcx
    jnz .scan2

.fail:
    xor eax, eax
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ----------------------------------------------------------------------------
; rsdp_validate — verify an ACPI RSDP candidate per spec.
;   in:  rsi = candidate (signature already matched), r11 = exclusive region end
;   out: rax = rsi if checksum-valid, else 0
;   clobbers: rax, r8, r9, r10  (preserves rsi, rcx, r11 — outer-loop state)
; Invariants enforced (fail-closed):
;   * the spanned bytes [rsi, rsi+len) lie fully inside [.., r11) -> no OOB read
;   * 8-bit sum of the first 20 bytes (ACPI 1.0 header) == 0
;   * if Revision (byte 15) >= 2: 33 <= Length <= 4096 AND 8-bit sum of the
;     first Length bytes == 0 (extended checksum)
; ----------------------------------------------------------------------------
rsdp_validate:
    ; --- bound: 20-byte v1 header must fit in the scanned region ---
    lea r8, [rsi + 20]
    cmp r8, r11
    ja  .reject
    ; --- 8-bit checksum over the 20-byte v1 structure ---
    mov r8, rsi
    mov r9d, 20
    xor r10d, r10d
.cs1:
    movzx eax, byte [r8]
    add r10b, al
    inc r8
    dec r9d
    jnz .cs1
    test r10b, r10b
    jnz .reject                 ; v1 checksum fail

    ; --- ACPI 1.0 RSDP (Revision < 2): 20-byte checksum is sufficient ---
    movzx eax, byte [rsi + 15]  ; Revision
    cmp al, 2
    jb  .accept

    ; --- ACPI 2.0+ : validate Length and the extended checksum ---
    mov r9d, [rsi + 20]         ; Length (dword, zero-extended into r9)
    cmp r9d, 33
    jb  .reject                 ; impossibly short extended RSDP
    cmp r9d, 4096
    ja  .reject                 ; implausibly large -> reject (bounds the sum loop)
    lea rax, [rsi + r9]         ; end of claimed structure
    cmp rax, r11
    ja  .reject                 ; would read past the scanned region
    mov r8, rsi
    xor r10d, r10d
.cs2:
    movzx eax, byte [r8]
    add r10b, al
    inc r8
    dec r9d
    jnz .cs2
    test r10b, r10b
    jnz .reject                 ; extended checksum fail

.accept:
    mov rax, rsi                ; validated candidate
    ret
.reject:
    xor eax, eax
    ret
