; rtl8156_dhcp_configure / rtl8156_dhcp_start / rtl8156_dhcp_pump moved to
; zero-asm GritHLK: src/kernel/grithlk/rtl8156_dhcp_sm.ghl (state machine +
; xchg spinlock + anti-reentrancy guard). %included via kernel_build.asm
; before this file. Globals (dhcp_start/dhcp_pump/dhcp_configure) now live there.

global rtl8156_init
rtl8156_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12

%ifdef RELEASE_BUILD
    ; Timed release boot only needs to avoid losing the NIC forever. The full
    ; USB port walk/vendor bring-up runs from rtl8156_deferred_init_pump after
    ; the desktop is up, so the R8 marker is not held hostage by link/NIC work.
    cmp byte [rtl8156_init_allow_blocking], 1
    je .release_full_init
    cmp byte [rtl8156_active], 1
    je .release_return_active
    cmp byte [rtl8156_deferred_init_done], 1
    je .release_return_failed
    mov byte [rtl8156_deferred_init_pending], 1
    xor eax, eax
    jmp .done
.release_return_active:
    mov eax, 1
    jmp .done
.release_return_failed:
    xor eax, eax
    jmp .done
.release_full_init:
%endif

    xor r12d, r12d
    mov rsi, sz_r8156_init
    call debug_print
    call rtl8156_ser_init

    mov byte [rtl8156_active], 0
    mov dword [rtl8156_probe_port_tries], 0
    mov byte [rtl8156_dbg_stage], 1
    mov word [rtl8156_last_vid], 0
    mov word [rtl8156_last_pid], 0
    mov dword [rtl8156_last_portsc], 0
    ; xhci_init wipes the entire XHCI memory region and resets the
    ; controller - that would destroy live HID slot contexts. Only call it
    ; if the controller hasn't been brought up yet.
    cmp byte [xhci_active], 1
    je .xhci_ready
    call xhci_init
    test eax, eax
    jz .fail
    mov r12b, 1
.xhci_ready:
    ; Switch xhci_address_device + queue_ctrl_trb to the rtl8156 device
    ; context so we don't stomp the HID slot1/slot2 contexts.
    mov byte [xhci_nic_mode], 1
    ; Even if HID already initialized xHCI, native root ports can still be
    ; unpowered or mid-debounce. Power/debounce every port without resetting
    ; addressed devices; the later ownership guard protects live HID slots.
    call rtl8156_power_all_ports
    ; Power on every port + initial reset of any device that's there. We
    ; need xhci_find_port for its power-on side effects only when this driver
    ; was the one that initialized xHCI. If HID already owns live slots, that
    ; reset would knock the mouse/keyboard port back to default state before
    ; the ownership guard below can skip it.
    test r12b, r12b
    jz .skip_find_port_side_effects
    call xhci_find_port
 .skip_find_port_side_effects:
    ; Walk EVERY port ourselves so a single bad port (e.g. already-addressed
    ; HID slot) doesn't terminate the search.
    ; Begin manual walk at port 1.
    mov byte [rtl8156_walk_port], 0
.walk_advance:
    inc byte [rtl8156_walk_port]
    movzx eax, byte [rtl8156_walk_port]
    movzx ecx, byte [xhci_max_ports]
    cmp eax, ecx
    ja .walk_exhausted
    ; (Previously skipped slot1/slot2_port here, but usb_hid_init records
    ; ports for every device it probed - including the NIC. We instead
    ; gate by VID/PID after the device descriptor read.)
    ; Read PORTSC; skip if no device connected (CCS=0) or if port is
    ; already enabled (PED=1 means another driver addressed it).
    mov rsi, [xhci_op_base]
    add rsi, 0x400
    movzx edx, byte [rtl8156_walk_port]
    dec edx                              ; 0-based for PORTSC indexing
    mov eax, edx
    shl eax, 4
    mov ebx, [rsi + rax + XHCI_PORTSC]
    mov [rtl8156_last_portsc], ebx
    mov byte [rtl8156_dbg_stage], 0x20
    test ebx, XHCI_PORTSC_CCS
    jz .walk_advance
    ; Skip ports already owned by an active HID slot. Port reset would knock
    ; the mouse/keyboard back to default state and break it until reboot -
    ; that's the "mouse stopped working after ethernet works" regression.
    ; Slot1/slot2_port get recorded for every probed port (incl. the NIC), but
    ; usb_hid_port_owned additionally requires usb_mouse_active / slot2_active,
    ; so it only returns 1 for ports we actually run HID polling against.
    push rax
    push rbx
    movzx edi, byte [rtl8156_walk_port]
    call usb_hid_port_owned
    test eax, eax
    pop rbx
    pop rax
    jnz .walk_advance
    ; Diag: 'W' + port number
    push rax
    mov al, 'W'
    call rtl8156_diag_char
    movzx eax, byte [rtl8156_walk_port]
    call rtl8156_ser_phex8
    pop rax
    ; Issue port reset.
    and ebx, ~XHCI_PORTSC_CHANGE_BITS
    and ebx, ~XHCI_PORTSC_PED
    or  ebx, XHCI_PORTSC_PR
    mov [rsi + rax + XHCI_PORTSC], ebx
    ; Wait up to 50 ticks for PRC.
    push rax
    mov rbx, [tick_count]
    add rbx, 50
.walk_rst_wait:
    mov ecx, [rsi + rax + XHCI_PORTSC]
    test ecx, XHCI_PORTSC_PRC
    jnz .walk_rst_done
    mov rdx, [tick_count]
    cmp rdx, rbx
    jl .walk_rst_wait
.walk_rst_done:
    ; Clear PRC, leave PED alone (PED is RW1C - writing 1 disables).
    and ecx, ~XHCI_PORTSC_CHANGE_BITS
    and ecx, ~XHCI_PORTSC_PED
    or  ecx, XHCI_PORTSC_PRC
    mov [rsi + rax + XHCI_PORTSC], ecx
    pop rax
    ; Set 1-based xhci_port_num for downstream code, then enter try_port.
    mov al, [rtl8156_walk_port]
    mov [xhci_port_num], al
    jmp .try_port
.walk_exhausted:
    mov al, 'X'
    call rtl8156_diag_char
    jmp .fail
.try_port:
    mov al, 'P'                  ; entered try_port for some port
    call rtl8156_diag_char
    movzx eax, byte [xhci_port_num]
    call rtl8156_ser_phex8
    ; Don't gate on usb_hid_port_owned here - if the device on this port
    ; turns out to be a Realtek NIC, we want to address it on a fresh slot
    ; regardless of who else claimed the port. The VID/PID check below
    ; (line ~360) is the real filter: non-Realtek devices skip via
    ; .next_port without disturbing the existing slot.
.not_owned:
    call xhci_flush_events
    call xhci_enable_slot
    test eax, eax
    jnz .slotted
    mov al, 'e'
    call rtl8156_diag_char
    jmp .next_port
.slotted:
    ; Save slot id NOW so rtl8156_wait_completion's slot-id filter accepts
    ; our own control-transfer completions during init. Without this, the
    ; saved slot id is 0 and every event gets rejected → get_desc fails.
    mov al, [xhci_slot_id]
    mov [rtl8156_slot_id], al
    ; Diag: 's' + slot_id (so we can confirm enable_slot returned a fresh slot)
    push rax
    mov al, 's'
    call rtl8156_diag_char
    mov al, [xhci_slot_id]
    call rtl8156_ser_phex8
    ; Set xhci_port_speed from PORTSC bits 13:10 for the current walk port.
    ; Without this, port_speed is stale from xhci_find_port and EP0 MaxPacketSize
    ; / Slot Context Speed end up mismatched with the actual link, which causes
    ; the controller to reject Address Device with Parameter Error.
    mov rsi, [xhci_op_base]
    add rsi, 0x400
    movzx edx, byte [xhci_port_num]
    dec edx
    shl edx, 4
    mov eax, [rsi + rdx + XHCI_PORTSC]
    shr eax, 10
    and eax, 0x0F
    mov [xhci_port_speed], al
    mov al, 'S'
    call rtl8156_diag_char
    mov al, [xhci_port_speed]
    call rtl8156_ser_phex8
    pop rax
    call xhci_address_device
    test eax, eax
    jnz .addressed
    mov byte [rtl8156_dbg_stage], 0xA0
    mov al, 'a'
    call rtl8156_diag_char
    ; Print full completion codes: cc1 (BSR=1) cc2 (BSR=0) stage slotstate
    push rax
    mov al, [xhci_dbg_adcc1]
    call rtl8156_ser_phex8
    mov al, '/'
    call rtl8156_diag_char
    mov al, [xhci_dbg_adcc2]
    call rtl8156_ser_phex8
    mov al, '/'
    call rtl8156_diag_char
    mov al, [xhci_dbg_adstage]
    call rtl8156_ser_phex8
    mov al, '/'
    call rtl8156_diag_char
    mov al, [xhci_dbg_slotstate]
    call rtl8156_ser_phex8
    pop rax
    jmp .next_port_disable_current
.addressed:
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 18
    mov r8d, 0x01000680
    mov r9d, 0x00120000
    call rtl8156_control_in
    test eax, eax
    jnz .got_desc
    mov byte [rtl8156_dbg_stage], 0xA1
    mov al, 'd'
    call rtl8156_diag_char
    jmp .next_port_disable_current
.got_desc:
    mov byte [rtl8156_dbg_stage], 0x40
    mov al, 'V'
    call rtl8156_diag_char
    mov ax, [abs XHCI_CTRL_BUF_ADDR + 8]
    mov [rtl8156_last_vid], ax
    mov ax, [abs XHCI_CTRL_BUF_ADDR + 10]
    mov [rtl8156_last_pid], ax
    call rtl8156_ser_phex8
    mov al, [abs XHCI_CTRL_BUF_ADDR + 9]
    call rtl8156_ser_phex8
    cmp word [abs XHCI_CTRL_BUF_ADDR + 8], RTL8156_VENDOR_REALTEK
    jne .next_port_disable_current
    mov ax, [abs XHCI_CTRL_BUF_ADDR + 10]
    cmp ax, 0x8156
    je .realtek_nic
    cmp ax, 0x8155
    je .realtek_nic
    cmp ax, 0x8153
    je .realtek_nic
    cmp ax, 0x8152
    jne .next_port_disable_current
.realtek_nic:
    mov [rtl8156_product], ax

    ; Full configuration descriptor.
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov rcx, 9
    mov r8d, 0x02000680
    mov r9d, 0x00090000
    call rtl8156_control_in
    test eax, eax
    jnz .cfg_header_ok
    mov byte [rtl8156_dbg_stage], 0xA2
    jmp .next_port_disable_current
.cfg_header_ok:
    movzx ecx, word [abs XHCI_CTRL_BUF_ADDR + 2]
    cmp ecx, 512
    jbe .cfg_len_ok
    mov byte [rtl8156_dbg_stage], 0xA3
    jmp .next_port_disable_current
.cfg_len_ok:
    mov rdi, XHCI_CTRL_BUF_ADDR
    mov r8d, 0x02000680
    mov r9d, ecx
    shl r9d, 16
    call rtl8156_control_in
    test eax, eax
    jnz .cfg_full_ok
    mov byte [rtl8156_dbg_stage], 0xA3
    jmp .next_port_disable_current
.cfg_full_ok:
    call rtl8156_find_bulk_eps
    test eax, eax
    jnz .eps_ok
    mov byte [rtl8156_dbg_stage], 0xA4
    jmp .next_port_disable_current
.eps_ok:
    mov byte [rtl8156_dbg_stage], 0x50

    ; Diagnostic: dump what we parsed from the config descriptor so we can
    ; tell at a glance whether IN/OUT endpoint numbers + MPS look sane.
    push rax
    push rdx
    push rsi
    lea rsi, [rel ser_ep_tag]
    call rtl8156_ser_puts
    mov al, [rtl8156_bulk_in_addr]
    call rtl8156_ser_phex8
    mov dx, 0x3F8
    mov al, '/'
    out dx, al
    mov al, [rtl8156_bulk_out_addr]
    call rtl8156_ser_phex8
    mov al, ' '
    out dx, al
    mov al, [rtl8156_bulk_in_mps + 1]
    call rtl8156_ser_phex8
    mov al, [rtl8156_bulk_in_mps + 0]
    call rtl8156_ser_phex8
    mov al, '/'
    out dx, al
    mov al, [rtl8156_bulk_out_mps + 1]
    call rtl8156_ser_phex8
    mov al, [rtl8156_bulk_out_mps + 0]
    call rtl8156_ser_phex8
    mov al, ' '
    out dx, al
    mov al, 'b'
    out dx, al
    mov al, [rtl8156_bulk_in_burst]
    call rtl8156_ser_phex8
    mov al, '/'
    out dx, al
    mov al, [rtl8156_bulk_out_burst]
    call rtl8156_ser_phex8
    mov al, 10
    out dx, al
    pop rsi
    pop rdx
    pop rax

    ; Set configuration 1.
    mov r8d, 0x00010900
    mov r9d, 0
    call rtl8156_control_nodata
    test eax, eax
    jnz .set_config_ok
    mov byte [rtl8156_dbg_stage], 0xA5
    jmp .next_port_disable_current
.set_config_ok:

    call rtl8156_configure_bulk_eps
    test eax, eax
    jnz .bulk_ctx_ok
    mov byte [rtl8156_dbg_stage], 0xA6
    jmp .next_port_disable_current
.bulk_ctx_ok:
    mov byte [rtl8156_dbg_stage], 0x60

    call xhci_flush_events
    call rtl8156_vendor_init
    test eax, eax
    jnz .vendor_ok
    mov byte [rtl8156_dbg_stage], 0xA7
    jmp .next_port_disable_current
.vendor_ok:
    mov byte [rtl8156_dbg_stage], 0x70

    call rtl8156_wait_link
    ; do not abort if link does not come up in time - driver still usable
    ; once cable is plugged in later; subsequent ping/DHCP will retry.

    mov byte [rtl8156_active], 1
    mov byte [rtl8156_dbg_stage], 0x80
    ; Remember which xHCI slot the NIC ended up on. xhci_slot_id is a shared
    ; global that subsequent enable_slot calls (e.g. HID slot2) overwrite, so
    ; we can't read it later - snapshot it now while it's still ours.
    mov al, [xhci_slot_id]
    mov [rtl8156_slot_id], al
    ; Make sure a bulk-IN TRB is always armed so the main-loop USB poller
    ; (usb_poll_mouse) has something to consume when a frame arrives.
    call rtl8156_arm_rx
    ; Snapshot the xHCI port too so other drivers (usb_hid re-init) know not
    ; to re-grab it - without this the next usb_hid_init scan picks the NIC's
    ; port and tries to re-address it, which fails since it's already linked.
    mov al, [xhci_port_num]
    mov [rtl8156_port], al
    mov rsi, sz_r8156_ready
    call debug_print
    call rtl8156_ser_ready
    mov byte [xhci_nic_mode], 0
    mov eax, 1
    jmp .done

.next_port_disable_current:
    mov al, [xhci_slot_id]
    test al, al
    jz .next_port
    call xhci_disable_slot
    mov byte [rtl8156_slot_id], 0

.next_port:
    call xhci_flush_events
    push rax
    mov al, 'N'                  ; diag: entered .next_port
    call rtl8156_diag_char
    pop rax
    inc dword [rtl8156_probe_port_tries]
    cmp dword [rtl8156_probe_port_tries], 16
    jae .fail
    jmp .walk_advance
.fail:
    cmp byte [rtl8156_dbg_stage], 0x80
    jae .fail_keep_stage
    mov byte [rtl8156_dbg_stage], 0xF0
.fail_keep_stage:
    mov rsi, sz_r8156_fail
    call debug_print
    call rtl8156_ser_fail
    mov byte [rtl8156_probed], 1
    mov byte [xhci_nic_mode], 0
    xor eax, eax
.done:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

global rtl8156_deferred_init_pump
rtl8156_deferred_init_pump:
%ifdef RELEASE_BUILD
    push rbx
    cmp byte [rtl8156_active], 1
    je .done
    cmp byte [rtl8156_deferred_init_pending], 1
    jne .done
    cmp byte [rtl8156_deferred_init_done], 1
    je .done
    cmp byte [rtl8156_deferred_init_running], 1
    je .done
    mov byte [rtl8156_deferred_init_running], 1
    mov byte [rtl8156_init_allow_blocking], 1
    call rtl8156_init
    mov byte [rtl8156_init_allow_blocking], 0
    mov byte [rtl8156_deferred_init_pending], 0
    mov byte [rtl8156_deferred_init_done], 1
    mov byte [rtl8156_deferred_init_running], 0
.done:
    pop rbx
%endif
    ret

; Power every xHCI root port and wait for debounce without resetting or
; addressing anything. This makes the NIC scan robust when HID initialized xHCI
; first and xhci_find_port's power-on side effects were skipped.
rtl8156_power_all_ports:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    cmp byte [xhci_active], 1
    jne .done
    mov rsi, [xhci_op_base]
    test rsi, rsi
    jz .done
    add rsi, 0x400
    movzx ecx, byte [xhci_max_ports]
    xor edx, edx
.loop:
    cmp edx, ecx
    jae .wait
    mov eax, edx
    shl eax, 4
    mov ebx, [rsi + rax + XHCI_PORTSC]
    test ebx, XHCI_PORTSC_PP
    jnz .next
    and ebx, ~XHCI_PORTSC_CHANGE_BITS
    and ebx, ~XHCI_PORTSC_PED
    or  ebx, XHCI_PORTSC_PP
    mov [rsi + rax + XHCI_PORTSC], ebx
.next:
    inc edx
    jmp .loop
.wait:
    mov rbx, [tick_count]
    add rbx, 20
.wait_loop:
    mov rax, [tick_count]
    cmp rax, rbx
    jae .done
    pause
    jmp .wait_loop
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
