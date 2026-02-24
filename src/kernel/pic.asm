; ============================================================================
; NexusOS v3.0 - 8259A PIC Driver
; Remaps IRQs to vectors 32-47, provides EOI and masking
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

section .text

; --- Initialize and remap the 8259A PICs ---
; Master PIC: IRQs 0-7 -> vectors 32-39
; Slave PIC:  IRQs 8-15 -> vectors 40-47
global pic_init
pic_init:
    ; Save current masks
    in al, 0x21
    mov [pic_mask_save], al
    in al, 0xA1
    mov [pic_mask_save + 1], al

    ; ICW1: Initialize + ICW4 needed
    mov al, 0x11
    out 0x20, al            ; Master command
    call .io_wait
    out 0xA0, al            ; Slave command
    call .io_wait

    ; ICW2: Vector offsets
    mov al, IRQ_BASE_MASTER ; 32
    out 0x21, al            ; Master data
    call .io_wait
    mov al, IRQ_BASE_SLAVE  ; 40
    out 0xA1, al            ; Slave data
    call .io_wait

    ; ICW3: Master/Slave wiring
    mov al, 0x04            ; Master: slave on IRQ2 (bit 2)
    out 0x21, al
    call .io_wait
    mov al, 0x02            ; Slave: cascade identity 2
    out 0xA1, al
    call .io_wait

    ; ICW4: 8086 mode
    mov al, 0x01
    out 0x21, al
    call .io_wait
    out 0xA1, al
    call .io_wait

    ; Mask all IRQs initially AND LEAVE THEM MASKED (we use IOAPIC now)
    mov al, 0xFF
    out 0x21, al            ; Mask all master IRQs
    call .io_wait
    mov al, 0xFF
    out 0xA1, al            ; Mask all slave IRQs
    call .io_wait

    ret

.io_wait:
    ; Small delay for PIC programming
    out 0x80, al
    ret

; --- Send End Of Interrupt to master PIC ---
global pic_eoi_master
pic_eoi_master:
    mov al, 0x20
    out 0x20, al
    ret

; --- Send End Of Interrupt to slave PIC (and master cascade) ---
global pic_eoi_slave
pic_eoi_slave:
    mov al, 0x20
    out 0xA0, al            ; EOI to slave
    out 0x20, al            ; EOI to master (cascade)
    ret

; --- Mask a specific IRQ line ---
; RDI = IRQ number (0-15)
global pic_mask_irq
pic_mask_irq:
    cmp edi, 8
    jge .slave
    ; Master PIC
    mov cl, dil
    mov ah, 1
    shl ah, cl
    in al, 0x21
    or al, ah
    out 0x21, al
    ret
.slave:
    sub edi, 8
    mov cl, dil
    mov ah, 1
    shl ah, cl
    in al, 0xA1
    or al, ah
    out 0xA1, al
    ret

; --- Unmask a specific IRQ line ---
; RDI = IRQ number (0-15)
global pic_unmask_irq
pic_unmask_irq:
    cmp edi, 8
    jge .slave
    ; Master PIC
    mov cl, dil
    mov ah, 1
    shl ah, cl
    not ah
    in al, 0x21
    and al, ah
    out 0x21, al
    ret
.slave:
    sub edi, 8
    mov cl, dil
    mov ah, 1
    shl ah, cl
    not ah
    in al, 0xA1
    and al, ah
    out 0xA1, al
    ret

section .data
pic_mask_save: db 0, 0
