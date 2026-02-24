; ============================================================================
; NexusOS v3.0 - Math Utility Functions
; ============================================================================
bits 64

section .text

; --- clamp: Clamp value to range ---
; EDI = value, ESI = min, EDX = max
; Returns: EAX = clamped value
global fn_clamp
fn_clamp:
    mov eax, edi
    cmp eax, esi
    cmovl eax, esi           ; If value < min, use min
    cmp eax, edx
    cmovg eax, edx           ; If value > max, use max
    ret

; --- min: Integer minimum ---
; EDI = a, ESI = b
; Returns: EAX = min(a, b)
global fn_min
fn_min:
    mov eax, edi
    cmp eax, esi
    cmovg eax, esi
    ret

; --- max: Integer maximum ---
; EDI = a, ESI = b
; Returns: EAX = max(a, b)
global fn_max
fn_max:
    mov eax, edi
    cmp eax, esi
    cmovl eax, esi
    ret

; --- abs: Absolute value ---
; EDI = value
; Returns: EAX = |value|
global fn_abs
fn_abs:
    mov eax, edi
    cdq
    xor eax, edx
    sub eax, edx
    ret

; --- rect_intersect: Test if two rectangles overlap ---
; RDI = rect1 pointer, RSI = rect2 pointer
; Returns: EAX = 1 if overlapping, 0 if not
global fn_rect_intersect
fn_rect_intersect:
    ; rect1.x + rect1.w <= rect2.x?
    mov eax, [rdi]           ; rect1.x
    add eax, [rdi + 8]      ; + rect1.w
    cmp eax, [rsi]           ; vs rect2.x
    jle .no_intersect

    ; rect2.x + rect2.w <= rect1.x?
    mov eax, [rsi]
    add eax, [rsi + 8]
    cmp eax, [rdi]
    jle .no_intersect

    ; rect1.y + rect1.h <= rect2.y?
    mov eax, [rdi + 4]
    add eax, [rdi + 12]
    cmp eax, [rsi + 4]
    jle .no_intersect

    ; rect2.y + rect2.h <= rect1.y?
    mov eax, [rsi + 4]
    add eax, [rsi + 12]
    cmp eax, [rdi + 4]
    jle .no_intersect

    mov eax, 1
    ret

.no_intersect:
    xor eax, eax
    ret
