; ============================================================================
; NexusOS v3.0 - MBR Boot Sector (Stage 1)
; Exactly 512 bytes. Loads Stage 2 from disk and jumps to it.
; ============================================================================
bits 16
org 0x7C00

mbr_start:
    ; Set up segments and stack
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00          ; Stack grows down from MBR
    sti

    ; Save boot drive number
    mov [boot_drive], dl

    ; Print loading indicator
    mov si, msg_loading
    call print16

    ; Load Stage 2 from sectors 1-63 to 0x7E00
    ; Use INT 13h Extended Read (LBA) if available, fallback to CHS
    mov ah, 0x41            ; Check extensions present
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .use_chs             ; CF=1: extensions not supported
    cmp bx, 0xAA55
    jne .use_chs

    ; --- LBA read using INT 13h AH=42h ---
    mov si, dap             ; DS:SI -> Disk Address Packet
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error
    jmp load_done

.use_chs:
    ; --- CHS read using INT 13h AH=02h ---
    ; Read 63 sectors starting from sector 2 (CHS: C=0, H=0, S=2)
    ; We read in chunks of 32 sectors to avoid DMA boundary issues
    mov bx, 0x7E00          ; ES:BX = destination
    mov cx, STAGE2_SECTORS  ; Sectors remaining
    mov si, 1               ; Starting LBA sector (0-indexed, sector 1)

.chs_loop:
    cmp cx, 0
    je load_done
    push cx
    ; Convert LBA to CHS for this sector
    ; For LBA < 63: C=0, H=0, S=LBA+1
    mov ax, si
    inc ax                  ; S = LBA + 1 (1-based)
    mov cl, al              ; Sector number
    xor ch, ch              ; Cylinder 0
    xor dh, dh              ; Head 0
    mov dl, [boot_drive]
    mov ah, 0x02
    mov al, 1               ; Read 1 sector at a time
    int 0x13
    jc disk_error
    pop cx
    add bx, 512
    inc si
    dec cx
    jmp .chs_loop

load_done:
    ; Verify stage 2 magic number
    cmp word [0x7E00], 0x4E58   ; 'NX' magic
    jne magic_error

    ; Jump to stage 2
    mov dl, [boot_drive]    ; Pass boot drive in DL
    jmp 0x0000:0x7E00

disk_error:
    mov si, msg_disk_err
    call print16
    jmp hang

magic_error:
    mov si, msg_magic_err
    call print16
    jmp hang

hang:
    cli
    hlt
    jmp hang

; --- Print null-terminated string (16-bit real mode) ---
print16:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp print16
.done:
    ret

; --- Data ---
boot_drive:     db 0
msg_loading:    db 'NexusOS', 0
msg_disk_err:   db ' Disk!', 0
msg_magic_err:  db ' Bad!', 0

STAGE2_SECTORS  equ 63

; --- Disk Address Packet for LBA read ---
align 4
dap:
    db 0x10                 ; DAP size (16 bytes)
    db 0                    ; Reserved
    dw STAGE2_SECTORS       ; Number of sectors to read
    dw 0x7E00               ; Offset
    dw 0x0000               ; Segment
    dq 1                    ; Starting LBA (sector 1)

; --- Pad to 510 bytes and add boot signature ---
times 510 - ($ - $$) db 0
dw 0xAA55
