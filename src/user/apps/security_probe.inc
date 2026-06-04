; ============================================================================
; Security probe app for high-impact vulnerability verification.
; Launched by serial command 0x01 + '8' in debug builds.
; ============================================================================

SEC_OFF_RAN       equ 0x100
SEC_OFF_READ_BUF  equ 0x2000
SEC_OFF_WRITE_SRC equ 0x5000
SEC_OFF_WRITE_DST equ 0x7000
SEC_FILL_SIZE     equ 4096
%ifdef NEXUS_CACHE32_MAX
SEC_FAT16_ROOT_CACHE equ 0x1A11000
%else
SEC_FAT16_ROOT_CACHE equ 0xD11000
%endif
SEC_README_ENTRY   equ (SEC_FAT16_ROOT_CACHE + 32)
SEC_WRITTEN_ENTRY  equ (SEC_FAT16_ROOT_CACHE + (6 * 32))
SECPROBE_COL_PANEL_BG equ 0x000000A8   ; security-probe result panel background (dark blue, ARGB)

%macro SEC_MARK 1
    mov rax, %1
    syscall
%endmacro

app_security_probe_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi
    mov rbx, [rdi + WIN_OFF_APPDATA]
    cmp byte [rbx + SEC_OFF_RAN], 1
    je .draw_only
    mov byte [rbx + SEC_OFF_RAN], 1

    SEC_MARK 0x80

    call sec_probe_fs_read_overwrite
    call sec_probe_fs_write_leak
    call sec_probe_foreign_close

    SEC_MARK 0x8F

.draw_only:
    mov rdi, [r12 + WIN_OFF_X]
    add rdi, BORDER_WIDTH + 10
    mov rsi, [r12 + WIN_OFF_Y]
    add rsi, TITLEBAR_HEIGHT + 12
    mov edx, 420
    mov ecx, 96
    mov r8d, SECPROBE_COL_PANEL_BG
    SYS_GUI_RECT rdi, rsi, rdx, rcx, r8
    lea rdx, [rel szSecurityProbeTitle]
    mov ecx, COLOR_TEXT_WHITE
    SYS_GUI_TEXT rdi, rsi, rdx, rcx, r8

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

sec_probe_fs_read_overwrite:
    push rbx
    push rdi
    push rsi
    push rcx

    lea rdi, [rbx + SEC_OFF_READ_BUF]
    mov ecx, SEC_FILL_SIZE
    mov al, 0xA5
    cld
    rep stosb

    mov rdi, SEC_README_ENTRY
    lea rsi, [rbx + SEC_OFF_READ_BUF]
    mov rdx, 1
    SYS_FS_READ rdi, rsi, rdx
    cmp rax, -1
    je .fail_read_reject

    cmp byte [rbx + SEC_OFF_READ_BUF + 1], 0xA5
    jne .pass
.fail:
    SEC_MARK 0xF2
    jmp .done
.fail_read_reject:
    SEC_MARK 0xE8
    jmp .done
.pass:
    SEC_MARK 0x82
.done:
    pop rcx
    pop rsi
    pop rdi
    pop rbx
    ret

sec_probe_fs_write_leak:
    push rbx
    push rcx
    push rdi
    push rsi

    lea rdi, [rbx + SEC_OFF_WRITE_SRC]
    mov ecx, SEC_FILL_SIZE
    xor eax, eax
    cld
    rep stosb
    mov byte [rbx + SEC_OFF_WRITE_SRC], 'Z'
    lea rsi, [rel szLeakMark]
    lea rdi, [rbx + SEC_OFF_WRITE_SRC + 1]
    mov ecx, 8
    rep movsb

    lea rdi, [rel secWriteName]
    lea rsi, [rbx + SEC_OFF_WRITE_SRC]
    mov rdx, 1
    SYS_FS_WRITE rdi, rsi, rdx
    cmp rax, 0
    jne .fail_write_reject

    mov rdi, SEC_WRITTEN_ENTRY
    lea rsi, [rbx + SEC_OFF_WRITE_DST]
    mov rdx, 64
    SYS_FS_READ rdi, rsi, rdx
    cmp byte [rbx + SEC_OFF_WRITE_DST], 'Z'
    jne .fail_no_written_byte

    lea rsi, [rel szLeakMark]
    lea rdi, [rbx + SEC_OFF_WRITE_DST + 1]
    mov ecx, 8
.cmp_loop:
    mov al, [rsi]
    cmp al, [rdi]
    jne .fail
    inc rsi
    inc rdi
    dec ecx
    jnz .cmp_loop
    SEC_MARK 0x83
    jmp .done
.fail:
    SEC_MARK 0xF3
    jmp .done
.fail_no_written_byte:
    SEC_MARK 0xE3
    jmp .done
.fail_write_reject:
    SEC_MARK 0xE9
.done:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

sec_probe_foreign_close:
    push rax
    push rcx
    push rdi
    mov rdi, APP_ABOUT
    SYS_APP_LAUNCH rdi
    cmp rax, -1
    je .fail
    mov rdi, rax
    mov rcx, [r12 + WIN_OFF_ID]
    cmp rdi, rcx
    jne .close_foreign
    mov rdi, rcx
    xor rdi, 1
.close_foreign:
    SYS_WM_CLOSE rdi
    cmp rax, 0
    jne .fail
    SEC_MARK 0x87
    jmp .done
.fail:
    SEC_MARK 0xF7
.done:
    pop rdi
    pop rcx
    pop rax
    ret

szSecurityProbeTitle db "Security Probe", 0
szLeakMark db "LEAKMARK"
secWriteName db "SECPROBE", "BIN"
