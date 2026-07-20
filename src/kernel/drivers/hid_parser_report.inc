; hid_process_touchpad_report - Process a parsed touchpad report
; Uses hid_parsed_* layout to extract fields and update mouse state.
; Input:  RSI = report data (past report ID byte if present)
;         ECX = report data length
; Output: Updates mouse_x, mouse_y, mouse_buttons, mouse_moved, mouse_scroll_y
; ============================================================================
; auto-wrapped (FN_BEGIN emits global): global hid_process_touchpad_report
FN_BEGIN hid_process_touchpad_report, 0, 0, FN_RET_SCALAR
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
    push r13

    mov rbp, rsi                ; RBP = report data
    mov r13d, ecx               ; R13D = actual report data length

    ; --- Extract contact count ---
    xor r10d, r10d              ; default contact count = 0
    cmp byte [hid_parsed_cc_bit_size], 0
    je .no_contact_count
    mov rsi, rbp
    mov ecx, r13d
    mov edi, [hid_parsed_cc_bit_offset]
    movzx r8d, byte [hid_parsed_cc_bit_size]
    call hid_extract_field_checked
    jc .no_xy
    mov r10d, eax               ; R10 = contact count
.no_contact_count:

    ; --- Palm rejection: skip report if Confidence bit = 0 ---
    cmp byte [hid_parsed_conf_bit_size], 0
    je .conf_ok
    mov rsi, rbp
    mov ecx, r13d
    movzx edi, word [hid_parsed_conf_bit_offset]
    movzx r8d, byte [hid_parsed_conf_bit_size]
    call hid_extract_field_checked
    jc .no_xy
    test eax, eax
    jz .no_xy                   ; confidence=0 → palm touch, skip entire report
.conf_ok:

    ; --- Extract tip switch ---
    xor r11d, r11d              ; default tip = 0
    test byte [hp_found_fields], 0x08
    jz .no_tip
    mov rsi, rbp
    mov ecx, r13d
    movzx edi, word [hid_parsed_tip_bit_offset]
    mov r8d, 1
    call hid_extract_field_checked
    jc .no_xy
    mov r11d, eax               ; R11 = tip switch
.no_tip:
    cmp byte [hid_parsed_cc_bit_size], 0
    jne .contact_count_ready
    test r11d, r11d
    jz .contact_count_ready
    mov r10d, 1
.contact_count_ready:

    ; --- Extract buttons ---
    xor r12d, r12d              ; default buttons = 0
    test byte [hp_found_fields], 0x01
    jz .no_buttons
    mov rsi, rbp
    mov ecx, r13d
    movzx edi, word [hid_parsed_btn_bit_offset]
    movzx r8d, byte [hid_parsed_btn_count]
    cmp r8d, 3
    jle .btn_size_ok
    mov r8d, 3                  ; cap at 3 buttons
.btn_size_ok:
    call hid_extract_field_checked
    jc .no_xy
    mov r12d, eax
.no_buttons:

    ; Combine buttons with tip switch (tip = left click if no buttons)
    test r12d, r12d
    jnz .has_buttons
    ; No physical buttons pressed - use tip as left click
    mov r12d, r11d
.has_buttons:

    cmp r10d, 0
    jne .extract_xy
    mov byte [hid_abs_prev_valid], 0
    mov edi, r10d
    mov esi, r11d
    call gesture_update
    cmp byte [gesture_tap_click], 0
    je .zero_contact_buttons
    or r12d, 1
    mov byte [gesture_tap_click], 0
.zero_contact_buttons:
    mov [mouse_buttons], r12b
    jmp .no_xy

    ; --- Extract X ---
.extract_xy:
    mov rsi, rbp
    mov ecx, r13d
    movzx edi, word [hid_parsed_x_bit_offset]
    movzx r8d, byte [hid_parsed_x_bit_size]
    test r8d, r8d
    jz .no_xy

    cmp byte [hid_parsed_is_absolute], 1
    je .extract_absolute_x
    ; Relative X
    call hid_extract_field_signed_checked
    jc .no_xy
    mov [hid_rel_x], eax
    jmp .extract_y

.extract_absolute_x:
    call hid_extract_field_checked
    jc .no_xy
    mov [hid_abs_x], eax
    jmp .extract_y

.extract_y:
    mov rsi, rbp
    mov ecx, r13d
    movzx edi, word [hid_parsed_y_bit_offset]
    movzx r8d, byte [hid_parsed_y_bit_size]

    cmp byte [hid_parsed_is_absolute], 1
    je .extract_absolute_y
    ; Relative Y
    call hid_extract_field_signed_checked
    jc .no_xy
    mov [hid_rel_y], eax
    jmp .apply_movement

.extract_absolute_y:
    call hid_extract_field_checked
    jc .no_xy
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
    mov rsi, rbp
    mov ecx, r13d
    call hid_extract_field_checked
    jc .no_xy
    ; Scale finger1_y to screen space same as finger0
    mov ecx, [hid_parsed_y_logical_max]
    sub ecx, [hid_parsed_y_logical_min]
    cmp ecx, 0
    jle .no_second_finger
    sub eax, [hid_parsed_y_logical_min]
    jns .f1y_pos
    xor eax, eax
.f1y_pos:
    imul eax, [scr_height]
    xor edx, edx
    cmp ecx, 0
    jle .no_second_finger
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
    mov rsi, rbp
    mov ecx, r13d
    call hid_extract_field_checked
    jc .no_xy
    ; Scale to screen X
    mov ecx, [hid_parsed_x_logical_max]
    sub ecx, [hid_parsed_x_logical_min]
    cmp ecx, 0
    jle .no_second_finger
    sub eax, [hid_parsed_x_logical_min]
    jns .f1x_pos
    xor eax, eax
.f1x_pos:
    imul eax, [scr_width]
    xor edx, edx
    cmp ecx, 0
    jle .no_second_finger
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
    cmp byte [hid_parsed_is_touchpad], 1
    je .apply_absolute_touchpad

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
    cmp ecx, 0
    jle .clamp_coords
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
    cmp ecx, 0
    jle .clamp_coords
    xor edx, edx
    div ecx
    mov [mouse_y], eax
    jmp .clamp_coords

.apply_absolute_touchpad:
    cmp byte [hid_abs_prev_valid], 1
    je .abs_touchpad_have_prev
    mov eax, [hid_abs_x]
    mov [hid_abs_prev_x], eax
    mov eax, [hid_abs_y]
    mov [hid_abs_prev_y], eax
    mov byte [hid_abs_prev_valid], 1
    jmp .clamp_coords

.abs_touchpad_have_prev:
    ; Convert absolute touchpad samples into relative cursor deltas. Directly
    ; mapping the finger position to screen coordinates makes the pointer jump.
    mov eax, [hid_abs_x]
    mov ebx, eax
    sub eax, [hid_abs_prev_x]
    mov [hid_abs_prev_x], ebx
    mov ecx, [hid_parsed_x_logical_max]
    sub ecx, [hid_parsed_x_logical_min]
    cmp ecx, 0
    jle .abs_touchpad_y
    imul eax, [scr_width]
    cdq
    idiv ecx
    add [mouse_x], eax

.abs_touchpad_y:
    mov eax, [hid_abs_y]
    mov ebx, eax
    sub eax, [hid_abs_prev_y]
    mov [hid_abs_prev_y], ebx
    mov ecx, [hid_parsed_y_logical_max]
    sub ecx, [hid_parsed_y_logical_min]
    cmp ecx, 0
    jle .clamp_coords
    imul eax, [scr_height]
    cdq
    idiv ecx
    add [mouse_y], eax

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
    pop r13
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

