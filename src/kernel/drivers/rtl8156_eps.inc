rtl8156_find_bulk_eps:
    mov rsi, XHCI_CTRL_BUF_ADDR
    cmp byte [rsi], 4
    jb .nf
    movzx ecx, word [rsi + 2]
    cmp ecx, 4
    jb .nf
    cmp ecx, 512
    ja .nf
    xor edx, edx
    xor ebx, ebx
    mov byte [rtl8156_bulk_in_addr], 0
    mov byte [rtl8156_bulk_out_addr], 0
.parse:
    cmp edx, ecx
    jae .check
    movzx eax, byte [rsi + rdx]
    cmp eax, 2
    jb .nf
    mov r8d, edx
    add r8d, eax
    cmp r8d, ecx
    ja .nf
    mov al, [rsi + rdx + 1]
    cmp al, USB_DESC_INTERFACE
    je .iface
    cmp al, USB_DESC_ENDPOINT
    je .ep
    jmp .next
.iface:
    cmp byte [rsi + rdx], 9
    jb .nf
    cmp byte [rsi + rdx + 5], 0xFF
    jne .not_iface
    mov bl, 1
    jmp .next
.not_iface:
    xor ebx, ebx
    jmp .next
.ep:
    test ebx, ebx
    jz .next
    cmp byte [rsi + rdx], 7
    jb .nf
    mov al, [rsi + rdx + 3]
    and al, 3
    cmp al, USB_EP_BULK
    jne .next
    mov ax, [rsi + rdx + 4]
    and ax, 0x07FF
    test ax, ax
    jnz .mps_ok
    mov ax, 1024
.mps_ok:
    mov al, [rsi + rdx + 2]
    test al, 0x80
    jz .out_ep
    mov [rtl8156_bulk_in_addr], al
    mov ax, [rsi + rdx + 4]
    and ax, 0x07FF
    test ax, ax
    jnz .in_mps
    mov ax, 1024
.in_mps:
    mov [rtl8156_bulk_in_mps], ax
    ; Peek at the descriptor immediately after this EP descriptor. If it is
    ; a SuperSpeed Endpoint Companion (type 0x30, length 6) grab bMaxBurst
    ; (offset 2). Required by xHCI for SS bulk endpoints - without it the
    ; chip's burst attempts are dropped and IN tokens return zero bytes
    ; forever.
    movzx eax, byte [rsi + rdx]           ; EP desc length (usually 7)
    ; SECURITY (GSEC G1): only peek the SS Endpoint Companion when the full
    ; 6-byte companion lies within the device-declared wTotalLength (ecx).
    ; Otherwise a truncated descriptor list makes this peek read stale control-
    ; buffer bytes past the declared total and latch them as bMaxBurst.
    mov r9d, edx
    add r9d, eax
    add r9d, 6
    cmp r9d, ecx
    ja .next
    mov r8, rsi
    add r8, rdx
    add r8, rax                           ; next descriptor
    movzx r9d, byte [r8 + 0]
    cmp r9d, 6
    jb .next
    cmp byte [r8 + 1], 0x30               ; SS EP Companion
    jne .next
    mov al, [r8 + 2]
    mov [rtl8156_bulk_in_burst], al
    jmp .next
.out_ep:
    mov [rtl8156_bulk_out_addr], al
    mov ax, [rsi + rdx + 4]
    and ax, 0x07FF
    test ax, ax
    jnz .out_mps
    mov ax, 1024
.out_mps:
    mov [rtl8156_bulk_out_mps], ax
    movzx eax, byte [rsi + rdx]
    ; SECURITY (GSEC G1): same SS-companion bound as the IN-endpoint peek above.
    mov r9d, edx
    add r9d, eax
    add r9d, 6
    cmp r9d, ecx
    ja .next
    mov r8, rsi
    add r8, rdx
    add r8, rax
    movzx r9d, byte [r8 + 0]
    cmp r9d, 6
    jb .next
    cmp byte [r8 + 1], 0x30
    jne .next
    mov al, [r8 + 2]
    mov [rtl8156_bulk_out_burst], al
.next:
    movzx eax, byte [rsi + rdx]
    add edx, eax
    jmp .parse
.check:
    cmp byte [rtl8156_bulk_in_addr], 0
    je .nf
    cmp byte [rtl8156_bulk_out_addr], 0
    je .nf
    mov eax, 1
    ret
.nf:
    xor eax, eax
    ret

rtl8156_configure_bulk_eps:
    push rbx
    push rcx
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15

    movzx eax, byte [rtl8156_bulk_out_addr]
    and eax, 0x7F
    shl eax, 1
    mov [rtl8156_bulk_out_dci], al
    movzx eax, byte [rtl8156_bulk_in_addr]
    and eax, 0x7F
    shl eax, 1
    inc eax
    mov [rtl8156_bulk_in_dci], al

    mov rdi, XHCI_INPUT_CTX_ADDR
    push rdi
    mov ecx, 4096 / 8
    xor eax, eax
    rep stosq
    pop rdi

    movzx eax, byte [rtl8156_bulk_out_dci]
    mov ebx, 1
    mov ecx, eax
    shl ebx, cl
    movzx eax, byte [rtl8156_bulk_in_dci]
    mov edx, 1
    mov ecx, eax
    shl edx, cl
    or ebx, edx
    or ebx, 1
    mov [rdi + 4], ebx

    movzx ecx, byte [xhci_ctx_stride]
    lea rsi, [rdi + rcx]
    mov rbx, XHCI_DEV_CTX_ADDR
    mov eax, [rbx + 0]
    and eax, ~(0x1F << 27)
    ; Context Entries = max(IN dci, OUT dci). Previously we used only IN dci
    ; which left OUT (DCI 4) outside the valid range when IN dci was 3.
    movzx edx, byte [rtl8156_bulk_in_dci]
    movzx r8d, byte [rtl8156_bulk_out_dci]
    cmp r8d, edx
    jbe .have_max_dci
    mov edx, r8d
.have_max_dci:
    shl edx, 27
    or eax, edx
    mov [rsi + 0], eax
    mov eax, [rbx + 4]
    mov [rsi + 4], eax
    mov eax, [rbx + 8]
    mov [rsi + 8], eax
    mov eax, [rbx + 12]
    mov [rsi + 12], eax

    mov r12d, RTL8156_BULK_OUT_RING_ADDR
    movzx r13d, word [rtl8156_bulk_out_mps]
    movzx r14d, byte [rtl8156_bulk_out_dci]
    mov r15d, XHCI_EP_BULK_OUT
    call rtl8156_write_ep_ctx

    mov r12d, RTL8156_BULK_IN_RING_ADDR
    movzx r13d, word [rtl8156_bulk_in_mps]
    movzx r14d, byte [rtl8156_bulk_in_dci]
    mov r15d, XHCI_EP_BULK_IN
    call rtl8156_write_ep_ctx

    call rtl8156_init_bulk_rings

    mov r8d, XHCI_INPUT_CTX_ADDR
    xor r9d, r9d
    xor r10d, r10d
    movzx eax, byte [xhci_slot_id]
    shl eax, 24
    or eax, TRB_CONFIG_EP
    mov r11d, eax
    call xhci_submit_cmd
    cmp eax, 1
    jne .fail

    ; Dump the post-Configure Device Context for the IN endpoint so we can
    ; see whether xHCI accepted our EP context (State field bits[2:0] of
    ; dword 0: 1=Running, 2=Halted, 3=Stopped, 4=Error). Also dump dword 1
    ; (MPS<<16 | MaxBurst<<8 | EPType<<3) so we can verify the values stuck.
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    movzx ecx, byte [xhci_ctx_stride]
    movzx eax, byte [rtl8156_bulk_in_dci]
    imul eax, ecx                  ; DEV_CTX has no Input Control prefix
    lea rsi, [RTL8156_XHCI_DEV_CTX_ADDR + rax]
    lea rdi, [rel ser_ep_ctx_in]
    push rsi
    mov rsi, rdi
    call rtl8156_ser_puts
    pop rsi
    mov eax, [rsi + 0]
    push rax
    shr eax, 24
    call rtl8156_ser_phex8
    pop rax
    push rax
    shr eax, 16
    call rtl8156_ser_phex8
    pop rax
    push rax
    shr eax, 8
    call rtl8156_ser_phex8
    pop rax
    call rtl8156_ser_phex8
    mov dx, 0x3F8
    mov al, ' '
    out dx, al
    mov eax, [rsi + 4]
    push rax
    shr eax, 24
    call rtl8156_ser_phex8
    pop rax
    push rax
    shr eax, 16
    call rtl8156_ser_phex8
    pop rax
    push rax
    shr eax, 8
    call rtl8156_ser_phex8
    pop rax
    call rtl8156_ser_phex8
    mov al, 10
    out dx, al
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax

    mov eax, 1
    jmp .done
.fail:
    xor eax, eax
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; R12D=ring, R13D=mps, R14D=dci, R15D=xhci ep type.
rtl8156_write_ep_ctx:
    push rax
    push rcx
    push rdx
    push rsi
    movzx ecx, byte [xhci_ctx_stride]
    mov eax, r14d
    inc eax
    imul eax, ecx
    lea rsi, [XHCI_INPUT_CTX_ADDR + rax]
    mov dword [rsi + 0], 0
    mov eax, (3 << 1)
    mov ecx, r15d
    shl ecx, 3
    or eax, ecx
    mov ecx, r13d
    shl ecx, 16
    or eax, ecx
    ; Max Burst Size (bits 15:8). For SuperSpeed bulk endpoints this MUST
    ; match the SS Endpoint Companion's bMaxBurst; otherwise xHCI rejects
    ; the device's burst attempts and IN tokens come back empty forever.
    cmp r15d, XHCI_EP_BULK_IN
    jne .burst_out
    movzx edx, byte [rtl8156_bulk_in_burst]
    jmp .burst_apply
.burst_out:
    cmp r15d, XHCI_EP_BULK_OUT
    jne .burst_done
    movzx edx, byte [rtl8156_bulk_out_burst]
.burst_apply:
    and edx, 0xFF
    shl edx, 8
    or eax, edx
.burst_done:
    mov [rsi + 4], eax
    mov eax, r12d
    or eax, 1
    mov [rsi + 8], eax
    mov dword [rsi + 12], 0
    mov eax, 1514
    mov ecx, r13d
    shl ecx, 16
    or eax, ecx
    mov [rsi + 16], eax
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

rtl8156_init_bulk_rings:
    push rax
    push rcx
    push rdi
    mov rdi, RTL8156_BULK_IN_RING_ADDR
    mov ecx, XHCI_RING_SIZE * XHCI_TRB_SIZE / 8
    xor eax, eax
    rep stosq
    mov rdi, RTL8156_BULK_OUT_RING_ADDR
    mov ecx, XHCI_RING_SIZE * XHCI_TRB_SIZE / 8
    rep stosq
    mov rdi, RTL8156_BULK_IN_RING_ADDR
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], RTL8156_BULK_IN_RING_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC
    mov rdi, RTL8156_BULK_OUT_RING_ADDR
    lea rax, [rdi + (XHCI_RING_SIZE - 1) * XHCI_TRB_SIZE]
    mov qword [rax], RTL8156_BULK_OUT_RING_ADDR
    mov dword [rax + 8], 0
    mov dword [rax + 12], TRB_LINK | TRB_TC
    mov dword [rtl8156_bulk_in_enqueue], 0
    mov dword [rtl8156_bulk_out_enqueue], 0
    mov byte [rtl8156_bulk_in_cycle], 1
    mov byte [rtl8156_bulk_out_cycle], 1
    pop rdi
    pop rcx
    pop rax
    ret
