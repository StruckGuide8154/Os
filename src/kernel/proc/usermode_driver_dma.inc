; ============================================================================
; usermode_driver_dma.inc - per-driver DMA-window paging (Track 8 loader).
;
; The driver-host broker (driver_host.ghl) never touches page tables itself; it
; calls these two thin TCB helpers to alias a driver's granted coherent DMA
; buffer into that driver's OWN ring-3 arena and to tear the alias down. The
; broker has already proven, before calling in here, that `phys` is the base of a
; DMA window it granted to this driver and that the driver holds DRV_CAP_DMA - so
; these helpers only do bounds-checked PTE writes, mirroring l3_apply_slot_
; isolation's discipline (edits bracketed in the nk_pt_window WP-off window
; because the arena PTEs live in the Phase-2 read-only page-table region).
;
; The DMA window is a FIXED per-slot sub-range [L3_SLOT_DMA_OFF, +L3_SLOT_DMA_MAX)
; mapped PRESENT|USER|WRITABLE|NX. It is disjoint by construction from the code
; blob, handle table, user stack, and shadow window (asserted in boot_memory.inc),
; and the map helper additionally fail-closes if a slot's committed code range
; would reach into the window - so a driver can never obtain an executable or
; cross-region DMA alias.
; ============================================================================

; l3_map_driver_dma - map a driver's granted DMA window into its own arena slot.
;   RDI = slot (0-based, = driver_id - 1)
;   RSI = device-physical base of the granted window (page-aligned, <4 GiB)
;   RDX = byte length of the window
; Returns RAX = ring-3 VA of the mapped window, or 0 on any fail-closed check.
FN_BEGIN l3_map_driver_dma, 3, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r8d, edi                     ; r8 = slot
    cmp r8, MAX_WINDOWS
    jae .mdd_fail
    test rdx, rdx
    jz .mdd_fail
    cmp rdx, L3_SLOT_DMA_MAX
    ja .mdd_fail
    ; phys must be page-aligned and non-zero (page_alloc_contig returns aligned).
    test rsi, 0xFFF
    jnz .mdd_fail
    test rsi, rsi
    jz .mdd_fail
    ; The slot's committed code range must not reach the DMA window, so a driver
    ; blob and its DMA alias can never overlap (loader keeps driver code low).
    mov rax, [l3_wx_code_end + r8*8]
    cmp rax, L3_SLOT_DMA_OFF
    ja .mdd_fail

    ; page count = ceil(len / 4096), bounded to L3_SLOT_DMA_PAGES by the len check.
    mov rcx, rdx
    add rcx, 0xFFF
    shr rcx, 12                      ; rcx = pages (1..L3_SLOT_DMA_PAGES)

    ; PT cursor = APP_ARENA_PT_BASE + slot*ARENA_SLOT_PAGES*8 + L3_SLOT_DMA_PTE0*8
    mov rax, r8
    imul rax, ARENA_SLOT_PAGES * 8
    add rax, APP_ARENA_PT_BASE
    add rax, L3_SLOT_DMA_PTE0 * 8
    mov r9, rax                      ; r9 = &PTE[0]

    mov r10, rsi                     ; r10 = phys cursor
    call nk_pt_window_begin
.mdd_fill:
    mov rax, r10
    or rax, 0x07                     ; PRESENT | WRITABLE | USER
    mov rbx, PAGE_NX
    or rax, rbx                      ; + NX (a DMA buffer is never executable)
    mov [r9], rax
    add r9, 8
    add r10, 0x1000
    dec rcx
    jnz .mdd_fill
    call nk_pt_window_end            ; restore WP + flush TLB (mapping now live)

    ; VA = arena_base + slot*APP_SLOT_SIZE + L3_SLOT_DMA_OFF
    mov rax, r8
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    add rax, L3_SLOT_DMA_OFF
    jmp .mdd_done
.mdd_fail:
    xor eax, eax
.mdd_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; l3_unmap_driver_dma - clear the whole per-slot DMA window (all L3_SLOT_DMA_PAGES
; PTEs -> non-present). RDI = slot. Idempotent; clearing already-zero PTEs is
; harmless. Called on cooperative unmap and on quarantine/restart revocation.
FN_BEGIN l3_unmap_driver_dma, 1, 0, FN_RET_SCALAR
    push rcx
    push r8
    push r9
    mov r8d, edi
    cmp r8, MAX_WINDOWS
    jae .mud_done
    mov rax, r8
    imul rax, ARENA_SLOT_PAGES * 8
    add rax, APP_ARENA_PT_BASE
    add rax, L3_SLOT_DMA_PTE0 * 8
    mov r9, rax
    mov rcx, L3_SLOT_DMA_PAGES
    call nk_pt_window_begin
.mud_clear:
    mov qword [r9], 0
    add r9, 8
    dec rcx
    jnz .mud_clear
    call nk_pt_window_end
.mud_done:
    xor eax, eax
    pop r9
    pop r8
    pop rcx
    ret
