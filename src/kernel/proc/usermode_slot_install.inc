FN_BEGIN l3_copy_app_blob_to_slot, 0, 0, FN_RET_SCALAR
    push rcx
    push rdi
    push rsi
    push r8
    push r9
    mov r9d, edi
%ifdef ENABLE_SYSCALL_PERM
    ; Heterogeneous syscall numbering (security_todo.md ??12): this slot is about
    ; to be re-copied with RAW (un-permuted) syscall immediates, so UN-commit its
    ; permutation up front. While committed==0 the dispatcher maps every number
    ; identity (correct for the raw blob); sc_slot_perm_apply_blob re-commits only
    ; after re-baking. Clearing here (before the copy) closes the recycle window
    ; in which a sibling core could apply the old inverse to the new raw blob.
    movzx ecx, r9b
    lea rax, [rel sc_slot_perm_committed]
    mov byte [rax + rcx], 0
%endif
    ; Invalidate the code-range integrity baseline BEFORE touching the blob.
    ; l3_code_hash_verify_all runs from pit_handler (timer IRQ); if it fired
    ; while the rep movsb below is mid-overwrite, it would hash a half-copied
    ; blob and compare it against the PREVIOUS tenant's still-"valid" baseline
    ; -> spurious mismatch -> kernel_panic_canary ("CANARY 0 @..." at boot).
    ; Clearing the valid byte up front makes the verifier skip this slot for the
    ; whole copy+setup window; l3_apply_wx_policy re-captures the baseline once
    ; the new blob is in place. (The later clear near the manifest reset is now
    ; redundant but harmless.)
    movzx ecx, r9b
    mov byte [l3_code_hash_valid + rcx], 0
    ; Re-randomize this slot's per-slot code slide first; the copy destination
    ; below depends on it. Sliding the blob within the slot means a leak from
    ; one slot doesn't reveal gadget addresses for any other slot.
    mov edi, r9d
    call l3_randomize_code_slide
    mov edi, r9d
    call l3_slot_base
    mov r8, rax                          ; r8 = unmodified slot base (return value)
    ; Wipe the slot arena before anything is re-initialized so no stale secrets
    ; from the prior tenant (callback ptrs, canary derivatives, handle-table
    ; contents) survive into the new app. Must precede the blob copy and the
    ; manifest/stack/handle re-init below ??? they re-populate this range. The
    ; user-stack guard page (L3_SLOT_USER_STACK_GUARD_OFF) is non-present, so
    ; wipe the ranges below and above it separately ??? touching it would #PF.
    ; Recycled slots may still have W^X code pages marked X+!W; open the monitor
    ; window so CR0.WP does not turn this legitimate scrub into a ring-0 #PF.
    push rdi
    push rcx
    push rax
    xor eax, eax
    cld
    call nk_pt_window_begin
    mov rdi, r8
    mov rcx, L3_SLOT_USER_STACK_GUARD_OFF / 8
    USER_ACCESS_BEGIN
    rep stosq
    USER_ACCESS_END
    lea rdi, [r8 + L3_SLOT_USER_STACK_GUARD_OFF + 0x1000]
    mov rcx, (APP_SLOT_SIZE - L3_SLOT_USER_STACK_GUARD_OFF - 0x1000) / 8
    USER_ACCESS_BEGIN
    rep stosq
    USER_ACCESS_END
    call nk_pt_window_end
    pop rax
    pop rcx
    pop rdi
    mov rdi, rax
    mov eax, r9d
    add rdi, [abs l3_slot_code_slide + rax*8]   ; copy destination = slot_base + slide
    mov rsi, [rel app_blob_base_v]
    mov rcx, [rel app_blob_size_v]
    ; Available copy window shrinks by the slide. Clamp against PLACE_CAP (the
    ; user-stack guard floor) so the copy can never write through the
    ; non-present guard page or into the user stack, even at the maximum slide.
    mov rdx, L3_APP_BLOB_PLACE_CAP
    mov eax, r9d
    sub rdx, [abs l3_slot_code_slide + rax*8]
    cmp rcx, rdx
    jbe .copy_len_ok
    mov rcx, rdx
.copy_len_ok:
    cld
    USER_ACCESS_BEGIN
    rep movsb
    USER_ACCESS_END
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (blank-app diagnosis): right after the verbatim copy, dump the first
    ; few APP_SYSNO immediates in THIS slot's copy so we can see whether they hold
    ; the small raw syscall number (correct) or a relocated slot-local address
    ; (corruption). Format: XCPY s<slot> o<offset> y<rawsysno> v<dword-at-imm>.
    ; Capped to the first 10 records, and only for the first 3 slot copies.
    cmp dword [rel xcpy_calls], 3
    jae .xcpy_skip
    inc dword [rel xcpy_calls]
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    mov r10, r8                          ; slot base
    mov eax, r9d
    add r10, [abs l3_slot_code_slide + rax*8]   ; r10 = copy dest (slot base + slide)
    lea rbx, [rel app_syscall_fixups_start]
    lea r11, [rel app_syscall_fixups_end]
    xor edx, edx                         ; record counter
.xcpy_loop:
    cmp rbx, r11
    jae .xcpy_done
    cmp edx, 10
    jae .xcpy_done
    mov ecx, [rbx]                       ; u32 blob-relative offset of immediate
    SER 'X'
    SER 'C'
    SER 'P'
    SER 'Y'
    SER ' '
    SER 'o'
    mov edi, ecx
    call ser_print_hex64
    SER ' '
    SER 'y'
    movzx edi, byte [rbx + 4]            ; raw sysno
    call ser_print_hex64
    SER ' '
    SER 'v'
    mov ecx, [rbx]
    USER_ACCESS_BEGIN                     ; SMAP: this reads the user slot page; without
    mov edi, [r10 + rcx]                  ; stac it #PFs (errcode 1) and storms the ISR
    USER_ACCESS_END                       ; the 4 immediate bytes now in the slot copy
    call ser_print_hex64
    SER 13
    SER 10
    add rbx, 5
    inc edx
    jmp .xcpy_loop
.xcpy_done:
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.xcpy_skip:
%endif
    mov rax, L3_SLOT_MAGIC
    mov ecx, r9d
    mov [l3_slot_live + rcx*8], rax
    ; Install this slot's W^X manifest (Codex review finding 2). Every GritHL app
    ; gets a default v1 manifest naming its code window; l3_apply_wx_policy marks
    ; that window X+!W and every other slot page (writable data tail, stack,
    ; handle table) W+NX. No app page is ever both writable and executable, even
    ; for an app that never calls SYS_WX_INSTALL_MANIFEST. The old v0 "legacy
    ; permissive" path (blob pages left W+X) is gone -- a missing/invalid manifest
    ; now fails CLOSED to whole-slot W+NX in l3_apply_wx_policy. Apps can still
    ; override with a tighter range via SYS_WX_INSTALL_MANIFEST at runtime.
    ; The blob was copied to slot offset `slide` (page-aligned) above, so the
    ; app's executable code+rodata occupies [slide, slide + code_size) and its
    ; writable data tail occupies [slide + code_size, slide + blob_size).
    ; code_size = app_blob_code_size_v = app_blob_code_end - app_blob_start, the
    ; page-aligned `.appdata` boundary. Both ends are page-aligned (slide and the
    ; split are page multiples), so l3_apply_wx_policy can mark whole pages.
    mov ecx, r9d
    mov rdx, [abs l3_slot_code_slide + rcx*8]   ; rdx = slide = code window start
    mov rax, rdx
    add rax, [rel app_blob_code_size_v]         ; rax = slide + code_size = window end
    mov [l3_wx_code_start + rcx*8], rdx
    mov [l3_wx_code_end + rcx*8], rax
    mov qword [l3_wx_manifest_ver + rcx*8], 1
    ; Invalidate the code-range integrity baseline (security_todo.md ??12): the
    ; new tenant's code differs from the recycled slot's, so l3_apply_wx_policy
    ; must re-capture the hash on the next valid-manifest activation. Clearing
    ; the byte is enough; l3_code_hash[] is recomputed before it is trusted.
    mov byte [l3_code_hash_valid + rcx], 0
    ; Re-randomize this slot's user stack top so a leak from a sibling slot
    ; does not predict our RSP layout for the new app's lifetime.
    mov edi, r9d
    call l3_randomize_user_stack_top
    ; Derive this slot's kernel-only identity key (security_todo.md ??10):
    ; FNV-1a(kernel_canary || slot_id || boot_nonce). Stored in l3_slot_key[]
    ; (kernel BSS), never copied into the slot's ring-3 memory. Re-derived on
    ; every slot recycle so a new tenant gets a fresh secret. A HMAC-this-data
    ; syscall is the explicit follow-up; only derivation + storage land here.
    mov edi, r9d
    call l3_derive_slot_key
%ifdef ENABLE_SYSCALL_PERM
    ; Heterogeneous syscall numbering per slot (security_todo.md ??12). Generate
    ; this slot's keyed-random permutation, then rewrite every syscall-number
    ; immediate in the slot's just-copied blob from the raw compiled number to
    ; this slot's FORWARD-permuted number. The dispatcher's per-slot inverse map
    ; recovers the real table row, so a static exploit blob baked against one
    ; launch's numbering lands on the wrong handler in another. Slot 0 is the
    ; identity permutation (fail-safe), so this is a no-op rewrite there. rsi =
    ; the slot's blob base = slot_base + this slot's code slide.
    mov edi, r9d
    call sc_slot_perm_generate
    mov edi, r9d
    mov rsi, r8                          ; r8 = unmodified slot base
    mov eax, r9d
    add rsi, [rel l3_slot_code_slide + rax*8]   ; + per-slot code slide
    call sc_slot_perm_apply_blob
%endif
    ; Phase 1 handle-table refactor: clear this slot's handle table so the
    ; new app starts with no inherited handles from the previous occupant.
    ; Phase 2 will wire syscalls (FAT16 dir-entry handles first) onto it.
    mov rdi, r8
    call handle_table_clear
    mov rax, r8
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rcx
    ret

; l3_release_slot - retire per-launch state for a closed app slot.
; EDI = slot. This is the lifecycle counterpart to l3_copy_app_blob_to_slot:
; it clears kernel-owned per-slot metadata and scrubs the user arena. The
; current paging model still uses fixed slot VAs, so this is not a physical
; decommit yet; it makes the slot non-live and removes the previous tenant's
; bytes before the next launch chooses a fresh code slide / stack top / syscall
; permutation.
FN_BEGIN l3_release_slot, 1, 0, FN_RET_VOID
    push rax
    push rcx
    push rdi
    push r8

    cmp edi, MAX_WINDOWS
    jae .release_done
    test edi, edi
    jz .release_done                  ; slot 0 is the hidden wallpaper runtime

    mov r8d, edi
    cmp r8, r15
    je .release_clear_meta            ; do not erase code under an active syscall
    call l3_slot_base
    mov rdi, rax
    xor eax, eax
    cld
    ; W^X leaves executable slot pages read-only. Slot teardown is allowed to
    ; scrub those pages, so bracket only the bulk wipe with the monitor WP-off
    ; window and keep SMAP open only for the actual user-page stores.
    call nk_pt_window_begin
    mov rcx, L3_SLOT_USER_STACK_GUARD_OFF / 8
    USER_ACCESS_BEGIN
    rep stosq
    USER_ACCESS_END

    mov edi, r8d
    call l3_slot_base
    lea rdi, [rax + L3_SLOT_USER_STACK_GUARD_OFF + 0x1000]
    mov rcx, (APP_SLOT_SIZE - L3_SLOT_USER_STACK_GUARD_OFF - 0x1000) / 8
    xor eax, eax
    USER_ACCESS_BEGIN
    rep stosq
    USER_ACCESS_END
    call nk_pt_window_end

.release_clear_meta:
    mov ecx, r8d
    xor eax, eax
    mov [l3_slot_live + rcx*8], rax
    mov [l3_wx_manifest_ver + rcx*8], rax
    mov [l3_wx_code_start + rcx*8], rax
    mov [l3_wx_code_end + rcx*8], rax
    mov [abs l3_slot_ustack_off + rcx*8], rax
    mov [abs l3_slot_code_slide + rcx*8], rax
    mov [l3_code_hash + rcx*8], rax
    mov byte [l3_code_hash_valid + rcx], 0
    mov [l3_slot_key + rcx*8], rax
%ifdef ENABLE_SYSCALL_PERM
    lea rax, [rel sc_slot_perm_committed]
    mov byte [rax + rcx], 0
%endif

.release_done:
    pop r8
    pop rdi
    pop rcx
    pop rax
    ret

; l3_slot_resolve_app_ptr
; EDI = slot, RSI = kernel pointer inside the built-in user blob
