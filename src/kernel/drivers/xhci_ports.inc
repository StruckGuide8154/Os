xhci_find_port:
    push rsi
    push rcx
    push rdx
    push rbx

    mov rsi, [xhci_op_base]
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400                ; Port register base

    movzx ecx, byte [xhci_max_ports]
    xor edx, edx                  ; Port index 0-based

    ; Serial: 'P' + max_ports hex byte
    push rax
    push rdx
    mov al, 'P'
    mov dx, 0x3F8
    out dx, al
    movzx eax, byte [xhci_max_ports]
    call serial_hex32
    pop rdx
    pop rax

    ; --- Power on EVERY root port first. After HCRST the ports come up
    ;     unpowered (PP=0); while PP=0 the CCS bit reads 0, so a scan would
    ;     see an empty controller even with a device attached. Set PP on all
    ;     ports, then wait for power-good + connect debounce before scanning.
    xor edx, edx
.pp_loop:
    cmp edx, ecx
    jge .pp_done
    mov eax, edx
    shl eax, 4
    mov ebx, [rsi + rax]
    test ebx, XHCI_PORTSC_PP
    jnz .pp_next
    and ebx, ~XHCI_PORTSC_CHANGE_BITS
    or  ebx, XHCI_PORTSC_PP
    mov [rsi + rax], ebx
.pp_next:
    inc edx
    jmp .pp_loop
.pp_done:
    ; Power-good ramp + root-hub connect debounce. Keep the conservative debug
    ; wait for hardware diagnosis; release depends on the later per-port reset
    ; and PED waits to avoid spending the whole UH budget here.
    mov rbx, [tick_count]
%ifdef RELEASE_BUILD
    add rbx, 1
%else
    add rbx, 20
%endif
.pp_wait:
    mov rax, [tick_count]
    cmp rax, rbx
    jge .pp_settled
    pause
    jmp .pp_wait
.pp_settled:
    call xhci_dbg_fp_snapshot     ; DEBUG: record what the scan will see
    xor edx, edx                  ; restart index for the CCS scan

.port_loop:
    cmp edx, ecx
    jge .no_port

    ; Read PORTSC for this port
    mov eax, edx
    shl eax, 4                    ; * 16 bytes per port
    mov ebx, [rsi + rax + XHCI_PORTSC]

    ; Serial: print PORTSC for each port
    push rax
    push rdx
    mov eax, ebx
    mov dx, 0x3F8
    call serial_hex32
    pop rdx
    pop rax

    ; Check CCS (Current Connect Status)
    test ebx, XHCI_PORTSC_CCS
    jz .fp_next

    ; Skip ports already owned by an active HID slot - resetting them here
    ; would detach the mouse/keyboard from its addressed slot.
    push rcx
    push rdx
    push rsi
    push rdi
    lea edi, [edx + 1]
    call usb_hid_port_owned
    mov r11d, eax
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    test r11d, r11d
    jnz .fp_next

    ; Also skip the rtl8156 NIC's port - re-addressing it would conflict
    ; with the active NIC slot. Without this, usb_hid_init re-running after
    ; rtl8156_selftest re-grabs port 1 (the NIC) and never reaches the mouse.
    extern rtl8156_active, rtl8156_port
    cmp byte [rtl8156_active], 1
    jne .not_nic_port
    movzx eax, byte [rtl8156_port]
    lea r11d, [edx + 1]
    cmp eax, r11d
    je .fp_next
.not_nic_port:

    jmp .found_port
.fp_next:
    inc edx
    jmp .port_loop

.found_port:
    ; Store 1-based port number
    lea eax, [edx + 1]
    mov [xhci_port_num], al

    ; Serial: 'F' + port number
    push rax
    push rdx
    mov al, 'F'
    mov dx, 0x3F8
    out dx, al
    movzx eax, byte [xhci_port_num]
    call serial_hex32
    pop rdx
    pop rax

    ; Re-read speed to check if it's USB 3.0+
    mov ecx, ebx
    shr ecx, XHCI_PORTSC_SPEED_SHIFT
    and ecx, 0x0F
    mov [xhci_port_speed], cl

    ; Power port if not powered
    test ebx, XHCI_PORTSC_PP
    jnz .port_powered
    ; Set PP, preserve CCS, clear change bits
    mov eax, ebx
    and eax, ~XHCI_PORTSC_CHANGE_BITS  ; Don't clear change bits
    or eax, XHCI_PORTSC_PP
    mov edx, [xhci_port_num]
    dec edx
    shl edx, 4
    mov [rsi + rdx + XHCI_PORTSC], eax
    ; Wait 30ms for port power (PIT-based, CPU-loops are calibrated for QEMU not real HW)
    push rax
    push rdx
    push rcx
    mov rdx, [tick_count]
    add rdx, 3                    ; 3 ticks = 30ms at 100Hz
.power_wait:
    mov rax, [tick_count]
    cmp rax, rdx
    jge .pwdone
    pause
    jmp .power_wait
.pwdone:
    pop rcx
    pop rdx
    pop rax
.port_powered:

    ; Reset port
    movzx edx, byte [xhci_port_num]
    dec edx
    shl rdx, 4
    mov eax, [rsi + rdx + XHCI_PORTSC]
    mov [xhci_dbg_portsc_pre], eax    ; DEBUG: PORTSC before reset
    movzx ecx, byte [xhci_port_speed]
    mov [xhci_dbg_speed_pre], cl       ; DEBUG: speed before reset
    mov byte [xhci_dbg_rststage], 40   ; DEBUG: about to issue reset
    and eax, ~XHCI_PORTSC_CHANGE_BITS  ; Preserve change bits
    and eax, ~XHCI_PORTSC_PED          ; Don't accidentally disable

    ; USB 3.0+ (Speed 4+) might need Warm Reset
    cmp ecx, 4
    jge .do_warm_reset

    ; Normal Reset
    or eax, XHCI_PORTSC_PR             ; Set Port Reset
    jmp .apply_reset
    
.do_warm_reset:
    ; SuperSpeed Warm Reset
    ; WPR is bit 31
    or eax, (1 << 31)                  ; XHCI_PORTSC_WPR
    
.apply_reset:
    mov [xhci_dbg_portsc_written], eax  ; DEBUG: exact value we are writing
    mov [rsi + rdx + XHCI_PORTSC], eax
    mov byte [xhci_dbg_rststage], 41   ; DEBUG: reset bit written

    ; DEBUG: read PORTSC back IMMEDIATELY to see if write took effect
    mov eax, [rsi + rdx + XHCI_PORTSC]
    mov [xhci_dbg_portsc_immed], eax

    ; Wait for reset complete: PRC or WRC. PIT-based deadline (60 ticks = 600ms)
    ; ensures real-hardware safety; CPU spin alone is too short on fast cores.
    push rbx
    mov rbx, [tick_count]
    add rbx, 60
    xor ecx, ecx                       ; poll iteration counter
.wait_reset:
    mov eax, [rsi + rdx + XHCI_PORTSC]
    inc ecx
    test eax, XHCI_PORTSC_PRC
    jnz .reset_done
    test eax, (1 << 19)                ; WRC bit
    jnz .reset_done
    mov rax, [tick_count]
    cmp rax, rbx
    jl .wait_reset_cont
    mov byte [xhci_dbg_rststage], 99   ; DEBUG: reset TIMED OUT
    jmp .reset_done
.wait_reset_cont:
    pause
    jmp .wait_reset
.reset_done:
    mov [xhci_dbg_reset_polls], ecx    ; DEBUG: how many polls before exit
    ; DEBUG: read PORTSC right after exit from wait loop
    mov eax, [rsi + rdx + XHCI_PORTSC]
    mov [xhci_dbg_portsc_wait], eax
    pop rbx
    cmp byte [xhci_dbg_rststage], 99
    je .skip_rst_ok
    mov byte [xhci_dbg_rststage], 42   ; DEBUG: PRC/WRC fired
.skip_rst_ok:

    ; Clear PRC and WRC by writing 1 to them.
    ; CRITICAL: PED (bit 1) is RW1C "write 1 to DISABLE". If we read PORTSC
    ; after a successful reset, PED is 1. If we write back with PED=1 set in
    ; the value, we DISABLE the port we just enabled. Mask out PED (and all
    ; other change bits we're not explicitly setting) to write a neutral
    ; value with only PRC|WRC set, leaving PED alone.
    ; (This is the xhci_port_state_to_neutral pattern from Linux.)
    mov eax, [rsi + rdx + XHCI_PORTSC]
    and eax, ~XHCI_PORTSC_CHANGE_BITS  ; don't accidentally clear other change bits
    and eax, ~XHCI_PORTSC_PED           ; PED RW1C: write 0 = no-op, write 1 = disable
    or eax, XHCI_PORTSC_PRC            ; Write 1 to clear PRC
    or eax, (1 << 19)                  ; Write 1 to clear WRC
    mov [rsi + rdx + XHCI_PORTSC], eax

    ; Re-read speed after reset (may change)
    mov eax, [rsi + rdx + XHCI_PORTSC]
    shr eax, XHCI_PORTSC_SPEED_SHIFT
    and eax, 0x0F
    mov [xhci_port_speed], al

    ; Wait 10ms after reset before enumeration (USB spec). PIT-based.
    push rbx
    mov rbx, [tick_count]
%ifdef RELEASE_BUILD
    add rbx, 1                         ; 1 tick = 10ms
%else
    add rbx, 2                         ; 2 ticks = 20ms (>= 10ms required)
%endif
.post_reset_wait:
    mov rax, [tick_count]
    cmp rax, rbx
    jge .post_reset_done
    pause
    jmp .post_reset_wait
.post_reset_done:
    pop rbx
.port_ready:
    ; Check PED (port enabled after reset) - give it extra time if needed
    mov eax, [rsi + rdx + XHCI_PORTSC]
    test eax, XHCI_PORTSC_PED
    jnz .ped_ok
    ; PED not set - try a bit longer. PIT-based deadline.
    push rbx
    mov rbx, [tick_count]
    add rbx, 50                        ; 50 ticks = 500ms
.wait_ped:
    mov eax, [rsi + rdx + XHCI_PORTSC]
    test eax, XHCI_PORTSC_PED
    jnz .ped_wait_done
    mov rax, [tick_count]
    cmp rax, rbx
    jge .ped_wait_done
    pause
    jmp .wait_ped
.ped_wait_done:
    pop rbx
    ; Read final speed
    mov eax, [rsi + rdx + XHCI_PORTSC]
    shr eax, XHCI_PORTSC_SPEED_SHIFT
    and eax, 0x0F
    mov [xhci_port_speed], al
.ped_ok:
    ; DEBUG: capture final PORTSC, speed, and PED/CCS flags
    mov eax, [rsi + rdx + XHCI_PORTSC]
    mov [xhci_dbg_portsc_post], eax
    mov ecx, eax
    and ecx, XHCI_PORTSC_PED
    setnz [xhci_dbg_ped_ok]
    mov ecx, eax
    and ecx, XHCI_PORTSC_CCS
    setnz [xhci_dbg_ccs_ok]
    movzx ecx, byte [xhci_port_speed]
    mov [xhci_dbg_speed_post], cl
    mov byte [xhci_dbg_rststage], 43   ; DEBUG: reset path complete

    mov eax, 1
    jmp .port_ret

.no_port:
    xor eax, eax
.port_ret:
    call xhci_dbg_fp_result       ; DEBUG: record 0/1 result
    pop rbx
    pop rdx
    pop rcx
    pop rsi
    ret

; ============================================================================
; xhci_find_port_next - Find next port with device, starting AFTER xhci_port_num
; Scans from (xhci_port_num) 0-based onward (skips current port)
; Returns: EAX = 1 found (xhci_port_num updated), 0 = none
; ============================================================================
global xhci_find_port_next
xhci_find_port_next:
    push rsi
    push rcx
    push rdx
    push rbx

    mov rsi, [xhci_op_base]
    XHCI_MMIO_ASSERT rsi, MMIO_XHCI_WINDOW
    add rsi, 0x400

    movzx ecx, byte [xhci_max_ports]
    ; Start from current port (0-based = xhci_port_num, already used)
    movzx edx, byte [xhci_port_num]  ; 1-based -> skip it, start at [xhci_port_num] 0-based
    ; edx is already the 0-based index of the next port to check

.next_loop:
    cmp edx, ecx
    jge .next_none

    mov eax, edx
    shl eax, 4
    mov ebx, [rsi + rax + XHCI_PORTSC]
    test ebx, XHCI_PORTSC_CCS
    jz .next_skip
    push rcx
    push rdx
    push rsi
    push rdi
    lea edi, [edx + 1]
    call usb_hid_port_owned
    mov r11d, eax
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    test r11d, r11d
    jnz .next_skip

    extern rtl8156_active, rtl8156_port
    cmp byte [rtl8156_active], 1
    jne .next_found
    movzx eax, byte [rtl8156_port]
    lea r11d, [edx + 1]
    cmp eax, r11d
    je .next_skip
    jmp .next_found
.next_skip:
    inc edx
    jmp .next_loop

.next_found:
    ; Temporarily save port1 and set port_num to this new port for reset sequence
    movzx eax, byte [xhci_port_num]
    mov [xhci_port1_num], al          ; save slot1 port
    lea eax, [edx + 1]
    mov [xhci_port_num], al           ; 1-based

    ; Reset and enable this port (reuse same reset logic inline)
    mov ecx, ebx
    shr ecx, XHCI_PORTSC_SPEED_SHIFT
    and ecx, 0x0F
    mov [xhci_port_speed], cl

    ; Power port if needed
    test ebx, XHCI_PORTSC_PP
    jnz .next_powered
    mov eax, ebx
    and eax, ~XHCI_PORTSC_CHANGE_BITS
    or eax, XHCI_PORTSC_PP
    movzx ecx, byte [xhci_port_num]
    dec ecx
    shl ecx, 4
    mov [rsi + rcx + XHCI_PORTSC], eax
.next_powered:

    ; Issue port reset (PR bit)
    movzx ecx, byte [xhci_port_num]
    dec ecx
    shl ecx, 4
    mov eax, [rsi + rcx + XHCI_PORTSC]
    and eax, ~XHCI_PORTSC_CHANGE_BITS
    and eax, ~XHCI_PORTSC_PED
    or eax, XHCI_PORTSC_PR
    mov [rsi + rcx + XHCI_PORTSC], eax

    ; Wait for reset complete (PRC bit) - PIT-based 500ms timeout
    push rdx
    mov rdx, [tick_count]
    add rdx, 50                   ; 50 ticks = 500ms at 100Hz
.next_rst_wait:
    mov eax, [rsi + rcx + XHCI_PORTSC]
    test eax, XHCI_PORTSC_PRC
    jnz .next_rst_pop_done

    push rax
    mov rax, [tick_count]
    cmp rax, rdx
    pop rax
    jl .next_rst_wait
.next_rst_pop_done:
    pop rdx
.next_rst_done:
    ; Clear PRC. Two bugs lurked here:
    ;  1. Original order set PRC then ANDed out CHANGE_BITS - that masked PRC
    ;     back to 0, so PRC was NEVER cleared.
    ;  2. Didn't mask PED (RW1C: write 1 disables) - inadvertently disabled
    ;     the port we just enabled (matches LS-mouse failure on AMD).
    and eax, ~XHCI_PORTSC_CHANGE_BITS   ; preserve other change bits
    and eax, ~XHCI_PORTSC_PED            ; PED RW1C: write 0 to leave alone
    or eax, XHCI_PORTSC_PRC              ; now set PRC=1 to clear it
    mov [rsi + rcx + XHCI_PORTSC], eax

    mov eax, 1
    jmp .next_ret

.next_none:
    xor eax, eax
.next_ret:
    pop rbx
    pop rdx
    pop rcx
    pop rsi
    ret

; ============================================================================
; xhci_enable_slot - Send Enable Slot command
; Returns: EAX = slot ID (1+), 0 on failure
; ============================================================================
global xhci_enable_slot