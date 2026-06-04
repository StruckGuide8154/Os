; §5  Video codecs — NBA + timeline
; ---------------------------------------------------------------------------

; nx_media_advance_frame
;   Per-tick frame advance. Honours pause / loop / pending seek. Writes
;   the resolved frame back into slot state and sets `scene_dirty` on
;   visible change so the WM repaints the next vsync.
;
;   Inputs:
;     r12 = file ptr
;     r13 = window struct ptr
;     ecx = frame_count
;     edx = fps
;   Output:
;     eax = current frame index in [0, frame_count)
;   Clobbers: rax, rbx, rdx (caller saves anything else it cares about).
nx_media_advance_frame:
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r8, [r13 + WIN_OFF_APPDATA]          ; slot base

    ; 1. Consume any pending seek. mp_seek_to stores target+1; zero =
    ;    "no seek". Clamp and rebase mp_last_tick.
    mov eax, [r8 + app_hl_media_mp_seek_to - app_blob_start]
    test eax, eax
    jz .adv_no_seek
    dec eax
    test eax, eax
    jns .adv_seek_nonneg
    xor eax, eax
.adv_seek_nonneg:
    cmp eax, ecx
    jb .adv_seek_in_range
    mov eax, ecx
    dec eax
.adv_seek_in_range:
    mov [r8 + app_hl_media_mp_frame - app_blob_start], eax
    mov rbx, [tick_count]
    mov [r8 + app_hl_media_mp_last_tick - app_blob_start], rbx
    mov dword [r8 + app_hl_media_mp_seek_to - app_blob_start], 0
    mov byte [scene_dirty], 1
    jmp .adv_clamp

.adv_no_seek:
    ; 2. Bring slot-saved frame into range (slots zero-init so frame 0 is
    ;    the valid resting state on first draw).
    mov eax, [r8 + app_hl_media_mp_frame - app_blob_start]
    cmp eax, ecx
    jb .adv_in_range
    xor eax, eax
    mov [r8 + app_hl_media_mp_frame - app_blob_start], eax
.adv_in_range:

    ; 3. Frozen if paused or single-frame clip.
    cmp dword [r8 + app_hl_media_mp_paused - app_blob_start], 0
    jne .adv_clamp
    cmp ecx, 1
    jbe .adv_clamp

    ; Animated and playing: media_live_refresh wakes the compositor on the
    ; frame boundary. Do not dirty here unless the frame actually changes.

    ; 4. interval_ticks = max(1, 100 / fps).
    mov r10d, eax                            ; current frame
    mov eax, 100
    xor edx, edx
    div dword [r12 + 16]
    test eax, eax
    jnz .adv_interval_ok
    mov eax, 1
.adv_interval_ok:
    mov r11d, eax                            ; interval ticks

    mov rax, [tick_count]
    mov rbx, [r8 + app_hl_media_mp_last_tick - app_blob_start]
    test rbx, rbx
    jnz .adv_have_last_tick
    ; First tick after open: seed last_tick, stay on frame 0.
    mov [r8 + app_hl_media_mp_last_tick - app_blob_start], rax
    mov eax, r10d
    jmp .adv_clamp
.adv_have_last_tick:
    mov r9, rax
    sub r9, rbx
    cmp r9d, r11d
    jb .adv_no_advance

    ; advanced_frames = (now - last) / interval
    mov rax, r9
    xor edx, edx
    div r11
    add eax, r10d                            ; new frame index (raw)

    cmp dword [r8 + app_hl_media_mp_no_loop - app_blob_start], 0
    je .adv_loop
    ; Freeze at last frame.
    cmp eax, ecx
    jb .adv_store
    mov eax, ecx
    dec eax
    jmp .adv_store
.adv_loop:
    xor edx, edx
    div ecx
    mov eax, edx                             ; raw mod frame_count
.adv_store:
    mov [r8 + app_hl_media_mp_frame - app_blob_start], eax
    mov rbx, [tick_count]
    mov [r8 + app_hl_media_mp_last_tick - app_blob_start], rbx
    mov byte [scene_dirty], 1
    jmp .adv_clamp
.adv_no_advance:
    mov eax, r10d

.adv_clamp:
    cmp eax, ecx
    jb .adv_ret
    xor eax, eax
.adv_ret:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    ret


; nx_media_blit_nba
;   NBA1: magic +0, u32 w +4, u32 h +8, u32 frame_count +12, u32 fps +16,
;   dense BGRA frames at +20.
nx_media_blit_nba:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi
    mov r13, rsi

    mov r14d, [r12 + 4]
    mov r15d, [r12 + 8]
    mov ecx,  [r12 + 12]
    mov edx,  [r12 + 16]
    test r14d, r14d
    jz .nba_done
    test r15d, r15d
    jz .nba_done
    test ecx, ecx
    jz .nba_done
    test edx, edx
    jz .nba_done

    ; Clamp frame_count to what the active source buffer can actually hold.
    ; r8 (set by app_media_draw) = source buffer capacity in bytes: either the
    ; window's own full-clip buffer or, when none is live, the 256 KiB slot
    ; buffer. A header may advertise more frames than the buffer holds (e.g. a
    ; truncated/failed load); without this clamp the per-frame source walk reads
    ; past the buffer into unmapped memory and faults, freezing the OS.
    push rdx                                 ; preserve fps
    mov eax, r14d
    mov r9d, r15d
    imul rax, r9                             ; w * h
    shl rax, 2                               ; frame stride in bytes
    jz .nba_clamp_done                       ; degenerate stride: leave as-is
    mov r10, rax                             ; r10 = frame stride
    mov rax, r8                              ; source capacity in bytes
    cmp rax, 20
    jbe .nba_clamp_none                      ; can't even hold the header
    sub rax, 20                              ; minus NBA header
    xor edx, edx
    div r10                                  ; rax = whole frames that fit
    cmp ecx, eax
    jbe .nba_clamp_done
    mov ecx, eax                             ; clamp frame_count down to fit
    jmp .nba_clamp_done
.nba_clamp_none:
    xor ecx, ecx
.nba_clamp_done:
    pop rdx                                  ; restore fps
    test ecx, ecx
    jz .nba_done                             ; nothing fits -> blank, never fault

    ; Resolve current frame (handles seek/pause/loop, writes state).
    call nx_media_advance_frame              ; eax = frame index
    mov ebx, eax                             ; preserve

    ; Source frame ptr.
    mov esi, r14d
    imul esi, r15d
    shl esi, 2                               ; frame stride bytes
    mov eax, ebx
    mul rsi                                  ; rax = frame * stride
    lea rsi, [r12 + 20]
    add rsi, rax

    ; Hand off to the scaler.
    push r12
    mov r12, rsi                             ; source for scaler
    mov dl, 0                                ; opaque
    mov r9d, MEDIA_BAR_H                     ; reserve bottom strip
    call nx_media_blit_scaled
    pop r12

    ; Draw the control bar over the bottom MEDIA_BAR_H px.
    mov rdi, r12
    mov rsi, r13
    mov edx, ebx
    mov ecx, [r12 + 12]
    mov r8d, [r12 + 16]
    call nx_media_draw_nba_controls

.nba_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret


