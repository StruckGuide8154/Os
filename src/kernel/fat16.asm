; ============================================================================
; NexusOS v3.0 - FAT16 Filesystem Driver
; Reads/writes files from a FAT16 partition starting at a fixed sector offset
; ============================================================================
bits 64

%include "constants.inc"

section .text

global fat16_init
global fat16_list_dir
global fat16_read_file
global fat16_write_file
global fat16_get_file_size
global fat16_file_count
global fat16_get_entry

extern ata_read_sectors
extern ata_write_sectors
extern ata_drive_sel

; The FAT16 partition starts at this LBA sector on the disk image
FAT16_PART_LBA  equ 320           ; After MBR + Stage2 + Kernel (sector 320 = byte 163840)

; FAT16 BPB offsets (from start of boot sector)
BPB_BYTES_PER_SECT  equ 11        ; word
BPB_SECT_PER_CLUS   equ 13        ; byte
BPB_RESERVED_SECTS  equ 14        ; word
BPB_NUM_FATS        equ 16        ; byte
BPB_ROOT_ENTRIES    equ 17        ; word
BPB_TOTAL_SECTS16   equ 19        ; word
BPB_FAT_SIZE16      equ 22        ; word

; FAT16 directory entry offsets
DIR_NAME            equ 0          ; 8 bytes filename
DIR_EXT             equ 8          ; 3 bytes extension
DIR_ATTR            equ 11         ; 1 byte attributes
DIR_FIRST_CLUS_HI   equ 20        ; 2 bytes (FAT32 only, 0 for FAT16)
DIR_FIRST_CLUS_LO   equ 26        ; 2 bytes
DIR_FILE_SIZE       equ 28         ; 4 bytes
DIR_ENTRY_SIZE      equ 32

; Attributes
ATTR_READ_ONLY      equ 0x01
ATTR_HIDDEN         equ 0x02
ATTR_SYSTEM         equ 0x04
ATTR_VOLUME_ID      equ 0x08
ATTR_DIRECTORY      equ 0x10
ATTR_ARCHIVE        equ 0x20
ATTR_LFN            equ 0x0F

; Temp buffers - placed AFTER XHCI memory region (which ends at 0x9B0000)
; Must not overlap BACK_BUFFER_SAVE_ADDR at 0xA00000
FAT16_SECTOR_BUF    equ 0x9B0000   ; 512 byte sector buffer
FAT16_FAT_CACHE     equ 0x9B1000   ; FAT table cache (up to 64KB)
FAT16_ROOT_CACHE    equ 0x9C1000   ; Root directory cache (up to 32 sectors = 16KB)
FAT16_FILE_BUF      equ 0x9D1000   ; File read buffer (up to 64KB)
FAT16_DIR_CACHE     equ 0x9E1000   ; Current directory listing cache

; ============================================================================
; fat16_init - Initialize FAT16 driver, read BPB and cache FAT + root dir
; Returns: eax = 0 on success
; ============================================================================
fat16_init:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    ; Read boot sector of FAT16 partition
    ; First attempt with default drive (0xE0)
    mov rdi, FAT16_PART_LBA
    mov rsi, FAT16_SECTOR_BUF
    mov edx, 1
    call ata_read_sectors
    test eax, eax
    jnz .try_next_drive

    ; Check partition signature
    cmp word [FAT16_SECTOR_BUF + 510], 0xAA55
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

    ; Check signature again
    cmp word [FAT16_SECTOR_BUF + 510], 0xAA55
    jne .init_fail

.bpb_found:
    ; Parse BPB
    mov rbx, FAT16_SECTOR_BUF
    movzx eax, word [rbx + BPB_BYTES_PER_SECT]
    mov [fat16_bytes_per_sect], ax
    movzx eax, byte [rbx + BPB_SECT_PER_CLUS]
    mov [fat16_sect_per_clus], al
    movzx eax, word [rbx + BPB_RESERVED_SECTS]
    mov [fat16_reserved_sects], ax
    movzx eax, byte [rbx + BPB_NUM_FATS]
    mov [fat16_num_fats], al
    movzx eax, word [rbx + BPB_ROOT_ENTRIES]
    mov [fat16_root_entries], ax
    movzx eax, word [rbx + BPB_FAT_SIZE16]
    mov [fat16_fat_size], ax

    ; Calculate key offsets (all relative to partition start)
    ; FAT start = reserved sectors
    movzx eax, word [fat16_reserved_sects]
    mov [fat16_fat_start_sect], eax

    ; Root dir start = reserved + num_fats * fat_size
    movzx ecx, byte [fat16_num_fats]
    movzx edx, word [fat16_fat_size]
    imul ecx, edx
    add eax, ecx
    mov [fat16_root_start_sect], eax

    ; Root dir sectors = (root_entries * 32 + 511) / 512
    movzx ecx, word [fat16_root_entries]
    shl ecx, 5            ; * 32
    add ecx, 511
    shr ecx, 9            ; / 512
    mov [fat16_root_sectors], ecx

    ; Data region start = root_start + root_sectors
    add eax, ecx
    mov [fat16_data_start_sect], eax

    ; Cache the FAT table
    mov edi, [fat16_fat_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_FAT_CACHE
    movzx edx, word [fat16_fat_size]
    ; Limit to 128 sectors (64KB) for safety
    cmp edx, 128
    jle .fat_size_ok
    mov edx, 128
.fat_size_ok:
    call ata_read_sectors

    ; Cache the root directory
    mov edi, [fat16_root_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_ROOT_CACHE
    mov edx, [fat16_root_sectors]
    call ata_read_sectors

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
fat16_file_count:
    mov eax, [fat16_file_count_val]
    ret

; ============================================================================
; fat16_get_entry - Get nth valid directory entry from root dir
; edi = index (0-based)
; Returns: rax = pointer to 32-byte dir entry, or 0 if not found
; ============================================================================
fat16_get_entry:
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

; ============================================================================
; fat16_read_file - Read a file by directory entry pointer
; rdi = pointer to directory entry (from fat16_get_entry)
; rsi = destination buffer
; edx = max bytes to read
; Returns: eax = bytes read, or -1 on error
; ============================================================================
fat16_read_file:
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    push r15
    push rdi
    push rsi

    mov r12, rdi           ; dir entry ptr
    mov r13, rsi           ; dest buffer
    mov r14d, edx          ; max bytes
    mov r15d, [r12 + DIR_FILE_SIZE]  ; actual file size

    ; Use smaller of max_bytes and file_size
    cmp r14d, r15d
    jle .size_ok
    mov r14d, r15d
.size_ok:

    ; Get first cluster
    movzx ebx, word [r12 + DIR_FIRST_CLUS_LO]
    test ebx, ebx
    jz .rf_empty           ; empty file

    xor ecx, ecx           ; bytes read so far
    movzx r8d, byte [fat16_sect_per_clus]

.rf_cluster_loop:
    ; Check cluster validity
    cmp ebx, 2
    jl .rf_done
    cmp ebx, 0xFFF8
    jge .rf_done

    ; Calculate LBA for this cluster
    ; LBA = data_start + (cluster - 2) * sect_per_clus + PART_LBA
    mov eax, ebx
    sub eax, 2
    movzx edx, byte [fat16_sect_per_clus]
    imul eax, edx
    add eax, [fat16_data_start_sect]
    add eax, FAT16_PART_LBA

    ; Read all sectors in this cluster
    push rcx
    mov edi, eax
    lea rsi, [r13 + rcx]   ; dest = buffer + bytes_read
    movzx edx, byte [fat16_sect_per_clus]
    call ata_read_sectors
    pop rcx

    ; Update bytes read
    movzx eax, byte [fat16_sect_per_clus]
    shl eax, 9             ; * 512
    add ecx, eax

    ; Check if we've read enough
    cmp ecx, r14d
    jge .rf_done

    ; Follow FAT chain
    ; Next cluster = FAT[current_cluster] (16-bit entry)
    mov eax, ebx
    shl eax, 1             ; * 2 (FAT16 entries are 2 bytes)
    movzx ebx, word [FAT16_FAT_CACHE + rax]
    jmp .rf_cluster_loop

.rf_empty:
    xor ecx, ecx

.rf_done:
    ; Return min(bytes_read, requested)
    cmp ecx, r14d
    jle .rf_ret_ok
    mov ecx, r14d
.rf_ret_ok:
    mov eax, ecx

    pop rsi
    pop rdi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; fat16_write_file - Write/create a file in root directory
; rdi = pointer to 11-char filename (8.3 format, space-padded)
; rsi = source buffer
; edx = number of bytes to write
; Returns: eax = 0 on success, -1 on error
; ============================================================================
fat16_write_file:
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    push r15
    push rdi
    push rsi

    mov r12, rdi           ; filename
    mov r13, rsi           ; source buffer
    mov r14d, edx          ; byte count

    ; First, find existing entry or free slot in root dir
    mov rbx, FAT16_ROOT_CACHE
    xor ecx, ecx
    movzx r8d, word [fat16_root_entries]
    mov r15, 0             ; free slot pointer (0 = not found yet)

.wf_search:
    cmp ecx, r8d
    jge .wf_search_done
    cmp byte [rbx], 0
    je .wf_found_free
    cmp byte [rbx], 0xE5
    je .wf_found_free

    ; Compare filename (11 bytes)
    push rcx
    push rdi
    push rsi
    mov rdi, rbx
    mov rsi, r12
    mov ecx, 11
.wf_cmp:
    mov al, [rdi]
    cmp al, [rsi]
    jne .wf_cmp_diff
    inc rdi
    inc rsi
    dec ecx
    jnz .wf_cmp
    ; Match found - overwrite this entry
    pop rsi
    pop rdi
    pop rcx
    mov r15, rbx
    jmp .wf_have_slot

.wf_cmp_diff:
    pop rsi
    pop rdi
    pop rcx
    add rbx, DIR_ENTRY_SIZE
    inc ecx
    jmp .wf_search

.wf_found_free:
    cmp r15, 0
    jne .wf_skip_free
    mov r15, rbx           ; remember first free slot
.wf_skip_free:
    ; Check if this is end-of-dir marker
    cmp byte [rbx], 0
    je .wf_search_done
    add rbx, DIR_ENTRY_SIZE
    inc ecx
    jmp .wf_search

.wf_search_done:
    cmp r15, 0
    je .wf_error            ; no free slot

.wf_have_slot:
    ; r15 = dir entry to use
    ; If overwriting existing file, free old clusters first
    cmp byte [r15], 0
    je .wf_new_entry
    cmp byte [r15], 0xE5
    je .wf_new_entry

    ; Free existing cluster chain
    movzx ebx, word [r15 + DIR_FIRST_CLUS_LO]
.wf_free_chain:
    cmp ebx, 2
    jl .wf_new_entry
    cmp ebx, 0xFFF8
    jge .wf_new_entry
    mov eax, ebx
    shl eax, 1
    movzx ebx, word [FAT16_FAT_CACHE + rax]
    mov word [FAT16_FAT_CACHE + rax], 0  ; free cluster
    jmp .wf_free_chain

.wf_new_entry:
    ; Write filename to entry
    push rcx
    push rdi
    push rsi
    mov rdi, r15
    mov rsi, r12
    mov ecx, 11
    rep movsb
    pop rsi
    pop rdi
    pop rcx

    ; Set attributes
    mov byte [r15 + DIR_ATTR], ATTR_ARCHIVE
    ; Clear high cluster word
    mov word [r15 + DIR_FIRST_CLUS_HI], 0
    ; Set file size
    mov [r15 + DIR_FILE_SIZE], r14d

    ; Allocate clusters and write data
    test r14d, r14d
    jz .wf_empty_file

    ; Find first free cluster
    xor ebx, ebx           ; first cluster (will store here)
    mov ecx, 2             ; start searching from cluster 2
    movzx r8d, word [fat16_fat_size]
    shl r8d, 8             ; fat_size * 256 = max entries (512 bytes / 2 per entry * fat_size)

.wf_find_first_free:
    cmp ecx, r8d
    jge .wf_error_full
    mov eax, ecx
    shl eax, 1
    cmp word [FAT16_FAT_CACHE + rax], 0
    je .wf_got_first
    inc ecx
    jmp .wf_find_first_free

.wf_got_first:
    mov ebx, ecx           ; first cluster
    mov [r15 + DIR_FIRST_CLUS_LO], cx

    ; Write data cluster by cluster
    mov r8d, r14d           ; remaining bytes
    mov r9, r13             ; current src pointer
    mov r10d, ebx           ; current cluster

.wf_write_cluster:
    ; Write this cluster's data
    mov eax, r10d
    sub eax, 2
    movzx edx, byte [fat16_sect_per_clus]
    imul eax, edx
    add eax, [fat16_data_start_sect]
    add eax, FAT16_PART_LBA

    push rcx
    mov edi, eax
    mov rsi, r9
    movzx edx, byte [fat16_sect_per_clus]
    call ata_write_sectors
    pop rcx

    ; Advance source pointer
    movzx eax, byte [fat16_sect_per_clus]
    shl eax, 9
    add r9, rax
    sub r8d, eax
    jle .wf_last_cluster     ; no more data

    ; Allocate next cluster
    mov ecx, r10d
    inc ecx                  ; start search after current
.wf_find_next:
    cmp ecx, 0xFFF0
    jge .wf_error_full
    mov eax, ecx
    shl eax, 1
    cmp word [FAT16_FAT_CACHE + rax], 0
    je .wf_got_next
    inc ecx
    jmp .wf_find_next

.wf_got_next:
    ; Link current cluster to next
    mov eax, r10d
    shl eax, 1
    mov [FAT16_FAT_CACHE + rax], cx
    mov r10d, ecx
    jmp .wf_write_cluster

.wf_last_cluster:
    ; Mark end of chain
    mov eax, r10d
    shl eax, 1
    mov word [FAT16_FAT_CACHE + rax], 0xFFFF

.wf_empty_file:
    ; Write updated FAT back to disk
    mov edi, [fat16_fat_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_FAT_CACHE
    movzx edx, word [fat16_fat_size]
    cmp edx, 128
    jle .wf_fat_ok
    mov edx, 128
.wf_fat_ok:
    call ata_write_sectors

    ; Write second FAT copy if exists
    cmp byte [fat16_num_fats], 2
    jl .wf_skip_fat2
    mov edi, [fat16_fat_start_sect]
    movzx eax, word [fat16_fat_size]
    add edi, eax
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_FAT_CACHE
    movzx edx, word [fat16_fat_size]
    cmp edx, 128
    jle .wf_fat2_ok
    mov edx, 128
.wf_fat2_ok:
    call ata_write_sectors
.wf_skip_fat2:

    ; Write updated root directory back to disk
    mov edi, [fat16_root_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_ROOT_CACHE
    mov edx, [fat16_root_sectors]
    call ata_write_sectors

    ; Recount files
    call fat16_count_root_files

    xor eax, eax
    jmp .wf_ret

.wf_error_full:
.wf_error:
    mov eax, -1

.wf_ret:
    pop rsi
    pop rdi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret



; ============================================================================
; fat16_change_dir - Change current directory (load into ROOT_CACHE)
; ax = cluster number (0 = root)
; Returns: eax = 0 on success
; ============================================================================
global fat16_change_dir
fat16_change_dir:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10

    movzx ebx, ax          ; cluster
    
    ; Cluster 0 -> Load Root Directory
    test ebx, ebx
    jnz .cd_subdir
    
    ; Load Root (contiguous)
    mov edi, [fat16_root_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_ROOT_CACHE
    mov edx, [fat16_root_sectors]
    call ata_read_sectors
    
    ; Reset file count
    call fat16_count_root_files
    xor eax, eax
    jmp .cd_done

.cd_subdir:
    ; Subdirectory: Read cluster chain into FAT16_ROOT_CACHE
    ; Max entries restricted by ROOT_CACHE size (16KB = 512 entries)
    ; Clear cache first
    mov rdi, FAT16_ROOT_CACHE
    mov ecx, 16384 / 4
    xor eax, eax
    rep stosd
    
    mov rsi, FAT16_ROOT_CACHE ; Dest
    xor r10d, r10d            ; Total bytes read
    
.cd_loop:
    cmp ebx, 2
    jl .cd_finish
    cmp ebx, 0xFFF8
    jge .cd_finish
    
    ; Read cluster
    mov eax, ebx
    sub eax, 2
    movzx edx, byte [fat16_sect_per_clus]
    imul eax, edx
    add eax, [fat16_data_start_sect]
    add eax, FAT16_PART_LBA
    
    mov edi, eax
    movzx edx, byte [fat16_sect_per_clus]
    
    ; Safety check for cache overflow
    mov eax, edx
    shl eax, 9 ; bytes to read
    lea r9d, [r10d + eax]
    cmp r9d, 16384
    jg .cd_finish ; Truncate if too big
    
    call ata_read_sectors
    
    ; Advance ptr
    movzx eax, byte [fat16_sect_per_clus]
    shl eax, 9
    add rsi, rax
    add r10d, eax
    
    ; Next cluster
    mov eax, ebx
    shl eax, 1
    movzx ebx, word [FAT16_FAT_CACHE + rax]
    jmp .cd_loop

.cd_finish:
    ; Recount files in new view
    call fat16_count_root_files
    xor eax, eax

.cd_done:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; fat16_get_file_size - Get file size from directory entry
; rdi = pointer to directory entry
; Returns: eax = file size in bytes
; ============================================================================
fat16_get_file_size:
    mov eax, [rdi + DIR_FILE_SIZE]
    ret

; ============================================================================
; fat16_sync_root - Write root directory cache to disk
; ============================================================================
global fat16_sync_root
fat16_sync_root:
    push rdi
    push rsi
    push rdx
    
    mov edi, [fat16_root_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_ROOT_CACHE
    mov edx, [fat16_root_sectors]
    call ata_write_sectors
    
    pop rdx
    pop rsi
    pop rdi
    ret

; ============================================================================
; Data
; ============================================================================
section .data

fat16_bytes_per_sect  dw 512
fat16_sect_per_clus   db 4
fat16_reserved_sects  dw 1
fat16_num_fats        db 2
fat16_root_entries    dw 512
fat16_fat_size        dw 0
fat16_fat_start_sect  dd 0
fat16_root_start_sect dd 0
fat16_root_sectors    dd 0
fat16_data_start_sect dd 0
fat16_file_count_val  dd 0


; ============================================================================
; fat16_debug_dump_root - Dump details about FAT16 init to buffer
; ============================================================================
global fat16_debug_dump_root
fat16_debug_dump_root:
    push rdi
    push rsi
    push rax
    push rbx
    push rcx
    push rdx

    mov rbx, rdi              ; RBX = write pointer

    ; Header
    lea rsi, [.hdr]
    call .copystr

    ; Drive Selection
    lea rsi, [.s_drive]
    call .copystr
    movzx eax, byte [ata_drive_sel]
    call .writehex8

    ; Partition LBA
    lea rsi, [.s_lba]
    call .copystr
    mov eax, FAT16_PART_LBA
    call .writehex32

    ; Signature check (from buffer)
    lea rsi, [.s_sig]
    call .copystr
    movzx eax, word [FAT16_SECTOR_BUF + 510]
    call .writehex16

    ; File Count
    lea rsi, [.s_files]
    call .copystr
    mov eax, [fat16_file_count_val]
    call .writehex32

    ; Root Start Sector
    lea rsi, [.s_root]
    call .copystr
    mov eax, [fat16_root_start_sect]
    call .writehex32
    
    ; Null terminate
    mov byte [rbx], 0

    pop rdx
    pop rcx
    pop rbx
    pop rax
    pop rsi
    pop rdi
    ret

; -- internal helpers --
.copystr:
    lodsb
    test al, al
    jz .cs_done
    mov [rbx], al
    inc rbx
    jmp .copystr
.cs_done:
    ret

.writehex8:
    push rax
    shr al, 4
    call .nib
    pop rax
    push rax
    and al, 0x0F
    call .nib
    pop rax
    ret

.writehex16:
    push rax
    shr ax, 8
    call .writehex8
    pop rax
    push rax
    call .writehex8
    pop rax
    ret

.writehex32:
    push rax
    shr eax, 16
    call .writehex16
    pop rax
    push rax
    call .writehex16
    pop rax
    ret
    
.nib:
    cmp al, 10
    jb .nib_digit
    add al, 'A' - 10
    jmp .nib_out
.nib_digit:
    add al, '0'
.nib_out:
    mov [rbx], al
    inc rbx
    ret

.hdr      db "FAT16 DBG: ", 0
.s_drive  db " Drv:", 0
.s_lba    db " LBA:", 0
.s_sig    db " Sig:", 0
.s_files  db " Files:", 0
.s_root   db " Root:", 0
