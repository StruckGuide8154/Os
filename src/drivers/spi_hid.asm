; ============================================================================
; NexusOS v3.0 - SPI HID Touchpad Driver
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
    ; Wait for device ready (~20ms equivalent in loops)
    mov ecx, 2000000
.reset_wait:
    dec ecx
    jnz .reset_wait

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

    movzx eax, word [spi_rx_buf + 8]   ; wReportDescLength
    test eax, eax
    jz .fail_desc
    cmp eax, SPI_RDESC_BUF_SIZE
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
    ; read descriptor length + 4 header bytes
    mov rcx, [spi_report_desc_len]
    movzx rcx, word [spi_report_desc_len]
    add rcx, 4
    call spi_transfer
    test eax, eax
    jz .rdesc_fail

    ; Check sync
    cmp byte [spi_rdesc_buf + 0], SPI_SYNC_DEV
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
    jne .poll_ret

    ; Request input report: SYNC + CID_OUTPUT + length=4 + register=0x0003
    mov byte [spi_tx_buf + 0], SPI_SYNC_HOST
    mov byte [spi_tx_buf + 1], SPI_CID_OUTPUT
    mov byte [spi_tx_buf + 2], 0x04
    mov byte [spi_tx_buf + 3], 0x00
    mov byte [spi_tx_buf + 4], 0x03    ; wInputRegister = 0x0003
    mov byte [spi_tx_buf + 5], 0x00

    ; Read response: header (4B) + up to 64B report
    lea rdi, [spi_tx_buf]
    mov rsi, 6
    lea rdx, [spi_rx_buf]
    mov rcx, 68
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
    ret

section .data
spi_hid_active:         db 0
spi_poll_state:         db 0
spi_report_desc_len:    dw 0

section .bss
SPI_TX_BUF_SIZE     equ 16
SPI_RX_BUF_SIZE     equ 72
SPI_RDESC_BUF_SIZE  equ 512

spi_tx_buf:     resb SPI_TX_BUF_SIZE
spi_rx_buf:     resb SPI_RX_BUF_SIZE
spi_rdesc_buf:  resb SPI_RDESC_BUF_SIZE
