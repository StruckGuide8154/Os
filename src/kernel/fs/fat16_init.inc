; ============================================================================
; fat16_init - Initialize FAT16 driver, read BPB and cache FAT + root dir
; Returns: eax = 0 on success
; ============================================================================
FN_BEGIN fat16_init, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    ; Read boot sector of FAT16 partition.
    mov byte [ata_drive_sel], 0xE0
    mov rdi, FAT16_PART_LBA
    mov rsi, FAT16_SECTOR_BUF
    mov edx, 1
    call ata_read_sectors
    test eax, eax
    jnz .try_next_drive

    ; Check partition signature and Grit FAT image marker. In UEFI QEMU the
    ; ESP is also exposed as an ATA disk; it can contain a valid-looking boot
    ; sector at this LBA, so a signature-only probe can bind the file manager
    ; to the wrong disk.
    cmp word [abs FAT16_SECTOR_BUF + 510], 0xAA55
    jne .try_next_drive
    cmp dword [abs FAT16_SECTOR_BUF + 3], 0x5558454E     ; "NEXU"
    jne .try_next_drive
    cmp dword [abs FAT16_SECTOR_BUF + 7], 0x20534F53     ; "SOS "
    je .bpb_found

.try_next_drive:
    ; Toggle drive (0xE0 -> 0xF0 or vice versa)
    mov al, [ata_drive_sel]
    xor al, 0x10
    mov [ata_drive_sel], al

    ; Try reading again
    mov rdi, FAT16_PART_LBA
    mov rsi, FAT16_SECTOR_BUF
    mov edx, 1
    call ata_read_sectors
    test eax, eax
    jnz .init_fail

    ; Check signature and marker again
    cmp word [abs FAT16_SECTOR_BUF + 510], 0xAA55
    jne .init_fail
    cmp dword [abs FAT16_SECTOR_BUF + 3], 0x5558454E
    jne .init_fail
    cmp dword [abs FAT16_SECTOR_BUF + 7], 0x20534F53
    jne .init_fail

.bpb_found:
    ; Parse BPB
    mov rbx, FAT16_SECTOR_BUF
    movzx eax, word [rbx + BPB_BYTES_PER_SECT]
    cmp eax, 512
    jne .init_fail
    mov [fat16_bytes_per_sect], ax
    movzx eax, byte [rbx + BPB_SECT_PER_CLUS]
    test eax, eax
    jz .init_fail
    cmp eax, 128
    ja .init_fail
    mov [fat16_sect_per_clus], al
    movzx eax, word [rbx + BPB_RESERVED_SECTS]
    test eax, eax
    jz .init_fail
    mov [fat16_reserved_sects], ax
    movzx eax, byte [rbx + BPB_NUM_FATS]
    cmp eax, 1
    jb .init_fail
    cmp eax, 2
    ja .init_fail
    mov [fat16_num_fats], al
    movzx eax, word [rbx + BPB_ROOT_ENTRIES]
    test eax, eax
    jz .init_fail
    cmp eax, FAT16_ROOT_CACHE_SECTORS * 16
    ja .init_fail
    mov [fat16_root_entries], ax
    movzx eax, word [rbx + BPB_FAT_SIZE16]
    test eax, eax
    jz .init_fail
    cmp eax, FAT16_FAT_CACHE_SECTORS
    ja .init_fail
    mov [fat16_fat_size], ax
    movzx eax, word [rbx + BPB_TOTAL_SECTS16]
    test eax, eax
    jz .init_fail
    mov [fat16_total_sects], eax

    ; Calculate key offsets (all relative to partition start)
    ; FAT start = reserved sectors
    movzx eax, word [fat16_reserved_sects]
    mov [fat16_fat_start_sect], eax

    ; Root dir start = reserved + num_fats * fat_size
    movzx ecx, byte [fat16_num_fats]
    movzx edx, word [fat16_fat_size]
    imul ecx, edx
    jo .init_fail
    add eax, ecx
    jc .init_fail
    cmp eax, [fat16_total_sects]
    jae .init_fail
    mov [fat16_root_start_sect], eax

    ; Root dir sectors = (root_entries * 32 + 511) / 512
    movzx ecx, word [fat16_root_entries]
    shl ecx, 5            ; * 32
    add ecx, 511
    shr ecx, 9            ; / 512
    mov [fat16_root_sectors], ecx

    ; Data region start = root_start + root_sectors
    add eax, ecx
    jc .init_fail
    cmp eax, [fat16_total_sects]
    jae .init_fail
    mov [fat16_data_start_sect], eax
    mov edx, [fat16_total_sects]
    sub edx, eax
    movzx ecx, byte [fat16_sect_per_clus]
    mov eax, edx
    xor edx, edx
    div ecx
    add eax, 2
    cmp eax, FAT16_MAX_FAT_ENTRIES
    jbe .fat_entries_ok
    mov eax, FAT16_MAX_FAT_ENTRIES
.fat_entries_ok:
    mov [fat16_fat_entries], eax

    ; Cache the FAT table
    mov edi, [fat16_fat_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_FAT_CACHE
    movzx edx, word [fat16_fat_size]
    call ata_read_sectors

    ; Cache the root directory
    mov edi, [fat16_root_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_ROOT_CACHE
    mov edx, [fat16_root_sectors]
    cmp edx, FAT16_ROOT_CACHE_SECTORS
    ja .init_fail
    call ata_read_sectors

    ; Seed the root-cache guard now that kernel_canary is final, then verify the
    ; initial load did not run past the 16KB extent.
    call fat16_canary_seed
    call fat16_canary_check

    ; Count files in root dir
    call fat16_count_root_files

    xor eax, eax
    jmp .init_ret

.init_fail:
    mov eax, -1

.init_ret:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; Internal: seed the trailing guard qword that brackets the 16KB root/subdir
; directory cache. ring-3 influences how much gets written into this fixed
; buffer (on-disk root_sectors/root_entries from a user-supplied image, and
; subdir cluster chains selected via fat16_change_dir), so a stray write past
; the extent must be caught. Seeded once from kernel_canary after init.
fat16_canary_seed:
    push rax
    mov rax, [rel kernel_canary]
    mov [abs FAT16_ROOT_CACHE_CANARY], rax
    pop rax
    ret

; Internal: verify the root-cache trailing guard; panic on mismatch. Called
; after every cache fill ring-3 can shape. Saves the regs the panic ABI uses
; so callers are unaffected on the good path.
fat16_canary_check:
    push rax
    mov rax, [abs FAT16_ROOT_CACHE_CANARY]
    cmp rax, [rel kernel_canary]
    jne .fc_bad
    pop rax
    ret
.fc_bad:
    mov rdi, rax
    lea rsi, [rel fat16_canary_check]
    mov edx, 0x46415443                  ; FATC: FAT directory cache guard
    jmp kernel_panic_canary

; Internal: count valid files in root directory
fat16_count_root_files:
    push rcx
    push rbx
    mov rbx, FAT16_ROOT_CACHE
    xor ecx, ecx           ; count
    xor edx, edx           ; index
    movzx r8d, word [fat16_root_entries]
.count_loop:
    cmp edx, r8d
    jge .count_done
    cmp byte [rbx], 0      ; end of entries
    je .count_done
    cmp byte [rbx], 0xE5   ; deleted entry
    je .count_skip
    mov al, [rbx + DIR_ATTR]
    cmp al, ATTR_LFN          ; LFN entries have attr = 0x0F exactly
    je .count_skip
    test al, ATTR_VOLUME_ID
    jnz .count_skip
    inc ecx
.count_skip:
    add rbx, DIR_ENTRY_SIZE
    inc edx
    jmp .count_loop
.count_done:
    mov [fat16_file_count_val], ecx
    pop rbx
    pop rcx
    ret

; ============================================================================
; fat16_file_count - Return number of files in root directory
; Returns: eax = file count
; ============================================================================
FN_BEGIN fat16_file_count, 0, 0, FN_RET_SCALAR
    call fat16_count_root_files
    mov eax, [fat16_file_count_val]
    ret

; ============================================================================
; fat16_get_entry - Get nth valid directory entry from root dir
; edi = index (0-based)
; Returns: rax = pointer to 32-byte dir entry, or 0 if not found
; ============================================================================
FN_BEGIN fat16_get_entry, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx

    mov rbx, FAT16_ROOT_CACHE
    xor ecx, ecx           ; valid entry counter
    xor edx, edx           ; raw entry counter
    movzx r8d, word [fat16_root_entries]

.ge_loop:
    cmp edx, r8d
    jge .ge_not_found
    cmp byte [rbx], 0
    je .ge_not_found
    cmp byte [rbx], 0xE5
    je .ge_skip
    mov al, [rbx + DIR_ATTR]
    test al, ATTR_VOLUME_ID
    jnz .ge_skip
    cmp al, ATTR_LFN
    je .ge_skip
    ; Valid entry
    cmp ecx, edi
    je .ge_found
    inc ecx
.ge_skip:
    add rbx, DIR_ENTRY_SIZE
    inc edx
    jmp .ge_loop

.ge_found:
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret

.ge_not_found:
    xor eax, eax
    pop rdx
    pop rcx
    pop rbx
    ret
