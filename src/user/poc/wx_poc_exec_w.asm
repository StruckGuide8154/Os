; ============================================================================
; W^X negative PoC: executing a W+NX page must fault.
;
; Manual wiring:
;   Include inside src/user/apps.asm and call wx_poc_exec_w_click from a test
;   callback. The indirect call should raise #PF; reaching WX-EXEC-W-FAIL means
;   NX was not enforced.
; ============================================================================

bits 64

%include "grit_app.inc"

align 4096
global wx_poc_exec_w_click
wx_poc_exec_w_click:
wx_poc_exec_w_code_start:
    mov rdi, wx_poc_exec_w_code_start - app_blob_start
    mov rsi, wx_poc_exec_w_code_end - app_blob_start
    SYS_WX_INSTALL_MANIFEST rdi, rsi
    cmp rax, 0
    jne .fail

    lea rbx, [rel wx_poc_exec_w_page]
    mov rdi, rbx
    mov rsi, MPROT_WX_MODE_WNX
    SYS_MPROTECT_WX rdi, rsi
    cmp rax, 0
    jne .fail

    mov byte [rbx + 0], 0xB8          ; mov eax, 0x42
    mov dword [rbx + 1], 0x42
    mov byte [rbx + 5], 0xC3          ; ret
    call rbx                          ; expected #PF
.fail:
    lea rdi, [rel sz_wx_exec_w_fail]
    SYS_PRINT rdi
    ret

align 4096
wx_poc_exec_w_page:
    times 4096 db 0
wx_poc_exec_w_code_end:

sz_wx_exec_w_fail: db "WX-EXEC-W-FAIL", 0
