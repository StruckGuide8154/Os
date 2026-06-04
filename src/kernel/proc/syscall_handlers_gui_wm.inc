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
    ; NexusHL callers sometimes leave stale high halves in argument registers;
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
    test rax, rax                         ; don't keep the pointer — handlers
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
    ; was being passed as title and h as width — every call failed the
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
    call sc_validate_user_io_range
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
    ; — combined with l3_translate_target's blob-region remapping — turns
    ; into cross-slot code execution at attacker-chosen offsets.
    mov rcx, r15
    imul rcx, APP_SLOT_SIZE
    add rcx, [rel l3_app_arena_base_v]
    cmp [rax + WIN_OFF_APPDATA], rcx
    jne .sc_wm_handlers_reject
    ; CPI-lite: stamp the per-window tag onto both callback fields before
    ; commit. Sign each handler against (&window, field_offset) so a tag
    ; valid for CLICKFN can't be replayed in KEYFN or another window.
    ; Stash the raw key_fn and the window ptr first — both helper calls
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
    ; WIN_OFF_USER_ARG. Bounds check win_id and require ACTIVE. Allowed iff:
    ;   (a) caller's slot owns the target window (same-slot writer), OR
    ;   (b) the field is still zero — first-write by the window's creator,
    ;       which lives in a different slot than the freshly-allocated one.
    ; Without (a)/(b) any app can clobber any active window's user_arg.
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
    je .sc_wm_set_user_arg_ok
    cmp qword [rax + 160], 0          ; WIN_OFF_USER_ARG
    jne .sc_wm_set_user_arg_reject
.sc_wm_set_user_arg_ok:
    ; Preserve the "zero == no selection" sentinel: don't stamp a tag onto
    ; a zero value, otherwise readers couldn't distinguish "never set" from
    ; "explicitly set to zero" — and the tag verifier would reject 0 too.
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
    call sc_validate_user_io_range
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
    ; Slot is being recycled — restore an unsandboxed cap mask so the next
    ; app that lands here isn't accidentally constrained by the prior
    ; tenant's manifest. The new tenant re-narrows via its own declare call.
    ; Re-stamp the authenticator alongside the mask (cap_mask_store) so the
    ; reset mask is recognised as legitimate, not as tampering, at the next
    ; dispatch for this slot. Default-deny (security_todo.md §4): a recycled
    ; slot drops to CAP_CORE, not CAP_ALL — the next tenant re-narrows to its
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

; SYS_DISPLAY_NATIVE — return the monitor's native (boot-time) framebuffer
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

; SYS_DISPLAY_SIZE — return the *current* logical desktop size packed the
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

