; ============================================================================
; W^X positive PoC: write JIT bytes in W+NX mode, flip to X+!W, execute.
;
; Manual wiring:
;   Include this file inside src/user/apps.asm and call wx_poc_pos_click from
;   an existing app callback, or temporarily rename the symbol to the callback
;   being tested. It expects app_blob_start to be in scope.
;
; Expected serial/debug output:
;   WX-POS-PASS
; ============================================================================

bits 64

%include "grit_app.inc"

align 4096
global wx_poc_pos_click
wx_poc_pos_click:
wx_poc_pos_code_start:
    mov rdi, wx_poc_pos_code_start - app_blob_start
    mov rsi, wx_poc_pos_code_end - app_blob_start
    SYS_WX_INSTALL_MANIFEST rdi, rsi
    cmp rax, 0
    jne .fail

    lea rbx, [rel wx_poc_pos_jit_page]
    mov rdi, rbx
    mov rsi, MPROT_WX_MODE_WNX
    SYS_MPROTECT_WX rdi, rsi
    cmp rax, 0
    jne .fail

    ; mov eax, 0x42; ret
    mov byte [rbx + 0], 0xB8
    mov dword [rbx + 1], 0x42
    mov byte [rbx + 5], 0xC3

    mov rdi, rbx
    mov rsi, MPROT_WX_MODE_XRO
    SYS_MPROTECT_WX rdi, rsi
    cmp rax, 0
    jne .fail

    call rbx
    cmp eax, 0x42
    jne .fail

    lea rdi, [rel sz_wx_pos_pass]
    SYS_PRINT rdi
    ret
.fail:
    lea rdi, [rel sz_wx_pos_fail]
    SYS_PRINT rdi
    ret

align 4096
wx_poc_pos_jit_page:
    times 4096 db 0
wx_poc_pos_code_end:

sz_wx_pos_pass: db "WX-POS-PASS", 0
sz_wx_pos_fail: db "WX-POS-FAIL", 0
