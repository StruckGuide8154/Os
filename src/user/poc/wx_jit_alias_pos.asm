; ============================================================================
; W^X JIT-alias positive PoC: write code via a W+NX alias, execute via X+!W.
;
; Manual wiring:
;   Include this file inside src/user/apps.asm and call wx_jit_alias_pos_click
;   from an existing app callback. Expects app_blob_start to be in scope.
;
; Expected serial/debug output:
;   WX-JIT-ALIAS-POS-PASS
; ============================================================================

bits 64

%include "nexus_app.inc"

; Synthetic 32-bit return value baked into the JIT-written `mov eax, imm32; ret`
; stub and re-checked after executing it through the X alias. Arbitrary sentinel
; ("JIT" leetspeak-ish) — its only job is to prove the bytes written through the
; W alias are the bytes executed through the X alias.
WX_JIT_ALIAS_SENTINEL equ 0x4A1751CC

align 4096
global wx_jit_alias_pos_click
wx_jit_alias_pos_click:
wx_jit_alias_pos_code_start:
    mov rdi, wx_jit_alias_pos_code_start - app_blob_start
    mov rsi, wx_jit_alias_pos_code_end - app_blob_start
    SYS_WX_INSTALL_MANIFEST rdi, rsi
    cmp rax, 0
    jne .fail

    ; X target lies inside the manifest's code range; W alias lies in the
    ; data page placed AFTER code_end so it is outside the code range but
    ; still inside the slot with a present PTE (blob page).
    lea rdi, [rel wx_jit_alias_pos_x_page]
    lea rsi, [rel wx_jit_alias_pos_w_page]
    mov rdx, 0x1000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    cmp rax, 0
    jne .fail

    ; mov eax, WX_JIT_ALIAS_SENTINEL ; ret — written via W+NX alias, exec via X+!W.
    lea rbx, [rel wx_jit_alias_pos_w_page]
    mov byte  [rbx + 0], 0xB8
    mov dword [rbx + 1], WX_JIT_ALIAS_SENTINEL
    mov byte  [rbx + 5], 0xC3

    lea rbx, [rel wx_jit_alias_pos_x_page]
    call rbx
    mov ecx, WX_JIT_ALIAS_SENTINEL
    cmp eax, ecx
    jne .fail

    lea rdi, [rel sz_wx_jit_alias_pos_pass]
    SYS_PRINT rdi
    SYS_EXIT
.fail:
    lea rdi, [rel sz_wx_jit_alias_pos_fail]
    SYS_PRINT rdi
    SYS_EXIT

align 4096
wx_jit_alias_pos_x_page:
    times 4096 db 0
wx_jit_alias_pos_code_end:

align 4096
wx_jit_alias_pos_w_page:
    times 4096 db 0

sz_wx_jit_alias_pos_pass: db "WX-JIT-ALIAS-POS-PASS", 0
sz_wx_jit_alias_pos_fail: db "WX-JIT-ALIAS-POS-FAIL", 0
