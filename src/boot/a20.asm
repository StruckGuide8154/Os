; ============================================================================
; NexusOS v3.0 - A20 Line Enable
; Called from Stage 2 in 16-bit real mode
; ============================================================================

enable_a20:
    ; Method 1: BIOS INT 15h
    mov ax, 0x2401
    int 0x15
    jc .try_kbd
    call check_a20
    test ax, ax
    jnz .done

.try_kbd:
    ; Method 2: Keyboard controller
    call .wait_kbd_in
    mov al, 0xAD            ; Disable keyboard
    out 0x64, al
    call .wait_kbd_in
    mov al, 0xD0            ; Read output port
    out 0x64, al
    call .wait_kbd_out
    in al, 0x60
    push ax
    call .wait_kbd_in
    mov al, 0xD1            ; Write output port
    out 0x64, al
    call .wait_kbd_in
    pop ax
    or al, 0x02             ; Set A20 bit
    out 0x60, al
    call .wait_kbd_in
    mov al, 0xAE            ; Enable keyboard
    out 0x64, al
    call .wait_kbd_in

    call check_a20
    test ax, ax
    jnz .done

    ; Method 3: Fast A20 (port 0x92)
    in al, 0x92
    or al, 0x02
    and al, 0xFE            ; Don't reset!
    out 0x92, al

    call check_a20
    test ax, ax
    jnz .done

    ; A20 failed - hang
    mov si, msg_a20_fail
    call print16_s2
    jmp $

.done:
    ret

.wait_kbd_in:
    in al, 0x64
    test al, 0x02
    jnz .wait_kbd_in
    ret

.wait_kbd_out:
    in al, 0x64
    test al, 0x01
    jz .wait_kbd_out
    ret

; Check if A20 is enabled. Returns AX=1 if enabled, 0 if not.
check_a20:
    pushf
    push ds
    push es
    push di
    push si

    xor ax, ax
    mov es, ax
    mov di, 0x0500

    mov ax, 0xFFFF
    mov ds, ax
    mov si, 0x0510

    ; Save original values
    mov al, [es:di]
    push ax
    mov al, [ds:si]
    push ax

    ; Write different values
    mov byte [es:di], 0x00
    mov byte [ds:si], 0xFF

    ; Check if they wrap
    cmp byte [es:di], 0xFF

    ; Save result of comparison
    je .a20_off_cleanup
    mov bx, 1       ; Enabled
    jmp .cleanup

.a20_off_cleanup:
    xor bx, bx      ; Disabled

.cleanup:
    ; Restore original values
    pop ax
    mov [ds:si], al
    pop ax
    mov [es:di], al

    mov ax, bx      ; Return result

    pop si
    pop di
    pop es
    pop ds
    popf
    ret

msg_a20_fail: db 'A20 fail', 0
