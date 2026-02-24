; ============================================================================
; NexusOS v3.0 - Interrupt Service Routines
; Exception handlers (0-31) and IRQ stubs (0-15 -> vectors 32-47)
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

section .text

extern pic_eoi_master, pic_eoi_slave
extern pit_handler
extern keyboard_handler
extern mouse_handler
extern i2c_hid_poll
extern spi_hid_poll
extern apic_eoi

; ============================================================================
; Exception ISR Stubs (0-31)
; ============================================================================
; Exceptions WITHOUT error code
ISR_NOERRCODE 0     ; Divide by zero
ISR_NOERRCODE 1     ; Debug
ISR_NOERRCODE 2     ; NMI
ISR_NOERRCODE 3     ; Breakpoint
ISR_NOERRCODE 4     ; Overflow
ISR_NOERRCODE 5     ; Bound range exceeded
ISR_NOERRCODE 6     ; Invalid opcode
ISR_NOERRCODE 7     ; Device not available
ISR_ERRCODE   8     ; Double fault (has error code)
ISR_NOERRCODE 9     ; Coprocessor segment overrun
ISR_ERRCODE   10    ; Invalid TSS
ISR_ERRCODE   11    ; Segment not present
ISR_ERRCODE   12    ; Stack segment fault
ISR_ERRCODE   13    ; General protection fault
ISR_ERRCODE   14    ; Page fault
ISR_NOERRCODE 15    ; Reserved
ISR_NOERRCODE 16    ; x87 floating point
ISR_ERRCODE   17    ; Alignment check
ISR_NOERRCODE 18    ; Machine check
ISR_NOERRCODE 19    ; SIMD floating point
ISR_NOERRCODE 20    ; Virtualization
ISR_NOERRCODE 21    ; Reserved
ISR_NOERRCODE 22
ISR_NOERRCODE 23
ISR_NOERRCODE 24
ISR_NOERRCODE 25
ISR_NOERRCODE 26
ISR_NOERRCODE 27
ISR_NOERRCODE 28
ISR_NOERRCODE 29
ISR_ERRCODE   30    ; Security exception
ISR_NOERRCODE 31

; Common ISR handler for exceptions
global isr_common_stub
isr_common_stub:
    PUSH_ALL

    ; Stack frame (after PUSH_ALL):
    ; [rsp+120] = interrupt number
    ; [rsp+128] = error code
    ; [rsp+136] = RIP
    ; [rsp+144] = CS
    ; [rsp+152] = RFLAGS

    ; For now, just paint a red pixel at top-left to indicate exception and halt
    mov rdi, [0x9000]        ; Framebuffer address
    mov dword [rdi], 0x000000FF  ; Red pixel (BGRA)
    mov dword [rdi+4], 0x000000FF
    mov dword [rdi+8], 0x000000FF

    ; Write exception number as colored pixels
    mov rax, [rsp + 120]     ; Interrupt number
    shl rax, 2               ; * 4 bytes per pixel
    add rax, 16              ; Offset from start
    add rdi, rax
    mov dword [rdi], 0x0000FFFF  ; Yellow pixel at position = exception#

    POP_ALL
    add rsp, 16              ; Pop error code and interrupt number
    iretq

; ============================================================================
; IRQ Stubs (0-15 -> vectors 32-47)
; ============================================================================
IRQ_STUB 0, 32     ; Timer (PIT)
IRQ_STUB 1, 33     ; Keyboard
IRQ_STUB 2, 34     ; Cascade
IRQ_STUB 3, 35     ; COM2
IRQ_STUB 4, 36     ; COM1
IRQ_STUB 5, 37     ; LPT2
IRQ_STUB 6, 38     ; Floppy
IRQ_STUB 7, 39     ; LPT1 / Spurious
IRQ_STUB 8, 40     ; CMOS RTC
IRQ_STUB 9, 41     ; Free
IRQ_STUB 10, 42    ; Free
IRQ_STUB 11, 43    ; Free
IRQ_STUB 12, 44    ; PS/2 Mouse
IRQ_STUB 13, 45    ; FPU
IRQ_STUB 14, 46    ; Primary ATA
IRQ_STUB 15, 47    ; Secondary ATA
IRQ_STUB 18, 50    ; Advanced Touchpad (APIC)

; Common IRQ handler
global irq_common_stub
irq_common_stub:
    PUSH_ALL

    ; Get IRQ number from interrupt vector on stack
    mov rax, [rsp + 120]     ; Interrupt vector number

    ; Dispatch to device-specific handler
    cmp rax, 32
    je .irq_timer
    cmp rax, 33
    je .irq_keyboard
    cmp rax, 44
    je .irq_mouse
    cmp rax, 50
    je .irq_apic_touchpad

    ; Unhandled IRQ - just send EOI
    jmp .send_eoi

.irq_timer:
    call pit_handler
    call apic_eoi
    jmp .done

.irq_keyboard:
    call keyboard_handler
    call apic_eoi
    jmp .done

.irq_mouse:
    call mouse_handler
    call apic_eoi
    jmp .done

.send_eoi:
    ; Check if slave PIC needs EOI (IRQ >= 40)
    cmp rax, 40
    jl .send_eoi_master
    call pic_eoi_slave
    jmp .done

.send_eoi_master:
    call pic_eoi_master
    jmp .done

.irq_apic_touchpad:
    call i2c_hid_poll
    call spi_hid_poll
    call apic_eoi
    jmp .done

.done:
    POP_ALL
    add rsp, 16              ; Pop error code and interrupt number
    iretq
