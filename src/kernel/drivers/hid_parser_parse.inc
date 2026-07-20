; ============================================================================
; hid_parse_report_desc - Parse HID report descriptor
; Input:  RSI = pointer to report descriptor data
;         ECX = length in bytes
; Output: Populates hid_parsed_* fields
;         EAX = 1 if useful fields found, 0 if not
; ============================================================================
; auto-wrapped (FN_BEGIN emits global): global hid_parse_report_desc
FN_BEGIN hid_parse_report_desc, 0, 0, FN_RET_SCALAR
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
    ; Contract is ECX = length (32-bit). Defensively zero-extend so a future
    ; caller that leaves garbage in the upper 32 bits of RCX cannot push the
    ; past-end pointer beyond the buffer and defeat every bounds check below.
    mov ecx, ecx               ; zero-extend ECX -> RCX
    mov rbp, rsi
    add rbp, rcx               ; RBP = past-end pointer
    jc .parse_fail             ; length so large rsi+len wraps -> reject

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
    mov byte [hp_usage_count], 0
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
    ; Guard all rsi+1/rsi+2/rsi+3 reads with a remaining-length check.
    lea rax, [rsi + 4]
    cmp rax, rbp
    ja .parse_done
    movzx ebx, byte [rsi]
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
    ; Guard rsi+1 reads with a remaining-length check.
    lea rax, [rsi + 2]
    cmp rax, rbp
    ja .parse_done
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
    ; Reset bit offset to 0: HID report IDs have independent layouts, and
    ; the ID byte is implicit, not counted in Input field offsets.
    mov dword [hp_bit_offset], 0
    mov byte [hid_parsed_has_report_id], 1
    mov [hid_parsed_report_id], bl
    jmp .parse_loop

.set_usage:
    mov [hp_usage], bx
    movzx eax, byte [hp_usage_count]
    cmp eax, HP_USAGE_LIST_MAX
    jae .set_usage_done
    mov [hp_usage_list + rax * 2], bx
    inc byte [hp_usage_count]
.set_usage_done:
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

    ; HID descriptors commonly declare Usage X, Usage Y, then one Input with
    ; Report Count=2. Record each usage at its own field offset.
    cmp byte [hp_usage_count], 1
    jbe .generic_single_usage

    xor r11d, r11d
.generic_usage_loop:
    cmp r11b, [hp_usage_count]
    jae .advance_bits
    cmp r11d, r9d
    jae .advance_bits

    movzx ecx, word [hp_usage_list + r11 * 2]
    mov eax, r11d
    imul eax, r8d
    mov edi, [hp_bit_offset]
    add edi, eax

    cmp ecx, USAGE_X
    je .x_multi_store
    cmp ecx, USAGE_Y
    je .y_multi_store
.generic_usage_next:
    inc r11d
    jmp .generic_usage_loop

.x_multi_store:
    cmp byte [hp_in_finger], 1
    jne .x_multi_ok
    cmp byte [hp_finger_idx], 0
    jne .generic_usage_next
.x_multi_ok:
    mov [hid_parsed_x_bit_offset], di
    mov [hid_parsed_x_bit_size], r8b
    mov eax, [hp_logical_max]
    mov [hid_parsed_x_logical_max], eax
    mov eax, [hp_logical_min]
    mov [hid_parsed_x_logical_min], eax
    cmp byte [hp_is_absolute], 1
    jne .x_multi_relative
    mov byte [hid_parsed_is_absolute], 1
.x_multi_relative:
    or byte [hp_found_fields], 0x02
    jmp .generic_usage_next

.y_multi_store:
    cmp byte [hp_in_finger], 1
    jne .y_multi_ok
    cmp byte [hp_finger_idx], 0
    jne .generic_usage_next
.y_multi_ok:
    mov [hid_parsed_y_bit_offset], di
    mov [hid_parsed_y_bit_size], r8b
    mov eax, [hp_logical_max]
    mov [hid_parsed_y_logical_max], eax
    mov eax, [hp_logical_min]
    mov [hid_parsed_y_logical_min], eax
    or byte [hp_found_fields], 0x04
    jmp .generic_usage_next

.generic_single_usage:
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
    jo .parse_fail
    mov edx, [hp_bit_offset]
    add edx, eax
    jc .parse_fail
    cmp edx, HID_MAX_REPORT_BITS
    ja .parse_fail
    mov [hp_bit_offset], edx

.clear_local:
    ; Clear local state (usage) after main items
    mov word [hp_usage], 0
    mov byte [hp_usage_count], 0
    jmp .parse_loop

.skip_long_item:
    ; Long item: next byte is data size, then 1 byte item tag, then data
    ; Require both size and tag bytes before skipping the payload.
    lea rax, [rsi + 2]
    cmp rax, rbp
    ja .parse_done
    movzx ecx, byte [rsi]      ; data size
    add rsi, 2                  ; skip size + tag bytes
    mov rax, rsi
    add rax, rcx
    jc .parse_done
    cmp rax, rbp
    ja .parse_done
    add rsi, rcx                ; skip data
    jmp .parse_loop

.parse_done:
    ; Calculate total report size in bytes
    mov eax, [hp_bit_offset]
    add eax, 7
    jc .parse_fail
    shr eax, 3                  ; round up to bytes
    cmp eax, MOUSE_BUFFER_SIZE
    ja .parse_fail
    mov [hid_parsed_report_bytes], al

    ; Check if we found enough useful fields: both X and Y are required.
    ; Accepting a single axis makes touchpads appear to move only horizontally
    ; or vertically when a descriptor was only partially parsed.
    mov al, [hp_found_fields]
    and al, 0x06
    cmp al, 0x06
    jne .parse_fail

    ; Absolute coordinates are scaled by (logical_max-logical_min). Reject a
    ; non-positive range at descriptor admission so no report can reach idiv
    ; with zero or -1 (including the INT_MIN/-1 #DE case).
    cmp byte [hid_parsed_is_absolute], 1
    jne .range_ok
    mov eax, [hid_parsed_x_logical_max]
    cmp eax, [hid_parsed_x_logical_min]
    jle .parse_fail
    mov eax, [hid_parsed_y_logical_max]
    cmp eax, [hid_parsed_y_logical_min]
    jle .parse_fail
.range_ok:

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
