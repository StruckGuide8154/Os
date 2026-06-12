bits 64

%include "grit_app.inc"

global hello_draw
global hello_click
global hello_key

hello_draw:
    lea rax, [rel .title]
    SYS_GUI_TEXT 24, 24, rax, 0x00FFFFFF, 0
    ret

hello_click:
    lea rdi, [rel .clicked]
    SYS_PRINT rdi
    ret

hello_key:
    cmp rsi, 27
    jne .done
    lea rdi, [rel .bye]
    SYS_PRINT rdi
.done:
    ret

section .rodata
.title:   db "Hello from a Grit ring-3 callback", 0
.clicked: db "hello_callback: click", 0
.bye:     db "hello_callback: escape pressed", 0
