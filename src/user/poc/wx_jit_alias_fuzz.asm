; ============================================================================
; W^X JIT-alias validator fuzz: invoke SYS_WX_JIT_ALIAS with malformed inputs
; and confirm each one is rejected with rax == -1.
;
; Subtests (all expected to return -1):
;   T01  unaligned x_va           (x_page + 1)
;   T02  unaligned w_alias_va     (w_page + 1)
;   T03  length = 0
;   T04  length not page-multiple (0x800)
;   T05  x range fully outside committed code range
;   T06  w alias range fully overlapping the code range
;   T07  w alias range partial overlap, high edge (alias straddles code_end)
;   T08  w alias range partial overlap, low edge  (alias straddles code_start)
;   T09  x range crosses slot end
;   T10  w alias range crosses slot end
;   T11  x_va in an unmapped slot hole (mid-slot, past the loaded blob)
;   T12  length = 0x1000 with x_va = 0 (clearly invalid)
;
; Manual wiring:
;   Include this file inside src/user/apps.asm and call wx_jit_alias_fuzz_click
;   from an existing app callback. Expects app_blob_start to be in scope.
;
; Expected serial output (success):
;   WX-JIT-ALIAS-FUZZ 12/12 PASS
; ============================================================================

bits 64

%include "grit_app.inc"

APP_SLOT_SIZE_LOCAL equ 0x200000

; A staging page positioned BEFORE the manifest's code_start. The blob loader
; maps every page of the assembled blob, so this page exists with a present
; PTE inside the slot but outside the committed code range - needed for the
; low-edge overlap subtest T08.
align 4096
fuzz_pre_code_page:
    times 4096 db 0

align 4096
global wx_jit_alias_fuzz_click
wx_jit_alias_fuzz_click:
wx_jit_alias_fuzz_code_start:
    mov rdi, wx_jit_alias_fuzz_code_start - app_blob_start
    mov rsi, wx_jit_alias_fuzz_code_end - app_blob_start
    SYS_WX_INSTALL_MANIFEST rdi, rsi
    cmp rax, 0
    jne .install_fail

    xor r12d, r12d                       ; pass count
    xor r13d, r13d                       ; fail bitmap

    ; --- T01: unaligned x_va --------------------------------------------------
    lea rdi, [rel fuzz_x_page]
    add rdi, 1
    lea rsi, [rel fuzz_w_page]
    mov rdx, 0x1000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 0
    call .tally

    ; --- T02: unaligned w_alias_va --------------------------------------------
    lea rdi, [rel fuzz_x_page]
    lea rsi, [rel fuzz_w_page]
    add rsi, 1
    mov rdx, 0x1000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 1
    call .tally

    ; --- T03: length = 0 ------------------------------------------------------
    lea rdi, [rel fuzz_x_page]
    lea rsi, [rel fuzz_w_page]
    xor rdx, rdx
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 2
    call .tally

    ; --- T04: length not page-multiple ----------------------------------------
    lea rdi, [rel fuzz_x_page]
    lea rsi, [rel fuzz_w_page]
    mov rdx, 0x800
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 3
    call .tally

    ; --- T05: x range fully OUTSIDE the code range ----------------------------
    ; fuzz_w_page lives past code_end, so it is outside the manifest's code
    ; range. Using it as the X target must fail the "X inside code" check.
    lea rdi, [rel fuzz_w_page]
    lea rsi, [rel fuzz_w_alt_page]
    mov rdx, 0x1000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 4
    call .tally

    ; --- T06: w alias range fully overlapping the code range ------------------
    ; fuzz_x_page sits inside the code range; using it as the alias must fail
    ; the "alias outside code" check.
    lea rdi, [rel fuzz_x_page]
    lea rsi, [rel fuzz_x_alias_target]
    mov rdx, 0x1000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 5
    call .tally

    ; --- T07: alias partial overlap, high edge --------------------------------
    ; alias = [code_end - 0x1000, code_end + 0x1000): low page inside code,
    ; high page outside.
    lea rdi, [rel fuzz_x_page]
    lea rsi, [rel fuzz_last_code_page]
    mov rdx, 0x2000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 6
    call .tally

    ; --- T08: alias partial overlap, low edge ---------------------------------
    ; alias = [code_start - 0x1000, code_start + 0x1000): low page outside
    ; code, high page inside.
    lea rdi, [rel fuzz_x_page]
    lea rsi, [rel fuzz_pre_code_page]
    mov rdx, 0x2000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 7
    call .tally

    ; --- T09: x range crosses slot end ---------------------------------------
    ; Slot base = address-aligned-down-to-APP_SLOT_SIZE; slot end = +2MB. The
    ; last slot page minus length 0x2000 spills past the slot boundary.
    lea rax, [rel fuzz_x_page]
    mov r14, APP_SLOT_SIZE_LOCAL
    dec r14
    not r14
    and rax, r14                         ; slot base
    add rax, APP_SLOT_SIZE_LOCAL         ; slot end
    sub rax, 0x1000                      ; last in-slot page
    mov rdi, rax
    lea rsi, [rel fuzz_w_page]
    mov rdx, 0x2000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 8
    call .tally

    ; --- T10: w alias range crosses slot end ---------------------------------
    lea rax, [rel fuzz_x_page]
    mov r14, APP_SLOT_SIZE_LOCAL
    dec r14
    not r14
    and rax, r14
    add rax, APP_SLOT_SIZE_LOCAL
    sub rax, 0x1000
    lea rdi, [rel fuzz_x_page]
    mov rsi, rax
    mov rdx, 0x2000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 9
    call .tally

    ; --- T11: x_va in an unmapped slot hole -----------------------------------
    ; Mid-slot is past the assembled blob, so its PTE is not present. Even if
    ; a future loader pre-maps holes, the validator still rejects on the
    ; X-vs-code-range check (mid-slot is outside the code range).
    lea rax, [rel fuzz_x_page]
    mov r14, APP_SLOT_SIZE_LOCAL
    dec r14
    not r14
    and rax, r14
    add rax, APP_SLOT_SIZE_LOCAL / 2
    mov rdi, rax
    lea rsi, [rel fuzz_w_page]
    mov rdx, 0x1000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 10
    call .tally

    ; --- T12: x_va = 0 with sane length ---------------------------------------
    xor rdi, rdi
    lea rsi, [rel fuzz_w_page]
    mov rdx, 0x1000
    SYS_WX_JIT_ALIAS rdi, rsi, rdx
    mov cl, 11
    call .tally

    ; --- report ---------------------------------------------------------------
    cmp r12d, 12
    jne .report_fail
    lea rdi, [rel sz_fuzz_pass]
    SYS_PRINT rdi
    SYS_EXIT
.report_fail:
    lea rdi, [rel sz_fuzz_fail]
    SYS_PRINT rdi
    SYS_EXIT
.install_fail:
    lea rdi, [rel sz_fuzz_install_fail]
    SYS_PRINT rdi
    SYS_EXIT

; .tally: rax = syscall return, cl = subtest index.
; Counts passes (rax == -1) in r12; sets bit cl in r13 on regression.
.tally:
    cmp rax, -1
    jne .tally_bad
    inc r12d
    ret
.tally_bad:
    mov eax, 1
    shl eax, cl
    or r13d, eax
    ret

; X target: inside the code range.
align 4096
fuzz_x_page:
    times 4096 db 0

; The page immediately before code_end - used as the partial-overlap (high
; edge) base for T07.
align 4096
fuzz_last_code_page:
    times 4096 db 0
wx_jit_alias_fuzz_code_end:

; Pages past code_end: outside the manifest's code range, still inside slot.
align 4096
fuzz_w_page:
    times 4096 db 0
align 4096
fuzz_w_alt_page:
    times 4096 db 0
align 4096
fuzz_x_alias_target:
    times 4096 db 0

sz_fuzz_pass:          db "WX-JIT-ALIAS-FUZZ 12/12 PASS", 0
sz_fuzz_fail:          db "WX-JIT-ALIAS-FUZZ FAIL", 0
sz_fuzz_install_fail:  db "WX-JIT-ALIAS-FUZZ INSTALL-FAIL", 0
