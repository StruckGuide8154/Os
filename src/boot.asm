; ============================================================================
; NexusOS v2.0 - UEFI Graphical Operating System
; 100% x86-64 Assembly. No C. No Rust. No libraries.
; Features: GOP framebuffer, 8x8 bitmap font, graphical desktop + text shell
; ============================================================================
bits 64
default rel

%define HEADER_SIZE   0x200
%define TEXT_RAWSIZE  0x10000
%define TEXT_VADDR    0x1000
%define TEXT_VSIZE    0x10000
%define RELOC_FOFF    (HEADER_SIZE + TEXT_RAWSIZE)
%define RELOC_FSIZE   0x200
%define RELOC_VADDR   0x11000
%define RELOC_VSIZE   0x0C
%define IMAGE_SIZE    0x12000

; Colors (text mode)
%define LCYAN   0x0B
%define YELLOW  0x0E
%define WHITE   0x0F
%define LGRAY   0x07
%define LGREEN  0x0A
%define LRED    0x0C
%define LMAG    0x0D

; UEFI offsets
%define ST_CONIN    48
%define ST_CONOUT   64
%define ST_RUNTIME  88
%define ST_BOOTSERV 96
%define ST_FW_VEND  24
%define CO_STR  8
%define CO_ATTR 40
%define CO_CLR  48
%define CI_KEY  8
%define BS_WAITEVT  232
%define BS_STALL    248
%define BS_WATCHDOG 256
%define BS_CHKEVT   264
%define BS_LOCATE   320
%define RS_TIME     24
%define RS_RESET    104

; GOP offsets
%define GOP_QUERY   0
%define GOP_SET     8
%define GOP_BLT     16
%define GOP_MODE    24
; GOP Mode
%define GOPM_MAX    0
%define GOPM_CUR    4
%define GOPM_INFO   8
%define GOPM_FBBASE 24
%define GOPM_FBSIZE 32
; GOP Mode Info
%define GOPI_HRES   4
%define GOPI_VRES   8
%define GOPI_PFMT   12
%define GOPI_PPSL   28

; UCS-2 macro
%macro u 1+
  %assign %%i 1
  %strlen %%len %1
  %rep %%len
    %substr %%c %1 %%i
    dw %%c
    %assign %%i %%i+1
  %endrep
  dw 0
%endmacro

; ============================================================================
; PE/COFF HEADER
; ============================================================================
section .text start=0
    dw 0x5A4D
    times 29 dw 0
    dd pe_hdr
pe_hdr:
    dd 0x00004550
    dw 0x8664, 2
    dd 0, 0, 0
    dw opt_end - opt_hdr
    dw 0x0206
opt_hdr:
    dw 0x020B
    db 1, 0
    dd TEXT_RAWSIZE, 0, 0, TEXT_VADDR, TEXT_VADDR
    dq 0x100000
    dd 0x1000, 0x200
    dw 0,0, 0,0, 0,0
    dd 0, IMAGE_SIZE, HEADER_SIZE, 0
    dw 10, 0
    dq 0x100000, 0x100000, 0x100000, 0x100000
    dd 0, 6
    dd 0,0, 0,0, 0,0, 0,0, 0,0
    dd RELOC_VADDR, RELOC_VSIZE
opt_end:
    db '.text',0,0,0
    dd TEXT_VSIZE, TEXT_VADDR, TEXT_RAWSIZE, HEADER_SIZE
    dd 0,0
    dw 0,0
    dd 0xE0000060
    db '.reloc',0,0
    dd RELOC_VSIZE, RELOC_VADDR, RELOC_FSIZE, RELOC_FOFF
    dd 0,0
    dw 0,0
    dd 0x42000040
    times (HEADER_SIZE - ($ - $$)) db 0

; ============================================================================
; ENTRY
; ============================================================================
_start:
    sub rsp, 128
    mov [v_handle], rcx
    mov [v_systab], rdx
    mov rax, [rdx + ST_CONOUT]
    mov [v_conout], rax
    mov rax, [rdx + ST_CONIN]
    mov [v_conin], rax
    mov rax, [rdx + ST_BOOTSERV]
    mov [v_bs], rax
    mov rax, [rdx + ST_RUNTIME]
    mov [v_rs], rax
    mov rax, [rdx + ST_FW_VEND]
    mov [v_fwv], rax

    ; Disable watchdog
    mov rcx, [v_bs]
    mov rax, [rcx + BS_WATCHDOG]
    xor ecx,ecx
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    sub rsp, 32
    call rax
    add rsp, 32

    ; Try to init GOP
    call fn_gop_init
    test eax, eax
    jnz .text_mode

    ; Try to init mouse
    call fn_mouse_init
    mov [v_mfound], al        ; save result (0=found, 1=not found)

    ; GOP available - show desktop with mouse cursor
    call fn_desktop

    ; Debug: draw mouse status indicator on title bar
    mov edi, 140
    mov esi, 12
    cmp byte [v_mfound], 0
    jne .mouse_nf
    ; Mouse found - show green "Mouse:OK"
    lea rdx, [a_mok]
    mov ecx, 0x0060E880
    mov r8d, 0x00201008
    call fn_draw_str
    jmp .mouse_dbg_done
.mouse_nf:
    ; No mouse - show red "Mouse:--"
    lea rdx, [a_mno]
    mov ecx, 0x004040FF
    mov r8d, 0x00201008
    call fn_draw_str
.mouse_dbg_done:
    call fn_cursor_show

.boot_gfx_wait:
    ; Poll keyboard
    mov rcx, [v_conin]
    mov rax, [rcx + CI_KEY]
    lea rdx, [kd]
    call rax
    test rax, rax
    jnz .boot_no_key
    ; Got a key - check if it's a mouse key (arrows, *, -)
    call fn_kb_mouse
    test eax, eax
    jnz .boot_kb_moved     ; arrow/click handled
    ; Not a mouse key -> go to shell
    jmp .to_shell
.boot_kb_moved:
    cmp eax, 2             ; left click?
    je .boot_click
    call fn_cursor_hide
    call fn_cursor_show
    jmp .boot_gfx_wait
.boot_click:
    call fn_handle_click
    cmp eax, 1             ; close button
    je .to_shell
    cmp eax, 3             ; start button -> shell
    je .to_shell
    ; minimize or nothing - just continue
    jmp .boot_gfx_wait
.boot_no_key:
    ; Poll hardware mouse
    call fn_mouse_poll
    cmp eax, 0
    je .boot_gfx_stall     ; no mouse event
    cmp eax, 2
    je .boot_hw_click
    ; Mouse moved - redraw cursor
    call fn_cursor_hide
    call fn_cursor_show
    jmp .boot_gfx_wait
.boot_hw_click:
    call fn_handle_click
    cmp eax, 1
    je .to_shell
    cmp eax, 3
    je .to_shell
    call fn_cursor_hide
    call fn_cursor_show
    jmp .boot_gfx_wait

.boot_gfx_stall:
    mov rcx, 2000           ; 2ms poll interval
    call fn_stall
    jmp .boot_gfx_wait
.to_shell:
    ; Clear text layer and enter shell
    call fn_cls
    jmp .shell

.text_mode:
    call fn_cls
    mov dl, LCYAN
    call fn_tcolor
    lea rcx, [s_notxt]
    call fn_tpr

.shell:
    call fn_shell
.halt:
    hlt
    jmp .halt

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

; fn_cursor_show - draw cursor at (v_mx, v_my), saving background first
fn_cursor_show:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96

    cmp qword [v_gop], 0
    je .cs_done

    ; Save background under cursor: GOP->Blt(VideoToBltBuffer)
    mov rcx, [v_gop]
    lea rdx, [cursor_save]
    mov r8d, 1               ; EfiBltVideoToBltBuffer
    mov eax, [v_mx]
    mov r9d, eax             ; SourceX = mx
    mov eax, [v_my]
    mov [rsp+32], rax        ; SourceY = my
    mov qword [rsp+40], 0   ; DestX = 0
    mov qword [rsp+48], 0   ; DestY = 0
    mov qword [rsp+56], 16  ; Width
    mov qword [rsp+64], 20  ; Height
    mov qword [rsp+72], 64  ; Delta = 16 * 4
    mov rax, [rcx + GOP_BLT]
    call rax

    ; Build cursor pixels: outline=black, fill=white, else=background
    lea r12, [cursor_bmp]     ; outline bitmap
    lea r13, [cursor_fill]    ; fill bitmap
    lea r14, [cursor_save]    ; saved bg
    lea r15, [cursor_buf]     ; output
    mov ecx, 20               ; 20 rows
.cs_row:
    movzx eax, word [r12]     ; outline row
    movzx ebx, word [r13]     ; fill row
    mov edx, 16               ; 16 columns
.cs_col:
    test bx, 0x8000
    jz .cs_not_fill
    ; Fill pixel = white
    mov dword [r15], 0x00FFFFFF
    jmp .cs_next
.cs_not_fill:
    test ax, 0x8000
    jz .cs_trans
    ; Outline pixel = black
    mov dword [r15], 0x00000000
    jmp .cs_next
.cs_trans:
    ; Transparent = copy from saved background
    mov edi, [r14]
    mov [r15], edi
.cs_next:
    shl ax, 1
    shl bx, 1
    add r14, 4
    add r15, 4
    dec edx
    jnz .cs_col
    add r12, 2                ; next outline row
    add r13, 2                ; next fill row
    dec ecx
    jnz .cs_row

    ; Blt cursor buffer to screen
    mov rcx, [v_gop]
    lea rdx, [cursor_buf]
    mov r8d, 2               ; EfiBltBufferToVideo
    xor r9d, r9d             ; SourceX = 0
    mov qword [rsp+32], 0   ; SourceY = 0
    mov eax, [v_mx]
    mov [rsp+40], rax        ; DestX = mx
    mov eax, [v_my]
    mov [rsp+48], rax        ; DestY = my
    mov qword [rsp+56], 16  ; Width
    mov qword [rsp+64], 20  ; Height
    mov qword [rsp+72], 64  ; Delta = 16 * 4
    mov rax, [rcx + GOP_BLT]
    call rax

    ; Save drawn position
    mov eax, [v_mx]
    mov [v_mx_drn], eax
    mov eax, [v_my]
    mov [v_my_drn], eax
    mov byte [v_mvis], 1
.cs_done:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fn_cursor_hide - restore background under cursor at DRAWN position
fn_cursor_hide:
    push rbx
    sub rsp, 96

    cmp byte [v_mvis], 0
    je .ch_done
    cmp qword [v_gop], 0
    je .ch_done

    ; Blt saved background back to where cursor was drawn
    mov rcx, [v_gop]
    lea rdx, [cursor_save]
    mov r8d, 2               ; EfiBltBufferToVideo
    xor r9d, r9d             ; SourceX = 0
    mov qword [rsp+32], 0   ; SourceY = 0
    mov eax, [v_mx_drn]
    mov [rsp+40], rax        ; DestX = drawn X
    mov eax, [v_my_drn]
    mov [rsp+48], rax        ; DestY = drawn Y
    mov qword [rsp+56], 16  ; Width
    mov qword [rsp+64], 20  ; Height
    mov qword [rsp+72], 64  ; Delta = 16 * 4
    mov rax, [rcx + GOP_BLT]
    call rax

    mov byte [v_mvis], 0
.ch_done:
    add rsp, 96
    pop rbx
    ret

; fn_kb_mouse - handle arrow keys as cursor, * as left click, - as right click
; Reads from kd[] (already filled by ReadKeyStroke)
; Returns: eax=0 not mouse key, 1=moved, 2=left click, 3=right click
fn_kb_mouse:
    push rbx
    sub rsp, 32

    ; Check scan code for arrow keys
    movzx eax, word [kd]       ; scan code
    movzx ebx, word [kd+2]    ; unicode char

    %define MOVE_STEP 6

    cmp ax, 0x03               ; Right arrow
    je .km_right
    cmp ax, 0x04               ; Left arrow
    je .km_left
    cmp ax, 0x01               ; Up arrow
    je .km_up
    cmp ax, 0x02               ; Down arrow
    je .km_down

    ; Check unicode char for * and -
    cmp bx, '*'
    je .km_lclick
    cmp bx, '-'
    je .km_rclick

    ; Not a mouse key
    xor eax, eax
    jmp .km_ret

.km_right:
    mov eax, [v_mx]
    add eax, MOVE_STEP
    mov ecx, [v_scrw]
    sub ecx, 16
    cmp eax, ecx
    jle .km_set_x
    mov eax, ecx
.km_set_x:
    mov [v_mx], eax
    mov eax, 1
    jmp .km_ret

.km_left:
    mov eax, [v_mx]
    sub eax, MOVE_STEP
    test eax, eax
    jns .km_set_xl
    xor eax, eax
.km_set_xl:
    mov [v_mx], eax
    mov eax, 1
    jmp .km_ret

.km_up:
    mov eax, [v_my]
    sub eax, MOVE_STEP
    test eax, eax
    jns .km_set_yu
    xor eax, eax
.km_set_yu:
    mov [v_my], eax
    mov eax, 1
    jmp .km_ret

.km_down:
    mov eax, [v_my]
    add eax, MOVE_STEP
    mov ecx, [v_scrh]
    sub ecx, 20
    cmp eax, ecx
    jle .km_set_yd
    mov eax, ecx
.km_set_yd:
    mov [v_my], eax
    mov eax, 1
    jmp .km_ret

.km_lclick:
    mov eax, 2
    jmp .km_ret

.km_rclick:
    mov eax, 3

.km_ret:
    add rsp, 32
    pop rbx
    ret

; fn_handle_click - check cursor position against UI elements
; Returns: eax = 0 nothing, 1 = close button, 2 = minimize, 3 = start button
fn_handle_click:
    sub rsp, 40
    mov eax, [v_mx]
    mov ecx, [v_my]

    ; Close button: x=[scrw-64, scrw-46], y=[52, 70]
    mov edx, [v_scrw]
    sub edx, 64
    cmp eax, edx
    jl .hc_not_close
    add edx, 18
    cmp eax, edx
    jg .hc_not_close
    cmp ecx, 52
    jl .hc_not_close
    cmp ecx, 70
    jg .hc_not_close
    mov eax, 1
    jmp .hc_ret
.hc_not_close:
    ; Minimize button: x=[scrw-88, scrw-70], y=[52, 70]
    mov eax, [v_mx]
    mov edx, [v_scrw]
    sub edx, 88
    cmp eax, edx
    jl .hc_not_min
    add edx, 18
    cmp eax, edx
    jg .hc_not_min
    cmp ecx, 52
    jl .hc_not_min
    cmp ecx, 70
    jg .hc_not_min
    mov eax, 2
    jmp .hc_ret
.hc_not_min:
    ; Start button: x=[4, 92], y=[scrh-32, scrh-4]
    mov eax, [v_mx]
    cmp eax, 4
    jl .hc_none
    cmp eax, 92
    jg .hc_none
    mov edx, [v_scrh]
    sub edx, 32
    cmp ecx, edx
    jl .hc_none
    add edx, 28
    cmp ecx, edx
    jg .hc_none
    mov eax, 3
    jmp .hc_ret
.hc_none:
    xor eax, eax
.hc_ret:
    add rsp, 40
    ret

; fn_mouse_poll - check for mouse movement, update cursor
; Returns: eax=0 if no event, eax=1 if moved, eax=2 if left click
fn_mouse_poll:
    push rbx
    push r12
    push r13
    sub rsp, 96

    cmp qword [v_mouse], 0
    je .mp_none

    ; First check if mouse has pending data via CheckEvent(WaitForInput)
    mov rcx, [v_mouse]
    mov rcx, [rcx + SPP_WAIT]  ; WaitForInput event
    mov rax, [v_bs]
    mov rax, [rax + BS_CHKEVT]
    sub rsp, 32
    call rax
    add rsp, 32
    test rax, rax
    jnz .mp_none              ; Event not signaled = no data

    ; GetState(this, &state)
    mov rcx, [v_mouse]
    lea rdx, [rsp+64]        ; state buffer at rsp+64 (safe from shadow space)
    mov rax, [rcx + SPP_GETST]
    sub rsp, 32
    call rax
    add rsp, 32
    test rax, rax
    jnz .mp_none              ; EFI_NOT_READY = no new data

    ; Branch based on pointer type
    cmp byte [v_mtype], 1
    je .mp_absolute

    ; --- RELATIVE (Simple Pointer Protocol) ---
    mov r12d, [rsp+64]       ; RelativeMovementX (raw INT32)
    mov ebx, [rsp+68]        ; RelativeMovementY (raw INT32)

    ; Scale by resolution
    mov rcx, [v_mouse]
    mov rcx, [rcx + SPP_MODE]
    mov r13d, [rcx]           ; ResolutionX

    mov eax, r12d
    cmp r13d, 256
    jb .mp_small_res_x
    mov ecx, r13d
    shr ecx, 2
    test ecx, ecx
    jz .mp_x_done
    cdq
    idiv ecx
    jmp .mp_x_done
.mp_small_res_x:
    shl eax, 1
.mp_x_done:
    mov r12d, eax

    mov eax, ebx
    push rax
    mov rcx, [v_mouse]
    mov rcx, [rcx + SPP_MODE]
    mov r13d, [rcx + 8]      ; ResolutionY
    pop rax
    cmp r13d, 256
    jb .mp_small_res_y
    mov ecx, r13d
    shr ecx, 2
    test ecx, ecx
    jz .mp_y_done
    cdq
    idiv ecx
    jmp .mp_y_done
.mp_small_res_y:
    shl eax, 1
.mp_y_done:
    mov ebx, eax

    ; Update position with clamping (relative mode)
    mov eax, [v_mx]
    add eax, r12d
    jmp .mp_clamp

.mp_absolute:
    ; --- ABSOLUTE (Absolute Pointer Protocol) ---
    ; State: UINT64 CurrentX (offset 0), UINT64 CurrentY (offset 8),
    ;        UINT64 CurrentZ (offset 16), UINT32 ActiveButtons (offset 24)
    ; Mode: UINT64 MinX(0), MinY(8), MinZ(16), MaxX(24), MaxY(32), MaxZ(40)
    mov r12, [rsp+64]        ; CurrentX (UINT64)
    mov r13, [rsp+72]        ; CurrentY (UINT64)

    ; Map X: screen_x = (CurrentX - MinX) * screen_w / (MaxX - MinX)
    mov rcx, [v_mouse]
    mov rcx, [rcx + SPP_MODE]
    mov rax, r12
    sub rax, [rcx]            ; CurrentX - MinX
    imul rax, rax, 1          ; keep as-is for now
    mov rbx, [rcx + 24]      ; MaxX
    sub rbx, [rcx]            ; MaxX - MinX
    test rbx, rbx
    jz .mp_abs_default_x
    movzx r8d, word [v_scrw]  ; screen width (fits 16 bits)
    imul rax, r8
    xor edx, edx
    div rbx
    jmp .mp_abs_x_done
.mp_abs_default_x:
    mov eax, [v_scrw]
    shr eax, 1
.mp_abs_x_done:
    ; eax = screen X

    push rax                  ; save screen X

    ; Map Y: screen_y = (CurrentY - MinY) * screen_h / (MaxY - MinY)
    mov rcx, [v_mouse]
    mov rcx, [rcx + SPP_MODE]
    mov rax, r13
    sub rax, [rcx + 8]       ; CurrentY - MinY
    mov rbx, [rcx + 32]      ; MaxY
    sub rbx, [rcx + 8]       ; MaxY - MinY
    test rbx, rbx
    jz .mp_abs_default_y
    movzx r8d, word [v_scrh]
    imul rax, r8
    xor edx, edx
    div rbx
    jmp .mp_abs_y_done
.mp_abs_default_y:
    mov eax, [v_scrh]
    shr eax, 1
.mp_abs_y_done:
    mov ebx, eax              ; ebx = screen Y (for clamping below)
    pop rax                   ; eax = screen X

    ; For absolute, set position directly (not add delta)
    jmp .mp_clamp_abs

.mp_clamp:
    ; Clamp X: 0 to scrw-16 (relative mode: eax = old_x + dx)
    test eax, eax
    jns .mp_xok
    xor eax, eax
.mp_xok:
    mov ecx, [v_scrw]
    sub ecx, 16
    cmp eax, ecx
    jle .mp_xset
    mov eax, ecx
.mp_xset:
    mov [v_mx], eax

    mov eax, [v_my]
    add eax, ebx
    ; Clamp Y
    test eax, eax
    jns .mp_yok
    xor eax, eax
.mp_yok:
    mov ecx, [v_scrh]
    sub ecx, 20
    cmp eax, ecx
    jle .mp_yset
    mov eax, ecx
.mp_yset:
    mov [v_my], eax
    jmp .mp_check_btn

.mp_clamp_abs:
    ; Absolute mode: eax=X, ebx=Y (already in screen coords)
    test eax, eax
    jns .mp_axok
    xor eax, eax
.mp_axok:
    mov ecx, [v_scrw]
    sub ecx, 16
    cmp eax, ecx
    jle .mp_axset
    mov eax, ecx
.mp_axset:
    mov [v_mx], eax

    mov eax, ebx
    test eax, eax
    jns .mp_ayok
    xor eax, eax
.mp_ayok:
    mov ecx, [v_scrh]
    sub ecx, 20
    cmp eax, ecx
    jle .mp_ayset
    mov eax, ecx
.mp_ayset:
    mov [v_my], eax

.mp_check_btn:
    ; Check button state
    ; Simple Pointer: LeftButton at state+12 (BOOL)
    ; Absolute Pointer: ActiveButtons at state+24 (UINT32, bit 0 = touch)
    cmp byte [v_mtype], 1
    je .mp_abs_btn
    movzx eax, byte [rsp+76]  ; state+12 = rsp+64+12
    test al, al
    jnz .mp_click
    jmp .mp_moved
.mp_abs_btn:
    mov eax, [rsp+88]         ; state+24 = rsp+64+24
    test eax, 1               ; bit 0 = touch active / left button
    jnz .mp_click

.mp_moved:
    mov eax, 1                ; moved
    jmp .mp_ret

.mp_click:
    mov eax, 2                ; left click
    jmp .mp_ret

.mp_none:
    xor eax, eax
.mp_ret:
    add rsp, 96
    pop r13
    pop r12
    pop rbx
    ret

; 12x20 arrow cursor bitmap (16 bits per row, MSB = leftmost pixel)
; Classic arrow pointer shape
cursor_bmp:
    dw 0b1000000000000000   ; row 0
    dw 0b1100000000000000   ; row 1
    dw 0b1110000000000000   ; row 2
    dw 0b1111000000000000   ; row 3
    dw 0b1111100000000000   ; row 4
    dw 0b1111110000000000   ; row 5
    dw 0b1111111000000000   ; row 6
    dw 0b1111111100000000   ; row 7
    dw 0b1111111110000000   ; row 8
    dw 0b1111111111000000   ; row 9
    dw 0b1111111111100000   ; row 10
    dw 0b1111111000000000   ; row 11
    dw 0b1111100000000000   ; row 12
    dw 0b1101100000000000   ; row 13
    dw 0b1000110000000000   ; row 14
    dw 0b0000110000000000   ; row 15
    dw 0b0000011000000000   ; row 16
    dw 0b0000011000000000   ; row 17
    dw 0b0000001100000000   ; row 18
    dw 0b0000000000000000   ; row 19

; Inner fill bitmap (1 = white fill, for pixels also set in cursor_bmp)
cursor_fill:
    dw 0b0000000000000000
    dw 0b0100000000000000
    dw 0b0110000000000000
    dw 0b0111000000000000
    dw 0b0111100000000000
    dw 0b0111110000000000
    dw 0b0111111000000000
    dw 0b0111111100000000
    dw 0b0111111110000000
    dw 0b0111111111000000
    dw 0b0111111000000000
    dw 0b0111100000000000
    dw 0b0110100000000000
    dw 0b0100110000000000
    dw 0b0000010000000000
    dw 0b0000010000000000
    dw 0b0000001000000000
    dw 0b0000001000000000
    dw 0b0000000000000000
    dw 0b0000000000000000

; ============================================================================
; DRAWING PRIMITIVES (using GOP Blt for reliable rendering)
; ============================================================================

; fn_fill_rect(x, y, w, h, color) - fills rectangle via GOP Blt VideoFill
; edi=x, esi=y, edx=w, ecx=h, r8d=color(BGRX)
fn_fill_rect:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96          ; stack space for Blt args + shadow

    mov r12d, edi         ; x
    mov r13d, esi         ; y
    mov r14d, edx         ; w
    mov r15d, ecx         ; h
    mov [v_bltpx], r8d    ; store color in blt pixel buffer

    ; GOP->Blt(this, &pixel, EfiBltVideoFill, srcX, srcY, destX, destY, w, h, delta)
    ; Stack params at: [rsp+32]=srcY [rsp+40]=destX [rsp+48]=destY [rsp+56]=w [rsp+64]=h [rsp+72]=delta
    mov qword [rsp+32], 0   ; SourceY = 0
    mov eax, r12d
    mov [rsp+40], rax        ; DestinationX
    mov eax, r13d
    mov [rsp+48], rax        ; DestinationY
    mov eax, r14d
    mov [rsp+56], rax        ; Width
    mov eax, r15d
    mov [rsp+64], rax        ; Height
    mov qword [rsp+72], 0   ; Delta = 0

    mov rcx, [v_gop]        ; this
    lea rdx, [v_bltpx]      ; BltBuffer = &pixel
    xor r8d, r8d            ; BltOperation = EfiBltVideoFill (0)
    xor r9d, r9d            ; SourceX = 0
    mov rax, [rcx + GOP_BLT]
    call rax

    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fn_draw_char(x, y, char, color, bg_color) - draws 8x8 char via GOP Blt
; edi=x, esi=y, dl=char, ecx=fg_color, r8d=bg_color
fn_draw_char:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 96

    mov r12d, edi       ; x
    mov r13d, esi       ; y
    movzx r14d, dl      ; char
    mov r15d, ecx       ; fg color
    mov ebp, r8d        ; bg color

    ; Get font data pointer: font_8x8 + (char - 32) * 8
    sub r14d, 32
    cmp r14d, 95
    jae .dc_done        ; out of range
    lea rbx, [font_8x8]
    shl r14d, 3         ; * 8
    add rbx, r14

    ; Build 8x8 pixel buffer (64 dwords = 256 bytes) in char_buf
    lea rdi, [char_buf]
    mov ecx, 8          ; 8 rows
.dc_build_row:
    movzx eax, byte [rbx]
    mov edx, 8          ; 8 columns
.dc_build_col:
    test al, 0x80
    jz .dc_build_bg
    mov [rdi], r15d     ; fg color
    jmp .dc_build_next
.dc_build_bg:
    mov [rdi], ebp      ; bg color
.dc_build_next:
    shl al, 1
    add rdi, 4
    dec edx
    jnz .dc_build_col
    inc rbx
    dec ecx
    jnz .dc_build_row

    ; Blt the 8x8 buffer to screen
    ; GOP->Blt(this, buf, EfiBltBufferToVideo, 0, 0, destX, destY, 8, 8, 8*4)
    mov rcx, [v_gop]
    lea rdx, [char_buf]
    mov r8d, 2              ; EfiBltBufferToVideo
    xor r9d, r9d            ; SourceX = 0
    mov qword [rsp+32], 0   ; SourceY = 0
    mov eax, r12d
    mov [rsp+40], rax        ; DestinationX
    mov eax, r13d
    mov [rsp+48], rax        ; DestinationY
    mov qword [rsp+56], 8   ; Width = 8
    mov qword [rsp+64], 8   ; Height = 8
    mov qword [rsp+72], 32  ; Delta = 8 pixels * 4 bytes = 32
    mov rax, [rcx + GOP_BLT]
    call rax

.dc_done:
    add rsp, 96
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fn_draw_str(x, y, str_ptr, fg, bg)
; edi=x, esi=y, rdx=str_ptr (ASCII null-term), ecx=fg, r8d=bg
fn_draw_str:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi       ; x
    mov r13d, esi       ; y
    mov rbx, rdx        ; string ptr
    mov r14d, ecx       ; fg
    mov r15d, r8d       ; bg
.ds_loop:
    movzx eax, byte [rbx]
    test al, al
    jz .ds_done
    mov edi, r12d
    mov esi, r13d
    mov dl, al
    mov ecx, r14d
    mov r8d, r15d
    push rbx
    call fn_draw_char
    pop rbx
    add r12d, 8         ; advance x by 8 pixels (char width)
    inc rbx
    jmp .ds_loop
.ds_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; DESKTOP UI
; ============================================================================
fn_desktop:
    sub rsp, 40

    ; Disable text cursor FIRST to prevent UEFI text layer from overwriting framebuffer
    mov rcx, [v_conout]
    xor edx, edx        ; FALSE = hide cursor
    mov rax, [rcx + 64]  ; EnableCursor offset
    sub rsp, 32
    call rax
    add rsp, 32

    ; ---- COLOR SCHEME (BGRX) ----
    ; Desktop bg:    0x00553311  (warm dark brown)
    ; Panel/bar:     0x00331A08  (deep brown)
    ; Panel accent:  0x00664422  (medium brown)
    ; Window bg:     0x00201018  (near-black with warm tint)
    ; Window title:  0x00883310  (rich amber)
    ; Highlight:     0x00CC6620  (bright amber)
    ; Text light:    0x00E0D0C0  (warm white)
    ; Text mid:      0x00A09888  (muted)

    ; === DESKTOP BACKGROUND ===
    mov edi, 0
    mov esi, 0
    mov edx, [v_scrw]
    mov ecx, [v_scrh]
    mov r8d, 0x00422210     ; warm dark brown
    call fn_fill_rect

    ; === TOP PANEL (30px) ===
    mov edi, 0
    mov esi, 0
    mov edx, [v_scrw]
    mov ecx, 30
    mov r8d, 0x00201008     ; deep dark panel
    call fn_fill_rect

    ; Panel bottom accent line (1px)
    mov edi, 0
    mov esi, 30
    mov edx, [v_scrw]
    mov ecx, 1
    mov r8d, 0x00553318     ; subtle border
    call fn_fill_rect

    ; Panel title
    mov edi, 12
    mov esi, 11
    lea rdx, [a_title]
    mov ecx, 0x00E8C878     ; warm gold
    mov r8d, 0x00201008
    call fn_draw_str

    ; Clock
    call fn_draw_clock

    ; === MAIN WINDOW ===
    mov eax, [v_scrw]
    sub eax, 80
    mov [v_winw], eax
    mov eax, [v_scrh]
    sub eax, 110
    mov [v_winh], eax

    ; Window drop shadow (offset +4,+4)
    mov edi, 44
    mov esi, 52
    mov edx, [v_winw]
    mov ecx, [v_winh]
    mov r8d, 0x00180A02     ; very dark shadow
    call fn_fill_rect

    ; Window outer border (1px bright edge)
    mov edi, 39
    mov esi, 47
    mov edx, [v_winw]
    add edx, 2
    mov ecx, [v_winh]
    add ecx, 2
    mov r8d, 0x00664422     ; border color
    call fn_fill_rect

    ; Window body
    mov edi, 40
    mov esi, 48
    mov edx, [v_winw]
    mov ecx, [v_winh]
    mov r8d, 0x00241410     ; dark window body
    call fn_fill_rect

    ; Window title bar (26px)
    mov edi, 40
    mov esi, 48
    mov edx, [v_winw]
    mov ecx, 26
    mov r8d, 0x00883310     ; rich amber title bar
    call fn_fill_rect

    ; Title bar bottom edge
    mov edi, 40
    mov esi, 74
    mov edx, [v_winw]
    mov ecx, 1
    mov r8d, 0x00AA5520     ; brighter amber accent
    call fn_fill_rect

    ; Close button (right side of title bar) - red square
    mov eax, [v_winw]
    add eax, 40
    sub eax, 24              ; right edge - 24px
    mov edi, eax
    mov esi, 52
    mov edx, 18
    mov ecx, 18
    mov r8d, 0x002020CC     ; red (BGRX: low B, low G, high R)
    call fn_fill_rect

    ; Close button "X" text
    mov eax, [v_winw]
    add eax, 40
    sub eax, 21
    mov edi, eax
    mov esi, 57
    lea rdx, [a_closebtn]
    mov ecx, 0x00FFFFFF
    mov r8d, 0x002020CC
    call fn_draw_str

    ; Minimize button (left of close)
    mov eax, [v_winw]
    add eax, 40
    sub eax, 48
    mov edi, eax
    mov esi, 52
    mov edx, 18
    mov ecx, 18
    mov r8d, 0x0020A0CC     ; amber/yellow
    call fn_fill_rect

    ; Minimize "_" text
    mov eax, [v_winw]
    add eax, 40
    sub eax, 45
    mov edi, eax
    mov esi, 57
    lea rdx, [a_minbtn]
    mov ecx, 0x00201008
    mov r8d, 0x0020A0CC
    call fn_draw_str

    ; Window title text
    mov edi, 52
    mov esi, 55
    lea rdx, [a_wintitle]
    mov ecx, 0x00FFFFFF
    mov r8d, 0x00883310
    call fn_draw_str

    ; === WINDOW CONTENT ===
    ; Content area starts at y=85

    mov edi, 60
    mov esi, 90
    lea rdx, [a_ln1]
    mov ecx, 0x0058D8F8     ; bright cyan-gold
    mov r8d, 0x00241410
    call fn_draw_str

    ; Separator line under heading
    mov edi, 60
    mov esi, 102
    mov edx, 220
    mov ecx, 1
    mov r8d, 0x00554030
    call fn_fill_rect

    mov edi, 60
    mov esi, 114
    lea rdx, [a_ln2]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 130
    lea rdx, [a_ln3]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 146
    lea rdx, [a_ln4]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    ; System section header
    mov edi, 60
    mov esi, 172
    lea rdx, [a_ln5]
    mov ecx, 0x0060E880     ; bright green
    mov r8d, 0x00241410
    call fn_draw_str

    ; Separator
    mov edi, 60
    mov esi, 184
    mov edx, 120
    mov ecx, 1
    mov r8d, 0x00405030
    call fn_fill_rect

    mov edi, 60
    mov esi, 196
    lea rdx, [a_ln6]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 212
    lea rdx, [a_ln7]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 228
    lea rdx, [a_ln8]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    ; Shell section header
    mov edi, 60
    mov esi, 254
    lea rdx, [a_ln9]
    mov ecx, 0x00FF80FF     ; magenta/pink
    mov r8d, 0x00241410
    call fn_draw_str

    ; Separator
    mov edi, 60
    mov esi, 266
    mov edx, 120
    mov ecx, 1
    mov r8d, 0x00504030
    call fn_fill_rect

    mov edi, 60
    mov esi, 278
    lea rdx, [a_ln10]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 298
    lea rdx, [a_ln11]
    mov ecx, 0x0050D0FF     ; orange accent
    mov r8d, 0x00241410
    call fn_draw_str

    ; === BOTTOM TASKBAR (36px) ===
    mov edi, 0
    mov eax, [v_scrh]
    sub eax, 36
    mov esi, eax
    mov edx, [v_scrw]
    mov ecx, 36
    mov r8d, 0x00201008     ; deep dark - matches top panel
    call fn_fill_rect

    ; Taskbar top accent line
    mov edi, 0
    mov eax, [v_scrh]
    sub eax, 36
    mov esi, eax
    mov edx, [v_scrw]
    mov ecx, 1
    mov r8d, 0x00553318     ; subtle border (matches top)
    call fn_fill_rect

    ; Taskbar "start" button area
    mov edi, 4
    mov eax, [v_scrh]
    sub eax, 32
    mov esi, eax
    mov edx, 88
    mov ecx, 28
    mov r8d, 0x00663818     ; slightly lighter
    call fn_fill_rect

    ; Start button text
    mov edi, 12
    mov eax, [v_scrh]
    sub eax, 24
    mov esi, eax
    lea rdx, [a_startbtn]
    mov ecx, 0x00E8C878     ; gold like panel title
    mov r8d, 0x00663818
    call fn_draw_str

    ; Taskbar window tab
    mov edi, 100
    mov eax, [v_scrh]
    sub eax, 32
    mov esi, eax
    mov edx, 200
    mov ecx, 28
    mov r8d, 0x00442818     ; active tab bg
    call fn_fill_rect

    ; Tab active indicator (2px bright line at top)
    mov edi, 100
    mov eax, [v_scrh]
    sub eax, 32
    mov esi, eax
    mov edx, 200
    mov ecx, 2
    mov r8d, 0x00CC8840     ; amber indicator
    call fn_fill_rect

    ; Tab text
    mov edi, 108
    mov eax, [v_scrh]
    sub eax, 24
    mov esi, eax
    lea rdx, [a_wintitle]
    mov ecx, 0x00D0C0B0
    mov r8d, 0x00442818
    call fn_draw_str

    ; Status area (right side of taskbar)
    mov eax, [v_scrw]
    sub eax, 200
    mov edi, eax
    mov eax, [v_scrh]
    sub eax, 24
    mov esi, eax
    lea rdx, [a_status]
    mov ecx, 0x0060B080     ; green status
    mov r8d, 0x00201008
    call fn_draw_str

    add rsp, 40
    ret

; Draw clock on title bar
fn_draw_clock:
    sub rsp, 64
    mov rcx, [v_rs]
    mov rax, [rcx + RS_TIME]
    lea rcx, [rsp+32]
    xor edx, edx
    call rax

    ; Format HH:MM
    movzx eax, byte [rsp+36]   ; hour
    mov ecx, 10
    xor edx, edx
    div ecx
    add al, '0'
    add dl, '0'
    mov [a_clock], al
    mov [a_clock+1], dl
    movzx eax, byte [rsp+37]   ; minute
    xor edx, edx
    div ecx
    add al, '0'
    add dl, '0'
    mov [a_clock+3], al
    mov [a_clock+4], dl

    mov eax, [v_scrw]
    sub eax, 60
    mov edi, eax
    mov esi, 11
    lea rdx, [a_clock]
    mov ecx, 0x00E0D0C0       ; warm white
    mov r8d, 0x00201008        ; match panel bg
    call fn_draw_str
    add rsp, 64
    ret

; ============================================================================
; TEXT-MODE SHELL (fallback + interactive)
; ============================================================================
fn_shell:
    push rbx
    push rsi
    sub rsp, 40
.loop:
    ; If in graphics mode, draw shell in the window area
    ; For now use text mode shell
    mov dl, LCYAN
    call fn_tcolor
    lea rcx, [s_prompt]
    call fn_tpr
    mov dl, WHITE
    call fn_tcolor
    lea rcx, [cmd_buf]
    mov edx, 250
    call fn_rdln
    lea rcx, [cmd_buf]
    call fn_exec
    jmp .loop
    add rsp, 40
    pop rsi
    pop rbx
    ret

fn_exec:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
.sk: movzx eax, word [rsi]
    cmp ax,' '
    jne .ck
    add rsi,2
    jmp .sk
.ck: cmp ax,0
    je .done

    lea rdx,[c_help]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .help

    lea rdx,[c_clear]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .clear

    lea rdx,[c_cls]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .clear

    lea rdx,[c_time]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .time

    lea rdx,[c_sysinfo]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .sysi

    lea rdx,[c_about]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .about

    lea rdx,[c_reboot]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .reboot

    lea rdx,[c_shutdown]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .shut

    lea rdx,[c_desktop]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .desk

    lea rdx,[c_echo_p]
    mov rcx,rsi
    call fn_pfx
    test eax,eax
    jz .echo

    lea rdx,[c_ver]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .ver

    mov dl, LRED
    call fn_tcolor
    lea rcx,[s_unk]
    call fn_tpr
    mov dl, WHITE
    call fn_tcolor
    jmp .done

.help: call fn_c_help
    jmp .done
.clear: call fn_cls
    jmp .done
.time: call fn_c_time
    jmp .done
.sysi: call fn_c_sysi
    jmp .done
.about: call fn_c_about
    jmp .done
.reboot:
    mov rcx,[v_rs]
    mov rax,[rcx+RS_RESET]
    mov ecx,1
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    sub rsp,32
    call rax
    add rsp,32
    jmp .done
.shut:
    mov rcx,[v_rs]
    mov rax,[rcx+RS_RESET]
    mov ecx,2
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    sub rsp,32
    call rax
    add rsp,32
    jmp .done
.desk:
    cmp qword [v_gop], 0
    je .done
    call fn_desktop
    call fn_cursor_show
    ; Stay in graphics mode - interactive loop with mouse
.desk_wait:
    ; Poll keyboard
    mov rcx, [v_conin]
    mov rax, [rcx + CI_KEY]
    lea rdx, [kd]
    call rax
    test rax, rax
    jnz .desk_poll_mouse
    ; Got key - check if ESC (scan code 0x17)
    movzx eax, word [kd]
    cmp ax, 0x17
    je .desk_exit
    ; Check if it's a mouse key (arrows, *, -)
    call fn_kb_mouse
    test eax, eax
    jnz .desk_kb_moved
    ; Other key - ignore on desktop
    jmp .desk_wait
.desk_kb_moved:
    cmp eax, 2             ; left click?
    je .desk_kb_click
    call fn_cursor_hide
    call fn_cursor_show
    jmp .desk_wait
.desk_kb_click:
    call fn_handle_click
    cmp eax, 1             ; close
    je .desk_exit
    cmp eax, 3             ; start -> shell
    je .desk_exit
    jmp .desk_wait
.desk_poll_mouse:
    ; Poll hardware mouse
    call fn_mouse_poll
    cmp eax, 0
    je .desk_stall
    cmp eax, 2
    je .desk_hw_click
    ; Mouse moved - update cursor
    call fn_cursor_hide
    call fn_cursor_show
    jmp .desk_wait
.desk_hw_click:
    call fn_handle_click
    cmp eax, 1
    je .desk_exit
    cmp eax, 3
    je .desk_exit
    call fn_cursor_hide
    call fn_cursor_show
    jmp .desk_wait
.desk_stall:
    mov rcx, 5000
    call fn_stall
    jmp .desk_wait
.desk_exit:
    call fn_cursor_hide
    call fn_cls
    jmp .done
.echo:
    add rsi,10
    mov rcx,rsi
    call fn_tpr
    lea rcx,[s_crlf]
    call fn_tpr
    jmp .done
.ver:
    mov dl, LCYAN
    call fn_tcolor
    lea rcx,[s_verfull]
    call fn_tpr
    mov dl, WHITE
    call fn_tcolor
    jmp .done
.done:
    add rsp,40
    pop rsi
    pop rbx
    ret

; COMMANDS
fn_c_help:
    sub rsp,40
    mov dl,YELLOW
    call fn_tcolor
    lea rcx,[s_hh]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    %assign hn 1
    %rep 11
    lea rcx,[s_h %+ hn]
    call fn_tpr
    %assign hn hn+1
    %endrep
    mov dl,WHITE
    call fn_tcolor
    add rsp,40
    ret

fn_c_time:
    sub rsp,64
    mov rcx,[v_rs]
    mov rax,[rcx+RS_TIME]
    lea rcx,[rsp+32]
    xor edx,edx
    call rax
    mov dl,LGREEN
    call fn_tcolor
    movzx eax,word [rsp+32]
    call fn_pdec
    lea rcx,[s_dash]
    call fn_tpr
    movzx eax,byte [rsp+34]
    call fn_pdec2
    lea rcx,[s_dash]
    call fn_tpr
    movzx eax,byte [rsp+35]
    call fn_pdec2
    lea rcx,[s_sp]
    call fn_tpr
    movzx eax,byte [rsp+36]
    call fn_pdec2
    lea rcx,[s_colon]
    call fn_tpr
    movzx eax,byte [rsp+37]
    call fn_pdec2
    lea rcx,[s_colon]
    call fn_tpr
    movzx eax,byte [rsp+38]
    call fn_pdec2
    lea rcx,[s_crlf]
    call fn_tpr
    mov dl,WHITE
    call fn_tcolor
    add rsp,64
    ret

fn_c_sysi:
    sub rsp,40
    mov dl,YELLOW
    call fn_tcolor
    lea rcx,[s_si1]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    lea rcx,[s_si2]
    call fn_tpr
    mov dl,WHITE
    call fn_tcolor
    mov rcx,[v_fwv]
    call fn_tpr
    lea rcx,[s_crlf]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    lea rcx,[s_si3]
    call fn_tpr
    lea rcx,[s_si4]
    call fn_tpr

    ; Show GOP resolution if available
    cmp qword [v_gop], 0
    je .nores
    lea rcx,[s_si5]
    call fn_tpr
    mov eax, [v_scrw]
    call fn_pdec
    lea rcx, [s_x]
    call fn_tpr
    mov eax, [v_scrh]
    call fn_pdec
    lea rcx,[s_crlf]
    call fn_tpr
.nores:
    mov dl,WHITE
    call fn_tcolor
    add rsp,40
    ret

fn_c_about:
    sub rsp,40
    mov dl,LMAG
    call fn_tcolor
    lea rcx,[s_ab1]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    lea rcx,[s_ab2]
    call fn_tpr
    lea rcx,[s_ab3]
    call fn_tpr
    lea rcx,[s_ab4]
    call fn_tpr
    mov dl,WHITE
    call fn_tcolor
    add rsp,40
    ret

; ============================================================================
; TEXT I/O PRIMITIVES
; ============================================================================
fn_tpr:
    push rbx
    sub rsp,32
    mov rbx,rcx
    mov rcx,[v_conout]
    mov rdx,rbx
    mov rax,[rcx+CO_STR]
    call rax
    add rsp,32
    pop rbx
    ret

fn_tcolor:
    sub rsp,40
    mov rcx,[v_conout]
    movzx edx,dl
    mov rax,[rcx+CO_ATTR]
    call rax
    add rsp,40
    ret

fn_cls:
    sub rsp,40
    mov rcx,[v_conout]
    mov rax,[rcx+CO_CLR]
    call rax
    add rsp,40
    ret

fn_stall:
    sub rsp,40
    mov rax,[v_bs]
    mov rax,[rax+BS_STALL]
    call rax
    add rsp,40
    ret

fn_rdln:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,48
    mov rdi,rcx
    mov r12d,edx
    xor r13d,r13d
.rl: mov rcx,[v_conin]
    mov rax,[rcx+CI_KEY]
    lea rdx,[kd]
    call rax
    test rax,rax
    jnz .rlw
    movzx ebx,word [kd+2]
    cmp bx,13
    je .rle
    cmp bx,8
    je .rlb
    cmp bx,0x20
    jb .rl
    cmp r13d,r12d
    jge .rl
    mov [rdi+r13*2],bx
    inc r13d
    mov word [eb],bx
    mov word [eb+2],0
    lea rcx,[eb]
    call fn_tpr
    jmp .rl
.rlw: mov rcx,10000
    call fn_stall
    jmp .rl
.rlb: cmp r13d,0
    je .rl
    dec r13d
    lea rcx,[s_bksp]
    call fn_tpr
    jmp .rl
.rle: mov word [rdi+r13*2],0
    lea rcx,[s_crlf]
    call fn_tpr
    add rsp,48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

fn_scmp:
    push rsi
    push rdi
    mov rsi,rcx
    mov rdi,rdx
.sc: movzx eax,word [rdi]
    movzx ecx,word [rsi]
    test ax,ax
    jz .sce
    cmp ax,'A'
    jb .s1
    cmp ax,'Z'
    ja .s1
    add ax,32
.s1: cmp cx,'A'
    jb .s2
    cmp cx,'Z'
    ja .s2
    add cx,32
.s2: cmp ax,cx
    jne .scn
    add rsi,2
    add rdi,2
    jmp .sc
.sce: cmp cx,0
    je .scy
    cmp cx,' '
    je .scy
.scn: mov eax,1
    pop rdi
    pop rsi
    ret
.scy: xor eax,eax
    pop rdi
    pop rsi
    ret

fn_pfx:
    push rsi
    push rdi
    mov rsi,rcx
    mov rdi,rdx
.pf: movzx eax,word [rdi]
    test ax,ax
    jz .pfy
    movzx ecx,word [rsi]
    cmp ax,'A'
    jb .p1
    cmp ax,'Z'
    ja .p1
    add ax,32
.p1: cmp cx,'A'
    jb .p2
    cmp cx,'Z'
    ja .p2
    add cx,32
.p2: cmp ax,cx
    jne .pfn
    add rsi,2
    add rdi,2
    jmp .pf
.pfy: xor eax,eax
    pop rdi
    pop rsi
    ret
.pfn: mov eax,1
    pop rdi
    pop rsi
    ret

fn_pdec:
    push rbx
    push rsi
    sub rsp,40
    lea rsi,[dbuf+20]
    mov word [rsi],0
    sub rsi,2
    mov ebx,10
    test eax,eax
    jnz .pd
    mov word [rsi],'0'
    mov rcx,rsi
    call fn_tpr
    jmp .pdd
.pd: test eax,eax
    jz .pdp
    xor edx,edx
    div ebx
    add dl,'0'
    mov byte [rsi],dl
    mov byte [rsi+1],0
    sub rsi,2
    jmp .pd
.pdp: add rsi,2
    mov rcx,rsi
    call fn_tpr
.pdd: add rsp,40
    pop rsi
    pop rbx
    ret

fn_pdec2:
    sub rsp,40
    mov ecx,10
    xor edx,edx
    div ecx
    add al,'0'
    add dl,'0'
    mov byte [d2buf],al
    mov byte [d2buf+1],0
    mov byte [d2buf+2],dl
    mov byte [d2buf+3],0
    mov word [d2buf+4],0
    lea rcx,[d2buf]
    call fn_tpr
    add rsp,40
    ret

; ============================================================================
; 8x8 BITMAP FONT (ASCII 32-126, 95 chars x 8 bytes = 760 bytes)
; ============================================================================
font_8x8:
; Space (32)
db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
; ! (33)
db 0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00
; " (34)
db 0x6C,0x6C,0x24,0x00,0x00,0x00,0x00,0x00
; # (35)
db 0x6C,0x6C,0xFE,0x6C,0xFE,0x6C,0x6C,0x00
; $ (36)
db 0x18,0x7E,0xC0,0x7C,0x06,0xFC,0x18,0x00
; % (37)
db 0x00,0xC6,0xCC,0x18,0x30,0x66,0xC6,0x00
; & (38)
db 0x38,0x6C,0x38,0x76,0xDC,0xCC,0x76,0x00
; ' (39)
db 0x18,0x18,0x30,0x00,0x00,0x00,0x00,0x00
; ( (40)
db 0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00
; ) (41)
db 0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00
; * (42)
db 0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00
; + (43)
db 0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00
; , (44)
db 0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30
; - (45)
db 0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00
; . (46)
db 0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00
; / (47)
db 0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00
; 0 (48)
db 0x7C,0xC6,0xCE,0xDE,0xF6,0xE6,0x7C,0x00
; 1 (49)
db 0x18,0x38,0x78,0x18,0x18,0x18,0x7E,0x00
; 2 (50)
db 0x7C,0xC6,0x06,0x1C,0x30,0x60,0xFE,0x00
; 3 (51)
db 0x7C,0xC6,0x06,0x3C,0x06,0xC6,0x7C,0x00
; 4 (52)
db 0x1C,0x3C,0x6C,0xCC,0xFE,0x0C,0x1E,0x00
; 5 (53)
db 0xFE,0xC0,0xFC,0x06,0x06,0xC6,0x7C,0x00
; 6 (54)
db 0x38,0x60,0xC0,0xFC,0xC6,0xC6,0x7C,0x00
; 7 (55)
db 0xFE,0xC6,0x0C,0x18,0x30,0x30,0x30,0x00
; 8 (56)
db 0x7C,0xC6,0xC6,0x7C,0xC6,0xC6,0x7C,0x00
; 9 (57)
db 0x7C,0xC6,0xC6,0x7E,0x06,0x0C,0x78,0x00
; : (58)
db 0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00
; ; (59)
db 0x00,0x18,0x18,0x00,0x18,0x18,0x30,0x00
; < (60)
db 0x06,0x0C,0x18,0x30,0x18,0x0C,0x06,0x00
; = (61)
db 0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00
; > (62)
db 0x60,0x30,0x18,0x0C,0x18,0x30,0x60,0x00
; ? (63)
db 0x7C,0xC6,0x0C,0x18,0x18,0x00,0x18,0x00
; @ (64)
db 0x7C,0xC6,0xDE,0xDE,0xDE,0xC0,0x78,0x00
; A-Z (65-90)
db 0x38,0x6C,0xC6,0xC6,0xFE,0xC6,0xC6,0x00
db 0xFC,0x66,0x66,0x7C,0x66,0x66,0xFC,0x00
db 0x3C,0x66,0xC0,0xC0,0xC0,0x66,0x3C,0x00
db 0xF8,0x6C,0x66,0x66,0x66,0x6C,0xF8,0x00
db 0xFE,0x62,0x68,0x78,0x68,0x62,0xFE,0x00
db 0xFE,0x62,0x68,0x78,0x68,0x60,0xF0,0x00
db 0x3C,0x66,0xC0,0xC0,0xCE,0x66,0x3E,0x00
db 0xC6,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0x00
db 0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00
db 0x1E,0x0C,0x0C,0x0C,0xCC,0xCC,0x78,0x00
db 0xE6,0x66,0x6C,0x78,0x6C,0x66,0xE6,0x00
db 0xF0,0x60,0x60,0x60,0x62,0x66,0xFE,0x00
db 0xC6,0xEE,0xFE,0xFE,0xD6,0xC6,0xC6,0x00
db 0xC6,0xE6,0xF6,0xDE,0xCE,0xC6,0xC6,0x00
db 0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00
db 0xFC,0x66,0x66,0x7C,0x60,0x60,0xF0,0x00
db 0x7C,0xC6,0xC6,0xC6,0xD6,0xDE,0x7C,0x06
db 0xFC,0x66,0x66,0x7C,0x6C,0x66,0xE6,0x00
db 0x7C,0xC6,0xE0,0x7C,0x0E,0xC6,0x7C,0x00
db 0x7E,0x5A,0x18,0x18,0x18,0x18,0x3C,0x00
db 0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00
db 0xC6,0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x00
db 0xC6,0xC6,0xD6,0xFE,0xFE,0xEE,0xC6,0x00
db 0xC6,0xC6,0x6C,0x38,0x6C,0xC6,0xC6,0x00
db 0x66,0x66,0x66,0x3C,0x18,0x18,0x3C,0x00
db 0xFE,0xC6,0x8C,0x18,0x32,0x66,0xFE,0x00
; [ (91)
db 0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00
; \ (92)
db 0xC0,0x60,0x30,0x18,0x0C,0x06,0x02,0x00
; ] (93)
db 0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00
; ^ (94)
db 0x10,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00
; _ (95)
db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF
; ` (96)
db 0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00
; a-z (97-122)
db 0x00,0x00,0x78,0x0C,0x7C,0xCC,0x76,0x00
db 0xE0,0x60,0x60,0x7C,0x66,0x66,0xDC,0x00
db 0x00,0x00,0x7C,0xC6,0xC0,0xC6,0x7C,0x00
db 0x1C,0x0C,0x0C,0x7C,0xCC,0xCC,0x76,0x00
db 0x00,0x00,0x7C,0xC6,0xFE,0xC0,0x7C,0x00
db 0x38,0x6C,0x60,0xF0,0x60,0x60,0xF0,0x00
db 0x00,0x00,0x76,0xCC,0xCC,0x7C,0x0C,0xF8
db 0xE0,0x60,0x6C,0x76,0x66,0x66,0xE6,0x00
db 0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00
db 0x06,0x00,0x06,0x06,0x06,0x66,0x66,0x3C
db 0xE0,0x60,0x66,0x6C,0x78,0x6C,0xE6,0x00
db 0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00
db 0x00,0x00,0xCC,0xFE,0xFE,0xD6,0xC6,0x00
db 0x00,0x00,0xDC,0x66,0x66,0x66,0x66,0x00
db 0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7C,0x00
db 0x00,0x00,0xDC,0x66,0x66,0x7C,0x60,0xF0
db 0x00,0x00,0x76,0xCC,0xCC,0x7C,0x0C,0x1E
db 0x00,0x00,0xDC,0x76,0x66,0x60,0xF0,0x00
db 0x00,0x00,0x7C,0xC0,0x7C,0x06,0xFC,0x00
db 0x10,0x30,0x7C,0x30,0x30,0x34,0x18,0x00
db 0x00,0x00,0xCC,0xCC,0xCC,0xCC,0x76,0x00
db 0x00,0x00,0xC6,0xC6,0xC6,0x6C,0x38,0x00
db 0x00,0x00,0xC6,0xD6,0xFE,0xFE,0x6C,0x00
db 0x00,0x00,0xC6,0x6C,0x38,0x6C,0xC6,0x00
db 0x00,0x00,0xC6,0xC6,0xC6,0x7E,0x06,0xFC
db 0x00,0x00,0xFE,0x8C,0x18,0x32,0xFE,0x00
; { (123)
db 0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00
; | (124)
db 0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00
; } (125)
db 0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00
; ~ (126)
db 0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00

; ============================================================================
; STRING DATA
; ============================================================================
align 2
s_crlf: dw 13,10,0
s_sp: dw ' ',0
s_dash: dw '-',0
s_colon: dw ':',0
s_bksp: dw 8,' ',8,0
s_x: dw 'x',0

s_prompt: u {'nexus> '}
s_notxt: u {'[GOP not found - text mode]'}
         dw 13,10,0

; Commands
c_help: u {'help'}
c_clear: u {'clear'}
c_cls: u {'cls'}
c_ver: u {'ver'}
c_about: u {'about'}
c_reboot: u {'reboot'}
c_shutdown: u {'shutdown'}
c_time: u {'time'}
c_sysinfo: u {'sysinfo'}
c_desktop: u {'desktop'}
c_echo_p: u {'echo '}

s_unk: u {'Unknown command. Type "help".'}
       dw 13,10,0

s_hh: dw 13,10
      u {'  === NexusOS Commands ==='}
      dw 13,10,0
s_h1: u {'  help      - This help screen'}
      dw 13,10,0
s_h2: u {'  clear/cls - Clear screen'}
      dw 13,10,0
s_h3: u {'  echo <t>  - Print text'}
      dw 13,10,0
s_h4: u {'  sysinfo   - System info'}
      dw 13,10,0
s_h5: u {'  time      - Date and time'}
      dw 13,10,0
s_h6: u {'  ver       - Version'}
      dw 13,10,0
s_h7: u {'  about     - About NexusOS'}
      dw 13,10,0
s_h8: u {'  desktop   - Show graphical desktop'}
      dw 13,10,0
s_h9: u {'  reboot    - Reboot'}
      dw 13,10,0
s_h10: u {'  shutdown  - Power off'}
       dw 13,10,0
s_h11: dw 13,10,0

s_verfull: u {'NexusOS v2.0 [x86-64 UEFI] - Graphical Assembly OS'}
           dw 13,10,0

s_si1: dw 13,10
       u {'  -- System Information --'}
       dw 13,10,13,10,0
s_si2: u {'  Firmware: '}
s_si3: u {'  Arch:     x86-64 (AMD64) Long Mode'}
       dw 13,10,0
s_si4: u {'  Boot:     UEFI'}
       dw 13,10,0
s_si5: u {'  Display:  '}

s_ab1: dw 13,10
       u {'  -- About NexusOS --'}
       dw 13,10,13,10,0
s_ab2: u {'  Written from absolute zero in x86-64 assembly.'}
       dw 13,10,0
s_ab3: u {'  No C. No Rust. No libraries. Pure divine intelligence.'}
       dw 13,10,0
s_ab4: u {'  Now with GOP graphical desktop UI.'}
       dw 13,10,13,10,0

; ASCII strings for graphics rendering
a_title: db 'NexusOS v2.0',0
a_wintitle: db 'System Console',0
a_clock: db '00:00',0
a_startbtn: db 'NexusOS',0
a_closebtn: db 'x',0
a_minbtn: db '_',0
a_status: db 'UEFI x86-64 | GOP',0
a_mok: db 'Mouse:OK',0
a_mno: db 'Mouse:--',0

a_ln1: db '=== Welcome to NexusOS ===',0
a_ln2: db 'A complete operating system written from scratch.',0
a_ln3: db 'Every byte hand-crafted in x86-64 assembly.',0
a_ln4: db 'No C compiler. No Rust. No libraries.',0
a_ln5: db '--- System ---',0
a_ln6: db 'Architecture: x86-64 (AMD64) Long Mode',0
a_ln7: db 'Boot Mode:    UEFI 2.x',0
a_ln8: db 'Display:      GOP Framebuffer',0
a_ln9: db '--- Shell ---',0
a_ln10: db 'Type commands in the UEFI text console below.',0
a_ln11: db 'Use "help" to see available commands.',0

; ============================================================================
; VARIABLES
; ============================================================================
align 8
v_handle:  dq 0
v_systab:  dq 0
v_conout:  dq 0
v_conin:   dq 0
v_bs:      dq 0
v_rs:      dq 0
v_fwv:     dq 0
v_gop:     dq 0
v_gopmode: dq 0
v_fb:      dq 0
v_scrw:    dd 0
v_scrh:    dd 0
v_pitch:   dd 0
v_winw:    dd 0
v_winh:    dd 0
v_tmp32:   dd 0
v_bltpx:   dd 0
v_mouse:   dq 0         ; Simple Pointer Protocol pointer
v_mx:      dd 0         ; mouse cursor X
v_my:      dd 0         ; mouse cursor Y
v_mvis:    db 0         ; cursor visible flag
v_mclick:  db 0         ; left button state
v_mfound:  db 0         ; 0=found, 1=not found
v_mtype:   db 0         ; 0=simple pointer (relative), 1=absolute pointer
v_mx_drn:  dd 0         ; cursor X when last drawn
v_my_drn:  dd 0         ; cursor Y when last drawn

align 16
char_buf:    times 64 dd 0    ; 8x8 pixel buffer for character rendering (256 bytes)
cursor_save: times 320 dd 0   ; 16x20 saved background (1280 bytes)
cursor_buf:  times 320 dd 0   ; 16x20 rendered cursor (1280 bytes)

kd:      times 4 db 0
eb:      times 4 db 0
dbuf:    times 24 db 0
d2buf:   times 8 db 0
cmd_buf: times 520 db 0

; PAD
times (HEADER_SIZE + TEXT_RAWSIZE - ($-$$)) db 0

; .reloc
reloc_s:
    dd 0x1000, 12
    dw 0, 0
times (RELOC_FSIZE - ($-reloc_s)) db 0
