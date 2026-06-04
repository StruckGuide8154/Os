
; l3_install_syscall_stack_pt - split the PDE covering l3_syscall_stacks into
; 4 KiB pages so per-slot guard pages can be punched. Idempotent: safe to call
; multiple times. Must run after paging is active and before any syscall (so
; called from kmain before syscall_init).
;
; Algorithm:
;   1. pde_idx = l3_syscall_stacks >> 21
;   2. Walk CR3 -> PML4[0] -> PDPT[0] -> PD0 (BIOS PD0=0x72000, UEFI=0x73000,
;      so we follow the pointers rather than hardcoding).
;   3. Populate SYSCALL_STACK_PT_BASE with 512 PTEs identity-mapping the
;      2 MiB region at (pde_idx << 21), supervisor + writable + NX.
;   4. Clear PAGE_PRESENT on the two guard pages of each MAX_WINDOWS-sized
;      slot (slot stride = L3_SYSCALL_STACK_STRIDE; guards at +0x0000 and
;      +0x2000 bracket the shadow stack and the syscall stack respectively).
;   5. Replace PD0[pde_idx] with SYSCALL_STACK_PT_BASE | PRESENT|WRITABLE
;      (supervisor ??? kernel-only region).
;   6. Flush TLB (mov cr3, cr3).
FN_BEGIN l3_install_syscall_stack_pt, 0, 0, FN_RET_VOID
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9

    mov rbx, L3_SYSCALL_STACK_ADDR
    mov rcx, rbx
    shr rcx, 21                          ; rcx = pde_idx
    cmp rcx, 512
    jae .ist_done                        ; outside PD0 ??? bail (>1 GiB kernel)

    ; Verify the whole 96 KiB array fits in one PDE (alignb 0x20000 guarantees this).
    mov rdx, rbx
    add rdx, MAX_WINDOWS * L3_SYSCALL_STACK_STRIDE - 1
    shr rdx, 21
    cmp rdx, rcx
    jne .ist_done

    ; Open the monitor window for the PT fill + PDE swap below (all writes land
    ; in the [0x70000,0x83000) page-table region protected in Phase 2).
    call nk_pt_window_begin

    ; Walk CR3 -> PML4[0] -> PDPT[0] -> PD0 base.
    mov rdi, PAGE_TABLE_ADDR             ; CR3 / PML4
    mov r8, [rdi]                        ; PML4[0]
    and r8, ~0xFFF
    mov r9, [r8]                         ; PDPT[0]
    and r9, ~0xFFF                       ; r9 = PD0 physical base

    ; Populate the syscall-stack PT: 512 PTEs over [pde<<21, (pde+1)<<21).
    mov rdi, SYSCALL_STACK_PT_BASE
    mov rdx, rcx
    shl rdx, 21                          ; physical base of this PDE
    mov rsi, 512
.ist_fill_pt:
    mov rax, rdx
    or rax, 0x03                         ; PRESENT | WRITABLE (supervisor ??? no USER)
    bts rax, 63                          ; NX (kernel data region)
    mov [rdi], rax
    add rdx, 0x1000
    add rdi, 8
    dec rsi
    jnz .ist_fill_pt

    ; Clear PAGE_PRESENT on the two guard pages of each 16 KiB slot: one at
    ; slot offset +0x0000 (below the shadow stack) and one at +0x2000 (below
    ; the syscall stack). The first slot's base PTE byte offset is
    ; ((l3_syscall_stacks - (pde<<21)) / 0x1000) * 8; the +0x2000 guard is two
    ; PTEs (= 16 bytes) further on; each subsequent slot is STRIDE/0x1000 PTEs
    ; (= 32 bytes) further on.
    mov rdx, rcx
    shl rdx, 21
    mov rax, rbx
    sub rax, rdx                         ; offset of l3_syscall_stacks within PDE
    shr rax, 12
    shl rax, 3                           ; byte offset of slot 0's base PTE
    add rax, SYSCALL_STACK_PT_BASE
    mov rsi, MAX_WINDOWS
.ist_clear_guard:
    mov rdx, [rax]
    and rdx, ~0x1                        ; clear PRESENT ??? guard at +0x0000
    mov [rax], rdx
    mov rdx, [rax + 16]
    and rdx, ~0x1                        ; clear PRESENT ??? guard at +0x2000
    mov [rax + 16], rdx
    add rax, (L3_SYSCALL_STACK_STRIDE / 0x1000) * 8
    dec rsi
    jnz .ist_clear_guard

    ; Swap PD0[pde_idx]: was 2 MiB large supervisor page; now points at the PT.
    lea rdi, [r9 + rcx*8]
    mov rax, SYSCALL_STACK_PT_BASE
    or rax, 0x03                         ; PRESENT | WRITABLE (supervisor)
    mov [rdi], rax

    ; Close the monitor window (restores WP + flushes the TLB so the new
    ; mapping takes effect).
    call nk_pt_window_end

%ifdef PROBE_SYSCALL_STACK_GUARD
    ; One-shot probe: touch the guard page of slot 0. Expected behavior:
    ; isr_common_stub catches the page fault, prints "SYSG=0000000000000000",
    ; and halts via isr_nested_halt ("!!!"). Only built when explicitly asked
    ; for via -dPROBE_SYSCALL_STACK_GUARD in build_uefi.ps1.
    SER 'P'
    SER 'R'
    SER 'B'
    SER 13
    SER 10
    lea rax, [rel l3_syscall_stacks]
    mov qword [rax], 0          ; first byte of array == slot 0 guard page
%endif

.ist_done:
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
    FN_END l3_install_syscall_stack_pt

; l3_apply_slot_isolation - EDI = active slot
; Walks the app-arena 4KB page tables and marks only the active slot's pages
; USER-accessible; every other slot's pages become supervisor-only. A ring-3
; app therefore faults if it dereferences another slot's memory. Flushes the
; TLB so the change takes effect before the iretq into ring 3.
FN_BEGIN l3_apply_slot_isolation, 0, 0, FN_RET_SCALAR
    push rax
    push rcx
    push rdx
    push r8
    push r9
    call nk_pt_window_begin         ; WP-off window for the USER-bit edits below
    mov r8d, edi                    ; active slot
    mov r9, APP_ARENA_PT_BASE       ; PTE cursor
    xor edx, edx                    ; slot index
.slot_loop:
    xor ecx, ecx                    ; 4KB page index within slot
.page_loop:
    mov rax, [r9]
    and rax, ~4                     ; clear USER (bit 2)
    cmp edx, r8d
    jne .store
    or  rax, 4                      ; active slot: USER-accessible
.store:
    mov [r9], rax
    add r9, 8
    inc ecx
    cmp ecx, ARENA_SLOT_PAGES
    jb .page_loop
    inc edx
    cmp edx, MAX_WINDOWS
    jb .slot_loop
    call nk_pt_window_end           ; restore WP + flush TLB
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; l3_apply_wx_policy - EDI = active slot
; Walks the active slot's 4KB PT and enforces strict W^X per page:
;
;   * Manifest version 0 (default, set by l3_copy_app_blob_to_slot):
;     no code range is committed yet. Every present page in the slot is
;     forced W+NX ??? an unmanifested slot literally cannot execute any
;     user code until it commits a manifest via SYS_WX_INSTALL_MANIFEST.
;
;   * Manifest version 1 (set by SYS_WX_INSTALL_MANIFEST after validation):
;     strict W+NX everywhere in the slot, except pages whose slot-offset
;     lies in [code_start_off, code_end_off) which become X+!W.
;
; Manifest versions other than 1, or installed bounds that fail the
; defense-in-depth revalidation, collapse back to the version-0 posture
; (whole slot W+NX). The function only touches the active slot's PT;
; other slots' PTEs are left as l3_apply_slot_isolation set them. TLB is
; flushed via CR3 reload before returning.
;
; Called from enter_usermode immediately after l3_apply_slot_isolation,
; and from SYS_WX_INSTALL_MANIFEST when the running slot updates its
; manifest. Preserves all caller registers.
global l3_apply_wx_policy
FN_BEGIN l3_apply_wx_policy, 0, 0, FN_RET_SCALAR
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12

    mov r8d, edi                    ; r8d = active slot index
    cmp r8d, MAX_WINDOWS
    jae .wx_done                    ; bogus slot ??? bail

    ; r9 = slot base virtual addr
    mov eax, r8d
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    mov r9, rax

    ; Read manifest. Magic must match ??? slots that have never been used by
    ; l3_copy_app_blob_to_slot have undefined metadata, treat as legacy.
    xor r10d, r10d                  ; r10d = effective manifest version
    mov eax, r8d
    mov rax, [l3_wx_manifest_ver + rax*8]
    cmp rax, 1
    jne .wx_have_ver
    ; Validate manifest bounds (defense-in-depth ??? install syscall already
    ; checks these, but re-validating on every activation costs ~4 compares
    ; and protects against a future bug that bypasses the install path).
    mov eax, r8d
    mov rcx, [l3_wx_code_start + rax*8]
    mov rdx, [l3_wx_code_end + rax*8]
    test rcx, 0xFFF
    jnz .wx_have_ver
    test rdx, 0xFFF
    jnz .wx_have_ver
    cmp rcx, L3_APP_CODE_OFF
    jb  .wx_have_ver
    cmp rdx, L3_SHADOW_WIN_OFF
    ja  .wx_have_ver
    cmp rcx, rdx
    jae .wx_have_ver
    mov r10d, 1

.wx_have_ver:
    ; r10d == 0  -> no valid manifest: force whole slot W+NX (no code pages).
    ; r10d == 1  -> manifest v1: [code_start_off, code_end_off) becomes X+!W.
    call nk_pt_window_begin         ; WP-off window for the per-page W/NX edits
.wx_manifest_loop:
    ; PT cursor for this slot: APP_ARENA_PT_BASE + slot * ARENA_SLOT_PAGES * 8
    mov eax, r8d
    imul rax, ARENA_SLOT_PAGES * 8
    add rax, APP_ARENA_PT_BASE
    mov r11, rax

    ; Pre-load page-offset bounds for the legacy stack-W+NX region.
    ; Stack lives in [L3_SLOT_USER_STACK_TOP - L3_USER_STACK_SIZE, APP_SLOT_SIZE);
    ; force W+NX across those pages in BOTH manifest paths.
    mov rbx, L3_SLOT_USER_STACK_TOP - L3_USER_STACK_SIZE
    and rbx, ~0xFFF                 ; page-aligned

    xor r12d, r12d                  ; page index within slot
.wx_page_loop:
    mov rax, [r11]
    test al, 1                      ; PAGE_PRESENT?
    jz .wx_next                     ; absent (guard page) ??? leave alone

    ; rsi = byte offset of this page within slot
    mov rsi, r12
    shl rsi, 12

    ; Stack region always W+NX.
    cmp rsi, rbx
    jae .wx_set_wnx

    ; Per-slot handle table is kernel-owned data living inside the legal code
    ; window. It must stay writable (handle_table_clear/alloc/close update it)
    ; and non-executable, so force W+NX regardless of the manifest. Without
    ; this carve-out an app whose declared code range covers
    ; L3_HANDLE_TABLE_OFF marks the page X+!W and the next kernel handle write
    ; takes a ring-0 #PF that iretqs back into itself forever.
    mov rdx, rsi
    sub rdx, L3_HANDLE_TABLE_OFF
    cmp rdx, (L3_HANDLE_TABLE_SZ + 0xFFF) & ~0xFFF
    jb .wx_set_wnx

    ; No manifest -> legacy permissive: blob pages keep their existing W+X
    ; permissions. NexusHL apps interleave .text and .data in one section,
    ; so forcing W+NX here breaks string scratches / .bss-style buffers.
    ; Apps that want strict W^X opt in via SYS_WX_INSTALL_MANIFEST.
    test r10d, r10d
    jz .wx_next

    mov ecx, r8d
    cmp rsi, [l3_wx_code_start + rcx*8]
    jb .wx_set_wnx
    cmp rsi, [l3_wx_code_end + rcx*8]
    jae .wx_set_wnx
    ; Code page: clear W (bit 1) AND clear NX (bit 63) ??? X+!W.
    and rax, -3                     ; ~2 sign-extended: clears bit 1
    mov rdx, PAGE_NX
    not rdx
    and rax, rdx                    ; clears bit 63
    mov [r11], rax
    jmp .wx_next

.wx_set_wnx:
    ; Data/stack page: set W (bit 1) AND set NX (bit 63) ??? W+NX.
    or rax, 2
    mov rdx, PAGE_NX
    or rax, rdx
    mov [r11], rax

.wx_next:
    add r11, 8
    inc r12d
    cmp r12d, ARENA_SLOT_PAGES
    jb .wx_page_loop

    ; Close the window (restore WP + flush TLB) so the new permissions take
    ; effect before iretq / return. The hash baseline below runs outside the
    ; window (it only reads code bytes).
    call nk_pt_window_end

    ; Code-range hash-on-install (security_todo.md ??12). The first time a slot
    ; presents a valid v1 manifest (r10d==1), capture the FNV-1a hash of its
    ; X-page bytes as the integrity baseline. Subsequent activations skip this
    ; (valid flag set); pit_handler re-verifies the baseline periodically. We
    ; baseline here rather than in the install syscall so the hook stays
    ; self-contained in usermode.asm and covers every path that commits a code
    ; range (enter_usermode + SYS_WX_INSTALL_MANIFEST both reach this walk).
    test r10d, r10d
    jz .wx_done
    cmp byte [l3_code_hash_valid + r8], 0
    jne .wx_done
    mov edi, r8d
    call l3_code_hash_install

.wx_done:
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Code-range integrity hashing (security_todo.md ??12).
;
; THREAT: an unintended W mapping landing on a code (X) page ??? e.g. a future
; JIT-alias bug or any kernel-write primitive ??? could mutate executable bytes
; after they were validated, without ever flipping a permission bit we scrub.
; l3_apply_wx_policy guards the *permissions*; this guards the *contents*.
;
; APPROACH: when a slot first commits a valid v1 manifest, hash every byte of
; its executable code range (FNV-1a; same constants as measured_boot.asm, but a
; local stateless fold so we carry no cross-file dependency) and stash it in
; l3_code_hash[slot]. pit_handler periodically re-hashes and compares; a
; mismatch means executable bytes changed under us -> kernel_panic_canary.
;
; The per-slot kernel-owned handle table lives inside the legal code window and
; is legitimately mutable (handle_alloc/close write it). l3_apply_wx_policy
; already forces those pages W+NX (a carve-out); the hash MUST skip the same
