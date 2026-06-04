; ============================================================================
; GDT  (copied to 0x500 before any kernel activity)
; CS = 0x08 (64-bit code), DS/ES/SS = 0x10 (data)
; ============================================================================
align 16
gdt64:
    dq 0                            ; Null

gdt64_code:
    dw 0x0000, 0x0000               ; Limit, Base[15:0]
    db 0x00                         ; Base[23:16]
    db 10011010b                    ; P=1 DPL=0 S=1 Type=1010 (Code R/X)
    db 00100000b                    ; L=1 (64-bit), D=0
    db 0x00                         ; Base[31:24]

gdt64_data:
    dw 0x0000, 0x0000
    db 0x00
    db 10010010b                    ; P=1 DPL=0 S=1 Type=0010 (Data R/W)
    db 00000000b
    db 0x00

gdt64_user_code32:                  ; Selector 0x18 - user 32-bit code placeholder (sysret layout)
    dq 0x00CFFA000000FFFF

gdt64_user_data:                    ; Selector 0x20 - user data DPL=3
    dw 0x0000, 0x0000
    db 0x00
    db 11110010b
    db 00000000b
    db 0x00

gdt64_user_code64:                  ; Selector 0x28 - user 64-bit code DPL=3
    dw 0x0000, 0x0000
    db 0x00
    db 11111010b
    db 00100000b
    db 0x00

gdt64_tss_uefi:                     ; Selector 0x30 - TSS descriptor (16 bytes)
    dw 103                          ; Limit (104 bytes - 1)
    dw 0                            ; Base[15:0]  (filled by tss_init)
    db 0                            ; Base[23:16]
    db 10001001b                    ; Present, TSS Available
    db 0                            ; Flags + Limit High
    db 0                            ; Base[31:24]
    dq 0                            ; Base[63:32] + reserved

gdt64_end:

; ============================================================================
; Protocol GUIDs
; ============================================================================
align 4
guid_gop:
    dd 0x9042a9de
    dw 0x23dc, 0x4a38
    db 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a

guid_sfs:
    dd 0x964e5b22
    dw 0x6459, 0x11d2
    db 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

; EFI_BLOCK_IO_PROTOCOL (964e5b21-6459-11d2-8e39-00a0c9697239)
guid_blkio:
    dd 0x964e5b21
    dw 0x6459, 0x11d2
    db 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x39

guid_lip:
    dd 0x5b1b31a1
    dw 0x9562, 0x11d2
    db 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

; EFI_SIMPLE_POINTER_PROTOCOL
guid_spp:
    dd 0x31878c87
    dw 0x0b75, 0x11d5
    db 0x9a, 0x4f, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d

; ============================================================================
; UCS-2 file paths
; ============================================================================
align 2
s_kern_path:    ustr "\EFI\BOOT\KERNEL.BIN"
s_apps_path:    ustr "\EFI\BOOT\APPS.BIN"
s_data_path:    ustr "\EFI\BOOT\DATA.IMG"
s_klog_path:    ustr "\KLOG.TXT"

; FAT32 8.3 path components for \EFI\BOOT\DATA.IMG extent resolution.
s_efi_83:       db 'EFI     ', '   '
s_boot_83:      db 'BOOT    ', '   '
s_data_83:      db 'DATA    ', 'IMG'

; ============================================================================
; Variables
; ============================================================================
align 8
v_handle:      dq 0
v_systab:      dq 0
v_bs:          dq 0
v_gop:         dq 0
v_spp:         dq 0
v_fb:          dq 0
v_scrw:        dd 0
v_scrh:        dd 0
v_pitch:       dd 0
v_lip:         dq 0
v_devhandle:   dq 0
v_sfs:         dq 0
v_root:        dq 0
v_file:        dq 0
v_kernel_addr: dq 0
v_ksize:       dq 0
v_apps_size:   dq 0
v_data_size:   dq 0
v_tmp_addr:    dq 0

; --- KASLR container parse results (filled post-ExitBootServices) -----------
v_payload_src:  dq 0
v_payload_size: dq 0
v_fixup_src:    dq 0
v_fixup_count:  dq 0
v_entry_off:    dq 0
v_kslide:       dq 0

; --- Phase 1b: storage extent resolution scratch -------------------------
; Populated by resolve_data_img_extents. Once Phase 2/3 land (NVMe / USB-MSC)
; the kernel's ramdisk_flush will consult these via VBE_INFO + the extent
; table at STORAGE_EXTENTS_ADDR to write dirty ramdisk pages back to the ESP.
v_blkio:        dq 0
v_bpb_buf:      dq 0    ; 4 KiB scratch page, sector 0 of partition
v_part_blksz:   dd 0
v_part_mediaid: dd 0
v_fat_secperclus:    dd 0
v_fat_rsvd:          dd 0
v_fat_numfats:       dd 0
v_fat_size32:        dd 0
v_fat_rootclus:      dd 0
v_fat_first_data_sec: dd 0
v_data_first_clus:   dd 0
v_data_file_size:    dd 0
