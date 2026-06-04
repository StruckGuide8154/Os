; ============================================================================
; GOP_INIT  - find GOP, set best video mode (prefer 1024x768), fill VBE_INFO
; Returns: RAX = 0 success, 1 fail
; ============================================================================
gop_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; 5 pushes = 40 bytes. Entry 16n-8. After pushes: 16n-48.
    ; sub 80 -> 16n-128 = 0 mod 16. Aligned.
    sub rsp, 80
    ; [rsp +  0..31] shadow space
    ; [rsp + 32]     arg5 slot
    ; [rsp + 40]     arg6 slot
    ; [rsp + 48]     local: num_handles
    ; [rsp + 56]     local: handle_buffer ptr
    ; [rsp + 64]     local: info_size
    ; [rsp + 72]     local: info_ptr

    ; --- Try LocateProtocol(gop_guid, NULL, &v_gop) ---
    mov rax, [v_bs]
    mov rax, [rax + BS_LOCATE]
    lea rcx, [guid_gop]
    xor edx, edx
    lea r8, [v_gop]
    call rax
    test rax, rax
    jz .found

    ; --- Fallback: LocateHandleBuffer + OpenProtocol ---
    mov qword [rsp+48], 0
    mov qword [rsp+56], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCHNDL]
    mov ecx, 2                      ; ByProtocol
    lea rdx, [guid_gop]
    xor r8d, r8d
    lea r9, [rsp+48]                ; &num_handles
    lea r10, [rsp+56]               ; &handle_buffer
    mov [rsp+32], r10               ; arg5
    call rax
    test rax, rax
    jnz .fail

    cmp qword [rsp+48], 0
    je .fail

    ; OpenProtocol(handle[0], &guid, &v_gop, imghandle, NULL, GET_PROTOCOL=2)
    mov rsi, [rsp+56]
    mov rcx, [rsi]
    mov rdx, [v_bs]
    mov rax, [rdx + BS_OPENPROT]
    lea rdx, [guid_gop]
    lea r8, [v_gop]
    mov r9, [v_handle]
    mov qword [rsp+32], 0
    mov qword [rsp+40], 2
    call rax
    test rax, rax
    jnz .fail

.found:
    mov rbx, [v_gop]
    test rbx, rbx
    jz .fail

    ; --- Iterate modes, pick the largest one whose pixel count fits the
    ;     kernel back buffer. "Largest" = greatest width*height. The cap
    ;     comes from boot_memory.inc::BOOT_BACK_BUFFER_SIZE (bytes) so any
    ;     future bump to the back buffer automatically widens the set of
    ;     acceptable modes.
    mov rax, [rbx + GOP_MODE]
    mov r12d, [rax + GOPM_MAX]
    xor r13d, r13d                  ; current mode index
    mov r14d, 0xFFFFFFFF            ; best mode (none)
    xor r15, r15                    ; best pixel count (rdx:rax fits in 32b for our sizes)

.mode_loop:
    cmp r13d, r12d
    jge .select

    mov rcx, rbx
    mov edx, r13d
    lea r8, [rsp+64]
    lea r9, [rsp+72]
    mov rax, [rbx + GOP_QUERY]
    call rax
    test rax, rax
    jnz .next_mode

    mov rax, [rsp+72]
    test rax, rax
    jz .next_mode

    mov ecx, [rax + GOPI_HRES]
    mov edx, [rax + GOPI_VRES]

    ; Reject modes wider than MAX_FB_WIDTH or taller than MAX_FB_HEIGHT.
    ; Without these caps we could pick a mode whose backing scanline does
    ; not fit BOOT_BACK_BUFFER_SIZE and crash the compositor.
    cmp ecx, MAX_FB_WIDTH
    ja .next_mode
    cmp edx, MAX_FB_HEIGHT
    ja .next_mode

    ; pixels = w * h. Compare to running max in r15.
    mov eax, ecx
    imul eax, edx                   ; eax = pixel count (fits in 32 bits for any sane res)
    cmp rax, r15
    jbe .next_mode
    mov r15, rax
    mov r14d, r13d

.next_mode:
    inc r13d
    jmp .mode_loop

.select:
    cmp r14d, 0xFFFFFFFF
    je .fail

    mov rcx, rbx
    mov edx, r14d
    mov rax, [rbx + GOP_SET]
    call rax
    test rax, rax
    jnz .fail

    mov rax, [rbx + GOP_MODE]
    mov rcx, [rax + GOPM_FBBASE]
    mov [v_fb], rcx

    mov edx, [rax + GOPM_CUR]
    mov rcx, rbx
    lea r8, [rsp+64]
    lea r9, [rsp+72]
    mov rax, [rbx + GOP_QUERY]
    call rax

    mov rax, [rsp+72]               ; Info ptr
    test rax, rax
    jz .fallback

    mov ecx, [rax + GOPI_HRES]
    mov [v_scrw], ecx
    mov ecx, [rax + GOPI_VRES]
    mov [v_scrh], ecx
    mov ecx, [rax + GOPI_PPSL]
    mov [v_pitch], ecx
    jmp .fill_vbe

.fallback:
    mov dword [v_scrw],  1024
    mov dword [v_scrh],  768
    mov dword [v_pitch], 1024

.fill_vbe:
    ; Fill boot info block:
    ;   [+0]  fb_addr   (qword)
    ;   [+8]  width     (dword)
    ;   [+12] height    (dword)
    ;   [+16] pitch_bytes (dword, pixels*4)
    ;   [+20] bpp       (dword)
    mov rdi, VBE_INFO
    mov rax, [v_fb]
    mov [rdi + VBE_FB_ADDR_OFF], rax
    mov eax, [v_scrw]
    mov [rdi + VBE_WIDTH_OFF], eax
    mov eax, [v_scrh]
    mov [rdi + VBE_HEIGHT_OFF], eax
    mov eax, [v_pitch]
    shl eax, 2                      ; pixels/line -> bytes/line
    mov [rdi + VBE_PITCH_OFF], eax
    mov dword [rdi + VBE_BPP_OFF], 32

    xor eax, eax
    jmp .done

.fail:
    mov eax, 1

.done:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
