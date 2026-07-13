; ============================================================================
; syscall_handlers_wx_net.inc
; syscall_entry handlers: W^X manifest/mprotect/JIT-alias, networking (ping/info/dhcp/tcp/dns)
;
; Extracted verbatim from syscall.asm (textual %include split, no logic change).
; Lines below remain in syscall_entry's local-label scope where applicable.
; ============================================================================
.sc_wx_install_manifest:
    ; rdi = code_start_off, rsi = code_end_off. Offsets are EXPRESSED RELATIVE
    ; TO THE BLOB START (i.e. (sym - app_blob_start)), not the slot base - the
    ; ring-3 app doesn't know its own per-slot code slide. We add the slide
    ; here so the stored bounds are absolute in-slot offsets, matching what
    ; l3_apply_wx_policy and sc_mprotect_wx / sc_wx_jit_alias compare against.
    test rdi, 0xFFF
    jnz .sc_wx_manifest_reject
    test rsi, 0xFFF
    jnz .sc_wx_manifest_reject
    cmp rdi, rsi
    jae .sc_wx_manifest_reject

    ; Apply per-slot code slide.
    mov eax, r15d
    mov rcx, [l3_slot_code_slide + rax*8]
    add rdi, rcx
    add rsi, rcx
    jc  .sc_wx_manifest_reject              ; overflow guard (defense-in-depth)

    cmp rdi, L3_APP_CODE_OFF
    jb .sc_wx_manifest_reject
    cmp rsi, L3_SHADOW_WIN_OFF
    ja .sc_wx_manifest_reject

    call sc_get_slot_bounds                 ; r8 = slot base, r9 = slot end
    mov rax, L3_SLOT_MAGIC
    mov ecx, r15d
    cmp [l3_slot_live + rcx*8], rax
    jne .sc_wx_manifest_reject

    mov eax, r15d
    ; Drop the code-integrity baseline BEFORE mutating the manifest bounds.
    ; These three fields are written with IF=1; a PIT IRQ landing between them
    ; (e.g. new code_start stored while code_end is still the old, smaller value
    ; -> start >= end -> l3_code_hash_compute returns 0) would run
    ; l3_code_hash_verify_all against the STALE baseline and fail closed with
    ; "CANARY 0 @..." (tag WCXH). Clearing valid first makes the verifier skip
    ; this slot across the inconsistent window AND forces l3_apply_wx_policy to
    ; re-capture the hash for the new range (its hash-install is gated on
    ; valid==0). Mirrors the up-front clear in l3_copy_app_blob_to_slot.
    mov byte [l3_code_hash_valid + rax], 0
    mov qword [l3_wx_code_start + rax*8], rdi
    mov qword [l3_wx_code_end + rax*8], rsi
    mov qword [l3_wx_manifest_ver + rax*8], 1

    mov edi, r15d
    call l3_apply_wx_policy
    mov qword [rsp + ALL_RAX], 0
    jmp .done
.sc_wx_manifest_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_mprotect_wx:
    ; rdi = page_addr, rsi = mode (0 = W+NX, 1 = X+!W).
    test rdi, 0xFFF
    jnz .sc_mprotect_reject
    cmp rsi, MPROT_WX_MODE_XRO
    ja .sc_mprotect_reject

    push rbx
    push rcx
    push rdx
    push r10
    push r11
    push r12
    push r13

    mov r10, rdi                         ; page address
    mov r11, rsi                         ; requested mode

    call sc_get_slot_bounds              ; r8 = slot base, r9 = slot end
    mov rdi, r10
    mov rsi, 0x1000
    call sc_range_in_bounds              ; slot-only, not app_blob fallback
    test eax, eax
    jz .sc_mprotect_fail_pop

    mov rax, L3_SLOT_MAGIC
    mov ecx, r15d
    cmp [l3_slot_live + rcx*8], rax
    jne .sc_mprotect_fail_pop
    mov eax, r15d
    cmp qword [l3_wx_manifest_ver + rax*8], 1
    jne .sc_mprotect_fail_pop

    mov r12, r10
    sub r12, r8                          ; slot-relative page offset
    mov eax, r15d
    cmp r12, [l3_wx_code_start + rax*8]
    jb .sc_mprotect_fail_pop
    cmp r12, [l3_wx_code_end + rax*8]
    jae .sc_mprotect_fail_pop

    mov eax, r15d
    cmp eax, MAX_WINDOWS
    jae .sc_mprotect_fail_pop
    imul rax, ARENA_SLOT_PAGES * 8
    mov rcx, r12
    shr rcx, 12
    lea r13, [APP_ARENA_PT_BASE + rax + rcx * 8]

    mov rax, [r13]
    test al, 1
    jz .sc_mprotect_fail_pop

    ; All validation passed - open the monitor window for the two PTE writes
    ; below. No bail path exists between here and nk_pt_window_end, so the
    ; window can never leak open.
    call nk_pt_window_begin

    ; Neutral step: W=0, NX=1, then flush before granting the final mode.
    and rax, -3
    mov rdx, PAGE_NX
    or rax, rdx
    mov [r13], rax
    invlpg [r10]

    cmp r11, MPROT_WX_MODE_WNX
    je .sc_mprotect_final_wnx
    ; X+!W: W is already clear; clear NX.
    mov rdx, PAGE_NX
    not rdx
    and rax, rdx
    jmp .sc_mprotect_store_final
.sc_mprotect_final_wnx:
    ; W+NX: set W; NX is already set.
    or rax, 2
.sc_mprotect_store_final:
    mov [r13], rax
    invlpg [r10]

    call nk_pt_window_end           ; restore WP + flush
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdx
    pop rcx
    pop rbx
    mov qword [rsp + ALL_RAX], 0
    jmp .done
.sc_mprotect_fail_pop:
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdx
    pop rcx
    pop rbx
.sc_mprotect_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_wx_jit_alias:
    ; rdi = x_va, rsi = w_alias_va, rdx = length (bytes, page-multiple).
    test rdx, rdx
    jz .sc_jit_alias_reject
    test rdx, 0xFFF
    jnz .sc_jit_alias_reject
    test rdi, 0xFFF
    jnz .sc_jit_alias_reject
    test rsi, 0xFFF
    jnz .sc_jit_alias_reject

    push rbx
    push rcx
    push r10
    push r11
    push r12
    push r13
    push r14

    mov r10, rdi                         ; x_va
    mov r11, rsi                         ; w_alias_va
    mov r12, rdx                         ; length

    ; Slot must be live and have a v1 manifest installed.
    mov rax, L3_SLOT_MAGIC
    mov ecx, r15d
    cmp [l3_slot_live + rcx*8], rax
    jne .sc_jit_alias_fail_pop
    mov eax, r15d
    cmp qword [l3_wx_manifest_ver + rax*8], 1
    jne .sc_jit_alias_fail_pop

    call sc_get_slot_bounds              ; r8 = slot base, r9 = slot end

    ; Both ranges must lie entirely inside the slot.
    mov rdi, r10
    mov rsi, r12
    call sc_range_in_bounds
    test eax, eax
    jz .sc_jit_alias_fail_pop
    mov rdi, r11
    mov rsi, r12
    call sc_range_in_bounds
    test eax, eax
    jz .sc_jit_alias_fail_pop

    ; Slot-relative offsets for both ranges.
    mov rax, r10
    sub rax, r8                          ; x_off  (start)
    mov rbx, r11
    sub rbx, r8                          ; w_off  (start)
    mov rcx, rax
    add rcx, r12                         ; x_off_end
    mov rdx, rbx
    add rdx, r12                         ; w_off_end

    ; X range must lie fully inside the installed code range.
    mov r13d, r15d
    cmp rax, [l3_wx_code_start + r13*8]
    jb .sc_jit_alias_fail_pop
    cmp rcx, [l3_wx_code_end + r13*8]
    ja .sc_jit_alias_fail_pop

    ; W alias must NOT overlap the code range. If alias was inside the code
    ; range, l3_apply_wx_policy would strip its W bit on the next activation.
    mov r14, [l3_wx_code_start + r13*8]  ; cs
    mov r13, [l3_wx_code_end   + r13*8]  ; ce  (clobbers r13d - slot reloaded below if needed)
    ; Overlap iff (w_off < ce) && (w_off_end > cs).
    cmp rbx, r13
    jae .sc_jit_alias_no_overlap
    cmp rdx, r14
    ja .sc_jit_alias_fail_pop
.sc_jit_alias_no_overlap:

    ; Walk the X range; for each page copy the physical frame into the
    ; corresponding W-alias PTE with PRESENT|USER|W|NX, preserving the X
    ; mapping unchanged.
    mov eax, r15d
    imul rax, ARENA_SLOT_PAGES * 8       ; rax = per-slot PT byte offset
    mov r13, rax
    add r13, APP_ARENA_PT_BASE           ; r13 = &PT[slot][0]

    mov rax, r10
    sub rax, r8
    shr rax, 12                          ; rax = x first page index
    lea rax, [r13 + rax * 8]             ; rax = &x_pte[0]

    mov rcx, r11
    sub rcx, r8
    shr rcx, 12                          ; rcx = w first page index
    lea rcx, [r13 + rcx * 8]             ; rcx = &w_pte[0]

    mov r14, r12
    shr r14, 12                          ; r14 = page count

    call nk_pt_window_begin             ; WP-off window for the alias PTE writes
.sc_jit_alias_loop:
    mov rdx, [rax]                       ; x PTE
    test dl, 1                           ; PRESENT?
    jz .sc_jit_alias_fail_inwin
    mov rsi, [rcx]                       ; existing w PTE - must be present
    test sil, 1
    jz .sc_jit_alias_fail_inwin

    ; Build the alias PTE: x's physical frame + flags PRESENT|RW|USER|NX,
    ; preserving the rest of x's low flags is unnecessary - we want a fresh
    ; W+NX user mapping of the same frame.
    mov rbx, rdx
    mov rdi, 0x000FFFFFFFFFF000          ; 4KB-aligned phys-frame mask
    and rbx, rdi                         ; rbx = phys frame from x PTE
    or rbx, 0x07                         ; PRESENT | RW | USER
    mov rdi, PAGE_NX
    or rbx, rdi                          ; + NX
    mov [rcx], rbx
    invlpg [r11]

    add rax, 8
    add rcx, 8
    add r11, 0x1000
    dec r14
    jnz .sc_jit_alias_loop

    call nk_pt_window_end               ; restore WP + flush
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop rcx
    pop rbx
    mov qword [rsp + ALL_RAX], 0
    jmp .done
.sc_jit_alias_fail_inwin:
    ; A per-page validation check failed mid-loop while the window was open -
    ; close it (restore WP) before taking the shared failure path.
    call nk_pt_window_end
.sc_jit_alias_fail_pop:
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop rcx
    pop rbx
.sc_jit_alias_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_net_ping4:
    ; Reject re-entrant calls - the kernel rtl8156 ping path is not safe
    ; to call concurrently. App that double-clicks while a previous ping is
    ; in flight gets -2 back, not a fresh syscall that races shared state.
    cmp byte [sc_net_ping_busy], 0
    jne .sc_net_ping4_busy
    mov byte [sc_net_ping_busy], 1
    mov rax, rdi
    shr rax, 32
    jnz .sc_net_ping4_reject
    mov edi, edi
    ; SYSCALL masks IF on entry. Blocking network paths use tick_count for
    ; RX/timeout waits, so let the timer run while the NIC dispatcher waits.
    sti
    call net_ping_ipv4
    push rax
    cli
    pop rax
    mov [rsp + ALL_RAX], rax
    mov byte [sc_net_ping_busy], 0
    extern usb_hid_requeue_slot1_reads
    call usb_hid_requeue_slot1_reads
    jmp .done
.sc_net_ping4_reject:
    mov byte [sc_net_ping_busy], 0
    mov qword [rsp + ALL_RAX], -1
    jmp .done
.sc_net_ping4_busy:
    mov qword [rsp + ALL_RAX], -2
    jmp .done

.sc_net_info:
    ; rdi = selector. Returns scalar in rax (zero for unknown selectors).
    xor eax, eax
    cmp rdi, 0
    je .ni_active
    cmp rdi, 1
    je .ni_bound
    cmp rdi, 2
    je .ni_ip
    cmp rdi, 3
    je .ni_router
    cmp rdi, 4
    je .ni_server
    cmp rdi, 5
    je .ni_guest
    cmp rdi, 6
    je .ni_nexthop
    cmp rdi, 7
    je .ni_dhcp_state
    cmp rdi, 8
    je .ni_last_ttl
    cmp rdi, 9
    je .ni_dns
    jmp .ni_store
.ni_active:
.ni_bound:
.ni_ip:
.ni_router:
.ni_server:
.ni_guest:
.ni_nexthop:
.ni_last_ttl:
.ni_dns:
    call net_info
.ni_store:
    mov [rsp + ALL_RAX], rax
    jmp .done
.ni_dhcp_state:
    ; Same self-redraw contract as net_ping4_tick: while an async DHCP
    ; transaction is in flight (state DISCOVER=1 or REQUEST=2), keep the scene
    ; marked dirty so the WM keeps redrawing and the app re-polls NI_DHCP_STATE
    ; each frame until it resolves to BOUND/FAILED. Without this the app would
    ; read state once, the scene would go clean, and the status would freeze on
    ; "discover..." even though the kernel pump advances the lease.
    call net_info
    mov [rsp + ALL_RAX], rax
    cmp rax, 1
    je .ni_dhcp_inflight
    cmp rax, 2
    je .ni_dhcp_inflight
    jmp .done
.ni_dhcp_inflight:
    mov byte [scene_dirty], 1
    jmp .done

.sc_net_dhcp_renew:
    ; Force a fresh DHCP transaction WITHOUT blocking. Previously this called the
    ; synchronous net_dhcp_configure inside the syscall (busy-waiting on rx for up
    ; to ~1.2s) which froze the whole UI - render/mouse/dhcp-pump couldn't run
    ; until it returned. Now it routes through the async net_dhcp_start kick (which
    ; clears any existing lease, forces a fresh DISCOVER, and arms the deadline for
    ; the main-loop rtl8156_dhcp_pump) and returns the CURRENT dhcp_state
    ; immediately. The app polls NI_DHCP_STATE each frame until it resolves.
    ; net_dhcp_start is non-blocking on rtl8156; the rtl8139 fallback still does a
    ; bounded synchronous configure, so keep an interrupt window around the call.
    sti
    call net_dhcp_start
    push rax
    cli
    pop rax
    test eax, eax
    jz .dhcp_no_nic
    mov rdi, 7                         ; NI_DHCP_STATE
    call net_info
    mov [rsp + ALL_RAX], rax
    jmp .done
.dhcp_no_nic:
    mov byte [rtl8156_dhcp_state], 4   ; FAILED - no NIC
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_net_dhcp_start:
    ; Kick off async DHCP. Returns 0 immediately. Caller polls NI_DHCP_STATE for
    ; progress. Backend selection + the (now non-blocking, fresh-DISCOVER-forcing)
    ; kick live in the GHLK module net_dhcp_dispatch.ghl. net_dhcp_start never
    ; blocks on the rtl8156 path; the rtl8139 fallback does a bounded synchronous
    ; configure, so keep timer interrupts live around the call.
    sti
    call net_dhcp_start
    push rax
    cli
    pop rax
    test eax, eax
    jz .dhcp_start_no_nic
    mov qword [rsp + ALL_RAX], 0
    jmp .done
.dhcp_start_no_nic:
    mov byte [rtl8156_dhcp_state], 4   ; FAILED
    mov qword [rsp + ALL_RAX], 0
    jmp .done

.sc_net_tcp_connect4:
    ; rdi = IPv4 A.B.C.D, rsi = destination port, rdx = source port.
    ; This currently performs the TCP open SYN path: resolve next-hop MAC via
    ; generic ARP, then queue one TCP SYN through generic IPv4/NIC dispatch.
    cmp byte [sc_net_tcp_busy], 0
    jne .sc_net_tcp_busy
    mov byte [sc_net_tcp_busy], 1
    mov rax, rdi
    shr rax, 32
    jnz .sc_net_tcp_reject
    mov rax, rsi
    shr rax, 16
    jnz .sc_net_tcp_reject
    mov rax, rdx
    shr rax, 16
    jnz .sc_net_tcp_reject
    mov edi, [rsp + ALL_RDI]
    mov si, [rsp + ALL_RSI]
    mov dx, [rsp + ALL_RDX]
    sti
    call net_tcp_connect_ipv4
    push rax
    cli
    pop rax
    mov [rsp + ALL_RAX], rax
    mov byte [sc_net_tcp_busy], 0
    jmp .done
.sc_net_tcp_reject:
    mov byte [sc_net_tcp_busy], 0
    mov qword [rsp + ALL_RAX], -1
    jmp .done
.sc_net_tcp_busy:
    mov qword [rsp + ALL_RAX], -2
    jmp .done

.sc_net_ping4_tick:
    ; Async ping. Returns RTT (us) on success, 0 if still pending, -1 on
    ; timeout/no-link, -2 if another ping is in flight. Caller polls per
    ; frame so the GUI never freezes during the wait.
    mov rax, rdi
    shr rax, 32
    jnz .sc_net_ping4_tick_bad
    mov edi, edi
    sti
    extern net_ping4_tick
    call net_ping4_tick
    push rax
    cli
    pop rax
    mov [rsp + ALL_RAX], rax
    ; Always keep the scene dirty after a tick. While in flight (0 = pending,
    ; -2 = busy) this re-pumps the FSM next frame. On the COMPLETION tick (the
    ; in-line busy-poll now resolves an RTT within a single call) it forces one
    ; more redraw so the final result paints immediately - without it the app
    ; kept showing "Pinging..." until the user clicked to trigger a redraw,
    ; especially on the DNS path where resolution + ping finish in one frame.
    mov byte [scene_dirty], 1
    jmp .done
.sc_net_ping4_tick_bad:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_net_dns_a:
    ; rdi = app-owned hostname C-string. ASYNC: advances the DNS state machine
    ; one step and returns immediately (no more kernel-halting busy-wait).
    ; Returns >0 resolved IPv4 A.B.C.D, 0 pending (poll again next frame), -1
    ; fail/invalid, -2 a different hostname's lookup is already in flight. While
    ; pending (0) or contended (-2) we keep the scene dirty so the app's draw()
    ; re-polls each frame and the FSM advances - mirroring net_ping4_tick.
    ; rsi = max scan length for the C-string validator. The dispatcher only
    ; 1-byte-probes a no-sibling-descriptor PTR arg and restores the user's
    ; (garbage) rsi, so the handler MUST set it here - same as .sc_print et al.
    ; Without this, sc_validate_user_cstring reads a random max_len and DNS
    ; rejects (-1) before net_dns_tick ever runs. THIS was the DNS-fail bug.
    mov rsi, SYSCALL_MAX_STR_LEN
    call sc_validate_user_cstring
    test eax, eax
    jz .sc_net_dns_reject
    mov rdi, [rsp + ALL_RDI]
    sti
    call net_dns_tick
    push rax
    cli
    pop rax
    mov [rsp + ALL_RAX], rax
    cmp rax, 0
    je .sc_net_dns_mark
    cmp rax, -2
    jne .done
.sc_net_dns_mark:
    mov byte [scene_dirty], 1
    jmp .done
.sc_net_dns_reject:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

; ============================================================================
; Installable-driver syscall wrappers.
;
; r15 is derived from the caller RIP by syscall entry and is authoritative.
; No wrapper accepts a driver_id or policy mask from ring 3. Grant creation,
; DMA mapping, and IRQ routing remain device-manager control-plane operations.
; ============================================================================
.sc_drvhost_denied:
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_drvhost_register:
    mov rsi, rdi
    movzx edi, r15b
    call drvhost_register_slot
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_mmio_read32:
    push rdi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_mmio_read32
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_mmio_write32:
    push rdi
    push rsi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rdx
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_mmio_write32
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_pio_read8:
    push rdi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_pio_read8
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_pio_write8:
    push rdi
    push rsi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rdx
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_pio_write8
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_pci_cfg_read32:
    push rdi
    push rsi
    push rdx
    push r10
    movzx edi, r15b
    call drvhost_id_for_slot
    test eax, eax
    jz .sc_drvhost_pci_cfg_denied
    mov rdi, rax
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 8]
    mov r8,  [rsp + 0]
    call drvhost_pci_cfg_read32
    add rsp, 32
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_drvhost_pci_cfg_denied:
    add rsp, 32
    mov qword [rsp + ALL_RAX], -1
    jmp .done

.sc_drvhost_ring_establish:
    push rdi
    movzx edi, r15b
    call drvhost_id_for_slot
    pop rsi
    test eax, eax
    jz .sc_drvhost_denied
    mov rdi, rax
    call drvhost_ring_establish
    mov [rsp + ALL_RAX], rax
    jmp .done

.sc_drvhost_ring_submit:
    ; Dispatcher validates the complete count*16 writable descriptor span.
    push rdi
    push rsi
    movzx edi, r15b
    call drvhost_id_for_slot
    test eax, eax
    jz .sc_drvhost_ring_denied
    mov rdi, rax
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 0]
    USER_ACCESS_BEGIN
    call drvhost_ring_submit
    USER_ACCESS_END
    add rsp, 16
    mov [rsp + ALL_RAX], rax
    jmp .done
.sc_drvhost_ring_denied:
    add rsp, 16
    mov qword [rsp + ALL_RAX], -1
    jmp .done

