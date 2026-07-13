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
; BT_BLK_STRIDE=22. The VBE geometry comes from src/include/boot_memory.inc;
; every dimension and arithmetic step is checked before framebuffer access.
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
    mov r10d, [abs VBE_INFO + VBE_HEIGHT_OFF]   ; r10d = height (px)
    test r10d, r10d
    jz .done
    cmp byte [abs VBE_INFO + VBE_BPP_OFF], 32   ; painter emits 32-bit pixels
    jne .done
    mov r9d, [abs VBE_INFO + VBE_PITCH_OFF]     ; r9d = pitch (bytes/row)
    test r9d, r9d
    jz .done
    cmp r8d, 0x3FFFFFFF                         ; width*4 must not overflow
    ja .done
    mov eax, r8d
    shl eax, 2
    cmp r9d, eax                                ; each visible row fits pitch
    jb .done

    mov r11d, [v_blkidx]                        ; r11d = idx (RIP-relative image var)
    cmp r11d, 0xFFFFFFFF                        ; never wrap the progress index
    je .done

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

    imul edx, edx, 22                           ; col*stride (bounded by width)
    add edx, 2                                  ; + left margin
    mov ecx, edx
    add ecx, 18
    jc .done
    cmp ecx, r8d                                ; x + block width <= width
    ja .done
    mov r8d, edx                                ; r8 = x (px)

    imul rax, rax, 22                           ; row*stride, 64-bit
    jo .done
    add rax, 4                                  ; + top margin (loader band y=4)
    jc .done
    mov rcx, rax
    add rcx, 18
    jc .done
    cmp rcx, r10                                ; y + block height <= height
    ja .done

    mul r9                                      ; rdx:rax = y*pitch
    test rdx, rdx
    jnz .done
    add rax, rsi                                ; framebuffer base + row offset
    jc .done
    shl r8, 2                                   ; x*4, already width-bounded
    add rax, r8
    jc .done
    mov rdi, rax

    ; Prove the last write address cannot wrap: 17 more rows plus 18 pixels.
    mov eax, 17
    mul r9
    test rdx, rdx
    jnz .done
    add rax, 72
    jc .done
    add rax, rdi
    jc .done

    lea eax, [r11 + 1]
    mov [v_blkidx], eax                         ; advance only after validation

    ; color = v_blkpal[idx & 7] -> ebx
    mov eax, r11d
    and eax, 7
    lea rcx, [v_blkpal]
    mov ebx, [rcx + rax*4]

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
