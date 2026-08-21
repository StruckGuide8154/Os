; ============================================================================
; syscall_handlers_gui_wm.inc
; syscall_entry handlers: GUI rect/text, FS count/entry/chdir/read/write, WM create/handlers/user-arg/close, display
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
.sc_gui_rect:
    ; rdi=x, rsi=y, rdx=w, r10=h, r8=color.  User syscalls must not feed
    ; out-of-range low 32-bit values into the renderer's clipping arithmetic.
    ; GritHL callers sometimes leave stale high halves in argument registers;
    ; the renderer consumes edi/esi/edx/ecx, so validate those exact values.
    cmp edi, [scr_width]
    ja .sc_gui_rect_reject
    cmp esi, [scr_height]
    ja .sc_gui_rect_reject
    cmp edx, [scr_width]
    ja .sc_gui_rect_reject
    cmp r10d, [scr_height]
    ja .sc_gui_rect_reject
    mov rcx, r10
    call render_rect
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_gui_rect_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_gui_text:
    ; rdi=x, rsi=y, rdx=cstring, r10=fg_color, r8=bg_color
    cmp edi, [scr_width]
    ja .sc_gui_text_reject
    cmp esi, [scr_height]
    ja .sc_gui_text_reject
    mov rdi, rdx
    mov rsi, SYSCALL_MAX_STR_LEN
    call sc_validate_user_cstring
    test eax, eax
    jz .sc_gui_text_reject
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    mov r10, [rsp + ALL_R10]
    mov rcx, r10
    mov r8,  [rsp + ALL_R8]
    call render_text
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_gui_text_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_fs_count:
    call fat16_file_count
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_fs_entry:
    push rdi
    SER 'F'
    SER 'E'
    pop rdi
    push rdi
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    ; rdi = valid-entry index. Returns rax = packed opaque handle, or 0.
    ;
    ; Phase 2 of the handle-table refactor: instead of copying the FAT16
    ; entry into a per-slot snapshot region and returning that kernel
    ; pointer to ring 3, we allocate a HANDLE_KIND_DIR_ENTRY entry whose
    ; payload is the valid-entry index. Every downstream FS syscall
    ; (read / format_name / delete / rename / open_file_np /
    ; open_file_media) resolves through handle_resolve + fat16_get_entry,
    ; so ring 3 never observes a kernel VA. The legacy snapshot cache and
    ; sc_validate_dir_entry_handle / sc_dir_entry_handle_to_kernel pair
    ; have been removed.
    xor eax, eax
    cmp rdi, FAT16_MAX_ENTRIES
    jae .sc_fs_entry_done
    push rdi                              ; preserve index
    call fat16_get_entry                  ; confirms the index resolves; we
    test rax, rax                         ; don't keep the pointer - handlers
    pop rdi                               ; re-resolve fresh each call.
    jz .sc_fs_entry_fail
    ; rdi still = valid-entry index (the handle payload).
    mov r8, rdi
    mov rax, r15
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    mov rdi, rax                          ; rdi = slot base
    mov al, HANDLE_KIND_DIR_ENTRY
    call handle_alloc                     ; eax = handle or 0 (table full)
    jmp .sc_fs_entry_done
.sc_fs_entry_fail:
    xor eax, eax
.sc_fs_entry_done:
    push rax
    SER 'F'
    SER 'H'
    mov rdi, rax
    call ser_print_hex64
    SER 13
    SER 10
    pop rax
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_fs_chdir:
    mov rax, rdi
    shr rax, 16
    jnz .sc_fs_chdir_reject
    test edi, edi
    jz .sc_fs_chdir_call
    cmp edi, 2
    jb .sc_fs_chdir_reject
    cmp edi, 0xFFF8
    jae .sc_fs_chdir_reject
.sc_fs_chdir_call:
    mov eax, edi
    call fat16_change_dir
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_chdir_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_wm_create:
    mov rdi, r8
    mov rsi, 64
    call sc_validate_user_cstring
    test eax, eax
    jz .sc_wm_create_reject
    mov rdi, r9
    call sc_validate_callback_target
    test eax, eax
    jz .sc_wm_create_reject
    mov rax, [rsp + ALL_RDI]
    or  rax, [rsp + ALL_RSI]
    or  rax, [rsp + ALL_RDX]
    or  rax, [rsp + ALL_R10]
    shr rax, 32
    jnz .sc_wm_create_reject
    mov eax, [rsp + ALL_RDX]
    cmp eax, MIN_WINDOW_W
    jb .sc_wm_create_reject
    mov eax, [rsp + ALL_R10]
    cmp eax, MIN_WINDOW_H
    jb .sc_wm_create_reject
    mov eax, [rsp + ALL_RDI]
    add eax, [rsp + ALL_RDX]
    jc .sc_wm_create_reject
    cmp eax, SCREEN_WIDTH
    ja .sc_wm_create_reject
    mov eax, [rsp + ALL_RSI]
    add eax, [rsp + ALL_R10]
    jc .sc_wm_create_reject
    cmp eax, SCREEN_HEIGHT
    ja .sc_wm_create_reject
    ; Remap user args (x, y, w, h, title, drawfn) to wm_create_window_ex's
    ; signature (rdi=title, rsi=x, rdx=y, rcx=w, r8=h, r9=drawfn). The
    ; validation above reads ALL_RDX as width / ALL_R10 as height, so the
    ; user-facing order must keep dimensions in slots 2-3; title sits at
    ; slot 4 (FN_KIND_CSTRING in the syscall table). Before this remap, w
    ; was being passed as title and h as width - every call failed the
    ; min-width check inside wm_create_window_ex.
    mov rdi, [rsp + ALL_R8]      ; title
    mov rsi, [rsp + ALL_RDI]     ; x
    mov rdx, [rsp + ALL_RSI]     ; y
    mov rcx, [rsp + ALL_RDX]     ; w
    mov r8,  [rsp + ALL_R10]     ; h
    mov r9,  [rsp + ALL_R9]      ; drawfn
    ; DEBUG: log every SYS_WM_CREATE with the calling slot (r15) and the drawfn
    ; so the serial log shows which app is spawning windows and how often.
    call dbg_wmcreate_log
    call wm_create_window_ex
    ; Mark the new window as manifested (informational window flag). NOTE: strike
    ; accounting no longer keys off WIN_OFF_FLAGS - it uses the per-slot
    ; slot_sandboxed[] byte (keyed on r15, the calling slot), so a running tenant
    ; cannot become strike-immune by creating/closing windows regardless of this
    ; flag. See docs/security/finding-strike-immunity-via-self-close.md.
    cmp rax, -1
    je .sc_wm_create_store
    movzx ecx, ax
    ; Self-bound the pool index before it is turned into a store address.
    ; `movzx ecx, ax` keeps only the low 16 bits, so the `cmp rax, -1` above is
    ; the ONLY thing standing between a non-index return value and the OR write
    ; below -- and it is a 64-bit compare, so it would miss a 32-bit-width
    ; failure code (eax = -1 leaves rax = 0x00000000FFFFFFFF, ax = 0xFFFF, an
    ; index of 65535 => a write ~16 MiB past WINDOW_POOL_ADDR). wm_do_create
    ; currently returns a full-width `mov rax, -1`, so this is unreachable
    ; today, but the write target must not depend on a callee's choice of
    ; return width. Bound it here and fail closed.
    cmp ecx, MAX_WINDOWS
    jae .sc_wm_create_store
    imul ecx, ecx, WINDOW_STRUCT_SIZE
    add rcx, WINDOW_POOL_ADDR
    ; App-created windows are provisioned by their already-sandboxed caller (the
    ; calling slot's manifest is live and it supplied its own drawfn), so there
    ; is no launch gap to protect against -- mark the window ready to render now.
    ; WF_READY is the wm_draw_window gate; without it the app's own window would
    ; never paint. (Informational WF_MANIFEST_OK retained; strike accounting
    ; keys off slot_sandboxed[r15], not window flags.)
    or qword [rcx + WIN_OFF_FLAGS], WF_MANIFEST_OK | WF_READY
.sc_wm_create_store:
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_wm_create_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_fs_read:
    ; rdi = dir-entry handle, rsi = user buffer, rdx = length.
    ; sc_resolve_dir_entry_arg rewrites rdi to the real FAT16 root-cache
    ; entry pointer (kernel-internal); after this point rdi is a kernel
    ; VA and must not flow back to ring 3.
    call sc_resolve_dir_entry_arg
    test eax, eax
    jz .sc_fs_read_reject
    push rdi                              ; save kernel entry pointer
    mov rdi, rsi
    mov rsi, rdx
    call sc_validate_user_write           ; OUTPUT: file data written into user buf (slot-only)
    pop rdi
    test eax, eax
    jz .sc_fs_read_reject
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    call fat16_read_file
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_read_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_wm_handlers:
    ; Reject out-of-range window indices. Unsigned compare catches both
    ; negative (large unsigned) and >=MAX_WINDOWS values; without this
    ; ring-3 can turn RDI into an arbitrary kernel write primitive by
    ; choosing any RDI such that WINDOW_POOL_ADDR + RDI*256 wraps onto a
    ; chosen kernel address.
    cmp rdi, MAX_WINDOWS
    jae .sc_wm_handlers_reject
    push rdi
    mov rdi, rsi
    call sc_validate_callback_target
    pop rdi
    test eax, eax
    jz .sc_wm_handlers_reject
    push rdi
    mov rdi, rdx
    call sc_validate_callback_target
    pop rdi
    test eax, eax
    jz .sc_wm_handlers_reject
    ; sc_validate_callback_target uses RSI as the range length, so reload the
    ; original handler pointers from the saved syscall frame before storing.
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    mov rax, rdi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    ; Only active windows may have handlers installed. This prevents a
    ; ring-3 app from hijacking a stale slot.
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .sc_wm_handlers_reject
    ; Ownership check: caller's slot must own the target window. Without
    ; this, any app can install callbacks into any other app's window, which
    ; - combined with l3_translate_target's blob-region remapping - turns
    ; into cross-slot code execution at attacker-chosen offsets.
    mov rcx, r15
    imul rcx, APP_SLOT_SIZE
    add rcx, [rel l3_app_arena_base_v]
    cmp [rax + WIN_OFF_APPDATA], rcx
    jne .sc_wm_handlers_reject
    ; CPI-lite: stamp the per-window tag onto both callback fields before
    ; commit. Sign each handler against (&window, field_offset) so a tag
    ; valid for CLICKFN can't be replayed in KEYFN or another window.
    ; Stash the raw key_fn and the window ptr first - both helper calls
    ; below clobber rdx/rsi/rdi.
    push rax                          ; [rsp+8] = &window
    push rdx                          ; [rsp+0] = raw key_fn
    mov rdi, rsi                      ; raw click_fn
    mov rsi, rax                      ; &window
    mov rdx, WIN_OFF_CLICKFN
    call cpi_sign_callback
    mov r10, rax                      ; signed click_fn
    pop rdi                           ; raw key_fn
    mov rsi, [rsp]                    ; &window (still on stack)
    mov rdx, WIN_OFF_KEYFN
    call cpi_sign_callback
    mov r11, rax                      ; signed key_fn
    pop rax                           ; &window
    mov [rax + WIN_OFF_CLICKFN], r10
    mov [rax + WIN_OFF_KEYFN], r11
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_wm_handlers_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_wm_set_user_arg:
    ; rdi = win_id, rsi = up-to-48-bit opaque value to stash at
    ; WIN_OFF_USER_ARG. Bounds check win_id and require ACTIVE. Only the caller's slot may write its own window's user_arg.
    ;
    ; Tagged poisoning: the stored qword is (value | (tag << 48)), where tag
    ; is a per-window secret = low16(kernel_canary ^ &window). On read via
    ; SYS_WM_GET_USER_ARG the kernel recomputes the tag and rejects any
    ; value whose top 16 bits do not match. That removes a type-confusion
    ; primitive where a malicious app could feed a freshly-fabricated qword
    ; (e.g. a kernel pointer pattern) into a peer window's draw fn before
    ; the legitimate creator's tag has been stamped. Callers must therefore
    ; keep the top 16 bits clear; a non-zero top half is rejected outright.
    cmp rdi, MAX_WINDOWS
    jae .sc_wm_set_user_arg_reject
    mov rax, rdi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .sc_wm_set_user_arg_reject
    mov rdx, 0xFFFF000000000000
    test rsi, rdx
    jnz .sc_wm_set_user_arg_reject
    mov rcx, r15
    imul rcx, APP_SLOT_SIZE
    add rcx, [rel l3_app_arena_base_v]
    cmp [rax + WIN_OFF_APPDATA], rcx
    jne .sc_wm_set_user_arg_reject
    ; Preserve the "zero == no selection" sentinel: don't stamp a tag onto
    ; a zero value, otherwise readers couldn't distinguish "never set" from
    ; "explicitly set to zero" - and the tag verifier would reject 0 too.
    test rsi, rsi
    jz .sc_wm_set_user_arg_store
    ; tag = low16(kernel_canary ^ &window); KDOM_USER_ARG is 0 so this is
    ; byte-identical to the former hand-written sequence (see §13).
    KHMAC_TAG rdx, edx, dx, rax, 0, KDOM_USER_ARG
    shl rdx, 48
    or rsi, rdx
.sc_wm_set_user_arg_store:
    mov [rax + 160], rsi              ; WIN_OFF_USER_ARG
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_wm_set_user_arg_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_wm_get_user_arg:
    ; rdi = win_id. Returns the low-48-bit value (zero-extended), or -1 if
    ; the stored qword's top-16 tag doesn't match the per-window tag computed
    ; from kernel_canary ^ &window. A stored qword of exactly 0 returns 0
    ; (the "never set" sentinel; see sc_wm_set_user_arg above).
    cmp rdi, MAX_WINDOWS
    jae .sc_wm_get_user_arg_reject
    mov rax, rdi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .sc_wm_get_user_arg_reject
    mov rdx, r15
    imul rdx, APP_SLOT_SIZE
    add rdx, [rel l3_app_arena_base_v]
    cmp [rax + WIN_OFF_APPDATA], rdx
    jne .sc_wm_get_user_arg_reject
    mov rcx, [rax + 160]              ; stored qword
    test rcx, rcx
    jz .sc_wm_get_user_arg_zero
    KHMAC_TAG rdx, edx, dx, rax, 0, KDOM_USER_ARG
    shl rdx, 48                       ; expected tag bits
    mov rsi, rcx
    mov r8, 0xFFFF000000000000
    and rsi, r8
    cmp rsi, rdx
    jne .sc_wm_get_user_arg_reject
    mov rdx, 0x0000FFFFFFFFFFFF
    and rcx, rdx
    mov [rsp + ALL_RAX], rcx
    jmp .done
.sc_wm_get_user_arg_zero:
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_wm_get_user_arg_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_fs_format_name:
    ; rdi = handle, rsi = user 16-byte output buffer.
    call sc_resolve_dir_entry_arg
    test eax, eax
    jz .sc_fs_format_name_reject
    push rdi                              ; kernel entry pointer
    mov rdi, rsi
    mov rsi, 16
    call sc_validate_user_write           ; OUTPUT: formatted name written to user buf (slot-only)
    pop rdi
    test eax, eax
    jz .sc_fs_format_name_reject
    mov rsi, [rsp + ALL_RSI]
    ; fat16_format_name takes (rdi = out buf, rsi = entry pointer).
    xchg rdi, rsi
    call fat16_format_name
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_format_name_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_app_launch:
    mov rax, rdi
    shr rax, 32
    jnz .sc_app_launch_reject
    cmp edi, APP_MIN_ID
    jb .sc_app_launch_reject
    cmp edi, APP_MAX_ID
    ja .sc_app_launch_reject
    mov edi, edi
    xor esi, esi
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    call app_launch
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_app_launch_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_wm_list:
    ; rdi = user out buffer, rsi = max_entries. Writes up to min(max_entries,
    ; MAX_WINDOWS) WM_LIST_REC-byte records for each WF_ACTIVE window and returns
    ; the count. Read-only: the kernel never trusts the buffer for anything but a
    ; bounded write, and exposes only id/flags/title - no kernel pointers cross.
    mov rcx, rsi                          ; requested cap
    cmp rcx, MAX_WINDOWS
    jbe .wl_have_cap
    mov rcx, MAX_WINDOWS
.wl_have_cap:
    test rcx, rcx
    jz .wl_zero                           ; cap 0 -> write nothing, return 0
    ; Validate the user buffer for cap * WM_LIST_REC bytes before any store.
    mov rax, rcx
    imul rax, WM_LIST_REC
    push rdi                              ; preserve dst + cap across validate
    push rcx
    mov rsi, rax
    call sc_validate_user_write           ; OUTPUT: window records written to user buf (slot-only)
    pop rcx
    pop rdi
    test eax, eax
    jz .sc_wm_list_reject
    mov r8, WINDOW_POOL_ADDR
    xor r9d, r9d                          ; pool index
    xor r10d, r10d                        ; written count
.wl_loop:
    cmp r9d, MAX_WINDOWS
    jge .wl_done
    cmp r10, rcx                          ; reached caller's cap?
    jge .wl_done
    test qword [r8 + WIN_OFF_FLAGS], WF_ACTIVE
    jz .wl_next
    ; Never list the ring-3 desktop shell itself: gshell reads SYS_WM_LIST to
    ; populate its taskbar, so listing the WF_SHELL window would show the desktop
    ; as an open "window" in its own taskbar.
    test qword [r8 + WIN_OFF_FLAGS], WF_SHELL
    jnz .wl_next
    USER_ACCESS_BEGIN
    mov eax, [r8 + WIN_OFF_ID]
    mov [rdi + 0], eax
    mov eax, [r8 + WIN_OFF_FLAGS]
    mov [rdi + 4], eax
    mov rax, [r8 + WIN_OFF_TITLE + 0]
    mov [rdi + WM_LIST_TITLE_OFF + 0], rax
    mov rax, [r8 + WIN_OFF_TITLE + 8]
    mov [rdi + WM_LIST_TITLE_OFF + 8], rax
    mov rax, [r8 + WIN_OFF_TITLE + 16]
    mov [rdi + WM_LIST_TITLE_OFF + 16], rax
    mov rax, [r8 + WIN_OFF_TITLE + 24]
    mov [rdi + WM_LIST_TITLE_OFF + 24], rax
    mov rax, [r8 + WIN_OFF_TITLE + 32]
    mov [rdi + WM_LIST_TITLE_OFF + 32], rax
    USER_ACCESS_END
    add rdi, WM_LIST_REC
    inc r10
.wl_next:
    add r8, WINDOW_STRUCT_SIZE
    inc r9d
    jmp .wl_loop
.wl_done:
    mov [rsp + ALL_RAX], r10
    jmp .done
.wl_zero:
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_wm_list_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_fs_write:
    push rdi
    mov rsi, 11
    call sc_validate_user_range
    pop rdi
    test eax, eax
    jz .sc_fs_write_reject
    push rdi
    mov rdi, rsi
    mov rsi, rdx
    call sc_validate_user_io_range
    pop rdi
    test eax, eax
    jz .sc_fs_write_reject
    mov rdi, [rsp + ALL_RDI]
    mov rsi, [rsp + ALL_RSI]
    mov rdx, [rsp + ALL_RDX]
    call fat16_write_file
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_write_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_fs_sync_root:
    test r15d, r15d
    jnz .sc_fs_sync_root_reject
    call fat16_sync_root
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_sync_root_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_wm_close:
    cmp rdi, MAX_WINDOWS
    jae .sc_wm_close_reject
    cmp edi, r15d
    jne .sc_wm_close_reject
    mov rax, rdi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .sc_wm_close_reject
    mov rdx, r15
    imul rdx, APP_SLOT_SIZE
    add rdx, [rel l3_app_arena_base_v]
    cmp [rax + WIN_OFF_APPDATA], rdx
    jne .sc_wm_close_reject
    call wm_close_window
    ; Slot is being recycled - restore an unsandboxed cap mask so the next
    ; app that lands here isn't accidentally constrained by the prior
    ; tenant's manifest. The new tenant re-narrows via its own declare call.
    ; Re-stamp the authenticator alongside the mask (cap_mask_store) so the
    ; reset mask is recognised as legitimate, not as tampering, at the next
    ; dispatch for this slot. Default-deny (security_todo.md §4): a recycled
    ; slot drops to CAP_CORE, not CAP_ALL - the next tenant re-narrows to its
    ; own manifest via kernel_apply_app_manifest at launch (APPLY_MANIFEST).
    ; Audit the transition first (cap_audit_log preserves all caller regs).
    lea rcx, [rel slot_cap_mask]
    movzx edx, r15b
    movzx ebx, byte [rcx + rdx]       ; old mask before the reset
    movzx edi, r15b
    mov esi, ebx                      ; old_mask
    mov edx, CAP_CORE                 ; new_mask
    mov ecx, CAP_AUDIT_RECYCLE
    xor r8d, r8d                      ; no app_id for a recycle
    call cap_audit_log
    movzx edi, r15b
    mov esi, CAP_CORE
    call cap_mask_store               ; (rdi=slot, rsi=CAP_CORE)
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_wm_close_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_display_set_mode:
    ; Runtime feature gate (boot_features.ghl): if FEAT_SYSCALL_SET_MODE is
    ; disabled via BOOTCFG (disable=setmode), reject the mode-set outright. This
    ; is the representative per-syscall gate AND a hard lock against ring-3
    ; mode-set as a secure-boot profile. Save the geometry args around the call
    ; (we overwrite rdi with the feature bit; rsi/rdx are caller-preserved by
    ; feat_enabled but we push all three for clarity and 16-byte alignment).
    push rdi
    push rsi
    push rdx
    mov rdi, FEAT_SYSCALL_SET_MODE
    call feat_enabled
    pop rdx
    pop rsi
    pop rdi
    test rax, rax
    jz .sc_display_set_mode_reject
    ; rdi=width, rsi=height, rdx=bpp. Keep ring-3 geometry inside the
    ; fixed boot back-buffer before the display driver touches global state.
    mov rax, rdi
    or  rax, rsi
    or  rax, rdx
    shr rax, 32
    jnz .sc_display_set_mode_reject
    test edi, edi
    jz .sc_display_set_mode_reject
    test esi, esi
    jz .sc_display_set_mode_reject
    cmp edx, 32
    jne .sc_display_set_mode_reject
    mov eax, edi
    mul esi
    jo .sc_display_set_mode_reject
    cmp eax, BOOT_BACK_BUFFER_SIZE / 4
    ja .sc_display_set_mode_reject
    mov edx, 32
    call display_set_mode
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_display_set_mode_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_cursor_init:
    call cursor_init
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_ticks:
    mov rax, [tick_count]
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_display_flags:
    ; Pack display state into a bit field:
    ;   bit 0 = vsync, bit 1 = fps overlay, bit 2 = stretch.
    ; New bits go in the high range; bit 0/1 are stable for old callers.
    xor eax, eax
    cmp byte [vsync_enabled], 0
    je .sc_display_flags_fps
    or eax, 1
.sc_display_flags_fps:
    cmp byte [fps_show], 0
    je .sc_display_flags_stretch
    or eax, 2
.sc_display_flags_stretch:
    cmp byte [display_stretch], 0
    je .sc_display_flags_done
    or eax, 4
.sc_display_flags_done:
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_display_set_flags:
    mov rax, rdi
    shr rax, 32
    jnz .sc_display_set_flags_reject
    mov eax, edi
    and eax, 1
    mov [vsync_enabled], al
    mov eax, edi
    shr eax, 1
    and eax, 1
    mov [fps_show], al
    mov eax, edi
    shr eax, 2
    and eax, 1
    mov [display_stretch], al
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_display_set_flags_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; SYS_MOUSE_SENSE - return packed per-axis pointer sensitivity (tenths):
; x in bits [15:0], y in bits [31:16].
.sc_mouse_sense:
    movzx eax, word [mouse_sense_x]
    movzx ecx, word [mouse_sense_y]
    shl ecx, 16
    or eax, ecx
    mov [rsp + ALL_RAX], rax
    jmp .done

; SYS_SET_MOUSE_SENSE(packed) - x in [15:0], y in [31:16], each clamped to
; [1,50] = 0.1x..5.0x. Out-of-range bits above 32 are rejected.
.sc_set_mouse_sense:
    mov rax, rdi
    shr rax, 32
    jnz .sc_set_mouse_sense_reject
    movzx eax, di                ; x (low 16)
    call .clamp_sense
    mov [mouse_sense_x], eax
    mov eax, edi
    shr eax, 16
    movzx eax, ax                ; y (high 16)
    call .clamp_sense
    mov [mouse_sense_y], eax
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_set_mouse_sense_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done
; clamp eax to [1,50]
.clamp_sense:
    cmp eax, 1
    jge .clamp_sense_lo_ok
    mov eax, 1
.clamp_sense_lo_ok:
    cmp eax, 50
    jle .clamp_sense_hi_ok
    mov eax, 50
.clamp_sense_hi_ok:
    ret

; SYS_DISPLAY_NATIVE - return the monitor's native (boot-time) framebuffer
; size as a packed qword: width in bits [31:0], height in bits [63:32].
; Apps use this to surface a "Use native resolution" choice that survives
; mode changes (scr_width/scr_height can drift away from the native size
; once display_set_mode runs).
.sc_display_native:
    mov eax, [fb_native_width]
    mov ecx, [fb_native_height]
    shl rcx, 32
    or rax, rcx
    mov [rsp + ALL_RAX], rax
    jmp .done

; SYS_DISPLAY_SIZE - return the *current* logical desktop size packed the
; same way as SYS_DISPLAY_NATIVE. This drifts whenever display_set_mode
; succeeds, so apps that want to show "current resolution" read this on
; every draw rather than caching it.
.sc_display_size:
    mov eax, [scr_width]
    mov ecx, [scr_height]
    shl rcx, 32
    or rax, rcx
    mov [rsp + ALL_RAX], rax
    jmp .done

