; ============================================================================
; Installable-driver syscall wrappers.
;
; r15 is derived from the caller RIP by syscall entry and is authoritative.
; No wrapper accepts a driver_id or policy mask from ring 3. Grant creation,
; DMA mapping, and IRQ routing remain device-manager control-plane operations.
; ============================================================================

.sc_drvhost_denied:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; REGISTER(requested_caps). Policy and image identity are kernel-owned.
.sc_drvhost_register:
    mov rsi, rdi
    movzx edi, r15b
    call drvhost_register_slot
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_mmio_read32:
    push rdi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_mmio_read32
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_mmio_write32:
    push rdi
    push rsi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rdx
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_mmio_write32
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_pio_read8:
    push rdi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_pio_read8
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_pio_write8:
    push rdi
    push rsi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rdx
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_pio_write8
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_pci_cfg_read32:
    push rdi
    push rsi
    push rdx
    push r10
    movzx edi, r15b
    call drvhost_id_for_slot
    test eax, eax
    jz .sc_drvhost_pci_cfg_denied
    mov rdi, rax
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 8]
    mov r8,  [rsp + 0]
    call drvhost_pci_cfg_read32
    add rsp, 32
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_drvhost_pci_cfg_denied:
    add rsp, 32
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_drvhost_ring_establish:
    push rdi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_ring_establish
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_ring_submit:
    ; Dispatcher validates the complete count*16 writable descriptor span.
    push rdi
    push rsi
    movzx edi, r15b
    call drvhost_id_for_slot
    test eax, eax
    jz .sc_drvhost_ring_denied
    mov rdi, rax
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 0]
    USER_ACCESS_BEGIN
    call drvhost_ring_submit
    USER_ACCESS_END
    add rsp, 16
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_drvhost_ring_denied:
    add rsp, 16
    mov qword [rsp + ALL_RAX], -1
    jmp .done
