; ============================================================================
; NexusOS v3.0 - Kernel Entry Point (64-bit Long Mode)
; Loaded at 0x100000 by Stage 2
; ============================================================================
bits 64

%include "constants.inc"
%include "structs.inc"
%include "macros.inc"

section .text
global _start
extern kmain

_start:
    ; Serial debug: Kernel entry reached
    mov dx, 0x3F8
    mov al, '('
    out dx, al
    mov al, '!'
    out dx, al
    mov al, '0'
    out dx, al
    mov al, '-'
    out dx, al
    mov al, 'E'
    out dx, al
    mov al, 'N'
    out dx, al
    mov al, 'T'
    out dx, al
    mov al, 'R'
    out dx, al
    mov al, 'Y'
    out dx, al
    mov al, ')'
    out dx, al

    ; Dump CR0, CR3, CR4 at kernel entry
    mov dx, 0x3F8
    mov al, '['
    out dx, al

    ; Print CR3 value (first byte as hex to confirm page tables)
    mov rax, cr3
    mov rbx, rax
    shr al, 4
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jle .cr3h
    add al, 7
.cr3h:
    out dx, al
    mov al, bl
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jle .cr3l
    add al, 7
.cr3l:
    out dx, al
    mov al, ']'
    out dx, al

    ; (!1-SEGS)
    mov al, '('
    out dx, al
    mov al, '!'
    out dx, al
    mov al, '1'
    out dx, al
    mov al, ')'
    out dx, al

    ; Set up segment registers for long mode
    mov ax, 0x10            ; Data segment selector (GDT64_DATA_SEG)
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Set up kernel stack
    mov rsp, KERNEL_STACK_TOP

    ; Enable SSE/SSE2 (required for fast framebuffer operations)
    ; CR0: clear EM (bit 2), set MP (bit 1)
    mov rax, cr0
    and ax, 0xFFFB          ; Clear EM (bit 2) - no x87 emulation
    or ax, 0x0002           ; Set MP (bit 1) - monitor coprocessor
    mov cr0, rax
    ; CR4: set OSFXSR (bit 9) + OSXMMEXCPT (bit 10)
    mov rax, cr4
    or ax, (1 << 9) | (1 << 10)
    mov cr4, rax

    ; (!2-STACK)
    mov dx, 0x3F8
    mov al, '('
    out dx, al
    mov al, '!'
    out dx, al
    mov al, '2'
    out dx, al
    mov al, ')'
    out dx, al

    ; Verify VBE info at 0x9000 before using it
    ; Print FB addr low byte as sanity check
    mov rax, 0x9000
    mov rax, [rax]           ; FB address

    ; (!3-FB)
    mov dx, 0x3F8
    mov al, '('
    out dx, al
    mov al, '!'
    out dx, al
    mov al, '3'
    out dx, al
    mov al, '='
    out dx, al

    ; Print lower 4 hex digits of FB addr
    mov rbx, rax
    mov ecx, 4
.fb_hex:
    rol rbx, 4
    mov al, bl
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jle .fb_hex_ok
    add al, 7
.fb_hex_ok:
    out dx, al
    dec ecx
    jnz .fb_hex
    mov al, ')'
    out dx, al

    ; Reload rdi from VBE info
    mov rax, 0x9000
    mov rdi, [rax]           ; Get LFB address

    ; (!4-PAINT)
    mov al, '('
    out dx, al
    mov al, '!'
    out dx, al
    mov al, '4'
    out dx, al
    mov al, ')'
    out dx, al

    ; Paint WHITE as proof of Kernel Entry
    mov rcx, SCREEN_WIDTH * SCREEN_HEIGHT  ; 1024*768 pixels

    mov eax, 0x00FFFFFF      ; WHITE
    rep stosd

    ; (!5-PAINTED)
    mov dx, 0x3F8
    mov al, '('
    out dx, al
    mov al, '!'
    out dx, al
    mov al, '5'
    out dx, al
    mov al, ')'
    out dx, al

    ; (!6-KMAIN)
    mov al, '('
    out dx, al
    mov al, '!'
    out dx, al
    mov al, '6'
    out dx, al
    mov al, ')'
    out dx, al

    ; Call kernel main
    call kmain

    ; If kmain returns, halt forever
.halt:
    cli
    hlt
    jmp .halt
