; ============================================================================
; syscall_support.inc
; syscall support: wmcreate debug log, arg validator (sc_validate_from_table et al), SYSCALL_ENTRY macro + syscall_table, kernel_canary_init
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
; dbg_wmcreate_log / dbg_wc_hex64 - MIGRATED to GritHLK (Stage 2a). Now emitted
; from src/kernel/grithlk/syscall_validate.ghl as structured zero-asm fns with
; the same global names and ABI (dbg_wmcreate_log: R15=slot, R9=drawfn;
; dbg_wc_hex64: RSI=value -> 16 hex digits; both preserve all registers). The
; dbg_wc_s1/dbg_wc_s2 strings below stay here and are referenced extern by the
; generated module.

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
    ; Default length probe is 1 byte (legacy, non-STRICT rows only). The
    ; descriptor decides the real length: this is the single place where PTR
    ; args get range-validated, so a handler that forgets its own check is safe.
    mov rsi, 1
    ; Extract this arg's 8-bit descriptor field from r13 (arg_desc) without
    ; clobbering rcx (the outer argc loop counter). r9 is scratch.
    push rcx
    mov rdx, r13
    mov r9d, r8d
    shl r9d, 3                  ; bit shift = arg_index * 8 (8 bits per arg)
    mov ecx, r9d
    shr rdx, cl
    pop rcx
    and edx, 0xFF               ; edx = this arg's descriptor byte
    mov r9d, edx
    and r9d, 0x0F               ; r9d = LEN_SRC nibble
    shr edx, 4
    and edx, 0x0F               ; edx = SIZE index nibble
    cmp r9d, SC_DESC_HANDLER_CODE
    je .check_ptr_handler       ; 0xE: handler owns the range check
    cmp r9d, SC_DESC_CONST_CODE
    je .check_ptr_const         ; 0xF: constant length = size_table[SIZE]
    test r9d, r9d
    jnz .check_ptr_sibling      ; 1..6: sibling count * size_table[SIZE]
    ; LEN_SRC 0 = unmigrated PTR arg. STRICT rows deny (eliminates the "handler
    ; forgot the range check" class); non-STRICT rows keep the 1-byte probe.
    test byte [r12 + SYSCALL_FLAGS_OFF], SC_FLAG_STRICT
    jnz .validate_fail
    jmp .check_ptr_do
.check_ptr_handler:
    ; The handler range-validates this pointer itself (length not expressible as
    ; sibling*size). Trust it: skip the dispatcher probe and pass the arg.
    jmp .check_ptr_ok
.check_ptr_const:
    lea rax, [rel sc_arg_size_table]
    mov esi, [rax + rdx*4]      ; rsi = constant byte length
    test esi, esi
    jz .validate_fail           ; reserved/unknown size index -> deny
    jmp .check_ptr_do
.check_ptr_sibling:
    ; Load the sibling scalar (r9d = 1-based index) as the element COUNT, then
    ; multiply by size_table[SIZE] with a 64-bit overflow check.
    push rdx                    ; save SIZE index across the frame load
    push rdi                    ; save ptr value
    push r8                     ; save current arg index (loop state)
    mov r8d, r9d
    dec r8d                     ; 0-based sibling index
    ; Direct frame load (no helper CALL, so no return address): relative to the
    ; helper's SC_VALIDATE_FRAME_OFF the adjustment is +16 for the THREE saved
    ; qwords (rdx, rdi, r8) now below the read.
    mov eax, 5
    cmp r8d, 5
    cmova r8d, eax              ; clamp any index > 5 to 5 (branchless)
    lea rax, [rel sc_arg_off_table]
    mov eax, [rax + r8*4]
    add eax, SC_VALIDATE_FRAME_OFF + 16
    mov rsi, [rsp + rax]        ; rsi = sibling value = element count
    pop r8
    pop rdi
    pop rdx                     ; rdx = SIZE index
    lea rax, [rel sc_arg_size_table]
    mov eax, [rax + rdx*4]      ; eax = element size (bytes)
    test eax, eax
    jz .validate_fail           ; reserved/unknown size index -> deny
    mul rsi                     ; rdx:rax = elem_size * count
    jc .validate_fail           ; product overflowed 64 bits -> deny
    mov rsi, rax                ; rsi = total byte length
.check_ptr_do:
    ; Descriptor bits 48..53 encode pointer direction. READ is the default and
    ; may accept the immutable shared app blob; WRITE accepts only the caller's
    ; private slot. Handler validators remain in place as defense in depth.
    mov eax, r8d
    add eax, SC_DESC_WRITE_SHIFT
    bt r13, rax
    jc .check_ptr_do_write
    call sc_validate_user_range
    jmp .check_ptr_done
.check_ptr_do_write:
    call sc_validate_user_write
.check_ptr_done:
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

; Element/constant size table for the per-arg descriptor SIZE nibble (SCSZ_*).
; Index -> byte size. A 0 entry (reserved rows 11..15) is treated as an invalid
; descriptor and denies the syscall. Keep row order in lockstep with the SCSZ_*
; equ block above.
align 4
sc_arg_size_table:
    dd 1, 2, 4, 8, 11, 16, 20, 24, 32, 48, 64, 0, 0, 0, 0, 0

; sc_resolve_dir_entry_arg - translate an untrusted user-supplied dir-entry
; handle into the matching real FAT16 root-cache entry pointer.
;
;   In:  RDI = user handle (as forwarded into the syscall handler)
;        R15 = current slot id (set by syscall_entry before dispatch)
;   Out: EAX = 1 and RDI = kernel entry pointer, on success
;        EAX = 0,                                on any failure
;
; The handle is verified through the per-slot handle table (magic, kind tag,
; index range, stored kind, generation). The payload - the valid-entry index
; - is then fed back through fat16_get_entry so the returned pointer reflects
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
; syscall - see syscall_caps.inc. Defaulting to CAP_ALL preserves legacy
; behaviour for any row that hasn't been annotated yet (sandboxing only
; bites once an app calls SYS_APP_DECLARE_MANIFEST and its mask narrows).
;
; The optional 5th argument is the per-arg sanitization descriptor - see
; SYSCALL_ARG_DESC_OFF above and the SC_DESC_LEN macros below. Default 0
; keeps the legacy 1-byte probe for PTR args; non-zero opts a row into
; sibling-driven range validation done in one place at the dispatcher.
;
; The optional 6th argument is the per-entry flags byte (offset 15) - see
; SYSCALL_FLAGS_OFF above. SC_FLAG_STRICT makes the validator deny any PTR
; arg whose arg_desc nibble is still 0/unmigrated rather than 1-byte-probing.
%macro SYSCALL_ENTRY 3-6 CAP_ALL, 0, 0
    dq %1
    db %2
    dd %3
    dw %4         ; 16-bit capability word at offset 13
    db %6         ; flags at offset 15 (SYSCALL_FLAGS_OFF)
    dq %5         ; arg_desc at offset 16
%endmacro

; Per-arg descriptor helpers (finding: every PTR arg must be range-validated at
; the dispatcher, not left to the handler). Each arg gets an 8-BIT field; arg N
; occupies bits [N*8 .. N*8+7] of the arg_desc qword (6 args = 48 bits used):
;   bits[3:0] LEN_SRC : 0        no descriptor (STRICT -> deny; else 1-byte probe)
;                       1..6     1-based index of the SCALAR sibling giving the
;                                element COUNT
;                       0xE      handler-validated (dispatcher skips; STRICT ok)
;                       0xF      constant length (no sibling)
;   bits[7:4] SIZE    : index into sc_arg_size_table - the element size for the
;                       sibling form, or the exact byte count for the constant
;                       form. The dispatcher computes count*size (64-bit,
;                       overflow -> deny) so a `pixels * 4` / `records * 64`
;                       buffer is validated whole, in one place.
;   bits[48:53] WRITE : one bit per arg. Set for kernel-to-user output buffers;
;                       clear for user-to-kernel inputs. A set bit selects
;                       sc_validate_user_write (slot only) at the dispatcher.
; Chain with bitwise OR (e.g. SC_DESC_CONST(0, SCSZ_11) |
; SC_DESC_LEN(1, 3) | SC_DESC_WRITE(1)).
;
; Size-index symbols - MUST match sc_arg_size_table's row order below.
SCSZ_1  equ 0
SCSZ_2  equ 1
SCSZ_4  equ 2
SCSZ_8  equ 3
SCSZ_11 equ 4
SCSZ_16 equ 5
SCSZ_20 equ 6
SCSZ_24 equ 7
SCSZ_32 equ 8
SCSZ_48 equ 9
SCSZ_64 equ 10
SC_DESC_HANDLER_CODE equ 0x0E
SC_DESC_CONST_CODE   equ 0x0F
SC_DESC_WRITE_SHIFT  equ 48
; PTR arg <arg_idx> byte length = sibling scalar <sib> (1-based) * size_table[sz].
%define SC_DESC_LENx(arg_idx, sib, sz) ((((sib) & 0x0F) | (((sz) & 0x0F) << 4)) << ((arg_idx)*8))
; Back-compat: raw byte length straight from the sibling scalar (element size 1).
%define SC_DESC_LEN(arg_idx, sib) SC_DESC_LENx(arg_idx, sib, SCSZ_1)
; PTR arg <arg_idx> byte length = a fixed constant (a size_table entry).
%define SC_DESC_CONST(arg_idx, sz) ((SC_DESC_CONST_CODE | (((sz) & 0x0F) << 4)) << ((arg_idx)*8))
; PTR arg <arg_idx> is fully range-validated INSIDE its handler; the dispatcher
; skips its probe and STRICT is satisfied. Use ONLY where the length is not
; expressible as sibling*size (e.g. two-dimensional packed dims - media blit).
%define SC_DESC_HANDLER(arg_idx) (SC_DESC_HANDLER_CODE << ((arg_idx)*8))
; PTR arg <arg_idx> is an OUTPUT destination. The dispatcher applies the
; slot-only write validator; handler validation is retained as a second check.
%define SC_DESC_WRITE(arg_idx) (1 << (SC_DESC_WRITE_SHIFT + (arg_idx)))

section .text
align 8
syscall_table:
    SYSCALL_ENTRY syscall_entry.sc_print,            1, SC_KIND1(FN_KIND_CSTRING), CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_exit,             0, 0,                          CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_gui_rect,         5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_gui_text,         5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_CSTRING, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_fs_count,         0, 0,                          CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_fs_entry,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_fs_chdir,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_wm_create,        6, SC_KIND6(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_CSTRING, FN_KIND_SCALAR), CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_fs_read,          3, SC_KIND3(FN_KIND_HANDLE, FN_KIND_PTR, FN_KIND_SCALAR), CAP_FS, (SC_DESC_LEN(1, 3) | SC_DESC_WRITE(1)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_wm_handlers,      3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_app_done,         0, 0,                          CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_fs_format_name,   2, SC_KIND2(FN_KIND_HANDLE, FN_KIND_PTR), CAP_FS, (SC_DESC_CONST(1, SCSZ_16) | SC_DESC_WRITE(1)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_app_launch,       1, SC_KIND1(FN_KIND_SCALAR),   CAP_APP_CTRL
    ; arg0 = 11-byte raw FAT16 short name (const); arg1 = data buffer of arg2 bytes.
    SYSCALL_ENTRY syscall_entry.sc_fs_write,         3, SC_KIND3(FN_KIND_PTR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_FS, (SC_DESC_CONST(0, SCSZ_11) | SC_DESC_LEN(1, 3)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_fs_sync_root,     0, 0,                          CAP_FS
    SYSCALL_ENTRY syscall_entry.sc_wm_close,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_display_set_mode, 3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_cursor_init,      0, 0,                          CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_ticks,            0, 0,                          CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_fs_delete,        1, SC_KIND1(FN_KIND_HANDLE),   CAP_FS_DELETE
    SYSCALL_ENTRY syscall_entry.sc_fs_rename,        2, SC_KIND2(FN_KIND_HANDLE, FN_KIND_PTR), CAP_FS_WRITE, SC_DESC_CONST(1, SCSZ_11), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_fs_mkdir,         1, SC_KIND1(FN_KIND_PTR),      CAP_FS_WRITE, SC_DESC_CONST(0, SCSZ_11), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_open_file_np,     1, SC_KIND1(FN_KIND_HANDLE),   CAP_APP_CTRL
    SYSCALL_ENTRY syscall_entry.sc_app_open,         1, SC_KIND1(FN_KIND_CSTRING),  CAP_APP_CTRL
    SYSCALL_ENTRY syscall_entry.sc_display_flags,    0, 0,                          CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_display_set_flags, 1, SC_KIND1(FN_KIND_SCALAR),  CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_desktop_bg,       0, 0,                          CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_desktop_set_bg,   1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_display_native,   0, 0,                          CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_display_size,     0, 0,                          CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_xml_parse,        2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, SC_DESC_LEN(0, 2), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_root,         0, 0,                          CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_tag,          1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_tag_name,     3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, (SC_DESC_LEN(1, 3) | SC_DESC_WRITE(1)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_first_child,  1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_next_sibling, 1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_parent,       1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_attr,         5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, (SC_DESC_LEN(1, 3) | SC_DESC_LEN(3, 5) | SC_DESC_WRITE(3)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_text,         3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, (SC_DESC_LEN(1, 3) | SC_DESC_WRITE(1)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_free,         0, 0,                          CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_draw_line,        5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_fill_circle,      4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    ; arg0 = 24-byte vertex struct (6 int32); handler also re-checks 24 bytes.
    SYSCALL_ENTRY syscall_entry.sc_fill_triangle,    2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, SC_DESC_CONST(0, SCSZ_24), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_last_error,   0, 0,                          CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_node_count,   0, 0,                          CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_blend_pixel,      3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_blend_span,       4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_text_runs,    1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DRAW
    SYSCALL_ENTRY syscall_entry.sc_xml_text_run,     4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, (SC_DESC_LEN(2, 4) | SC_DESC_WRITE(2)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_namespace,    5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, (SC_DESC_LEN(3, 5) | SC_DESC_WRITE(3)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_node_namespace, 3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, (SC_DESC_LEN(1, 3) | SC_DESC_WRITE(1)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_xml_entity_value, 4, SC_KIND4(FN_KIND_PTR, FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, (SC_DESC_LEN(0, 2) | SC_DESC_LEN(2, 4) | SC_DESC_WRITE(2)), SC_FLAG_STRICT
    ; arg3 = ARGB source = arg2 (pixel count) * 4 bytes.
    SYSCALL_ENTRY syscall_entry.sc_blend_span_argb,  4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR), CAP_GUI_DRAW, SC_DESC_LENx(3, 3, SCSZ_4), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_blend_span_argb_screen, 4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR), CAP_GUI_DRAW, SC_DESC_LENx(3, 3, SCSZ_4), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_blend_span_argb_multiply, 4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_PTR), CAP_GUI_DRAW, SC_DESC_LENx(3, 3, SCSZ_4), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_sysinfo,          2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_CORE
    SYSCALL_ENTRY syscall_entry.sc_net_ping4,        1, SC_KIND1(FN_KIND_SCALAR),   CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_info,         1, SC_KIND1(FN_KIND_SCALAR),   CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_dhcp_renew,   0, 0,                          CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_dhcp_start,   0, 0,                          CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_tcp_connect4,  3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_NET
    ; hostname is a bounded C-string; FN_KIND_CSTRING makes the dispatcher scan
    ; it in-slot + NUL-terminated (was FN_KIND_PTR + silent 1-byte probe).
    SYSCALL_ENTRY syscall_entry.sc_net_dns_a,        1, SC_KIND1(FN_KIND_CSTRING),  CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_net_ping4_tick,   1, SC_KIND1(FN_KIND_SCALAR),   CAP_NET
    SYSCALL_ENTRY syscall_entry.sc_desktop_bg_busy,   0, 0,                         CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_open_file_media,   1, SC_KIND1(FN_KIND_HANDLE),  CAP_APP_CTRL
    SYSCALL_ENTRY syscall_entry.sc_wm_set_user_arg,   2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    ; sc_media_blit_scaled - secure aspect-preserving BGRA blit. arg1 (src) length
    ; is src_w*src_h*4 with both dims packed into arg2, so it is NOT expressible as
    ; sibling*size; the handler bounds both dims to [1,4096], computes the 64-bit
    ; byte length, caps it at MEDIA_MAX_BYTES, and calls sc_validate_user_range.
    ; SC_DESC_HANDLER marks that explicit delegation so STRICT is satisfied without
    ; a silent 1-byte probe.
    SYSCALL_ENTRY syscall_entry.sc_media_blit_scaled, 5, SC_KIND5(FN_KIND_SCALAR, FN_KIND_PTR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW | CAP_MEDIA, SC_DESC_HANDLER(1), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_wx_install_manifest, 2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_WX
    SYSCALL_ENTRY syscall_entry.sc_mprotect_wx,      2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_WX
    SYSCALL_ENTRY syscall_entry.sc_wx_jit_alias,     3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_WX
    ; SYS_HANDLE_CLOSE - handle is a scalar from the validator's POV
    ; (handle_close does the magic/kind/gen verification internally).
    SYSCALL_ENTRY syscall_entry.sc_handle_close,     1, SC_KIND1(FN_KIND_SCALAR),   CAP_CORE
    ; SYS_FS_ENTRY_INFO - (handle, out_buf, out_buf_len). The handle is
    ; FN_KIND_HANDLE so a bad handle is rejected before sc_fs_entry_info
    ; runs; out_buf is a fixed FS_ENTRY_INFO_SIZE (20-byte) snapshot, so the
    ; dispatcher validates a constant 20 bytes (handler re-checks against the
    ; user mapping). Was FN_KIND_PTR with only a 1-byte probe.
    SYSCALL_ENTRY syscall_entry.sc_fs_entry_info,    3, SC_KIND3(FN_KIND_HANDLE, FN_KIND_PTR, FN_KIND_SCALAR), CAP_FS_READ, (SC_DESC_CONST(1, SCSZ_20) | SC_DESC_WRITE(1)), SC_FLAG_STRICT
    ; SYS_APP_DECLARE_MANIFEST(app_id) - narrow the calling slot's cap mask
    ; to the manifest declared for app_id in syscall_caps.inc. One-way: a
    ; sandboxed app can never widen its mask. Tagged CAP_CORE so even a
    ; deeply-sandboxed app can still call it (a no-op the second time).
    SYSCALL_ENTRY syscall_entry.sc_app_declare_manifest, 1, SC_KIND1(FN_KIND_SCALAR), CAP_CORE
    ; SYS_WM_GET_USER_ARG - tag-verified read of WIN_OFF_USER_ARG. Reader
    ; companion to SYS_WM_SET_USER_ARG; required so user-mode draw fns no
    ; longer dereference window-pool memory directly to fetch their arg.
    SYSCALL_ENTRY syscall_entry.sc_wm_get_user_arg,  1, SC_KIND1(FN_KIND_SCALAR), CAP_GUI_DRAW
    ; SYS_MOUSE_SENSE() -> packed per-axis pointer sensitivity (tenths):
    ;   x in bits[15:0], y in bits[31:16]. SYS_SET_MOUSE_SENSE(packed) writes it,
    ;   each axis clamped to [1,50] = 0.1x..5.0x. Settings Mouse tab uses these.
    SYSCALL_ENTRY syscall_entry.sc_mouse_sense,      0, 0,                          CAP_GUI_DISPLAY
    SYSCALL_ENTRY syscall_entry.sc_set_mouse_sense,  1, SC_KIND1(FN_KIND_SCALAR),   CAP_GUI_DISPLAY
    ; SYS_PROC_SETPRIO(process_index, priority) - priority manager write path.
    ; CAP_PROC so only Task Manager (its manifest grants CAP_PROC) can retune a
    ; process. Both args are scalars (no pointers), clamped/validated in-handler.
    SYSCALL_ENTRY syscall_entry.sc_proc_setprio,     2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_PROC
    ; gui2 retained-mode library (syscall_handlers_gui2.inc).
    ; SYS_GUI_BATCH(buf_ptr, record_count) -> #primitives drawn. The buffer is
    ; record_count * 64 bytes; arg_desc ties PTR arg 1's length to scalar arg 2
    ; (* GUI_REC_SIZE done in-handler) so the dispatcher range-checks before the
    ; record walk. STRICT denies an unmigrated PTR nibble.
    SYSCALL_ENTRY syscall_entry.sc_gui_batch,        2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, SC_DESC_LENx(0, 2, SCSZ_64), SC_FLAG_STRICT
    ; SYS_GUI_PRESENT(damage_ptr, rect_count) -> rect count. damage is
    ; rect_count * 32 bytes (4 quads each); arg_desc ties PTR arg 1 to scalar 2.
    SYSCALL_ENTRY syscall_entry.sc_gui_present,      2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_GUI_DRAW, SC_DESC_LENx(0, 2, SCSZ_32), SC_FLAG_STRICT
    ; SYS_GUI_GLYPH_BAKE(codepoint, fg, bg) -> atlas cell index or -1. All
    ; scalars; returns GLYPH_NONE (-1) for now (no atlas surface yet).
    SYSCALL_ENTRY syscall_entry.sc_gui_glyph_bake,   3, SC_KIND3(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_GUI_DRAW
    ; SYS_WM_LIST(out_buf, max_entries) -> count of open windows written (-1 reject).
    ; Read-only enumeration for the ring-3 desktop shell's taskbar. Each record is
    ; WM_LIST_REC bytes: u32 id, u32 flags, 40-byte title (=48). CAP_WM_QUERY-gated
    ; so only the shell can see the window list. arg_desc validates the PTR for
    ; count * WM_LIST_REC(48) bytes at the dispatcher (was count*1 - an
    ; under-check the handler had to cover); STRICT denies a raw nibble.
    SYSCALL_ENTRY syscall_entry.sc_wm_list,          2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_WM_QUERY, (SC_DESC_LENx(0, 2, SCSZ_48) | SC_DESC_WRITE(0)), SC_FLAG_STRICT

    ; Fixed sparse driver ABI. Reserved rows fail closed. CAP_DRIVER is absent
    ; from every built-in app manifest and is installed only for an admitted
    ; driver slot by the future external-driver loader.
    %rep (232 - 81)
        SYSCALL_ENTRY syscall_entry.sc_drvhost_denied, 0, 0, CAP_DRIVER
    %endrep
    ; 232 REGISTER(requested_caps): policy and identity are kernel-owned.
    SYSCALL_ENTRY syscall_entry.sc_drvhost_register,     1, SC_KIND1(FN_KIND_SCALAR), CAP_DRIVER
    ; 233..236 MMIO/DMA/IRQ/PIO grant requests are control-plane only.
    %rep 4
        SYSCALL_ENTRY syscall_entry.sc_drvhost_denied,   0, 0, CAP_DRIVER
    %endrep
    ; 237..239 reserved.
    %rep 3
        SYSCALL_ENTRY syscall_entry.sc_drvhost_denied,   0, 0, CAP_DRIVER
    %endrep
    SYSCALL_ENTRY syscall_entry.sc_drvhost_mmio_read32,  1, SC_KIND1(FN_KIND_SCALAR), CAP_DRIVER
    SYSCALL_ENTRY syscall_entry.sc_drvhost_mmio_write32, 2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_DRIVER
    ; 242 DMA map and 243 IRQ wait await the manager mapping/event path.
    %rep 2
        SYSCALL_ENTRY syscall_entry.sc_drvhost_denied,   0, 0, CAP_DRIVER
    %endrep
    SYSCALL_ENTRY syscall_entry.sc_drvhost_pio_read8,    1, SC_KIND1(FN_KIND_SCALAR), CAP_DRIVER
    SYSCALL_ENTRY syscall_entry.sc_drvhost_pio_write8,   2, SC_KIND2(FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_DRIVER
    SYSCALL_ENTRY syscall_entry.sc_drvhost_ring_establish, 1, SC_KIND1(FN_KIND_SCALAR), CAP_DRIVER
    SYSCALL_ENTRY syscall_entry.sc_drvhost_ring_submit,  2, SC_KIND2(FN_KIND_PTR, FN_KIND_SCALAR), CAP_DRIVER, (SC_DESC_LENx(0, 2, SCSZ_16) | SC_DESC_WRITE(0)), SC_FLAG_STRICT
    SYSCALL_ENTRY syscall_entry.sc_drvhost_pci_cfg_read32, 4, SC_KIND4(FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR, FN_KIND_SCALAR), CAP_DRIVER
    ; 249 cross-driver MMIO grant is control-plane only.
    SYSCALL_ENTRY syscall_entry.sc_drvhost_denied,       0, 0, CAP_DRIVER
syscall_table_end:
syscall_table_count equ (syscall_table_end - syscall_table) / SYSCALL_ENTRY_SIZE

FN_BEGIN test_syscall_proc, 0, 0, FN_RET_VOID
.loop:
    hlt
    jmp .loop

; ----------------------------------------------------------------------------
; kernel_canary_init - seed the global stack canary from RDTSC ^ RDRAND and a
; signed public QRNG commitment. Called once before syscall_init. Release builds
; fail closed without a successful hardware draw; debug/QEMU may fall back to
; timing only. A final non-zero guard prevents an all-zero canary.
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
    jmp .kc_mix_commitment
.kc_no_rdrand:
%ifdef RELEASE_BUILD
    ; A public commitment cannot replace secret entropy. Release kernels refuse
    ; to boot if RDRAND is unavailable or fails all retries. Debug/QEMU builds
    ; retain the timing fallback strictly for testability.
    ud2
%endif
.kc_mix_commitment:
    ; Mix the signed PUBLIC QRNG commitment as a domain salt. KERNEL.ENV covers
    ; these bytes, preventing substitution without invalidating the release
    ; signature. Secrecy still comes from the per-boot hardware draw above.
    push rsi
    push rcx
    lea rsi, [rel qrng_commitment]
    mov ecx, qrng_commitment_len / 8
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

