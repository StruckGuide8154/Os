; ============================================================================
; Grit v3.0 - Structure Definitions
; ============================================================================

; --- Window structure (256 bytes) ---
struc window_t
    .id:            resd 1      ; 0x00: Unique window ID
    .x:             resd 1      ; 0x04: Position X
    .y:             resd 1      ; 0x08: Position Y
    .w:             resd 1      ; 0x0C: Total width (including border)
    .h:             resd 1      ; 0x10: Total height (including titlebar+border)
    .client_x:      resd 1      ; 0x14: Client area X offset from window
    .client_y:      resd 1      ; 0x18: Client area Y offset from window
    .client_w:      resd 1      ; 0x1C: Client area width
    .client_h:      resd 1      ; 0x20: Client area height
    .flags:         resd 1      ; 0x24: WF_* flags
    .z_order:       resd 1      ; 0x28: Z-order (higher = on top)
                    resd 1      ; 0x2C: padding
    .title:         resq 1      ; 0x30: Pointer to title string
    .draw_fn:       resq 1      ; 0x38: App draw callback (rdi=window_ptr)
    .key_fn:        resq 1      ; 0x40: App keypress callback (rdi=window_ptr, esi=key)
    .click_fn:      resq 1      ; 0x48: App click callback (rdi=window_ptr, esi=x, edx=y)
    .app_data:      resq 1      ; 0x50: App-private data pointer
    .drag_ox:       resd 1      ; 0x58: Drag offset X (mouse_x - window_x at drag start)
    .drag_oy:       resd 1      ; 0x5C: Drag offset Y
    .padding:       resb 160    ; Pad to 256 bytes
endstruc

; --- Key event (4 bytes) ---
struc key_event_t
    .scancode:      resb 1      ; Raw scancode
    .ascii:         resb 1      ; ASCII translation (0 if special key)
    .modifiers:     resb 1      ; KMOD_* flags
    .pressed:       resb 1      ; 1=pressed, 0=released
endstruc

; --- Mouse event (16 bytes) ---
struc mouse_event_t
    .x:             resd 1      ; Absolute cursor X
    .y:             resd 1      ; Absolute cursor Y
    .buttons:       resb 1      ; Button state (bit0=left, bit1=right, bit2=middle)
    .event_type:    resb 1      ; MEVT_* type
    .padding:       resb 6      ; Pad to 16 bytes
endstruc

; --- Rectangle (16 bytes) ---
struc rect_t
    .x:             resd 1
    .y:             resd 1
    .w:             resd 1
    .h:             resd 1
endstruc

; --- E820 memory map entry (24 bytes) ---
struc e820_entry_t
    .base:          resq 1      ; Base address
    .length:        resq 1      ; Length in bytes
    .type:          resd 1      ; 1=usable, 2=reserved, 3=ACPI reclaimable
    .acpi:          resd 1      ; ACPI extended attributes
endstruc
; --- Process structure (512 bytes) ---
struc process_t
    .rax:           resq 1      ; 0x00
    .rbx:           resq 1
    .rcx:           resq 1
    .rdx:           resq 1
    .rsi:           resq 1
    .rdi:           resq 1
    .rbp:           resq 1
    .rsp:           resq 1      ; 0x38
    .r8:            resq 1
    .r9:            resq 1
    .r10:           resq 1
    .r11:           resq 1
    .r12:           resq 1
    .r13:           resq 1
    .r14:           resq 1
    .r15:           resq 1      ; 0x78
    .rip:           resq 1      ; 0x80
    .rflags:        resq 1      ; 0x88
    .cr3:           resq 1      ; 0x90
    .state:         resd 1      ; 0x98: 0=EMPTY, 1=READY, 2=RUNNING, 3=SLEEPING, 4=TERMINATED
    .id:            resd 1      ; 0x9C: Process ID
    .win_id:        resd 1      ; 0xA0: Associated window ID
    .slot:          resd 1      ; 0xA4: App arena slot index
    .cs:            resq 1      ; 0xA8
    .ss:            resq 1      ; 0xB0
    .kernel_rsp:    resq 1      ; 0xB8
    ; --- Stage 1 SMP process-manager fields ------------------------------------
    ; affinity_mask: bit i set => this process is permitted to run on core i.
    ; Bits 0..1 (system cores) are clear for app processes by default; the
    ; kernel process (PID 0) carries an all-bits-set mask. Bits >= ncores are
    ; ignored by the placer.
    .affinity_mask: resd 1      ; 0xC0
    .home_core:     resd 1      ; 0xC4: last placed / preferred core
    ; cpu_time_cycles: raw TSC cycles billed to this process by AP workers
    ; running jobs whose WQ_OFF_PROC_ID matches this PCB's .id. Convert to
    ; seconds at display time via cpu_tsc_per_tick * 100. lock-add updated
    ; from APs; readers may see a stale value but never a torn one.
    .cpu_time_cycles:resq 1     ; 0xC8
    ; --- Priority manager fields (Stage 0) -------------------------------------
    ; priority:      current EFFECTIVE scheduling priority (PRIO_* in
    ;                constants.inc). The priority-aware process_schedule picks the
    ;                highest-priority READY process; an over-budget slot is demoted
    ;                toward PRIO_IDLE (Stage 1) and restored toward base_priority
    ;                after a clean window.
    ; base_priority: the class the process launched at; demotion/boost decays back
    ;                to this value.
    ; quantum_left:  remaining time-slice ticks for the running process (Stage 2
    ;                preemption decrements this each tick; 0 => reschedule).
    ; strikes:       consecutive over-budget windows (demote-then-kill counter).
    .priority:      resd 1      ; 0xD0
    .base_priority: resd 1      ; 0xD4
    .quantum_left:  resd 1      ; 0xD8
    .strikes:       resd 1      ; 0xDC
    .padding:       resb 344    ; Pad to 512 bytes
endstruc
