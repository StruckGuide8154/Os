; ============================================================================
; NexusOS v3.0 - VESA VBE Mode Setup
; Must be called in 16-bit real mode (uses INT 10h)
; Saves framebuffer info to VBE_INFO_ADDR (0x9000)
; ============================================================================

; VBE info buffer (used temporarily)
VBE_BLOCK_ADDR  equ 0x5000     ; 512 bytes for VbeInfoBlock
VBE_MODE_BUF    equ 0x5200     ; 256 bytes for ModeInfoBlock

setup_vesa:
    ; Step 1: Get VBE Controller Info
    mov ax, 0x4F00
    mov di, VBE_BLOCK_ADDR
    ; Set signature to "VBE2" to request VBE 2.0+ info
    mov dword [di], 0x32454256  ; 'VBE2'
    int 0x10
    cmp ax, 0x004F
    jne vesa_fail_global

    ; Step 2: Search mode list for 1024x768x32
    mov si, [VBE_BLOCK_ADDR + 14]   ; Mode list pointer (offset)
    mov ax, [VBE_BLOCK_ADDR + 16]   ; Mode list pointer (segment)
    mov fs, ax                       ; FS:SI -> mode list
    
    ; If pointer is null, jump to fallback
    or ax, si
    jz try_fallback_global

mode_loop:
    mov cx, [fs:si]
    cmp cx, 0xFFFF                   ; End of mode list
    je try_fallback_global
    
    ; Save loop state
    push si
    push fs
    push cx ; Mode number
    
    ; Get mode info
    mov ax, 0x4F01
    ; CX is already the mode number
    mov di, VBE_MODE_BUF
    int 0x10
    
    cmp ax, 0x004F
    jne next_mode
    
    ; Check: 1024x768, 32bpp, linear framebuffer supported
    cmp word [VBE_MODE_BUF + 18], 1024   ; XResolution
    jne next_mode
    cmp word [VBE_MODE_BUF + 20], 768    ; YResolution
    jne next_mode
    cmp byte [VBE_MODE_BUF + 25], 32     ; BitsPerPixel
    jne next_mode
    ; Check if linear framebuffer is supported (bit 7 of ModeAttributes)
    test word [VBE_MODE_BUF + 0], 0x0080
    jz next_mode

    ; Found our mode!
    pop cx                              ; CX = mode number
    pop fs
    pop si
    jmp set_mode_global

next_mode:
    pop cx
    pop fs
    pop si
    add si, 2                       ; Next mode in list (word size)
    jmp mode_loop

try_fallback_global:
    ; Try hardcoded mode 0x118 (1024x768x24/32) or 0x115 (800x600x24/32)
    ; Note: bit 14 set for LFB (0x4000)
    
    ; Try 1024x768
    mov cx, 0x118
    call check_mode
    jnc set_mode_global
    
    ; Try 800x600
    mov cx, 0x115
    call check_mode
    jnc set_mode_global
    
    jmp vesa_fail_global

; Check if mode in CX is valid and supported
; Returns CF=0 if valid, CF=1 if invalid
check_mode:
    pusha
    mov ax, 0x4F01
    mov di, VBE_MODE_BUF
    int 0x10
    cmp ax, 0x004F
    jne .check_fail
    
    test word [VBE_MODE_BUF + 0], 0x0080
    jz .check_fail
    
    popa
    clc     ; Clear carry = success
    ret
.check_fail:
    popa
    stc     ; Set carry = fail
    ret

set_mode_global:
    ; Step 3: Save framebuffer info to VBE_INFO_ADDR
    ; Framebuffer physical address
    mov eax, [VBE_MODE_BUF + 40]       ; PhysBasePtr
    mov [VBE_INFO_ADDR + 0], eax       ; FB address low 32 bits
    mov dword [VBE_INFO_ADDR + 4], 0   ; FB address high 32 bits

    ; Screen dimensions
    movzx eax, word [VBE_MODE_BUF + 18]
    mov [VBE_INFO_ADDR + 8], eax       ; Width

    movzx eax, word [VBE_MODE_BUF + 20]
    mov [VBE_INFO_ADDR + 12], eax      ; Height

    movzx eax, word [VBE_MODE_BUF + 16]
    mov [VBE_INFO_ADDR + 16], eax      ; BytesPerScanLine (pitch)

    movzx eax, byte [VBE_MODE_BUF + 25]
    mov [VBE_INFO_ADDR + 20], eax      ; BitsPerPixel

    ; Step 4: Set the VESA mode with linear framebuffer
    mov ax, 0x4F02
    mov bx, cx
    or bx, 0x4000                       ; Bit 14 = use linear framebuffer
    xor di, di
    int 0x10
    cmp ax, 0x004F
    jne vesa_fail_global

    ; Success - screen is now in graphics mode
    ret

vesa_fail_global:
    mov si, msg_vesa_fail
    call print16_s2
    jmp $

msg_vesa_fail: db 'VESA fail', 0

VBE_INFO_ADDR   equ 0x9000
