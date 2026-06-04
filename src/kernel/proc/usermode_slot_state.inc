FN_BEGIN l3_randomize_code_slide, 0, 0, FN_RET_VOID
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    mov r8d, edi
%ifdef NEXUS_NO_MEM_RANDOM
    mov ecx, r8d
    mov qword [rel l3_slot_code_slide + rcx*8], 0
    jmp .lrcs_done
%endif
    ; max_slide_bytes = (L3_APP_BLOB_PLACE_CAP - blob_size), floor-aligned to page.
    ; PLACE_CAP (the user-stack guard floor), not COPY_CAP (the shadow-window
    ; boundary), bounds placement so a slid blob never reaches the guard page or
    ; the user stack above it. If the blob is larger than the cap (shouldn't
    ; happen ??? l3_copy_app_blob_to_slot truncates anyway), pin slide to 0.
    mov rcx, L3_APP_BLOB_PLACE_CAP
    sub rcx, [rel app_blob_size_v]
    jbe .lrcs_zero
    shr rcx, 12                          ; rcx = number of page-positions - 1
    inc rcx                              ; rcx = number of page-positions (>= 1)
    ; Sample entropy.
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rbx, rax
    mov eax, 1
    cpuid
    test ecx, 1 << 30
    jz .lrcs_no_rdrand
    mov ecx, 8
.lrcs_try_rdrand:
    rdrand rax
    jc .lrcs_have_rdrand
    dec ecx
    jnz .lrcs_try_rdrand
    jmp .lrcs_no_rdrand
.lrcs_have_rdrand:
    xor rbx, rax
.lrcs_no_rdrand:
    ; rdx:rax = rbx; divide by rcx (page-position count) -> remainder in rdx.
    mov rax, L3_APP_BLOB_PLACE_CAP
    sub rax, [rel app_blob_size_v]
    shr rax, 12
    inc rax                              ; recompute (rcx was clobbered by cpuid)
    mov rcx, rax
    mov rax, rbx
    xor rdx, rdx
    div rcx                              ; rdx = rbx mod page-position-count
    shl rdx, 12                          ; rdx = slide in bytes, page-aligned
    mov ecx, r8d
    mov [rel l3_slot_code_slide + rcx*8], rdx
    jmp .lrcs_done
.lrcs_zero:
    mov ecx, r8d
    mov qword [rel l3_slot_code_slide + rcx*8], 0
.lrcs_done:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    FN_END l3_randomize_code_slide
    ret

; ============================================================================
; Per-slot cryptographic identity key (security_todo.md ??10).
;
; Each slot gets a kernel-only secret key derived at slot init from
;     slot_key = FNV-1a( kernel_canary || slot_id || boot_nonce )
; using the SAME FNV-1a family already relied on across the tree
; (measured_boot.asm, the code-range hash above). The key is a per-install
; secret an app can later prove knowledge of via a HMAC-this-data syscall
; (explicit FOLLOW-UP ??? not landed here). The key NEVER touches the slot's
; ring-3 memory: it lives only in kernel BSS (l3_slot_key[]), outside the
; app arena, exactly like l3_code_hash[] / l3_slot_code_slide[].
;
; The boot nonce is a one-shot RDTSC ^ RDRAND draw (same source as
; kernel_canary_init / l3_randomize_*), captured once via l3_boot_nonce_ensure
; and stable for the boot. Mixing it in means the per-slot key differs across
; boots even for the same canary+slot, so a leaked key from a prior boot is
; useless against the next one.
;
; Storage uses the same non-cryptographic FNV stopgap documented in
; measured_boot.asm: collision-resistant enough to act as a per-slot secret
; identifier, swap-able for a real KDF later without touching the call sites.
; ============================================================================
L3_SLOT_KEY_FNV_OFFSET equ 0xCBF29CE484222325
L3_SLOT_KEY_FNV_PRIME  equ 0x00000100000001B3

; l3_boot_nonce_ensure - lazily seed the kernel-only boot nonce from
; RDTSC ^ RDRAND on first call; later calls are a no-op. A final non-zero
; guard avoids an all-zero nonce (matches kernel_canary_init). Plain-label
; internal helper. Preserves all caller registers.
l3_boot_nonce_ensure:
    cmp byte [rel l3_boot_nonce_done], 0
    jne .bne_ret
    push rax
    push rbx
    push rcx
    push rdx
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rbx, rax
    mov eax, 1
    cpuid
    test ecx, 1 << 30
    jz .bne_no_rdrand
    mov ecx, 8
.bne_try_rdrand:
    rdrand rax
    jc .bne_have_rdrand
    dec ecx
    jnz .bne_try_rdrand
    jmp .bne_no_rdrand
.bne_have_rdrand:
    xor rbx, rax
.bne_no_rdrand:
    test rbx, rbx
    jnz .bne_store
    mov rbx, 0xB007A11CE5EED5EE
.bne_store:
    mov [rel l3_boot_nonce], rbx
    mov byte [rel l3_boot_nonce_done], 1
    pop rdx
    pop rcx
    pop rbx
    pop rax
.bne_ret:
    ret

; l3_derive_slot_key - EDI = slot. Derive this slot's kernel-only key as
; FNV-1a over (kernel_canary || slot_id || boot_nonce), 8 bytes each LE, and
; store it in l3_slot_key[slot]. The key is never written into ring-3 memory.
; Plain-label internal helper (no global) so it carries no coverage gate.
; Preserves all caller registers.
l3_derive_slot_key:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    mov ecx, edi                          ; ecx = slot
    cmp ecx, MAX_WINDOWS
    jae .dsk_ret                          ; bogus slot ??? never index past array
    call l3_boot_nonce_ensure             ; make sure the nonce is live

    mov rax, L3_SLOT_KEY_FNV_OFFSET       ; rax = running hash
    mov rbx, L3_SLOT_KEY_FNV_PRIME        ; rbx = FNV prime (constant across folds)

    ; Fold the three 8-byte inputs in order: kernel_canary, slot_id, boot_nonce.
    mov rdx, [rel kernel_canary]
    call .dsk_fold8
    mov edx, ecx                          ; slot id (zero-extended to 64)
    call .dsk_fold8
    mov rdx, [rel l3_boot_nonce]
    call .dsk_fold8

    mov [rel l3_slot_key + rcx*8], rax
.dsk_ret:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .dsk_fold8 - fold the 8 bytes of rdx (LE) into the running FNV hash in rax,
; with the prime preloaded in rbx. Clobbers rdx (consumed) + a scratch byte in
; the low bits; rcx (slot) and rbx (prime) are preserved.
.dsk_fold8:
    push rdi                              ; byte counter scratch
    push r8                               ; byte scratch (caller's r8 preserved)
    mov edi, 8
.dsk_fold_byte:
    movzx r8, dl                          ; next low byte of the input word
    xor rax, r8                           ; FNV-1a: hash ^= byte
    imul rax, rbx                         ; hash *= prime
    shr rdx, 8
    dec edi
    jnz .dsk_fold_byte
    pop r8
    pop rdi
    ret

; l3_copy_app_blob_to_slot - copy the built-in user blob into a slot arena
