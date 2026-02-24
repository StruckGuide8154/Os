; ============================================================================
; NexusOS v3.0 - Global Descriptor Table
; Three stages: 16-bit temp, 32-bit PM, 64-bit LM
; ============================================================================

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
    ; Null descriptor
    dq 0

gdt64_code:
    ; 64-bit code segment: L=1, D=0
    dw 0x0000               ; Limit[15:0] (ignored in 64-bit)
    dw 0x0000               ; Base[15:0]
    db 0x00                 ; Base[23:16]
    db 10011010b            ; Access: present, ring0, code, exec/read
    db 00100000b            ; Flags: L=1 (64-bit), D=0
    db 0x00                 ; Base[31:24]

gdt64_data:
    ; 64-bit data segment
    dw 0x0000
    dw 0x0000
    db 0x00
    db 10010010b            ; Access: present, ring0, data, read/write
    db 00000000b            ; Flags: none
    db 0x00
gdt64_end:

gdt64_ptr:
    dw gdt64_end - gdt64_start - 1
    dd gdt64_start
    dd 0                    ; Upper 32 bits (for lgdt in 64-bit mode)

GDT64_CODE_SEG equ gdt64_code - gdt64_start
GDT64_DATA_SEG equ gdt64_data - gdt64_start
