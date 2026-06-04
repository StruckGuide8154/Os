; ============================================================================
; RESOLVE_DATA_IMG_EXTENTS - Phase 1b (partial)
; ----------------------------------------------------------------------------
; While firmware services are still alive, open EFI_BLOCK_IO_PROTOCOL on the
; boot device handle (which is the ESP partition), read its BPB, and capture
; the FAT32 parameters needed to walk DATA.IMG's cluster chain.
;
; Status:
;   [x] HandleProtocol(devhandle, BlockIoGuid)
;   [x] Allocate sector scratch
;   [x] Read partition LBA 0 and parse FAT32 BPB into v_fat_* fields
;   [ ] Walk root directory cluster, find "DATA    IMG" entry          (TODO Phase 1b.2)
;   [ ] Walk FAT32 chain, coalesce runs into extents at               (TODO Phase 1b.3)
;       STORAGE_EXTENTS_ADDR, write VBE_STORAGE_EXT_* fields
;   [ ] Resolve partition-relative -> absolute disk LBA via            (TODO Phase 1b.4)
;       DevicePath HARDDRIVE node (needed when NVMe driver lands)
;
; Until Phase 1b.2-1b.3 land, VBE_STORAGE_EXT_CNT_OFF stays 0 so the kernel's
; ramdisk_flush keeps no-op behavior. The BPB capture below is non-destructive
; and idempotent - safe to call every boot.
;
; Non-fatal on every UEFI error: failure leaves the contract zeroed and the
; rest of boot is unaffected.
; ============================================================================
; EFI_BLOCK_IO_PROTOCOL layout
%define BIO_MEDIA      8
%define BIO_RESET      16
%define BIO_READ       24
%define BIO_WRITE      32
%define BIO_FLUSH      40

; EFI_BLOCK_IO_MEDIA layout (natural alignment, EFI 2.0)
%define BIOM_MEDIAID   0
%define BIOM_BLKSZ     32     ; UINT32 BlockSize after 5 BOOLEAN + pad
%define BIOM_LASTBLK   40     ; EFI_LBA LastBlock (u64, 8-aligned)
; Note: older EFI 1.x had BlockSize at +24; we don't support those.

; FAT32 BPB offsets (from start of partition sector 0)
%define BPB32_BYTSPSEC 11
%define BPB32_SECPCLUS 13
%define BPB32_RSVDSEC  14
%define BPB32_NUMFATS  16
%define BPB32_FATSZ32  36
%define BPB32_ROOTCLUS 44
%define BPB32_SIG      510    ; should be 0xAA55

; FAT32 directory entry offsets
%define DIRENT_ATTR       11
%define DIRENT_CLUS_HI    20
%define DIRENT_CLUS_LO    26
%define DIRENT_FILE_SIZE  28
%define ATTR_LONG_NAME    0x0F
%define ATTR_DIRECTORY    0x10
%define FAT32_EOC         0x0FFFFFF8

resolve_data_img_extents:
    push rbx
    push r12
    push r13
    sub rsp, 48
    ; [rsp+0..31] shadow
    ; [rsp+32]    arg5 slot

    SER 'X'                                  ; X = resolve_extents entered

    ; --- Zero contract fields up-front so any early return is "no backing" ---
    mov byte  [abs VBE_INFO + VBE_STORAGE_CLASS_OFF], 0
    mov byte  [abs VBE_INFO + VBE_STORAGE_LUN_OFF], 0
    mov word  [abs VBE_INFO + VBE_STORAGE_BLKSIZE_OFF], 0
    mov dword [abs VBE_INFO + VBE_STORAGE_EXT_CNT_OFF], 0
    mov qword [abs VBE_INFO + VBE_STORAGE_EXT_PTR_OFF], 0

    mov rax, [v_devhandle]
    test rax, rax
    jz .rdx_fail

    ; --- HandleProtocol(v_devhandle, &guid_blkio, &v_blkio) ---
    mov qword [v_blkio], 0
    mov rcx, [v_devhandle]
    lea rdx, [guid_blkio]
    lea r8,  [v_blkio]
    mov rax, [v_bs]
    mov rax, [rax + BS_HNDLPROT]
    call rax
    test rax, rax
    jnz .rdx_fail
    cmp qword [v_blkio], 0
    je .rdx_fail

    ; --- AllocatePages(AnyPages, EfiLoaderData, 1, &v_bpb_buf) ---
    mov qword [v_bpb_buf], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    mov ecx, 0
    mov edx, 2
    mov r8, 1
    lea r9, [v_bpb_buf]
    call rax
    test rax, rax
    jnz .rdx_fail
    cmp qword [v_bpb_buf], 0
    je .rdx_fail

    ; --- Capture media params (BlockSize, MediaId) ---
    mov rbx, [v_blkio]
    mov r12, [rbx + BIO_MEDIA]
    test r12, r12
    jz .rdx_fail
    mov eax, [r12 + BIOM_BLKSZ]
    cmp eax, 512
    jne .rdx_fail              ; only 512 B blocks supported today
    mov [v_part_blksz], eax
    mov eax, [r12 + BIOM_MEDIAID]
    mov [v_part_mediaid], eax

    ; --- ReadBlocks(This, MediaId, LBA=0, BufSz=512, Buf=v_bpb_buf) ---
    mov rcx, rbx
    mov edx, [v_part_mediaid]
    xor r8, r8                 ; LBA = 0
    mov r9, 512                ; BufferSize
    mov rax, [v_bpb_buf]
    mov [rsp+32], rax
    mov rax, [rbx + BIO_READ]
    call rax
    test rax, rax
    jnz .rdx_fail

    ; --- Validate boot signature, then FAT32 BPB ---
    mov r13, [v_bpb_buf]
    cmp word [r13 + BPB32_SIG], 0xAA55
    jne .rdx_fail
    movzx eax, word [r13 + BPB32_BYTSPSEC]
    cmp eax, 512
    jne .rdx_fail
    movzx eax, byte [r13 + BPB32_SECPCLUS]
    test eax, eax
    jz .rdx_fail
    mov [v_fat_secperclus], eax
    movzx eax, word [r13 + BPB32_RSVDSEC]
    test eax, eax
    jz .rdx_fail
    mov [v_fat_rsvd], eax
    movzx eax, byte [r13 + BPB32_NUMFATS]
    cmp eax, 1
    jb .rdx_fail
    mov [v_fat_numfats], eax
    mov eax, [r13 + BPB32_FATSZ32]
    test eax, eax
    jz .rdx_fail              ; FAT16 ESP not supported here (UEFI spec requires FAT32 on ESPs > 512 MB)
    mov [v_fat_size32], eax
    mov eax, [r13 + BPB32_ROOTCLUS]
    cmp eax, 2
    jb .rdx_fail
    mov [v_fat_rootclus], eax

    ; FirstDataSector = RsvdSecCnt + NumFATs * FATSz32
    mov eax, [v_fat_rsvd]
    mov edx, [v_fat_numfats]
    imul edx, [v_fat_size32]
    add eax, edx
    mov [v_fat_first_data_sec], eax

    SER 'B'                                  ; B = BPB parsed OK

    ; Publish stable metadata before the walk. Class stays 0 until a kernel
    ; backing driver exists, but the extent table can already be captured.
    mov ax, [v_part_blksz]
    mov [abs VBE_INFO + VBE_STORAGE_BLKSIZE_OFF], ax
    mov qword [abs VBE_INFO + VBE_STORAGE_EXT_PTR_OFF], STORAGE_EXTENTS_ADDR

    ; --- Resolve \EFI\BOOT\DATA.IMG by walking FAT32 directory clusters ---
    mov eax, [v_fat_rootclus]
    lea rsi, [s_efi_83]
    call fat32_find_dirent
    jc .rdx_fail
    test bl, ATTR_DIRECTORY
    jz .rdx_fail

    lea rsi, [s_boot_83]
    call fat32_find_dirent
    jc .rdx_fail
    test bl, ATTR_DIRECTORY
    jz .rdx_fail

    lea rsi, [s_data_83]
    call fat32_find_dirent
    jc .rdx_fail
    test bl, ATTR_DIRECTORY
    jnz .rdx_fail
    cmp eax, 2
    jb .rdx_fail
    test edx, edx
    jz .rdx_fail
    mov [v_data_first_clus], eax
    mov [v_data_file_size], edx

    SER 'D'                                  ; D = DATA.IMG directory entry found

    ; --- Walk the DATA.IMG FAT32 chain and coalesce contiguous clusters ---
    call fat32_emit_data_extents
    jc .rdx_fail
    mov [abs VBE_INFO + VBE_STORAGE_EXT_CNT_OFF], eax

    SER 'e'                                  ; e = extents emitted

.rdx_fail:
    add rsp, 48
    pop r13
    pop r12
    pop rbx
    ret

; read_part_sector
;   r8  = partition-relative LBA
;   r10 = 512-byte destination buffer
;   returns EFI_STATUS in rax
;   clobbers volatile registers
read_part_sector:
    sub rsp, 40
    mov r11, [v_blkio]
    mov rcx, r11
    mov edx, [v_part_mediaid]
    mov r9, 512
    mov [rsp+32], r10
    mov rax, [r11 + BIO_READ]
    call rax
    add rsp, 40
    ret

; fat32_cluster_lba
;   eax = cluster number
;   returns rax = partition-relative LBA of the cluster's first sector
;   clobbers rdx
fat32_cluster_lba:
    sub eax, 2
    mul dword [v_fat_secperclus]
    add eax, [v_fat_first_data_sec]
    ret

; fat32_get_next_cluster
;   eax = current cluster
;   returns CF clear + eax = next cluster (masked to 28 bits), or CF set
;   clobbers volatile registers
fat32_get_next_cluster:
    sub rsp, 40
    shl eax, 2
    mov edx, eax
    shr eax, 9
    add eax, [v_fat_rsvd]
    mov r8d, eax
    mov r10, [v_bpb_buf]
    mov [rsp+32], edx
    call read_part_sector
    test rax, rax
    jnz .gnc_fail
    mov edx, [rsp+32]
    and edx, 511
    mov r10, [v_bpb_buf]
    mov eax, [r10 + rdx]
    and eax, 0x0FFFFFFF
    clc
    add rsp, 40
    ret
.gnc_fail:
    stc
    add rsp, 40
    ret

; fat32_find_dirent
;   eax = starting directory cluster
;   rsi = pointer to 11-byte 8.3 uppercase name
;   returns CF clear + eax = first cluster, edx = file size, bl = attr
;   returns CF set if not found or on read/FAT error
fat32_find_dirent:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    cld
    mov r12d, eax
    mov r13, rsi
.fde_cluster:
    cmp r12d, 2
    jb .fde_fail
    xor r14d, r14d
.fde_sector:
    mov eax, r12d
    call fat32_cluster_lba
    add eax, r14d
    mov r8d, eax
    mov r10, [v_bpb_buf]
    call read_part_sector
    test rax, rax
    jnz .fde_fail

    mov r15, [v_bpb_buf]
    mov ecx, 16
.fde_entry:
    mov al, [r15]
    test al, al
    jz .fde_fail                 ; 0x00 marks end of this directory
    cmp al, 0xE5
    je .fde_next_entry
    mov bl, [r15 + DIRENT_ATTR]
    mov al, bl
    and al, ATTR_LONG_NAME
    cmp al, ATTR_LONG_NAME
    je .fde_next_entry

    push rcx
    mov rsi, r13
    mov rdi, r15
    mov ecx, 11
    repe cmpsb
    pop rcx
    jne .fde_next_entry

    movzx eax, word [r15 + DIRENT_CLUS_HI]
    shl eax, 16
    movzx edx, word [r15 + DIRENT_CLUS_LO]
    or eax, edx
    mov edx, [r15 + DIRENT_FILE_SIZE]
    clc
    jmp .fde_done
.fde_next_entry:
    add r15, 32
    dec ecx
    jnz .fde_entry

    inc r14d
    cmp r14d, [v_fat_secperclus]
    jb .fde_sector

    mov eax, r12d
    call fat32_get_next_cluster
    jc .fde_fail
    cmp eax, FAT32_EOC
    jae .fde_fail
    mov r12d, eax
    jmp .fde_cluster
.fde_fail:
    stc
.fde_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; fat32_emit_data_extents
;   eax = DATA.IMG first cluster
;   edx = DATA.IMG file size in bytes
;   returns CF clear + eax = extent count, or CF set
fat32_emit_data_extents:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r12d, eax
    mov eax, edx
    add eax, 511
    shr eax, 9
    mov r13d, eax                   ; remaining file sectors
    xor r15d, r15d                  ; extent count
    test r13d, r13d
    jz .ede_fail
.ede_cluster:
    mov eax, r12d
    call fat32_cluster_lba
    mov rbx, rax                    ; current extent start LBA
    mov ecx, [v_fat_secperclus]
    cmp ecx, r13d
    jbe .ede_chunk_ok
    mov ecx, r13d
.ede_chunk_ok:
    test r15d, r15d
    jz .ede_new_extent

    mov edi, r15d
    dec edi
    shl edi, 4
    lea r14, [abs STORAGE_EXTENTS_ADDR + rdi]
    mov rax, [r14]
    mov edx, [r14 + 8]
    add rax, rdx
    cmp rax, rbx
    jne .ede_new_extent
    add [r14 + 8], ecx
    jmp .ede_appended
.ede_new_extent:
    cmp r15d, STORAGE_EXTENTS_MAX
    jae .ede_fail
    mov edi, r15d
    shl edi, 4
    lea r14, [abs STORAGE_EXTENTS_ADDR + rdi]
    mov [r14], rbx
    mov [r14 + 8], ecx
    mov dword [r14 + 12], 0
    inc r15d
.ede_appended:
    sub r13d, ecx
    jz .ede_done

    mov eax, r12d
    call fat32_get_next_cluster
    jc .ede_fail
    cmp eax, FAT32_EOC
    jae .ede_fail
    cmp eax, 2
    jb .ede_fail
    mov r12d, eax
    jmp .ede_cluster
.ede_done:
    mov eax, r15d
    clc
    jmp .ede_ret
.ede_fail:
    stc
.ede_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
