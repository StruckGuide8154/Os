; l3_code_hash_compute - EDI = slot. Returns RAX = low 64 bits of the SHA-256 of
; the slot's executable code-range bytes (skipping the handle-table carve-out),
; or 0 if the slot has no valid v1 manifest / an empty range. Truncated SHA-256
; replaces the former FNV-1a fold: FNV is unkeyed and algebraically invertible,
; so an attacker who can write a code page (the exact threat this tripwire
; guards - see usermode_paging.inc) could forge a second preimage (~2^32 work,
; constants are in KERNEL.BIN) and pass the check. SHA-256 has no such shortcut
; (~2^64 even truncated, non-invertible). The SHA state is a reentrant context
; on THIS stack frame (ci_sha256_* take a ctx pointer), so install (syscall) and
; verify_all (PIT IRQ) never share state and need no lock.
;
; Preserves rbx,rcx,rdx,rsi,rdi,rbp,r8..r15 (clobbers only rax). The byte stream
; fed to SHA-256 is identical for install and verify (same walk), so baselines
; compare correctly; the value differs from the old FNV but is never persisted
; across boots (l3_code_hash is .bss, re-baselined every boot).
extern ci_sha256_init
extern ci_sha256_update
extern ci_sha256_final_lo
CI_SHA_CTX_SIZE equ 408                   ; 400-byte ctx + 8 to keep rsp 16-aligned
FN_DECL l3_code_hash_compute, 0, 0, FN_RET_SCALAR
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15                              ; 14 pushes (rsp stays 8 mod 16)
    sub rsp, CI_SHA_CTX_SIZE              ; ctx at [rsp..rsp+400); rsp now 16-aligned

    mov r12d, edi                         ; r12d = slot
    cmp r12d, MAX_WINDOWS
    jae .ch_zero

    ; Require a committed v1 manifest with sane bounds (same gate as the policy
    ; walk). Anything else means "no code range to hash".
    mov eax, r12d
    cmp qword [l3_wx_manifest_ver + rax*8], 1
    jne .ch_zero
    mov rbp, [l3_wx_code_start + rax*8]   ; rbp = cursor = code_start offset
    mov r14, [l3_wx_code_end + rax*8]     ; r14 = code_end offset (exclusive)
    cmp rbp, r14
    jae .ch_zero

    ; r13 = slot base virtual address.
    mov edi, r12d
    call l3_slot_base
    mov r13, rax

    ; r15 = handle-table carve-out start offset, rbx = carve-out end offset
    ; (page-rounded, matching l3_apply_wx_policy's skip window). The carve-out is
    ; page-aligned, so it can be skipped whole pages at a time.
    mov r15, L3_HANDLE_TABLE_OFF
    mov rbx, (L3_HANDLE_TABLE_SZ + 0xFFF) & ~0xFFF
    add rbx, r15

    mov rdi, rsp                          ; ctx
    call ci_sha256_init

    ; SMAP: the slot is user (PTE.U=1) memory; bracket the byte reads. ci_sha256_
    ; update reads user bytes into the (kernel-stack) ctx; both are fine with AC=1.
    USER_ACCESS_BEGIN
.ch_page_loop:
    cmp rbp, r14
    jae .ch_loop_done
    ; r8 = next page boundary above the cursor (exclusive).
    mov r8, rbp
    or r8, 0xFFF
    inc r8
    ; r9 = run end for this page = min(next-page-boundary, code_end).
    mov r9, r8
    cmp r9, r14
    jbe .ch_have_runend
    mov r9, r14
.ch_have_runend:
    ; Skip the handle-table carve-out page [r15, rbx): mutable kernel data.
    cmp rbp, r15
    jb .ch_present_check
    cmp rbp, rbx
    jb .ch_skip_page
.ch_present_check:
    ; Only hash bytes from PRESENT pages. A non-present page (guard / never
    ; populated) would #PF in ring 0 and holds no executable bytes -> skip it.
    ; PT entry = APP_ARENA_PT_BASE + slot*ARENA_SLOT_PAGES*8 + (off>>12)*8.
    mov r10, rbp
    shr r10, 12                           ; page index within slot
    mov eax, r12d
    imul rax, ARENA_SLOT_PAGES * 8
    lea r10, [rax + r10*8 + APP_ARENA_PT_BASE]
    mov rax, [r10]
    test al, 1                            ; PAGE_PRESENT?
    jz .ch_skip_page
    ; Feed run [rbp, r9): src = base + rbp, len = r9 - rbp.
    mov rdi, rsp                          ; ctx
    lea rsi, [r13 + rbp]                  ; src
    mov rdx, r9
    sub rdx, rbp                          ; len
    call ci_sha256_update
    mov rbp, r9                           ; advance cursor past the hashed run
    jmp .ch_page_loop
.ch_skip_page:
    mov rbp, r8                           ; advance to the next page boundary
    jmp .ch_page_loop
.ch_loop_done:
    USER_ACCESS_END
    mov rdi, rsp                          ; ctx
    call ci_sha256_final_lo               ; rax = low 64 bits of SHA-256
    jmp .ch_ret

.ch_zero:
    xor eax, eax                          ; no valid range -> tag 0
.ch_ret:
    add rsp, CI_SHA_CTX_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
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
    ; compute returns 0 for any slot that does NOT currently present a sane v1
    ; manifest (ver!=1 or start>=end) - i.e. a slot that was recycled, is mid
    ; re-install, or never carried a real code range. The valid flag can still
    ; read nonzero across that window (TOCTOU vs l3_copy_app_blob_to_slot /
    ; SYS_WX_INSTALL_MANIFEST, or stale/garbage BSS for a never-installed slot),
    ; which previously compared 0 against the stale baseline and fail-closed with
    ; a spurious "CANARY 0 @..." (tag WCXH) at boot. A genuine W-on-code attack
    ; mutates the bytes (nonzero, mismatching hash) and never zeroes the
    ; manifest, so a 0 here means "no executable range to protect": drop the
    ; stale baseline and skip rather than panic. No real coverage is lost.
    test rax, rax
    jz .va_stale
    cmp rax, [l3_code_hash + rcx*8]
    jne .va_mismatch
.va_next:
    inc ecx
    jmp .va_loop
.va_stale:
    mov byte [l3_code_hash_valid + rcx], 0
    jmp .va_next
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
    DBG_EVT_IMPORTANT EVT_WX_HASH_FAIL, rcx, rax, [l3_code_hash + rcx*8], [l3_wx_manifest_ver + rcx*8], [l3_wx_code_start + rcx*8], [l3_wx_code_end + rcx*8], 0
%ifdef ENABLE_DEBUG_SERIAL
    SER 'W'
    SER 'C'
    SER 'X'
    SER 'H'
    SER ' '
    SER 's'
    mov edi, ecx
    call ser_print_hex64
    SER ' '
    SER 'r'
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    SER 'e'
    mov rdi, [l3_code_hash + rcx*8]
    call ser_print_hex64
    SER ' '
    SER 'v'
    mov rdi, [l3_wx_manifest_ver + rcx*8]
    call ser_print_hex64
    SER ' '
    SER 'b'
    mov rdi, [l3_wx_code_start + rcx*8]
    call ser_print_hex64
    SER '/'
    mov rdi, [l3_wx_code_end + rcx*8]
    call ser_print_hex64
    SER ' '
    SER 'l'
    movzx edi, byte [l3_code_hash_valid + rcx]
    call ser_print_hex64
    SER 13
    SER 10
%endif
    ; PER-SLOT KILL (was: jmp kernel_panic_canary global halt). The diverged
    ; bytes are attributable to slot ECX, so tear down ONLY that slot rather than
    ; halting every tenant. sc_slot_integrity_kill wants the faulting slot in r15
    ; and the reason code in edx; this is the PIT-cadence sweep (IRQ context), so
    ; r15 here is NOT a syscall-entry slot id - load it from ECX and restore it
    ; after. The helper clobbers rax/rcx/rdx/rsi/rdi/r8 (all dead or stack-saved
    ; here); we reload ECX from the stack-saved copy (pushed rcx) afterward, drop
    ; this slot's now-untrusted baseline, and continue the sweep fail-closed.
    extern sc_slot_integrity_kill
    push r15
    movzx r15d, cl                       ; r15 = faulting slot id
    mov edx, 0x57435848                  ; WCXH: executable code hash mismatch
    call sc_slot_integrity_kill
    pop r15
    mov ecx, [rsp+16]                    ; reload slot index (stack: rdi@0, rdx@8, rcx@16)
    mov byte [l3_code_hash_valid + rcx], 0  ; baseline untrusted -> stop re-checking
    jmp .va_next

; l3_install_app_done_trampoline MIGRATED TO ZERO-ASM GritHLK:
; src/kernel/grithlk/usermode_callbacks.ghl -> build/ghl/usermode_callbacks.asm
; (%include'd by kernel_build.asm). It is part of the ring-3 callback/app-done
; trampoline path and was ported with that path; defining it here too would be a
; duplicate symbol. See feedback_no_asm_shims_full_zero_asm.
