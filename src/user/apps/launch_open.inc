app_open_file:
    ; Extension routing. The 3-byte field at entry+8 holds the 8.3 extension,
    ; already upper-cased and space-padded by FAT16. Match against the known
    ; media extensions first; everything else opens in Notepad.
    ;
    ;   "BMP" → legacy BMP viewer (kept for back-compat)
    ;   "NIC" → Media Player (native still image)
    ;   "NBA" → Media Player (native animation)
    ;   "SVG" → Media Player (subset rasteriser; see media_viewer.inc §6)
    ;   "XML" → Media Player (renders as plain text view)
    ;
    ; Adding a new media format = one new compare block here that jumps to
    ; app_open_file_in_media, plus a codec row in media_viewer.inc §2.
    cmp byte [rdi + 8], 'B'
    jne .not_bmp
    cmp byte [rdi + 9], 'M'
    jne .not_bmp
    cmp byte [rdi + 10], 'P'
    jne .not_bmp
    jmp app_open_file_in_bmpview
.not_bmp:
    cmp byte [rdi + 8], 'N'
    jne .check_svg
    cmp byte [rdi + 9], 'I'
    jne .check_nba
    cmp byte [rdi + 10], 'C'
    jne .not_native_media
    jmp app_open_file_in_media
.check_nba:
    cmp byte [rdi + 9], 'B'
    jne .not_native_media
    cmp byte [rdi + 10], 'A'
    jne .not_native_media
    jmp app_open_file_in_media
.check_svg:
    cmp byte [rdi + 8], 'S'
    jne .check_xml
    cmp byte [rdi + 9], 'V'
    jne .not_native_media
    cmp byte [rdi + 10], 'G'
    jne .not_native_media
    jmp app_open_file_in_media
.check_xml:
    cmp byte [rdi + 8], 'X'
    jne .not_native_media
    cmp byte [rdi + 9], 'M'
    jne .not_native_media
    cmp byte [rdi + 10], 'L'
    jne .not_native_media
    jmp app_open_file_in_media
.not_native_media:
    jmp app_open_file_in_notepad

; ============================================================================
; app_open_file_in_media - thin user-mode wrapper. Routes to a kernel helper
; via SYS_OPEN_FILE_NP semantics - see kernel_open_file_in_media below for
; why the heavy lifting must run in kernel context (real fat16 globals).
; RDI = dir entry pointer
; ============================================================================
global app_open_file_in_media
app_open_file_in_media:
    SYS_OPEN_FILE_MEDIA rdi
    ret

; ============================================================================
; app_open_file_in_notepad - thin user-mode wrapper.
;   Routes everything through SYS_OPEN_FILE_NP so the heavy lifting (launch
;   notepad, read FAT16, parse lines, push into the notepad slot) runs in
;   kernel mode where the globals it touches actually live. When this code
;   ran in Ring 3 it modified the *caller's* (explorer's) slot copy of
;   notepad_buf, which is why every notepad stayed seeded with "Hello".
; RDI = slot-cached dir entry pointer
; ============================================================================
global app_open_file_in_notepad
app_open_file_in_notepad:
    SYS_OPEN_FILE_NP rdi
    ret

; ============================================================================
; kernel_open_file_in_notepad - runs in kernel context. Same semantics as the
; old user-mode helper, but uses direct kernel calls instead of syscall
; macros and finishes by re-copying the blob into the new notepad's slot so
; the slot reflects the freshly-loaded file contents.
;
; Note: common.inc %xdefine'd FAT16 helpers to user-mode syscall wrappers.
; Locally restore the real kernel symbols for launch helpers that run in ring 0;
; restore the aliases afterwards so the rest of the user blob is unaffected.
; RDI = slot-cached dir entry pointer
; Returns RAX = window id, or -1 on launch failure
; ============================================================================
%undef fat16_file_count
%undef fat16_get_entry
%undef fat16_change_dir
%undef fat16_read_file
extern fat16_file_count
extern fat16_get_entry
extern fat16_change_dir
extern fat16_read_file

; kernel_open_app_command - secure command-line app launcher.
; RDI = validated user cstring: "app" or "app params"
; Returns RAX = window id, or -1.
global kernel_open_app_command
kernel_open_app_command:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi

    ; Copy the caller string into a bounded kernel-owned buffer before parsing.
    lea rdi, [app_open_cmd_buf]
    mov rsi, r12
    mov ecx, APP_SLOT_PARAM_SZ - 1
.koac_copy_cmd:
    lodsb
    stosb
    test al, al
    jz .koac_cmd_copied
    dec ecx
    jnz .koac_copy_cmd
    mov byte [rdi], 0
.koac_cmd_copied:

    lea rbx, [app_open_cmd_buf]
.koac_skip_lead:
    mov al, [rbx]
    cmp al, ' '
    je .koac_skip_lead_1
    cmp al, 9
    jne .koac_have_name
.koac_skip_lead_1:
    inc rbx
    jmp .koac_skip_lead
.koac_have_name:
    cmp byte [rbx], 0
    je .koac_fail
    mov r12, rbx

.koac_find_name_end:
    mov al, [rbx]
    test al, al
    jz .koac_name_ended
    cmp al, ' '
    je .koac_name_delim
    cmp al, 9
    je .koac_name_delim
    cmp al, ','
    je .koac_name_delim
    inc rbx
    jmp .koac_find_name_end
.koac_name_delim:
    mov byte [rbx], 0
    inc rbx
.koac_name_ended:
    mov rdi, r12
    call app_command_name_to_id
    test eax, eax
    jz .koac_fail
    mov r13d, eax

    ; Copy raw params, trimming leading whitespace/commas only.
.koac_skip_param_lead:
    mov al, [rbx]
    cmp al, ' '
    je .koac_skip_param_1
    cmp al, 9
    je .koac_skip_param_1
    cmp al, ','
    jne .koac_copy_params_start
.koac_skip_param_1:
    inc rbx
    jmp .koac_skip_param_lead
.koac_copy_params_start:
    lea rdi, [app_open_param_buf]
    xor eax, eax
    mov ecx, APP_SLOT_PARAM_SZ
    cld
    rep stosb
    lea rdi, [app_open_param_buf]
    mov rsi, rbx
    mov ecx, APP_SLOT_PARAM_SZ - 1
.koac_copy_param:
    lodsb
    stosb
    test al, al
    jz .koac_param_copied
    dec ecx
    jnz .koac_copy_param
    mov byte [rdi], 0
.koac_param_copied:

    cmp r13d, APP_NOTEPAD
    jne .koac_launch_generic
    cmp byte [app_open_param_buf], 0
    je .koac_launch_generic
    lea rdi, [app_open_param_buf]
    call app_find_entry_by_path
    test rax, rax
    jz .koac_fail
    mov rdi, rax
    call kernel_open_file_in_notepad
    cmp rax, -1
    je .koac_done
    mov edi, eax
    lea rsi, [app_open_param_buf]
    call app_store_launch_params
    jmp .koac_done

.koac_launch_generic:
    mov edi, r13d
    sub rsp, 8
    call app_launch
    add rsp, 8
    cmp rax, -1
    je .koac_done
    mov edi, eax
    lea rsi, [app_open_param_buf]
    call app_store_launch_params
    jmp .koac_done

.koac_fail:
    mov rax, -1
.koac_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; RDI = app name token, returns EAX = APP_* id or 0.
app_command_name_to_id:
    lea rsi, [szAppNameExplorer]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_explorer
    lea rsi, [szAppNameTerminal]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_terminal
    lea rsi, [szAppNameNotepad]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_notepad
    lea rsi, [szAppNameSettings]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_settings
    lea rsi, [szAppNamePaint]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_paint
    lea rsi, [szAppNameAbout]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_about
%ifndef RELEASE_BUILD
    lea rsi, [szAppNameSecurity]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_security
    lea rsi, [szAppNameSecurityProbe]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_security
%endif
    lea rsi, [szAppNamePing]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_ping
    lea rsi, [szAppNameMedia]
    call app_str_eq_ci
    test eax, eax
    jnz .acnti_media
    xor eax, eax
    ret
.acnti_explorer:
    mov eax, APP_EXPLORER
    ret
.acnti_terminal:
    mov eax, APP_TERMINAL
    ret
.acnti_notepad:
    mov eax, APP_NOTEPAD
    ret
.acnti_settings:
    mov eax, APP_SETTINGS
    ret
.acnti_paint:
    mov eax, APP_PAINT
    ret
.acnti_about:
    mov eax, APP_ABOUT
    ret
%ifndef RELEASE_BUILD
.acnti_security:
    mov eax, APP_SECURITY_PROBE
    ret
%endif
.acnti_ping:
    mov eax, APP_PING
    ret
.acnti_media:
    mov eax, APP_MEDIA
    ret

; Case-insensitive ASCII strcmp. RDI=a, RSI=b, EAX=1 on match.
app_str_eq_ci:
    push rdi
    push rsi
.ase_loop:
    mov al, [rdi]
    mov ah, [rsi]
    cmp al, 'A'
    jb .ase_a_ready
    cmp al, 'Z'
    ja .ase_a_ready
    add al, 32
.ase_a_ready:
    cmp ah, 'A'
    jb .ase_b_ready
    cmp ah, 'Z'
    ja .ase_b_ready
    add ah, 32
.ase_b_ready:
    cmp al, ah
    jne .ase_no
    test al, al
    jz .ase_yes
    inc rdi
    inc rsi
    jmp .ase_loop
.ase_yes:
    mov eax, 1
    jmp .ase_done
.ase_no:
    xor eax, eax
.ase_done:
    pop rsi
    pop rdi
    ret

; EDI=window id, RSI=params. Copies params into the target app slot.
app_store_launch_params:
    push rax
    push rcx
    push rdi
    push rsi
    cmp edi, MAX_WINDOWS
    jae .aslp_done
    mov eax, edi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    mov rdi, [rax + WIN_OFF_APPDATA]
    test rdi, rdi
    jz .aslp_done
    add rdi, APP_SLOT_PARAM_OFF
    mov ecx, APP_SLOT_PARAM_SZ
    cld
    rep movsb
.aslp_done:
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; RDI=path. Resolves root/current FAT16 path to a live dir-entry pointer.
app_find_entry_by_path:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov r12, rdi
    ; A root-qualified path starts at /, \, C:/, C:\, or root/.
    cmp byte [r12], '/'
    je .afebp_root_slash
    cmp byte [r12], '\'
    je .afebp_root_slash
    mov al, [r12]
    cmp al, 'C'
    je .afebp_drive_maybe
    cmp al, 'c'
    jne .afebp_root_name_maybe
.afebp_drive_maybe:
    cmp byte [r12 + 1], ':'
    jne .afebp_root_name_maybe
    mov ax, 0
    call fat16_change_dir
    add r12, 2
    jmp .afebp_skip_slashes
.afebp_root_name_maybe:
    mov rdi, r12
    lea rsi, [szAppNameRoot]
    call app_path_has_prefix
    test eax, eax
    jz .afebp_component_loop
    mov ax, 0
    call fat16_change_dir
    add r12, 4
    jmp .afebp_skip_slashes
.afebp_root_slash:
    mov ax, 0
    call fat16_change_dir
.afebp_skip_slashes:
    cmp byte [r12], '/'
    je .afebp_skip_one
    cmp byte [r12], '\'
    jne .afebp_component_loop
.afebp_skip_one:
    inc r12
    jmp .afebp_skip_slashes

.afebp_component_loop:
    cmp byte [r12], 0
    je .afebp_fail
    lea rdi, [app_open_comp_buf]
    xor ecx, ecx
.afebp_copy_comp:
    mov al, [r12]
    test al, al
    jz .afebp_comp_done
    cmp al, '/'
    je .afebp_comp_done
    cmp al, '\'
    je .afebp_comp_done
    cmp ecx, 63
    jae .afebp_fail
    mov [rdi], al
    inc rdi
    inc r12
    inc ecx
    jmp .afebp_copy_comp
.afebp_comp_done:
    mov byte [rdi], 0
    lea rdi, [app_open_comp_buf]
    lea rsi, [app_open_83_buf]
    call filename_to_83
    lea rdi, [app_open_83_buf]
    call app_find_entry_83
    test rax, rax
    jz .afebp_fail
    mov r14, rax
    ; Skip separators and decide if this is the final component.
.afebp_after_comp_slashes:
    cmp byte [r12], '/'
    je .afebp_after_comp_skip
    cmp byte [r12], '\'
    jne .afebp_after_comp_ready
.afebp_after_comp_skip:
    inc r12
    jmp .afebp_after_comp_slashes
.afebp_after_comp_ready:
    cmp byte [r12], 0
    je .afebp_success
    mov al, [r14 + 11]
    test al, 0x10
    jz .afebp_fail
    mov ax, [r14 + 26]
    call fat16_change_dir
    test eax, eax
    jnz .afebp_fail
    jmp .afebp_component_loop

.afebp_success:
    mov rax, r14
    jmp .afebp_done
.afebp_fail:
    xor eax, eax
.afebp_done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI=path, RSI=literal prefix. EAX=1 if followed by /, \, or NUL.
app_path_has_prefix:
    push rdi
    push rsi
.aphp_loop:
    mov al, [rsi]
    test al, al
    jz .aphp_prefix_done
    mov ah, [rdi]
    cmp ah, 'A'
    jb .aphp_cmp
    cmp ah, 'Z'
    ja .aphp_cmp
    add ah, 32
.aphp_cmp:
    cmp ah, al
    jne .aphp_no
    inc rdi
    inc rsi
    jmp .aphp_loop
.aphp_prefix_done:
    mov al, [rdi]
    test al, al
    jz .aphp_yes
    cmp al, '/'
    je .aphp_yes
    cmp al, '\'
    je .aphp_yes
.aphp_no:
    xor eax, eax
    jmp .aphp_done
.aphp_yes:
    mov eax, 1
.aphp_done:
    pop rsi
    pop rdi
    ret

; RDI=11-byte 8.3 name. Returns matching current-directory entry or 0.
app_find_entry_83:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rdi
    call fat16_file_count
    mov ebx, eax
    xor ecx, ecx
.afe83_loop:
    cmp ecx, ebx
    jge .afe83_fail
    mov edi, ecx
    push rcx
    call fat16_get_entry
    pop rcx
    test rax, rax
    jz .afe83_fail
    mov rsi, r12
    mov rdi, rax
    mov edx, 11
.afe83_cmp:
    mov al, [rdi]
    cmp al, [rsi]
    jne .afe83_next
    inc rdi
    inc rsi
    dec edx
    jnz .afe83_cmp
    sub rdi, 11
    mov rax, rdi
    jmp .afe83_done
.afe83_next:
    inc ecx
    jmp .afe83_loop
.afe83_fail:
    xor eax, eax
.afe83_done:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

global kernel_open_file_in_notepad
; Open a FAT16 file (RDI = dir-entry ptr) in a fresh Notepad window. All per-
; instance state is written directly into the new window's L3 slot - never
; into the kernel image's np_* master copies. The kernel-side notepad_buf is
; used as a transient raw-bytes scratch, scoped strictly to this call.