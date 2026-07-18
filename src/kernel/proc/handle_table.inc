; ============================================================================
; Grit - Per-slot handle table (pointer-table refactor)
;
; Primitives for the opaque-handle ABI that replaces raw kernel pointers
; across the syscall boundary. As of Phase 2:
;   - SYS_FS_ENTRY returns a packed HANDLE_KIND_DIR_ENTRY handle (see
;     syscall.asm .sc_fs_entry). The legacy per-slot snapshot cache is gone.
;   - The FN_KIND_HANDLE validator arm in sc_validate_from_table calls
;     handle_resolve; FS syscall handlers translate handle -> kernel
;     entry pointer via sc_resolve_dir_entry_arg.
;   - SYS_HANDLE_CLOSE wraps handle_close; SYS_FS_ENTRY_INFO copies the
;     entry fields by value so kernel VAs never leak to ring 3.
;
; Future kinds (XML node, net socket, window) reuse these primitives by
; allocating with a different HANDLE_KIND_* tag - the validator arm picks
; the expected kind from the syscall table's argument descriptor.
;
; All operations are slot-local and lock-free: each slot's table is touched
; only by its own ring-3 process (one core at a time per slot) so no atomic
; sequencing is required. If that invariant ever changes, switch the
; allocator's kind-byte write to a `lock cmpxchg`.
;
; Encoding and per-entry layout: see boot_memory.inc.
; ============================================================================

; Exposed to usermode.asm (slot init) and syscall.asm (Phase 2 will call
; alloc/resolve/close from the FS syscall handlers).
global handle_table_clear
global handle_alloc
global handle_resolve
global handle_close
global handle_seal
global handle_set_quota
global slot_handle_quota

; ---------------------------------------------------------------------------
; handle_table_clear - zero this slot's handle table.
;   RDI = slot base ptr (as returned by l3_slot_base).
; Clobbers: RAX, RCX, RDI. Preserves all other regs.
; ---------------------------------------------------------------------------
handle_table_clear:
    push rdi
    push rcx
    push rax
    add rdi, L3_HANDLE_TABLE_OFF
    xor eax, eax
    mov ecx, L3_HANDLE_TABLE_SZ / 8
    cld
    USER_ACCESS_BEGIN                ; SMAP: table page is PTE.U=1 slot memory
    rep stosq
    USER_ACCESS_END
    pop rax
    pop rcx
    pop rdi
    ret

; ---------------------------------------------------------------------------
; handle_alloc - reserve a fresh handle in this slot's table.
;   RDI = slot base ptr
;   AL  = kind (must be non-zero; see HANDLE_KIND_*)
;   R8  = payload (kind-specific, e.g. valid-entry index for DIR_ENTRY)
; Returns:
;   EAX = packed handle (non-zero), or 0 if the slot is at quota, the table is
;         full, or kind == 0.
; Clobbers: RAX, RCX, RDX, R9, R10, R11. Preserves RDI/RSI/R8.
;
; Linear scan for an entry with kind == HANDLE_KIND_NONE. On reuse, the
; stored generation is incremented (skipping 0 on wrap) so a stale handle
; from the previous occupant resolves as mismatched.
;
; Quota: the slot's soft cap (slot_handle_quota[slot]) is enforced first - the
; allocator counts currently-live entries and fails if issuing one more would
; exceed the quota. HANDLE_TABLE_CAP remains the hard physical ceiling.
; ---------------------------------------------------------------------------
handle_alloc:
    test al, al
    jz .ha_fail
    push rdi
    push rsi
    mov r10b, al                     ; r10b = requested kind
    ; --- per-slot quota gate: count live entries, deny once at cap ---
    call handle_slot_id_from_base    ; r11d = slot id (RDI = slot base)
    movzx r11d, byte [abs slot_handle_quota + r11]   ; r11d = quota
    test r11d, r11d                  ; 0 = unset -> default (full capacity)
    jnz .ha_have_quota
    mov r11d, HANDLE_DEFAULT_QUOTA
.ha_have_quota:
    add rdi, L3_HANDLE_TABLE_OFF     ; rdi = entry walker
    xor ecx, ecx                     ; ecx = index
    xor edx, edx                     ; edx = live count
.ha_count:
    USER_ACCESS_BEGIN                ; SMAP: table page is PTE.U=1 slot memory
    cmp byte [rdi + HANDLE_ENT_KIND_OFF], HANDLE_KIND_NONE
    USER_ACCESS_END
    je .ha_count_next
    inc edx
.ha_count_next:
    add rdi, L3_HANDLE_ENTRY_SIZE
    inc ecx
    cmp ecx, HANDLE_TABLE_CAP
    jb .ha_count
    cmp edx, r11d                    ; live >= quota?
    jae .ha_quota_full
    ; --- second pass: find the first free entry ---
    ; Slot base was pushed first (line above), then RSI, so it now lives at
    ; [rsp+8]; [rsp] holds the saved RSI. Reading [rsp] here pointed the scan
    ; (and the kind/payload writes) at RSI+table_off instead of the real table,
    ; so handle_resolve always read kind=0 and every FN_KIND_HANDLE arg was
    ; rejected (explorer "no files" + handle-table leak).
    mov rdi, [rsp + 8]               ; reload slot base
    add rdi, L3_HANDLE_TABLE_OFF     ; rdi = entry walker
    xor ecx, ecx                     ; ecx = index
.ha_scan:
    USER_ACCESS_BEGIN                ; SMAP: table page is PTE.U=1 slot memory
    cmp byte [rdi + HANDLE_ENT_KIND_OFF], HANDLE_KIND_NONE
    USER_ACCESS_END
    je .ha_found
    add rdi, L3_HANDLE_ENTRY_SIZE
    inc ecx
    cmp ecx, HANDLE_TABLE_CAP
    jb .ha_scan
.ha_quota_full:
    ; at quota or table full
    pop rsi
    pop rdi
    jmp .ha_fail
.ha_found:
    ; Bump generation (wraps 0xFFFF -> 1 so a valid generation never == 0).
    USER_ACCESS_BEGIN                ; SMAP: table page is PTE.U=1 slot memory
    movzx eax, word [rdi + HANDLE_ENT_GEN_OFF]
    inc eax
    cmp eax, HANDLE_GEN_MASK
    jbe .ha_gen_ok
    mov eax, 1
.ha_gen_ok:
    mov word [rdi + HANDLE_ENT_GEN_OFF], ax
    mov byte [rdi + HANDLE_ENT_KIND_OFF], r10b
    mov byte [rdi + HANDLE_ENT_FLAGS_OFF], 0
    mov dword [rdi + HANDLE_ENT_KIND_OFF + 4], 0   ; reserved u32
    mov [rdi + HANDLE_ENT_PAYLOAD_OFF], r8
    USER_ACCESS_END
    ; Pack: magic(2) | kind(8) | gen(16) | index(6)
    movzx edx, r10b                   ; kind
    shl edx, HANDLE_KIND_SHIFT
    movzx r9d, ax                     ; gen
    shl r9d, HANDLE_GEN_SHIFT
    or  edx, r9d
    or  edx, ecx                      ; index (already in low 6 bits)
    mov eax, HANDLE_MAGIC
    shl eax, HANDLE_MAGIC_SHIFT
    or  eax, edx
    pop rsi
    pop rdi
    ret
.ha_fail:
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
; handle_resolve - verify a ring-3 handle and return its payload.
;   RDI = slot base ptr
;   EDX = handle (untrusted)
;   AL  = expected kind
; Returns:
;   EAX = 1 + R8 = payload  on success
;   EAX = 0                 on any mismatch / out-of-range / wrong magic
; Clobbers: RAX, RCX, RDX, R9, R10. Preserves RDI/RSI/R8 on failure;
; on success R8 holds the resolved payload.
; ---------------------------------------------------------------------------
handle_resolve:
    push rdi
    push rsi
    movzx r10d, al                    ; r10d = expected kind (zero-extended;
                                      ; the cmp below uses r10d so the upper
                                      ; bytes MUST be clean - `mov r10b, al`
                                      ; alone leaves caller garbage in
                                      ; r10[31:8] and rejects valid handles).
    ; Magic check (bits 31:30 must be 0b10).
    mov ecx, edx
    shr ecx, HANDLE_MAGIC_SHIFT
    and ecx, HANDLE_MAGIC_MASK
    cmp ecx, HANDLE_MAGIC
    jne .hr_fail
    ; Extract index, kind, gen.
    mov ecx, edx
    and ecx, HANDLE_INDEX_MASK        ; ecx = index
    cmp ecx, HANDLE_TABLE_CAP
    jae .hr_fail
    mov r9d, edx
    shr r9d, HANDLE_KIND_SHIFT
    and r9d, HANDLE_KIND_MASK         ; r9d = kind in handle
    movzx eax, r10b
    cmp r9d, eax
    jne .hr_fail
    mov r9d, edx
    shr r9d, HANDLE_GEN_SHIFT
    and r9d, HANDLE_GEN_MASK          ; r9d = gen in handle
    ; Locate entry.
    add rdi, L3_HANDLE_TABLE_OFF
    imul rcx, rcx, L3_HANDLE_ENTRY_SIZE
    add rdi, rcx
    ; Read stored kind/gen/payload in one SMAP bracket (table page is PTE.U=1
    ; slot memory). Payload goes to a scratch reg, not R8, so a later mismatch
    ; leaves R8 untouched per the "preserve R8 on failure" contract.
    USER_ACCESS_BEGIN
    movzx ecx, byte [rdi + HANDLE_ENT_KIND_OFF]
    movzx edx, word [rdi + HANDLE_ENT_GEN_OFF]
    mov rax, [rdi + HANDLE_ENT_PAYLOAD_OFF]
    USER_ACCESS_END
%ifdef ENABLE_DEBUG_SERIAL
    ; TEMP probe: dump stored-kind/expected-kind/stored-gen/handle-gen so we can
    ; see which comparison rejects a freshly-minted handle (explorer-no-files).
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    SER 'R'
    mov rdi, rcx                      ; stored kind
    call ser_print_hex64
    SER '/'
    mov rdi, r10                      ; expected kind
    call ser_print_hex64
    SER '@'
    mov rdi, [rsp + 24]               ; saved rdi = entry address read
    call ser_print_hex64
    SER '#'
    mov rdi, r15                      ; slot id used by resolve
    call ser_print_hex64
    SER 13
    SER 10
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
%endif
    cmp ecx, r10d                     ; stored kind must match expected
    jne .hr_fail
    cmp edx, r9d                      ; stored gen must match handle's gen
    jne .hr_fail
    mov r8, rax                       ; OK - commit payload
    pop rsi
    pop rdi
    mov eax, 1
    ret
.hr_fail:
    pop rsi
    pop rdi
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
; handle_close - release a handle in this slot's table.
;   RDI = slot base ptr
;   EDX = handle (untrusted)
;   AL  = expected kind (so close() can't free another kind's slot)
; Returns:
;   EAX = 1 on success, 0 on mismatch.
; ---------------------------------------------------------------------------
handle_close:
    push rdi
    push rsi
    push r8
    push rdx                          ; handle_resolve clobbers RDX
    call handle_resolve
    pop rdx
    test eax, eax
    jz .hc_done
    ; Re-walk to the entry and zero its kind. Generation is left alone -
    ; the allocator bumps it on the next reuse, so a stale handle from
    ; before this close still mismatches.
    mov ecx, edx
    and ecx, HANDLE_INDEX_MASK
    add rdi, L3_HANDLE_TABLE_OFF
    imul rcx, rcx, L3_HANDLE_ENTRY_SIZE
    add rdi, rcx
    xor r8, r8
    USER_ACCESS_BEGIN                ; SMAP: table page is PTE.U=1 slot memory
    mov byte [rdi + HANDLE_ENT_KIND_OFF], HANDLE_KIND_NONE
    mov [rdi + HANDLE_ENT_PAYLOAD_OFF], r8
    USER_ACCESS_END
    mov eax, 1
.hc_done:
    pop r8
    pop rsi
    pop rdi
    ret

; ---------------------------------------------------------------------------
; handle_slot_id_from_base - derive the 0-based slot index from a slot base
; ptr (as returned by l3_slot_base).
;   RDI = slot base ptr (preserved)
; Returns:
;   R11D = slot index (0..APP_SLOT_COUNT-1)
; Clobbers: R11. Preserves all other regs. Used to index the kernel-BSS
; per-slot quota array, which (unlike the table itself) must live outside
; ring-3-writable slot memory so an app can't widen its own quota.
; ---------------------------------------------------------------------------
handle_slot_id_from_base:
    push rax
    push rdx
    mov rax, rdi
    sub rax, [rel l3_app_arena_base_v]   ; byte offset into arena
    xor edx, edx
    mov r11, APP_SLOT_SIZE
    div r11                                ; rax = slot index
    mov r11d, eax
    pop rdx
    pop rax
    ret

; ---------------------------------------------------------------------------
; handle_set_quota - set a slot's soft max-FD quota (per-manifest §5).
;   EDI = slot index
;   ESI = requested quota
; The value is clamped to [0, HANDLE_TABLE_CAP] (the hard physical ceiling).
; Stored in kernel BSS so ring 3 cannot widen it. Call at slot init / manifest
; apply. Clobbers: none of the ABI regs beyond RAX. Preserves RDI/RSI.
; ---------------------------------------------------------------------------
handle_set_quota:
    cmp edi, APP_SLOT_COUNT
    jae .hsq_done
    mov eax, esi
    cmp eax, HANDLE_TABLE_CAP
    jbe .hsq_clamped
    mov eax, HANDLE_TABLE_CAP
.hsq_clamped:
    mov byte [abs slot_handle_quota + rdi], al
.hsq_done:
    ret

; ---------------------------------------------------------------------------
; handle_seal - mark a live handle non-transferable (§4 sealed capabilities).
; Once sealed, any transfer/duplication path (the FN_KIND_HANDLE validator arm
; and any future dup/grant syscall) must refuse it via handle_is_sealed.
;   RDI = slot base ptr
;   EDX = handle (untrusted)
;   AL  = expected kind
; Returns:
;   EAX = 1 on success, 0 on mismatch/out-of-range/wrong magic.
; Clobbers: RAX, RCX, RDX, R9, R10. Preserves RDI/RSI/R8.
; ---------------------------------------------------------------------------
handle_seal:
    push rdi
    push rsi
    push r8
    push rdx                          ; handle_resolve clobbers RDX
    call handle_resolve
    pop rdx
    test eax, eax
    jz .hsl_done
    mov ecx, edx
    and ecx, HANDLE_INDEX_MASK
    add rdi, L3_HANDLE_TABLE_OFF
    imul rcx, rcx, L3_HANDLE_ENTRY_SIZE
    add rdi, rcx
    USER_ACCESS_BEGIN                ; SMAP: table page is PTE.U=1 slot memory
    or byte [rdi + HANDLE_ENT_FLAGS_OFF], HANDLE_FLAG_SEALED
    USER_ACCESS_END
    mov eax, 1
.hsl_done:
    pop r8
    pop rsi
    pop rdi
    ret

; ---------------------------------------------------------------------------
; handle_is_sealed - query the sealed flag for a (resolved) handle. Transfer/
; duplication paths call this and must refuse when it returns 1, formalizing
; the slot-local rule: a sealed handle is bound to the slot it was issued to.
;   RDI = slot base ptr
;   EDX = handle (untrusted)
;   AL  = expected kind
; Returns:
;   EAX = 1 if the handle resolves AND is sealed, else 0. (A handle that fails
;         to resolve returns 0 here; callers should resolve separately.)
; Clobbers: RAX, RCX, RDX, R9, R10. Preserves RDI/RSI/R8.
; ---------------------------------------------------------------------------
global handle_is_sealed
handle_is_sealed:
    push rdi
    push rsi
    push r8
    push rdx
    call handle_resolve
    pop rdx
    test eax, eax
    jz .his_no
    mov ecx, edx
    and ecx, HANDLE_INDEX_MASK
    add rdi, L3_HANDLE_TABLE_OFF
    imul rcx, rcx, L3_HANDLE_ENTRY_SIZE
    add rdi, rcx
    USER_ACCESS_BEGIN
    movzx eax, byte [rdi + HANDLE_ENT_FLAGS_OFF]
    USER_ACCESS_END
    and eax, HANDLE_FLAG_SEALED
    jz .his_no
    mov eax, 1
    jmp .his_done
.his_no:
    xor eax, eax
.his_done:
    pop r8
    pop rsi
    pop rdi
    ret

; ---------------------------------------------------------------------------
; Per-slot soft FD quota (kernel BSS - NOT in ring-3-writable slot memory, so
; an app can't widen its own quota via a slot-memory write bug). A byte of 0
; means "unset" and handle_alloc treats it as HANDLE_DEFAULT_QUOTA (full
; capacity); a manifest narrows a slot via handle_set_quota (clamped to
; [0, HANDLE_TABLE_CAP]). BSS-zero therefore needs no boot seed.
; ---------------------------------------------------------------------------
section .bss
align 16
slot_handle_quota: resb APP_SLOT_COUNT
section .text
