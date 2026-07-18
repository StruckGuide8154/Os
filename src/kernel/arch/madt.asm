; ============================================================================
; Grit v3.0 - MADT Parser
; Used for parsing ACPI Multiple APIC Description Table
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

; Serial char macro for debugging


extern ioapic_base
extern debug_print

; Upper clamp on the firmware-declared MADT total length. The table is bounded
; by the validated RSDP->XSDT chain (see rsdp.asm/acpi.asm audits), but the MADT's
; own Length field at [rsi+4] is firmware/attacker-controlled and read fresh here,
; so it is independently clamped (matches the acpi.asm 0x10000 entry-span clamp).
MADT_MAX_LEN equ 0x10000

; ----------------------------------------------------------------------------
; Memory-safety invariant (proven free of OOB / non-termination — see
;   security/audits/madt_asm.md):
;   * end  = rsi + min(Length, MADT_MAX_LEN), with Length >= 44 (else fail-closed).
;   * Loop head: rbx in [rsi+44, end].  A header read needs rbx+2 <= end (checked).
;   * Entry length edx is forced >= 2 (else fail-closed) AND rbx+edx <= end
;     (else fail-closed), so the whole entry lies in-table and rbx strictly
;     increases by >=2 each iteration -> the scan provably terminates.
;   * Each handler asserts edx >= (its max field offset+1) before any field read,
;     so every [rbx+k] access satisfies k < edx <= end-rbx, i.e. in-bounds.
; All bounds failures are fail-closed (stop the scan) and logless.
; ----------------------------------------------------------------------------

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

    mov ecx, [rsi + 4]      ; Total table length (zero-extended into rcx)
    cmp ecx, 44             ; must contain at least the 44-byte header
    jb .done                ; truncated/forged short table -> fail-closed
    cmp ecx, MADT_MAX_LEN   ; clamp an oversized/forged length
    jbe .len_ok
    mov ecx, MADT_MAX_LEN
.len_ok:
    lea rbx, [rsi + 44]     ; First entry
    add rcx, rsi            ; End of table = base + clamped length

.scan_loop:
    lea rax, [rbx + 2]      ; need the 2-byte (type,length) header in-table
    cmp rax, rcx
    ja .done                ; no room for a header -> done

    movzx eax, byte [rbx]   ; Type
    movzx edx, byte [rbx + 1] ; Length

    cmp edx, 2             ; a zero/one-length entry never advances rbx
    jb .done               ; -> would hang; fail-closed (guarantees termination)
    lea r8, [rbx + rdx]    ; entry must fit entirely within the table
    cmp r8, rcx
    ja .done               ; truncated entry past end -> fail-closed

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
    cmp edx, 8             ; spec LAPIC entry length; need [rbx+4] in-entry
    jb .next               ; malformed short entry -> skip (already in-bounds)
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
    ; x2APIC entry: +4 X2APIC ID, +8 Flags, +12 ACPI Processor UID (spec len 16).
    cmp edx, 16            ; need [rbx+8..11] (Flags) and [rbx+4..7] (ID) in-entry
    jb .next               ; malformed short entry -> skip
    inc dword [madt_lapic_count]
    mov eax, [rbx + 8]     ; Flags (was [rbx+12] = UID -> wrong field; corrected)
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
    cmp edx, 12           ; spec I/O APIC entry length; need [rbx+4..7] in-entry
    jb .next              ; malformed short entry -> skip (keep current base)
    mov eax, [rbx + 4]    ; I/O APIC physical MMIO address (firmware-trusted value)
    test eax, eax
    jz .next              ; reject a zero base -> keep IOAPIC_DEFAULT_BASE
    mov [ioapic_base], rax
    jmp .next

.found_iso:
    ; +2: Bus Source (usually 0 = ISA)
    ; +3: IRQ Source
    ; +4: Global System Interrupt (4 bytes)
    ; +8: Flags (2 bytes)
    ; If IRQ Source is 0 (Timer), log the Global System Interrupt
    cmp edx, 10           ; spec ISO entry length; need [rbx+3] and [rbx+4..7]
    jb .next              ; malformed short entry -> skip
    cmp byte [rbx + 3], 0
    jne .next

    ; Found Timer ISO
%ifndef RELEASE_BUILD
    ; Raw OUT diagnostic. The entry length lives in rdx and drives .next; the
    ; port write below would clobber it, so bracket the OUT with push/pop rdx.
    SER 'I'
    SER 'S'
    SER 'O'
    mov eax, [rbx + 4]
    add al, '0'
    push rdx
    mov edx, 0x3F8
    out dx, al
    pop rdx
%endif
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
align 8
; Allocated unconditionally: apic.asm reads madt_lapic_ids[] on every build
; (BSP apic id lookup), not only under GRIT_SMP, so the array must exist always.
madt_lapic_ids: times SMP_MAX_CORES db 0
