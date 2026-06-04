; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI PE header and entry flow
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

section .text start=0
    dw 0x5A4D
    times 29 dw 0
    dd pe_hdr
pe_hdr:
    dd 0x00004550
    dw 0x8664, 2
    dd 0, 0, 0
    dw opt_end - opt_hdr
    dw 0x0206
opt_hdr:
    dw 0x020B
    db 1, 0
    dd TEXT_RAWSIZE, 0, 0, TEXT_VADDR, TEXT_VADDR
    dq 0x100000
    dd 0x1000, 0x200
    dw 0,0, 0,0, 0,0
    dd 0, IMAGE_SIZE, HEADER_SIZE, 0
    dw 10, 0
    dq 0x100000, 0x100000, 0x100000, 0x100000
    dd 0, 6
    dd 0,0, 0,0, 0,0, 0,0, 0,0
    dd RELOC_VADDR, RELOC_VSIZE
opt_end:
    db '.text',0,0,0
    dd TEXT_VSIZE, TEXT_VADDR, TEXT_RAWSIZE, HEADER_SIZE
    dd 0,0
    dw 0,0
    dd 0xE0000060
    db '.reloc',0,0
    dd RELOC_VSIZE, RELOC_VADDR, RELOC_FSIZE, RELOC_FOFF
    dd 0,0
    dw 0,0
    dd 0x42000040
    times (HEADER_SIZE - ($ - $$)) db 0

; ============================================================================
; ENTRY
; ============================================================================
_start:
    sub rsp, 128
    mov [v_handle], rcx
    mov [v_systab], rdx
    mov rax, [rdx + ST_CONOUT]
    mov [v_conout], rax
    mov rax, [rdx + ST_CONIN]
    mov [v_conin], rax
    mov rax, [rdx + ST_BOOTSERV]
    mov [v_bs], rax
    mov rax, [rdx + ST_RUNTIME]
    mov [v_rs], rax
    mov rax, [rdx + ST_FW_VEND]
    mov [v_fwv], rax

    ; Disable watchdog
    mov rcx, [v_bs]
    mov rax, [rcx + BS_WATCHDOG]
    xor ecx,ecx
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    sub rsp, 32
    call rax
    add rsp, 32

    ; Try to init GOP
    call fn_gop_init
    test eax, eax
    jnz .text_mode

    ; Try to init mouse
    call fn_mouse_init
    mov [v_mfound], al        ; save result (0=found, 1=not found)

    ; GOP available - show desktop with mouse cursor
    call fn_desktop

    ; Debug: draw mouse status indicator on title bar
    mov edi, 140
    mov esi, 12
    cmp byte [v_mfound], 0
    jne .mouse_nf
    ; Mouse found - show green "Mouse:OK"
    lea rdx, [a_mok]
    mov ecx, 0x0060E880
    mov r8d, 0x00201008
    call fn_draw_str
    jmp .mouse_dbg_done
.mouse_nf:
    ; No mouse - show red "Mouse:--"
    lea rdx, [a_mno]
    mov ecx, 0x004040FF
    mov r8d, 0x00201008
    call fn_draw_str
.mouse_dbg_done:
    call fn_cursor_show

.boot_gfx_wait:
    ; Poll keyboard
    mov rcx, [v_conin]
    mov rax, [rcx + CI_KEY]
    lea rdx, [kd]
    call rax
    test rax, rax
    jnz .boot_no_key
    ; Got a key - check if it's a mouse key (arrows, *, -)
    call fn_kb_mouse
    test eax, eax
    jnz .boot_kb_moved     ; arrow/click handled
    ; Not a mouse key -> go to shell
    jmp .to_shell
.boot_kb_moved:
    cmp eax, 2             ; left click?
    je .boot_click
    call fn_cursor_hide
    call fn_cursor_show
    jmp .boot_gfx_wait
.boot_click:
    call fn_handle_click
    cmp eax, 1             ; close button
    je .to_shell
    cmp eax, 3             ; start button -> shell
    je .to_shell
    ; minimize or nothing - just continue
    jmp .boot_gfx_wait
.boot_no_key:
    ; Poll hardware mouse
    call fn_mouse_poll
    cmp eax, 0
    je .boot_gfx_stall     ; no mouse event
    cmp eax, 2
    je .boot_hw_click
    ; Mouse moved - redraw cursor
    call fn_cursor_hide
    call fn_cursor_show
    jmp .boot_gfx_wait
.boot_hw_click:
    call fn_handle_click
    cmp eax, 1
    je .to_shell
    cmp eax, 3
    je .to_shell
    call fn_cursor_hide
    call fn_cursor_show
    jmp .boot_gfx_wait

.boot_gfx_stall:
    mov rcx, 2000           ; 2ms poll interval
    call fn_stall
    jmp .boot_gfx_wait
.to_shell:
    ; Clear text layer and enter shell
    call fn_cls
    jmp .shell

.text_mode:
    call fn_cls
    mov dl, LCYAN
    call fn_tcolor
    lea rcx, [s_notxt]
    call fn_tpr

.shell:
    call fn_shell
.halt:
    hlt
    jmp .halt

