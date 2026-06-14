; --- Debug: build diagnostic string into buffer ---
; RDI = output buffer (at least 256 bytes)
; Returns: RDI preserved
%ifndef RELEASE_BUILD
global mouse_debug_dump
mouse_debug_dump:
    push rdi
    push rsi
    push rax
    push rbx
    push rcx
    push rdx

    mov rbx, rdi              ; RBX = write pointer

    ; "Mouse Debug Info" header
    lea rsi, [.hdr]
    call .copystr

    ; Init status
    lea rsi, [.s_init]
    call .copystr
    movzx eax, byte [mouse_init_status]
    call .writehex8

    ; IRQ count
    lea rsi, [.s_irq]
    call .copystr
    movzx eax, byte [mouse_irq_count]
    call .writehex8

    ; Mouse X,Y
    lea rsi, [.s_xy]
    call .copystr
    mov eax, [mouse_x]
    call .writehex16
    mov byte [rbx], ','
    inc rbx
    mov eax, [mouse_y]
    call .writehex16

    ; Buttons
    lea rsi, [.s_btn]
    call .copystr
    movzx eax, byte [mouse_buttons]
    call .writehex8

    ; 8042 status register (live)
    lea rsi, [.s_8042]
    call .copystr
    in al, 0x64
    movzx eax, al
    call .writehex8

    ; CCB initial/final
    lea rsi, [.s_ccb]
    call .copystr
    movzx eax, byte [mouse_dbg_ccb]
    call .writehex8
    mov byte [rbx], '>'
    inc rbx
    movzx eax, byte [mouse_dbg_ccb_final]
    call .writehex8

    ; Self-test result
    lea rsi, [.s_st]
    call .copystr
    movzx eax, byte [mouse_dbg_selftest]
    call .writehex8

    ; Port2 test
    lea rsi, [.s_p2]
    call .copystr
    movzx eax, byte [mouse_dbg_port2test]
    call .writehex8

    ; Reset response
    lea rsi, [.s_rst]
    call .copystr
    movzx eax, byte [mouse_dbg_reset_ack]
    call .writehex8
    mov byte [rbx], ','
    inc rbx
    movzx eax, byte [mouse_dbg_reset_result]
    call .writehex8
    mov byte [rbx], ','
    inc rbx
    movzx eax, byte [mouse_dbg_device_id]
    call .writehex8

    ; PIC masks (live)
    lea rsi, [.s_pic]
    call .copystr
    in al, 0x21               ; Master PIC mask
    movzx eax, al
    call .writehex8
    mov byte [rbx], ','
    inc rbx
    in al, 0xA1               ; Slave PIC mask
    movzx eax, al
    call .writehex8

    ; Raw last 3 bytes
    lea rsi, [.s_raw]
    call .copystr
    movzx eax, byte [mouse_dbg_raw]
    call .writehex8
    mov byte [rbx], ' '
    inc rbx
    movzx eax, byte [mouse_dbg_raw+1]
    call .writehex8
    mov byte [rbx], ' '
    inc rbx
    movzx eax, byte [mouse_dbg_raw+2]
    call .writehex8

    ; Null terminate
    mov byte [rbx], 0

    pop rdx
    pop rcx
    pop rbx
    pop rax
    pop rsi
    pop rdi
    ret

; -- internal helpers for debug dump --
.copystr:
    ; Copy null-terminated string from RSI to [RBX], advance RBX
    lodsb
    test al, al
    jz .cs_done
    mov [rbx], al
    inc rbx
    jmp .copystr
.cs_done:
    ret

.writehex8:
    ; Write AL as 2 hex chars to [RBX]
    push rax
    shr al, 4
    call .nib
    pop rax
    push rax
    and al, 0x0F
    call .nib
    pop rax
    ret

.writehex16:
    ; Write AX as 4 hex chars to [RBX]
    push rax
    shr eax, 12
    and al, 0x0F
    call .nib
    pop rax
    push rax
    shr eax, 8
    and al, 0x0F
    call .nib
    pop rax
    push rax
    shr al, 4
    call .nib
    pop rax
    push rax
    and al, 0x0F
    call .nib
    pop rax
    ret

.nib:
    cmp al, 10
    jb .nib_digit
    add al, 'A' - 10
    jmp .nib_out
.nib_digit:
    add al, '0'
.nib_out:
    mov [rbx], al
    inc rbx
    ret

.hdr  db " -- Mouse Debug --", 0
.s_init db " Init:", 0
.s_irq  db " IRQ:", 0
.s_xy   db " XY:", 0
.s_btn  db " Btn:", 0
.s_8042 db " 8042:", 0
.s_ccb  db " CCB:", 0
.s_st   db " ST:", 0
.s_p2   db " P2:", 0
.s_rst  db " Rst:", 0
.s_pic  db " PIC:", 0
.s_raw  db " Raw:", 0
%endif

; ----------------------------------------------------------------------------
; mouse_apply_sense_x / _y - scale a signed relative delta by the per-axis
; pointer sensitivity (mouse_sense_* tenths): eax = eax * sense / 10.
; Preserves all registers except eax (saves rcx/rdx). Used by the USB-HID and
; I2C-HID relative-pointer paths so the Settings Mouse tab affects every device.
; ----------------------------------------------------------------------------
global mouse_apply_sense_x, mouse_apply_sense_y
mouse_apply_sense_x:
    push rcx
    push rdx
    imul eax, [mouse_sense_x]
    cdq
    mov ecx, 10
    idiv ecx
    pop rdx
    pop rcx
    ret
mouse_apply_sense_y:
    push rcx
    push rdx
    imul eax, [mouse_sense_y]
    cdq
    mov ecx, 10
    idiv ecx
    pop rdx
    pop rcx
    ret

