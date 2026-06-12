kernel_open_file_in_notepad:
    SER 'O'
    SER 'F'
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                      ; dir entry ptr
    ; Notepad is a text editor. Keep known binary media formats out of its
    ; parser even if a caller bypasses Explorer's type-aware Open With list.
    cmp byte [r12 + 8], 'B'
    jne .kop_not_bmp
    cmp byte [r12 + 9], 'M'
    jne .kop_not_bmp
    cmp byte [r12 + 10], 'P'
    je .kop_fail
.kop_not_bmp:
    cmp byte [r12 + 8], 'N'
    jne .kop_not_media
    cmp byte [r12 + 9], 'I'
    jne .kop_check_nba
    cmp byte [r12 + 10], 'C'
    je .kop_fail
    jmp .kop_not_media
.kop_check_nba:
    cmp byte [r12 + 9], 'B'
    jne .kop_not_media
    cmp byte [r12 + 10], 'A'
    je .kop_fail
.kop_not_media:

    ; Launch a fresh Notepad. app_seed_notepad_slot resets the slot to a
    ; pristine "Hello" baseline; we then overwrite slot state with file data.
    mov rdi, APP_NOTEPAD
    sub rsp, 8
    call app_launch
    add rsp, 8
    cmp rax, -1
    je .kop_fail
    mov r13, rax                      ; new window id (== slot index)

    ; Cascade window position so file viewers don't cover Explorer.
    mov rax, r13
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_X], 560
    mov rbx, r13
    imul rbx, 24
    add rbx, 80
    mov [rax + WIN_OFF_Y], rbx
    lea rdi, [rax + 48]
    mov rsi, r12
    call fat16_format_name_to

    ; Resolve the slot base. All subsequent writes are slot-relative.
    mov edi, r13d
    call l3_slot_base
    mov r14, rax                      ; r14 = slot base

    ; SMAP: r14 is a user (PTE.U=1) slot page. Bracket the slot writes; the
    ; fat16 read below targets the kernel scratch buffer so it stays outside.
    USER_ACCESS_BEGIN
    ; Save dir entry into slot so Save can find the file later.
    mov [r14 + np_open_entry - app_blob_start], r12

    ; Pre-zero slot's notepad_buf + np_line_len so untouched cells stay clean.
    push rdi
    push rax
    push rcx
    lea rdi, [r14 + notepad_buf - app_blob_start]
    xor eax, eax
    mov ecx, NP_BUF_SIZE
    rep stosb
    lea rdi, [r14 + np_line_len - app_blob_start]
    xor eax, eax
    mov ecx, NP_MAX_LINES
    rep stosd
    pop rcx
    pop rax
    pop rdi
    USER_ACCESS_END

    ; Read raw file bytes into kernel-side notepad_buf (scratch only).
    mov rdi, r12
    lea rsi, [notepad_buf]
    mov edx, NP_BUF_SIZE - 1
    call fat16_read_file
    ; SMAP: the parse path below writes the slot (user page) on every branch,
    ; including .kop_empty. Arm AC now, after the kernel-scratch read returns,
    ; so all paths into the slot-write region run with AC set. Kernel-scratch
    ; reads ([rbx+rsi], [notepad_buf]) inside the region are fine with AC set.
    USER_ACCESS_BEGIN
    cmp eax, -1
    je .kop_empty
    test eax, eax
    jz .kop_empty
    ; Clamp the byte count to the scratch capacity; fat16_read_file is
    ; expected to honour edx, but defence-in-depth - this is the only
    ; bound between an attacker-controlled file size and the parse loop.
    cmp eax, NP_BUF_SIZE - 1
    jbe .kop_size_ok
    mov eax, NP_BUF_SIZE - 1
.kop_size_ok:
    lea rbx, [notepad_buf]
    mov byte [rbx + rax], 0

    ; Parse scratch -> slot's per-line layout.
    ;   r14 = slot base, rbx = scratch base, r12d = raw byte count
    mov r12d, eax
    xor ecx, ecx                      ; line index
    xor edx, edx                      ; column
    xor esi, esi                      ; raw offset

.kop_parse_loop:
    cmp esi, r12d
    jge .kop_parse_done
    cmp ecx, NP_MAX_LINES - 1
    jge .kop_parse_done

    movzx eax, byte [rbx + rsi]
    inc esi

    cmp al, 13
    je .kop_parse_cr
    cmp al, 10
    je .kop_parse_lf

    cmp edx, NP_MAX_COLS - 1
    jge .kop_parse_loop               ; clip overlong lines

    push rcx
    imul ecx, NP_MAX_COLS
    add rcx, rdx
    mov [r14 + rcx + notepad_buf - app_blob_start], al
    pop rcx
    inc edx
    jmp .kop_parse_loop

.kop_parse_cr:
    cmp esi, r12d
    jge .kop_parse_newline
    cmp byte [rbx + rsi], 10
    jne .kop_parse_newline
    inc esi
.kop_parse_lf:
.kop_parse_newline:
    push rcx
    imul ecx, NP_MAX_COLS
    add rcx, rdx
    mov byte [r14 + rcx + notepad_buf - app_blob_start], 0
    pop rcx
    mov [r14 + np_line_len - app_blob_start + rcx * 4], edx
    inc ecx
    xor edx, edx
    jmp .kop_parse_loop

.kop_parse_done:
    push rcx
    push rcx
    imul ecx, NP_MAX_COLS
    add rcx, rdx
    mov byte [r14 + rcx + notepad_buf - app_blob_start], 0
    pop rcx
    mov [r14 + np_line_len - app_blob_start + rcx * 4], edx
    pop rcx
    inc ecx
    mov [r14 + np_num_lines - app_blob_start], ecx
    mov dword [r14 + np_cursor_row - app_blob_start], 0
    mov dword [r14 + np_cursor_col - app_blob_start], 0
    mov dword [r14 + np_scroll_top - app_blob_start], 0
    jmp .kop_seed_visible

.kop_empty:
    mov dword [r14 + np_num_lines - app_blob_start], 1
    mov dword [r14 + np_cursor_row - app_blob_start], 0
    mov dword [r14 + np_cursor_col - app_blob_start], 0
    mov dword [r14 + np_scroll_top - app_blob_start], 0
    mov byte  [r14 + notepad_buf - app_blob_start], 0
    mov dword [r14 + np_line_len - app_blob_start], 0

.kop_seed_visible:
    ; Seed slot's szOpenTextScratch with the first visible line so the very
    ; first draw frame (which may fire before copy_line_to_scratch runs)
    ; renders real bytes instead of whatever was there before.
    lea rdi, [r14 + app_hl_notepad_szOpenTextScratch - app_blob_start]
    lea rsi, [r14 + notepad_buf - app_blob_start]
    mov ecx, NP_MAX_COLS - 1
.kop_copy_visible:
    lodsb
    test al, al
    jz .kop_copy_visible_done
    stosb
    dec ecx
    jnz .kop_copy_visible
.kop_copy_visible_done:
    mov byte [rdi], 0
    USER_ACCESS_END

    ; Clear scratch so we don't leave file bytes in the kernel image's master
    ; copy (defence-in-depth - nothing should read them, but stale file
    ; content lingering in kernel .data is a needless info-leak surface).
    push rdi
    push rax
    push rcx
    lea rdi, [notepad_buf]
    xor eax, eax
    mov ecx, NP_BUF_SIZE
    rep stosb
    pop rcx
    pop rax
    pop rdi

    mov rax, r13
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.kop_fail:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; kernel_open_file_in_media - runs in kernel context. Launches Media Player
; for an arbitrary FAT16 entry (NIC, NBA, or any future codec) and reads the
; file bytes into the new window's slot at APP_SLOT_BMP_FILE_OFF - the same
; offset `app_media_draw` probes for the magic on every frame.
;
; Mirrors kernel_open_file_in_notepad: the heavy lifting must run in kernel
; mode so the real fat16_* helpers (not user-mode syscall macros) can be
; called, and so the slot we write into is the *new* Media Player window's
; slot, not the caller's (a long-standing bug in the legacy BMP opener).
;
; RDI = slot-cached dir entry pointer
; Returns RAX = window id, or -1 on launch failure / read failure.
; ============================================================================
global kernel_open_file_in_media
extern page_alloc_contig
extern fat16_get_file_size
extern media_full_buf
extern media_full_buf_pages
extern media_release_window_buf
kernel_open_file_in_media:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi                      ; dir entry ptr

    ; Launch a fresh Media Player window via the normal dispatch.
    mov rdi, APP_MEDIA
    sub rsp, 8
    call app_launch
    add rsp, 8
    cmp rax, -1
    je .kom_fail
    mov r13, rax                      ; new window id

    ; Cascade window position so the viewer doesn't cover the explorer.
    mov rax, r13
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_X], 200
    mov rbx, r13
    imul rbx, 24
    add rbx, 100
    mov [rax + WIN_OFF_Y], rbx

    ; Resolve the new window's slot base.
    mov edi, r13d
    call l3_slot_base
    mov r14, rax                      ; slot base

    ; SMAP: from here the function freely mixes slot (user, PTE.U=1) reads and
    ; writes with kernel-scratch and window-pool accesses across many branches,
    ; and fat16_read_file below writes its bytes straight into the slot. Arm AC
    ; once for the whole body and clac at every ret. fat16_read_file does not
    ; touch AC, so it propagates correctly; an IRQ clears AC on entry and iret
    ; restores it, so the window is not nested-IRQ exploitable.
    USER_ACCESS_BEGIN

    ; Zero the slot's media buffer header so a failed read doesn't leave
    ; an old codec magic lingering from a previous tenant of this slot.
    lea rdi, [r14 + APP_SLOT_BMP_FILE_OFF]
    xor eax, eax
    mov ecx, 64                       ; just the header region is enough
    rep stosd

    ; Read file bytes into the slot's media buffer.
    lea rdi, [r14 + APP_SLOT_BMP_FILE_OFF]
    mov rsi, rdi
    mov rdi, r12
    mov edx, APP_SLOT_BMP_FILE_SZ
    call fat16_read_file
    cmp eax, -1
    je .kom_fail
    mov ebx, eax
    mov r15d, ebx

    ; APP_SLOT_BMP_FILE_SZ intentionally caps the generic synchronous load.
    ; NBA files can be much larger than a slot-local media buffer, so each media
    ; window allocates its OWN physically-contiguous full-clip buffer sized to
    ; the file and the real header stays in the slot for controls/hit-testing.
    ; Per-window ownership (vs. the old single shared buffer) means opening a
    ; second video no longer truncates the first one's playback.
    cmp dword [r14 + APP_SLOT_BMP_FILE_OFF], LAUNCH_NBA1_MAGIC ; 'NBA1'
    jne .kom_loaded

    ; Drop any buffer left over from a previous tenant of this reused window id.
    mov edi, r13d
    call media_release_window_buf

    mov rdi, r12
    call fat16_get_file_size                 ; eax = file size in bytes
    cmp eax, APP_SLOT_BMP_FILE_SZ
    jbe .kom_nba_clamp_slot                  ; fits the slot: no full buffer
    cmp eax, MEDIA_FULL_BUF_MAX_SZ
    jbe .kom_nba_sz_ok
    mov eax, MEDIA_FULL_BUF_MAX_SZ           ; cap absurdly large clips
.kom_nba_sz_ok:
    mov ebx, eax                             ; ebx = bytes to read
    add eax, 0xFFF
    shr eax, 12                              ; pages needed
    mov rdi, rax
    call page_alloc_contig                   ; rax = buffer base (0 = OOM)
    test rax, rax
    jz .kom_nba_clamp_slot                   ; OOM: fall back to slot
    ; Record ownership so the renderer can find it and close can free it.
    lea rdx, [rel media_full_buf]
    mov [rdx + r13*8], rax
    mov ecx, ebx
    add ecx, 0xFFF
    shr ecx, 12
    lea rdx, [rel media_full_buf_pages]
    mov [rdx + r13*8], rcx
    ; Load the clip into the freshly allocated buffer.
    mov rsi, rax                             ; dest
    mov rdi, r12                             ; entry
    mov edx, ebx                             ; max bytes
    call fat16_read_file
    cmp eax, 20
    jbe .kom_nba_free_fallback
    lea rcx, [rel media_full_buf]
    mov r11, [rcx + r13*8]                   ; buffer base
    cmp dword [r11], LAUNCH_NBA1_MAGIC
    jne .kom_nba_free_fallback
    mov ebx, eax                             ; bytes loaded into full buffer
    ; Refresh the slot header from the full buffer so controls/sizing match.
    mov eax, [r11 + 0]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 0], eax
    mov eax, [r11 + 4]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 4], eax
    mov eax, [r11 + 8]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 8], eax
    mov eax, [r11 + 12]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 12], eax
    mov eax, [r11 + 16]
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 16], eax
    jmp .kom_nba_validate_loaded

.kom_nba_free_fallback:
    ; The full-buffer read failed validation. Release it and fall back to the
    ; slot-local bytes already loaded above.
    mov edi, r13d
    call media_release_window_buf
.kom_nba_clamp_slot:
    ; No full buffer in play. Fall back to the slot-local bytes and clamp
    ; frame_count so the renderer never walks past the 256 KiB slot buffer.
    mov ebx, r15d
.kom_nba_validate_loaded:
    cmp ebx, 20
    jbe .kom_nba_no_frames
    mov eax, [r14 + APP_SLOT_BMP_FILE_OFF + 4]
    test eax, eax
    jz .kom_nba_no_frames
    mov ecx, [r14 + APP_SLOT_BMP_FILE_OFF + 8]
    test ecx, ecx
    jz .kom_nba_no_frames
    imul eax, ecx
    shl eax, 2
    test eax, eax
    jz .kom_nba_no_frames
    mov ecx, eax                      ; frame bytes
    mov eax, ebx
    sub eax, 20
    xor edx, edx
    div ecx                           ; eax = complete loaded frames
    test eax, eax
    jz .kom_nba_no_frames
    cmp eax, [r14 + APP_SLOT_BMP_FILE_OFF + 12]
    jae .kom_loaded
    mov [r14 + APP_SLOT_BMP_FILE_OFF + 12], eax
    jmp .kom_loaded
.kom_nba_no_frames:
    mov dword [r14 + APP_SLOT_BMP_FILE_OFF + 12], 0
.kom_loaded:
    ; Native-size NBA playback avoids the expensive scaler hot path for the
    ; common BOOTANIM.NBA case while still using normal controls/chrome.
    cmp dword [r14 + APP_SLOT_BMP_FILE_OFF], LAUNCH_NBA1_MAGIC ; 'NBA1'
    jne .kom_return
    mov rax, r13
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov ebx, [r14 + APP_SLOT_BMP_FILE_OFF + 4]          ; source w
    test ebx, ebx
    jz .kom_return
    add ebx, BORDER_WIDTH * 2
    cmp ebx, MIN_WINDOW_W
    jae .kom_w_ok
    mov ebx, MIN_WINDOW_W
.kom_w_ok:
    mov [rax + WIN_OFF_W], rbx
    mov ebx, [r14 + APP_SLOT_BMP_FILE_OFF + 8]          ; source h
    test ebx, ebx
    jz .kom_return
    add ebx, TITLEBAR_HEIGHT + BORDER_WIDTH + MEDIA_PLAYER_BAR_H
    cmp ebx, MIN_WINDOW_H
    jae .kom_h_ok
    mov ebx, MIN_WINDOW_H
.kom_h_ok:
    mov [rax + WIN_OFF_H], rbx

.kom_return:
    USER_ACCESS_END

    mov rax, r13
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.kom_fail:
    ; Reached both before the USER_ACCESS_BEGIN above (early app_launch fail,
    ; AC already clear) and after it; clac is a harmless no-op in the former.
    USER_ACCESS_END
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Restore the user-mode alias for the remainder of the blob.
%xdefine fat16_file_count app_sys_fs_count
%xdefine fat16_get_entry app_sys_fs_get_entry
%xdefine fat16_change_dir app_sys_fs_change_dir
%xdefine fat16_read_file app_sys_fs_read

; ============================================================================
; FILE EXPLORER APP
; Virtual filesystem with navigable directories
; ============================================================================

; Draw callback: RDI = window struct ptr
