; ============================================================================
; syscall_handlers_sys_fs.inc
; syscall_entry handlers: sysinfo, desktop bg, FS delete/rename/mkdir, open-file, handle close, fs_entry_info, app declare/open
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
.sc_sysinfo:
    ; rdi = selector, rsi = arg (e.g. core index). Returns a scalar in rax.
    ; Selectors 100..199 are reserved for fbperf (framebuffer perf/debug).
    xor eax, eax
    cmp rdi, 100
    jb  .si_legacy
    cmp rdi, 199
    ja  .si_check_sec
    extern fbperf_get
    call fbperf_get
    jmp .si_store
.si_check_sec:
    ; Selectors 200..240 reserved for the security-feature status inventory
    ; (security_status.asm) consumed by the Settings Security tab.
    cmp rdi, 240
    ja  .si_legacy
    extern security_status_query
    call security_status_query
    jmp .si_store
.si_legacy:
    cmp rdi, 0
    je .si_fps
    cmp rdi, 1
    je .si_ram_free
    cmp rdi, 2
    je .si_ram_max
    cmp rdi, 3
    je .si_cpu_mhz
    cmp rdi, 4
    je .si_cores
    cmp rdi, 5
    je .si_core_util
    cmp rdi, 6
    je .si_core_mhz
    cmp rdi, 16
    je .si_gpu_provider
    cmp rdi, 17
    je .si_gpu_bdf
    cmp rdi, 18
    je .si_gpu_id
    cmp rdi, 19
    je .si_gpu_class
    cmp rdi, 20
    je .si_gpu_bar0_lo
    cmp rdi, 21
    je .si_gpu_bar0_hi
    cmp rdi, 22
    je .si_gpu_cmd
    cmp rdi, 23
    je .si_gpu_active
    jmp .si_store
.si_fps:
    mov eax, [last_fps]
    jmp .si_store
.si_ram_free:
    mov rax, [free_page_count]
    shl rax, 2              ; 4 KB pages -> KB
    jmp .si_store
.si_ram_max:
    ; total_usable_pages includes fixed kernel/GUI/app arenas reserved before
    ; the allocator starts, so apps can report actual used RAM instead of 0
    ; until the first dynamic page allocation.
    mov rax, [total_usable_pages]
    test rax, rax
    jnz .si_ram_max_have
    mov rax, [boot_free_pages]
.si_ram_max_have:
    shl rax, 2
    jmp .si_store
.si_cpu_mhz:
    mov rax, [cpu_tsc_per_tick]
    xor rdx, rdx
    mov rcx, 10000          ; tsc/tick -> MHz (Hz = val*100)
    test rcx, rcx
    div rcx
    jmp .si_store
.si_cores:
    mov eax, [madt_enabled_cpu_count]
    test eax, eax
    jnz .si_store
    mov eax, [cpuid_logical_count]
    jmp .si_store
.si_core_util:
    cmp rsi, SMP_MAX_CORES
    jae .si_store
    mov rax, rsi
    imul rax, SMP_CORE_STATE_SIZE
    mov eax, [smp_core_states + rax + 24]
    jmp .si_store
.si_core_mhz:
    cmp rsi, SMP_MAX_CORES
    jae .si_cpu_mhz
    mov rax, rsi
    imul rax, SMP_CORE_STATE_SIZE
    mov eax, [smp_core_states + rax + 28]
    test eax, eax
    jnz .si_store
    jmp .si_cpu_mhz
.si_gpu_provider:
    mov eax, [amd_display_status]
    jmp .si_store
.si_gpu_bdf:
    mov eax, [amd_display_bdf]
    jmp .si_store
.si_gpu_id:
    mov eax, [amd_display_id]
    jmp .si_store
.si_gpu_class:
    mov eax, [amd_display_class]
    jmp .si_store
.si_gpu_bar0_lo:
    mov eax, [amd_display_bar0]
    jmp .si_store
.si_gpu_bar0_hi:
    mov rax, [amd_display_bar0]
    shr rax, 32
    jmp .si_store
.si_gpu_cmd:
    mov eax, [amd_display_cmd]
    jmp .si_store
.si_gpu_active:
    movzx eax, byte [amd_display_active]
    jmp .si_store
.si_store:
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_desktop_bg:
    movzx eax, byte [desktop_bg_theme]
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_desktop_set_bg:
    cmp byte [wallpaper_render_active], 0
    jne .sc_desktop_set_bg_busy
    cmp byte [wallpaper_selected], 0
    je .sc_desktop_set_bg_accept
    cmp byte [wallpaper_cache_valid], 1
    jne .sc_desktop_set_bg_busy
    cmp byte [wallpaper_cache_presented], 1
    jne .sc_desktop_set_bg_busy
.sc_desktop_set_bg_accept:
    mov rax, rdi
    shr rax, 32
    jnz .sc_desktop_set_bg_reject
    cmp edi, 2
    ja .sc_desktop_set_bg_reject
    mov [desktop_bg_theme], dil
    ; The user has now picked a wallpaper in Settings: enable wallpaper drawing
    ; and drop the cache so wm_draw_desktop_background rasterizes this theme on
    ; the next frame. This is the only path that triggers the SVG renderer.
    mov byte [wallpaper_selected], 1
    mov byte [wallpaper_cache_valid], 0
    mov byte [wallpaper_cache_presented], 0
    mov byte [scene_dirty], 1
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_desktop_set_bg_busy:
    mov qword [rsp + ALL_RAX], -2
    jmp .done
.sc_desktop_set_bg_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_desktop_bg_busy:
    xor eax, eax
    cmp byte [wallpaper_render_active], 0
    jne .sc_desktop_bg_busy_yes
    cmp byte [wallpaper_selected], 0
    je .sc_desktop_bg_busy_store
    cmp byte [wallpaper_cache_valid], 1
    jne .sc_desktop_bg_busy_yes
    cmp byte [wallpaper_cache_presented], 1
    je .sc_desktop_bg_busy_store
.sc_desktop_bg_busy_yes:
    mov eax, 1
.sc_desktop_bg_busy_store:
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_fs_delete:
    ; rdi = handle. Resolver leaves rdi as the kernel root-cache entry
    ; pointer so fat16_delete_entry mutates the real cache (the snapshot
    ; cache that used to back this call no longer exists).
    call sc_resolve_dir_entry_arg
    test eax, eax
    jz .sc_fs_delete_reject
    call fat16_delete_entry
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_delete_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_fs_rename:
    ; rdi = handle, rsi = 11-byte raw FAT16 short name in user memory.
    call sc_resolve_dir_entry_arg
    test eax, eax
    jz .sc_fs_rename_reject
    push rdi                              ; kernel entry pointer
    mov rdi, rsi
    mov rsi, 11
    call sc_validate_user_range
    pop rdi
    test eax, eax
    jz .sc_fs_rename_reject
    mov rsi, [rsp + ALL_RSI]
    call fat16_rename_entry
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_rename_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_fs_mkdir:
    mov rsi, 11
    call sc_validate_user_range
    test eax, eax
    jz .sc_fs_mkdir_reject
    mov rdi, [rsp + ALL_RDI]
    call fat16_mkdir
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_mkdir_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_open_file_np:
    call sc_resolve_dir_entry_arg
    test eax, eax
    jz .sc_open_file_np_reject
    ; Notepad is only for text-like files. If a stale UI path asks Notepad to
    ; open known media, route to Media Player at the syscall boundary.
    cmp byte [rdi + 8], 'B'
    jne .sc_open_file_np_not_bmp
    cmp byte [rdi + 9], 'M'
    jne .sc_open_file_np_not_bmp
    cmp byte [rdi + 10], 'P'
    je .sc_open_file_np_media
.sc_open_file_np_not_bmp:
    cmp byte [rdi + 8], 'N'
    jne .sc_open_file_np_check_svg
    cmp byte [rdi + 9], 'I'
    jne .sc_open_file_np_check_nba
    cmp byte [rdi + 10], 'C'
    je .sc_open_file_np_media
    jmp .sc_open_file_np_text
.sc_open_file_np_check_nba:
    cmp byte [rdi + 9], 'B'
    jne .sc_open_file_np_text
    cmp byte [rdi + 10], 'A'
    je .sc_open_file_np_media
    jmp .sc_open_file_np_text
.sc_open_file_np_check_svg:
    cmp byte [rdi + 8], 'S'
    jne .sc_open_file_np_check_xml
    cmp byte [rdi + 9], 'V'
    jne .sc_open_file_np_text
    cmp byte [rdi + 10], 'G'
    je .sc_open_file_np_media
    jmp .sc_open_file_np_text
.sc_open_file_np_check_xml:
    cmp byte [rdi + 8], 'X'
    jne .sc_open_file_np_text
    cmp byte [rdi + 9], 'M'
    jne .sc_open_file_np_text
    cmp byte [rdi + 10], 'L'
    je .sc_open_file_np_media
.sc_open_file_np_text:
    call kernel_open_file_in_notepad
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_open_file_np_media:
    call kernel_open_file_in_media
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_open_file_np_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_open_file_media:
    call sc_resolve_dir_entry_arg
    test eax, eax
    jz .sc_open_file_media_reject
    call kernel_open_file_in_media
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_open_file_media_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; SYS_HANDLE_CLOSE — release an opaque handle. rdi = handle.
;
; Generic close; today only HANDLE_KIND_DIR_ENTRY exists. handle_close
; verifies the handle (magic + kind + index + generation) before zeroing
; the entry's kind byte. A stale handle from before this close still
; fails to resolve because the allocator bumps the generation on the next
; reuse of the same index.
.sc_handle_close:
    mov edx, edi                          ; edx = untrusted handle
    mov rax, r15
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    mov rdi, rax                          ; rdi = slot base
    mov al, HANDLE_KIND_DIR_ENTRY
    call handle_close                     ; eax = 1 ok, 0 mismatch
    test eax, eax
    jz .sc_handle_close_reject
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_handle_close_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; SYS_FS_ENTRY_INFO — read a fixed-layout snapshot of a FAT16 entry into
; a user buffer. rdi = handle, rsi = user out buf, rdx = buf size.
;
; This is the replacement for the legacy "SYS_FS_ENTRY returned a
; dereferenceable snapshot pointer" contract. The kernel decides what
; fields are exposed (name/ext/attr, first cluster, size — no internal
; FAT16 metadata) and copies them out by value, so ring 3 never observes
; a kernel address.
.sc_fs_entry_info:
    push rdi
    push rdx
    SER 'F'
    SER 'I'
    call ser_print_hex64
    SER 13
    SER 10
    pop rdx
    pop rdi
    cmp rdx, FS_ENTRY_INFO_SIZE
    jb .sc_fs_entry_info_reject
    push rdi                              ; save handle
    push rsi                              ; save user buf
    mov rdi, rsi
    mov rsi, FS_ENTRY_INFO_SIZE
    call sc_validate_user_io_range
    pop rsi
    pop rdi
    test eax, eax
    jz .sc_fs_entry_info_reject
    push rsi                              ; user buf survives the resolver
    call sc_resolve_dir_entry_arg         ; rdi -> kernel entry pointer
    pop rsi
    test eax, eax
    jz .sc_fs_entry_info_reject
    ; Layout:
    ;   [0..7]   name              (bytes 0..7 of FAT entry)
    ;   [8..10]  ext               (bytes 8..10)
    ;   [11]     attr              (byte 11)
    ;   [12..13] first_cluster_lo  (u16 at offset 26)
    ;   [14..15] reserved          (0)
    ;   [16..19] size              (u32 at offset 28)
    ; rdi = kernel FAT16 entry (supervisor); rsi = user out buffer (PTE.U=1).
    ; Bracket the whole copy so the [rsi+...] stores don't SMAP-#PF; stac does
    ; not affect the supervisor [rdi+...] loads.
    USER_ACCESS_BEGIN
    mov rax, [rdi + 0]
    mov [rsi + 0], rax
    mov eax, [rdi + 8]
    mov [rsi + 8], eax
    movzx eax, word [rdi + 26]
    mov [rsi + 12], ax
    mov word [rsi + 14], 0
    mov eax, [rdi + 28]
    mov [rsi + 16], eax
    USER_ACCESS_END
    xor eax, eax
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_fs_entry_info_reject:
    SER 'F'
    SER 'X'
    SER 13
    SER 10
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; SYS_APP_DECLARE_MANIFEST(app_id):
;   AND-narrows slot_cap_mask[r15] by app_manifest_table[app_id - APP_MIN_ID].
;   Returns the resulting effective mask (or -1 on bad app_id). AND-only
;   ensures the manifest call can never *grant* a capability — it can only
;   take them away — so an attacker who hijacks an already-narrowed slot
;   can't re-declare into a more powerful manifest.
.sc_app_declare_manifest:
    cmp edi, APP_MIN_ID
    jb .sc_app_declare_manifest_reject
    cmp edi, APP_MAX_ID
    ja .sc_app_declare_manifest_reject
    push rdi                          ; stash original app_id for the audit record
    sub edi, APP_MIN_ID
    lea rcx, [rel app_manifest_table]
    movzx eax, byte [rcx + rdi]       ; manifest cap bits for this app
    lea rcx, [rel slot_cap_mask]
    movzx edx, r15b
    movzx ebx, byte [rcx + rdx]       ; old mask (for the audit record)
    and al, bl                        ; AND-narrow against the current mask
    ; Audit this capability transition before persisting it (security_todo.md
    ; §4). cap_audit_log(dil=slot, sil=old, dl=new, cl=reason, r8d=app_id);
    ; it preserves all caller regs.
    movzx edi, r15b
    mov esi, ebx                      ; old_mask
    movzx edx, al                     ; new_mask
    mov ecx, CAP_AUDIT_DECLARE
    mov r8, [rsp]                     ; original app_id (stashed above)
    push rax
    call cap_audit_log
    pop rax
    add rsp, 8                         ; discard stashed app_id
    ; Persist the narrowed mask together with a fresh authenticator so the
    ; dispatcher's HMAC check accepts it. cap_mask_store(rdi=slot, rsi=mask).
    movzx edi, r15b
    movzx esi, al
    call cap_mask_store
    movzx eax, sil                    ; resulting effective mask
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_app_declare_manifest_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_app_open:
    mov rsi, APP_OPEN_CMD_MAX
    call sc_validate_user_cstring
    test eax, eax
    jz .sc_app_open_reject
    mov rdi, [rsp + ALL_RDI]                ; reload ptr (cstring scan clobbered it)
    mov rsi, APP_OPEN_CMD_MAX
    call sc_validate_path_canonical         ; reject .., abs/drive escapes, ctrl bytes
    test eax, eax
    jz .sc_app_open_reject
    mov rdi, [rsp + ALL_RDI]
    call kernel_open_app_command
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_app_open_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

