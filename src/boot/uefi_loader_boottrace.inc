; ============================================================================
; Boot-progress block tracer - loader side (GRIT_BOOT_TRACE, debug-only).
;
; bootblk_next paints the next colored square into the loader's top progress
; band (y=4) of the GOP framebuffer and advances v_blkidx. The kernel paints an
; independent band below it (boot_timing.ghl boot_block_next). Together they give
; a visible per-stage boot trace on real hardware: when the machine hangs before
; the GUI, the last/rightmost block painted is the last stage that COMPLETED.
;
; The whole file is %ifdef'd out unless GRIT_BOOT_TRACE is defined, so release
; (and ordinary debug) loader images are byte-for-byte unchanged. The routine
; saves and restores ALL registers + flags so callers need no clobber awareness.
;
; Geometry must stay in lockstep with boot_timing.ghl: BT_BLK_SIZE=18,
; BT_BLK_STRIDE=22. VBE_FB_ADDR_OFF / VBE_WIDTH_OFF / VBE_PITCH_OFF come from
; src/include/boot_memory.inc; VBE_INFO is the fixed handoff page (abs).
; ============================================================================
%ifdef GRIT_BOOT_TRACE

align 8
v_blkidx: dd 0
align 4
; 0x00RRGGBB palette, cycled every 8 blocks (matches blk_color in boot_timing.ghl).
v_blkpal:
    dd 0x00FF3030, 0x00FF9020, 0x00F0F000, 0x0030D030
    dd 0x0030D0D0, 0x004080FF, 0x00E040E0, 0x00FFFFFF

; void bootblk_next(void) - preserves every register + flags.
bootblk_next:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    pushfq

    mov rsi, [abs VBE_INFO + VBE_FB_ADDR_OFF]   ; rsi = framebuffer base (fixed phys)
    test rsi, rsi
    jz .done
    mov r8d, [abs VBE_INFO + VBE_WIDTH_OFF]     ; r8d = width (px)
    test r8d, r8d
    jz .done
    mov r9d, [abs VBE_INFO + VBE_PITCH_OFF]     ; r9d = pitch (bytes/row)

    mov r11d, [v_blkidx]                        ; r11d = idx (RIP-relative image var)
    lea eax, [r11 + 1]
    mov [v_blkidx], eax                         ; idx++

    ; color = v_blkpal[idx & 7] -> ebx (survives the div/imul below)
    mov eax, r11d
    and eax, 7
    lea rcx, [v_blkpal]
    mov ebx, [rcx + rax*4]

    ; per_row = width / BT_BLK_STRIDE(22)
    mov eax, r8d
    xor edx, edx
    mov ecx, 22
    div ecx                                     ; eax = per_row
    test eax, eax
    jz .done
    mov ecx, eax                                ; ecx = per_row

    ; row = idx / per_row (eax) ; col = idx % per_row (edx)
    mov eax, r11d
    xor edx, edx
    div ecx

    imul edx, edx, 22                           ; col*stride
    add edx, 2                                  ; + left margin
    mov r10d, edx                               ; r10 = x (px)
    imul eax, eax, 22                           ; row*stride
    add eax, 4                                  ; + top margin (loader band y=4)

    mul r9d                                     ; rax = y*pitch (edx=0; fits 32 bits)
    lea rdi, [rsi + rax]                        ; fb + y*pitch
    lea rdi, [rdi + r10*4]                      ; + x*4 -> row base ptr

    mov r11d, 18                                ; BT_BLK_SIZE rows (dy)
.row:
    mov rcx, rdi
    mov edx, 18                                 ; BT_BLK_SIZE cols (dx)
    mov eax, ebx                                ; color
.col:
    mov [rcx], eax
    add rcx, 4
    dec edx
    jnz .col
    add rdi, r9                                 ; next scanline
    dec r11d
    jnz .row
.done:
    popfq
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

%endif
