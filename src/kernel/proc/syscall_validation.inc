; SMAP/SMEP macros (USER_ACCESS_BEGIN/END) and smap_smep_init. Guarded by its
; own %ifndef so a second include from syscall.asm is harmless. This is the
; translation unit that emits smap_smep_init (main.asm references it extern).
%include "smap.inc"

; ----------------------------------------------------------------------------
; MIGRATED to GritHLK (Stage 2a): the following LEAF validators are now emitted
; from src/kernel/grithlk/syscall_validate.ghl as structured zero-asm fns with
; the SAME global symbol names and the SAME register ABI:
;     sc_get_slot_bounds, sc_range_in_bounds, sc_validate_user_range,
;     sc_validate_user_io_range, sc_validate_callback_target
; The generated build/ghl/syscall_validate.asm is %include'd by kernel_build.asm
; before syscall.asm, so callers here and in the handler .inc files still link.
; (sc_range_in_bounds/sc_validate_user_range now use signed compares for the
;  bounds tests; equivalent for the low-half user VAs these ever see.)
;
; The two helpers below STAY in assembly: they read USER memory byte-by-byte
; inside USER_ACCESS_BEGIN/END (stac/clac only under ENABLE_SMAP); the GHLK
; smap_open/close intrinsics emit UNCONDITIONAL stac/clac, which would #UD on a
; non-SMAP build - so porting them would not be behavior-preserving.
; ----------------------------------------------------------------------------

; RDI=ptr, RSI=max_len -> EAX=1 if a NUL-terminated string lives entirely in
; the current app slot or the built-in user blob.
sc_validate_user_cstring:
    push rdi
    push rsi
    push rcx
    push r9
    push r10
    push r11
    mov r10, rdi
    mov r11, rsi
    xor r9d, r9d
    xor rcx, rcx
.uvc_loop:
    cmp rcx, r11
    jae .uvc_done
    lea rdi, [r10 + rcx]
    mov rsi, 1
    call sc_validate_user_range
    test eax, eax
    jz .uvc_done
    USER_ACCESS_BEGIN                   ; SMAP: kernel reads a user-slot byte
    cmp byte [rdi], 0
    USER_ACCESS_END
    je .uvc_match
    inc rcx
    jmp .uvc_loop
.uvc_match:
    mov r9d, 1
.uvc_done:
    mov eax, r9d
    pop r11
    pop r10
    pop r9
    pop rcx
    pop rsi
    pop rdi
    ret

; RDI=ptr (NUL-terminated, already passed sc_validate_user_cstring so it lives
; in-slot and is NUL-terminated within RSI), RSI=max_len -> EAX=1 if the path is
; canonical/safe, EAX=0 to reject. Each user byte is read inside an
; USER_ACCESS_BEGIN/END bracket so SMAP builds don't #PF. Pure scan, no alloc.
; Reject rules (path-canonicalization guard for SYS_APP_OPEN):
;   - any byte < 0x20 that is not the terminating NUL: control/non-printable
;     bytes have no place in a command string and could smuggle separators.
;   - leading '/' or '\' as the first byte: absolute-path escape out of the slot
;     sandbox's notion of a relative command name.
;   - "<letter>:" as the first two bytes: Windows drive-absolute prefix escape.
;   - a ".." whole path component (".." at start or right after a separator AND
;     immediately followed by '/', '\', or NUL): directory-traversal escape.
;     "a..b" / "..foo" are ordinary names and are allowed.
; Separators are both '/' (0x2F) and '\' (0x5C).
;
; MEMORY-SAFETY (self-bounding, TOCTOU-free): every user byte this scan reads is
; first re-validated to lie inside the current app slot via sc_validate_user_range
; (R15 = slot, maintained by the dispatcher) BEFORE it is dereferenced - see the
; SPC_REQUIRE_INSLOT macro at each read site. The function therefore does NOT
; trust that sc_validate_user_cstring ran first on an identical buffer, nor that
; the NUL it found is still present: a concurrent same-slot writer (once per-CPU
; CR3 lets app code run on another core - see process_placement.inc) could flip
; that NUL after cstring passes, which would otherwise let this scan run all
; max_len bytes and read past the slot end when ptr sits near slot_end. Each read
; is independently bounded, so the scan is memory-safe under any concurrency.

; Reject the whole scan (EAX=0) unless the single user byte at RDI lives in the
; current app slot. rsi is dead here (max_len was copied to r11 at entry) and
; sc_validate_user_range preserves rcx/rdx/r8/r9/r10/r11/rdi/rsi/r15, so no scan
; state is lost across the call; only rax (the verdict) is clobbered.
%macro SPC_REQUIRE_INSLOT 0
    mov rsi, 1
    call sc_validate_user_range
    test eax, eax
    jz .spc_reject
%endmacro

sc_validate_path_canonical:
    push rcx                                ; index
    push rdx                                ; current byte
    push r8                                 ; lookahead / scratch byte
    push r9                                 ; at-component-start flag
    push r10                                ; base ptr
    push r11                                ; max_len
    mov r10, rdi
    mov r11, rsi
    xor rcx, rcx
    mov r9d, 1                              ; start of string == start of a component
.spc_loop:
    cmp rcx, r11                            ; safety bound: never scan past max_len
    jae .spc_ok                             ; ran out without hitting a bad byte
    lea rdi, [r10 + rcx]
    SPC_REQUIRE_INSLOT                          ; fail-closed if [ptr+rcx] left the slot
    USER_ACCESS_BEGIN                       ; SMAP: kernel reads a user-slot byte
    movzx edx, byte [rdi]
    USER_ACCESS_END
    test dl, dl
    jz .spc_ok                              ; NUL ends the scan -> canonical
    cmp dl, 0x20                            ; reject control / non-printable bytes
    jb .spc_reject
    ; absolute-path / drive-prefix checks only at the very first byte
    test rcx, rcx
    jnz .spc_not_first
    cmp dl, '/'
    je .spc_reject
    cmp dl, '\'
    je .spc_reject
    ; "<letter>:" drive-absolute prefix: byte0 is A-Z/a-z and byte1 is ':'
    mov r8d, edx
    or  r8b, 0x20                           ; fold to lowercase for the letter test
    cmp r8b, 'a'
    jb .spc_not_first
    cmp r8b, 'z'
    ja .spc_not_first
    cmp r11, 2                              ; need a second byte to be a prefix
    jb .spc_not_first
    lea rdi, [r10 + 1]
    SPC_REQUIRE_INSLOT                          ; byte1 (drive-prefix peek) must be in-slot
    USER_ACCESS_BEGIN
    movzx r8d, byte [rdi]
    USER_ACCESS_END
    cmp r8b, ':'
    je .spc_reject
.spc_not_first:
    ; ".." component detection: only when this '.' begins a component.
    cmp dl, '.'
    jne .spc_advance
    test r9d, r9d                           ; must be at a component start
    jz .spc_advance
    inc rcx                                 ; look at the next byte
    cmp rcx, r11
    jae .spc_ok                             ; lone '.' at slot/bound end -> fine
    lea rdi, [r10 + rcx]
    SPC_REQUIRE_INSLOT                          ; lookahead byte must be in-slot too
    USER_ACCESS_BEGIN
    movzx r8d, byte [rdi]
    USER_ACCESS_END
    cmp r8b, '.'
    jne .spc_after_dot                      ; ".x" - not a traversal; reprocess r8
    ; we have ".." - check the byte after it terminates the component
    inc rcx
    cmp rcx, r11
    jae .spc_reject                         ; ".." flush against the bound -> reject
    lea rdi, [r10 + rcx]
    SPC_REQUIRE_INSLOT                          ; lookahead byte must be in-slot too
    USER_ACCESS_BEGIN
    movzx r8d, byte [rdi]
    USER_ACCESS_END
    test r8b, r8b
    jz .spc_reject                          ; ".."<NUL>  -> traversal
    cmp r8b, '/'
    je .spc_reject                          ; ".."/      -> traversal
    cmp r8b, '\'
    je .spc_reject                          ; "..\"      -> traversal
    ; ".." followed by a name char (e.g. "..foo") is an ordinary name; the byte
    ; in r8b is the next char to classify. Fall through to reprocess it.
.spc_after_dot:
    ; r8b holds a byte we already consumed past; classify it like the main loop
    ; without re-reading. It is < 0x20? reject. It is a separator? mark start.
    cmp r8b, 0x20
    jb .spc_reject
    xor r9d, r9d
    cmp r8b, '/'
    je .spc_mark_start
    cmp r8b, '\'
    jne .spc_step
.spc_mark_start:
    mov r9d, 1
.spc_step:
    inc rcx
    jmp .spc_loop
.spc_advance:
    ; classify the current byte (in dl) for the next iteration's start flag
    xor r9d, r9d
    cmp dl, '/'
    je .spc_advance_start
    cmp dl, '\'
    jne .spc_advance_step
.spc_advance_start:
    mov r9d, 1
.spc_advance_step:
    inc rcx
    jmp .spc_loop
.spc_reject:
    xor eax, eax
    jmp .spc_done
.spc_ok:
    mov eax, 1
.spc_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; FAT16 dir-entry handles are now opaque indices in the per-slot handle
; table (see src/kernel/proc/handle_table.inc); the legacy
; sc_validate_dir_entry_handle / sc_dir_entry_handle_to_kernel pair has
; been removed. The validator's FN_KIND_HANDLE arm calls handle_resolve
; directly, and FS syscall handlers call sc_resolve_dir_entry_arg in
; syscall.asm to translate handle -> kernel root-cache entry pointer.
;
; The per-slot snapshot region (L3_DIR_ENTRY_CACHE_*) backed the old
; "dereference the returned pointer" contract for SYS_FS_ENTRY and is no
; longer used; ring 3 reads entry fields by value through
; SYS_FS_ENTRY_INFO. Slot 0x1D1000..0x1D5000 is currently unused and is
; reserved for future per-slot caches.

; sc_validate_callback_target - MIGRATED to GritHLK (Stage 2a). See
; src/kernel/grithlk/syscall_validate.ghl (RDI=callback target -> EAX=1 if null
; or 64 mapped bytes inside user-owned memory).
