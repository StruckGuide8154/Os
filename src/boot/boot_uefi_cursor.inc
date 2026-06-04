; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI cursor and mouse interaction
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
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

