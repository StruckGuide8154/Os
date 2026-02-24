; ============================================================================
; NexusOS v3.0 - PS/2 Keyboard Driver
; IRQ1 handler, scancode set 1 -> ASCII translation, circular buffer
; ============================================================================
bits 64

%include "constants.inc"

extern tick_count
KB_REPEAT_DELAY     equ 40      ; ticks before first repeat (~400ms at 100Hz)
KB_REPEAT_RATE      equ 5       ; ticks between repeats (~50ms)

section .text

; --- Initialize keyboard ---
global keyboard_init
keyboard_init:
    ; Flush keyboard buffer
.flush:
    in al, 0x64
    test al, 0x01            ; Output buffer full?
    jz .flushed
    in al, 0x60              ; Read and discard
    jmp .flush
.flushed:
    ; Initialize buffer
    mov dword [kb_head], 0
    mov dword [kb_tail], 0
    mov byte [kb_modifiers], 0
    mov byte [kb_extended], 0
    ret

; --- IRQ1 Keyboard Handler (called from ISR) ---
global keyboard_handler
keyboard_handler:
    push rax
    push rbx
    push rcx
    push rdx

    ; Read scancode from data port
    in al, 0x60
    movzx eax, al

    ; Check for extended scancode prefix
    cmp al, 0xE0
    je .extended
    cmp al, 0xE1
    je .done                 ; Ignore E1 prefix (pause key)

    ; Check if this is an extended scancode follow-up
    cmp byte [kb_extended], 1
    je .ext_key

    ; Check if this is a release (break) code (bit 7 set)
    mov bl, al
    test bl, 0x80
    jnz .release

    ; --- Key press ---
    ; Check for NumLock toggle
    cmp al, 0x45             ; NumLock press
    je .numlock_toggle

    ; Check for modifier keys
    cmp al, 0x2A             ; Left Shift press
    je .shift_press
    cmp al, 0x36             ; Right Shift press
    je .shift_press
    cmp al, 0x1D             ; Left Ctrl press
    je .ctrl_press
    cmp al, 0x38             ; Left Alt press
    je .alt_press

    ; Translate scancode to ASCII
    movzx ecx, al
    cmp ecx, 128
    jge .done

    ; Choose table based on shift state
    test byte [kb_modifiers], KMOD_SHIFT
    jnz .shifted
    movzx edx, byte [scancode_normal + ecx]
    jmp .push_key
.shifted:
    movzx edx, byte [scancode_shifted + ecx]

.push_key:
    ; Push key event to circular buffer
    ; Format: scancode (byte), ascii (byte), modifiers (byte), pressed (byte)
    mov ecx, [kb_tail]
    mov r8d, ecx
    shl r8d, 2               ; * 4 bytes per entry
    lea rbx, [kb_buffer + r8]

    mov [rbx], al             ; Scancode
    mov [rbx + 1], dl         ; ASCII
    ; Save for key repeat (r8 is free here)
    mov [kb_repeat_scancode], al
    mov [kb_repeat_ascii], dl
    mov r8d, [tick_count]
    add r8d, KB_REPEAT_DELAY
    mov [kb_repeat_next_tick], r8d
    mov dl, [kb_modifiers]
    mov [rbx + 2], dl         ; Modifiers
    mov byte [rbx + 3], 1     ; Pressed

    ; Advance tail
    inc ecx
    and ecx, (KB_BUFFER_SIZE - 1)
    mov [kb_tail], ecx
    jmp .done

.release:
    and bl, 0x7F             ; Get scancode without break bit
    cmp bl, 0x2A             ; Left Shift release
    je .shift_release
    cmp bl, 0x36             ; Right Shift release
    je .shift_release
    cmp bl, 0x1D             ; Left Ctrl release
    je .ctrl_release
    cmp bl, 0x38             ; Left Alt release
    je .alt_release
    ; Clear key repeat if this is the held key being released
    cmp bl, [kb_repeat_scancode]
    jne .done
    mov byte [kb_repeat_scancode], 0
    jmp .done

.shift_press:
    or byte [kb_modifiers], KMOD_SHIFT
    jmp .done
.shift_release:
    and byte [kb_modifiers], ~KMOD_SHIFT
    jmp .done
.ctrl_press:
    or byte [kb_modifiers], KMOD_CTRL
    jmp .done
.ctrl_release:
    and byte [kb_modifiers], ~KMOD_CTRL
    jmp .done
.alt_press:
    or byte [kb_modifiers], KMOD_ALT
    jmp .done
.alt_release:
    and byte [kb_modifiers], ~KMOD_ALT
    jmp .done

.numlock_toggle:
    xor byte [kb_numlock], 1    ; Toggle NumLock state
    jmp .done

.ext_key:
    mov byte [kb_extended], 0
    ; Check for release of extended key
    test al, 0x80
    jnz .done                ; Ignore extended key releases
    ; Push extended key press: scancode | 0x80 flag in high byte, ASCII=0
    mov ecx, [kb_tail]
    mov r8d, ecx
    shl r8d, 2
    lea rbx, [kb_buffer + r8]
    or al, 0x80              ; Mark as extended scancode
    mov [rbx], al             ; Extended scancode (0x80 | raw)
    mov byte [rbx + 1], 0    ; No ASCII
    mov dl, [kb_modifiers]
    mov [rbx + 2], dl
    mov byte [rbx + 3], 1    ; Pressed
    inc ecx
    and ecx, (KB_BUFFER_SIZE - 1)
    mov [kb_tail], ecx
    jmp .done

.extended:
    mov byte [kb_extended], 1
    jmp .done

.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Read one key event from buffer ---
; Returns: EAX = packed key event (scancode|ascii|mods|pressed), or 0 if empty
global keyboard_read
keyboard_read:
    mov ecx, [kb_head]
    cmp ecx, [kb_tail]
    je .empty

    mov r8d, ecx
    shl r8d, 2
    lea rbx, [kb_buffer + r8]
    mov eax, [rbx]           ; Read 4 bytes (packed key event)

    ; Advance head
    inc ecx
    and ecx, (KB_BUFFER_SIZE - 1)
    mov [kb_head], ecx
    ret

.empty:
    xor eax, eax
    ret

; --- Check if buffer has data ---
; Returns: EAX = 1 if data available, 0 if empty
global keyboard_available
keyboard_available:
    mov eax, [kb_head]
    cmp eax, [kb_tail]
    je .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; --- Fire repeat event if a key is held and timer expired ---
; Call once per frame from main loop
global keyboard_repeat_tick
keyboard_repeat_tick:
    push rax
    push rbx
    push rcx
    push rdx
    push r8

    movzx eax, byte [kb_repeat_scancode]
    test eax, eax
    jz .rep_done

    mov ecx, [tick_count]
    cmp ecx, [kb_repeat_next_tick]
    jl .rep_done

    ; Advance next repeat tick
    add ecx, KB_REPEAT_RATE
    mov [kb_repeat_next_tick], ecx

    ; Push repeat key event to buffer
    mov ecx, [kb_tail]
    mov r8d, ecx
    shl r8d, 2
    lea rbx, [kb_buffer + r8]
    mov [rbx], al                 ; scancode
    movzx edx, byte [kb_repeat_ascii]
    mov [rbx + 1], dl             ; ASCII
    mov dl, [kb_modifiers]
    mov [rbx + 2], dl             ; modifiers
    mov byte [rbx + 3], 1         ; pressed
    inc ecx
    and ecx, (KB_BUFFER_SIZE - 1)
    mov [kb_tail], ecx

.rep_done:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .data
kb_modifiers:   db 0
kb_extended:    db 0
global kb_numlock
kb_numlock:     db 0         ; 0 = cursor mode (arrows move mouse), 1 = typing mode
kb_head:        dd 0
kb_tail:        dd 0
kb_repeat_scancode: db 0
kb_repeat_ascii:    db 0
kb_repeat_next_tick: dd 0

section .bss
kb_buffer:      resb (KB_BUFFER_SIZE * 4)

section .data
; Scancode Set 1 -> ASCII translation table (US QWERTY)
; Index = scancode, value = ASCII character (0 = no mapping)
scancode_normal:
    ;     0     1     2     3     4     5     6     7     8     9     A     B     C     D     E     F
    db    0,   27,  '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  '0',  '-',  '=',    8,    9  ; 0x00-0x0F
    db  'q',  'w',  'e',  'r',  't',  'y',  'u',  'i',  'o',  'p',  '[',  ']',   13,    0,  'a',  's'  ; 0x10-0x1F
    db  'd',  'f',  'g',  'h',  'j',  'k',  'l',  ';', 0x27,  '`',    0, '\',  'z',  'x',  'c',  'v'  ; 0x20-0x2F
    db  'b',  'n',  'm',  ',',  '.',  '/',    0,  '*',    0,  ' ',    0, KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5  ; 0x30-0x3F
    db KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10,  0,    0,  '7',  '8',  '9',  '-',  '4',  '5',  '6',  '+',  '1'  ; 0x40-0x4F
    db  '2',  '3',  '0',  '.',    0,    0,    0, KEY_F11, KEY_F12, 0,   0,    0,    0,    0,    0,    0   ; 0x50-0x5F
    times 64 db 0  ; 0x60-0x7F

scancode_shifted:
    db    0,   27,  '!',  '@',  '#',  '$',  '%',  '^',  '&',  '*',  '(',  ')',  '_',  '+',    8,    9  ; 0x00-0x0F
    db  'Q',  'W',  'E',  'R',  'T',  'Y',  'U',  'I',  'O',  'P',  '{',  '}',   13,    0,  'A',  'S'  ; 0x10-0x1F
    db  'D',  'F',  'G',  'H',  'J',  'K',  'L',  ':',  '"',  '~',    0,  '|',  'Z',  'X',  'C',  'V'  ; 0x20-0x2F
    db  'B',  'N',  'M',  '<',  '>',  '?',    0,  '*',    0,  ' ',    0, KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5  ; 0x30-0x3F
    db KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10,  0,    0,  '7',  '8',  '9',  '-',  '4',  '5',  '6',  '+',  '1'  ; 0x40-0x4F
    db  '2',  '3',  '0',  '.',    0,    0,    0, KEY_F11, KEY_F12, 0,   0,    0,    0,    0,    0,    0   ; 0x50-0x5F
    times 64 db 0  ; 0x60-0x7F
