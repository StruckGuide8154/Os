; ============================================================================
; Grit v3.0 - ATA PIO Disk Driver
; Provides sector read/write using ATA PIO mode (ports 0x1F0-0x1F7)
; ============================================================================
bits 64

%include "constants.inc"

extern tick_count
extern ramdisk_intercept_read
extern ramdisk_intercept_write

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
    ; RAM-disk fast path. If a ramdisk region covers this LBA range, the
    ; entire request is served from memory and we never touch the IDE
    ; ports. This is what makes the kernel work on real hardware that
    ; lacks a legacy IDE controller (NVMe-only laptops, USB-boot).
    ; eax: 1=handled, 0=outside region (fall through), -1=partial overlap.
    call ramdisk_intercept_read
    test eax, eax
    jz .ata_pio_read
    cmp eax, 1
    je .read_ramdisk_ok
    mov eax, -1                 ; partial overlap is a kernel bug
    ret
.read_ramdisk_ok:
    xor eax, eax
    ret

.ata_pio_read:
    ; Float-bus probe. On real hardware with no legacy IDE controller (NVMe /
    ; USB boot, no DATA.IMG ramdisk) the status port reads back 0xFF because the
    ; bus floats high. Without this check each sector read would burn the full
    ; ~268M-iteration tick-free spin in ata_wait_drq/ready (interrupts are off
    ; during fat16_init), stalling boot for seconds before failing. Detect the
    ; absent controller in one IN and fail immediately instead.
    call ata_bus_present
    test eax, eax
    jnz .read_bus_ok
    mov eax, -1
    ret
.read_bus_ok:
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
    ; RAM-disk fast path. See ata_read_sectors for rationale. Writes are
    ; not propagated back to DATA.IMG on disk - they live for the boot
    ; session only, matching QEMU without -snapshot=off.
    call ramdisk_intercept_write
    test eax, eax
    jz .ata_pio_write
    cmp eax, 1
    je .write_ramdisk_ok
    mov eax, -1
    ret
.write_ramdisk_ok:
    xor eax, eax
    ret

.ata_pio_write:
    ; Float-bus probe - see ata_read_sectors / .ata_pio_read.
    call ata_bus_present
    test eax, eax
    jnz .write_bus_ok
    mov eax, -1
    ret
.write_bus_ok:
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

; ata_bus_present - one-shot float-bus detection. Reads the primary status port
; once; if every bit is set (0xFF) the IDE data bus is floating high, i.e. there
; is no controller responding. Returns eax=1 if a controller appears present,
; eax=0 if absent. No spin, no PIT dependency: safe to call with interrupts off.
ata_bus_present:
    ; Preserve rdx: ata_read/write_sectors call this BEFORE consuming their
    ; edx=sector_count argument. Clobbering dx here turned every PIO request
    ; into a 0x1F7(=503)-sector transfer that sprayed disk bytes over the
    ; kernel image (latent until the first sub-FAT16_PART_LBA caller, since
    ; ramdisk-intercepted I/O returns before reaching this probe).
    push rdx
    mov dx, ATA_STATUS
    in al, dx
    pop rdx
    cmp al, 0xFF
    je .abp_absent
    mov eax, 1
    ret
.abp_absent:
    xor eax, eax
    ret

; PIT-based deadline waits. CPU-spin loops are unreliable across CPU clocks
; (too short on fast real HW, too long on slow QEMU). 100 ticks = 1 second.
ata_wait_ready:
    push rbx
    push rcx
    mov rbx, [tick_count]
    add rbx, 100
    ; Spin-count fallback deadline. fat16_init runs with interrupts disabled
    ; (sti is deferred until after the FAT cache fill to keep the PIT IRQ out of
    ; that window), so tick_count does not advance here. Without a tick-free
    ; bound a hung drive would spin forever; ~256M pause-iterations is a coarse
    ; multi-second wall-clock cap that terminates even with IF=0.
    mov rcx, 0x10000000
.wr_loop:
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_BSY
    jz .wr_ok
    mov rax, [tick_count]
    cmp rax, rbx
    jae .wr_timeout
    dec rcx
    jz .wr_timeout
    pause
    jmp .wr_loop
.wr_timeout:
    pop rcx
    pop rbx
    mov eax, -1
    ret
.wr_ok:
    pop rcx
    pop rbx
    xor eax, eax
    ret

ata_wait_drq:
    push rbx
    push rcx
    mov rbx, [tick_count]
    add rbx, 100
    ; Tick-free spin fallback - see ata_wait_ready (sti is deferred past the
    ; FAT cache fill, so tick_count is frozen during fat16_init).
    mov rcx, 0x10000000
.wdrq_loop:
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_ERR
    jnz .wdrq_err
    test al, ATA_SR_DRQ
    jnz .wdrq_ok
    mov rax, [tick_count]
    cmp rax, rbx
    jae .wdrq_err
    dec rcx
    jz .wdrq_err
    pause
    jmp .wdrq_loop
.wdrq_err:
    pop rcx
    pop rbx
    mov eax, -1
    ret
.wdrq_ok:
    pop rcx
    pop rbx
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

