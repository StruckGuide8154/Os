; ============================================================================
; NexusOS v3.0 - String and Memory Utility Functions
; ============================================================================
bits 64

section .text

; --- strlen: Get string length ---
; RDI = pointer to null-terminated string
; Returns: RAX = length
global fn_strlen
fn_strlen:
    push rcx
    push rdi
    xor rcx, rcx
    dec rcx                  ; RCX = -1 (max count)
    xor al, al              ; Searching for null
    repne scasb
    not rcx
    dec rcx                  ; RCX = length
    mov rax, rcx
    pop rdi
    pop rcx
    ret

; --- strcmp: Compare two strings ---
; RDI = string1, RSI = string2
; Returns: RAX = 0 if equal, <0 if s1<s2, >0 if s1>s2
global fn_strcmp
fn_strcmp:
    push rbx
.cmp_loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .cmp_diff
    test al, al
    jz .cmp_equal
    inc rdi
    inc rsi
    jmp .cmp_loop
.cmp_diff:
    movzx eax, al
    movzx ebx, bl
    sub eax, ebx
    pop rbx
    ret
.cmp_equal:
    xor eax, eax
    pop rbx
    ret

; --- strcpy: Copy string ---
; RDI = dest, RSI = src
; Returns: RAX = dest
global fn_strcpy
fn_strcpy:
    push rdi
    push rsi
.copy_loop:
    lodsb
    stosb
    test al, al
    jnz .copy_loop
    pop rsi
    mov rax, [rsp]
    pop rdi
    mov rax, rdi
    ret

; --- memcpy: Copy bytes ---
; RDI = dest, RSI = src, RDX = count
; Returns: RAX = dest
global fn_memcpy
fn_memcpy:
    push rdi
    push rcx
    mov rcx, rdx
    ; Copy qwords first
    shr rcx, 3
    rep movsq
    ; Copy remaining bytes
    mov rcx, rdx
    and rcx, 7
    rep movsb
    pop rcx
    pop rdi
    mov rax, rdi
    ret

; --- memset: Fill memory ---
; RDI = dest, ESI = byte value, RDX = count
; Returns: RAX = dest
global fn_memset
fn_memset:
    push rdi
    push rcx
    mov rax, rsi
    mov rcx, rdx
    ; Fill qwords
    mov ah, al
    movzx eax, ax
    imul eax, 0x01010101     ; Replicate byte across dword
    mov r8, rax
    shl rax, 32
    or rax, r8               ; Replicate across qword
    push rcx
    shr rcx, 3
    rep stosq
    pop rcx
    and rcx, 7
    mov al, sil
    rep stosb
    pop rcx
    pop rdi
    mov rax, rdi
    ret

; --- memsetd: Fill memory with dwords ---
; RDI = dest, ESI = dword value, RDX = count (number of dwords)
global fn_memsetd
fn_memsetd:
    push rdi
    push rcx
    push rax
    mov eax, esi
    mov rcx, rdx
    rep stosd
    pop rax
    pop rcx
    pop rdi
    ret

; --- itoa: Convert integer to ASCII string ---
; RDI = value (unsigned 64-bit), RSI = buffer, EDX = radix (10 or 16)
; Returns: RAX = pointer to buffer
global fn_itoa
fn_itoa:
    push rbx
    push rcx
    push rdi
    push rsi
    push r8

    mov rax, rdi             ; Value
    mov r8, rsi              ; Buffer start
    mov rbx, rsi             ; Working pointer
    mov ecx, edx             ; Radix

    ; Special case: 0
    test rax, rax
    jnz .itoa_loop
    mov byte [rbx], '0'
    inc rbx
    jmp .itoa_terminate

.itoa_loop:
    test rax, rax
    jz .itoa_reverse
    xor edx, edx
    div rcx                  ; RAX = quotient, RDX = remainder
    cmp dl, 10
    jl .digit
    add dl, 'A' - 10
    jmp .store
.digit:
    add dl, '0'
.store:
    mov [rbx], dl
    inc rbx
    jmp .itoa_loop

.itoa_reverse:
    ; Null-terminate
    mov byte [rbx], 0
    dec rbx                  ; Point to last digit

    ; Reverse the string
    mov rdi, r8              ; Start
.rev_loop:
    cmp rdi, rbx
    jge .itoa_done
    mov al, [rdi]
    mov cl, [rbx]
    mov [rdi], cl
    mov [rbx], al
    inc rdi
    dec rbx
    jmp .rev_loop

.itoa_terminate:
    mov byte [rbx], 0

.itoa_done:
    mov rax, r8              ; Return buffer pointer

    pop r8
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; --- itoa_dec2: Format a number as 2-digit decimal with leading zero ---
; EDI = value (0-99), RSI = buffer (at least 3 bytes)
global fn_itoa_dec2
fn_itoa_dec2:
    push rax
    push rdx

    mov eax, edi
    xor edx, edx
    mov ecx, 10
    div ecx                  ; EAX = tens, EDX = ones

    add al, '0'
    mov [rsi], al
    add dl, '0'
    mov [rsi + 1], dl
    mov byte [rsi + 2], 0

    pop rdx
    pop rax
    ret

; --- uint32_to_str: Wrapper for fn_itoa (decimal) ---
global uint32_to_str
uint32_to_str:
    mov edx, 10
    jmp fn_itoa
