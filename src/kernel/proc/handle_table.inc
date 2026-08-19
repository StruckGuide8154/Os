; ============================================================================
; Grit - Per-slot opaque handle table
;
; SECURITY MODEL
; --------------
; Ring 3 receives only packed u32 handle values. The authoritative table that
; maps those values to kernel payloads lives in KERNEL BSS, not in the app slot.
; An app can therefore mutate every byte of its writable arena without being
; able to forge a kind, generation, flags, or payload.
;
; The previous implementation stored the authoritative table at
; slot+L3_HANDLE_TABLE_OFF. That page is USER-accessible and W+NX for the active
; slot, so treating it as "kernel-owned" was not a real privilege boundary.
; Keeping the same public ABI while moving authority here closes that gap and
; gives VFS a sound capability substrate.
;
; Public ABI is unchanged:
;   handle_table_clear(RDI=slot_base)
;   handle_alloc(RDI=slot_base, AL=kind, R8=payload) -> EAX handle/0
;   handle_resolve(RDI=slot_base, EDX=handle, AL=kind) -> EAX 1/0, R8 payload
;   handle_close(RDI=slot_base, EDX=handle, AL=kind) -> EAX 1/0
;   handle_seal(RDI=slot_base, EDX=handle, AL=kind) -> EAX 1/0
;   handle_is_sealed(...) -> EAX 1/0
;   handle_set_quota(EDI=slot, ESI=quota)
;
; Generation is bumped on table clear, close, and allocation. A slot recycle
; therefore cannot immediately revive a stale handle from the previous app.
; ============================================================================

global handle_table_clear
global handle_alloc
global handle_resolve
global handle_close
global handle_seal
global handle_is_sealed
global handle_set_quota
global slot_handle_quota

; ---------------------------------------------------------------------------
; handle_slot_id_from_base
;   RDI = trusted slot base returned by l3_slot_base
; Returns R11D = slot index, or APP_SLOT_COUNT for an invalid/non-aligned base.
; Preserves every register except R11.
; ---------------------------------------------------------------------------
handle_slot_id_from_base:
    push rax
    push rdx
    mov r11d, APP_SLOT_COUNT

    mov rax, [rel l3_app_arena_base_v]
    cmp rdi, rax
    jb .hsib_done
    mov rdx, rdi
    sub rdx, rax

    ; APP_SLOT_SIZE is 2 MiB and power-of-two. Reject a pointer into the middle
    ; of a slot rather than silently rounding it down to an authority domain.
    test rdx, APP_SLOT_SIZE - 1
    jnz .hsib_done
    mov rax, rdx
    shr rax, 21                       ; APP_SLOT_SIZE == 0x200000
    cmp eax, APP_SLOT_COUNT
    jae .hsib_done
    mov r11d, eax

.hsib_done:
    pop rdx
    pop rax
    ret

; ---------------------------------------------------------------------------
; handle_table_locate
;   RDI = slot base
; Returns EAX=1, R10D=slot id, R11=kernel table base; EAX=0 on invalid base.
; Clobbers RAX/R10/R11 only.
; ---------------------------------------------------------------------------
handle_table_locate:
    call handle_slot_id_from_base
    cmp r11d, APP_SLOT_COUNT
    jae .htl_fail
    mov r10d, r11d
    mov eax, r10d
    imul rax, L3_HANDLE_TABLE_SZ
    lea r11, [rel kernel_handle_tables]
    add r11, rax
    mov eax, 1
    ret
.htl_fail:
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
; handle_bump_generation
;   RDI = kernel handle-entry pointer
; Returns AX = new non-zero generation. Clobbers EAX only.
; ---------------------------------------------------------------------------
handle_bump_generation:
    movzx eax, word [rdi + HANDLE_ENT_GEN_OFF]
    inc eax
    cmp eax, HANDLE_GEN_MASK
    jbe .hbg_ok
    mov eax, 1
.hbg_ok:
    mov word [rdi + HANDLE_ENT_GEN_OFF], ax
    ret

; ---------------------------------------------------------------------------
; handle_table_clear
; Clear one slot's authoritative table while INVALIDATING every generation.
; The old implementation memset the generation back to zero, which allowed the
; first same-kind allocation after a slot recycle to recreate generation 1.
; Here every entry advances before becoming free.
; ---------------------------------------------------------------------------
handle_table_clear:
    push rax
    push rcx
    push rdi
    push r10
    push r11

    call handle_table_locate
    test eax, eax
    jz .htc_done

    mov rdi, r11
    mov ecx, HANDLE_TABLE_CAP
.htc_loop:
    call handle_bump_generation
    mov byte [rdi + HANDLE_ENT_KIND_OFF], HANDLE_KIND_NONE
    mov byte [rdi + HANDLE_ENT_FLAGS_OFF], 0
    mov dword [rdi + 4], 0
    mov qword [rdi + HANDLE_ENT_PAYLOAD_OFF], 0
    add rdi, L3_HANDLE_ENTRY_SIZE
    dec ecx
    jnz .htc_loop

.htc_done:
    pop r11
    pop r10
    pop rdi
    pop rcx
    pop rax
    ret

; ---------------------------------------------------------------------------
; handle_alloc
;   RDI = slot base
;   AL  = non-zero HANDLE_KIND_*
;   R8  = kernel-owned payload
; Returns EAX = packed handle, or 0.
;
; The authoritative entry is written only to kernel_handle_tables[]. Quota is
; also kernel BSS. No USER_ACCESS_BEGIN/END is required on this path.
; ---------------------------------------------------------------------------
handle_alloc:
    test al, al
    jz .ha_fail

    push rdi
    push rsi
    push r8
    push r12
    push r13
    movzx r12d, al                    ; requested kind
    mov r13, r8                       ; payload survives helper calls

    call handle_table_locate
    test eax, eax
    jz .ha_fail_pushed

    ; Per-slot live-handle quota.
    lea rax, [rel slot_handle_quota]
    movzx r9d, byte [rax + r10]
    test r9d, r9d
    jnz .ha_have_quota
    mov r9d, HANDLE_DEFAULT_QUOTA
.ha_have_quota:

    xor ecx, ecx                      ; index
    xor edx, edx                      ; live count
    mov rsi, r11
.ha_count:
    cmp byte [rsi + HANDLE_ENT_KIND_OFF], HANDLE_KIND_NONE
    je .ha_count_next
    inc edx
.ha_count_next:
    add rsi, L3_HANDLE_ENTRY_SIZE
    inc ecx
    cmp ecx, HANDLE_TABLE_CAP
    jb .ha_count
    cmp edx, r9d
    jae .ha_fail_pushed

    ; First free entry.
    xor ecx, ecx
    mov rsi, r11
.ha_scan:
    cmp byte [rsi + HANDLE_ENT_KIND_OFF], HANDLE_KIND_NONE
    je .ha_found
    add rsi, L3_HANDLE_ENTRY_SIZE
    inc ecx
    cmp ecx, HANDLE_TABLE_CAP
    jb .ha_scan
    jmp .ha_fail_pushed

.ha_found:
    mov rdi, rsi
    call handle_bump_generation       ; AX = fresh generation
    mov r8d, eax                      ; save generation while filling entry
    mov byte [rsi + HANDLE_ENT_KIND_OFF], r12b
    mov byte [rsi + HANDLE_ENT_FLAGS_OFF], 0
    mov dword [rsi + 4], 0
    mov [rsi + HANDLE_ENT_PAYLOAD_OFF], r13

    ; Pack magic(2) | kind(8) | generation(16) | index(6).
    mov edx, r12d
    shl edx, HANDLE_KIND_SHIFT
    mov r9d, r8d
    shl r9d, HANDLE_GEN_SHIFT
    or edx, r9d
    or edx, ecx
    mov eax, HANDLE_MAGIC
    shl eax, HANDLE_MAGIC_SHIFT
    or eax, edx
    jmp .ha_done

.ha_fail_pushed:
    xor eax, eax
.ha_done:
    pop r13
    pop r12
    pop r8
    pop rsi
    pop rdi
    ret

.ha_fail:
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
; handle_resolve
;   RDI = slot base
;   EDX = untrusted ring-3 handle
;   AL  = expected kind
; Returns EAX=1 and R8=payload on success; EAX=0 and original R8 on failure.
;
; Validation order is deliberately cheap-to-expensive: packed scalar fields
; first, then slot lookup, then the authoritative kernel entry.
; ---------------------------------------------------------------------------
handle_resolve:
    push rdi
    push rsi
    push r8                           ; overwritten with payload on success
    push r12
    push r13
    push r14

    movzx r12d, al                    ; expected kind
    mov r13d, edx                     ; preserve untrusted handle
    test r12d, r12d
    jz .hr_fail

    ; Magic.
    mov ecx, r13d
    shr ecx, HANDLE_MAGIC_SHIFT
    and ecx, HANDLE_MAGIC_MASK
    cmp ecx, HANDLE_MAGIC
    jne .hr_fail

    ; Index.
    mov r14d, r13d
    and r14d, HANDLE_INDEX_MASK
    cmp r14d, HANDLE_TABLE_CAP
    jae .hr_fail

    ; Kind carried in the handle must match the expected syscall kind.
    mov ecx, r13d
    shr ecx, HANDLE_KIND_SHIFT
    and ecx, HANDLE_KIND_MASK
    cmp ecx, r12d
    jne .hr_fail

    ; Generation carried in the handle.
    mov r9d, r13d
    shr r9d, HANDLE_GEN_SHIFT
    and r9d, HANDLE_GEN_MASK
    test r9d, r9d
    jz .hr_fail

    call handle_table_locate
    test eax, eax
    jz .hr_fail

    mov ecx, r14d
    imul rcx, L3_HANDLE_ENTRY_SIZE
    add rcx, r11                      ; RCX = authoritative kernel entry

    movzx edx, byte [rcx + HANDLE_ENT_KIND_OFF]
    cmp edx, r12d
    jne .hr_fail
    movzx edx, word [rcx + HANDLE_ENT_GEN_OFF]
    cmp edx, r9d
    jne .hr_fail

    mov rax, [rcx + HANDLE_ENT_PAYLOAD_OFF]
    mov [rsp + 24], rax               ; replace saved R8 with success payload
    mov eax, 1
    jmp .hr_done

.hr_fail:
    xor eax, eax
.hr_done:
    pop r14
    pop r13
    pop r12
    pop r8
    pop rsi
    pop rdi
    ret

; ---------------------------------------------------------------------------
; handle_close
; Resolve exact kind/generation, then free and bump generation immediately.
; ---------------------------------------------------------------------------
handle_close:
    push rdi
    push rsi
    push r8
    push r12
    push r13
    movzx r12d, al
    mov r13d, edx

    call handle_resolve
    test eax, eax
    jz .hc_fail
    call handle_table_locate
    test eax, eax
    jz .hc_fail

    mov ecx, r13d
    and ecx, HANDLE_INDEX_MASK
    imul rcx, L3_HANDLE_ENTRY_SIZE
    add rcx, r11
    mov rdi, rcx
    call handle_bump_generation
    mov byte [rcx + HANDLE_ENT_KIND_OFF], HANDLE_KIND_NONE
    mov byte [rcx + HANDLE_ENT_FLAGS_OFF], 0
    mov dword [rcx + 4], 0
    mov qword [rcx + HANDLE_ENT_PAYLOAD_OFF], 0
    mov eax, 1
    jmp .hc_done
.hc_fail:
    xor eax, eax
.hc_done:
    pop r13
    pop r12
    pop r8
    pop rsi
    pop rdi
    ret

; ---------------------------------------------------------------------------
; handle_set_quota
; EDI=slot index, ESI=requested quota. 0 means "unset/default" as before.
; ---------------------------------------------------------------------------
handle_set_quota:
    cmp edi, APP_SLOT_COUNT
    jae .hsq_done
    mov eax, esi
    cmp eax, HANDLE_TABLE_CAP
    jbe .hsq_clamped
    mov eax, HANDLE_TABLE_CAP
.hsq_clamped:
    lea rdx, [rel slot_handle_quota]
    mov byte [rdx + rdi], al
.hsq_done:
    ret

; ---------------------------------------------------------------------------
; handle_seal
; Mark an exact live handle as non-transferable. Flags are authoritative because
; they are stored in kernel BSS alongside the payload.
; ---------------------------------------------------------------------------
handle_seal:
    push rdi
    push rsi
    push r8
    push r12
    push r13
    movzx r12d, al
    mov r13d, edx

    call handle_resolve
    test eax, eax
    jz .hsl_fail
    call handle_table_locate
    test eax, eax
    jz .hsl_fail
    mov ecx, r13d
    and ecx, HANDLE_INDEX_MASK
    imul rcx, L3_HANDLE_ENTRY_SIZE
    add rcx, r11
    or byte [rcx + HANDLE_ENT_FLAGS_OFF], HANDLE_FLAG_SEALED
    mov eax, 1
    jmp .hsl_done
.hsl_fail:
    xor eax, eax
.hsl_done:
    pop r13
    pop r12
    pop r8
    pop rsi
    pop rdi
    ret

; ---------------------------------------------------------------------------
; handle_is_sealed
; Returns 1 only if the handle resolves and its authoritative kernel entry is
; sealed. Invalid handles return 0; callers that need to distinguish invalid
; from unsealed must call handle_resolve separately, matching the old contract.
; ---------------------------------------------------------------------------
handle_is_sealed:
    push rdi
    push rsi
    push r8
    push r12
    push r13
    movzx r12d, al
    mov r13d, edx

    call handle_resolve
    test eax, eax
    jz .his_no
    call handle_table_locate
    test eax, eax
    jz .his_no
    mov ecx, r13d
    and ecx, HANDLE_INDEX_MASK
    imul rcx, L3_HANDLE_ENTRY_SIZE
    add rcx, r11
    movzx eax, byte [rcx + HANDLE_ENT_FLAGS_OFF]
    and eax, HANDLE_FLAG_SEALED
    jz .his_no
    mov eax, 1
    jmp .his_done
.his_no:
    xor eax, eax
.his_done:
    pop r13
    pop r12
    pop r8
    pop rsi
    pop rdi
    ret

; ---------------------------------------------------------------------------
; Authoritative handle state. Both arrays are supervisor-only kernel BSS.
; 12 slots * 64 entries * 16 bytes = 12 KiB, fixed and allocation-free.
; ---------------------------------------------------------------------------
section .bss
align 16
kernel_handle_tables: resb APP_SLOT_COUNT * L3_HANDLE_TABLE_SZ
slot_handle_quota:    resb APP_SLOT_COUNT
section .text
