; ============================================================================
; NexusOS v3.0 - HID Report Descriptor Parser & Gesture Engine
; Parses HID report descriptors to extract field layouts (X, Y, buttons,
; contact count, tip switch) and provides gesture detection (tap-to-click,
; two-finger scroll).
;
; Shared between USB HID, I2C HID, and SPI HID drivers.
; ============================================================================
bits 64

%include "constants.inc"

extern tick_count
extern mouse_buttons, mouse_moved

section .text

; ============================================================================
; HID Item Tag constants (byte & 0xFC to mask off bSize)
; ============================================================================
HID_USAGE_PAGE      equ 0x04    ; Global: Usage Page
HID_LOGICAL_MIN     equ 0x14    ; Global: Logical Minimum
HID_LOGICAL_MAX     equ 0x24    ; Global: Logical Maximum
HID_PHYSICAL_MIN    equ 0x34    ; Global: Physical Minimum
HID_PHYSICAL_MAX    equ 0x44    ; Global: Physical Maximum
HID_REPORT_SIZE     equ 0x74    ; Global: Report Size (bits per field)
HID_REPORT_ID       equ 0x84    ; Global: Report ID
HID_REPORT_COUNT    equ 0x94    ; Global: Report Count (number of fields)
HID_USAGE           equ 0x08    ; Local: Usage
HID_USAGE_MIN       equ 0x18    ; Local: Usage Minimum
HID_USAGE_MAX       equ 0x28    ; Local: Usage Maximum
HID_INPUT           equ 0x80    ; Main: Input
HID_COLLECTION      equ 0xA0   ; Main: Collection
HID_END_COLLECTION  equ 0xC0   ; Main: End Collection

; Usage Pages
UP_GENERIC_DESKTOP  equ 0x01
UP_BUTTON           equ 0x09
UP_DIGITIZER        equ 0x0D

; Usages (Generic Desktop)
USAGE_X             equ 0x30
USAGE_Y             equ 0x31

; Usages (Digitizer)
USAGE_TIP_SWITCH    equ 0x42
USAGE_CONTACT_ID    equ 0x51
USAGE_CONTACT_COUNT equ 0x54
USAGE_FINGER        equ 0x22
USAGE_TOUCHPAD      equ 0x05
USAGE_CONFIDENCE    equ 0x47    ; Digitizer Confidence (palm rejection)

; Input item flags
HID_INPUT_CONSTANT  equ (1 << 0)   ; 0=Data, 1=Constant
HID_INPUT_VARIABLE  equ (1 << 1)   ; 0=Array, 1=Variable
HID_INPUT_RELATIVE  equ (1 << 2)   ; 0=Absolute, 1=Relative

; ============================================================================
; hid_parse_report_desc - Parse HID report descriptor
; Input:  RSI = pointer to report descriptor data
;         ECX = length in bytes
; Output: Populates hid_parsed_* fields
;         EAX = 1 if useful fields found, 0 if not
; ============================================================================
global hid_parse_report_desc
hid_parse_report_desc:
    push rbx
    push rcx
    push rdx
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14

    ; Clear all parsed fields
    lea rdi, [hid_parsed_report_id]
    xor eax, eax
    mov ecx, (hid_parsed_end - hid_parsed_report_id)
    rep stosb

    ; Set defaults
    mov byte [hid_parsed_max_contacts], 1
    mov dword [hid_parsed_x_logical_max], 4095
    mov dword [hid_parsed_y_logical_max], 4095

    ; Parser state
    xor r8d, r8d                ; r8  = current usage page
    xor r9d, r9d                ; r9  = current usage
    xor r10d, r10d              ; r10 = logical min
    xor r11d, r11d              ; r11 = logical max
    xor r12d, r12d              ; r12 = report size (bits per field)
    xor r13d, r13d              ; r13 = report count
    xor r14d, r14d              ; r14 = current bit offset in report
    mov word [hp_report_id], 0
    mov byte [hp_in_finger], 0  ; tracking which finger collection
    mov byte [hp_finger_idx], 0 ; finger slot index (0 or 1)
    mov byte [hp_found_fields], 0

    ; RSI = start of descriptor, pop RCX to get length
    pop r14                     ; restore r14 (was pushed)
    push r14
    ; Actually we need the original RCX (length). It was pushed.
    ; Let me restructure - use RBP for end pointer
    mov rbp, rsi
    ; ECX was already modified by rep stosb above.
    ; We need to reload from stack. The original ECX is at [rsp + 48] (6 regs pushed after it)
    ; Actually let me restructure this properly.
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ; Start over with cleaner register usage
    jmp hid_parse_report_desc_v2

hid_parse_report_desc_v2:
    push rbx
    push rcx
    push rdx
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; Clear parsed structure
    push rsi
    push rcx
    lea rdi, [hid_parsed_report_id]
    xor eax, eax
    push rcx
    mov ecx, (hid_parsed_end - hid_parsed_report_id)
    rep stosb
    pop rcx
    pop rcx
    pop rsi
    ; ECX and RSI restored

    ; Set defaults
    mov byte [hid_parsed_max_contacts], 1
    mov dword [hid_parsed_x_logical_max], 4095
    mov dword [hid_parsed_y_logical_max], 4095

    ; RBP = end pointer
    mov rbp, rsi
    add rbp, rcx               ; RBP = past-end pointer

    ; Parser state in memory (registers are too few)
    mov word [hp_usage_page], 0
    mov word [hp_usage], 0
    mov dword [hp_logical_min], 0
    mov dword [hp_logical_max], 0
    mov byte [hp_report_size], 0
    mov byte [hp_report_count], 0
    mov word [hp_report_id], 0
    mov dword [hp_bit_offset], 0
    mov byte [hp_in_finger], 0
    mov byte [hp_finger_idx], 0
    mov byte [hp_found_fields], 0
    mov byte [hid_parsed_conf_bit_size], 0

.parse_loop:
    cmp rsi, rbp
    jge .parse_done

    ; Read item header byte
    movzx eax, byte [rsi]
    inc rsi

    ; Long item? (byte == 0xFE)
    cmp al, 0xFE
    je .skip_long_item

    ; Extract bSize, bType, bTag
    mov ecx, eax
    and ecx, 0x03               ; bSize: 0,1,2,3 (3 means 4 bytes)
    mov edx, eax
    and edx, 0xFC               ; tag+type (mask off size)

    ; Read data value based on bSize
    xor ebx, ebx                ; EBX = data value
    cmp ecx, 0
    je .data_done
    cmp ecx, 1
    je .read_1
    cmp ecx, 2
    je .read_2
    ; bSize=3 means 4 bytes
    cmp rsi, rbp
    jge .parse_done
    movzx ebx, byte [rsi]
    cmp rsi, rbp
    jge .parse_done
    movzx eax, byte [rsi + 1]
    shl eax, 8
    or ebx, eax
    movzx eax, byte [rsi + 2]
    shl eax, 16
    or ebx, eax
    movzx eax, byte [rsi + 3]
    shl eax, 24
    or ebx, eax
    add rsi, 4
    jmp .data_done

.read_2:
    cmp rsi, rbp
    jge .parse_done
    movzx ebx, byte [rsi]
    movzx eax, byte [rsi + 1]
    shl eax, 8
    or ebx, eax
    add rsi, 2
    jmp .data_done

.read_1:
    cmp rsi, rbp
    jge .parse_done
    movzx ebx, byte [rsi]
    inc rsi

.data_done:
    ; EDX = tag+type, EBX = data value, ECX = original bSize

    ; --- Global items ---
    cmp edx, HID_USAGE_PAGE
    je .set_usage_page
    cmp edx, HID_LOGICAL_MIN
    je .set_logical_min
    cmp edx, HID_LOGICAL_MAX
    je .set_logical_max
    cmp edx, HID_REPORT_SIZE
    je .set_report_size
    cmp edx, HID_REPORT_COUNT
    je .set_report_count
    cmp edx, HID_REPORT_ID
    je .set_report_id

    ; --- Local items ---
    cmp edx, HID_USAGE
    je .set_usage

    ; --- Main items ---
    cmp edx, HID_INPUT
    je .process_input
    cmp edx, HID_COLLECTION
    je .process_collection
    cmp edx, HID_END_COLLECTION
    je .process_end_collection

    ; Unknown item - skip
    jmp .parse_loop

.set_usage_page:
    mov [hp_usage_page], bx
    jmp .parse_loop

.set_logical_min:
    ; Sign-extend based on size
    cmp ecx, 1
    jne .lm_not_1
    movsx ebx, bl
.lm_not_1:
    cmp ecx, 2
    jne .lm_not_2
    movsx ebx, bx
.lm_not_2:
    mov [hp_logical_min], ebx
    jmp .parse_loop

.set_logical_max:
    cmp ecx, 1
    jne .lx_not_1
    movsx ebx, bl
.lx_not_1:
    cmp ecx, 2
    jne .lx_not_2
    movsx ebx, bx
.lx_not_2:
    mov [hp_logical_max], ebx
    jmp .parse_loop

.set_report_size:
    mov [hp_report_size], bl
    jmp .parse_loop

.set_report_count:
    mov [hp_report_count], bl
    jmp .parse_loop

.set_report_id:
    mov [hp_report_id], bx
    ; Report ID presence means first byte of report is the ID
    ; Reset bit offset to 0 (ID byte is implicit, not counted in bits)
    ; Actually in HID spec, report ID byte is NOT included in Input field offsets.
    ; The bit offset starts AFTER the report ID byte.
    ; We track this by noting the report has an ID.
    mov byte [hid_parsed_has_report_id], 1
    mov [hid_parsed_report_id], bl
    jmp .parse_loop

.set_usage:
    mov [hp_usage], bx
    jmp .parse_loop

.process_collection:
    ; Check if this is a Finger collection (Usage Page=Digitizer, Usage=Finger)
    cmp word [hp_usage_page], UP_DIGITIZER
    jne .coll_not_finger
    cmp word [hp_usage], USAGE_FINGER
    jne .coll_not_finger
    mov byte [hp_in_finger], 1
    ; Record bit offset at start of this finger block (for stride calculation)
    mov eax, [hp_bit_offset]
    mov [hp_finger_start_offset], eax
    jmp .clear_local
.coll_not_finger:
    ; Check if Touchpad application collection
    cmp word [hp_usage_page], UP_DIGITIZER
    jne .clear_local
    cmp word [hp_usage], USAGE_TOUCHPAD
    jne .clear_local
    mov byte [hid_parsed_is_touchpad], 1
    jmp .clear_local

.process_end_collection:
    cmp byte [hp_in_finger], 1
    jne .clear_local
    mov byte [hp_in_finger], 0
    ; Compute contact stride from this finger block (end - start)
    cmp byte [hp_finger_idx], 0
    jne .end_coll_not_first
    mov eax, [hp_bit_offset]
    sub eax, [hp_finger_start_offset]
    test eax, eax
    jz .end_coll_not_first
    mov [hid_parsed_contact_stride], ax   ; stride in bits for this contact block
.end_coll_not_first:
    ; Advance finger index
    cmp byte [hp_finger_idx], 1
    jge .clear_local
    inc byte [hp_finger_idx]
    jmp .clear_local

.process_input:
    ; EBX = Input item flags
    ; Check if constant (padding) - skip if so
    test ebx, HID_INPUT_CONSTANT
    jnz .advance_bits

    ; This is a data field. Check what usage it corresponds to.
    movzx eax, word [hp_usage_page]
    movzx ecx, word [hp_usage]
    mov edi, [hp_bit_offset]
    movzx r8d, byte [hp_report_size]
    movzx r9d, byte [hp_report_count]

    ; Check if this is absolute or relative
    mov r10d, ebx               ; save input flags
    test ebx, HID_INPUT_RELATIVE
    jnz .input_relative
    mov byte [hp_is_absolute], 1
    jmp .check_field
.input_relative:
    mov byte [hp_is_absolute], 0

.check_field:
    ; --- Button page ---
    cmp eax, UP_BUTTON
    jne .not_button
    ; Buttons: record offset and count
    mov [hid_parsed_btn_bit_offset], di
    mov [hid_parsed_btn_count], r9b
    or byte [hp_found_fields], 0x01
    jmp .advance_bits

.not_button:
    ; --- Generic Desktop page ---
    cmp eax, UP_GENERIC_DESKTOP
    jne .not_generic_desktop

    cmp ecx, USAGE_X
    jne .not_x
    ; X axis - only store for first finger (finger_idx==0) or non-finger context
    cmp byte [hp_in_finger], 1
    je .x_check_finger_idx
    jmp .x_store
.x_check_finger_idx:
    cmp byte [hp_finger_idx], 0
    jne .advance_bits           ; second+ finger: don't overwrite offset0
.x_store:
    mov [hid_parsed_x_bit_offset], di
    mov [hid_parsed_x_bit_size], r8b
    mov eax, [hp_logical_max]
    mov [hid_parsed_x_logical_max], eax
    mov eax, [hp_logical_min]
    mov [hid_parsed_x_logical_min], eax
    cmp byte [hp_is_absolute], 1
    jne .x_relative
    mov byte [hid_parsed_is_absolute], 1
.x_relative:
    or byte [hp_found_fields], 0x02
    jmp .advance_bits

.not_x:
    cmp ecx, USAGE_Y
    jne .not_y
    ; Y axis - only store for first finger
    cmp byte [hp_in_finger], 1
    je .y_check_finger_idx
    jmp .y_store
.y_check_finger_idx:
    cmp byte [hp_finger_idx], 0
    jne .advance_bits
.y_store:
    mov [hid_parsed_y_bit_offset], di
    mov [hid_parsed_y_bit_size], r8b
    mov eax, [hp_logical_max]
    mov [hid_parsed_y_logical_max], eax
    mov eax, [hp_logical_min]
    mov [hid_parsed_y_logical_min], eax
    or byte [hp_found_fields], 0x04
    jmp .advance_bits

.not_y:
    jmp .advance_bits

.not_generic_desktop:
    ; --- Digitizer page ---
    cmp eax, UP_DIGITIZER
    jne .advance_bits

    cmp ecx, USAGE_TIP_SWITCH
    jne .not_tip
    mov [hid_parsed_tip_bit_offset], di
    or byte [hp_found_fields], 0x08
    jmp .advance_bits

.not_tip:
    cmp ecx, USAGE_CONTACT_ID
    jne .not_cid
    mov [hid_parsed_cid_bit_offset], di
    mov [hid_parsed_cid_bit_size], r8b
    jmp .advance_bits

.not_cid:
    cmp ecx, USAGE_CONTACT_COUNT
    jne .not_cc
    mov [hid_parsed_cc_bit_offset], di
    mov [hid_parsed_cc_bit_size], r8b
    or byte [hp_found_fields], 0x10
    jmp .advance_bits

.not_cc:
    cmp ecx, USAGE_CONFIDENCE
    jne .advance_bits
    ; Store offset of confidence bit for first finger only
    cmp byte [hp_finger_idx], 0
    jne .advance_bits
    mov [hid_parsed_conf_bit_offset], di
    mov [hid_parsed_conf_bit_size], r8b
    jmp .advance_bits

.advance_bits:
    ; Advance bit offset by report_size * report_count
    movzx eax, byte [hp_report_size]
    movzx ecx, byte [hp_report_count]
    imul eax, ecx
    add [hp_bit_offset], eax

.clear_local:
    ; Clear local state (usage) after main items
    mov word [hp_usage], 0
    jmp .parse_loop

.skip_long_item:
    ; Long item: next byte is data size, then 1 byte item tag, then data
    cmp rsi, rbp
    jge .parse_done
    movzx ecx, byte [rsi]      ; data size
    add rsi, 2                  ; skip size + tag bytes
    add rsi, rcx                ; skip data
    jmp .parse_loop

.parse_done:
    ; Calculate total report size in bytes
    mov eax, [hp_bit_offset]
    add eax, 7
    shr eax, 3                  ; round up to bytes
    mov [hid_parsed_report_bytes], al

    ; Check if we found enough useful fields
    ; Need at least X and Y
    test byte [hp_found_fields], 0x06
    jz .parse_fail

    mov eax, 1
    jmp .parse_ret

.parse_fail:
    xor eax, eax

.parse_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; hid_extract_field - Extract a field value from a HID report
; Input:  RSI = pointer to report data (after report ID if present)
;         EDI = bit offset of field
;         ESI is NOT modified (uses RSI from stack)
;         R8D = bit size of field (1-32)
; Output: EAX = extracted value (zero-extended)
; ============================================================================
global hid_extract_field
hid_extract_field:
    push rbx
    push rcx
    push rdx
    push rsi

    ; RSI = report data pointer (from stack, original)
    mov rsi, [rsp]              ; get original RSI from push

    ; Calculate byte offset and bit shift
    mov eax, edi
    shr eax, 3                  ; byte offset = bit_offset / 8
    add rsi, rax                ; point to starting byte

    mov ecx, edi
    and ecx, 7                  ; bit shift within byte = bit_offset % 8

    ; Read up to 4 bytes starting from this position
    xor eax, eax
    movzx edx, byte [rsi]
    mov eax, edx
    cmp r8d, 8
    jle .shift
    movzx edx, byte [rsi + 1]
    shl edx, 8
    or eax, edx
    cmp r8d, 16
    jle .shift
    movzx edx, byte [rsi + 2]
    shl edx, 16
    or eax, edx
    cmp r8d, 24
    jle .shift
    movzx edx, byte [rsi + 3]
    shl edx, 24
    or eax, edx

.shift:
    ; Shift right by bit offset within byte
    shr eax, cl

    ; Mask to field size
    mov ecx, r8d
    cmp ecx, 32
    jge .no_mask
    mov edx, 1
    shl edx, cl
    dec edx                     ; mask = (1 << size) - 1
    and eax, edx
.no_mask:

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; hid_extract_field_signed - Extract a signed field value
; Same as hid_extract_field but sign-extends the result
; ============================================================================
global hid_extract_field_signed
hid_extract_field_signed:
    push rcx
    call hid_extract_field

    ; Sign extend: if bit (size-1) is set, OR with upper bits
    mov ecx, r8d
    dec ecx                     ; bit position of sign bit
    bt eax, ecx
    jnc .positive
    ; Sign extend
    inc ecx                     ; back to size
    cmp ecx, 32
    jge .positive
    mov edx, 0xFFFFFFFF
    shl edx, cl
    or eax, edx
.positive:
    pop rcx
    ret

; ============================================================================
; hid_process_touchpad_report - Process a parsed touchpad report
; Uses hid_parsed_* layout to extract fields and update mouse state.
; Input:  RSI = report data (past report ID byte if present)
;         ECX = report data length
; Output: Updates mouse_x, mouse_y, mouse_buttons, mouse_moved, mouse_scroll_y
; ============================================================================
global hid_process_touchpad_report
hid_process_touchpad_report:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12

    mov rbp, rsi                ; RBP = report data

    ; --- Extract contact count ---
    xor r10d, r10d              ; default contact count = 0
    cmp byte [hid_parsed_cc_bit_size], 0
    je .no_contact_count
    mov rsi, rbp
    mov edi, [hid_parsed_cc_bit_offset]
    movzx r8d, byte [hid_parsed_cc_bit_size]
    call hid_extract_field
    mov r10d, eax               ; R10 = contact count
.no_contact_count:

    ; --- Palm rejection: skip report if Confidence bit = 0 ---
    cmp byte [hid_parsed_conf_bit_size], 0
    je .conf_ok
    mov rsi, rbp
    movzx edi, word [hid_parsed_conf_bit_offset]
    movzx r8d, byte [hid_parsed_conf_bit_size]
    call hid_extract_field
    test eax, eax
    jz .no_xy                   ; confidence=0 → palm touch, skip entire report
.conf_ok:

    ; --- Extract tip switch ---
    xor r11d, r11d              ; default tip = 0
    test byte [hp_found_fields], 0x08
    jz .no_tip
    mov rsi, rbp
    movzx edi, word [hid_parsed_tip_bit_offset]
    mov r8d, 1
    call hid_extract_field
    mov r11d, eax               ; R11 = tip switch
.no_tip:

    ; --- Extract buttons ---
    xor r12d, r12d              ; default buttons = 0
    test byte [hp_found_fields], 0x01
    jz .no_buttons
    mov rsi, rbp
    movzx edi, word [hid_parsed_btn_bit_offset]
    movzx r8d, byte [hid_parsed_btn_count]
    cmp r8d, 3
    jle .btn_size_ok
    mov r8d, 3                  ; cap at 3 buttons
.btn_size_ok:
    call hid_extract_field
    mov r12d, eax
.no_buttons:

    ; Combine buttons with tip switch (tip = left click if no buttons)
    test r12d, r12d
    jnz .has_buttons
    ; No physical buttons pressed - use tip as left click
    mov r12d, r11d
.has_buttons:

    ; --- Extract X ---
    mov rsi, rbp
    movzx edi, word [hid_parsed_x_bit_offset]
    movzx r8d, byte [hid_parsed_x_bit_size]
    test r8d, r8d
    jz .no_xy

    cmp byte [hid_parsed_is_absolute], 1
    je .extract_absolute_x
    ; Relative X
    call hid_extract_field_signed
    mov [hid_rel_x], eax
    jmp .extract_y

.extract_absolute_x:
    call hid_extract_field
    mov [hid_abs_x], eax
    jmp .extract_y

.extract_y:
    mov rsi, rbp
    movzx edi, word [hid_parsed_y_bit_offset]
    movzx r8d, byte [hid_parsed_y_bit_size]

    cmp byte [hid_parsed_is_absolute], 1
    je .extract_absolute_y
    ; Relative Y
    call hid_extract_field_signed
    mov [hid_rel_y], eax
    jmp .apply_movement

.extract_absolute_y:
    call hid_extract_field
    mov [hid_abs_y], eax

.apply_movement:
    ; --- Extract second-finger Y for accurate two-finger scroll ---
    ; When contact count >= 2 and stride > 0, sample finger 1's position
    cmp r10d, 2
    jl .no_second_finger
    movzx eax, word [hid_parsed_contact_stride]
    test eax, eax
    jz .no_second_finger
    cmp byte [hid_parsed_is_absolute], 1
    jne .no_second_finger
    ; finger1_y_offset = y_bit_offset + stride
    movzx edi, word [hid_parsed_y_bit_offset]
    add edi, eax                ; + stride bits
    movzx r8d, byte [hid_parsed_y_bit_size]
    test r8d, r8d
    jz .no_second_finger
    call hid_extract_field
    ; Scale finger1_y to screen space same as finger0
    mov ecx, [hid_parsed_y_logical_max]
    sub ecx, [hid_parsed_y_logical_min]
    test ecx, ecx
    jz .no_second_finger
    sub eax, [hid_parsed_y_logical_min]
    jns .f1y_pos
    xor eax, eax
.f1y_pos:
    imul eax, [scr_height]
    xor edx, edx
    div ecx
    ; Average with finger0 Y for more stable tracking
    mov ecx, [mouse_y]
    add eax, ecx
    shr eax, 1
    mov [hid_f1_avg_y], eax     ; store averaged Y for gesture

    ; Also extract finger1 X for pinch detection
    movzx edi, word [hid_parsed_x_bit_offset]
    movzx eax, word [hid_parsed_contact_stride]
    add edi, eax                ; finger1_x_offset = x_bit_offset + stride
    movzx r8d, byte [hid_parsed_x_bit_size]
    test r8d, r8d
    jz .no_second_finger
    call hid_extract_field
    ; Scale to screen X
    mov ecx, [hid_parsed_x_logical_max]
    sub ecx, [hid_parsed_x_logical_min]
    test ecx, ecx
    jz .no_second_finger
    sub eax, [hid_parsed_x_logical_min]
    jns .f1x_pos
    xor eax, eax
.f1x_pos:
    imul eax, [scr_width]
    xor edx, edx
    div ecx
    mov [hid_f1_x], eax         ; finger1 screen X

.no_second_finger:

    ; --- Update gesture engine ---
    mov edi, r10d               ; contact count
    mov esi, r11d               ; tip switch
    call gesture_update

    ; --- Apply position updates ---
    cmp byte [hid_parsed_is_absolute], 1
    je .apply_absolute

    ; --- Relative mode ---
    mov eax, [hid_rel_x]
    ; Apply sensitivity (divide by 2 for touchpads, keep as-is for mice)
    cmp byte [hid_parsed_is_touchpad], 1
    jne .rel_no_scale
    sar eax, 1
.rel_no_scale:
    add [mouse_x], eax

    mov eax, [hid_rel_y]
    cmp byte [hid_parsed_is_touchpad], 1
    jne .rel_no_scale_y
    sar eax, 1
.rel_no_scale_y:
    add [mouse_y], eax
    jmp .clamp_coords

.apply_absolute:
    ; Scale absolute X to screen width
    ; screen_x = (abs_x - logical_min) * scr_width / (logical_max - logical_min)
    mov eax, [hid_abs_x]
    sub eax, [hid_parsed_x_logical_min]
    jns .abs_x_pos
    xor eax, eax
.abs_x_pos:
    imul eax, [scr_width]
    mov ecx, [hid_parsed_x_logical_max]
    sub ecx, [hid_parsed_x_logical_min]
    test ecx, ecx
    jz .clamp_coords
    xor edx, edx
    div ecx
    mov [mouse_x], eax

    ; Scale absolute Y
    mov eax, [hid_abs_y]
    sub eax, [hid_parsed_y_logical_min]
    jns .abs_y_pos
    xor eax, eax
.abs_y_pos:
    imul eax, [scr_height]
    mov ecx, [hid_parsed_y_logical_max]
    sub ecx, [hid_parsed_y_logical_min]
    test ecx, ecx
    jz .clamp_coords
    xor edx, edx
    div ecx
    mov [mouse_y], eax

.clamp_coords:
    ; Clamp X to [0, scr_width-1]
    cmp dword [mouse_x], 0
    jge .clamp_x_min_ok
    mov dword [mouse_x], 0
.clamp_x_min_ok:
    mov eax, [scr_width]
    dec eax
    cmp [mouse_x], eax
    jle .clamp_x_max_ok
    mov [mouse_x], eax
.clamp_x_max_ok:

    ; Clamp Y to [0, scr_height-1]
    cmp dword [mouse_y], 0
    jge .clamp_y_min_ok
    mov dword [mouse_y], 0
.clamp_y_min_ok:
    mov eax, [scr_height]
    dec eax
    cmp [mouse_y], eax
    jle .clamp_y_max_ok
    mov [mouse_y], eax
.clamp_y_max_ok:

    ; --- Update buttons (gesture engine may override for taps) ---
    ; Check if gesture engine generated a tap click
    cmp byte [gesture_tap_click], 0
    je .no_tap_click
    or r12d, 1                  ; Force left button
    mov byte [gesture_tap_click], 0
.no_tap_click:
    mov [mouse_buttons], r12b

    ; --- Set moved flag ---
    mov byte [mouse_moved], 1

.no_xy:
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; gesture_update - Update gesture detection state machine
; Input:  EDI = contact count (0-10)
;         ESI = tip switch (0 or 1)
; Called once per touchpad report from hid_process_touchpad_report.
; ============================================================================
global gesture_update
gesture_update:
    push rax
    push rbx
    push rcx
    push rdx

    mov eax, edi                ; contact count
    mov ecx, esi                ; tip switch

    ; --- Tap-to-click detection ---
    ; Transition: 0 contacts -> 1 contact = finger down
    cmp byte [gesture_prev_count], 0
    jne .not_tap_start
    cmp eax, 1
    jne .not_tap_start
    ; Finger just touched - record start
    mov rbx, [tick_count]
    mov [gesture_tap_start_tick], rbx
    mov ebx, [mouse_x]
    mov [gesture_tap_start_x], ebx
    mov ebx, [mouse_y]
    mov [gesture_tap_start_y], ebx
    mov byte [gesture_tap_pending], 1
    jmp .check_scroll

.not_tap_start:
    ; Transition: 1 contact -> 0 contacts = finger lifted
    cmp byte [gesture_prev_count], 1
    jne .not_tap_end
    cmp eax, 0
    jne .not_tap_end
    cmp byte [gesture_tap_pending], 0
    je .not_tap_end

    ; Finger lifted - check if it's a tap
    mov byte [gesture_tap_pending], 0
    mov rbx, [tick_count]
    sub rbx, [gesture_tap_start_tick]
    cmp rbx, 25                 ; < 250ms (25 ticks at 100Hz)
    jg .not_tap_end

    ; Check distance moved
    mov ebx, [mouse_x]
    sub ebx, [gesture_tap_start_x]
    ; abs(ebx)
    test ebx, ebx
    jns .tap_dx_pos
    neg ebx
.tap_dx_pos:
    cmp ebx, 20
    jg .not_tap_end

    mov ebx, [mouse_y]
    sub ebx, [gesture_tap_start_y]
    test ebx, ebx
    jns .tap_dy_pos
    neg ebx
.tap_dy_pos:
    cmp ebx, 20
    jg .not_tap_end

    ; It's a tap! Generate click
    mov byte [gesture_tap_click], 1
    jmp .check_scroll

.not_tap_end:
    ; If contact count > 1, cancel tap
    cmp eax, 1
    jle .check_scroll
    mov byte [gesture_tap_pending], 0

.check_scroll:
    ; --- Two-finger scroll detection ---
    ; Transition: anything -> 2 contacts = start scroll
    cmp eax, 2
    jne .not_scroll_active

    cmp byte [gesture_scroll_active], 1
    je .scroll_continue

    ; Start scrolling - use averaged two-finger Y if available, else mouse_y
    mov byte [gesture_scroll_active], 1
    mov ebx, [hid_f1_avg_y]
    test ebx, ebx
    jnz .scroll_start_ref
    mov ebx, [mouse_y]
.scroll_start_ref:
    mov [gesture_scroll_ref_y], ebx
    mov ebx, [mouse_x]
    mov [gesture_scroll_ref_x], ebx
    jmp .gesture_done

.scroll_continue:
    ; Compute scroll delta using best available position
    mov ebx, [hid_f1_avg_y]
    test ebx, ebx
    jnz .scroll_use_avg
    mov ebx, [mouse_y]
.scroll_use_avg:
    sub ebx, [gesture_scroll_ref_y]
    ; Scale: divide by 8 for smoother scrolling
    sar ebx, 3
    mov [mouse_scroll_y], ebx

    ; Update reference
    mov ebx, [hid_f1_avg_y]
    test ebx, ebx
    jnz .scroll_ref_avg
    mov ebx, [mouse_y]
.scroll_ref_avg:
    mov [gesture_scroll_ref_y], ebx
    jmp .gesture_done

.not_scroll_active:
    ; If we were scrolling and contact count dropped, stop
    cmp byte [gesture_scroll_active], 1
    jne .check_pinch
    mov byte [gesture_scroll_active], 0
    mov dword [mouse_scroll_y], 0

.check_pinch:
    ; --- Pinch-to-zoom: 2 fingers, compute Manhattan distance delta ---
    cmp eax, 2
    jne .check_3finger
    ; Manhattan distance = |f0x - f1x| + |f0y - f1y|
    mov ebx, [mouse_x]
    sub ebx, [hid_f1_x]
    test ebx, ebx
    jns .pinch_dx_pos
    neg ebx
.pinch_dx_pos:
    mov ecx, [hid_f1_avg_y]
    test ecx, ecx
    jz .check_3finger           ; no finger1 data
    mov edx, [mouse_y]
    sub edx, ecx
    test edx, edx
    jns .pinch_dy_pos
    neg edx
.pinch_dy_pos:
    add ebx, edx                ; ebx = current distance
    ; Compute delta vs previous distance
    mov edx, [gesture_pinch_dist_prev]
    mov [gesture_pinch_dist_prev], ebx
    test edx, edx
    jz .check_3finger           ; no previous sample
    sub ebx, edx                ; ebx = distance delta (positive=zoom in)
    ; Apply threshold to reduce noise (ignore if < 8 pixels)
    mov ecx, ebx
    test ecx, ecx
    jns .pinch_delta_pos
    neg ecx
.pinch_delta_pos:
    cmp ecx, 8
    jl .check_3finger
    sar ebx, 2                  ; scale down
    mov [mouse_pinch_delta], ebx
    jmp .gesture_done

.check_3finger:
    ; Clear pinch distance when not 2 fingers
    cmp eax, 2
    je .gesture_done
    mov dword [gesture_pinch_dist_prev], 0
    mov dword [mouse_pinch_delta], 0

    ; --- 3-finger swipe detection ---
    cmp eax, 3
    jne .gesture_done
    ; Use finger0 X motion vs reference to detect swipe direction
    cmp byte [gesture_scroll_active], 1
    je .gesture_done            ; don't swipe while scroll active
    mov ebx, [mouse_x]
    mov ecx, [gesture_scroll_ref_x]
    test ecx, ecx
    jz .swipe_set_ref           ; first frame with 3 fingers
    sub ebx, ecx                ; ebx = X delta from ref
    ; Threshold: > 40px horizontal motion = swipe
    cmp ebx, 40
    jge .swipe_right
    cmp ebx, -40
    jle .swipe_left
    jmp .gesture_done
.swipe_right:
    mov byte [gesture_swipe_dir], 1
    mov ebx, [mouse_x]
    mov [gesture_scroll_ref_x], ebx
    jmp .gesture_done
.swipe_left:
    mov byte [gesture_swipe_dir], -1
    mov ebx, [mouse_x]
    mov [gesture_scroll_ref_x], ebx
    jmp .gesture_done
.swipe_set_ref:
    mov [gesture_scroll_ref_x], ebx
    mov byte [gesture_swipe_dir], 0

.gesture_done:
    ; Save current contact count as previous
    mov [gesture_prev_count], al

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Data Section
; ============================================================================
section .data

; --- Parser temporary state ---
hp_usage_page:      dw 0
hp_usage:           dw 0
hp_logical_min:     dd 0
hp_logical_max:     dd 0
hp_report_size:     db 0
hp_report_count:    db 0
hp_report_id:       dw 0
hp_bit_offset:      dd 0
hp_in_finger:           db 0
hp_finger_idx:          db 0
hp_found_fields:        db 0    ; bitmask: 1=buttons, 2=X, 4=Y, 8=tip, 16=contact_count
hp_is_absolute:         db 0
hp_finger_start_offset: dd 0   ; bit offset at start of current finger collection

; --- Parsed report descriptor results ---
global hid_parsed_report_id
global hid_parsed_has_report_id
global hid_parsed_is_absolute
global hid_parsed_is_touchpad
global hid_parsed_report_bytes
global hid_parsed_x_bit_offset, hid_parsed_x_bit_size
global hid_parsed_y_bit_offset, hid_parsed_y_bit_size
global hid_parsed_x_logical_min, hid_parsed_x_logical_max
global hid_parsed_y_logical_min, hid_parsed_y_logical_max
global hid_parsed_btn_bit_offset, hid_parsed_btn_count
global hid_parsed_tip_bit_offset
global hid_parsed_cid_bit_offset, hid_parsed_cid_bit_size
global hid_parsed_cc_bit_offset, hid_parsed_cc_bit_size
global hid_parsed_max_contacts
global hid_parsed_contact_stride

hid_parsed_report_id:       db 0
hid_parsed_has_report_id:   db 0
hid_parsed_is_absolute:     db 0
hid_parsed_is_touchpad:     db 0
hid_parsed_report_bytes:    db 0

hid_parsed_x_bit_offset:   dw 0
hid_parsed_x_bit_size:     db 0
hid_parsed_y_bit_offset:   dw 0
hid_parsed_y_bit_size:     db 0
hid_parsed_x_logical_min:  dd 0
hid_parsed_x_logical_max:  dd 4095
hid_parsed_y_logical_min:  dd 0
hid_parsed_y_logical_max:  dd 4095

hid_parsed_btn_bit_offset: dw 0
hid_parsed_btn_count:      db 0

hid_parsed_tip_bit_offset: dw 0
hid_parsed_cid_bit_offset: dw 0
hid_parsed_cid_bit_size:   db 0
hid_parsed_cc_bit_offset:  dw 0
hid_parsed_cc_bit_size:    db 0
hid_parsed_max_contacts:    db 1
hid_parsed_contact_stride:  dw 0    ; bits between contacts in multi-touch report
hid_parsed_conf_bit_offset: dw 0    ; bit offset of Confidence field (palm rejection)
hid_parsed_conf_bit_size:   db 0    ; bit size of Confidence field (0=not present)
hid_parsed_end:

; --- Gesture engine state ---
global gesture_tap_click
global mouse_scroll_y

gesture_prev_count:         db 0
gesture_tap_start_tick:     dq 0
gesture_tap_start_x:        dd 0
gesture_tap_start_y:        dd 0
gesture_tap_pending:        db 0
gesture_tap_click:          db 0
gesture_scroll_active:      db 0
gesture_scroll_ref_y:       dd 0
gesture_scroll_ref_x:       dd 0
gesture_pinch_dist_prev:    dd 0    ; previous pinch distance for delta
gesture_swipe_dir:          db 0    ; 1=right, -1=left, 0=none (3-finger swipe)

global mouse_pinch_delta
mouse_pinch_delta:          dd 0    ; pinch zoom delta (+zoom in, -zoom out)
mouse_scroll_y:             dd 0    ; vertical scroll delta (shared global)

; --- Temporary extraction values ---
hid_abs_x:  dd 0
hid_abs_y:  dd 0
hid_rel_x:  dd 0
hid_rel_y:  dd 0
hid_f1_avg_y: dd 0
hid_f1_x:   dd 0            ; finger1 screen X for pinch detection

; Externs
extern mouse_x, mouse_y
extern scr_width, scr_height
