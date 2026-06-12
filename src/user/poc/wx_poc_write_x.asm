; ============================================================================
; W^X negative PoC: writing an X+!W page must fault.
;
; Manual wiring:
;   Include inside src/user/apps.asm and call wx_poc_write_x_click from a test
;   callback. The final store should raise #PF; reaching WX-WRITE-X-FAIL means
;   the page was writable while executable.
; ============================================================================

bits 64

%include "grit_app.inc"

align 4096
global wx_poc_write_x_click
wx_poc_write_x_click:
wx_poc_write_x_code_start:
    mov rdi, wx_poc_write_x_code_start - app_blob_start
    mov rsi, wx_poc_write_x_code_end - app_blob_start
    SYS_WX_INSTALL_MANIFEST rdi, rsi
    cmp rax, 0
    jne .fail

    lea rbx, [rel wx_poc_write_x_page]
    mov rdi, rbx
    mov rsi, MPROT_WX_MODE_XRO
    SYS_MPROTECT_WX rdi, rsi
    cmp rax, 0
    jne .fail

    mov byte [rbx], 0x90              ; expected #PF
.fail:
    lea rdi, [rel sz_wx_write_x_fail]
    SYS_PRINT rdi
    ret

align 4096
wx_poc_write_x_page:
    times 4096 db 0xC3
wx_poc_write_x_code_end:

sz_wx_write_x_fail: db "WX-WRITE-X-FAIL", 0
