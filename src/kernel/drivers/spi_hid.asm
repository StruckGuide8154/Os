; ============================================================================
; Grit v3.0 - SPI HID Touchpad Driver
; Implements Microsoft HID-over-SPI protocol (Windows Precision Touchpad)
;
; Protocol (per Microsoft HID-over-SPI spec):
;   Each transaction: [SYNC_BYTE][CONTENT_ID][LENGTH_LO][LENGTH_HI][DATA...]
;   SYNC_BYTE = 0xFF (host-to-device) or 0x80 (device-to-host)
;   CONTENT_ID:  0x0F = input report, 0x04 = command, 0x05 = descriptor
;   HOST_WRITE triggers: host sends 0xFF+0x0F to request input report
;
; Supports:
;   - SPI device descriptor fetch
;   - HID report descriptor parsing (via hid_parser.asm)
;   - Variable-length input report read
;   - Absolute + relative modes via parsed layout
; ============================================================================
bits 64

%include "constants.inc"

extern mouse_x
extern mouse_y
extern mouse_buttons
extern mouse_moved
extern mouse_scroll_y
extern scr_width
extern scr_height

extern spi_init
extern spi_transfer
extern spi_type

; HID parser
extern hid_parse_report_desc
extern hid_process_touchpad_report
extern hid_parsed_is_absolute
extern hid_parsed_report_bytes
extern hid_parsed_has_report_id

extern tick_count

; SPI-HID packet constants
SPI_SYNC_HOST       equ 0xFF    ; host->device sync byte
SPI_SYNC_DEV        equ 0x80    ; device->host sync byte (when data ready)
SPI_SYNC_IDLE       equ 0x00    ; bus idle

SPI_CID_OUTPUT      equ 0x0F    ; input report request
SPI_CID_RESET       equ 0x04    ; reset/command
SPI_CID_DESC        equ 0x05    ; device descriptor

; Poll state
SPI_STATE_IDLE      equ 0
SPI_STATE_WAIT      equ 1       ; waiting for device ready

; --- buffer sizing & the security invariants that keep every device-controlled
;     transfer length in-bounds (proof: security/audits/spi_hid_asm.md) ---
%define SPI_RX_HDR          4       ; SPI response header: [sync][cid][len_lo][len_hi]
%define SPI_RX_REPORT_MAX   64      ; max input-report payload bytes read/parsed per poll
%define SPI_RDESC_MAX       512     ; max HID report descriptor accepted
%define SPI_TX_BUF_SIZE     16
%define SPI_RX_BUF_SIZE     72
%define SPI_RDESC_BUF_SIZE  (SPI_RDESC_MAX + SPI_RX_HDR)   ; desc + header => no OOB on a full 512B desc
%if SPI_RX_BUF_SIZE < (SPI_RX_HDR + SPI_RX_REPORT_MAX)
  %error "spi_rx_buf too small: header + input-report payload would overrun it"
%endif

section .text
global spi_hid_init
global spi_hid_poll

; ============================================================================
; spi_hid_init - Initialize SPI HID touchpad
; Returns: EAX = 1 if found and initialized, 0 otherwise
; ============================================================================
spi_hid_init:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    mov byte [spi_hid_active], 0
    mov byte [spi_poll_state], SPI_STATE_IDLE

    ; Init SPI controller
    call spi_init
    test eax, eax
    jz .fail

    ; Send reset
    call spi_hid_send_reset
    ; Wait for device ready - PIT-based 50ms (5 ticks at 100Hz). CPU spin is
    ; calibrated to QEMU and fires in microseconds on real HW.
    push rbx
    mov rbx, [tick_count]
    add rbx, 5
.reset_wait:
    mov rax, [tick_count]
    cmp rax, rbx
    jae .reset_done
    pause
    jmp .reset_wait
.reset_done:
    pop rbx

    ; Fetch HID device descriptor
    call spi_hid_get_device_desc
    test eax, eax
    jz .fail

    ; Fetch and parse HID report descriptor
    call spi_hid_get_report_desc
    ; Ignore parse failure - will use fallback

    mov byte [spi_hid_active], 1
    mov eax, 1
    jmp .ret

.fail:
    xor eax, eax
.ret:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; spi_hid_send_reset - Send HID RESET command over SPI
; ============================================================================
spi_hid_send_reset:
    push rbx
    ; Build reset packet: SYNC + CID_RESET + LENGTH=0x0002 + OPCODE_RESET=0x0001
    mov byte [spi_tx_buf + 0], SPI_SYNC_HOST
    mov byte [spi_tx_buf + 1], SPI_CID_RESET
    mov byte [spi_tx_buf + 2], 0x04    ; length (4 bytes total including header)
    mov byte [spi_tx_buf + 3], 0x00
    mov byte [spi_tx_buf + 4], 0x01    ; RESET opcode
    mov byte [spi_tx_buf + 5], 0x00

    lea rdi, [spi_tx_buf]
    mov rsi, 6
    xor rdx, rdx
    xor rcx, rcx
    call spi_transfer
    pop rbx
    ret

; ============================================================================
; spi_hid_get_device_desc - Fetch 22-byte HID device descriptor
; Returns: EAX = 1 success, 0 fail
; ============================================================================
spi_hid_get_device_desc:
    push rbx
    push rcx

    ; Request device descriptor: SYNC + CID_DESC + length + register 0x0000
    mov byte [spi_tx_buf + 0], SPI_SYNC_HOST
    mov byte [spi_tx_buf + 1], SPI_CID_DESC
    mov byte [spi_tx_buf + 2], 0x04
    mov byte [spi_tx_buf + 3], 0x00
    mov byte [spi_tx_buf + 4], 0x00    ; wDescriptorAddress low
    mov byte [spi_tx_buf + 5], 0x00    ; wDescriptorAddress high

    lea rdi, [spi_tx_buf]
    mov rsi, 6
    lea rdx, [spi_rx_buf]
    mov rcx, 30
    call spi_transfer
    test eax, eax
    jz .fail_desc

    ; Validate: device byte 0 should be SPI_SYNC_DEV (0x80)
    cmp byte [spi_rx_buf + 0], SPI_SYNC_DEV
    jne .fail_desc

    ; Parse device descriptor response
    ; [0] sync [1] CID [2-3] length [4-5] wHIDDescLength
    ; [6-7] bcdVersion [8-9] wReportDescLength
    ; [10-11] wInputRegister [12-13] wOutputRegister
    ; [14-15] wCommandRegister [16-17] wDataRegister
    ; [18-19] wVendorID [20-21] wProductID

    movzx eax, word [spi_rx_buf + 8]   ; wReportDescLength (device-controlled, 0..65535)
    test eax, eax
    jz .fail_desc
    ; Accept at most SPI_RDESC_MAX descriptor bytes. The receive buffer is sized
    ; SPI_RDESC_MAX + SPI_RX_HDR, so the later "len + header" read stays in-bounds.
    cmp eax, SPI_RDESC_MAX
    jg .fail_desc
    mov [spi_report_desc_len], ax

    mov eax, 1
    jmp .desc_ret
.fail_desc:
    xor eax, eax
.desc_ret:
    pop rcx
    pop rbx
    ret

; ============================================================================
; spi_hid_get_report_desc - Fetch and parse HID report descriptor
; ============================================================================
spi_hid_get_report_desc:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    movzx ecx, word [spi_report_desc_len]
    test ecx, ecx
    jz .rdesc_fail

    ; Request report descriptor: register 0x0001
    mov byte [spi_tx_buf + 0], SPI_SYNC_HOST
    mov byte [spi_tx_buf + 1], SPI_CID_DESC
    add ecx, 4                          ; add header overhead
    mov [spi_tx_buf + 2], cl
    shr ecx, 8
    mov [spi_tx_buf + 3], cl
    movzx ecx, word [spi_report_desc_len]
    mov byte [spi_tx_buf + 4], 0x01    ; register 0x0001 (report descriptor)
    mov byte [spi_tx_buf + 5], 0x00

    lea rdi, [spi_tx_buf]
    mov rsi, 6
    lea rdx, [spi_rdesc_buf]
    ; read descriptor length + header. report_desc_len is bounded to SPI_RDESC_MAX by
    ; spi_hid_get_device_desc, and spi_rdesc_buf is SPI_RDESC_MAX + SPI_RX_HDR bytes, so
    ; this RX count (<= SPI_RDESC_MAX + SPI_RX_HDR = SPI_RDESC_BUF_SIZE) never overruns it.
    movzx rcx, word [spi_report_desc_len]
    add rcx, SPI_RX_HDR
    call spi_transfer
    test eax, eax
    jz .rdesc_fail

    ; Check sync
    cmp byte [spi_rdesc_buf + 0], SPI_SYNC_DEV
    jne .rdesc_fail

    ; The wire header is device-controlled too.  Do not parse descriptor bytes
    ; beyond the packet length the device returned, and reject an over-claim
    ; beyond the transfer we requested even though the backing buffer is large
    ; enough.  A valid descriptor response is exactly header + advertised HID
    ; report-descriptor bytes.
    movzx eax, word [spi_rdesc_buf + 2]
    movzx ecx, word [spi_report_desc_len]
    add ecx, SPI_RX_HDR
    cmp eax, ecx
    jne .rdesc_fail

    ; Parse: descriptor starts at offset 4
    lea rsi, [spi_rdesc_buf + 4]
    movzx ecx, word [spi_report_desc_len]
    call hid_parse_report_desc
    ; EAX = 1 if parsed ok
    jmp .rdesc_ret
.rdesc_fail:
    xor eax, eax
.rdesc_ret:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; spi_hid_poll - Non-blocking SPI HID poll (called from main loop)
; ============================================================================
spi_hid_poll:
    cmp byte [spi_hid_active], 1
    jne .poll_skip

    ; SECURITY (reentrancy / TOCTOU): this routine mutates shared spi_tx_buf/spi_rx_buf
    ; and drives the SPI state machine. It is documented "callable from the main loop"
    ; and is already invoked from the touchpad IRQ (isr.asm .irq_apic_touchpad). An
    ; atomic test-and-set makes any concurrent or reentrant entry skip cleanly instead
    ; of corrupting an in-flight transfer. xchg carries an implicit LOCK (mirrors the
    ; i2c_hid_poll / mouse_handler busy-flag idiom).
    mov al, 1
    xchg al, [spi_poll_busy]
    test al, al
    jnz .poll_skip

    ; Request input report: SYNC + CID_OUTPUT + length=4 + register=0x0003
    mov byte [spi_tx_buf + 0], SPI_SYNC_HOST
    mov byte [spi_tx_buf + 1], SPI_CID_OUTPUT
    mov byte [spi_tx_buf + 2], 0x04
    mov byte [spi_tx_buf + 3], 0x00
    mov byte [spi_tx_buf + 4], 0x03    ; wInputRegister = 0x0003
    mov byte [spi_tx_buf + 5], 0x00

    ; Read response: header (SPI_RX_HDR) + up to SPI_RX_REPORT_MAX payload bytes.
    ; This RX count is <= SPI_RX_BUF_SIZE (static-asserted above), so the transfer
    ; cannot overrun spi_rx_buf.
    lea rdi, [spi_tx_buf]
    mov rsi, 6
    lea rdx, [spi_rx_buf]
    mov rcx, SPI_RX_HDR + SPI_RX_REPORT_MAX
    call spi_transfer
    test eax, eax
    jz .poll_ret

    ; Check sync byte - if not 0x80, device has no data
    cmp byte [spi_rx_buf + 0], SPI_SYNC_DEV
    jne .poll_ret

    ; Get report length from header [2-3]
    movzx ecx, word [spi_rx_buf + 2]
    test ecx, ecx
    jz .poll_ret
    cmp ecx, 0xFFFF
    je .poll_ret
    sub ecx, 4                         ; subtract header
    jle .poll_ret

    ; SECURITY (OOB read): the device-claimed length in header [2-3] is NOT a promise of
    ; how many bytes were actually clocked in. We only read SPI_RX_REPORT_MAX payload
    ; bytes into spi_rx_buf, so clamp the parse length to that. Without this the parser
    ; (hid_process_touchpad_report, ECX = data length) would walk up to ~64 KiB past the
    ; buffer on a malicious/faulty report header.
    cmp ecx, SPI_RX_REPORT_MAX
    jbe .len_ok
    mov ecx, SPI_RX_REPORT_MAX
.len_ok:

    ; Process data at spi_rx_buf + 4
    lea rsi, [spi_rx_buf + 4]

    ; Check if we parsed the report descriptor
    cmp byte [hid_parsed_report_bytes], 0
    je .fallback_parse

    ; Use hid_parser path
    cmp byte [hid_parsed_has_report_id], 1
    jne .no_skip_id
    inc rsi
    dec ecx
.no_skip_id:
    call hid_process_touchpad_report
    mov byte [mouse_moved], 1
    jmp .poll_ret

.fallback_parse:
    ; Fallback: parse as 5-byte absolute or relative report
    ; [0]=buttons [1-2]=X (LE) [3-4]=Y (LE)
    cmp ecx, 5
    jl .try_3byte

    movzx eax, byte [rsi]
    and al, 0x07
    mov [mouse_buttons], al

    cmp byte [hid_parsed_is_absolute], 1
    je .fallback_abs

    ; Relative
    movsx eax, byte [rsi + 1]
    add [mouse_x], eax
    movsx eax, byte [rsi + 2]
    add [mouse_y], eax
    jmp .fallback_clamp

.fallback_abs:
    movzx eax, word [rsi + 1]
    mov ecx, [scr_width]
    imul eax, ecx
    mov ecx, 0x7FFF
    xor edx, edx
    div ecx
    mov [mouse_x], eax

    movzx eax, word [rsi + 3]
    mov ecx, [scr_height]
    imul eax, ecx
    mov ecx, 0x7FFF
    xor edx, edx
    div ecx
    mov [mouse_y], eax
    jmp .fallback_clamp

.try_3byte:
    cmp ecx, 3
    jl .poll_ret
    movzx eax, byte [rsi]
    and al, 0x07
    mov [mouse_buttons], al
    movsx eax, byte [rsi + 1]
    add [mouse_x], eax
    movsx eax, byte [rsi + 2]
    add [mouse_y], eax

.fallback_clamp:
    cmp dword [mouse_x], 0
    jge .cx_ok
    mov dword [mouse_x], 0
.cx_ok:
    mov eax, [scr_width]
    dec eax
    cmp [mouse_x], eax
    jle .cy_check
    mov [mouse_x], eax
.cy_check:
    cmp dword [mouse_y], 0
    jge .cy_ok
    mov dword [mouse_y], 0
.cy_ok:
    mov eax, [scr_height]
    dec eax
    cmp [mouse_y], eax
    jle .moved_ok
    mov [mouse_y], eax
.moved_ok:
    mov byte [mouse_moved], 1

.poll_ret:
    mov byte [spi_poll_busy], 0        ; release the reentrancy guard
.poll_skip:
    ret

section .data
spi_hid_active:         db 0
spi_poll_state:         db 0
spi_poll_busy:          db 0           ; atomic test-and-set reentrancy guard (see spi_hid_poll)
spi_report_desc_len:    dw 0

section .bss
; sizes are defined as %define constants at the top of the file so the
; %if static-assert can validate the header+payload invariant at assemble time.
spi_tx_buf:     resb SPI_TX_BUF_SIZE
spi_rx_buf:     resb SPI_RX_BUF_SIZE
spi_rdesc_buf:  resb SPI_RDESC_BUF_SIZE
