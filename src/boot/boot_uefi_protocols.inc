; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI GOP and pointer protocol discovery
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

; GOP INIT - Locate Graphics Output Protocol
; ============================================================================
fn_gop_init:
    sub rsp, 56
    ; LocateProtocol(&GOP_GUID, NULL, &gop_ptr)
    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCATE]
    lea rcx, [gop_guid]
    xor edx, edx           ; Registration = NULL
    lea r8, [v_gop]         ; Interface output
    sub rsp, 32
    call rax
    add rsp, 32
    test rax, rax
    jnz .gop_fail

    ; Get mode info
    mov rcx, [v_gop]
    mov rax, [rcx + GOP_MODE]
    mov [v_gopmode], rax
    mov rcx, [rax + GOPM_INFO]
    mov edx, [rcx + GOPI_HRES]
    mov [v_scrw], edx
    mov edx, [rcx + GOPI_VRES]
    mov [v_scrh], edx
    mov edx, [rcx + GOPI_PPSL]
    mov [v_pitch], edx
    mov rax, [v_gopmode]
    mov rax, [rax + GOPM_FBBASE]
    mov [v_fb], rax

    xor eax, eax    ; success
    add rsp, 56
    ret
.gop_fail:
    mov eax, 1
    add rsp, 56
    ret

; GOP GUID: 9042a9de-23dc-4a38-96fb-7aded080516a
gop_guid:
    dd 0x9042a9de
    dw 0x23dc, 0x4a38
    db 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a

; ============================================================================
; MOUSE INIT - Locate Simple Pointer or Absolute Pointer Protocol
; ============================================================================
; Simple Pointer Protocol GUID: 31878c87-0b75-11d5-9a4f-0090273fc14d
spp_guid:
    dd 0x31878c87
    dw 0x0b75, 0x11d5
    db 0x9a, 0x4f, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d

; Absolute Pointer Protocol GUID: 8D59D32B-C655-4AE9-9B15-F25904992A43
app_guid:
    dd 0x8D59D32B
    dw 0xC655, 0x4AE9
    db 0x9B, 0x15, 0xF2, 0x59, 0x04, 0x99, 0x2A, 0x43

; Protocol offsets (same for both)
%define SPP_RESET   0
%define SPP_GETST   8
%define SPP_WAIT    16
%define SPP_MODE    24

fn_mouse_init:
    sub rsp, 56

    ; Try Simple Pointer Protocol first
    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCATE]
    lea rcx, [spp_guid]
    xor edx, edx
    lea r8, [v_mouse]
    sub rsp, 32
    call rax
    add rsp, 32
    test rax, rax
    jnz .try_abs_pointer

    ; Simple Pointer found
    mov byte [v_mtype], 0    ; 0 = relative (simple pointer)
    jmp .mouse_reset

.try_abs_pointer:
    ; Try Absolute Pointer Protocol (touchpads, touch screens)
    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCATE]
    lea rcx, [app_guid]
    xor edx, edx
    lea r8, [v_mouse]
    sub rsp, 32
    call rax
    add rsp, 32
    test rax, rax
    jnz .mouse_fail

    ; Absolute Pointer found
    mov byte [v_mtype], 1    ; 1 = absolute pointer

.mouse_reset:
    ; Reset mouse
    mov rcx, [v_mouse]
    mov rax, [rcx + SPP_RESET]
    xor edx, edx           ; ExtendedVerification = FALSE
    sub rsp, 32
    call rax
    add rsp, 32

    ; Init cursor position to center of screen
    mov eax, [v_scrw]
    shr eax, 1
    mov [v_mx], eax
    mov eax, [v_scrh]
    shr eax, 1
    mov [v_my], eax
    mov byte [v_mvis], 0     ; cursor not currently visible

    xor eax, eax
    add rsp, 56
    ret
.mouse_fail:
    mov qword [v_mouse], 0
    mov eax, 1
    add rsp, 56
    ret

; ============================================================================
; MOUSE CURSOR - Draw/Hide 12x16 arrow cursor using GOP Blt
; ============================================================================
