; ============================================================================
; i2c_hid_poll - Non-blocking touchpad poll (called from main loop)
;
; State machine (2 states - the input report is read in ONE I2C
; transaction, as the I2C-HID spec requires):
;   State 0: Address wInputRegister + queue the full report read burst
;            (RESTART..STOP), arm a deadline -> state=1
;   State 1: Wait until the whole burst is in the RX FIFO, then drain
;            and process it. On deadline timeout, recover -> state=0
; ============================================================================
i2c_hid_poll:
    cmp byte [i2c_hid_active], 1
    jne .poll_ret_noframe

    push rbx                    ; rbx is callee-saved; clobbered by xor ebx,ebx below

    ; Atomic test-and-set of the reentry guard. i2c_hid_poll runs in BOTH the
    ; main loop (frame_pacing.ghl, interrupts enabled) and the touchpad IRQ
    ; (isr.asm .irq_apic_touchpad), so the touchpad IRQ can preempt a main-loop
    ; poll. A non-atomic cmp-then-mov leaves a TOCTOU window: both contexts read
    ; busy==0 before either writes 1, then run concurrently and desync the I2C
    ; state machine / RX-FIFO drain. `xchg` carries an implicit LOCK on a memory
    ; operand, so exactly one context observes the prior 0 and proceeds; the
    ; other sees 1 and bails. Mirrors the `xchg al, [mouse_moved]` TAS idiom in
    ; mouse_handler.inc. Every acquiring exit below clears i2c_poll_busy.
    mov al, 1
    xchg al, [i2c_poll_busy]
    test al, al
    jne .poll_ret_busy

    mov rsi, [i2c_base_addr]
    ; §8: prove the whole DW_IC register window (every [rsi+off] below, off<=0xF4)
    ; lies inside this driver's registered MMIO page before any poll-path access.
    I2C_MMIO_ASSERT rsi, MMIO_I2C_WINDOW
    inc dword [i2c_dbg_polls]           ; DEBUG: count poll entries

    ; Check for TX abort (non-blocking)
    mov eax, [rsi + DW_IC_RAW_INTR_STAT]
    test eax, (1 << 6)
    jz .no_abort
    inc dword [i2c_dbg_aborts]          ; DEBUG: count aborts
    mov eax, [rsi + DW_IC_TX_ABRT_SRC]  ; DEBUG: why did it abort?
    mov [i2c_dbg_abrt_src], eax
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]
    inc dword [i2c_error_count]
    cmp dword [i2c_error_count], 50
    jge .do_bus_reset
    mov byte [i2c_poll_state], 0
    mov byte [i2c_poll_busy], 0
    pop rbx
    ret
.no_abort:

    movzx eax, byte [i2c_poll_state]
    cmp eax, 1
    je .state1

    ; === STATE 0: issue a single-transaction input-report read ===
    ; The I2C-HID spec requires the 2-byte length header AND the report
    ; payload to be read in ONE transaction (one START..STOP). Splitting
    ; it - read header, STOP, then a second read - makes the device treat
    ; the report as consumed; the second read returns an empty 0-length
    ; report. So queue the whole burst up front.
.state0:
    ; Drain any stale RX data
    mov eax, [rsi + DW_IC_RXFLR]
    test eax, eax
    jz .state0_no_drain
    call i2c_flush_rx
.state0_no_drain:
    ; Clear any stale abort
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]

    ; Bytes to read = wMaxInputLength, clamped to our HID parser buffer. Do
    ; not clamp to RX FIFO depth: real touchpad reports often exceed 16 bytes.
    ; State 1 drains RX progressively while queueing more read commands.
    movzx ecx, word [i2c_max_input_len]
    cmp ecx, 8
    jae .ric_have
    mov ecx, 16                 ; missing/bogus descriptor value
.ric_have:
    cmp ecx, MOUSE_BUFFER_SIZE
    jbe .ric_min
    mov ecx, MOUSE_BUFFER_SIZE
.ric_min:
    cmp ecx, 8
    jae .ric_ok
    mov ecx, 8
.ric_ok:
    mov [i2c_read_count], cx

    ; Address the Input Register (2-byte LE write, no STOP -> RESTART read)
    movzx eax, word [i2c_hid_input_reg]
    call i2c_write_byte
    movzx eax, word [i2c_hid_input_reg]
    shr eax, 8
    call i2c_write_byte
    call i2c_wait_tx_empty
    jc .state0_recover

    mov word [i2c_read_queued], 0
    mov word [i2c_read_index], 0

    ; Deadline: if the burst has not fully arrived within ~10 PIT ticks
    ; (~100ms) the transaction aborted - recover instead of stalling.
    mov eax, [tick_count]
    add eax, 10
    mov [i2c_poll_deadline], eax

    mov byte [i2c_poll_state], 1
    jmp .state1

    ; Address phase failed before any read burst was armed.
.state0_recover:
    inc dword [i2c_error_count]
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]
    call i2c_flush_rx
    mov byte [i2c_poll_state], 0
    mov byte [i2c_poll_busy], 0
    pop rbx
    ret

    ; === STATE 1: wait for the burst, then process it ===
.state1:
    ; Drain any bytes already delivered. RXFLR never exceeds the hardware FIFO
    ; depth, so waiting for RXFLR == whole report breaks on real touchpads.
.state1_drain:
    mov eax, [rsi + DW_IC_RXFLR]
    test eax, eax
    jz .state1_queue
    movzx ebx, word [i2c_read_index]
    movzx ecx, word [i2c_read_count]
    cmp ebx, ecx
    jae .state1_queue
    mov eax, [rsi + DW_IC_DATA_CMD]
    mov [i2c_report_buf + rbx], al
    inc ebx
    mov [i2c_read_index], bx
    jmp .state1_drain

.state1_queue:
    ; Queue more read commands while the TX FIFO has space.
    movzx ebx, word [i2c_read_queued]
    movzx ecx, word [i2c_read_count]
    cmp ebx, ecx
    jae .state1_check_done
    mov eax, [rsi + DW_IC_TXFLR]
    movzx edx, byte [i2c_tx_fifo_depth]
    test edx, edx
    jnz .tx_depth_ok
    mov edx, 16
.tx_depth_ok:
    cmp eax, edx
    jae .state1_check_done

    mov eax, IC_CMD_READ
    test ebx, ebx
    jnz .not_first_read
    or eax, IC_CMD_RESTART
.not_first_read:
    mov edx, ebx
    inc edx
    cmp dx, [i2c_read_count]
    jne .not_last_read
    or eax, IC_CMD_STOP
.not_last_read:
    mov [rsi + DW_IC_DATA_CMD], eax
    inc ebx
    mov [i2c_read_queued], bx
    jmp .state1_drain

.state1_check_done:
    movzx eax, word [i2c_read_index]
    movzx ecx, word [i2c_read_count]
    cmp eax, ecx
    jge .state1_ready

    ; Burst not fully in yet.  If the hardware still has TX commands queued,
    ; spin up to ~2ms (TSC-based) waiting for bytes to arrive.  This converts
    ; what was a 4-frame sequence (one 16-byte FIFO-load per 16.7ms frame at
    ; 60 fps) into a single-call read: a 64-byte report at 400kHz I2C finishes
    ; in ~1.4ms, well within the 2ms budget.
    mov eax, [rsi + DW_IC_TXFLR]
    test eax, eax
    jz .state1_deadline_check       ; TX empty -> no outstanding reads; skip spin

    mov rcx, [cpu_tsc_per_tick]
    test rcx, rcx
    jz .state1_deadline_check       ; TSC not calibrated yet; skip spin

    rdtsc
    shl rdx, 32
    or rax, rdx                     ; rax = 64-bit TSC now
    mov rcx, [cpu_tsc_per_tick]
    shr rcx, 2                      ; /4 => ~2.5ms at 100Hz (10ms/tick)
    add rax, rcx
    mov [i2c_spin_tsc_deadline], rax

.state1_rx_spin:
    pause
    ; Abort check inside spin so a bus error doesn't waste the full 2ms budget.
    mov eax, [rsi + DW_IC_RAW_INTR_STAT]
    test eax, (1 << 6)              ; TX_ABRT
    jnz .state1_spin_abort
    mov eax, [rsi + DW_IC_RXFLR]
    test eax, eax
    jnz .state1_drain               ; bytes arrived -> drain and queue more
    rdtsc
    shl rdx, 32
    or rax, rdx
    cmp rax, [i2c_spin_tsc_deadline]
    jb .state1_rx_spin              ; still within spin budget

.state1_deadline_check:
    ; Spin exhausted (or skipped). Fall back to the slow tick-based deadline so
    ; very large reports can span at most ~100ms before an error is declared.
    mov eax, [tick_count]
    cmp eax, [i2c_poll_deadline]
    jb .poll_ret                    ; still within deadline, keep waiting
    ; Tick deadline expired -> abort and recover.
    inc dword [i2c_error_count]
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]
    call i2c_flush_rx
    mov byte [i2c_poll_state], 0
    mov byte [i2c_poll_busy], 0
    pop rbx
    ret

.state1_spin_abort:
    ; TX abort detected during spin: clear state and let next poll retry.
    inc dword [i2c_dbg_aborts]
    mov eax, [rsi + DW_IC_CLR_TX_ABRT]
    inc dword [i2c_error_count]
    call i2c_flush_rx
    mov byte [i2c_poll_state], 0
    mov byte [i2c_poll_busy], 0
    pop rbx
    ret

.state1_ready:
    mov byte [i2c_poll_state], 0
    mov dword [i2c_error_count], 0  ; Reset error count on success

    ; --- Serial latency stamp: "P<4-hex-delta>\r" where delta = TSC>>16 between
    ; consecutive processed reports.  At 3GHz: 1 unit ≈ 21.8 μs.
    ; Target for 125Hz touchpad: ~8ms inter-report = ~0x016E units at 3GHz.
    ; Connect a serial terminal and observe the printed values to confirm rate.
    ;
    ; PRIVACY/LOGLESS: this emits per-report touchpad TIMING over COM1, which is
    ; a side channel of user-input cadence (scroll/move rate, idle gaps). Gated
    ; behind ENABLE_DEBUG_SERIAL so release builds are zero-cost AND leak nothing
    ; off-machine, matching the SER/BOOTLOG2 convention in macros.inc.
%ifdef ENABLE_DEBUG_SERIAL
    push rbx
    push rcx
    push rdx
    rdtsc
    shl rdx, 32
    or rax, rdx                     ; rax = 64-bit TSC now
    mov rcx, rax                    ; rcx = current TSC (saved before computing delta)
    sub rax, [i2c_last_report_tsc]  ; rax = delta since last report
    shr rax, 16                     ; scale: ~21μs/unit at 3GHz
    mov [i2c_last_report_tsc], rcx  ; update last timestamp (rcx = current TSC)
    mov rbx, rax                    ; rbx = scaled delta (nibble source, rax can now be clobbered)
    mov dx, 0x3F8
    mov al, 'P'
    out dx, al
    ; nibble 3 (bits 15:12)
    mov al, bh
    shr al, 4
    and al, 0xF
    add al, 0x30
    cmp al, 0x3A
    jb .lat0
    add al, 7
.lat0:
    out dx, al
    ; nibble 2 (bits 11:8)
    mov al, bh
    and al, 0xF
    add al, 0x30
    cmp al, 0x3A
    jb .lat1
    add al, 7
.lat1:
    out dx, al
    ; nibble 1 (bits 7:4)
    mov al, bl
    shr al, 4
    and al, 0xF
    add al, 0x30
    cmp al, 0x3A
    jb .lat2
    add al, 7
.lat2:
    out dx, al
    ; nibble 0 (bits 3:0)
    mov al, bl
    and al, 0xF
    add al, 0x30
    cmp al, 0x3A
    jb .lat3
    add al, 7
.lat3:
    out dx, al
    mov al, 13
    out dx, al
    pop rdx
    pop rcx
    pop rbx
%endif ; ENABLE_DEBUG_SERIAL

    ; --- DEBUG: capture raw report (count, length, first 8 bytes) ---
    inc dword [i2c_dbg_rpts]
    movzx eax, word [i2c_report_buf]
    mov [i2c_dbg_len], ax
    lea rdi, [i2c_report_buf]
    lea rax, [i2c_dbg_bytes]
    mov ecx, 8
.dbg_cap:
    mov dl, [rdi]
    mov [rax], dl
    inc rdi
    inc rax
    dec ecx
    jnz .dbg_cap
    ; --- end debug ---

    ; Parse the report. Bytes [0:1] are the length header. The real
    ; report may be longer than our 32-byte burst, so clamp the data
    ; length to what we actually read.
    lea rdi, [i2c_report_buf]
    movzx ecx, word [rdi]       ; packet length from header
    movzx eax, word [i2c_read_count]
    cmp ecx, eax
    jbe .len_in_range
    mov ecx, eax
.len_in_range:
    sub ecx, 2                   ; data length after header
    cmp ecx, 1
    jl .poll_ret                 ; No useful data (idle / empty report)
    add rdi, 2                   ; skip length header

    ; Check if we have parsed report descriptor
    cmp byte [i2c_use_parsed], 1
    je .use_parsed_report

    ; === Fallback: legacy 6-byte fixed-format report ===
    ; [ReportID] [Buttons] [Xlow] [Xhi] [Ylow] [Yhi]
    movzx eax, byte [rdi]       ; Report ID
    inc rdi
    dec ecx

    movzx eax, byte [rdi]       ; Buttons
    and al, 0x07
    mov [mouse_buttons], al

    ; X delta (16-bit signed LE)
    movzx eax, byte [rdi + 1]
    movzx ebx, byte [rdi + 2]
    shl ebx, 8
    or eax, ebx
    movsx eax, ax
    sar eax, 1                   ; sensitivity scaling
    add [mouse_x], eax

    ; Y delta (16-bit signed LE)
    movzx eax, byte [rdi + 3]
    movzx ebx, byte [rdi + 4]
    shl ebx, 8
    or eax, ebx
    movsx eax, ax
    sar eax, 1
    add [mouse_y], eax

    ; Scroll wheel byte (byte 5, 8-bit signed, optional)
    cmp ecx, 6
    jl .no_legacy_scroll
    movsx eax, byte [rdi + 5]
    test eax, eax
    jz .no_legacy_scroll
    mov [mouse_scroll_y], eax
.no_legacy_scroll:

    ; Clamp
    jmp .poll_clamp

.use_parsed_report:
    ; Skip report ID byte if present
    push rcx
    cmp byte [hid_parsed_has_report_id], 1
    jne .no_skip_id
    mov al, [rdi]
    cmp al, [hid_parsed_report_id]
    jne .parsed_report_id_mismatch
    inc rdi
    dec ecx
.no_skip_id:

    ; Use parsed layout to process report
    mov rsi, rdi                 ; report data pointer
    ; ECX = data length
    call hid_process_touchpad_report
    pop rcx
    mov byte [mouse_moved], 1   ; mark moved so cursor updates
    jmp .poll_ret

.parsed_report_id_mismatch:
    ; The Synaptics SYNA1B92 defaults to its RELATIVE MOUSE collection until a
    ; host switches it into PTP absolute mode. That collection is Report ID 0x02,
    ; a 4-byte report (incl ID): [ID][buttons][dX:s8][dY:s8] (confirmed from the
    ; device's own HID caps: UsagePage 0x1/Usage 0x2 Mouse, X/Y relative 8-bit).
    ; The parsed layout targets the ABSOLUTE collection, so its report ID never
    ; matches and every real motion report was being dropped here -> dead cursor.
    ; Consume the relative mouse report directly so the pointer moves.
    ; On entry rdi -> report ID byte; ecx (restored below) = data length (no hdr).
    pop rcx
    cmp ecx, 8
    ja .poll_ret                 ; long report -> not the relative mouse packet
    cmp ecx, 4
    jl .poll_ret                 ; too short to carry buttons + dX + dY
    movzx eax, byte [rdi + 1]    ; buttons
    and al, 0x07
    mov [mouse_buttons], al
    movsx eax, byte [rdi + 2]    ; dX, signed 8-bit relative delta
    imul eax, [mouse_sense_x]    ; * sensitivity (tenths)
    cdq
    mov ecx, 10
    idiv ecx                     ; / 10
    shl eax, 1                   ; 2x I2C-path boost: compensates ~60Hz polling
                                 ; vs 125Hz native rate (each read captures 2
                                 ; reports' worth of motion, but we only see 1)
    add [mouse_x], eax
    movsx eax, byte [rdi + 3]    ; dY, signed 8-bit relative delta
    imul eax, [mouse_sense_y]
    cdq
    mov ecx, 10
    idiv ecx
    shl eax, 1                   ; same 2x boost for Y
    add [mouse_y], eax
    jmp .poll_clamp              ; clamp to screen + set mouse_moved

.poll_clamp:
    ; Clamp coordinates
    cmp dword [mouse_x], 0
    jge .cx_ok
    mov dword [mouse_x], 0
.cx_ok:
    mov eax, [scr_width]
    dec eax
    cmp [mouse_x], eax
    jle .cx_max_ok
    mov [mouse_x], eax
.cx_max_ok:
    cmp dword [mouse_y], 0
    jge .cy_ok
    mov dword [mouse_y], 0
.cy_ok:
    mov eax, [scr_height]
    dec eax
    cmp [mouse_y], eax
    jle .cy_max_ok
    mov [mouse_y], eax
.cy_max_ok:
    mov byte [mouse_moved], 1

.poll_ret:
    mov byte [i2c_poll_busy], 0
    pop rbx
.poll_ret_noframe:
    ret

.poll_ret_busy:
    pop rbx
    ret

.do_bus_reset:
    call i2c_hid_bus_reset
    mov byte [i2c_poll_busy], 0
    pop rbx
    ret
