; ============================================================================
; W^X negative PoC: a manifestless blob page must never be write-then-execute.
;
; Manual wiring:
;   Include inside src/user/apps.asm and invoke wx_poc_manifestless_blob_click
;   from a test callback only after clearing that slot's W^X manifest to version
;   0/invalid. The fixed kernel fails closed: a no-valid-manifest slot is W+NX,
;   so execution faults before the blob page can run. The historical vulnerable
;   path left blob pages W+X; this PoC then writes a tiny function into the blob
;   and executes it, printing WX-MANIFESTLESS-FAIL.
; ============================================================================

bits 64

%include "grit_app.inc"

align 4096
global wx_poc_manifestless_blob_click
wx_poc_manifestless_blob_click:
    lea rbx, [rel wx_poc_manifestless_blob_page]
    mov byte [rbx + 0], 0xB8          ; mov eax, 0x42
    mov dword [rbx + 1], 0x42
    mov byte [rbx + 5], 0xC3          ; ret
    call rbx                          ; expected #PF under fail-closed W+NX

    lea rdi, [rel sz_wx_manifestless_fail]
    SYS_PRINT rdi
    ret

align 4096
wx_poc_manifestless_blob_page:
    times 4096 db 0

sz_wx_manifestless_fail: db "WX-MANIFESTLESS-FAIL", 0
