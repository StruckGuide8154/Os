FN_BEGIN wm_init, 0, 0, FN_RET_VOID
    push rbx
    ; Zero out window pool
    mov rdi, WINDOW_POOL_ADDR
    mov rcx, MAX_WINDOWS * WINDOW_STRUCT_SIZE
    xor rax, rax
    rep stosb
    mov qword [wm_window_count], 0
    mov qword [wm_drag_window_id], -1
    mov qword [wm_app_drag_window_id], -1
    mov qword [wm_focused_window], -1

    ; Slot 0 = native GritHL wallpaper renderer. Set it up like a regular
    ; window so wm_draw_desktop_background can call into app_hl_wallpaper_draw
    ; through call_app_l3 / the normal l3 ABI.
    mov rbx, WINDOW_POOL_ADDR
    mov qword [rbx + WIN_OFF_ID], 0
    mov qword [rbx + WIN_OFF_X], 0
    mov qword [rbx + WIN_OFF_Y], 0
    mov eax, [scr_width]
    mov [rbx + WIN_OFF_W], rax
    mov eax, [scr_height]
    mov [rbx + WIN_OFF_H], rax
    ; Note: NO flags. Slot 0 is invisible to window iteration (focus, hit
    ; testing, draw loop) -- it only exists to give call_app_l3 a stable
    ; per-slot L3 arena for the wallpaper renderer.
    mov qword [rbx + WIN_OFF_FLAGS], 0
    lea rax, [rel app_hl_wallpaper_draw]
    mov [rbx + WIN_OFF_DRAWFN], rax
    xor edi, edi
    call l3_slot_base
    mov [rbx + WIN_OFF_APPDATA], rax

    ; Slot 0 is a kernel-owned hidden app, so it never passes through the
    ; normal launcher manifest path. Grant only the GUI authority its renderer
    ; needs: display queries/background selection plus SVG raster syscalls.
    xor edi, edi
    mov esi, CAP_CORE | CAP_GUI
    call cap_mask_store

    ; Give the hidden wallpaper renderer a PCB so expensive SVG callbacks can
    ; be pinned to an AP home_core instead of falling back to the BSP.
    lea rdi, [rel app_hl_wallpaper_draw]
    xor esi, esi
    xor edx, edx
    call process_create
    mov [wallpaper_process_id], eax

    pop rbx
    FN_END wm_init
    ret

; Create window (simple): RDI=title, RSI=x, RDX=y, RCX=w, R8=h
; Returns RAX = window ID (-1 on fail)
FN_BEGIN wm_create_window, 5, 0, FN_RET_HANDLE
    xor r9d, r9d
    FN_END wm_create_window
    jmp wm_do_create

FN_BEGIN wm_create_window_ex, 6, 0, FN_RET_HANDLE
    FN_END wm_create_window_ex
    jmp wm_do_create

wm_do_create:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Save args
    mov r12, rdi         ; title
    mov r13, rsi         ; x
    mov r14, rdx         ; y
    mov r15, rcx         ; w
    ; r8 = h, r9 = draw_fn already in regs

    mov rax, r13
    or  rax, r14
    or  rax, r15
    or  rax, r8
    shr rax, 32
    jnz .fail
    cmp r15d, MIN_WINDOW_W
    jb .fail
    cmp r8d, MIN_WINDOW_H
    jb .fail
    ; Clamp against the RUNTIME framebuffer resolution (UEFI GOP scr_width/
    ; scr_height), not the compile-time SCREEN_WIDTH/SCREEN_HEIGHT fallback
    ; constants (1024x768). The active GOP mode is commonly larger (e.g.
    ; 1920x1200), and the full-screen WF_SHELL desktop is created at the live
    ; scr_width x scr_height -- comparing against the stale constants rejected
    ; it (x+w > 1024) and returned -1, leaving a blank desktop with no taskbar.
    mov eax, r13d
    add eax, r15d
    jc .fail
    cmp eax, [scr_width]
    ja .fail
    mov eax, r14d
    add eax, r8d
    jc .fail
    cmp eax, [scr_height]
    ja .fail

    ; Slot 0 is reserved for the native desktop wallpaper renderer's
    ; GritHL state. Normal windows use slots 1..MAX_WINDOWS-1.
    cmp qword [wm_window_count], MAX_WINDOWS - 1
    jge .fail

    ; Unfocus all existing windows
    mov rbx, WINDOW_POOL_ADDR
    xor ecx, ecx
.unfocus_loop:
    cmp ecx, MAX_WINDOWS
    je .unfocus_done
    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .unfocus_next
    and qword [rbx + WIN_OFF_FLAGS], ~WF_FOCUSED
.unfocus_next:
    add rbx, WINDOW_STRUCT_SIZE
    inc ecx
    jmp .unfocus_loop
.unfocus_done:

    ; Find free slot. Under normal builds, start the scan at a randomized
    ; user slot and wrap once. The slot id is part of the user VA
    ; (slot_base = arena_base + slot * 2 MiB), so first-free allocation made
    ; the outer app address predictable even though the blob and stack are
    ; slid inside the slot. GRIT_NO_MEM_RANDOM keeps diagnostics stable.
%ifdef GRIT_NO_MEM_RANDOM
    mov ecx, 1
%else
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov r10, rax
    mov eax, 1
    cpuid
    test ecx, 1 << 30
    jz .slot_no_rdrand
    mov ecx, 8
.slot_try_rdrand:
    rdrand rax
    jc .slot_have_rdrand
    dec ecx
    jnz .slot_try_rdrand
    jmp .slot_no_rdrand
.slot_have_rdrand:
    xor r10, rax
.slot_no_rdrand:
    rdtsc
    shl rdx, 32
    or rax, rdx
    xor r10, rax
    mov rax, r10
    xor edx, edx
    mov ecx, MAX_WINDOWS - 1
    div rcx                              ; rdx = 0..MAX_WINDOWS-2
    lea ecx, [edx + 1]                   ; user slots are 1..MAX_WINDOWS-1
%endif
    mov r11d, ecx                        ; randomized start slot
    mov r10d, MAX_WINDOWS - 1            ; number of user slots to probe
    mov rax, rcx
    imul rax, WINDOW_STRUCT_SIZE
    lea rbx, [WINDOW_POOL_ADDR + rax]
.find_loop:
    test qword [rbx + WIN_OFF_FLAGS], WF_ACTIVE
    jz .found_slot
    inc ecx
    cmp ecx, MAX_WINDOWS
    jb .find_next_ready
    mov ecx, 1
.find_next_ready:
    mov rax, rcx
    imul rax, WINDOW_STRUCT_SIZE
    lea rbx, [WINDOW_POOL_ADDR + rax]
    dec r10d
    jnz .find_loop
    jmp .fail

.found_slot:
    ; Zero entire slot first
    push rcx
    mov rdi, rbx
    xor eax, eax
    mov ecx, WINDOW_STRUCT_SIZE
    rep stosb
    pop rcx

    ; ecx = slot index, rbx = ptr
    mov qword [rbx + WIN_OFF_ID], rcx
    mov [rbx + WIN_OFF_X], r13
    mov [rbx + WIN_OFF_Y], r14
    mov [rbx + WIN_OFF_W], r15
    mov [rbx + WIN_OFF_H], r8

    ; Flags = Active | Visible | Focused
    mov rax, WF_VISIBLE | WF_ACTIVE | WF_FOCUSED
    mov [rbx + WIN_OFF_FLAGS], rax

    ; New tenant for this slot index: clear the per-slot sandbox-live flag so the
    ; §12 strike engine suppresses rejects during the launch gap (this window is
    ; drawable now, but kernel_apply_app_manifest has not run yet). The manifest
    ; apply sets slot_sandboxed[slot]=1 once the sandbox is real. Kept independent
    ; of WIN_OFF_FLAGS so a later SYS_WM_CLOSE cannot reopen the strike-immunity
    ; hole. ecx = slot/window index (1..MAX_WINDOWS-1).
    ; See docs/security/finding-strike-immunity-via-self-close.md.
    push rax
    lea rax, [rel slot_sandboxed]
    mov byte [rax + rcx], 0
    pop rax

    ; Copy title (up to 63 chars)
    mov rsi, r12
    lea rdi, [rbx + WIN_OFF_TITLE]
    mov eax, 63
.copy_title:
    test eax, eax
    jz .title_done
    lodsb
    stosb
    test al, al
    jz .title_null
    dec eax
    jmp .copy_title
.title_null:
.title_done:
    mov byte [rdi], 0

    ; Set draw callback
    mov [rbx + WIN_OFF_DRAWFN], r9
    push rcx
    movzx edi, cx
    call l3_slot_base
    pop rcx
    mov [rbx + WIN_OFF_APPDATA], rax

    ; Register process
    mov rdi, r9
    movzx rsi, cx
    movzx rdx, cx
    call process_create

    ; Update globals
    movzx eax, cx
    mov [wm_focused_window], rax
    inc qword [wm_window_count]

    mov rax, rcx         ; Return window ID
    ; Record the freshly-created id for app_launch's kfault landing pad, so a
    ; ring-0 fault before wm_window_finalize can close this orphan instead of
    ; leaking the slot. Harmless for SYS_WM_CREATE callers: launch_pending_win is
    ; only consulted inside app_launch's .al_land, which always re-initialises it
    ; on entry, so a value left here outside a launch is never acted on.
    mov [launch_pending_win], rax
    jmp .done

.fail:
    mov rax, -1
.done:
    FN_END wm_create_window_ex
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Finalize a freshly-launched window: RDI = window ID. Idempotent; preserves RAX.
;
; Called as the LAST step of every app launch (app_launch_impl .done), after the
; capability manifest is applied, the L3 slot is seeded, and the signed
; click/key/draw handlers are installed. Promotes the window to WF_READY (and
; re-asserts WF_VISIBLE) and marks the scene dirty so the WM repaints the
; now-fully-provisioned window on the very next frame.
;
; Until this runs, wm_draw_window skips the window entirely (see WF_READY in
; constants.inc), which closes the launch-ordering race that otherwise painted
; ~1/3 of opened apps blank. Guarded so it only ever finalizes a live slot: a
; bounds-rejected id or an already-closed/free window is a no-op, so a stale id
; can neither resurrect a dead slot nor scribble outside the window pool.
FN_BEGIN wm_window_finalize, 1, 0, FN_RET_VOID
    cmp rdi, MAX_WINDOWS
    jae .wf_done
    push rax
    mov rax, rdi
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .wf_pop
    or qword [rax + WIN_OFF_FLAGS], WF_VISIBLE | WF_READY
    mov byte [scene_dirty], 1
.wf_pop:
    pop rax
.wf_done:
    FN_END wm_window_finalize
    ret

; Close window by ID: RDI = window ID
FN_BEGIN wm_close_window, 1, 0, FN_RET_VOID
    ; Use unsigned compare: jge treats rdi as signed, so a caller-supplied
    ; negative index (e.g. -1) falls through and lets the code below write
    ; WIN_OFF_FLAGS at WINDOW_POOL_ADDR + rdi*256 -- a limited kernel write.
    cmp rdi, MAX_WINDOWS
    jae .close_ret
    push rax
    push rbx
    call process_kill_window
    call l3_release_slot
    mov rax, rdi
    mov rbx, WINDOW_STRUCT_SIZE
    imul rax, rbx
    add rax, WINDOW_POOL_ADDR
    mov qword [rax + WIN_OFF_FLAGS], 0   ; Clear all flags (inactive)
    dec qword [wm_window_count]
    ; If this was focused, move focus to another active visible window so the
    ; user can keep working after closing a launched document.
    cmp [wm_focused_window], rdi
    jne .close_nofocus
    call wm_focus_top_active
.close_nofocus:
    pop rbx
    pop rax
.close_ret:
    FN_END wm_close_window
    ret

wm_focus_top_active:
    push rax
    push rbx
    push rcx
    mov rcx, MAX_WINDOWS
    dec rcx
.fta_loop:
    cmp rcx, 0
    jl .fta_none
    mov rax, rcx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    test qword [rax + WIN_OFF_FLAGS], WF_ACTIVE
    jz .fta_next
    test qword [rax + WIN_OFF_FLAGS], WF_VISIBLE
    jz .fta_next
    test qword [rax + WIN_OFF_FLAGS], WF_MINIMIZED
    jnz .fta_next
    mov rbx, WINDOW_POOL_ADDR
    xor eax, eax
.fta_clear_loop:
    cmp eax, MAX_WINDOWS
    je .fta_set
    and qword [rbx + WIN_OFF_FLAGS], ~WF_FOCUSED
    add rbx, WINDOW_STRUCT_SIZE
    inc eax
    jmp .fta_clear_loop
.fta_set:
    mov rax, rcx
    imul rax, WINDOW_STRUCT_SIZE
    add rax, WINDOW_POOL_ADDR
    or qword [rax + WIN_OFF_FLAGS], WF_FOCUSED
    mov [wm_focused_window], rcx
    jmp .fta_done
.fta_next:
    dec rcx
    jmp .fta_loop
.fta_none:
    mov qword [wm_focused_window], -1
.fta_done:
    pop rcx
    pop rbx
    pop rax
    ret

