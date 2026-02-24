; ============================================================================
; NexusOS v3.0 - Interrupt Descriptor Table (64-bit Long Mode)
; 256 entries, each 16 bytes
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

section .text

; External ISR/IRQ handler addresses (defined in isr.asm)
extern isr_0, isr_1, isr_2, isr_3, isr_4, isr_5, isr_6, isr_7
extern isr_8, isr_9, isr_10, isr_11, isr_12, isr_13, isr_14
extern isr_15, isr_16, isr_17, isr_18, isr_19, isr_20, isr_21
extern isr_22, isr_23, isr_24, isr_25, isr_26, isr_27, isr_28
extern isr_29, isr_30, isr_31
extern irq_0, irq_1, irq_2, irq_3, irq_4, irq_5, irq_6, irq_7
extern irq_8, irq_9, irq_10, irq_11, irq_12, irq_13, irq_14, irq_15, irq_18

; --- Set one IDT entry ---
; RDI = entry index (0-255)
; RSI = handler address
idt_set_entry:
    push rbx
    ; Calculate entry address: IDT_ADDR + index * 16
    mov rax, rdi
    shl rax, 4              ; * 16
    lea rbx, [IDT_ADDR + rax]

    ; Entry format (16 bytes):
    ; [0-1]  Offset[15:0]
    ; [2-3]  Segment selector (code segment = 0x08)
    ; [4]    IST (0)
    ; [5]    Type/Attr (0x8E = present, ring0, interrupt gate)
    ; [6-7]  Offset[31:16]
    ; [8-11] Offset[63:32]
    ; [12-15] Reserved (0)

    mov rax, rsi             ; Handler address
    mov word [rbx], ax       ; Offset[15:0]
    mov word [rbx + 2], 0x08 ; Code segment selector
    mov byte [rbx + 4], 0    ; IST = 0
    mov byte [rbx + 5], 0x8E ; Type: present, DPL=0, interrupt gate
    shr rax, 16
    mov word [rbx + 6], ax   ; Offset[31:16]
    shr rax, 16
    mov dword [rbx + 8], eax ; Offset[63:32]
    mov dword [rbx + 12], 0  ; Reserved

    pop rbx
    ret

; --- Initialize IDT ---
global idt_init
idt_init:
    push rbx
    push r12

    ; Clear entire IDT (256 * 16 = 4096 bytes)
    mov rdi, IDT_ADDR
    xor rax, rax
    mov rcx, 4096 / 8
    rep stosq

    ; Set exception handlers (ISR 0-31)
    mov rdi, 0
    lea rsi, [isr_0]
    call idt_set_entry

    mov rdi, 1
    lea rsi, [isr_1]
    call idt_set_entry

    mov rdi, 2
    lea rsi, [isr_2]
    call idt_set_entry

    mov rdi, 3
    lea rsi, [isr_3]
    call idt_set_entry

    mov rdi, 4
    lea rsi, [isr_4]
    call idt_set_entry

    mov rdi, 5
    lea rsi, [isr_5]
    call idt_set_entry

    mov rdi, 6
    lea rsi, [isr_6]
    call idt_set_entry

    mov rdi, 7
    lea rsi, [isr_7]
    call idt_set_entry

    mov rdi, 8
    lea rsi, [isr_8]
    call idt_set_entry

    mov rdi, 9
    lea rsi, [isr_9]
    call idt_set_entry

    mov rdi, 10
    lea rsi, [isr_10]
    call idt_set_entry

    mov rdi, 11
    lea rsi, [isr_11]
    call idt_set_entry

    mov rdi, 12
    lea rsi, [isr_12]
    call idt_set_entry

    mov rdi, 13
    lea rsi, [isr_13]
    call idt_set_entry

    mov rdi, 14
    lea rsi, [isr_14]
    call idt_set_entry

    mov rdi, 15
    lea rsi, [isr_15]
    call idt_set_entry

    mov rdi, 16
    lea rsi, [isr_16]
    call idt_set_entry

    mov rdi, 17
    lea rsi, [isr_17]
    call idt_set_entry

    mov rdi, 18
    lea rsi, [isr_18]
    call idt_set_entry

    mov rdi, 19
    lea rsi, [isr_19]
    call idt_set_entry

    mov rdi, 20
    lea rsi, [isr_20]
    call idt_set_entry

    mov rdi, 21
    lea rsi, [isr_21]
    call idt_set_entry

    mov rdi, 22
    lea rsi, [isr_22]
    call idt_set_entry

    mov rdi, 23
    lea rsi, [isr_23]
    call idt_set_entry

    mov rdi, 24
    lea rsi, [isr_24]
    call idt_set_entry

    mov rdi, 25
    lea rsi, [isr_25]
    call idt_set_entry

    mov rdi, 26
    lea rsi, [isr_26]
    call idt_set_entry

    mov rdi, 27
    lea rsi, [isr_27]
    call idt_set_entry

    mov rdi, 28
    lea rsi, [isr_28]
    call idt_set_entry

    mov rdi, 29
    lea rsi, [isr_29]
    call idt_set_entry

    mov rdi, 30
    lea rsi, [isr_30]
    call idt_set_entry

    mov rdi, 31
    lea rsi, [isr_31]
    call idt_set_entry

    ; Set IRQ handlers (vectors 32-47)
    mov rdi, 32
    lea rsi, [irq_0]
    call idt_set_entry

    mov rdi, 33
    lea rsi, [irq_1]
    call idt_set_entry

    mov rdi, 34
    lea rsi, [irq_2]
    call idt_set_entry

    mov rdi, 35
    lea rsi, [irq_3]
    call idt_set_entry

    mov rdi, 36
    lea rsi, [irq_4]
    call idt_set_entry

    mov rdi, 37
    lea rsi, [irq_5]
    call idt_set_entry

    mov rdi, 38
    lea rsi, [irq_6]
    call idt_set_entry

    mov rdi, 39
    lea rsi, [irq_7]
    call idt_set_entry

    mov rdi, 40
    lea rsi, [irq_8]
    call idt_set_entry

    mov rdi, 41
    lea rsi, [irq_9]
    call idt_set_entry

    mov rdi, 42
    lea rsi, [irq_10]
    call idt_set_entry

    mov rdi, 43
    lea rsi, [irq_11]
    call idt_set_entry

    mov rdi, 44
    lea rsi, [irq_12]
    call idt_set_entry

    mov rdi, 45
    lea rsi, [irq_13]
    call idt_set_entry

    mov rdi, 46
    lea rsi, [irq_14]
    call idt_set_entry

    mov rdi, 47
    lea rsi, [irq_15]
    call idt_set_entry

    mov rdi, 50
    lea rsi, [irq_18]
    call idt_set_entry

    ; Load IDT
    lea rax, [idt_ptr]
    lidt [rax]

    pop r12
    pop rbx
    ret

section .data
align 16
idt_ptr:
    dw (256 * 16) - 1       ; Limit (4095)
    dq IDT_ADDR              ; Base address
