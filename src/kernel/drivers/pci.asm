; ============================================================================
; Grit v3.0 - PCI Driver
; Basic mechanism to read/write PCI configuration space
; ============================================================================
bits 64

AMD_GPU_VENDOR_ID      equ 0x1002
AMD_RADEON_780M_DEVID  equ 0x15BF
PCI_DISPLAY_CLASS      equ 0x03

section .data
global pci_gpu_scan_done
global pci_gpu_count
global pci_gpu_radeon780m_found
global pci_gpu_radeon780m_bdf
global pci_gpu_radeon780m_id
global pci_gpu_radeon780m_class
global pci_gpu_radeon780m_bar0
global pci_gpu_radeon780m_cmd
global pci_gpu_amd_display_found
global pci_gpu_amd_display_bdf
global pci_gpu_amd_display_id
global pci_gpu_amd_display_class
global pci_gpu_amd_display_bar0
global pci_gpu_amd_display_cmd
pci_gpu_scan_done:        db 0
pci_gpu_count:            db 0
pci_gpu_radeon780m_found: db 0
pci_gpu_radeon780m_bdf:   dd 0
pci_gpu_radeon780m_id:    dd 0
pci_gpu_radeon780m_class: dd 0
pci_gpu_radeon780m_bar0:  dq 0
pci_gpu_radeon780m_cmd:   dd 0
pci_gpu_amd_display_found: db 0
pci_gpu_amd_display_bdf:   dd 0
pci_gpu_amd_display_id:    dd 0
pci_gpu_amd_display_class: dd 0
pci_gpu_amd_display_bar0:  dq 0
pci_gpu_amd_display_cmd:   dd 0

section .text

; --- Read 32-bit word from PCI Config Space ---
; Arguments:
;   RBX = Bus (8 bits) | Device (5 bits) | Function (3 bits) | Register (8 bits, must be dword aligned)
;         Format: 0000:bbbb:bbbb:dddd:dfff:rrrr:rr00
;         Actually standard format is:
;         Bit 31: Enable (1)
;         Bit 30-24: Reserved
;         Bit 23-16: Bus
;         Bit 15-11: Device
;         Bit 10-8: Function
;         Bit 7-2: Register (00- FC)
;
;   We'll take a packed address in EAX or separate args?
;   Let's use a simpler signature:
;   EAX = Packed Address (Bus << 16 | Dev << 11 | Func << 8 | Reg)
; Returns:
;   EAX = Value
global pci_read_conf_dword
pci_read_conf_dword:
    push rdx
    
    or eax, 0x80000000       ; Set Enable bit
    mov dx, 0xCF8
    out dx, eax
    
    mov dx, 0xCFC
    in eax, dx
    
    pop rdx
    ret

; --- Write 32-bit word to PCI Config Space ---
; Arguments:
;   EAX = Packed Address
;   ECX = Value
global pci_write_conf_dword
pci_write_conf_dword:
    push rdx
    
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    
    mov dx, 0xCFC
    mov eax, ecx
    out dx, eax
    
    pop rdx
    ret

; --- Scan PCI config space for display controllers and the AMD Radeon 780M ---
; Keeps the device identity as the physical 1:1 bus/device/function tuple:
;   pci_gpu_radeon780m_bdf = bus<<16 | dev<<8 | function
global pci_gpu_scan
pci_gpu_scan:
    mov byte [pci_gpu_scan_done], 1
    mov byte [pci_gpu_count], 0
    mov byte [pci_gpu_radeon780m_found], 0
    mov dword [pci_gpu_radeon780m_bdf], 0
    mov dword [pci_gpu_radeon780m_id], 0
    mov dword [pci_gpu_radeon780m_class], 0
    mov qword [pci_gpu_radeon780m_bar0], 0
    mov dword [pci_gpu_radeon780m_cmd], 0
    mov byte [pci_gpu_amd_display_found], 0
    mov dword [pci_gpu_amd_display_bdf], 0
    mov dword [pci_gpu_amd_display_id], 0
    mov dword [pci_gpu_amd_display_class], 0
    mov qword [pci_gpu_amd_display_bar0], 0
    mov dword [pci_gpu_amd_display_cmd], 0

    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    xor r12d, r12d                ; display controller count
    xor r8d, r8d                  ; bus
.bus:
    cmp r8d, 256
    jge .done
    xor r9d, r9d                  ; device
.dev:
    cmp r9d, 32
    jge .next_bus
    xor r10d, r10d                ; function
.fn:
    cmp r10d, 8
    jge .next_dev

    ; Packed config base = bus<<16 | dev<<11 | fn<<8.
    mov eax, r8d
    shl eax, 16
    mov ecx, r9d
    shl ecx, 11
    or eax, ecx
    mov ecx, r10d
    shl ecx, 8
    or eax, ecx
    mov r11d, eax

    call pci_read_conf_dword
    cmp eax, 0xFFFFFFFF
    je .next_fn
    mov r13d, eax                 ; device/vendor dword

    mov eax, r11d
    or eax, 0x08
    call pci_read_conf_dword
    mov r14d, eax                 ; class/subclass/progIF/rev
    mov ecx, eax
    shr ecx, 24
    cmp ecx, PCI_DISPLAY_CLASS
    jne .check_780m
    inc r12d

    cmp byte [pci_gpu_amd_display_found], 0
    jne .check_780m
    mov eax, r13d
    and eax, 0xFFFF
    cmp eax, AMD_GPU_VENDOR_ID
    jne .check_780m
    mov byte [pci_gpu_amd_display_found], 1
    mov [pci_gpu_amd_display_id], r13d
    mov [pci_gpu_amd_display_class], r14d
    mov eax, r8d
    shl eax, 16
    mov ecx, r9d
    shl ecx, 8
    or eax, ecx
    or eax, r10d
    mov [pci_gpu_amd_display_bdf], eax

    ; Keep passive bring-up metadata for the generic AMD display fallback too.
    ; Linux amdgpu matches a broad AMD PCI ID table, then discovers hardware IP
    ; blocks later; this stage keeps identity only and still avoids enabling
    ; decode or touching MMIO.
    mov eax, r11d
    or eax, 0x04
    call pci_read_conf_dword
    mov [pci_gpu_amd_display_cmd], eax

    ; Ensure MEMORY + BUS_MASTER are enabled on the AMD iGPU. UEFI normally
    ; sets these for any device with an active framebuffer, but a few
    ; vendor BIOSes leave Bus Master off - which silently breaks any path
    ; that lets the GPU initiate reads (PSP DMA, IMU autoload, CP ucode
    ; fetch). Setting these bits when already set is a no-op; setting them
    ; when off cannot hurt - we never need to *clear* MEMORY/BM on a
    ; running display device.
    mov ecx, eax                         ; ecx = current cmd
    and ecx, 0x0000FFFF                  ; keep low 16 bits (PCI cmd is 16-bit)
    or  ecx, 0x0006                      ; bit 1 = MEMORY, bit 2 = BUS_MASTER
    mov eax, r11d
    or  eax, 0x04
    call pci_write_conf_dword
    ; Re-read so the latched value reflects what's actually set.
    mov eax, r11d
    or  eax, 0x04
    call pci_read_conf_dword
    mov [pci_gpu_amd_display_cmd], eax

    mov eax, r11d
    or eax, 0x10
    call pci_read_conf_dword
    mov ebx, eax
    mov r15d, eax
    and r15d, 0xFFFFFFF0
    test ebx, 0x04
    jz .store_amd_bar0
    mov eax, r11d
    or eax, 0x14
    call pci_read_conf_dword
    shl rax, 32
    or r15, rax
.store_amd_bar0:
    mov [pci_gpu_amd_display_bar0], r15

.check_780m:
    mov eax, r13d
    and eax, 0xFFFF
    cmp eax, AMD_GPU_VENDOR_ID
    jne .next_fn
    mov eax, r13d
    shr eax, 16
    cmp eax, AMD_RADEON_780M_DEVID
    jne .next_fn

    mov byte [pci_gpu_radeon780m_found], 1
    mov [pci_gpu_radeon780m_id], r13d
    mov [pci_gpu_radeon780m_class], r14d

    ; Human-readable 1:1 BDF: bus<<16 | dev<<8 | function.
    mov eax, r8d
    shl eax, 16
    mov ecx, r9d
    shl ecx, 8
    or eax, ecx
    or eax, r10d
    mov [pci_gpu_radeon780m_bdf], eax

    ; Passive identity only: do not write command register, enable decode,
    ; or touch BAR MMIO during hardware bring-up.
    mov eax, r11d
    or eax, 0x04
    call pci_read_conf_dword
    mov [pci_gpu_radeon780m_cmd], eax

    mov eax, r11d
    or eax, 0x10
    call pci_read_conf_dword
    mov ebx, eax
    mov r15d, eax
    and r15d, 0xFFFFFFF0
    test ebx, 0x04
    jz .store_bar0
    mov eax, r11d
    or eax, 0x14
    call pci_read_conf_dword
    shl rax, 32
    or r15, rax
.store_bar0:
    mov [pci_gpu_radeon780m_bar0], r15

.next_fn:
    inc r10d
    jmp .fn
.next_dev:
    inc r9d
    jmp .dev
.next_bus:
    inc r8d
    jmp .bus
.done:
    cmp r12d, 255
    jbe .store_count
    mov r12d, 255
.store_count:
    mov [pci_gpu_count], r12b

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
