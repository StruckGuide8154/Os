; fat16_change_dir - Change current directory (load into ROOT_CACHE)
; ax = cluster number (0 = root)
; Returns: eax = 0 on success
; ============================================================================
; auto-wrapped (FN_BEGIN emits global): global fat16_change_dir
FN_BEGIN fat16_change_dir, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11

    movzx ebx, ax          ; cluster
    mov [fat16_cur_dir_cluster], bx
    
    ; Cluster 0 -> Load Root Directory
    test ebx, ebx
    jnz .cd_subdir
    
    ; Load Root (contiguous)
    mov edi, [fat16_root_start_sect]
    add edi, FAT16_PART_LBA
    mov rsi, FAT16_ROOT_CACHE
    mov edx, [fat16_root_sectors]
    cmp edx, FAT16_ROOT_CACHE_SECTORS
    ja .cd_fail
    call ata_read_sectors

    ; Verify the contiguous root reload stayed within the cache extent.
    call fat16_canary_check
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
    mov r11d, [fat16_fat_entries]
    
.cd_loop:
    test r11d, r11d
    jz .cd_finish
    dec r11d
    cmp ebx, 2
    jl .cd_finish
    cmp ebx, 0xFFF8
    jge .cd_finish
    cmp ebx, [fat16_fat_entries]
    jae .cd_finish
    
    ; Read cluster
    mov eax, ebx
    sub eax, 2
    movzx edx, byte [fat16_sect_per_clus]
    imul eax, edx
    jo .cd_finish
    add eax, [fat16_data_start_sect]
    jc .cd_finish
    mov edx, eax
    movzx r9d, byte [fat16_sect_per_clus]
    add edx, r9d
    jc .cd_finish
    cmp edx, [fat16_total_sects]
    ja .cd_finish
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
    ; Verify the subdir cluster-chain load stayed within the cache extent.
    call fat16_canary_check
    ; Recount files in new view
    call fat16_count_root_files
    xor eax, eax

.cd_done:
    ; The live cache no longer matches any slot's recorded view: this raw load
    ; may have come from the launcher/shell (kernel context, no valid slot) or
    ; from fat16_switch_to/.sc_fs_chdir which re-stamp ownership themselves.
    ; Invalidate here so a non-syscall reload always forces the next ring-3 FS
    ; syscall to re-materialize its own cwd.
    mov dword [rel fat16_cache_owner], FAT16_CACHE_OWNER_NONE
    pop r11
    pop r10

    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

.cd_fail:
    mov eax, -1
    jmp .cd_done

; ----------------------------------------------------------------------------
; fat16_switch_to - ensure FAT16_ROOT_CACHE holds the calling slot's (r15) cwd.
; No-op when the slot already owns the live cache. Otherwise reloads the slot's
; recorded cwd cluster via fat16_change_dir and claims ownership. Preserves ALL
; caller registers (called as the first instruction of every FS syscall
; handler, where r15 = the calling slot).
;
; Internal plain label (no FN_BEGIN / not global) - like the FS internal
; helpers, so check_coverage.py requires no FN gate.
; ----------------------------------------------------------------------------
global fat16_switch_to
fat16_switch_to:
    push rax
    push rcx
    movzx ecx, r15b
    cmp ecx, APP_SLOT_COUNT
    jae .fsw_slot0                      ; out-of-range -> treat as slot 0
    jmp .fsw_have_slot
.fsw_slot0:
    xor ecx, ecx
.fsw_have_slot:
    cmp [rel fat16_cache_owner], ecx
    je .fsw_ret                         ; this slot already owns the live cache
    ; Reload the slot's recorded cwd cluster into the live cache.
    movzx eax, word [rel fat16_slot_cwd + rcx*2]
    push rcx
    call fat16_change_dir               ; ax = cluster; sets owner = NONE
    pop rcx
    mov [rel fat16_cache_owner], ecx    ; claim ownership for this slot
.fsw_ret:
    pop rcx
    pop rax
    ret

; ============================================================================
; fat16_get_file_size - Get file size from directory entry
; rdi = pointer to directory entry
; Returns: eax = file size in bytes
; ============================================================================
FN_BEGIN fat16_get_file_size, 0, 0, FN_RET_SCALAR
    mov eax, [rdi + DIR_FILE_SIZE]
    ret

; ============================================================================
; fat16_sync_root - Write root directory cache to disk
; ============================================================================
; auto-wrapped (FN_BEGIN emits global): global fat16_sync_root
FN_BEGIN fat16_sync_root, 0, 0, FN_RET_SCALAR
    call fat16_flush_current_dir
    ret

; ============================================================================
; Snapshot-on-open (security_todo.md §5) - TOCTOU elimination for the
; SYS_FS_ENTRY_INFO -> SYS_FS_READ sequence.
;
; SYS_FS_ENTRY_INFO resolves a per-slot dir-entry handle (carrying a
; valid-entry INDEX) to the live FAT16 root/subdir-cache entry pointer and
; copies {name, ext, attr, cluster, size} out by value. A later SYS_FS_READ
; re-resolves the SAME index to whatever entry occupies that slot NOW. If a
; rename / resize / delete (or a directory change) altered the entry between
; the info call and the read, the index silently resolves to a DIFFERENT file
; - a time-of-check/time-of-use window: the app validated file A, the kernel
; reads file B.
;
; Defence: at SYS_FS_ENTRY_INFO, atomically capture the identifying fields
; (name+ext, first cluster, size) of the resolved entry into a per-slot,
; kernel-owned snapshot. At SYS_FS_READ, re-verify the live entry against that
; snapshot; if it diverges, FAIL CLOSED (the read is rejected) - so a raced
; rename/resize can never feed the app bytes from an entry it never inspected.
;
; Storage model mirrors the §7 per-slot net policy and slot_handle_quota[]:
; parallel per-slot arrays in KERNEL BSS, OUTSIDE the ring-3 app arena, so an
; app cannot forge or widen its own snapshot. Indexed by slot id
; (0..APP_SLOT_COUNT-1). A per-slot "armed" byte (BSS-zero = not armed) gates
; enforcement: a slot that never called SYS_FS_ENTRY_INFO reads exactly as
; before (non-breaking). The 17-byte identity = name[11] | cluster[2] |
; size[4].
;
; DISPATCHER WIRING (LANDED - now live):
;   * .sc_fs_entry_info (syscall_handlers_sys_fs.inc) arms the snapshot AFTER
;     sc_resolve_dir_entry_arg succeeds: push rsi / mov esi,r15d /
;     call fat16_entry_info_snapshot / pop rsi (RDI = entry, preserved).
;   * .sc_fs_read (syscall_handlers_gui_wm.inc) verifies AFTER the resolve +
;     range check and BEFORE fat16_read_file: mov esi,r15d /
;     call fat16_entry_snapshot_verify / test eax,eax / jz .sc_fs_read_reject.
;   * l3_copy_app_blob_to_slot (usermode_slot_install.inc) calls
;     fat16_entry_snapshot_clear on slot recycle so a new tenant is never
;     checked against the prior tenant's identity.
;   Register conventions below (RDI = entry ptr, ESI = slot) were chosen to drop
;   straight into those sites without disturbing the saved-arg frame. A slot that
;   never calls SYS_FS_ENTRY_INFO is never armed, so reads behave as before.
; ============================================================================

; fat16_entry_info_snapshot - capture the identity of a resolved dir entry.
;   RDI = kernel FAT16 dir-entry pointer (32-byte entry)
;   ESI = slot id
; Stores name[0..10] | first_cluster_lo (u16 @26) | size (u32 @28) into the
; slot's snapshot and arms it. Out-of-range slot is ignored (no arm). Preserves
; RDI/RSI. Clobbers RAX, RCX.
; auto-wrapped (FN_BEGIN emits global): global fat16_entry_info_snapshot
FN_BEGIN fat16_entry_info_snapshot, 0, 0, FN_RET_SCALAR
    push rdi
    push rsi
    push rcx
    push rdx
    cmp esi, APP_SLOT_COUNT
    jae .fs_snap_done
    ; dest = fat16_entry_snap + slot * FAT16_SNAP_STRIDE
    mov eax, esi
    imul eax, FAT16_SNAP_STRIDE
    lea rdx, [rel fat16_entry_snap]
    add rdx, rax                          ; rdx = snapshot slot base
    ; name+ext (11 bytes)
    xor ecx, ecx
.fs_snap_name:
    cmp ecx, 11
    jae .fs_snap_name_done
    mov al, [rdi + rcx]
    mov [rdx + rcx], al
    inc ecx
    jmp .fs_snap_name
.fs_snap_name_done:
    ; cluster_lo (u16 @26) -> snapshot +11
    mov ax, [rdi + DIR_FIRST_CLUS_LO]
    mov [rdx + 11], ax
    ; size (u32 @28) -> snapshot +13
    mov eax, [rdi + DIR_FILE_SIZE]
    mov [rdx + 13], eax
    ; arm this slot's snapshot
    mov eax, esi
    mov byte [rel fat16_entry_snap_armed + rax], 1
.fs_snap_done:
    pop rdx
    pop rcx
    pop rsi
    pop rdi
    ret

; fat16_entry_snapshot_verify - verify a resolved dir entry against the slot's
; armed snapshot before a read.
;   RDI = kernel FAT16 dir-entry pointer (32-byte entry)
;   ESI = slot id
; Returns:
;   EAX = 1 if the slot has NO armed snapshot (legacy/no-op), or the live entry
;         still matches the captured identity (name | cluster | size).
;   EAX = 0 if an armed snapshot exists and the live entry DIVERGED - FAIL
;         CLOSED, the caller must reject the read.
; Preserves RDI/RSI. Clobbers RAX, RCX, RDX.
; auto-wrapped (FN_BEGIN emits global): global fat16_entry_snapshot_verify
FN_BEGIN fat16_entry_snapshot_verify, 0, 0, FN_RET_SCALAR
    push rdi
    push rsi
    push rcx
    push rdx
    cmp esi, APP_SLOT_COUNT
    jae .fs_ver_allow                     ; bad slot -> treat as no policy
    mov eax, esi
    cmp byte [rel fat16_entry_snap_armed + rax], 0
    je .fs_ver_allow                      ; not armed -> legacy allow
    mov eax, esi
    imul eax, FAT16_SNAP_STRIDE
    lea rdx, [rel fat16_entry_snap]
    add rdx, rax                          ; rdx = snapshot slot base
    ; Compare name+ext (11 bytes)
    xor ecx, ecx
.fs_ver_name:
    cmp ecx, 11
    jae .fs_ver_name_done
    mov al, [rdi + rcx]
    cmp al, [rdx + rcx]
    jne .fs_ver_deny
    inc ecx
    jmp .fs_ver_name
.fs_ver_name_done:
    ; cluster_lo (u16)
    mov ax, [rdi + DIR_FIRST_CLUS_LO]
    cmp ax, [rdx + 11]
    jne .fs_ver_deny
    ; size (u32)
    mov eax, [rdi + DIR_FILE_SIZE]
    cmp eax, [rdx + 13]
    jne .fs_ver_deny
.fs_ver_allow:
    mov eax, 1
    jmp .fs_ver_ret
.fs_ver_deny:
    xor eax, eax
.fs_ver_ret:
    pop rdx
    pop rcx
    pop rsi
    pop rdi
    ret

; fat16_entry_snapshot_clear - disarm a slot's snapshot (e.g. on slot recycle
; or an explicit close). Out-of-range slot ignored. ESI = slot id. Clobbers
; RAX. Preserves RSI. (Provided for the recycle path to call; not yet wired -
; the snapshot is also implicitly superseded the next time ENTRY_INFO arms it.)
; auto-wrapped (FN_BEGIN emits global): global fat16_entry_snapshot_clear
FN_BEGIN fat16_entry_snapshot_clear, 0, 0, FN_RET_SCALAR
    cmp esi, APP_SLOT_COUNT
    jae .fs_clr_done
    mov eax, esi
    mov byte [rel fat16_entry_snap_armed + rax], 0
.fs_clr_done:
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
fat16_total_sects     dd 0
fat16_fat_entries     dd 0
fat16_file_count_val  dd 0
fat16_cur_dir_cluster dw 0


; ============================================================================
; fat16_debug_dump_root - Dump details about FAT16 init to buffer
; ============================================================================
; auto-wrapped (FN_BEGIN emits global): global fat16_debug_dump_root
FN_BEGIN fat16_debug_dump_root, 0, 0, FN_RET_SCALAR
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
    movzx eax, word [abs FAT16_SECTOR_BUF + 510]
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

; ============================================================================
; Snapshot-on-open per-slot storage (security_todo.md §5). KERNEL BSS, OUTSIDE
; the ring-3 app arena, so an app cannot forge or widen its own snapshot.
; BSS-zero => no slot armed (the non-breaking default). Indexed by slot id.
; ============================================================================
section .bss
alignb 16
fat16_entry_snap_armed: resb APP_SLOT_COUNT
alignb 16
fat16_entry_snap:       resb (FAT16_SNAP_STRIDE * APP_SLOT_COUNT)

; --- Per-slot current directory (security: cwd + dir-cache view is per slot) -
; The directory cache (FAT16_ROOT_CACHE) holds the entries a DIR_ENTRY handle's
; index payload refers to. With a single global cwd, one app's chdir reloads
; that cache out from under another app, so an index issued to app A would
; silently mean a different file once app B navigated away. Each slot now owns
; a cwd cluster; fat16_switch_to reloads the live cache to the calling slot's
; cwd whenever ownership differs, making dir-entry handle identities stable
; per slot. BSS-zero default = cluster 0 = root, matching the boot cache load.
fat16_slot_cwd:   resw APP_SLOT_COUNT          ; per-slot current-dir cluster
alignb 4
; Slot whose directory is currently materialized in FAT16_ROOT_CACHE.
; BSS-zero = slot 0 (which owns the root cache loaded by fat16_init).
; fat16_change_dir stamps FAT16_CACHE_OWNER_NONE here so any raw (launcher /
; shell, non-syscall) reload forces the next syscall to re-materialize.
fat16_cache_owner: resd 1
