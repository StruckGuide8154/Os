; ============================================================================
; Grit v3.0 - Global Descriptor Table
; Three stages: 16-bit temp, 32-bit PM, 64-bit LM
; ============================================================================

%ifndef STAGE2_BUILD
%include "constants.inc"
%else
SMP_MAX_CORES equ 1
%endif

; --- 32-bit Protected Mode GDT (temporary, for transition) ---
align 16
gdt32_start:
    ; Null descriptor
    dq 0

gdt32_code:
    ; 32-bit code segment: base=0, limit=4GB, execute/read
    dw 0xFFFF               ; Limit[15:0]
    dw 0x0000               ; Base[15:0]
    db 0x00                 ; Base[23:16]
    db 10011010b            ; Access: present, ring0, code, exec/read
    db 11001111b            ; Flags: 4K granularity, 32-bit + Limit[19:16]
    db 0x00                 ; Base[31:24]

gdt32_data:
    ; 32-bit data segment: base=0, limit=4GB, read/write
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b            ; Access: present, ring0, data, read/write
    db 11001111b
    db 0x00
gdt32_end:

gdt32_ptr:
    dw gdt32_end - gdt32_start - 1
    dd gdt32_start

GDT32_CODE_SEG equ gdt32_code - gdt32_start
GDT32_DATA_SEG equ gdt32_data - gdt32_start

; --- 64-bit Long Mode GDT ---
align 16
gdt64_start:
    ; Null descriptor (Selector 0x00)
    dq 0

gdt64_code:
    ; 64-bit kernel code segment (Selector 0x08): L=1, D=0
    dw 0x0000               ; Limit[15:0] (ignored in 64-bit)
    dw 0x0000               ; Base[15:0]
    db 0x00                 ; Base[23:16]
    db 10011010b            ; Access: present, ring0, code, exec/read
    db 00100000b            ; Flags: L=1 (64-bit), D=0
    db 0x00                 ; Base[31:24]

gdt64_data:
    ; 64-bit kernel data segment (Selector 0x10)
    dw 0x0000
    dw 0x0000
    db 0x00
    db 10010010b            ; Access: present, ring0, data, read/write
    db 00000000b            ; Flags: none
    db 0x00

gdt64_user_code32:
    ; User 32-bit code placeholder (Selector 0x18) - required for sysret layout
    dq 0x00CFFA000000FFFF   ; Present, DPL=3, Code, 32-bit

gdt64_user_data:
    ; 64-bit user data segment (Selector 0x20): DPL=3, read/write
    dw 0x0000
    dw 0x0000
    db 0x00
    db 11110010b            ; Access: present, ring3, data, read/write
    db 00000000b            ; Flags: none
    db 0x00

gdt64_user_code64:
    ; 64-bit user code segment (Selector 0x28): DPL=3, L=1
    dw 0x0000
    dw 0x0000
    db 0x00
    db 11111010b            ; Access: present, ring3, code, exec/read
    db 00100000b            ; Flags: L=1, D=0
    db 0x00

gdt64_tss:
    ; 64-bit TSS descriptor for the BSP (Selector 0x30).
    ; Each subsequent AP gets its own TSS descriptor below; the per-core
    ; selector is 0x30 + core_idx * 16. tss.asm's tss_init_for_core walks
    ; this table and patches the per-core TSS base in at runtime.
    dw 103                  ; Limit (104 bytes - 1)
    dw 0                    ; Base low (filled at runtime)
    db 0                    ; Base mid 1
    db 10001001b            ; Access: Present, TSS Available
    db 0                    ; Flags + Limit High
    db 0                    ; Base mid 2
    dq 0                    ; Base high (remaining 32 bits + reserved)

gdt64_tss_ap:
    ; (SMP_MAX_CORES - 1) additional TSS slots, one per AP. Each is a 16-byte
    ; descriptor; bases stay zero until tss_init_for_core(idx) fills them in.
    times ((SMP_MAX_CORES - 1) * 2) dq 0

gdt64_end:

gdt64_ptr:
    dw gdt64_end - gdt64_start - 1
    dq gdt64_start          ; dq instead of dd dd to avoid upper bits confusion

GDT64_CODE_SEG  equ gdt64_code - gdt64_start
GDT64_DATA_SEG  equ gdt64_data - gdt64_start
GDT64_USER_DATA equ (gdt64_user_data - gdt64_start) | 3
GDT64_USER_CODE equ (gdt64_user_code64 - gdt64_start) | 3
GDT64_TSS       equ gdt64_tss - gdt64_start

%ifndef STAGE2_BUILD
section .text
; --- Re-load GDT from within kernel ---
global gdt64_init
bits 64
gdt64_init:
    push rax
    lea rax, [gdt64_ptr]
    lgdt [rax]
    
    ; Reload segments
    mov ax, GDT64_DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    
    ; Far jump to reload CS
    ; In 64-bit, we can use a direct push/retf
    lea rax, [.next]
    push qword GDT64_CODE_SEG
    push rax
    retfq
.next:
    pop rax
    ret
%endif
