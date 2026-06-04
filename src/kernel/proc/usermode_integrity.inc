L3_CODE_HASH_FNV_OFFSET equ 0xCBF29CE484222325
L3_CODE_HASH_FNV_PRIME  equ 0x00000100000001B3

; l3_code_hash_compute - EDI = slot. Returns RAX = FNV-1a hash of the slot's
; executable code-range bytes (skipping the handle-table carve-out), or 0 if
; the slot has no valid v1 manifest / an empty range. Preserves rbx,rcx,rdx,
; rsi,rdi,r8..r12 (clobbers only rax + the saved/restored temporaries).
FN_DECL l3_code_hash_compute, 0, 0, FN_RET_SCALAR
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

    mov r8d, edi                         ; r8d = slot
    cmp r8d, MAX_WINDOWS
    jae .ch_zero

    ; Require a committed v1 manifest with sane bounds (same gate as the policy
    ; walk). Anything else means "no code range to hash".
    mov eax, r8d
    cmp qword [l3_wx_manifest_ver + rax*8], 1
    jne .ch_zero
    mov rsi, [l3_wx_code_start + rax*8]   ; rsi = code_start offset
    mov rdx, [l3_wx_code_end + rax*8]     ; rdx = code_end offset (exclusive)
    cmp rsi, rdx
    jae .ch_zero

    ; r9 = slot base virtual address.
    mov edi, r8d
    call l3_slot_base
    mov r9, rax

    ; r10 = handle-table carve-out start offset, r11 = carve-out end offset
    ; (page-rounded, matching l3_apply_wx_policy's skip window).
    mov r10, L3_HANDLE_TABLE_OFF
    mov r11, (L3_HANDLE_TABLE_SZ + 0xFFF) & ~0xFFF
    add r11, r10

    mov r12, L3_CODE_HASH_FNV_OFFSET      ; r12 = running hash accumulator
    mov rcx, rsi                          ; rcx = current offset cursor

    ; SMAP: the slot is user (PTE.U=1) memory; bracket the byte reads.
    USER_ACCESS_BEGIN
.ch_loop:
    cmp rcx, rdx
    jae .ch_loop_done
    ; Skip the handle-table carve-out [r10, r11): mutable kernel data, not code.
    cmp rcx, r10
    jb .ch_present_check
    cmp rcx, r11
    jb .ch_skip
.ch_present_check:
    ; Only fold bytes from PRESENT pages. A non-present page in the range
    ; (e.g. a guard or never-populated page) would #PF in ring 0 here ??? and it
    ; holds no executable bytes anyway ??? so skip the whole page. PT entry for
    ; this offset = APP_ARENA_PT_BASE + slot*ARENA_SLOT_PAGES*8 + (off>>12)*8.
    mov rbx, rcx
    shr rbx, 12                           ; page index within slot
    mov eax, r8d
    imul rax, ARENA_SLOT_PAGES * 8
    lea rbx, [rax + rbx*8 + APP_ARENA_PT_BASE]
    mov rax, [rbx]
    test al, 1                            ; PAGE_PRESENT?
    jz .ch_skip_page
    ; rax held the PTE (scratch); the running hash lives in r12 across the loop.
    movzx ebx, byte [r9 + rcx]            ; slot byte
    xor r12, rbx                          ; FNV-1a: hash ^= byte
    mov rbx, L3_CODE_HASH_FNV_PRIME
    imul r12, rbx                         ; hash *= prime
    inc rcx
    jmp .ch_loop
.ch_skip_page:
    ; Advance rcx to the next page boundary (skip the whole absent page).
    or rcx, 0xFFF
    inc rcx
    jmp .ch_loop
.ch_skip:
    inc rcx
    jmp .ch_loop
.ch_loop_done:
    USER_ACCESS_END
    mov rax, r12                          ; final running hash
    jmp .ch_ret

.ch_zero:
    xor eax, eax                          ; no valid range -> hash 0
.ch_ret:
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
    ret

; l3_code_hash_install - EDI = slot. Capture the slot's code-range hash as the
; integrity baseline and mark it live. Idempotent re-baseline; preserves all
; caller registers.
FN_DECL l3_code_hash_install, 0, 0, FN_RET_SCALAR
    push rax
    push rcx
    push rdi
    mov ecx, edi                          ; ecx = slot (preserved across call)
    call l3_code_hash_compute             ; rax = hash
    mov [l3_code_hash + rcx*8], rax
    mov byte [l3_code_hash_valid + rcx], 1
    pop rdi
    pop rcx
    pop rax
    ret

; l3_code_hash_verify_all - re-hash every slot with a live baseline and panic
; on the first mismatch (an unintended W landed on a code page). Called from
; pit_handler on a tick cadence. Preserves all caller registers. Reached from
; IRQ context, hence FN_DECL (no trace push/call before we are sure of state).
extern kernel_panic_canary
FN_DECL l3_code_hash_verify_all, 0, 0, FN_RET_SCALAR
    push rax
    push rcx
    push rdx
    push rdi
    xor ecx, ecx                          ; slot index
.va_loop:
    cmp ecx, MAX_WINDOWS
    jae .va_done
    cmp byte [l3_code_hash_valid + rcx], 0
    je .va_next
    mov edx, ecx                          ; save slot across the call
    mov edi, ecx
    call l3_code_hash_compute             ; rax = recomputed hash
    mov ecx, edx
    cmp rax, [l3_code_hash + rcx*8]
    jne .va_mismatch
.va_next:
    inc ecx
    jmp .va_loop
.va_done:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret
.va_mismatch:
    ; Executable bytes diverged from the install-time baseline. Treat as a W^X
    ; integrity violation and take the same fail-closed path as a corrupted
    ; canary / forged callback. Never returns.
    jmp kernel_panic_canary

FN_DECL l3_install_app_done_trampoline, 0, 0, FN_RET_SCALAR
    push rcx
    mov ecx, edi
    call l3_slot_base
    add rax, [rel l3_slot_code_slide + rcx*8]
    add rax, app_l3_done_trampoline - app_blob_start
    pop rcx
    ret
