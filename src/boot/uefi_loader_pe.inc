; ============================================================================
; PE/COFF HEADER
; ============================================================================
section .text start=0
    dw 0x5A4D                       ; MZ
    times 29 dw 0
    dd pe_hdr

pe_hdr:
    dd 0x00004550                   ; "PE\0\0"
    dw 0x8664                       ; x86-64
    dw 2                            ; 2 sections
    dd 0, 0, 0
    dw opt_end - opt_hdr
    dw 0x0206

opt_hdr:
    dw 0x020B                       ; PE32+
    db 1, 0
    dd TEXT_RAW, 0, 0, TEXT_VA, TEXT_VA
    dq KERN_DEST                    ; Image base (preferred)
    dd 0x1000, 0x200                ; Section / file alignment
    dw 0,0, 0,0, 0,0
    dd 0, IMAGE_SZ, HDR_SZ, 0
    dw 10, 0                        ; Subsystem: EFI Application
    dq KERN_DEST, KERN_DEST, KERN_DEST, KERN_DEST
    dd 0, 6                         ; Data directory count
    dd 0,0, 0,0, 0,0, 0,0, 0,0
    dd RELOC_VA, RELOC_VSZ          ; Base reloc directory
opt_end:

    db '.text',0,0,0
    dd TEXT_RAW, TEXT_VA, TEXT_RAW, HDR_SZ
    dd 0, 0
    dw 0, 0
    dd 0xE0000060                   ; Code | Execute | Read | Write

    db '.reloc',0,0
    dd RELOC_VSZ, RELOC_VA, RELOC_FSZ, RELOC_FOFF
    dd 0, 0
    dw 0, 0
    dd 0x42000040                   ; Initialized data | Discardable | Read

    times (HDR_SZ - ($ - $$)) db 0
