; ============================================================================
; syscall_support.inc
; syscall support: wmcreate debug log, arg validator (sc_validate_from_table et al), SYSCALL_ENTRY macro + syscall_table, kernel_canary_init
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
dbg_wmcreate_log:
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
    push r15
    mov r10, r15                              ; save slot before clobber
    mov r11, r9                               ; save drawfn before clobber
    lea rdi, [rel dbg_wc_s1]
    call serial_puts
    mov rsi, r10
    call dbg_wc_hex64
    lea rdi, [rel dbg_wc_s2]
    call serial_puts
    mov rsi, r11
    call dbg_wc_hex64
    call serial_crlf
    pop r15
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

; rsi=value -> 16 hex digits via serial_putc. Clobbers rax,rcx,rdx (saved here).
dbg_wc_hex64:
    push rax
    push rcx
    push rdx
    push rbx
    mov rcx, 16
.dwc_loop:
    rol rsi, 4
    mov rax, rsi
    and rax, 0x0F
    cmp rax, 10
    jb .dwc_dec
    add rax, 'a' - 10
    jmp .dwc_emit
.dwc_dec:
    add rax, '0'
.dwc_emit:
    mov dil, al
    push rsi
    push rcx
    mov al, dil
    movzx edi, al
    call serial_putc
    pop rcx
    pop rsi
    dec rcx
    jnz .dwc_loop
    pop rbx
    pop rdx
    pop rcx
    pop rax
    ret

section .data
dbg_wc_s1: db "[WCREATE] slot=", 0
dbg_wc_s2: db " dfn=", 0
section .text

; R12=syscall table entry, PUSH_ALL frame on RSP. EAX=1 ok, 0 reject.
sc_validate_from_table:
    KPROLOGUE                           ; shadow-stack guard (syscall-stack only)
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r13                                  ; arg-desc qword, live across loop
    movzx ecx, byte [r12 + SYSCALL_ARGC_OFF]
    mov ebx, [r12 + SYSCALL_KIND_OFF]
    mov r13, [r12 + SYSCALL_ARG_DESC_OFF]
    xor r8d, r8d
.validate_loop:
    cmp r8d, ecx
    jae .validate_ok
    mov edx, ebx
    and edx, 3
    cmp edx, FN_KIND_SCALAR
    je .next_arg
    cmp edx, FN_KIND_PTR
    je .check_ptr
    cmp edx, FN_KIND_CSTRING
    je .check_cstring
    cmp edx, FN_KIND_HANDLE
    je .check_handle
    jmp .validate_fail
.check_ptr:
    call sc_load_arg_for_validation
    push rdi
    SER 'V'
    SER 'P'
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    ; Default length probe is 1 byte. If the descriptor names a sibling
    ; SCALAR arg as the length source, load that scalar and use it as the
    ; full byte length instead — this is the single place where PTR args
    ; get range-validated, so a handler that forgets the explicit check is
    ; still safe.
    mov rsi, 1
    ; Compute the descriptor nibble for this arg without clobbering rcx
    ; (the outer argc loop counter). r9 is scratch.
    push rcx
    mov rdx, r13
    mov r9d, r8d
    shl r9d, 2                  ; bit shift = arg_index * 4
    mov ecx, r9d
    shr rdx, cl
    pop rcx
    and edx, 0x0F
    jnz .check_ptr_has_desc
    ; Nibble 0 = this PTR arg was never migrated to a sibling-length
    ; descriptor. STRICT rows (security_todo.md §2, "Mandatory non-zero
    ; arg_desc for every PTR arg") deny-on-unmigrated instead of falling back
    ; to the 1-byte probe — eliminates the "handler forgot the range check"
    ; class for opted-in rows. Non-STRICT rows keep the legacy 1-byte probe.
    test byte [r12 + SYSCALL_FLAGS_OFF], SC_FLAG_STRICT
    jnz .validate_fail
    jmp .check_ptr_do
.check_ptr_has_desc:
    ; edx = 1-based sibling index; reload that scalar via the same helper.
    push rdi
    push r8                     ; save current arg index (loop state)
    mov r8d, edx
    dec r8d                     ; 0-based sibling index
    call sc_load_arg_for_validation
    mov rsi, rdi                ; rsi = sibling's value = byte length
    pop r8
    pop rdi
.check_ptr_do:
    call sc_validate_user_range
    test eax, eax
    jnz .check_ptr_ok
    SER 'V'
    SER 'Q'
    SER 13
    SER 10
    jmp .validate_fail
.check_ptr_ok:
    jmp .next_arg
.check_cstring:
    call sc_load_arg_for_validation
    mov rsi, SYSCALL_MAX_STR_LEN
    call sc_validate_user_cstring
    test eax, eax
    jz .validate_fail
    jmp .next_arg
.check_handle:
    call sc_load_arg_for_validation       ; rdi = untrusted handle
    push rdi
    SER 'V'
    SER 'H'
    call ser_print_hex64
    SER 13
    SER 10
    pop rdi
    mov edx, edi
    mov rax, r15
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    mov rdi, rax
    mov al, HANDLE_KIND_DIR_ENTRY
    call handle_resolve
    test eax, eax
    jnz .check_handle_ok
    SER 'V'
    SER 'X'
    SER 13
    SER 10
    jmp .validate_fail
.check_handle_ok:
.next_arg:
    shr ebx, 2
    inc r8d
    jmp .validate_loop
.validate_ok:
    mov eax, 1
    jmp .validate_done
.validate_fail:
    xor eax, eax
.validate_done:
    pop r13
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    KEPILOGUE

; R8D=arg index, returns selected argument in RDI.
; Frame: ret(8) + sc_validate_from_table pushes [rbx,rcx,rdx,rdi,rsi,r8,r13]
; (56) + outer call's ret(8) = 72 bytes between rsp and the PUSH_ALL frame.
SC_VALIDATE_FRAME_OFF equ 72
sc_load_arg_for_validation:
    KPROLOGUE                           ; shadow-stack guard (syscall-stack only)
    ; Constant-time arg select (Spectre-v1): no data-dependent branch on the
    ; index. Clamp index>5 to 5 (ALL_R9, the old default) with cmova, then read
    ; the frame offset from a fixed table and load the saved register.
    mov eax, 5
    cmp r8d, 5
    cmova r8d, eax                      ; clamp any index > 5 to 5 (branchless)
    lea rax, [rel sc_arg_off_table]
    mov eax, [rax + r8*4]               ; eax = ALL_* frame offset for this index
    add eax, SC_VALIDATE_FRAME_OFF      ; eax = full displacement from rsp
    mov rdi, [rsp + rax]                ; load the selected saved register
    KEPILOGUE

align 4
sc_arg_off_table:
    dd ALL_RDI, ALL_RSI, ALL_RDX, ALL_R10, ALL_R8, ALL_R9

; sc_resolve_dir_entry_arg — translate an untrusted user-supplied dir-entry
; handle into the matching real FAT16 root-cache entry pointer.
;
;   In:  RDI = user handle (as forwarded into the syscall handler)
;        R15 = current slot id (set by syscall_entry before dispatch)
;   Out: EAX = 1 and RDI = kernel entry pointer, on success
;        EAX = 0,                                on any failure
;
; The handle is verified through the per-slot handle table (magic, kind tag,
; index range, stored kind, generation). The payload — the valid-entry index
; — is then fed back through fat16_get_entry so the returned pointer reflects
; current FAT16 cache state (a directory change after SYS_FS_ENTRY does NOT
; produce a dangling kernel VA; the handle simply resolves to whatever is at
; that index now). Volume-label / LFN / deleted entries are skipped by
; fat16_get_entry, so the index is "valid-entry index", not a raw byte
; offset.
;
; Preserves: nothing beyond RDI (which is overwritten with the kernel
; pointer). Saves and restores RCX, RDX, RSI, R8, R9, R10 so handlers can
; chain straight into the FS worker without re-loading them.
sc_resolve_dir_entry_arg:
    KPROLOGUE                           ; shadow-stack guard (syscall-stack only)
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov edx, edi                        ; edx = handle to verify
    mov rax, r15
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    mov rdi, rax                        ; rdi = slot base
    mov al, HANDLE_KIND_DIR_ENTRY
    call handle_resolve                 ; eax = 1/0; on success R8 = payload
    test eax, eax
    jz .rdea_fail
    mov edi, r8d                        ; edi = valid-entry index
    call fat16_get_entry                ; rax = kernel entry pointer or 0
    test rax, rax
    jz .rdea_fail
    mov rdi, rax
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    mov eax, 1
    KEPILOGUE
.rdea_fail:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    xor eax, eax
    KEPILOGUE

%define SC_KIND1(a) (a)
%define SC_KIND2(a,b) ((a) | ((b) << 2))
%define SC_KIND3(a,b,c) ((a) | ((b) << 2) | ((c) << 4))
%define SC_KIND4(a,b,c,d) ((a) | ((b) << 2) | ((c) << 4) | ((d) << 6))
%define SC_KIND5(a,b,c,d,e) ((a) | ((b) << 2) | ((c) << 4) | ((d) << 6) | ((e) << 8))
%define SC_KIND6(a,b,c,d,e,f) ((a) | ((b) << 2) | ((c) << 4) | ((d) << 6) | ((e) << 8) | ((f) << 10))

; SYSCALL_ENTRY handler, argc, kind [, caps [, arg_desc]]
;
; The optional 4th argument is the capability mask required to invoke this
; syscall — see syscall_caps.inc. Defaulting to CAP_ALL preserves legacy
; behaviour for any row that hasn't been annotated yet (sandboxing only
; bites once an app calls SYS_APP_DECLARE_MANIFEST and its mask narrows).
;
; The optional 5th argument is the per-arg sanitization descriptor — see
; SYSCALL_ARG_DESC_OFF above and the SC_DESC_LEN macros below. Default 0
; keeps the legacy 1-byte probe for PTR args; non-zero opts a row into
; sibling-driven range validation done in one place at the dispatcher.
;
; The optional 6th argument is the per-entry flags byte (offset 14) — see
; SYSCALL_FLAGS_OFF above. SC_FLAG_STRICT makes the validator deny any PTR
; arg whose arg_desc nibble is still 0/unmigrated rather than 1-byte-probing.
%macro SYSCALL_ENTRY 3-6 CAP_ALL, 0, 0
    dq %1
    db %2
    dd %3
    db %4
    db %6         ; flags at offset 14 (SYSCALL_FLAGS_OFF)
    db 0          ; pad byte 15
    dq %5         ; arg_desc at offset 16
%endmacro

; Per-arg descriptor helpers. Nibble N (4 bits) encodes the 1-based index of
; the SCALAR sibling that holds the byte length of PTR arg N. 0 means "no
; sibling; fall back to the 1-byte probe". Chain with bitwise OR:
;   SC_DESC_LEN(1, 3) | SC_DESC_LEN(3, 4)
; says "PTR arg 1 takes its length from arg 3; PTR arg 3 from arg 4".
%define SC_DESC_LEN(arg_idx, len_sibling_1based) ((len_sibling_1based) << ((arg_idx)*4))

section .text
align 8
syscall_table:
    SYSCALL_ENTRY syscall_entry.sc_print,            1, SC_KIND1(FN_KIND_CSTRING), CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_exit,             0, 0,                          CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_gui_rect,         5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_gui_text,         5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_CSTRING, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_fs_count,         0, 0,                          CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_fs_entry,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_fs_chdir,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_wm_create,        6, SC_KIND6(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_CSTRING, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_fs_read,          3, SC_KIND3(FN_KIND_HANDLE, FN_KIND_PTR, FN_KIND_SCALAR), CAP_FS, SC_DESC_LEN(1, 3), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_wm_handlers,      3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_app_done,         0, 0,                          CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_fs_format_name,   2, SC_KIND2(FN_KIND_HANDLE, FN_KIND_PTR), CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_app_launch,       1, SC_KIND1(FN_KIND_SCALAR),   CAP_APP_CTRL
    SYSCALL_ENTRY syscall_entry.sc_fs_write,         3, SC_KIND3(FN_KIND_PTR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_fs_sync_root,     0, 0,                          CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_wm_close,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_display_set_mode, 3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_cursor_init,      0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_ticks,            0, 0,                          CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_fs_delete,        1, SC_KIND1(FN_KIND_HANDLE),   CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_fs_rename,        2, SC_KIND2(FN_KIND_HANDLE, FN_KIND_PTR), CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_fs_mkdir,         1, SC_KIND1(FN_KIND_PTR),      CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_open_file_np,     1, SC_KIND1(FN_KIND_HANDLE),   CAP_APP_CTRL
    SYSCALL_ENTRY syscall_entry.sc_app_open,         1, SC_KIND1(FN_KIND_CSTRING),  CAP_APP_CTRL
    SYSCALL_ENTRY syscall_entry.sc_display_flags,    0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_display_set_flags, 1, SC_KIND1(FN_KIND_SCALAR),  CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_desktop_bg,       0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_desktop_set_bg,   1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_display_native,   0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_display_size,     0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_parse,        2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, SC_DESC_LEN(0, 2), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_root,         0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_tag,          1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_tag_name,     3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, SC_DESC_LEN(1, 3), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_first_child,  1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_next_sibling, 1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_parent,       1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_attr,         5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, (SC_DESC_LEN(1, 3) | SC_DESC_LEN(3, 5)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_text,         3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, SC_DESC_LEN(1, 3), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_free,         0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_draw_line,        5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_fill_circle,      4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_fill_triangle,    2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_last_error,   0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_node_count,   0, 0,                          CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_blend_pixel,      3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_blend_span,       4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_text_runs,    1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_xml_text_run,     4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, SC_DESC_LEN(2, 4), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_namespace,    5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, SC_DESC_LEN(3, 5), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_node_namespace, 3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, SC_DESC_LEN(1, 3), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_entity_value, 4, SC_KIND4(FN_KIND_PTR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI, (SC_DESC_LEN(0, 2) | SC_DESC_LEN(2, 4)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_blend_span_argb,  4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_blend_span_argb_screen, 4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_blend_span_argb_multiply, 4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR), CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_sysinfo,          2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_net_ping4,        1, SC_KIND1(FN_KIND_SCALAR),   CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_info,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_dhcp_renew,   0, 0,                          CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_dhcp_start,   0, 0,                          CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_tcp_connect4,  3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_dns_a,        1, SC_KIND1(FN_KIND_PTR),      CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_ping4_tick,   1, SC_KIND1(FN_KIND_SCALAR),   CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_desktop_bg_busy,   0, 0,                         CAP_GUI
    SYSCALL_ENTRY syscall_entry.sc_open_file_media,   1, SC_KIND1(FN_KIND_HANDLE),  CAP_APP_CTRL
    SYSCALL_ENTRY syscall_entry.sc_wm_set_user_arg,   2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI
    ; sc_media_blit_scaled — secure aspect-preserving BGRA blit; src is
    ; PTR-validated to live inside the calling slot before the scaler runs.
    SYSCALL_ENTRY syscall_entry.sc_media_blit_scaled, 5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_MEDIA
    SYSCALL_ENTRY syscall_entry.sc_wx_install_manifest, 2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_WX
    SYSCALL_ENTRY syscall_entry.sc_mprotect_wx,      2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_WX
    SYSCALL_ENTRY syscall_entry.sc_wx_jit_alias,     3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_WX
    ; SYS_HANDLE_CLOSE — handle is a scalar from the validator's POV
    ; (handle_close does the magic/kind/gen verification internally).
    SYSCALL_ENTRY syscall_entry.sc_handle_close,     1, SC_KIND1(FN_KIND_SCALAR),   CAP_CORE
    ; SYS_FS_ENTRY_INFO — (handle, out_buf, out_buf_len). The handle is
    ; FN_KIND_HANDLE so a bad handle is rejected before sc_fs_entry_info
    ; runs; out_buf is FN_KIND_PTR with a 1-byte probe (the handler does
    ; the full 20-byte range check against the user mapping).
    SYSCALL_ENTRY syscall_entry.sc_fs_entry_info,    3, SC_KIND3(FN_KIND_HANDLE, FN_KIND_PTR, FN_KIND_SCALAR), CAP_FS
    ; SYS_APP_DECLARE_MANIFEST(app_id) — narrow the calling slot's cap mask
    ; to the manifest declared for app_id in syscall_caps.inc. One-way: a
    ; sandboxed app can never widen its mask. Tagged CAP_CORE so even a
    ; deeply-sandboxed app can still call it (a no-op the second time).
    SYSCALL_ENTRY syscall_entry.sc_app_declare_manifest, 1, SC_KIND1(FN_KIND_SCALAR), CAP_CORE
    ; SYS_WM_GET_USER_ARG — tag-verified read of WIN_OFF_USER_ARG. Reader
    ; companion to SYS_WM_SET_USER_ARG; required so user-mode draw fns no
    ; longer dereference window-pool memory directly to fetch their arg.
    SYSCALL_ENTRY syscall_entry.sc_wm_get_user_arg,  1, SC_KIND1(FN_KIND_SCALAR), CAP_GUI
syscall_table_end:
syscall_table_count equ (syscall_table_end - syscall_table) / SYSCALL_ENTRY_SIZE

FN_BEGIN test_syscall_proc, 0, 0, FN_RET_VOID
.loop:
    hlt
    jmp .loop

; ----------------------------------------------------------------------------
; kernel_canary_init - seed the global stack canary from RDTSC ^ RDRAND (when
; available). Called once from kernel_main before syscall_init so every
; SYSCALL pushes a unique value. RDRAND failure (older CPUs, QEMU TCG) falls
; back to RDTSC alone; a final non-zero guard prevents an all-zero canary.
; ----------------------------------------------------------------------------
FN_BEGIN kernel_canary_init, 0, 0, FN_RET_VOID
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
    test ecx, 1 << 30                 ; CPUID.01H:ECX.RDRAND[bit 30]
    jz .kc_no_rdrand
    mov ecx, 8
.kc_try_rdrand:
    rdrand rax
    jc .kc_have_rdrand
    dec ecx
    jnz .kc_try_rdrand
    jmp .kc_no_rdrand
.kc_have_rdrand:
    xor rbx, rax
.kc_no_rdrand:
    ; Fold the quantum entropy blob (IBM ibm_marrakesh, job d8cved7d0j8c73f3fjq0)
    ; into the canary: XOR-compress all qrng_seed_len bytes so the canary depends
    ; on every byte of certified-irreproducible randomness. Critically this makes
    ; the RDRAND-absent fallback (QEMU TCG / old CPUs) unguessable instead of
    ; RDTSC-only. Provenance: tools/quantum/qrng_manifest.txt.
    push rsi
    push rcx
    lea rsi, [rel qrng_seed_blob]
    mov ecx, qrng_seed_len / 8
.kc_qrng_fold:
    xor rbx, [rsi]
    add rsi, 8
    rol rbx, 17                       ; cheap avalanche: every byte touches every bit
    dec ecx
    jnz .kc_qrng_fold
    pop rcx
    pop rsi
    test rbx, rbx
    jnz .kc_store
    mov rbx, 0xDEADC0DEDEADC0DE
.kc_store:
    mov [rel kernel_canary], rbx
    pop rdx
    pop rcx
    pop rbx
    pop rax
    FN_END kernel_canary_init
    ret

