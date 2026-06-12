; ============================================================================
; xml_self_test - runs embedded fixtures, prints PASS/FAIL via debug_print.
; No args. Clobbers all caller-save. Safe to call once after display_init.
; ============================================================================
global xml_self_test
extern debug_print
extern serial_putc

; Table entry: qword buf_ptr, qword len, dword expect_ok (1=parse must succeed,
;              0=must fail), dword expect_err (only checked if expect_ok=0)
%macro XT 4
    dq %1
    dq %2 - %1
    dd %3
    dd %4
%endmacro

xml_self_test:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbp, rsp

    xor r12d, r12d        ; pass
    xor r13d, r13d        ; fail
    lea rbx, [rel xt_table]
    mov r14d, XT_COUNT

.next:
    test r14d, r14d
    jz .done
    dec r14d

    call xml_free
    mov rdi, [rbx + 0]    ; buf
    mov rsi, [rbx + 8]    ; len
    call xml_parse        ; rax = 1 ok, 0 fail
    mov ecx, [rbx + 16]   ; expect_ok
    test ecx, ecx
    jz .expect_fail

    ; expect_ok==1: rax must be 1 AND root != -1
    cmp rax, 1
    jne .test_fail
    call xml_root
    cmp rax, 0
    jl .test_fail
    jmp .test_pass

.expect_fail:
    test rax, rax
    jnz .test_fail        ; parse should NOT have succeeded
    call xml_last_error   ; rax=code
    mov edx, [rbx + 20]   ; expect_err
    test edx, edx
    jz .test_pass         ; 0 = don't care, any error fine
    cmp eax, edx
    jne .test_fail
    jmp .test_pass

.test_pass:
    inc r12d
    jmp .advance
.test_fail:
    inc r13d
.advance:
    add rbx, 24
    jmp .next

.done:
    ; Print "[XML] PASS=N FAIL=M\n" - build into xt_msg buffer
    lea rdi, [rel xt_msg]
    mov rax, '[XML] PA'
    mov [rdi], rax
    mov rax, 'SS='
    mov [rdi+8], eax
    add rdi, 11
    mov eax, r12d
    call xt_u32_dec      ; writes ascii at rdi, advances rdi
    mov dword [rdi], ' FA'
    mov word [rdi+3], 'IL'
    mov byte [rdi+5], '='
    add rdi, 6
    mov eax, r13d
    call xt_u32_dec
    mov byte [rdi], 0

    lea rsi, [rel xt_msg]
    call debug_print

    ; Also emit to COM1 for headless test
    lea rsi, [rel xt_msg]
.sloop:
    mov al, [rsi]
    test al, al
    jz .sdone
    call serial_putc
    inc rsi
    jmp .sloop
.sdone:
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc

    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rdi = dst, eax = value. Writes decimal, advances rdi past last digit.
xt_u32_dec:
    push rbx
    push rcx
    push rdx
    mov ecx, 10
    lea rbx, [rel xt_digits + 16]   ; end of scratch
    mov byte [rbx], 0
.div:
    xor edx, edx
    div ecx
    dec rbx
    add dl, '0'
    mov [rbx], dl
    test eax, eax
    jnz .div
.copy:
    mov al, [rbx]
    test al, al
    jz .cdone
    mov [rdi], al
    inc rdi
    inc rbx
    jmp .copy
.cdone:
    pop rdx
    pop rcx
    pop rbx
    ret

section .data
xt_f1:  db '<root><child>hello</child></root>'
xt_f1e:
xt_f2:  db '<?xml version="1.0"?>',10
        db '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">',10
        db '  <rect x="10" y="20" width="80" height="60" fill="#3366cc"/>',10
        db "  <text x='50' y='55'>Hi &amp; bye &lt;3</text>",10
        db '</svg>'
xt_f2e:
xt_f3:  db '<!-- top comment -->',10
        db '<doc>',10
        db '  <!-- inner comment -->',10
        db '  <code><![CDATA[if (a < b && c > d) { x = "&"; }]]></code>',10
        db '  <num>&#65;&#x42;&#67;</num>',10
        db '</doc>'
xt_f3e:
xt_f4:  db '<a><b><c><d>deep</d></c></b><b2/></a>'
xt_f4e:
xt_f5:  db '<svg:path svg:fill="red"><svg:child/></svg:path>'
xt_f5e:
xt_b1:  db '<a>&bogus;</a>'
xt_b1e:
xt_b2:  db '<a/><b/>'
xt_b2e:
xt_b3:  db '<a><b></a>'
xt_b3e:
xt_b4:  db '<a><b>'
xt_b4e:
xt_b5:  db '<a><!-- bad'
xt_b5e:
xt_f6:  db '<!DOCTYPE doc><doc>ok</doc>'
xt_f6e:
xt_f7:  db '<!DOCTYPE doc [<!ENTITY brand "Grit"> <!ELEMENT doc ANY>]>',10
        db '<doc>Made by &brand;</doc>'
xt_f7e:
xt_f8:  db '<doc>a<b/>c<b/>d</doc>'
xt_f8e:
xt_b6:  db '<a>&#zz;</a>'
xt_b6e:
xt_b7:  db '<a>&undefined;</a>'
xt_b7e:

align 8
xt_table:
    XT xt_f1, xt_f1e, 1, 0
    XT xt_f2, xt_f2e, 1, 0
    XT xt_f3, xt_f3e, 1, 0
    XT xt_f4, xt_f4e, 1, 0
    XT xt_f5, xt_f5e, 1, 0
    XT xt_b1, xt_b1e, 0, 8    ; bad entity -> err 8
    XT xt_b2, xt_b2e, 0, 9    ; multi-root -> err 9
    XT xt_b3, xt_b3e, 0, 4    ; mismatched close -> err 4
    XT xt_b4, xt_b4e, 0, 0    ; unclosed tag must fail
    XT xt_b5, xt_b5e, 0, 0    ; unterminated comment must fail
    XT xt_f6, xt_f6e, 1, 0    ; <!DOCTYPE> parse-and-skip
    XT xt_f7, xt_f7e, 1, 0    ; internal DTD <!ENTITY> + custom ref
    XT xt_f8, xt_f8e, 1, 0    ; mixed content (text/element runs)
    XT xt_b6, xt_b6e, 0, 8    ; malformed numeric char ref -> err 8
    XT xt_b7, xt_b7e, 0, 8    ; undefined entity -> err 8
XT_COUNT equ 15

section .bss
xt_msg:    resb 64
xt_digits: resb 24

section .text
