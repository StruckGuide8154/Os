; ============================================================================
; NexusOS v3.0 - PS/2 Mouse Driver
; Full 8042 controller init, IRQ12 handler, 3-byte packet protocol
; ============================================================================
bits 64

%include "constants.inc"

extern scr_width, scr_height
extern mouse_scroll_y

section .text

; --- Initialize PS/2 mouse (full 8042 sequence per OSDev wiki) ---
global mouse_init

mouse_init:
    push rax
    push rbx
    push rcx
    push rdx

    ; Initialize state
    mov dword [mouse_x], (SCREEN_WIDTH / 2)
    mov dword [mouse_y], (SCREEN_HEIGHT / 2)
    mov byte [mouse_buttons], 0
    mov byte [mouse_cycle], 0
    mov dword [mouse_evt_head], 0
    mov dword [mouse_evt_tail], 0
    mov byte [mouse_irq_count], 0

    ; Serial: 'M' = mouse init start
    mov dx, 0x3F8
    mov al, 'M'
    out dx, al

    ; ---- Step 1: Disable both PS/2 ports ----
    call mouse_wait_input
    jc .init_fail
    mov al, 0xAD               ; Disable first port (keyboard)
    out 0x64, al
    call mouse_wait_input
    jc .init_fail
    mov al, 0xA7               ; Disable second port (mouse)
    out 0x64, al

    ; ---- Step 2: Flush the output buffer ----
    mov ecx, 32                ; Read up to 32 stale bytes
.flush:
    in al, 0x64
    test al, 0x01
    jz .flush_done
    in al, 0x60                ; Discard byte
    dec ecx
    jnz .flush
.flush_done:

    ; Serial: '1'
    mov dx, 0x3F8
    mov al, '1'
    out dx, al

    ; ---- Step 3: Set controller config byte ----
    ; Read current config
    call mouse_wait_input
    jc .init_fail
    mov al, 0x20               ; Read config byte
    out 0x64, al
    call mouse_wait_output
    jc .init_fail
    in al, 0x60
    mov bl, al                 ; Save config in BL
    mov [mouse_dbg_ccb], al    ; Save for debug

    ; Modify: enable IRQ1 (bit0), IRQ12 (bit1), clear disable-clocks (bits 4,5)
    or bl, 0x03                ; Set bits 0,1 (IRQ1 + IRQ12)
    and bl, ~0x30              ; Clear bits 4,5 (enable both clocks)

    ; Write config back
    call mouse_wait_input
    jc .init_fail
    mov al, 0x60               ; Write config byte
    out 0x64, al
    call mouse_wait_input
    jc .init_fail
    mov al, bl
    out 0x60, al

    ; Serial: '2'
    mov dx, 0x3F8
    mov al, '2'
    out dx, al

    ; ---- Step 4: Controller self-test ----
    call mouse_wait_input
    jc .init_fail
    mov al, 0xAA               ; Self-test command
    out 0x64, al
    call mouse_wait_output
    jc .init_fail
    in al, 0x60
    mov [mouse_dbg_selftest], al
    cmp al, 0x55               ; Expected: 0x55 = pass
    jne .init_fail             ; Self-test failed

    ; Serial: '3'
    mov dx, 0x3F8
    mov al, '3'
    out dx, al

    ; ---- Step 5: Test second port (mouse) ----
    call mouse_wait_input
    jc .init_fail
    mov al, 0xA9               ; Test second port
    out 0x64, al
    call mouse_wait_output
    jc .init_fail
    in al, 0x60
    mov [mouse_dbg_port2test], al
    cmp al, 0x00               ; 0x00 = pass
    jne .init_fail

    ; Serial: '4'
    mov dx, 0x3F8
    mov al, '4'
    out dx, al

    ; ---- Step 6: Enable both ports ----
    call mouse_wait_input
    jc .init_fail
    mov al, 0xAE               ; Enable first port (keyboard)
    out 0x64, al
    call mouse_wait_input
    jc .init_fail
    mov al, 0xA8               ; Enable second port (mouse)
    out 0x64, al

    ; ---- Step 6b: Re-write config byte (self-test reset it) ----
    call mouse_wait_input
    jc .init_fail
    mov al, 0x20               ; Read config
    out 0x64, al
    call mouse_wait_output
    jc .init_fail
    in al, 0x60
    or al, 0x03                ; Enable IRQ1 (bit0) + IRQ12 (bit1)
    and al, ~0x30              ; Enable both clocks (clear bits 4,5)
    mov bl, al
    call mouse_wait_input
    jc .init_fail
    mov al, 0x60               ; Write config
    out 0x64, al
    call mouse_wait_input
    jc .init_fail
    mov al, bl
    out 0x60, al

    ; ---- Step 7: Reset mouse device (0xFF) ----
    call mouse_write           ; Send 0xD4 prefix (write-to-mouse)
    mov al, 0xFF               ; Reset command
    call mouse_write_data
    ; Read ACK (0xFA)
    call mouse_wait_output
    jc .skip_reset_resp
    in al, 0x60
    mov [mouse_dbg_reset_ack], al
    ; Read self-test result (0xAA)
    call mouse_wait_output
    jc .skip_reset_resp
    in al, 0x60
    mov [mouse_dbg_reset_result], al
    ; Read device ID (usually 0x00)
    call mouse_wait_output
    jc .skip_reset_resp
    in al, 0x60
    mov [mouse_dbg_device_id], al
.skip_reset_resp:

    ; Serial: '5'
    mov dx, 0x3F8
    mov al, '5'
    out dx, al

    ; ---- Step 8: Set defaults ----
    call mouse_write
    mov al, 0xF6               ; Set defaults
    call mouse_write_data
    call mouse_read_ack

    ; ---- Step 9: Negotiate Intellimouse (scroll wheel) via magic sample-rate sequence ----
    ; Magic: set sample rate 200, 100, 80 in sequence -> device ID becomes 0x03
    call mouse_write
    mov al, 0xF3
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 200
    call mouse_write_data
    call mouse_read_ack

    call mouse_write
    mov al, 0xF3
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 100
    call mouse_write_data
    call mouse_read_ack

    call mouse_write
    mov al, 0xF3
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 80
    call mouse_write_data
    call mouse_read_ack

    ; Query device ID (0xF2) - if 0x03, mouse has scroll wheel
    call mouse_write
    mov al, 0xF2
    call mouse_write_data
    call mouse_read_ack         ; ACK to query command
    call mouse_wait_output
    jc .skip_im_check
    in al, 0x60
    cmp al, 0x03                ; 0x03 = Intellimouse with scroll wheel
    jne .skip_im_check
    mov byte [mouse_im_mode], 1

    ; Try to upgrade to 5-button Intellimouse: magic sequence 200, 200, 80
    call mouse_write
    mov al, 0xF3
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 200
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 0xF3
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 200
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 0xF3
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 80
    call mouse_write_data
    call mouse_read_ack
    ; Query device ID again
    call mouse_write
    mov al, 0xF2
    call mouse_write_data
    call mouse_read_ack
    call mouse_wait_output
    jc .skip_im_check
    in al, 0x60
    cmp al, 0x04                ; 0x04 = 5-button Intellimouse
    jne .skip_im_check
    mov byte [mouse_im_mode], 2
.skip_im_check:

    ; ---- Step 9b: Set final sample rate 100 ----
    call mouse_write
    mov al, 0xF3
    call mouse_write_data
    call mouse_read_ack
    call mouse_write
    mov al, 100
    call mouse_write_data
    call mouse_read_ack

    ; ---- Step 10: Enable data reporting ----
    call mouse_write
    mov al, 0xF4               ; Enable data reporting
    call mouse_write_data
    call mouse_read_ack

    ; Serial: '6'
    mov dx, 0x3F8
    mov al, '6'
    out dx, al

    ; ---- Step 11: Re-read and store final config byte for debug ----
    call mouse_wait_input
    jc .init_ok
    mov al, 0x20
    out 0x64, al
    call mouse_wait_output
    jc .init_ok
    in al, 0x60
    mov [mouse_dbg_ccb_final], al

.init_ok:
    mov byte [0x500], 0xAA
    mov byte [mouse_init_status], 0xAA

    ; Serial: 'OK'
    mov dx, 0x3F8
    mov al, 'O'
    out dx, al
    mov al, 'K'
    out dx, al

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.init_fail:
    mov byte [0x500], 0xFF
    mov byte [mouse_init_status], 0xFF

    ; Serial: 'F!'
    mov dx, 0x3F8
    mov al, 'F'
    out dx, al
    mov al, '!'
    out dx, al

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Helper: signal we're writing to mouse
mouse_write:
    call mouse_wait_input
    mov al, 0xD4             ; Write to mouse port
    out 0x64, al
    ret

; Helper: write data byte to mouse
mouse_write_data:
    call mouse_wait_input
    out 0x60, al
    ret

; Helper: read ACK from mouse
mouse_read_ack:
    call mouse_wait_output
    in al, 0x60              ; Should be 0xFA (ACK)
    ret

; Wait until input buffer is empty (bit 1 of status = 0)
; Returns CF=0 on success, CF=1 on timeout
global mouse_wait_input
mouse_wait_input:
    push rcx
    mov ecx, 100000          ; Timeout counter
.loop:
    in al, 0x64
    test al, 0x02
    jz .done
    dec ecx
    jnz .loop
    pop rcx
    stc
    ret
.done:
    pop rcx
    clc
    ret

; Wait until output buffer is full (bit 0 of status = 1)
; Returns CF=0 on success, CF=1 on timeout
mouse_wait_output:
    push rcx
    mov ecx, 100000          ; Timeout counter
.loop:
    in al, 0x64
    test al, 0x01
    jnz .done
    dec ecx
    jnz .loop
    pop rcx
    stc
    ret
.done:
    pop rcx
    clc
    ret

; --- IRQ12 Mouse Handler (called from ISR) ---
global mouse_handler
mouse_handler:
    push rax
    push rbx
    push rcx
    push rdx

    ; Check status register bit 5 to confirm this is mouse data (not keyboard)
    in al, 0x64
    test al, 0x20            ; Bit 5 = aux output buffer full (mouse data)
    jz .not_mouse            ; If bit 5 clear, this is keyboard data, ignore

    ; Debug: increment IRQ12 counter
    inc byte [mouse_irq_count]

    ; Read byte from data port
    in al, 0x60
    movzx eax, al

    ; Store last raw bytes for debug
    movzx ecx, byte [mouse_cycle]
    lea rbx, [mouse_dbg_raw]
    mov [rbx + rcx], al

    ; PS/2 mouse sends 3-byte packets:
    ; Byte 0: Y_overflow | X_overflow | Y_sign | X_sign | 1 | Middle | Right | Left
    ; Byte 1: X movement (unsigned, sign from byte 0 bit 4)
    ; Byte 2: Y movement (unsigned, sign from byte 0 bit 5)

    cmp cl, 0
    je .byte0
    cmp cl, 1
    je .byte1
    cmp cl, 2
    je .byte2
    cmp cl, 3
    je .byte3
    ; Invalid state, reset
    mov byte [mouse_cycle], 0
    jmp .done

.byte0:
    ; Validate: bit 3 should always be set in byte 0
    test al, 0x08
    jz .resync               ; Invalid packet, try to resync

    ; Check overflow bits - discard if overflow
    test al, 0xC0
    jnz .done                ; X or Y overflow, discard packet

    mov [mouse_packet], al
    mov byte [mouse_cycle], 1
    jmp .done

.resync:
    ; Bad byte0 - flush and reset cycle
    mov byte [mouse_cycle], 0
    jmp .done

.byte1:
    mov [mouse_packet + 1], al
    mov byte [mouse_cycle], 2
    jmp .done

.byte2:
    mov [mouse_packet + 2], al
    ; Intellimouse 0x03/0x04: need 4th byte for scroll wheel / extra buttons
    cmp byte [mouse_im_mode], 0
    je .do_process
    mov byte [mouse_cycle], 3   ; wait for Z byte
    jmp .done

.byte3:
    mov [mouse_packet + 3], al
    mov byte [mouse_cycle], 0
    jmp .do_process

.do_process:
    mov byte [mouse_cycle], 0

    ; Process complete packet
    ; Extract X delta with sign extension
    movzx eax, byte [mouse_packet + 1]   ; X movement (unsigned)
    movzx ebx, byte [mouse_packet]       ; Flags byte
    test bl, 0x10                         ; X sign bit
    jz .x_positive
    or eax, 0xFFFFFF00
.x_positive:
    mov ecx, eax
    add ecx, [mouse_x]
    cmp ecx, 0
    jge .x_min_ok
    xor ecx, ecx
.x_min_ok:
    mov eax, [scr_width]
    dec eax
    cmp ecx, eax
    jle .x_max_ok
    mov ecx, eax
.x_max_ok:
    mov [mouse_x], ecx

    ; Extract Y delta with sign extension
    movzx eax, byte [mouse_packet + 2]
    test bl, 0x20                         ; Y sign bit
    jz .y_positive
    or eax, 0xFFFFFF00
.y_positive:
    ; PS/2 Y: positive = UP, screen Y: positive = DOWN -> subtract
    mov ecx, eax
    mov edx, [mouse_y]
    sub edx, ecx
    cmp edx, 0
    jge .y_min_ok
    xor edx, edx
.y_min_ok:
    mov eax, [scr_height]
    dec eax
    cmp edx, eax
    jle .y_max_ok
    mov edx, eax
.y_max_ok:
    mov [mouse_y], edx

    ; Update button state
    mov al, bl
    and al, 0x07
    mov [mouse_buttons], al

    ; For 5-button Intellimouse (mode 2): extract buttons 4 & 5 from byte3
    cmp byte [mouse_im_mode], 2
    jne .no_im5_btns
    movzx ecx, byte [mouse_packet + 3]
    test ecx, 0x10              ; bit 4 = button 4
    jz .no_btn4
    or byte [mouse_buttons], 0x08
.no_btn4:
    test ecx, 0x20              ; bit 5 = button 5
    jz .no_im5_btns
    or byte [mouse_buttons], 0x10
.no_im5_btns:

    ; Update scroll wheel delta (Intellimouse byte 3, bits 3:0, 4-bit signed)
    cmp byte [mouse_im_mode], 0
    je .no_scroll
    movsx eax, byte [mouse_packet + 3]
    and eax, 0x0F               ; mask to 4 bits
    test eax, 0x08              ; sign bit set?
    jz .scroll_pos
    or eax, 0xFFFFFFF0          ; sign-extend to 32-bit
.scroll_pos:
    mov [mouse_scroll_y], eax
.no_scroll:

    ; Push mouse event to buffer
    mov ecx, [mouse_evt_tail]
    mov r8d, ecx
    shl r8d, 4
    lea rbx, [mouse_evt_buffer + r8]

    mov eax, [mouse_x]
    mov [rbx + 0], eax
    mov eax, [mouse_y]
    mov [rbx + 4], eax
    mov al, [mouse_buttons]
    mov [rbx + 8], al

    mov al, MEVT_MOVE
    test byte [mouse_buttons], 0x01
    jz .no_lclick
    mov al, MEVT_LCLICK
.no_lclick:
    mov [rbx + 9], al

    mov byte [mouse_moved], 1

    inc ecx
    and ecx, (MOUSE_BUFFER_SIZE - 1)
    mov [mouse_evt_tail], ecx
    jmp .done

.not_mouse:
    ; Not mouse data - read and discard to clear buffer
    in al, 0x60
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Read one mouse event from buffer ---
global mouse_read
mouse_read:
    mov ecx, [mouse_evt_head]
    cmp ecx, [mouse_evt_tail]
    je .empty

    mov r8d, ecx
    shl r8d, 4
    lea rbx, [mouse_evt_buffer + r8]

    mov rax, [rbx]
    mov [rdi], rax
    mov rax, [rbx + 8]
    mov [rdi + 8], rax

    inc ecx
    and ecx, (MOUSE_BUFFER_SIZE - 1)
    mov [mouse_evt_head], ecx

    mov eax, 1
    ret

.empty:
    xor eax, eax
    ret

; --- Get current mouse position ---
global mouse_get_pos
mouse_get_pos:
    mov eax, [mouse_x]
    mov edx, [mouse_y]
    ret

; --- Get mouse buttons ---
global mouse_get_buttons
mouse_get_buttons:
    mov al, [mouse_buttons]
    ret

; --- Check and clear mouse moved flag ---
global mouse_check_moved
mouse_check_moved:
    xor eax, eax
    xchg al, [mouse_moved]
    ret

; --- Debug: build diagnostic string into buffer ---
; RDI = output buffer (at least 256 bytes)
; Returns: RDI preserved
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

section .data
global mouse_x, mouse_y, mouse_buttons, mouse_moved

global mouse_init_status
mouse_init_status:  db 0
mouse_x:            dd (SCREEN_WIDTH / 2)
mouse_y:            dd (SCREEN_HEIGHT / 2)
mouse_buttons:      db 0
mouse_moved:        db 0
mouse_cycle:        db 0
mouse_im_mode:      db 0        ; 1 = Intellimouse 4-byte packets (scroll wheel)
mouse_packet:       db 0, 0, 0, 0
mouse_evt_head:     dd 0
mouse_evt_tail:     dd 0
mouse_irq_count:    db 0

; Debug data saved during init
mouse_dbg_ccb:          db 0
mouse_dbg_ccb_final:    db 0
mouse_dbg_selftest:     db 0
mouse_dbg_port2test:    db 0
mouse_dbg_reset_ack:    db 0
mouse_dbg_reset_result: db 0
mouse_dbg_device_id:    db 0
mouse_dbg_raw:          db 0, 0, 0

section .bss
mouse_evt_buffer:   resb (MOUSE_BUFFER_SIZE * 16)
