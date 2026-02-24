; ============================================================================
; NexusOS v3.0 - Stage 2 Bootloader
; Loaded at 0x7E00 by MBR. Enters long mode and jumps to kernel at 0x100000.
; Flow: A20 -> E820 -> VESA -> Load Kernel -> Paging -> PM -> LM -> Kernel
; ============================================================================
bits 16
org 0x7E00

stage2_start:
    dw 0x4E58               ; 'NX' magic number (verified by MBR)

stage2_entry:
    ; Save boot drive (passed in DL by MBR)
    mov [BOOT_DRIVE_ADDR], dl

    ; Set up segments
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; Init COM1 for serial debug
    call serial_init

    ; Print status
    mov si, msg_stage2
    call print16_s2

    mov al, dl
    call print_hex

    ; Step 1: Enable A20
    call enable_a20
    mov si, msg_a20_ok
    call print16_s2
    mov al, '1'
    call serial_putc

    ; Step 2: Probe memory with E820
    call probe_memory
    mov si, msg_e820_ok
    call print16_s2
    mov al, '2'
    call serial_putc

    ; Step 3: Load kernel from disk to 0x100000
    call load_kernel
    mov si, msg_kern_ok
    call print16_s2
    mov al, '3'
    call serial_putc

    ; Verify kernel loaded: check first 4 bytes at 0x100000
    ; (load_kernel already entered unreal mode at the end)
    mov edi, 0x100000
    a32 mov eax, [ds:edi]
    test eax, eax
    jnz .kern_ok
    mov al, 'Z'           ; 'Z' = kernel is zeros!
    call serial_putc
    jmp .kern_diag_done
.kern_ok:
    mov al, 'K'           ; 'K' = kernel has data
    call serial_putc
.kern_diag_done:

    ; Step 4: Set VESA mode (must be done in real mode!)
    call setup_vesa
    ; Screen is now in graphics mode - no more text output via INT 10h
    mov al, '4'
    call serial_putc

    ; Step 5: Build page tables
    call setup_paging
    mov al, '5'
    call serial_putc

    ; Step 6: Enter Protected Mode
    cli
    lgdt [gdt32_ptr]
    mov eax, cr0
    or eax, 1               ; Set PE bit
    mov cr0, eax
    jmp GDT32_CODE_SEG:.pm_entry

bits 32
.pm_entry:
    ; In 32-bit Protected Mode
    mov ax, GDT32_DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Step 7: Enable PAE
    mov eax, cr4
    or eax, (1 << 5)        ; Set PAE bit
    mov cr4, eax

    ; Step 8: Load PML4 into CR3
    mov eax, 0x70000         ; PML4 physical address
    mov cr3, eax

    ; Step 9: Enable Long Mode in EFER MSR
    mov ecx, 0xC0000080      ; IA32_EFER MSR
    rdmsr
    or eax, (1 << 8)         ; Set LME (Long Mode Enable)
    wrmsr

    ; Step 10: Enable paging (enters compatibility mode)
    mov eax, cr0
    or eax, (1 << 31)        ; Set PG bit
    mov cr0, eax

    ; Step 11: Load 64-bit GDT and far jump to 64-bit code
    lgdt [gdt64_ptr]
    jmp GDT64_CODE_SEG:.lm_entry

bits 64
.lm_entry:
    ; In 64-bit Long Mode!
    mov ax, GDT64_DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Set up kernel stack
    mov rsp, 0x200000        ; KERNEL_STACK_TOP

    ; Serial: '6' = reached long mode
    mov dx, 0x3F8 + 5
.s6wait:
    in al, dx
    test al, 0x20
    jz .s6wait
    mov dx, 0x3F8
    mov al, '6'
    out dx, al

    ; Paint screen GREEN as proof of Stage 2 completion
    mov eax, [0x9000]        ; Framebuffer address from VBE info
    mov edi, eax
    mov ecx, (1024 * 768)    ; Number of pixels
    mov eax, 0x0000FF00      ; GREEN
    rep stosd

    ; Serial: '7' = about to jump to kernel
    mov dx, 0x3F8 + 5
.s7wait:
    in al, dx
    test al, 0x20
    jz .s7wait
    mov dx, 0x3F8
    mov al, '7'
    out dx, al

    ; Check if kernel is actually loaded (first dword should not be zero)
    mov eax, [0x100000]
    test eax, eax
    jnz .kernel_present
    ; Kernel is zeros! Serial '!' and halt
    mov dx, 0x3F8 + 5
.sewait:
    in al, dx
    test al, 0x20
    jz .sewait
    mov dx, 0x3F8
    mov al, '!'
    out dx, al
    cli
    hlt
.kernel_present:
    ; Serial '8' = kernel looks valid
    mov dx, 0x3F8 + 5
.s8wait:
    in al, dx
    test al, 0x20
    jz .s8wait
    mov dx, 0x3F8
    mov al, '8'
    out dx, al

    ; Jump to kernel at 0x100000
    mov rax, 0x100000
    jmp rax

; ============================================================================
; 16-bit Support Routines (included files)
; ============================================================================
bits 16

; --- Serial port (COM1 = 0x3F8) debug output ---
serial_init:
    push ax
    push dx
    mov dx, 0x3F8 + 1    ; IER
    xor al, al
    out dx, al            ; Disable interrupts
    mov dx, 0x3F8 + 3    ; LCR
    mov al, 0x80          ; DLAB=1
    out dx, al
    mov dx, 0x3F8 + 0    ; DLL
    mov al, 0x01          ; 115200 baud
    out dx, al
    mov dx, 0x3F8 + 1    ; DLM
    xor al, al
    out dx, al
    mov dx, 0x3F8 + 3    ; LCR
    mov al, 0x03          ; 8N1
    out dx, al
    mov dx, 0x3F8 + 2    ; FCR
    mov al, 0xC7          ; Enable FIFO
    out dx, al
    pop dx
    pop ax
    ret

serial_putc:
    push dx
    push ax
    mov dx, 0x3F8 + 5
.wait:
    in al, dx
    test al, 0x20         ; THR empty?
    jz .wait
    pop ax
    mov dx, 0x3F8
    out dx, al
    pop dx
    ret

; --- Print null-terminated string in real mode ---
print16_s2:
    pusha
.loop:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp .loop
.done:
    popa
    ret

; --- Print hex byte (AL) ---
print_hex:
    pusha
    mov cx, ax
    mov bx, 0x0007
    
    ; High nibble
    mov al, cl
    shr al, 4
    call .nibble
    
    ; Low nibble
    mov al, cl
    and al, 0x0F
    call .nibble
    
    mov al, ' '
    mov ah, 0x0E
    int 0x10
    
    popa
    ret
    
.nibble:
    add al, '0'
    cmp al, '9'
    jle .ok
    add al, 7
.ok:
    mov ah, 0x0E
    int 0x10
    ret

; --- Probe memory using INT 15h, EAX=E820h ---
; Stores entries at E820_MAP_ADDR (0x2000)
; Stores count at E820_COUNT_ADDR (0x1FF0)
probe_memory:
    mov di, 0x2000           ; ES:DI -> buffer for E820 entries
    xor ebx, ebx            ; Continuation value (0 = start)
    xor si, si              ; Entry counter

.e820_loop:
    mov eax, 0x0000E820
    mov ecx, 24              ; Buffer size (24 bytes per entry)
    mov edx, 0x534D4150      ; 'SMAP' signature
    int 0x15

    jc .e820_done            ; CF=1 on error or end
    cmp eax, 0x534D4150      ; Verify 'SMAP' signature returned
    jne .e820_done

    ; Valid entry
    inc si
    add di, 24              ; Next entry slot

    test ebx, ebx           ; EBX=0 means last entry
    jz .e820_done
    jmp .e820_loop

.e820_done:
    mov [0x1FF0], si         ; Store entry count
    ret

; --- Load kernel from disk sectors 64+ to 0x100000 ---
; Strategy: Load all sectors to temp buffer at 0x10000-0x2FFFF (128KB below 1MB)
; then use Unreal Mode to copy the whole thing to 0x100000 in one go.
; This avoids the problem of BIOS INT 13h destroying unreal mode segment limits.
load_kernel:
    ; Get Drive Geometry for CHS fallback
    mov ah, 0x08
    mov dl, [BOOT_DRIVE_ADDR]
    int 0x13
    jc .geo_fail
    and cx, 0x3F            ; CL bits 0-5 = Max Sector
    mov [drv_spt], cx
    movzx dx, dh
    inc dx                  ; Max Head + 1
    mov [drv_heads], dx
    jmp .start_load

.geo_fail:
    mov word [drv_spt], 63
    mov word [drv_heads], 16

.start_load:
    ; Phase 1: Read all kernel sectors to temp buffer below 1MB
    ; Temp buffer: 0x1000:0x0000 = phys 0x10000
    ; Max 256 sectors = 128KB. Buffer extends to 0x30000.
    mov dword [kern_lba], 64         ; Starting LBA sector
    mov word [kern_remaining], 256   ; Sectors remaining (128KB)
    mov word [kern_buf_seg], 0x1000  ; Current segment for loading
    mov word [kern_buf_off], 0x0000  ; Current offset

.read_loop:
    cmp word [kern_remaining], 0
    je .read_done

    ; Try LBA first - update DAP fields first, then set registers
    mov word [kern_dap + 2], 1          ; 1 sector
    mov ax, [kern_buf_off]
    mov [kern_dap + 4], ax              ; Offset
    mov ax, [kern_buf_seg]
    mov [kern_dap + 6], ax              ; Segment
    mov eax, [kern_lba]
    mov [kern_dap + 8], eax             ; LBA
    ; Now set INT 13h registers (after DAP is fully prepared)
    mov ah, 0x42
    mov dl, [BOOT_DRIVE_ADDR]
    mov si, kern_dap
    int 0x13
    jnc .read_next                      ; LBA worked

    ; LBA Failed, try CHS
    call lba_to_chs_read_v2
    jc .load_fail

.read_next:
    ; Advance buffer pointer (512 bytes = 0x200)
    mov ax, [kern_buf_off]
    add ax, 0x200
    jnc .no_seg_wrap                    ; If no overflow, keep going
    ; Overflow: advance segment by 0x1000 (64KB), reset offset
    add word [kern_buf_seg], 0x1000
    xor ax, ax
.no_seg_wrap:
    mov [kern_buf_off], ax

    inc dword [kern_lba]
    dec word [kern_remaining]
    jmp .read_loop

.read_done:
    ; Verify temp buffer has data (check first 4 bytes at 0x1000:0x0000 = phys 0x10000)
    push es
    mov ax, 0x1000
    mov es, ax
    mov eax, [es:0]
    pop es
    test eax, eax
    jnz .tmp_ok
    mov al, 'T'          ; 'T' = temp buffer is empty!
    call serial_putc
    jmp .copy_skip
.tmp_ok:
    mov al, 'B'          ; 'B' = buffer has data
    call serial_putc

    ; Phase 2: Enter Unreal Mode and copy from temp buffer to 0x100000
    call enter_unreal

    ; Copy 256 * 512 = 131072 bytes from 0x10000 to 0x100000
    mov esi, 0x10000         ; Source (physical)
    mov edi, 0x100000        ; Destination (physical)
    mov ecx, (256 * 512) / 4 ; Dword count = 32768
.copy_loop:
    a32 mov eax, [ds:esi]
    a32 mov [ds:edi], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .copy_loop

    ; Verify copy worked
    mov edi, 0x100000
    a32 mov eax, [ds:edi]
    test eax, eax
    jnz .copy_ok
    mov al, 'X'          ; 'X' = copy failed
    call serial_putc
    jmp .copy_skip
.copy_ok:
    mov al, 'C'          ; 'C' = copy succeeded
    call serial_putc
.copy_skip:
    ret

.load_fail:
    mov si, msg_load_err
    call print16_s2
    mov al, ah
    call print_hex
    jmp $

; --- LBA to CHS Read Routine (v2) ---
; Input: [kern_lba], [kern_buf_seg], [kern_buf_off]
; Output: Reads 1 sector to [kern_buf_seg]:[kern_buf_off]
lba_to_chs_read_v2:
    push ax
    push bx
    push cx
    push dx

    ; LBA / SPT
    mov ax, [kern_lba]  ; Low 16 bits of LBA (enough for kernel)
    xor dx, dx
    div word [drv_spt]  ; AX = LBA / SPT, DX = LBA % SPT

    inc dx              ; Sector = (LBA % SPT) + 1
    mov cx, dx          ; CL = Sector

    ; Temp / Heads
    xor dx, dx
    div word [drv_heads]; AX = Cylinder, DX = Head

    ; Construct DX (Head) and CX (Cylinder/Sector)
    mov dh, dl          ; Head
    mov ch, al          ; Cylinder Low
    shl ah, 6
    or cl, ah           ; Cylinder High (bits 8-9) in CL bits 6-7

    mov dl, [BOOT_DRIVE_ADDR]
    mov ax, [kern_buf_seg]
    mov es, ax
    mov bx, [kern_buf_off]  ; ES:BX = target buffer

    mov ah, 0x02        ; Read Sectors
    mov al, 1           ; Count = 1
    int 0x13

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- Enter Unreal Mode (Big Real Mode) ---
; Allows 32-bit addressing in real mode segments
enter_unreal:
    cli
    push ds
    push es
    lgdt [gdt32_ptr]
    mov eax, cr0
    or al, 1                ; Enter protected mode
    mov cr0, eax
    mov bx, GDT32_DATA_SEG
    mov ds, bx              ; Load descriptor with 4GB limit
    mov es, bx              ; Load ES key
    and al, 0xFE            ; Back to real mode
    mov cr0, eax
    pop es                  ; Restore ES segment (but limit stays 4GB)
    pop ds                  ; Restore DS segment (but limit stays 4GB)
    sti
    ret

; --- Kernel load data ---
kern_lba:       dd 0
kern_remaining: dw 0
kern_buf_seg:   dw 0x1000
kern_buf_off:   dw 0x0000
drv_spt:        dw 63
drv_heads:      dw 16

align 4
kern_dap:
    db 0x10                 ; DAP size
    db 0                    ; Reserved
    dw 0                    ; Sector count (filled in)
    dw 0x0000               ; Offset = 0x10000
    dw 0x1000               ; Segment = 0x1000 (segment:offset = 0x1000:0x0000 = 0x10000)
    dq 0                    ; LBA (filled in)

; --- Messages ---
msg_stage2:  db 13, 10, 'Stage2 ', 0
msg_a20_ok:  db 'A20 ', 0
msg_e820_ok: db 'E820 ', 0
msg_kern_ok: db 'Kern ', 0
msg_load_err: db 'LoadErr', 0

BOOT_DRIVE_ADDR equ 0x0600

; ============================================================================
; Include boot helper files
; ============================================================================
%include "a20.asm"
%include "gdt.asm"
%include "vesa.asm"
%include "paging.asm"

; Pad stage2 to fill its allocated sectors
times (63 * 512) - ($ - $$) db 0
