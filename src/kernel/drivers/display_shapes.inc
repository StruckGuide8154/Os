; ============================================================================
; SVG rasterizer primitives (used by usermode SVG renderer via syscalls).
; All routines write to the back buffer and clip to screen bounds.
; ============================================================================

; --- Draw arbitrary line (Bresenham) ---
; EDI = x0, ESI = y0, EDX = x1, ECX = y1, R8D = color
FN_BEGIN draw_line, 0, 0, FN_RET_SCALAR
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
    push r14

    movsxd r9,  edi          ; x0
    movsxd r10, esi          ; y0
    movsxd r11, edx          ; x1
    movsxd r12, ecx          ; y1
    mov    r13d, r8d         ; color

    mov rax, r11
    sub rax, r9              ; x1 - x0
    mov rbx, 1               ; sx = +1
    jns .ln_dx_ok
    neg rax
    mov rbx, -1
.ln_dx_ok:                   ; rax = dx (>=0), rbx = sx

    mov rcx, r12
    sub rcx, r10             ; y1 - y0
    mov rdx, 1               ; sy = +1
    jns .ln_dy_ok
    neg rcx
    mov rdx, -1
.ln_dy_ok:
    neg rcx                  ; rcx = -|dy|  (i.e. dy <= 0)

    mov r14, rax
    add r14, rcx             ; err = dx + dy

.ln_loop:
    push rax
    push rbx
    push rcx
    push rdx
    mov edi, r9d
    mov esi, r10d
    mov edx, r13d
    call pixel_set
    pop rdx
    pop rcx
    pop rbx
    pop rax

    cmp r9, r11
    jne .ln_step
    cmp r10, r12
    je .ln_done
.ln_step:
    lea rdi, [r14 + r14]     ; e2 = 2*err
    cmp rdi, rcx             ; if e2 >= dy
    jl .ln_skip_x
    add r14, rcx
    add r9, rbx
.ln_skip_x:
    cmp rdi, rax             ; if e2 <= dx
    jg .ln_skip_y
    add r14, rax
    add r10, rdx
.ln_skip_y:
    jmp .ln_loop

.ln_done:
    pop r14
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
    ret

; --- Fill circle (scanline via SSE sqrt) ---
; EDI = cx, ESI = cy, EDX = r, ECX = color
FN_BEGIN fill_circle, 0, 0, FN_RET_SCALAR
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
    sub rsp, 16
    movdqu [rsp], xmm0

    movsxd r9,  edi          ; cx
    movsxd r10, esi          ; cy
    movsxd r11, edx          ; r
    mov    r13d, ecx         ; color

    test r11, r11
    jl .fc_done              ; negative radius is invalid/no-op
    jnz .fc_scan

    ; Degenerate circle: SVG treats r=0 as a single point for our filled
    ; raster primitive. Clipping is still delegated to pixel_set.
    mov edi, r9d
    mov esi, r10d
    mov edx, r13d
    call pixel_set
    jmp .fc_done

.fc_scan:
    mov r12, r11
    neg r12                  ; r12 = y_off = -r
.fc_row:
    cmp r12, r11
    jg .fc_done

    ; dx_sq = r*r - y*y
    mov rax, r11
    imul rax, rax
    mov rbx, r12
    imul rbx, rbx
    sub rax, rbx
    js .fc_next              ; defensive

    cvtsi2sd xmm0, rax
    sqrtsd xmm0, xmm0
    cvttsd2si rax, xmm0      ; rax = dx (floor)

    mov edi, r9d
    sub edi, eax             ; cx - dx
    mov esi, r10d
    add esi, r12d            ; cy + y_off
    lea edx, [eax + eax + 1] ; 2*dx + 1
    mov ecx, r13d
    call draw_hline_raster

.fc_next:
    inc r12
    jmp .fc_row
.fc_done:
    movdqu xmm0, [rsp]
    add rsp, 16
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
    ret

; --- Fill triangle (flat-top/flat-bottom scanline) ---
; EDI = pointer to 6 int32 coords [x0,y0,x1,y1,x2,y2], ESI = color
FN_BEGIN fill_triangle, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rbp, rdi             ; rbp = coords ptr
    mov r15d, esi            ; r15d = color

    ; Load v0/v1/v2 into r8..r13 (signed 64-bit)
    movsxd r8,  dword [rbp + 0]    ; x0
    movsxd r9,  dword [rbp + 4]    ; y0
    movsxd r10, dword [rbp + 8]    ; x1
    movsxd r11, dword [rbp + 12]   ; y1
    movsxd r12, dword [rbp + 16]   ; x2
    movsxd r13, dword [rbp + 20]   ; y2

    ; Sort by Y ascending: ensure y0<=y1<=y2 by pairwise swaps
    cmp r9, r11
    jle .ft_s1
    xchg r8, r10
    xchg r9, r11
.ft_s1:
    cmp r11, r13
    jle .ft_s2
    xchg r10, r12
    xchg r11, r13
.ft_s2:
    cmp r9, r11
    jle .ft_sorted
    xchg r8, r10
    xchg r9, r11
.ft_sorted:
    ; Degenerate: collinear triangle. Draw the three edges so single-line
    ; inputs do not expand into a stair-stepped filled wedge.
    mov rax, r10
    sub rax, r8              ; x1-x0
    mov rbx, r13
    sub rbx, r9              ; y2-y0
    imul rax, rbx
    mov rcx, r12
    sub rcx, r8              ; x2-x0
    mov rbx, r11
    sub rbx, r9              ; y1-y0
    imul rcx, rbx
    sub rax, rcx
    jnz .ft_not_collinear

    mov r14, r8
    mov edi, r8d
    mov esi, r9d
    mov edx, r10d
    mov ecx, r11d
    mov r8d, r15d
    call draw_line
    mov edi, r10d
    mov esi, r11d
    mov edx, r12d
    mov ecx, r13d
    mov r8d, r15d
    call draw_line
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r9d
    mov r8d, r15d
    call draw_line
    jmp .ft_done

.ft_not_collinear:
    ; Degenerate: y0==y2 -> single horizontal line
    cmp r9, r13
    jne .ft_general

    ; min/max of x0,x1,x2 -> hline at y0
    mov rax, r8
    mov rbx, r8
    cmp r10, rax
    jge .ft_d1
    mov rax, r10
.ft_d1:
    cmp r10, rbx
    jle .ft_d2
    mov rbx, r10
.ft_d2:
    cmp r12, rax
    jge .ft_d3
    mov rax, r12
.ft_d3:
    cmp r12, rbx
    jle .ft_d4
    mov rbx, r12
.ft_d4:
    mov edi, eax
    mov esi, r9d
    mov edx, ebx
    sub edx, eax
    inc edx
    mov ecx, r15d
    call draw_hline_raster
    jmp .ft_done

.ft_general:
    ; Iterate scanline y from y0 to y2 inclusive (rcx = current y)
    mov rcx, r9
.ft_yloop:
    cmp rcx, r13
    jg .ft_done

    ; Long edge xa = x0 + (x2-x0) * (y - y0) / (y2 - y0)
    mov rax, r12
    sub rax, r8              ; x2-x0
    mov rbx, rcx
    sub rbx, r9              ; y - y0
    imul rax, rbx            ; (x2-x0)*(y-y0)
    mov rbx, r13
    sub rbx, r9              ; y2-y0 (>0 here since not flat)
    cqo
    idiv rbx                 ; rax = (x2-x0)*(y-y0) / (y2-y0)
    add rax, r8              ; xa
    mov r14, rax

    ; Short edge xb depends on which half
    cmp rcx, r11
    jl .ft_upper
    ; Lower: xb = x1 + (x2-x1)*(y-y1) / (y2-y1)
    cmp r13, r11
    je .ft_skip              ; flat-bottom: y2==y1, undefined; skip safely
    mov rax, r12
    sub rax, r10             ; x2-x1
    mov rbx, rcx
    sub rbx, r11             ; y-y1
    imul rax, rbx
    mov rbx, r13
    sub rbx, r11             ; y2-y1
    cqo
    idiv rbx
    add rax, r10             ; xb
    jmp .ft_have_xb

.ft_upper:
    cmp r11, r9
    je .ft_skip              ; flat-top
    mov rax, r10
    sub rax, r8              ; x1-x0
    mov rbx, rcx
    sub rbx, r9
    imul rax, rbx
    mov rbx, r11
    sub rbx, r9
    cqo
    idiv rbx
    add rax, r8              ; xb

.ft_have_xb:
    ; left = min(xa, xb), width = |xa-xb|+1
    cmp rax, r14
    jle .ft_have_lr
    xchg rax, r14
.ft_have_lr:                 ; rax = left, r14 = right
    mov edi, eax
    mov esi, ecx
    mov edx, r14d
    sub edx, eax
    inc edx
    push rcx
    mov ecx, r15d
    call draw_hline_raster
    pop rcx

.ft_skip:
    inc rcx
    jmp .ft_yloop

.ft_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Raster primitives smoke self-test ---
; Exercises draw_line / fill_circle / fill_triangle with normal + degenerate
; inputs. Verifies a few deterministic pixels and prints the result to COM1.
FN_BEGIN raster_self_test, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8

    xor ebx, ebx             ; failure flag

    ; Line: normal
    mov edi, 100
    mov esi, 100
    mov edx, 200
    mov ecx, 150
    mov r8d, 0x00FF0000
    call draw_line
    ; Line: zero-length
    mov edi, 50
    mov esi, 50
    mov edx, 50
    mov ecx, 50
    mov r8d, 0x0000FF00
    call draw_line
    mov eax, 50
    imul rax, [scr_pitch_q]
    mov ecx, 50
    lea rax, [rax + rcx * 4]
    mov rdx, [bb_addr]
    cmp dword [rdx + rax], 0x0000FF00
    je .rst_line_ok
    mov ebx, 1
.rst_line_ok:
    ; Line: off-screen (negative coords) - clipping path
    mov edi, -50
    mov esi, -50
    mov edx, 300
    mov ecx, 300
    mov r8d, 0x000000FF
    call draw_line

    ; Circle: normal
    mov edi, 400
    mov esi, 300
    mov edx, 40
    mov ecx, 0x00FFFF00
    call fill_circle
    ; Circle: r=0 (single clipped pixel)
    mov edi, 10
    mov esi, 10
    mov edx, 0
    mov ecx, 0x00808080
    call fill_circle
    mov eax, 10
    imul rax, [scr_pitch_q]
    mov ecx, 10
    lea rax, [rax + rcx * 4]
    mov rdx, [bb_addr]
    cmp dword [rdx + rax], 0x00808080
    je .rst_circle0_ok
    mov ebx, 1
.rst_circle0_ok:
    ; Circle: r=1
    mov edi, 500
    mov esi, 300
    mov edx, 1
    mov ecx, 0x00FFFFFF
    call fill_circle

    ; Triangle: normal (use stack scratch)
    sub rsp, 32
    mov dword [rsp + 0],  600
    mov dword [rsp + 4],  100
    mov dword [rsp + 8],  700
    mov dword [rsp + 12], 200
    mov dword [rsp + 16], 550
    mov dword [rsp + 20], 250
    mov rdi, rsp
    mov esi, 0x00FF00FF
    call fill_triangle
    ; Triangle: degenerate (collinear)
    mov dword [rsp + 0],  10
    mov dword [rsp + 4],  10
    mov dword [rsp + 8],  20
    mov dword [rsp + 12], 10
    mov dword [rsp + 16], 30
    mov dword [rsp + 20], 10
    mov rdi, rsp
    mov esi, 0x00808080
    call fill_triangle
    mov eax, 10
    imul rax, [scr_pitch_q]
    mov ecx, 20
    lea rax, [rax + rcx * 4]
    mov rdx, [bb_addr]
    cmp dword [rdx + rax], 0x00808080
    je .rst_triangle_ok
    mov ebx, 1
.rst_triangle_ok:
    add rsp, 32

    test ebx, ebx
    jz .rst_emit_ok
    lea rsi, [rel rst_fail_msg]
    jmp .rst_loop

.rst_emit_ok:
    lea rsi, [rel rst_ok_msg]
.rst_loop:
    mov al, [rsi]
    test al, al
    jz .rst_done
    call serial_putc
    inc rsi
    jmp .rst_loop
.rst_done:

    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .data
rst_ok_msg: db '[RST] OK', 13, 10, 0
rst_fail_msg: db '[RST] FAIL', 13, 10, 0

section .text
