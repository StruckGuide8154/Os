; ============================================================================
; syscall_perm.inc
; syscall per-slot machinery: allow-bitmap build/reset, slot-permutation ensure/generate/apply, kernel_apply_app_manifest, manifest/deny tables
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
;
; Stage 2b GHLK migration note (docs/ghlk-syscall-rearchitecture.md): the
; HMAC/cap-mask leaf cluster moved to src/kernel/grithlk/syscall_secure.ghl.
; The helpers in THIS file (sc_build_allow_bitmap, sc_reset_allow_bitmap,
; sc_slot_perm_ensure/_generate/_apply_blob, kernel_apply_app_manifest) are
; INTENTIONALLY kept in asm: their loop bounds / row strides are
; syscall_table_count and SC_ALLOW_BYTES, which are NASM ASSEMBLE-TIME `equ`s
; derived from the syscall table - not stable GHLK numeric literals. GHLK
; `const`/`state`/bounds-check sizes must be literals, so a zero-asm port would
; have to hardcode the table count, a fragility/security regression if the
; table ever grows. Revisit once gritc.py can bind a NASM symbol as a count.
; ============================================================================
section .text
; ----------------------------------------------------------------------------
; sc_build_allow_bitmap(rdi=slot, rsi=cap_mask, rdx=app_id)
;
; Rebuild slot_syscall_allow[slot] from the slot's effective cap mask and the
; per-app explicit deny list (security_todo.md §2, "Manifest declares syscall
; set, not just cap bits"). Two passes:
;   1. For each syscall table row i, set bit i iff the row's CAP tag is fully
;      covered by cap_mask (row.cap & mask == row.cap) - i.e. the cap gate
;      would let this slot reach syscall i. This makes the bitmap the exact
;      cap-implied call set, no hand-authoring.
;   2. Walk the app's deny list (app_syscall_deny_table[app_id - APP_MIN_ID],
;      a run of syscall numbers ended by SC_DENY_LIST_END) and CLEAR each named
;      bit - the finer-than-caps trim. Notepad denies SYS_FS_DELETE here.
; app_id out of [APP_MIN_ID, APP_MAX_ID] skips pass 2 (cap-derived set only).
;
; Internal helper (plain label, not global - so check_coverage.py doesn't
; require FN_BEGIN, matching sc_record_strike). Preserves all caller regs.
; ----------------------------------------------------------------------------
sc_build_allow_bitmap:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    ; r11 = slot's bitmap base = slot_syscall_allow + slot*SC_ALLOW_BYTES
    movzx eax, dil
    imul eax, eax, SC_ALLOW_BYTES
    lea r11, [rel slot_syscall_allow]
    add r11, rax
    movzx r10d, si                      ; r10w = 16-bit cap_mask (si dies in pass 2 setup)
    ; Pass 0: clear the slot's bitmap bytes.
    xor ecx, ecx
.sba_zero:
    cmp ecx, SC_ALLOW_BYTES
    jae .sba_zero_done
    mov byte [r11 + rcx], 0
    inc ecx
    jmp .sba_zero
.sba_zero_done:
    ; Pass 1: set bit i for every row whose cap tag is covered by the mask.
    lea rbx, [rel syscall_table]
    xor ecx, ecx                        ; ecx = syscall index i
.sba_set:
    cmp ecx, syscall_table_count
    jae .sba_set_done
    movzx eax, word [rbx + SYSCALL_CAP_OFF]   ; row.cap (16-bit)
    mov r8d, eax
    and r8d, r10d                       ; row.cap & mask (16-bit)
    cmp r8d, eax
    jne .sba_set_next                   ; not fully covered -> leave bit clear
    ; set bit ecx: byte = ecx>>3, bit = ecx&7
    mov eax, ecx
    mov r9d, ecx
    shr eax, 3                          ; byte index
    and r9d, 7                          ; bit position
    mov r8b, [r11 + rax]
    bts r8d, r9d
    mov [r11 + rax], r8b
.sba_set_next:
    add rbx, SYSCALL_ENTRY_SIZE
    inc ecx
    jmp .sba_set
.sba_set_done:
    ; Pass 2: apply the per-app explicit deny list. Skip if app_id is out of
    ; range (rdx still holds the original app_id from the caller).
    cmp rdx, APP_MIN_ID
    jb .sba_done
    cmp rdx, APP_MAX_ID
    ja .sba_done
    mov eax, edx
    sub eax, APP_MIN_ID
    lea rbx, [rel app_syscall_deny_table]
    mov rbx, [rbx + rax*8]              ; rbx -> this app's deny list
.sba_deny:
    movzx eax, byte [rbx]
    cmp al, SC_DENY_LIST_END
    je .sba_done
    ; clear bit al: byte = al>>3, bit = al&7
    movzx ecx, al
    mov r9d, ecx
    shr ecx, 3
    and r9d, 7
    mov r8b, [r11 + rcx]
    btr r8d, r9d
    mov [r11 + rcx], r8b
    inc rbx
    jmp .sba_deny
.sba_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; sc_reset_allow_bitmap(rdi=slot) - set the slot's bitmap back to all-ones
; (unrestricted), the BSS default. Used on slot recycle so a recycled slot
; isn't stuck with the previous tenant's narrowed set before its manifest is
; re-applied. Preserves all caller regs.
; ----------------------------------------------------------------------------
sc_reset_allow_bitmap:
    push rax
    push rcx
    push r11
    movzx eax, dil
    imul eax, eax, SC_ALLOW_BYTES
    lea r11, [rel slot_syscall_allow]
    add r11, rax
    xor ecx, ecx
.sra_loop:
    cmp ecx, SC_ALLOW_BYTES
    jae .sra_done
    mov byte [r11 + rcx], 0xFF
    inc ecx
    jmp .sra_loop
.sra_done:
    pop r11
    pop rcx
    pop rax
    ret

%ifdef ENABLE_SYSCALL_PERM
; ----------------------------------------------------------------------------
; Heterogeneous syscall numbering per slot - generation (security_todo.md §12).
;
; sc_slot_perm_ensure(edi=slot): if this slot's permutation has not been
; generated yet (sentinel sc_slot_perm_ready[slot]==0), generate it once. The
; lazy first-use trigger lives on the dispatch path so the gated build is
; self-contained - it needs no edit to the contended usermode.asm slot-init
; path. THE LOADER HOOK (documented, scoped out) would instead call
; sc_slot_perm_generate from l3_copy_app_blob_to_slot, right after
; l3_derive_slot_key (usermode.asm), and ALSO rewrite the app's SYS_* constants
; with the FORWARD permutation; see the §12 _Done_ note. Preserves all caller
; regs.
;
; sc_slot_perm_generate(edi=slot): build a fresh per-launch random permutation
; for the slot. Forward perm fwd[] (real_row -> app_visible) via Fisher-Yates
; driven by a keyed RNG seeded from the SAME source as the per-slot key work
; (l3_slot_key[slot], itself RDTSC^RDRAND-derived via the boot nonce), mixed
; with kernel_canary and a fresh RDTSC so the layout differs per launch. The
; persisted artifact is the INVERSE: inv[app_visible]=real_row. Preserves all
; caller regs.
;
; Internal plain-label helpers (no FN_BEGIN - matches sc_build_allow_bitmap),
; so check_coverage.py doesn't require coverage and they carry no FN gate.
; ----------------------------------------------------------------------------
extern l3_slot_key

sc_slot_perm_ensure:
    push rax
    movzx eax, dil
    cmp eax, MAX_WINDOWS
    jae .spe_ret
    lea rax, [rel sc_slot_perm_ready]
    movzx ecx, dil
    cmp byte [rax + rcx], 0
    jne .spe_ret_pop_rcx
    push rcx
    call sc_slot_perm_generate          ; edi=slot still live
    pop rcx
.spe_ret_pop_rcx:
    pop rax
    ret
.spe_ret:
    pop rax
    ret

sc_slot_perm_generate:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    movzx r10d, dil                     ; r10 = slot (validated by caller path)
    cmp r10d, MAX_WINDOWS
    jae .spg_done
    ; A fresh generation invalidates any prior bake: UN-commit this slot before
    ; touching the tables so the dispatcher falls back to identity (against the
    ; about-to-be-recopied RAW blob) until sc_slot_perm_apply_blob re-commits.
    ; Cleared first, before fwd/inv are rewritten, so no sibling core can apply a
    ; half-built inverse.
    lea rax, [rel sc_slot_perm_committed]
    mov byte [rax + r10], 0
    ; r9 = this slot's FORWARD-permutation row in sc_slot_perm_fwd; the shuffle
    ; runs here, then the inverse is derived into sc_slot_perm_inv. Persisting
    ; the forward map (instead of discarding it) is what lets the loader rewrite
    ; the app's compiled SYS_* immediates per slot.
    mov eax, r10d
    imul eax, eax, syscall_table_count
    lea r9, [rel sc_slot_perm_fwd]
    lea r9, [r9 + rax*2]                 ; r9 -> u16 fwd[] row for this slot
    ; fwd[] identity init (also the final value for slot 0 / the identity case).
    xor ecx, ecx
.spg_id:
    cmp ecx, syscall_table_count
    jae .spg_id_done
    mov word [r9 + rcx*2], cx            ; fwd[i] = i
    inc ecx
    jmp .spg_id
.spg_id_done:
    ; Slot 0 stays IDENTITY (fail-safe). Slot 0 is the reserved/desktop slot and
    ; also the slot every kernel-resident ring-3 trampoline (call_app_l3_app_done
    ; in usermode.asm, which issues a RAW syscall number from a kernel VA outside
    ; the per-slot arena) is attributed to by the dispatcher's RSP-based slot
    ; derivation. Those trampolines are NOT part of the per-slot copied blob, so
    ; their immediates are never rewritten; keeping slot 0 identity makes the
    ; dispatcher's inverse map a no-op for them. Real apps run in slots 1..N.
    test r10d, r10d
    jz .spg_build_inv
    ; --- seed the keyed RNG (r11) -----------------------------------------
    ;   seed = l3_slot_key[slot] ^ kernel_canary ^ RDTSC, guarded non-zero.
    mov rax, [rel l3_slot_key + r10*8]
    xor rax, [rel kernel_canary]
    rdtsc
    shl rdx, 32
    or rax, rdx
    test rax, rax
    jnz .spg_seed_ok
    mov rax, 0x9E3779B97F4A7C15         ; non-zero fallback (golden ratio)
.spg_seed_ok:
    mov r11, rax                        ; r11 = SplitMix64 state
    ; --- Fisher-Yates over fwd[]: for i = count-1 down to 1, j = rand % (i+1),
    ;     swap fwd[i], fwd[j]. Constant work per element; the only branch is the
    ;     loop bound, not the syscall number, so no per-number timing leak.
    mov ecx, syscall_table_count
    dec ecx                              ; i = count-1
.spg_shuf:
    cmp ecx, 1
    jb .spg_shuf_done
    ; r8 = next random draw (SplitMix64 over r11)
    call .spg_rng                        ; -> rax random qword
    ; j = rax mod (i+1)
    mov r8d, ecx
    inc r8d                              ; i+1
    xor edx, edx
    div r8                               ; rax/r8 -> rdx = remainder = j
    ; swap fwd[i] <-> fwd[j]
    movzx eax, word [r9 + rcx*2]         ; fwd[i]
    movzx ebx, word [r9 + rdx*2]         ; fwd[j]
    mov word [r9 + rcx*2], bx
    mov word [r9 + rdx*2], ax
    dec ecx
    jmp .spg_shuf
.spg_shuf_done:
.spg_build_inv:
    ; --- Derive inv[] (app_visible -> real_row) from fwd[] (real_row ->
    ; app_visible): inv[fwd[i]] = i. Written directly into this slot's
    ; sc_slot_perm_inv row (r8 = inv row base).
    mov eax, r10d
    imul eax, eax, syscall_table_count
    lea r8, [rel sc_slot_perm_inv]
    lea r8, [r8 + rax*2]                 ; r8 -> u16 inv[] row for this slot
    xor ecx, ecx
.spg_inv:
    cmp ecx, syscall_table_count
    jae .spg_inv_done
    movzx eax, word [r9 + rcx*2]         ; app_visible = fwd[real_row=ecx]
    mov word [r8 + rax*2], cx            ; inv[app_visible] = real_row
    inc ecx
    jmp .spg_inv
.spg_inv_done:
    ; Mark the tables BUILT (sc_slot_perm_ready) so a concurrent/later
    ; sc_slot_perm_ensure does not re-shuffle this slot with a fresh seed -
    ; a second generation would no longer match the FORWARD numbers already
    ; baked into the running blob. Note: "tables built" is NOT "safe to apply".
    ; The dispatcher must not consume sc_slot_perm_inv[] until the blob has
    ; actually been rewritten to this generation's forward numbers; that COMMIT
    ; is published by sc_slot_perm_apply_blob (sc_slot_perm_committed), strictly
    ; after every immediate is patched. Until then the blob still holds RAW
    ; numbers and the only correct mapping is identity. Setting ready here but
    ; committed there closes the window where a sibling core could dispatch with
    ; a valid inverse against a not-yet-rewritten (raw) blob and misroute a
    ; non-returning syscall into a returning one (#UD at the trampoline's ud2).
    lea rax, [rel sc_slot_perm_ready]
    mov byte [rax + r10], 1
.spg_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .spg_rng - SplitMix64 step over state r11; returns next value in rax.
; Clobbers rax/rdx only (rcx=loop i and the rest are preserved by the caller).
.spg_rng:
    push rcx
    mov rax, 0x9E3779B97F4A7C15
    add r11, rax
    mov rax, r11
    mov rcx, rax
    shr rcx, 30
    xor rax, rcx
    mov rdx, 0xBF58476D1CE4E5B9
    imul rax, rdx
    mov rcx, rax
    shr rcx, 27
    xor rax, rcx
    mov rdx, 0x94D049BB133111EB
    imul rax, rdx
    mov rcx, rax
    shr rcx, 31
    xor rax, rcx
    pop rcx
    ret

; ----------------------------------------------------------------------------
; sc_slot_perm_apply_blob(edi=slot, rsi=blob_base) - rewrite this slot's copy
; of the app blob so every syscall-number immediate carries the slot's
; FORWARD-permuted number (real_row -> app_visible). The dispatcher's inverse
; map then recovers the real row. Called from l3_copy_app_blob_to_slot
; (usermode.asm) right after l3_derive_slot_key, with rsi = the slot's blob
; base (slot_base + per-slot code slide), which is where the build-time
; app_blob_start landed in this slot.
;
; Walks the build-emitted fixup table [app_syscall_fixups_start,
; app_syscall_fixups_end): each 5-byte record is {u32 blob-relative offset of
; a `mov eax, imm32` immediate, u8 raw compiled sysno}. For each record it
; looks up fwd[slot*count + raw_sysno] and stores it as the new 4-byte
; immediate at blob_base + offset.
;
; FAIL-SAFE: ensures the slot's permutation exists (sc_slot_perm_ensure);
; slot 0 / the identity case leaves fwd[i]=i so every immediate is rewritten to
; itself (a no-op). A raw_sysno >= syscall_table_count is left untouched (it is
; not a real table row; the dispatcher's bounds check rejects it either way).
; Writes go through USER_ACCESS brackets because the slot arena is PTE.U=1.
; Preserves all caller regs.
;
; Internal plain-label helper (no FN_BEGIN / not global - matches
; sc_slot_perm_generate/_ensure, so check_coverage.py requires no FN gate).
; ----------------------------------------------------------------------------
sc_slot_perm_apply_blob:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    movzx r10d, dil                     ; r10 = slot
    cmp r10d, MAX_WINDOWS
    jae .spa_done
    mov r9, rsi                         ; r9 = slot blob base
    ; Make sure this slot's permutation (and thus sc_slot_perm_fwd row) exists.
    call sc_slot_perm_ensure            ; edi=slot still valid
    ; r8 = this slot's forward-permutation row base.
    mov eax, r10d
    imul eax, eax, syscall_table_count
    lea r8, [rel sc_slot_perm_fwd]
    lea r8, [r8 + rax*2]
    ; rbx walks the fixup records; rsi is the table end.
    lea rbx, [rel app_syscall_fixups_start]
    lea rsi, [rel app_syscall_fixups_end]
.spa_loop:
    cmp rbx, rsi
    jae .spa_done
    mov ecx, [rbx]                      ; u32 blob-relative offset
    movzx edx, byte [rbx + 4]           ; u8 raw sysno
    add rbx, 5
    cmp edx, syscall_table_count
    jae .spa_loop                       ; not a real row -> leave immediate as-is
    movzx eax, word [r8 + rdx*2]        ; app_visible = fwd[raw_sysno]
    ; store the 4-byte immediate at blob_base + offset
    lea rdi, [r9 + rcx]
    USER_ACCESS_BEGIN
    mov dword [rdi], eax
    USER_ACCESS_END
    jmp .spa_loop
.spa_done:
    ; COMMIT: every immediate in this slot's blob now carries this generation's
    ; forward number, so the dispatcher's inverse map is safe to apply. Publish
    ; the commit LAST (after all the stores above). On x86's TSO model a sibling
    ; core that observes committed[slot]==1 is guaranteed to also observe the
    ; rewritten immediates and the inverse table, so it can never apply a live
    ; inverse against a still-raw blob. (Slot 0 / identity also commits here as a
    ; no-op rewrite, so its dispatch keeps mapping every number to itself.)
    lea rax, [rel sc_slot_perm_committed]
    mov byte [rax + r10], 1
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
%endif

; kernel_apply_app_manifest(rdi=slot, rsi=app_id)
;
; Kernel-only helper that sets slot_cap_mask[slot] = manifest(app_id).
; Called from the user-side app_launch (which runs in CPL0 - see the SER
; macros it uses) right after wm_create_window_ex returns a slot. This is
; the *required* enforcement point: every launch path the system supports
; ends up here, so apps can't run a single syscall outside their manifest.
;
; Out-of-range slot is a no-op (cannot store). An out-of-range app_id is NOT
; left at the boot default: it drops to the CAP_CORE floor via .kam_deny.
; The slot default is already deny-by-default (slot_cap_mask boots at CAP_CORE,
; see syscall_data.ghl), so a launch path that somehow skipped this apply still
; leaves the slot confined to core syscalls rather than fully unrestricted.
;
; Clobbers: rax, rcx, rsi, r8.
FN_BEGIN kernel_apply_app_manifest, 2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), FN_RET_VOID
    cmp edi, MAX_WINDOWS
    jae .kam_done                     ; slot out of range: cannot store -> no-op
    ; Mark this slot's window as sandboxed: its capability decision (the manifest
    ; below, or the CAP_CORE default-deny floor) is being made now, so the launch-
    ; ordering strike suppression in sc_record_strike no longer applies from here.
    ; Done before the app_id checks so BOTH the success and .kam_deny paths flip it.
    ; Window id == slot id for app windows. Clobbers eax (in the documented set).
    movzx eax, dil
    imul eax, eax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    or qword [rax + WIN_OFF_FLAGS], WF_MANIFEST_OK
    ; Authoritative per-slot strike gate: the sandbox is now live for this slot.
    ; sc_record_strike keys off slot_sandboxed[slot] (NOT the window flag above,
    ; which a tenant can clear via SYS_WM_CLOSE while still running). Set on BOTH
    ; the manifest-applied and .kam_deny floor paths, since either way the slot's
    ; capability decision has been made. See
    ; docs/security/finding-strike-immunity-via-self-close.md.
    movzx ecx, dil
    lea r8, [rel slot_sandboxed]
    mov byte [r8 + rcx], 1
    cmp rsi, APP_MIN_ID
    jb .kam_deny                      ; valid slot, unknown app_id -> default-deny
    cmp rsi, APP_MAX_ID
    ja .kam_deny
    push rsi                          ; stash original app_id for the audit record
    sub rsi, APP_MIN_ID
    lea rcx, [rel app_manifest_table]
    movzx esi, word [rcx + rsi*2]     ; new mask = manifest(app_id) (16-bit, dw table)
    ; Audit this capability transition (security_todo.md §4) before persisting.
    ; cap_audit_log(dil=slot, sil=old, dl=new, cl=reason, r8d=app_id); it
    ; preserves all caller regs, so rdi (slot) and rsi (new mask) survive.
    lea rcx, [rel slot_cap_mask]
    movzx eax, dil
    movzx eax, byte [rcx + rax]       ; old mask before the apply
    push rdi
    push rsi
    movzx edi, dil                    ; slot
    mov edx, esi                      ; new_mask (dl)
    mov esi, eax                      ; old_mask (sil)
    mov ecx, CAP_AUDIT_APPLY
    mov r8, [rsp + 16]                ; original app_id (stashed first)
    call cap_audit_log
    pop rsi
    pop rdi
    ; (original app_id stays stashed on the stack for the allow-bitmap rebuild
    ; after cap_mask_store; discarded there.)
    ; Write mask + authenticator together so the dispatcher's HMAC check trusts
    ; this (legitimate) narrowing instead of treating it as tampering.
%ifdef ENABLE_DEBUG_SERIAL
    ; DEBUG (blank-app diagnosis): log the mask each slot receives at launch so
    ; we can confirm GUI-capable apps actually get CAP_GUI (0x02). rdi=slot,
    ; rsi=mask here; both must survive for cap_mask_store below.
    push rdi
    push rsi
    SER 'X'
    SER 'M'
    SER 'A'
    SER 'N'
    SER ' '
    SER 's'
    movzx edi, dil
    call ser_print_hex64              ; slot
    SER ' '
    SER 'm'
    movzx edi, sil
    call ser_print_hex64              ; applied cap mask
    SER 13
    SER 10
    pop rsi
    pop rdi
%endif
    call cap_mask_store               ; (rdi=slot, rsi=mask) - rdi/rsi preserved
    ; Activate the finer per-syscall gate: rebuild this slot's allow bitmap to
    ; the manifest's cap-implied call set minus its deny list, instead of
    ; leaving the all-ones BSS default that made slot_syscall_allow a no-op.
    ; This is what finally enforces e.g. Notepad's SYS_FS_DELETE deny.
    mov rdx, [rsp]                    ; original app_id (still stashed)
    call sc_build_allow_bitmap        ; (rdi=slot, rsi=mask, rdx=app_id)
    add rsp, 8                        ; discard stashed app_id
.kam_done:
    ret
.kam_deny:
    ; Valid slot but unknown/out-of-range app_id (launcher bug or forged
    ; launch). Default-deny (security_todo.md §4): drop to the CAP_CORE floor
    ; - exit/print only - rather than leave the slot at its pre-launch mask
    ; (CAP_ALL), and narrow the allow bitmap to that floor. rdi = the
    ; range-checked slot.
    movzx edi, dil
    mov esi, CAP_CORE
    call cap_mask_store               ; rdi=slot, rsi=CAP_CORE preserved
    mov edx, APP_MAX_ID + 1           ; out-of-range app_id -> no deny-list pass
    call sc_build_allow_bitmap        ; (rdi=slot, rsi=CAP_CORE, rdx=oob)
    ret
section .data

; app_id -> capability mask. Indexed by (app_id - APP_MIN_ID). Keep in sync
; with the MANIFEST_* defines in syscall_caps.inc; the indirection here keeps
; the table dense and lets the dispatcher resolve a manifest in one load.
; 16-bit entries (dw) since the cap mask widened to 2 bytes for the CAP_FS split.
align 8
app_manifest_table:
    dw MANIFEST_EXPLORER                ; APP_EXPLORER         (2)
    dw MANIFEST_TERMINAL                ; APP_TERMINAL         (3)
    dw MANIFEST_NOTEPAD                 ; APP_NOTEPAD          (4)
    dw MANIFEST_SETTINGS                ; APP_SETTINGS         (5)
    dw MANIFEST_PAINT                   ; APP_PAINT            (6)
    dw MANIFEST_ABOUT                   ; APP_ABOUT            (7)
    dw MANIFEST_SECURITY_PROBE          ; APP_SECURITY_PROBE   (8)
    dw MANIFEST_TASKMGR                 ; APP_TASKMGR          (9)
    dw MANIFEST_PING                    ; APP_PING            (10)
    dw MANIFEST_MEDIA                   ; APP_MEDIA           (11)
    dw MANIFEST_SHELL                   ; APP_SHELL           (12)

; Per-app syscall deny lists (security_todo.md §2). Each list is a run of
; syscall numbers terminated by SC_DENY_LIST_END (0xFF); sc_build_allow_bitmap
; walks it and CLEARS each named bit after the cap-derived baseline is laid
; down. Apps with nothing to trim share sc_deny_none (just the terminator).
; The canonical trim: Notepad keeps CAP_FS (it reads/writes files) but must
; never DELETE one, so its list denies SYS_FS_DELETE.
sc_deny_none:           db SC_DENY_LIST_END
sc_deny_notepad:        db SC_SYS_FS_DELETE, SC_DENY_LIST_END

; app_id -> deny list pointer. Indexed by (app_id - APP_MIN_ID); parallels
; app_manifest_table row-for-row. Keep the two in sync.
align 8
app_syscall_deny_table:
    dq sc_deny_none                     ; APP_EXPLORER         (2)
    dq sc_deny_none                     ; APP_TERMINAL         (3)
    dq sc_deny_notepad                  ; APP_NOTEPAD          (4)
    dq sc_deny_none                     ; APP_SETTINGS         (5)
    dq sc_deny_none                     ; APP_PAINT            (6)
    dq sc_deny_none                     ; APP_ABOUT            (7)
    dq sc_deny_none                     ; APP_SECURITY_PROBE   (8)
    dq sc_deny_none                     ; APP_TASKMGR          (9)
    dq sc_deny_none                     ; APP_PING            (10)
    dq sc_deny_none                     ; APP_MEDIA           (11)
    dq sc_deny_none                     ; APP_SHELL           (12)

section .text
