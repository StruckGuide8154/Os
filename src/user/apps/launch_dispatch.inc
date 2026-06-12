app_launch:
    sub rsp, 8
    mov [rsp], rdi                     ; preserve app id across kfault_arm (rdi)
    lea rdi, [rel .al_land]
    call kfault_arm                    ; kfault_jmp_rsp -> this app-id slot
    mov rdi, [rsp]                     ; restore app id
    call app_launch_impl
    call kfault_disarm
    add rsp, 8
    ret
.al_land:
    ; Reached via the ISR longjmp after a recovered ring-0 fault inside the
    ; launch body. Callee-saved regs + RSP were restored to their kfault_arm
    ; snapshot; RSP points at the app-id slot. Disarm and fail soft.
    call kfault_disarm
    add rsp, 8
    mov rax, -1
    ret

app_launch_impl:
    SER 'L'
    SER '['
    push rdi
    call ser_print_hex64
    pop rdi
    SER ']'
    cmp rdi, APP_EXPLORER
    je .launch_explorer
    cmp rdi, APP_TERMINAL
    je .launch_terminal
    cmp rdi, APP_NOTEPAD
    je .launch_notepad
    cmp rdi, APP_SETTINGS
    je .launch_settings
    cmp rdi, APP_PAINT
    je .launch_paint
    cmp rdi, APP_ABOUT
    je .launch_about
%ifndef RELEASE_BUILD
    cmp rdi, APP_SECURITY_PROBE
    je .launch_security_probe
%endif
    cmp rdi, APP_TASKMGR
    je .launch_taskmgr
    cmp rdi, APP_PING
    je .launch_ping
    cmp rdi, APP_MEDIA
    je .launch_media
    mov rax, -1
    ret

.launch_explorer:
    SER 'E'
    SER 'e'
    ; Reset explorer state to root
    mov dword [explorer_sel], 0
    mov dword [explorer_dir], 0
    mov byte [ctx_menu_visible], 0
    mov byte [exp_ctx_visible], 0
    mov byte [exp_rename_active], 0
    mov byte [exp_newfolder_active], 0
    mov byte [exp_newfolder_done_msg], 0
    mov byte [exp_prop_visible], 0
    lea rdi, [rel szExplorerTitle]
    mov rsi, 120
    mov rdx, 80
    mov rcx, 420
    mov r8, 340
    mov r9, app_hl_explorer_draw
    SER '{'
    sub rsp, 8               ; Align stack
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_EXPLORER
    call app_refresh_window_slot
    call app_reset_explorer_slot
    mov r10, app_hl_explorer_click
    mov r11, app_hl_explorer_key
    call app_set_window_handlers
    mov r10, app_hl_explorer_rclick
    call app_set_window_rclick
    SER 'e'
    jmp .done

.launch_terminal:
    ; Terminal is now a pure-GritHL app (src/user/grithl/apps/terminal.ghl).
    ; Per-slot state lives in its state{} block (zero-initialised on copy) and
    ; the welcome banner is seeded lazily on first draw, so no launch-time
    ; state/history/fat16 seeding is required - same shape as .launch_ping.
    lea rdi, [rel szTermTitle]
    mov rsi, 200
    mov rdx, 150
    mov rcx, 450
    mov r8, 300
    mov r9, app_hl_terminal_draw
    sub rsp, 8               ; Align stack
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_TERMINAL
    mov r10, app_hl_terminal_click
    mov r11, app_hl_terminal_key
    call app_set_window_handlers
    jmp .done

.launch_notepad:
    SER 'N'
    SER 'n'
    ; Per-instance state is owned by the L3 slot; app_seed_notepad_slot below
    ; populates it. Do NOT touch the kernel image's np_* master copies here -
    ; they are linker placeholders, not shared state, and were a source of
    ; cross-instance corruption when used as scratch.
    lea rdi, [rel szNotepadTitle]
    mov rsi, 250
    mov rdx, 120
    mov rcx, 400
    mov r8, 300
    mov r9, app_hl_notepad_draw
    SER '{'
    sub rsp, 8               ; Align stack
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_NOTEPAD
    call app_seed_notepad_slot
    mov r10, app_hl_notepad_click
    mov r11, app_hl_notepad_key
    call app_set_window_handlers
    SER 'n'
    jmp .done

.launch_settings:
    SER 'S'
    SER 's'
    lea rdi, [rel szSettingsTitle]
    mov rsi, 300
    mov rdx, 180
    mov rcx, 380
    mov r8, 340
    mov r9, app_hl_settings_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_SETTINGS
    mov r10, app_hl_settings_click
    mov r11, app_hl_settings_key
    call app_set_window_handlers
    SER 's'
    jmp .done

.launch_paint:
    SER 'P'
    SER 'p'
    ; Per-instance paint state is owned by the L3 slot via the GritHL
    ; `state {}` block; the kernel-image paint_* placeholders are unused.
    lea rdi, [rel szPaintTitle]
    mov rsi, 150
    mov rdx, 100
    mov rcx, 340   ; width (toolbar + canvas)
    mov r8, 240    ; height (toolbar + canvas)
    mov r9, app_hl_paint_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_PAINT
    mov r10, app_hl_paint_click
    mov r11, app_hl_paint_key
    call app_set_window_handlers
    mov r10, app_hl_paint_drag
    call app_set_window_drag
    SER 'p'
    jmp .done

.launch_about:
    SER 'B'
    SER 'b'
    lea rdi, [rel szAboutTitle]
    mov rsi, 280
    mov rdx, 200
    mov rcx, 380
    mov r8, 300
    mov r9, app_hl_about_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_ABOUT
    mov r10, app_hl_about_click
    mov r11, app_hl_about_key
    call app_set_window_handlers
    SER 'b'
    jmp .done

.launch_security_probe:
%ifndef RELEASE_BUILD
    lea rdi, [rel szSecurityProbeTitle]
    mov rsi, 80
    mov rdx, 70
    mov rcx, 520
    mov r8, 260
    mov r9, app_security_probe_draw
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_SECURITY_PROBE
    xor r10d, r10d
    xor r11d, r11d
    call app_set_window_handlers
    jmp .done
%endif

.launch_taskmgr:
    SER 'M'
    SER 'm'
    lea rdi, [rel szTaskMgrTitle]
    mov rsi, 200
    mov rdx, 120
    mov rcx, 360
    mov r8, 300
    mov r9, app_hl_taskmgr_draw
    SER '{'
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    SER '}'
    push rax
    push rdi
    mov rdi, rax
    call ser_print_hex64
    pop rdi
    pop rax
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_TASKMGR
    mov r10, app_hl_taskmgr_click
    mov r11, app_hl_taskmgr_key
    call app_set_window_handlers
    SER 'm'
    jmp .done

.launch_media:
    ; The Media Player's draw fn is the kernel asm renderer (codec dispatch
    ; in media_viewer.asm), not the auto-generated app_hl_media_draw stub.
    ; Click/key still route through the ghl handlers so future UI work can
    ; live in media.ghl without touching this glue.
    lea rdi, [rel szMediaTitle]
    mov rsi, 180
    mov rdx, 120
    mov rcx, 480
    mov r8, 340
    lea r9, [rel app_media_draw]
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_MEDIA
    call app_refresh_window_slot
    mov r10, app_hl_media_click
    mov r11, app_hl_media_key
    call app_set_window_handlers
    jmp .done

.launch_ping:
    lea rdi, [rel szPingTitle]
    mov rsi, 220
    mov rdx, 90
    mov rcx, 480
    mov r8, 360
    mov r9, app_hl_ping_draw
    sub rsp, 8
    call wm_create_window_ex
    add rsp, 8
    cmp rax, -1
    je .done
    APPLY_MANIFEST APP_PING
    mov r10, app_hl_ping_click
    mov r11, app_hl_ping_key
    call app_set_window_handlers
    jmp .done

.done:
    ret


; ============================================================================
; app_open_file - Open a file, routing by extension
; RDI = pointer to FAT16 dir entry (32 bytes)
; ============================================================================
global app_open_file