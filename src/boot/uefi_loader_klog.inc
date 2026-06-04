; ============================================================================
; FLUSH_KLOG_IF_PENDING
; ----------------------------------------------------------------------------
; Checks the kernel-log flush region at 0x600000 for a magic header left
; behind by the previous boot's kernel (via F11). If present, writes the
; payload to \KLOG.TXT on the ESP and clears the magic so we do not write
; the same buffer again next boot.
;
; Layout at 0x600000:
;   +0  qword magic = 0x3130534E474F4C4B  ("KLOGNS01")
;   +8  qword payload length (bytes)
;   +16 payload (ASCII text)
;
; Non-fatal: any UEFI error simply skips the write and continues boot.
; ============================================================================
%define KLOG_FLUSH_ADDR_LO 0x600000
%define KLOG_MAGIC_QWORD   0x3130534E474F4C4B

flush_klog_if_pending:
    push rbx
    push r12
    push r13
    sub rsp, 64
    ; [rsp +  0..31] shadow
    ; [rsp + 32]     arg5
    ; [rsp + 40]     local: bytecount in/out
    ; [rsp + 48]     scratch

    SER 'k'                                  ; k = flush_klog entered

    ; --- Check magic ---
    mov rax, KLOG_MAGIC_QWORD
    cmp [abs KLOG_FLUSH_ADDR_LO], rax
    jne .fk_no_magic
    SER 'M'                                  ; M = magic found
    jmp .fk_have_magic
.fk_no_magic:
    SER 'm'                                  ; m = no magic
    jmp .fk_done
.fk_have_magic:

    mov r12, [abs KLOG_FLUSH_ADDR_LO + 8]   ; payload length
    test r12, r12
    jz .fk_clear                            ; empty payload, just clear magic
    cmp r12, 0x100000                       ; sanity cap 1 MB
    ja .fk_clear

    ; --- Reopen root volume ---
    mov rbx, [v_sfs]
    test rbx, rbx
    jz .fk_clear
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    test rax, rax
    jz .fk_root_ok
    SER 'R'                                  ; R = OpenVolume failed
    jmp .fk_clear
.fk_root_ok:

    ; --- Open \KLOG.TXT with CREATE|READ|WRITE ---
    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file]
    lea r8,  [s_klog_path]
    ; OpenMode = CREATE(0x8000000000000000) | READ(1) | WRITE(2) = 0x8000000000000003
    mov r9, 0x8000000000000003
    mov qword [rsp+32], 0                   ; Attributes = 0
    mov rax, [rbx + FP_OPEN]
    call rax
    test rax, rax
    jz .fk_open_ok
    SER 'O'                                  ; O = Open(KLOG.TXT) failed
    jmp .fk_close_root
.fk_open_ok:
    SER 'o'                                  ; o = Open succeeded

    ; --- Write payload ---
    mov [rsp+40], r12                        ; bytecount in
    mov rbx, [v_file]
    mov rcx, rbx
    lea rdx, [rsp+40]
    mov r8, KLOG_FLUSH_ADDR_LO + 16          ; payload ptr
    mov rax, [rbx + FP_WRITE]
    call rax
    test rax, rax
    jz .fk_write_ok
    SER 'X'                                  ; X = Write failed
    jmp .fk_close_file
.fk_write_ok:
    SER 'w'                                  ; w = Write succeeded
.fk_close_file:

    ; --- Close file ---
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax

.fk_close_root:
    mov rbx, [v_root]
    test rbx, rbx
    jz .fk_clear
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax

.fk_clear:
    ; Wipe the magic so we don't re-write next boot.
    xor eax, eax
    mov [abs KLOG_FLUSH_ADDR_LO], rax
    mov [abs KLOG_FLUSH_ADDR_LO + 8], rax

.fk_done:
    add rsp, 64
    pop r13
    pop r12
    pop rbx
    ret
