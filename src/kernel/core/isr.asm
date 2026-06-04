; ============================================================================
; NexusOS v3.0 - Interrupt Service Routines
; Exception handlers (0-31) and IRQ stubs (0-15 -> vectors 32-47)
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

section .text

extern pic_eoi_master, pic_eoi_slave
extern pit_handler
extern keyboard_handler
extern mouse_handler
extern i2c_hid_poll
extern spi_hid_poll
extern apic_eoi
extern render_frame
extern process_mouse
extern keyboard_repeat_tick
extern keyboard_available
extern process_keyboard
extern usb_poll_mouse
extern battery_poll
extern gui_initialized
extern trace_dump_serial
extern trace_dump_screen
extern l3_app_arena_base_v
extern l3_app_arena_size_v
extern l3_syscall_stacks
extern kernel_canary
extern kernel_panic_canary

; ============================================================================
; Exception ISR Stubs (0-31)
; ============================================================================
; Exceptions WITHOUT error code
ISR_NOERRCODE 0     ; Divide by zero
ISR_NOERRCODE 1     ; Debug
ISR_NOERRCODE 2     ; NMI
ISR_NOERRCODE 3     ; Breakpoint
ISR_NOERRCODE 4     ; Overflow
ISR_NOERRCODE 5     ; Bound range exceeded
ISR_NOERRCODE 6     ; Invalid opcode
ISR_NOERRCODE 7     ; Device not available
ISR_ERRCODE   8     ; Double fault (has error code)
ISR_NOERRCODE 9     ; Coprocessor segment overrun
ISR_ERRCODE   10    ; Invalid TSS
ISR_ERRCODE   11    ; Segment not present
ISR_ERRCODE   12    ; Stack segment fault
ISR_ERRCODE   13    ; General protection fault
ISR_ERRCODE   14    ; Page fault
ISR_NOERRCODE 15    ; Reserved
ISR_NOERRCODE 16    ; x87 floating point
ISR_ERRCODE   17    ; Alignment check
ISR_NOERRCODE 18    ; Machine check
ISR_NOERRCODE 19    ; SIMD floating point
ISR_NOERRCODE 20    ; Virtualization
ISR_NOERRCODE 21    ; Reserved
ISR_NOERRCODE 22
ISR_NOERRCODE 23
ISR_NOERRCODE 24
ISR_NOERRCODE 25
ISR_NOERRCODE 26
ISR_NOERRCODE 27
ISR_NOERRCODE 28
ISR_NOERRCODE 29
ISR_ERRCODE   30    ; Security exception
ISR_NOERRCODE 31

; Common ISR handler for exceptions
; auto-wrapped (FN_BEGIN emits global): global isr_common_stub
FN_DECL isr_common_stub, 0, 0, FN_RET_SCALAR
    push rax
    KPTI_SWITCH_TO_KERNEL_CR3 rax
    pop rax
    cld
    
    ; Nested exception guard
    lock inc dword [rel nested_exc_count]
    cmp dword [rel nested_exc_count], 1
    ja isr_nested_halt

    sub rsp, 8                                  ; canary alignment pad
    push qword [rel kernel_canary]              ; canary push
    PUSH_ALL

    ; Stack-guard fast path: on a page fault whose CR2 falls on a per-slot
    ; user-stack guard page (one 4KB page below the user stack of any of
    ; the APP_SLOT_COUNT slots), log "STKG=<slot>" and abort the slot
    ; instead of the verbose register dump. Falls through to the dump for
    ; every other fault.
    cmp qword [rsp + 136], 14
    jne .not_stack_guard
    mov rax, cr2
    mov r10, [rel l3_app_arena_base_v]
    sub rax, r10
    jc .check_syscall_guard
    mov r10, rax
    shr r10, 21                        ; r10 = slot index
    cmp r10, APP_SLOT_COUNT
    jae .check_syscall_guard
    and rax, APP_SLOT_SIZE - 1
    and rax, ~0xFFF                    ; page-aligned offset within slot
    cmp rax, L3_SLOT_USER_STACK_GUARD_OFF
    jne .check_syscall_guard
    SER 'S'
    SER 'T'
    SER 'K'
    SER 'G'
    SER '='
    mov rdi, r10
    call ser_print_hex64
    SER 13
    SER 10
    ; If from ring 3, hand off to the existing slot-abort tail. From ring 0
    ; this is a kernel bug — halt loudly (the nested-exc guard already fired).
    mov rax, [rsp + 160]               ; saved CS
    and rax, 3
    cmp rax, 3
    je .exc_ring3_abort
    jmp isr_nested_halt
.check_syscall_guard:
    ; Per-slot syscall-stack guard. l3_install_syscall_stack_pt clears
    ; PAGE_PRESENT on the two guard pages of each MAX_WINDOWS * STRIDE-byte
    ; slot (+0x0000 below the shadow stack, +0x2000 below the syscall stack);
    ; an overflow off the bottom of either stack lands here. Syscall stacks
    ; are kernel-context only, so a hit from anywhere means kernel halt
    ; after logging the slot id.
    mov rax, cr2
    mov r10, l3_syscall_stacks
    sub rax, r10
    jc .not_stack_guard
    mov r10, MAX_WINDOWS * L3_SYSCALL_STACK_STRIDE
    cmp rax, r10
    jae .not_stack_guard
    mov r10, rax
    shr r10, 14                        ; r10 = slot index (STRIDE = 16384 = 1<<14)
    and rax, L3_SYSCALL_STACK_STRIDE - 1
    and rax, ~0xFFF                    ; page-aligned offset within slot
    cmp rax, 0x2000
    je .syscall_guard_hit              ; +0x2000 guard (below syscall stack)
    test rax, rax
    jnz .not_stack_guard               ; non-zero & not 0x2000 = real stack page
.syscall_guard_hit:
    SER 'S'
    SER 'Y'
    SER 'S'
    SER 'G'
    SER '='
    mov rdi, r10
    call ser_print_hex64
    SER 13
    SER 10
    jmp isr_nested_halt
.not_stack_guard:

    ; Print Info: X<#>[@<RIP>#<CS>!<RSP>]
    SER 'X'
    mov rdi, [rsp + 136]
    call ser_print_hex64
    SER '@'
    mov rdi, [rsp + 152]
    call ser_print_hex64
    SER '#'
    mov rdi, [rsp + 160]
    call ser_print_hex64
    SER 'E'
    mov rdi, [rsp + 144]
    call ser_print_hex64
    SER 'R'
    mov rdi, cr2
    call ser_print_hex64
    SER '!'
    mov rdi, [rsp + 176]
    call ser_print_hex64
    SER 13
    SER 10

    ; Dump all registers
    SER 'A'
    mov rdi, [rsp + 112]     ; RAX
    call ser_print_hex64
    SER 'B'
    mov rdi, [rsp + 104]     ; RBX
    call ser_print_hex64
    SER 'C'
    mov rdi, [rsp + 96]      ; RCX
    call ser_print_hex64
    SER 'D'
    mov rdi, [rsp + 88]      ; RDX
    call ser_print_hex64
    SER 'I'
    mov rdi, [rsp + 72]      ; RDI
    call ser_print_hex64
    SER 'S'
    mov rdi, [rsp + 80]      ; RSI
    call ser_print_hex64
    SER 'P'
    mov rdi, [rsp + 64]      ; RBP
    call ser_print_hex64
    SER 13
    SER 10
    SER '8'
    mov rdi, [rsp + 56]      ; R8
    call ser_print_hex64
    SER '9'
    mov rdi, [rsp + 48]      ; R9
    call ser_print_hex64
    SER '0'
    mov rdi, [rsp + 40]      ; R10
    call ser_print_hex64
    SER '1'
    mov rdi, [rsp + 32]      ; R11
    call ser_print_hex64
    SER '2'
    mov rdi, [rsp + 24]      ; R12
    call ser_print_hex64
    SER '3'
    mov rdi, [rsp + 16]      ; R13
    call ser_print_hex64
    SER '4'
    mov rdi, [rsp + 8]       ; R14
    call ser_print_hex64
    SER '5'
    mov rdi, [rsp + 0]       ; R15
    call ser_print_hex64
    SER 13
    SER 10

    ; DEBUG (blank-app #UD diagnosis): dump 16 bytes at the faulting RIP so we can
    ; identify the exact offending opcode. Only for ring-3 faults (CS[1:0]==3) so
    ; RIP is a mapped app-arena VA (kernel pages may be unmapped under KPTI). SMAP
    ; is off in this diag build, so a ring-0 read of the user page won't #AC.
    mov rax, [rsp + 160]     ; saved CS
    and rax, 3
    cmp rax, 3
    jne .skip_op_dump
    SER 'O'
    SER 'P'
    SER '='
    mov rsi, [rsp + 152]     ; faulting RIP
    mov rdi, [rsi]           ; bytes [0..7]
    call ser_print_hex64
    SER ' '
    mov rsi, [rsp + 152]
    mov rdi, [rsi + 8]       ; bytes [8..15]
    call ser_print_hex64
    SER 13
    SER 10
.skip_op_dump:

%ifdef ENABLE_TRACE
    call trace_dump_serial
    call trace_dump_screen
%endif

    ; Paint red pixels to indicate exception
    mov rdi, [abs VBE_INFO_ADDR + VBE_FB_ADDR_OFF]
    mov dword [rdi], 0x000000FF
    mov dword [rdi+4], 0x000000FF
    mov dword [rdi+8], 0x000000FF
    mov rax, [rsp + 136]
    shl rax, 2
    add rax, 16
    add rdi, rax
    mov dword [rdi], 0x0000FFFF

    ; If exception from Ring 3 (CS[1:0] == 3), abort the app callback
    ; instead of iretq-ing back to the faulting Ring 3 instruction.
    mov rax, [rsp + 160]     ; saved CS on exception frame (after PUSH_ALL: 15 regs*8=120, then canary+pad=16, then int#=8, errcode=8, rip=8, cs offset)
    and rax, 3
    cmp rax, 3
    je .exc_ring3_abort

    POP_ALL
    mov rax, [rsp]                              ; canary check
    cmp rax, [rel kernel_canary]
    jne .isr_canary_bad
    add rsp, 32              ; Pop canary, pad, error code, interrupt number
    lock dec dword [rel nested_exc_count]
    mov rax, [rsp + 8]
    and rax, 3
    cmp rax, 3
    jne .isr_no_kpti_user
    KPTI_SWITCH_TO_USER_CR3 rax
.isr_no_kpti_user:
    iretq
.isr_canary_bad:
    mov rdi, rax
    lea rsi, [rel .isr_canary_bad]
    jmp kernel_panic_canary

.exc_ring3_abort:
    POP_ALL
    mov rax, [rsp]                              ; canary check
    cmp rax, [rel kernel_canary]
    jne .isr_r3_canary_bad
    add rsp, 32              ; Pop canary, pad, errcode, int#; RSP now at user RIP.
    mov rax, [rsp]
    sub rax, [rel l3_app_arena_base_v]
    jc .exc_ring3_slot_zero
    cmp rax, [rel l3_app_arena_size_v]
    jae .exc_ring3_slot_zero
    shr rax, 21
    jmp .exc_ring3_slot_ready
.exc_ring3_slot_zero:
    xor eax, eax
.exc_ring3_slot_ready:
    lock dec dword [rel nested_exc_count]
    push rax                 ; call_app_l3_return expects the app slot at [rsp].
    extern call_app_l3_return
    jmp call_app_l3_return
.isr_r3_canary_bad:
    mov rdi, rax
    lea rsi, [rel .isr_r3_canary_bad]
    jmp kernel_panic_canary

; ============================================================================
; IRQ Stubs (0-15 -> vectors 32-47)
; ============================================================================
IRQ_STUB 0, 32     ; Timer (PIT)
IRQ_STUB 1, 33     ; Keyboard
IRQ_STUB 2, 34     ; Cascade
IRQ_STUB 3, 35     ; COM2
IRQ_STUB 4, 36     ; COM1
IRQ_STUB 5, 37     ; LPT2
IRQ_STUB 6, 38     ; Floppy
IRQ_STUB 7, 39     ; LPT1 / Spurious
IRQ_STUB 8, 40     ; CMOS RTC
IRQ_STUB 9, 41     ; Free
IRQ_STUB 10, 42    ; Free
IRQ_STUB 11, 43    ; Free
IRQ_STUB 12, 44    ; PS/2 Mouse
IRQ_STUB 13, 45    ; FPU
IRQ_STUB 14, 46    ; Primary ATA
IRQ_STUB 15, 47    ; Secondary ATA
IRQ_STUB 17, 49    ; SMP workqueue wake IPI
IRQ_STUB 18, 50    ; Advanced Touchpad (APIC)

; Common IRQ handler
; auto-wrapped (FN_BEGIN emits global): global irq_common_stub
FN_DECL irq_common_stub, 0, 0, FN_RET_SCALAR
    push rax
    KPTI_SWITCH_TO_KERNEL_CR3 rax
    pop rax
    sub rsp, 8                                  ; canary alignment pad
    push qword [rel kernel_canary]              ; canary push
    PUSH_ALL

    ; Get IRQ number from interrupt vector on stack
    mov rax, [rsp + 136]     ; Interrupt vector number

    ; Dispatch to device-specific handler
    cmp rax, 32
    je .irq_timer
    cmp rax, 33
    je .irq_keyboard
    cmp rax, 44
    je .irq_mouse
    cmp rax, 49
    je .irq_wq_wake
    cmp rax, 50
    je .irq_apic_touchpad

    ; Unhandled IRQ - just send EOI
    jmp .send_eoi

.irq_timer:
    call pit_handler

    ; Send EOI to hardware
    call apic_eoi           
    call pic_eoi_master
    jmp .done


.irq_keyboard:
    call keyboard_handler
    call apic_eoi
    call pic_eoi_master
    jmp .done

.irq_mouse:
    call mouse_handler
    call apic_eoi
    call pic_eoi_slave
    call pic_eoi_master
    jmp .done

.irq_wq_wake:
    call apic_eoi
    jmp .done

.send_eoi:
    ; Check if slave PIC needs EOI (IRQ >= 40)
    cmp rax, 40
    jl .send_eoi_master
    call pic_eoi_slave
    jmp .done

.send_eoi_master:
    call pic_eoi_master
    jmp .done

.irq_apic_touchpad:
    call i2c_hid_poll
    call spi_hid_poll
    call apic_eoi
    jmp .done

.done:
    POP_ALL
    mov rax, [rsp]                              ; canary check
    cmp rax, [rel kernel_canary]
    jne .irq_canary_bad
    add rsp, 32              ; Pop canary, pad, error code, interrupt number
    mov rax, [rsp + 8]
    and rax, 3
    cmp rax, 3
    jne .irq_no_kpti_user
    KPTI_SWITCH_TO_USER_CR3 rax
.irq_no_kpti_user:
    iretq
.irq_canary_bad:
    mov rdi, rax
    lea rsi, [rel .irq_canary_bad]
    jmp kernel_panic_canary

isr_nested_halt:
    SER '!'
    SER '!'
    SER '!'
    hlt
    jmp isr_nested_halt

; Helper: Print 64-bit hex value to serial
ser_print_hex64:
%ifndef ENABLE_DEBUG_SERIAL
    ret
%else
    push rcx
    push rax
    push rdx
    mov rcx, 16
.hex_loop:
    rol rdi, 4
    mov al, dil
    and al, 0x0F
    cmp al, 10
    jl .hex_digit
    add al, 'A' - '0' - 10
.hex_digit:
    add al, '0'
    mov dx, 0x3F8
    out dx, al
    loop .hex_loop
    pop rdx
    pop rax
    pop rcx
    ret
%endif

section .data
nested_exc_count: dd 0

section .text
