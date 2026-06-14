; ============================================================================
; Grit v3.0 - Kernel log ring buffer + F12 overlay viewer
; ----------------------------------------------------------------------------
; debug_print appends each line into a fixed-size ring; F12 toggles a
; full-screen overlay showing the last N lines. Up/Down arrows scroll while
; the overlay is open. The ring also serves as the source buffer that the
; (future) USB MSC writer will flush to disk.
; ============================================================================
bits 64

KLOG_LINES      equ 256                ; power of 2
KLOG_LINE_LEN   equ 128                ; bytes per slot (incl null)
KLOG_VIEW_LINES equ 40                 ; lines visible on screen
KLOG_LINE_MASK  equ (KLOG_LINES - 1)

; --- Cross-boot flush region ---------------------------------------------
; The kernel writes the serialized ring (plain ASCII, \r\n between lines)
; here, then triggers a warm reboot. The UEFI loader on the next boot
; checks the magic and copies the payload to \KLOG.TXT on the ESP via
; SIMPLE_FILE_SYSTEM_PROTOCOL, then clears the magic. RAM persists across
; a warm reboot (port 0x64 cmd 0xFE) on every PC since the 90s.
KLOG_FLUSH_ADDR equ 0x600000           ; well above kernel/stack/IDT
KLOG_MAGIC_LO   equ 0x474F4C4B         ; "KLOG"
KLOG_MAGIC_HI   equ 0x3130534E         ; "NS01"
; Header layout at KLOG_FLUSH_ADDR:
;   +0  qword magic (KLOG_MAGIC_LO | KLOG_MAGIC_HI<<32)
;   +8  qword payload length (bytes following, not counting header)
;   +16 payload (ASCII text)
KLOG_FLUSH_MAX  equ (KLOG_LINES * KLOG_LINE_LEN + 4096)  ; ample slack

extern bb_addr
extern fill_rect
extern render_text
extern scr_width
extern scr_height
extern driver_debug_render

section .data
global klog_visible
klog_visible    db 0
klog_view_off   dd 0                   ; lines back from newest (0 = bottom)

section .bss
alignb 16
global klog_buf
klog_buf:       resb KLOG_LINES * KLOG_LINE_LEN
global klog_count
klog_count:     resq 1                 ; total lines ever written (saturates fine)

section .text

; --- klog_write ---
; RSI = null-terminated string. Appends to ring buffer. Clobbers nothing
; (all caller-saved regs preserved so it is safe to call from debug_print).
global klog_write
klog_write:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9

    test rsi, rsi
    jz .kw_done

    mov rax, [klog_count]
    mov rcx, rax
    and rcx, KLOG_LINE_MASK            ; slot index
    mov rdx, KLOG_LINE_LEN
    imul rcx, rdx                      ; byte offset
    lea rdi, [rel klog_buf]
    add rdi, rcx                       ; dest

    mov r8d, KLOG_LINE_LEN - 1         ; max chars to copy
.kw_copy:
    test r8d, r8d
    jz .kw_term
    mov al, [rsi]
    test al, al
    jz .kw_term
    mov [rdi], al
    inc rsi
    inc rdi
    dec r8d
    jmp .kw_copy
.kw_term:
    mov byte [rdi], 0
    inc qword [klog_count]

    ; Auto-scroll to bottom when a new line arrives so the user always sees
    ; the latest output. They can still scroll up after.
    mov dword [rel klog_view_off], 0
.kw_done:
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; --- klog_toggle ---
global klog_toggle
klog_toggle:
    mov al, [rel klog_visible]
    xor al, 1
    mov [rel klog_visible], al
    mov dword [rel klog_view_off], 0
    ret

; --- klog_scroll ---
; EDI = signed delta in lines (positive = older, negative = newer).
global klog_scroll
klog_scroll:
    push rax
    push rcx
    mov eax, [rel klog_view_off]
    add eax, edi
    test eax, eax
    jns .ks_clamp_hi
    xor eax, eax                       ; clamp at 0 (bottom)
    jmp .ks_store
.ks_clamp_hi:
    ; max scroll = (count - VIEW_LINES) but never < 0
    mov rcx, [rel klog_count]
    sub rcx, KLOG_VIEW_LINES
    jns .ks_cap
    xor ecx, ecx
.ks_cap:
    cmp eax, ecx
    jbe .ks_store
    mov eax, ecx
.ks_store:
    mov [rel klog_view_off], eax
    pop rcx
    pop rax
    ret

; --- klog_render_overlay ---
; If visible, draw last KLOG_VIEW_LINES lines (minus klog_view_off) over the
; current backbuffer. Caller is responsible for the display_flip; we render
; into the backbuffer just like the rest of the GUI.
global klog_render_overlay
klog_render_overlay:
%ifdef RELEASE_BUILD
    ret
%else
    cmp byte [rel klog_visible], 0
    je .kr_done

    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    ; Full-screen dark backdrop
    xor edi, edi
    xor esi, esi
    mov edx, [scr_width]
    mov ecx, [scr_height]
    mov r8d, 0x00101820
    call fill_rect

    ; Compute first line index to display.
    ; newest = klog_count - 1 - klog_view_off
    ; first  = newest - (KLOG_VIEW_LINES - 1)
    mov rax, [rel klog_count]
    test rax, rax
    jz .kr_no_lines
    dec rax
    mov ecx, [rel klog_view_off]
    sub rax, rcx
    js .kr_no_lines
    mov r10, rax                       ; newest visible
    sub rax, KLOG_VIEW_LINES - 1
    jns .kr_have_first
    xor eax, eax
.kr_have_first:
    mov r11, rax                       ; first visible

    ; Render header
    mov edi, 8
    mov esi, 4
    lea rdx, [rel klog_hdr]
    mov ecx, 0x00FFFF80
    mov r8d, 0x00101820
    call render_text

    ; Driver diagnostics are rendered by a separate manager so new hardware
    ; debug providers do not have to modify the klog viewer.
    mov edi, 24
    call driver_debug_render

    ; Loop r11..r10
    mov r12, r11
    mov r13d, eax                      ; y cursor below driver diagnostics
.kr_loop:
    cmp r12, r10
    ja .kr_done_loop

    ; offset = (r12 & MASK) * LINE_LEN
    mov rax, r12
    and rax, KLOG_LINE_MASK
    mov rcx, KLOG_LINE_LEN
    imul rax, rcx
    lea rdx, [rel klog_buf]
    add rdx, rax                       ; string ptr

    mov edi, 8                         ; x
    mov esi, r13d                      ; y
    mov ecx, 0x0000FF80                ; text color
    mov r8d, 0x00101820                ; bg
    call render_text

    add r13d, 16
    inc r12
    jmp .kr_loop
.kr_done_loop:
    ; Footer with position info
    mov edi, 8
    mov eax, [scr_height]
    sub eax, 18
    mov esi, eax
    lea rdx, [rel klog_ftr]
    mov ecx, 0x0080C0FF
    mov r8d, 0x00101820
    call render_text

.kr_no_lines:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.kr_done:
    ret
%endif

; ============================================================================
; klog_flush_and_reboot
; ----------------------------------------------------------------------------
; Serializes the entire ring (oldest line first) as CRLF-separated ASCII
; into the cross-boot flush region with a magic header, then issues a warm
; reboot via the 8042 keyboard controller. The UEFI bootloader on the next
; boot detects the magic and writes the payload to \KLOG.TXT.
; ============================================================================
global klog_flush_and_reboot
klog_flush_and_reboot:
%ifdef RELEASE_BUILD
    ret
%else
    cli

    ; Write magic + reserve length slot
    mov rdi, KLOG_FLUSH_ADDR
    mov eax, KLOG_MAGIC_LO
    mov [rdi], eax
    mov eax, KLOG_MAGIC_HI
    mov [rdi + 4], eax
    mov qword [rdi + 8], 0             ; length placeholder

    add rdi, 16                        ; payload cursor
    mov r12, rdi                       ; payload start

    ; Determine oldest line index. If klog_count <= KLOG_LINES, oldest = 0;
    ; otherwise oldest = klog_count - KLOG_LINES.
    mov rax, [rel klog_count]
    test rax, rax
    jz .kf_finalize
    cmp rax, KLOG_LINES
    jbe .kf_oldest_zero
    mov rbx, rax
    sub rbx, KLOG_LINES
    jmp .kf_have_oldest
.kf_oldest_zero:
    xor ebx, ebx
.kf_have_oldest:
    mov rcx, [rel klog_count]          ; one-past-newest
    mov rdx, KLOG_FLUSH_ADDR + KLOG_FLUSH_MAX - 4  ; payload hard cap

.kf_line_loop:
    cmp rbx, rcx
    jae .kf_finalize
    cmp rdi, rdx
    jae .kf_finalize

    ; Source line pointer = klog_buf + (rbx & MASK) * KLOG_LINE_LEN
    mov rax, rbx
    and rax, KLOG_LINE_MASK
    mov r8, KLOG_LINE_LEN
    imul rax, r8
    lea rsi, [rel klog_buf]
    add rsi, rax

    mov r9d, KLOG_LINE_LEN
.kf_char:
    test r9d, r9d
    jz .kf_eol
    mov al, [rsi]
    test al, al
    jz .kf_eol
    mov [rdi], al
    inc rsi
    inc rdi
    dec r9d
    cmp rdi, rdx
    jae .kf_finalize
    jmp .kf_char
.kf_eol:
    mov byte [rdi], 0x0D
    inc rdi
    mov byte [rdi], 0x0A
    inc rdi
    inc rbx
    jmp .kf_line_loop

.kf_finalize:
    ; Write final length back into header
    mov rax, rdi
    sub rax, r12
    mov [abs KLOG_FLUSH_ADDR + 8], rax

    ; --- Warm reboot via 8042 ---
    ; Drain keyboard controller, then issue cmd 0xFE (CPU reset).
.kf_wait:
    in al, 0x64
    test al, 0x02
    jnz .kf_wait
    mov al, 0xFE
    out 0x64, al

    ; If the 8042 doesn't reset (some modern systems), fall through to
    ; triple-fault as a last resort.
.kf_hang:
    lidt [rel klog_bad_idt]
    int 3
    hlt
    jmp .kf_hang
%endif

section .data
%ifndef RELEASE_BUILD
klog_hdr: db "[ Grit klog -- F12 close  Up/Down scroll  F11 flush+reboot ]", 0
klog_ftr: db "klog overlay -- live ring buffer", 0
align 8
klog_bad_idt:
    dw 0
    dq 0
%endif
