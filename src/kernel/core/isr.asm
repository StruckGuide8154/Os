; ============================================================================
; Grit v3.0 - Interrupt Service Routines
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
extern lapic_base               ; isr_ap_tick EOI (Tier-2 AP self-wake timer)
extern kernel_event_flags
extern xhci_irq_ack
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
extern l3_slot_in_flight
extern kernel_canary
extern kernel_panic_canary
extern tick_count, frame_count, fps_count, last_fps, start_tick
extern wm_window_count, klog_count, free_page_count
; _start is the kernel image base label (link address == KERNEL_LINK_BASE). Its
; runtime address minus KERNEL_LINK_BASE is the live KASLR slide, used to print
; a slide-relative ("link") RIP on the recovery path so a logged fault maps 1:1
; to build/kslroff.lst (the slide-0 listing) without knowing this boot's slide.
extern _start

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
    ; this is a kernel bug - halt loudly (the nested-exc guard already fired).
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

    ; ------------------------------------------------------------------
    ; Guarded ring-0 fault recovery (kfault longjmp).
    ; A ring-0 fault used to iretq straight back into the faulting
    ; instruction (the normal tail below), so a wild write in the display
    ; flip path re-faulted forever: the main loop never advanced past
    ; render_frame(), so mouse/keyboard/net were never serviced and the
    ; whole OS appeared frozen. If a kguard region is armed AND this fault
    ; came from ring 0, we instead abandon the faulting kernel operation
    ; and longjmp back to the guard's landing pad (render_frame_guarded),
    ; which returns to the main loop so input keeps flowing. Ring-3 faults
    ; ignore the guard and fall through to the normal abort path.
    cmp qword [rel kfault_armed], 0
    je .no_kguard
    mov rax, [rsp + 160]               ; saved CS
    and rax, 3
    jnz .no_kguard                     ; ring 3 -> normal slot-abort path
    ; Compact-but-complete log so a recovered ring-0 fault is one-shot fixable
    ; without the full register dump and WITHOUT freezing the OS:
    ;   KREC=<faulting RIP> L=<link RIP> V=<vector> E=<errcode> C=<cr2>
    ; L is the faulting RIP rebased to KERNEL_LINK_BASE (RIP - live KASLR slide),
    ; so it maps directly into build/kslroff.lst regardless of this boot's slide.
    SER 'K'
    SER 'R'
    SER 'E'
    SER 'C'
    SER '='
    mov rdi, [rsp + 152]               ; faulting RIP
    call ser_print_hex64
    SER 'L'
    mov rdi, [rsp + 152]               ; faulting RIP
    lea rax, [rel _start]              ; runtime kernel base
    sub rax, KERNEL_LINK_BASE          ; rax = live KASLR slide
    sub rdi, rax                       ; rdi = link-time (slide-0) RIP
    call ser_print_hex64
    SER 'V'
    mov rdi, [rsp + 136]               ; exception vector number
    call ser_print_hex64
    SER 'E'
    mov rdi, [rsp + 144]               ; CPU error code
    call ser_print_hex64
    SER 'C'
    mov rdi, cr2
    call ser_print_hex64
    SER 13
    SER 10
    lock inc qword [rel kfault_recovered_count]
    ; Balance the nested-exc guard this stub incremented on entry, and
    ; disarm so a fault inside the landing path can't re-enter here.
    lock dec dword [rel nested_exc_count]
    mov qword [rel kfault_armed], 0
    ; Restore callee-saved registers to their guard-entry values.
    mov rbx, [rel kfault_jmp_rbx]
    mov rbp, [rel kfault_jmp_rbp]
    mov r12, [rel kfault_jmp_r12]
    mov r13, [rel kfault_jmp_r13]
    mov r14, [rel kfault_jmp_r14]
    mov r15, [rel kfault_jmp_r15]
    ; Synthesize an iret frame returning to the landing pad on the guard's
    ; saved stack with IF=1 (in long mode iretq always pops SS:RSP, even
    ; for a same-privilege return, so RSP becomes kfault_jmp_rsp).
    mov rax, [rel kfault_jmp_rsp]
    mov rsp, rax
    push qword 0x10                    ; SS  = kernel data
    push rax                           ; RSP = guard entry stack
    push qword 0x202                   ; RFLAGS (IF=1)
    push qword 0x08                    ; CS  = kernel code
    push qword [rel kfault_jmp_rip]    ; RIP = landing pad
    iretq
.no_kguard:

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

    ; ------------------------------------------------------------------
    ; Counter dump: on any fault (notably a display-driver crash) print
    ; every global counter to serial so the pre-fault state is visible.
    ; Format: CNT T=<tick> F=<frame> f=<fps> L=<lastfps> S=<starttick>
    ;             W=<windows> K=<klog> P=<freepages>
    ; tick/start are 64-bit; the rest are 32-bit (zero-extended).
    SER 'C'
    SER 'N'
    SER 'T'
    SER ' '
    SER 'T'
    mov rdi, [tick_count]
    call ser_print_hex64
    SER 'F'
    mov edi, [frame_count]
    call ser_print_hex64
    SER 'f'
    mov edi, [fps_count]
    call ser_print_hex64
    SER 'L'
    mov edi, [last_fps]
    call ser_print_hex64
    SER 'S'
    mov rdi, [start_tick]
    call ser_print_hex64
    SER 'W'
    mov edi, [wm_window_count]
    call ser_print_hex64
    SER 'K'
    mov edi, [klog_count]
    call ser_print_hex64
    SER 'P'
    mov edi, [free_page_count]
    call ser_print_hex64
    SER 13
    SER 10

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
    mov edx, 0x49535243                  ; ISRC: ring-0 exception footer canary
    jmp kernel_panic_canary

.exc_ring3_abort:
    POP_ALL
    mov rax, [rsp]                              ; canary check
    cmp rax, [rel kernel_canary]
    jne .isr_r3_canary_bad
    add rsp, 32              ; Pop canary, pad, errcode, int#; RSP now at user RIP.
    ; Recover via the slot whose ring-3 callback is actually IN FLIGHT, NOT the
    ; slot derived from the faulting RIP. The BSP runs one inline callback at a
    ; time, so exactly one l3_slot_in_flight entry is set while a callback runs,
    ; and that slot has a saved kernel frame (call_app_l3 recorded KERNEL_RSP) so
    ; l3_return_guard can cleanly unwind back to cb_run_guarded. Deriving the slot
    ; from the faulting RIP is WRONG whenever ring-3 branched out of its slot -
    ; e.g. into an un-slid kernel-blob VA (the notepad-click freeze): that RIP is
    ; below the arena, so the old code picked slot 0, which has no live callback
    ; frame, so l3_return_guard parked the BSP with cli;hlt -> whole-OS freeze.
    xor ecx, ecx
.exc_r3_inflight_scan:
    cmp ecx, MAX_WINDOWS
    jae .exc_r3_orphan                  ; none in flight -> no callback frame to unwind
    cmp qword [abs l3_slot_in_flight + rcx*8], 0
    je .exc_r3_inflight_next
    mov eax, ecx                        ; recover via the in-flight callback slot
    jmp .exc_ring3_slot_ready
.exc_r3_inflight_next:
    inc ecx
    jmp .exc_r3_inflight_scan
.exc_r3_orphan:
    ; ORPHANED ring-3 fault: no slot has a live callback frame, so there is no
    ; saved kernel RSP for l3_return_guard to unwind through - the RIP-derived
    ; path below would land on slot 0 (KERNEL_RSP==0), and l3_return_guard's
    ; no-landing-pad fallback would park the BSP with cli;hlt -> WHOLE-OS FREEZE
    ; (the app-open freeze: ring 3 ran an untracked kernel-resident-blob VA, e.g.
    ; an un-permuted #15 syscall, then took a ring-3 fetch #PF). If the BSP main
    ; loop has armed its top-level recovery guard, longjmp straight back to it
    ; (input/render/timers stay alive; the offending app is struck on the kmain
    ; side). This is a SEPARATE buffer from kfault so render_frame_guarded's inner
    ; kfault arm/disarm cannot clobber this outer pad.
    cmp qword [rel r3g_armed], 0
    je .exc_r3_from_rip                 ; no guard armed -> legacy RIP-derived path
    mov qword [rel r3g_armed], 0        ; disarm; kmain re-arms each loop iteration
    lock dec dword [rel nested_exc_count]
    mov rbx, [rel r3g_jmp_rbx]
    mov rbp, [rel r3g_jmp_rbp]
    mov r12, [rel r3g_jmp_r12]
    mov r13, [rel r3g_jmp_r13]
    mov r14, [rel r3g_jmp_r14]
    mov r15, [rel r3g_jmp_r15]
    mov rax, [rel r3g_jmp_rsp]
    mov rsp, rax
    push qword 0x10                     ; SS  = kernel data
    push rax                            ; RSP = kmain guard-entry stack
    push qword 0x202                    ; RFLAGS (IF=1)
    push qword 0x08                     ; CS  = kernel code
    push qword [rel r3g_jmp_rip]        ; RIP = kmain landing pad
    mov rax, 1                          ; r3guard_arm "returns" 1 on recovery
    iretq
.exc_r3_from_rip:
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
    extern l3_return_guard
    jmp l3_return_guard      ; guards KERNEL_RSP==0 then call_app_l3_return
.isr_r3_canary_bad:
    mov rdi, rax
    lea rsi, [rel .isr_r3_canary_bad]
    mov edx, 0x5233434E                  ; R3CN: ring-3 exception abort footer canary
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
    cmp rax, 51
    je .irq_xhci

    ; Unhandled IRQ - just send EOI
    jmp .send_eoi

.irq_timer:
    call pit_handler

    ; Send EOI to hardware
    call apic_eoi
    call pic_eoi_master

    ; Callback deadman: ONLY when the timer interrupted a ring-3 callback
    ; (CS&3==3) do we consider aborting a runaway. Never abort from ring 0
    ; (that would kill the kernel). EOI has already happened above, so the
    ; LAPIC stays healthy regardless of which exit path we take.
    ;
    ; IRQ frame layout from rsp here (NO error code, unlike the exc stub):
    ;   PUSH_ALL = 15*8 = 120, then canary+pad = 16, then int# = 8,
    ;   then RIP @ 144, CS @ 152, RFLAGS @ 160, user RSP @ 168.
    mov rax, [rsp + 152]    ; saved CS on the IRQ frame
    and rax, 3
    cmp rax, 3
    je .irq_timer_ring3     ; ring 3: callback deadman path below

    ; --- Tier-1 kernel-liveness watchdog (feedback_no_freeze_invariant) -------
    ; The timer interrupted ring 0. If the BSP main loop has been wedged past the
    ; deadline (a kernel infinite loop / livelock with IF=1), abandon the stuck
    ; kernel operation and longjmp back to kmain's top-level r3guard landing pad
    ; - the SAME recovery used for orphaned ring-3 faults - so input/render/timers
    ; stay alive instead of the OS appearing frozen. Only when a pad is armed.
    cmp qword [rel r3g_armed], 0
    je .done                ; no landing pad yet (pre-main-loop) -> nothing to do
    extern kwd_check
    call kwd_check
    test eax, eax
    jz .done                ; not wedged: normal ring-0 timer exit (unchanged)
%ifdef ENABLE_DEBUG_SERIAL
    SER 'K'
    SER 'W'
    SER 'D'
    SER 'G'
    SER 13
    SER 10
%endif
    ; Forced recovery: rewind to the kmain guard frame and iretq to its pad.
    ; First drop any kernel lock the abandoned BSP context held (no re-deadlock).
    extern blk_recover_release_bsp
    call blk_recover_release_bsp
    mov qword [rel r3g_armed], 0
    mov dword [rel nested_exc_count], 0      ; we are unwinding the whole stack
    ; (kwd_check already bumped kwd_recovered_count on the trip)
    mov rbx, [rel r3g_jmp_rbx]
    mov rbp, [rel r3g_jmp_rbp]
    mov r12, [rel r3g_jmp_r12]
    mov r13, [rel r3g_jmp_r13]
    mov r14, [rel r3g_jmp_r14]
    mov r15, [rel r3g_jmp_r15]
    mov rax, [rel r3g_jmp_rsp]
    mov rsp, rax
    push qword 0x10                          ; SS  = kernel data
    push rax                                 ; RSP = kmain guard-entry stack
    push qword 0x202                         ; RFLAGS (IF=1)
    push qword 0x08                          ; CS  = kernel code
    push qword [rel r3g_jmp_rip]             ; RIP = kmain landing pad
    mov rax, 1                               ; r3guard_arm "returns" 1 on recovery
    iretq

.irq_timer_ring3:
    extern cb_deadman_check
    call cb_deadman_check
    test eax, eax
    jz .done                ; no overrun: normal timer exit, byte-identical path
    ; Abort requested: clean call_app_l3_return unwind on the IRQ frame.
    POP_ALL
    mov rax, [rsp]                          ; canary check
    cmp rax, [rel kernel_canary]
    jne .irq_r3_canary_bad
    add rsp, 24             ; Pop canary, pad, int# (NO errcode); RSP now at user RIP.
    mov rax, [rsp]
    sub rax, [rel l3_app_arena_base_v]
    jc .irq_timer_slot_zero
    cmp rax, [rel l3_app_arena_size_v]
    jae .irq_timer_slot_zero
    shr rax, 21
    jmp .irq_timer_slot_ready
.irq_timer_slot_zero:
    xor eax, eax
.irq_timer_slot_ready:
    push rax                ; call_app_l3_return expects the app slot at [rsp].
    jmp l3_return_guard     ; guards KERNEL_RSP==0 then call_app_l3_return
.irq_r3_canary_bad:
    mov rdi, rax
    lea rsi, [rel .irq_r3_canary_bad]
    mov edx, 0x5233434E                  ; R3CN: ring-3 IRQ abort footer canary
    jmp kernel_panic_canary


.irq_keyboard:
    call keyboard_handler
    lock or dword [rel kernel_event_flags], 1
    call apic_eoi
    call pic_eoi_master
    jmp .done

.irq_mouse:
    call mouse_handler
    lock or dword [rel kernel_event_flags], 1
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
    lock or dword [rel kernel_event_flags], 1
    call apic_eoi
    jmp .done

.irq_xhci:
    call xhci_irq_ack
    lock or dword [rel kernel_event_flags], 3
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
    mov edx, 0x49525143                  ; IRQC: IRQ footer canary
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

; ============================================================================
; NMI handler (vector 2) - Tier-2 kernel-liveness watchdog landing pad.
; (feedback_no_freeze_invariant / kernel_liveness_watchdog)
;
; This DELIBERATELY does NOT route through isr_common_stub: that stub's
; nested-exception guard halts on re-entry, which is the exact opposite of what
; a liveness watchdog must do. An NMI is non-maskable, so it is delivered even
; while the BSP spins with interrupts disabled (cli / IF=0) - the one stall the
; PIT-based Tier-1 watchdog can never catch. A live AP detects the frozen BSP
; heartbeat and sends us this NMI IPI (kwd_ap_watch -> wd_send_nmi_bsp).
;
; Policy lives in GHL (kwd_nmi_should_recover): recover ONLY when an AP actually
; flagged a stall AND kmain has a landing pad armed; otherwise pass the NMI
; through untouched (some other, legitimate NMI source).
; ============================================================================
FN_DECL isr_nmi, 0, 0, FN_RET_SCALAR
    push rax
    KPTI_SWITCH_TO_KERNEL_CR3 rax
    pop rax
    cld
    PUSH_ALL                                ; NMI can interrupt anything: save all
    extern kwd_nmi_should_recover
    call kwd_nmi_should_recover
    test eax, eax
    jnz .nmi_recover
    POP_ALL                                 ; not ours -> restore and resume
    iretq
.nmi_recover:
    ; Abandon the wedged BSP operation. First drop any kernel spinlock the
    ; recovered context held, so a waiter cannot re-deadlock on a lock whose
    ; holder we are about to unwind (held-lock-abandoned-by-recovery fix).
    extern blk_recover_release_bsp
    call blk_recover_release_bsp
%ifdef ENABLE_DEBUG_SERIAL
    SER 'K'
    SER 'W'
    SER 'D'
    SER 'N'
    SER 13
    SER 10
%endif
    ; Rewind to kmain's r3guard frame and iretq to its landing pad - the SAME
    ; recovery the Tier-1 PIT path and orphaned-ring-3 faults use.
    mov qword [rel r3g_armed], 0
    mov dword [rel nested_exc_count], 0
    mov rbx, [rel r3g_jmp_rbx]
    mov rbp, [rel r3g_jmp_rbp]
    mov r12, [rel r3g_jmp_r12]
    mov r13, [rel r3g_jmp_r13]
    mov r14, [rel r3g_jmp_r14]
    mov r15, [rel r3g_jmp_r15]
    mov rax, [rel r3g_jmp_rsp]
    mov rsp, rax
    push qword 0x10                          ; SS  = kernel data
    push rax                                 ; RSP = kmain guard-entry stack
    push qword 0x202                         ; RFLAGS (IF=1)
    push qword 0x08                          ; CS  = kernel code
    push qword [rel r3g_jmp_rip]             ; RIP = kmain landing pad
    mov rax, 1                               ; r3guard_arm "returns" 1 on recovery
    iretq

; ============================================================================
; isr_ap_tick (vector AP_WD_TICK_VEC) - per-AP one-shot LAPIC-timer wake.
; Idle APs STI;HLT and would otherwise only wake on a work IPI; this self-wake
; lets every idle AP re-run kwd_ap_watch at a bounded cadence (~tens of ms) so
; the cross-core watchdog keeps observing the BSP heartbeat. Body is trivial:
; just EOI and return; the worker loop re-arms the one-shot before its next HLT.
; ============================================================================
FN_DECL isr_ap_tick, 0, 0, FN_RET_SCALAR
    push rax
    mov rax, [rel lapic_base]
    mov dword [rax + 0x0B0], 0               ; LAPIC EOI
    pop rax
    iretq

; ============================================================================
; kfault guard primitives (setjmp/longjmp-style ring-0 recovery).
;
; Any ring-0 kernel section can bracket risky work with a recovery landing pad:
;
;       lea  rdi, [rel .my_land]
;       call kfault_arm                ; rdi = landing-pad RIP
;       call risky_thing               ; may #PF / #GP at ring 0
;       call kfault_disarm
;       ... ; normal completion
;   .my_land:
;       call kfault_disarm             ; (idempotent) reached after recovery
;       ... ; abort/cleanup path
;
; On a ring-0 fault while armed, the page-fault/GP stub (above) restores the
; saved callee-saved regs + RSP and longjmps to the saved landing pad with
; IF=1, bumping kfault_recovered_count. Ring-3 faults ignore the guard.
;
; kfault_arm(rdi = landing-pad RIP):
;   Captures rbx/rbp/r12-r15, the CALLER's RSP (i.e. rsp as it will be just
;   after kfault_arm returns), and the landing-pad RIP, then sets armed=1.
;   On a longjmp the stack is rewound to the caller's frame and execution
;   resumes at the landing pad, as if kfault_arm had "returned a second time".
;   Clobbers rax only; preserves all callee-saved regs.
;
; kfault_disarm():
;   Clears armed. Idempotent (safe to call on both the normal and recovery
;   paths). Clobbers nothing of interest (no register outputs).
;
; NOT reentrant: there is a single recovery buffer. A nested kfault_arm
; overwrites the outer arm's saved state, so the inner landing pad wins and
; the outer region is no longer protected until it re-arms. Callers must not
; rely on nested guards; keep armed regions flat (arm -> risky work ->
; disarm) and avoid arming across calls that themselves arm.
; ============================================================================
; auto-wrapped (FN_DECL emits global): global kfault_arm, kfault_disarm
FN_DECL kfault_arm, 1, 0, FN_RET_SCALAR
    mov [rel kfault_jmp_rbx], rbx
    mov [rel kfault_jmp_rbp], rbp
    mov [rel kfault_jmp_r12], r12
    mov [rel kfault_jmp_r13], r13
    mov [rel kfault_jmp_r14], r14
    mov [rel kfault_jmp_r15], r15
    ; Record the caller's RSP: our return address sits at [rsp], so after we
    ; ret the caller's RSP is rsp+8. A longjmp rewinds straight to that frame.
    lea rax, [rsp + 8]
    mov [rel kfault_jmp_rsp], rax
    mov [rel kfault_jmp_rip], rdi      ; landing-pad RIP supplied by caller
    mov qword [rel kfault_armed], 1
    ret

FN_DECL kfault_disarm, 0, 0, FN_RET_SCALAR
    mov qword [rel kfault_armed], 0
    ret

; ----------------------------------------------------------------------------
; r3guard_arm() - top-level BSP recovery pad for ORPHANED ring-3 faults.
;
; setjmp-style: captures the caller (kmain main-loop) frame and returns 0 the
; first time. If a ring-3 fault occurs with NO in-flight callback slot to unwind
; through, the ISR .exc_r3_orphan path longjmps here, and r3guard_arm "returns" 1
; - so kmain re-enters its loop with input/render/timers alive instead of the BSP
; parking forever in l3_return_guard's cli;hlt. Uses a DEDICATED buffer so the
; inner render_frame_guarded kfault arm/disarm cannot clobber this outer pad.
; Must be called directly in the frame to recover to (kmain), not via a wrapper.
; auto-wrapped (FN_DECL emits global): global r3guard_arm
FN_DECL r3guard_arm, 0, 0, FN_RET_SCALAR
    mov [rel r3g_jmp_rbx], rbx
    mov [rel r3g_jmp_rbp], rbp
    mov [rel r3g_jmp_r12], r12
    mov [rel r3g_jmp_r13], r13
    mov [rel r3g_jmp_r14], r14
    mov [rel r3g_jmp_r15], r15
    lea rax, [rsp + 8]                 ; caller RSP after this ret
    mov [rel r3g_jmp_rsp], rax
    mov rax, [rsp]                     ; return address = landing-pad RIP
    mov [rel r3g_jmp_rip], rax
    mov qword [rel r3g_armed], 1
    xor eax, eax                       ; first (direct) return: 0
    ret

; ----------------------------------------------------------------------------
; render_frame_guarded(): the original display-path consumer, now expressed in
; terms of the primitives above. Behavior is identical: arm with .land as the
; landing pad, call render_frame, disarm. On a ring-0 fault inside the present
; path the ISR longjmps to .land (RSP already rewound to this frame), which
; disarms and returns to the main loop so input keeps flowing.
; ----------------------------------------------------------------------------
extern render_frame
; auto-wrapped (FN_DECL emits global): global render_frame_guarded
FN_DECL render_frame_guarded, 0, 0, FN_RET_SCALAR
    lea rdi, [rel .land]
    call kfault_arm
    call render_frame
    call kfault_disarm
    ret
.land:
    ; Reached via the ISR longjmp after a recovered ring-0 fault. Callee-saved
    ; regs and RSP were already restored by the ISR. Disarm (idempotent: the
    ; ISR also cleared armed) and return to the main loop.
    call kfault_disarm
    ret

section .data
nested_exc_count: dd 0
; kfault recovery buffer (setjmp/longjmp-style). armed != 0 means a guard region
; is live and a ring-0 fault should longjmp instead of returning to the fault.
kfault_armed:            dq 0
kfault_jmp_rbx:          dq 0
kfault_jmp_rbp:          dq 0
kfault_jmp_r12:          dq 0
kfault_jmp_r13:          dq 0
kfault_jmp_r14:          dq 0
kfault_jmp_r15:          dq 0
kfault_jmp_rsp:          dq 0
kfault_jmp_rip:          dq 0
kfault_recovered_count:  dq 0          ; total ring-0 faults recovered (diag)
global kfault_recovered_count
; armed flag exposed so a section can cheaply check "am I (or an outer guard)
; already armed?" before deciding to arm - the buffer is single-slot / not
; reentrant (see kfault_arm header).
global kfault_armed

; Top-level ring-3 orphan-fault recovery buffer (r3guard_arm). Separate from
; kfault so the inner render_frame_guarded kfault usage never clobbers it.
r3g_armed:               dq 0
r3g_jmp_rbx:             dq 0
r3g_jmp_rbp:             dq 0
r3g_jmp_r12:             dq 0
r3g_jmp_r13:             dq 0
r3g_jmp_r14:             dq 0
r3g_jmp_r15:             dq 0
r3g_jmp_rsp:             dq 0
r3g_jmp_rip:             dq 0
global r3g_armed

section .text
