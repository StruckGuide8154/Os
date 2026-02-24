; ============================================================================
; NexusOS v3.0 - ATA PIO Disk Driver
; Provides sector read/write using ATA PIO mode (ports 0x1F0-0x1F7)
; ============================================================================
bits 64

%include "constants.inc"

section .text

global ata_read_sectors
global ata_write_sectors
global ata_drive_select_byte
global ata_drive_sel

; ATA PIO ports (primary controller)
ATA_DATA        equ 0x1F0
ATA_ERROR       equ 0x1F1
ATA_SECT_COUNT  equ 0x1F2
ATA_LBA_LO     equ 0x1F3
ATA_LBA_MID     equ 0x1F4
ATA_LBA_HI      equ 0x1F5
ATA_DRIVE       equ 0x1F6
ATA_CMD         equ 0x1F7
ATA_STATUS      equ 0x1F7

ATA_CMD_READ    equ 0x20
ATA_CMD_WRITE   equ 0x30

ATA_SR_BSY      equ 0x80
ATA_SR_DRQ      equ 0x08
ATA_SR_ERR      equ 0x01

; ============================================================================
; ata_read_sectors - Read sectors from disk using LBA28 PIO
; rdi = LBA (sector number)
; rsi = pointer to destination buffer
; edx = number of sectors to read
; Returns: eax = 0 on success, -1 on error
; ============================================================================
ata_read_sectors:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13

    mov r12, rdi         ; LBA
    mov r13, rsi         ; buffer
    mov ebx, edx         ; sector count

.read_loop:
    test ebx, ebx
    jz .read_done

    ; Select drive and wait for it to be ready
    call ata_select_drive
    test eax, eax
    jnz .read_error

    ; Sector count = 1
    mov dx, ATA_SECT_COUNT
    mov al, 1
    out dx, al

    ; LBA low byte
    mov eax, r12d
    mov dx, ATA_LBA_LO
    out dx, al

    ; LBA mid byte
    mov eax, r12d
    shr eax, 8
    mov dx, ATA_LBA_MID
    out dx, al

    ; LBA high byte
    mov eax, r12d
    shr eax, 16
    mov dx, ATA_LBA_HI
    out dx, al

    ; Send READ command
    mov dx, ATA_CMD
    mov al, ATA_CMD_READ
    out dx, al

    ; Wait for data ready
    call ata_wait_drq
    test eax, eax
    jnz .read_error

    ; Read 256 words (512 bytes) from data port
    mov rdi, r13
    mov dx, ATA_DATA
    mov ecx, 256
    rep insw

    ; Advance to next sector
    add r13, 512
    inc r12
    dec ebx
    jmp .read_loop

.read_done:
    xor eax, eax         ; success
    jmp .read_ret

.read_error:
    mov eax, -1

.read_ret:
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; ata_write_sectors - Write sectors to disk using LBA28 PIO
; rdi = LBA (sector number)
; rsi = pointer to source buffer
; edx = number of sectors to write
; Returns: eax = 0 on success, -1 on error
; ============================================================================
ata_write_sectors:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13

    mov r12, rdi         ; LBA
    mov r13, rsi         ; buffer
    mov ebx, edx         ; sector count

.write_loop:
    test ebx, ebx
    jz .write_done

    ; Select drive and wait for it to be ready
    call ata_select_drive
    test eax, eax
    jnz .write_error

    ; Sector count = 1
    mov dx, ATA_SECT_COUNT
    mov al, 1
    out dx, al

    ; LBA bytes
    mov eax, r12d
    mov dx, ATA_LBA_LO
    out dx, al
    mov eax, r12d
    shr eax, 8
    mov dx, ATA_LBA_MID
    out dx, al
    mov eax, r12d
    shr eax, 16
    mov dx, ATA_LBA_HI
    out dx, al

    ; Send WRITE command
    mov dx, ATA_CMD
    mov al, ATA_CMD_WRITE
    out dx, al

    ; Wait for DRQ
    call ata_wait_drq
    test eax, eax
    jnz .write_error

    ; Write 256 words (512 bytes) to data port
    mov rsi, r13
    mov dx, ATA_DATA
    mov ecx, 256
    rep outsw

    ; Flush cache
    mov dx, ATA_CMD
    mov al, 0xE7          ; CACHE FLUSH
    out dx, al
    call ata_wait_ready

    ; Advance
    add r13, 512
    inc r12
    dec ebx
    jmp .write_loop

.write_done:
    xor eax, eax
    jmp .write_ret

.write_error:
    mov eax, -1

.write_ret:
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; --- Internal helpers ---

ata_wait_ready:
    ; Wait for BSY to clear, timeout after ~1M iterations
    push rcx
    mov ecx, 1000000
.wr_loop:
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_BSY
    jz .wr_ok
    dec ecx
    jnz .wr_loop
    pop rcx
    mov eax, -1
    ret
.wr_ok:
    pop rcx
    xor eax, eax
    ret

ata_wait_drq:
    ; Wait for DRQ (data request) bit, with timeout
    push rcx
    mov ecx, 1000000
.wdrq_loop:
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_ERR
    jnz .wdrq_err
    test al, ATA_SR_DRQ
    jnz .wdrq_ok
    dec ecx
    jnz .wdrq_loop
.wdrq_err:
    pop rcx
    mov eax, -1
    ret
.wdrq_ok:
    pop rcx
    xor eax, eax
    ret


; Helper: Select drive and wait for ready
; Uses r12d (LBA) for top bits, [ata_drive_sel] for drive
; Returns eax=0 success, -1 error
ata_select_drive:
    push dx
    push ax
    
    ; Select drive
    mov eax, r12d
    shr eax, 24
    and al, 0x0F
    or al, [ata_drive_sel]
    mov dx, ATA_DRIVE
    out dx, al
    
    ; IO Wait (400ns)
    call ata_io_wait
    
    pop ax
    pop dx
    
    ; Wait for BSY to clear
    call ata_wait_ready
    ret

; Helper: IO Wait
ata_io_wait:
    push dx
    push ax
    mov dx, ATA_STATUS
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    pop ax
    pop dx
    ret

section .data
    ata_drive_sel db 0xE0

