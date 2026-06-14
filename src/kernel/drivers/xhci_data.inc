; ============================================================================
; Data
; ============================================================================
section .data

global xhci_active
xhci_active:        db 0          ; 1 if XHCI initialized and mouse configured

align 4
xhci_evt_lock:      dd 0          ; spinlock guarding xhci_evt_dequeue + ERDP write

; --- DEBUG: per-controller xhci_init progress log ---
; Each entry = 4 bytes {bus, dev, fn, stage}. stage: 1=pciFound 2=capsRead
; 3=ownership 4=reset 5=ringsUp 6=running.
global xhci_initlog_n, xhci_initlog
xhci_initlog_n:     db 0
xhci_initlog:       times 8*4 db 0
xhci_initlog_cur:   dq 0

; --- DEBUG: xhci_find_port snapshots. Each record = 16 bytes:
;   +0 opbase_lo(dd)  +4 maxports(db)  +5 result(db)  +6.. port speed map (10)
global xhci_dbg_fp_n, xhci_dbg_fp
xhci_dbg_fp_n:      db 0
xhci_dbg_fp:        times 4*16 db 0
xhci_dbg_fp_cur:    dq 0

xhci_pci_addr:      dd 0          ; PCI bus/dev/func address
global xhci_pci_search_start
xhci_pci_search_start: dd 0      ; Where to continue PCI scan from (for multi-controller)
global xhci_pci_this_start
xhci_pci_this_start:   dd 0      ; Start position of currently active controller (for re-init)
xhci_mmio_base:     dq 0          ; MMIO base address
global xhci_op_base
xhci_op_base:       dq 0          ; Operational registers base
xhci_db_base:       dq 0          ; Doorbell array base
xhci_rt_base:       dq 0          ; Runtime registers base

; Slot2 mode: when 1, address_device/configure_endpoint use slot2 addresses
global xhci_slot2_mode
xhci_slot2_mode:    db 0
; NIC mode: when 1, address_device uses the dedicated rtl8156 device context +
; control EP0 ring (RTL8156_XHCI_DEV_CTX_ADDR / RTL8156_XHCI_CTRL_RING_ADDR).
; Overrides slot2_mode for both DCBAA + ring selection.
global xhci_nic_mode
xhci_nic_mode:      db 0

xhci_cap_length:    db 0
xhci_max_slots:     db 0
global xhci_max_ports
xhci_max_ports:     db 0
xhci_scratchpad_count: dw 0
xhci_scratchpad_req:   dw 0         ; Raw count from HCSPARAMS2 (uncapped)
; DEBUG: ADDRESS_DEVICE diagnostics. addrn = which submit (1=BSR set, 2=BSR clear);
; addrcc = completion code of last submit (0=timeout/no event, 1=success,
; 5=TRB error, 11=ctx state error, 17=parameter error, etc.)
global xhci_dbg_addrn, xhci_dbg_addrcc, xhci_scratchpad_count, xhci_scratchpad_req
xhci_dbg_addrn:  db 0
xhci_dbg_addrcc: db 0
xhci_dbg_adstage: db 0          ; sub-stage within xhci_address_device
xhci_dbg_adcc1:  db 0           ; completion code for BSR=1 step
xhci_dbg_adcc2:  db 0           ; completion code for BSR=0 step
xhci_dbg_portsc: dd 0           ; PORTSC snapshot at last capture
xhci_dbg_rststage:    db 0      ; sub-stage within port reset (40-43, 99=timeout)
xhci_dbg_portsc_pre:  dd 0      ; PORTSC before reset bit written
xhci_dbg_portsc_post: dd 0      ; PORTSC after reset settled
xhci_dbg_speed_pre:   db 0      ; speed before reset (from initial scan)
xhci_dbg_speed_post:  db 0      ; speed after reset (final)
xhci_dbg_ped_ok:      db 0      ; 1 if PED bit set post-reset
xhci_dbg_ccs_ok:      db 0      ; 1 if CCS bit set post-reset
xhci_dbg_slotstate:   db 0      ; Slot State (bits 31:27 of slot ctx DW3) after BSR=1
xhci_dbg_portsc_written: dd 0   ; exact value we wrote to PORTSC for reset
xhci_dbg_portsc_immed:   dd 0   ; PORTSC read immediately after write (did write take?)
xhci_dbg_portsc_wait:    dd 0   ; PORTSC after exit from PRC wait loop
xhci_dbg_reset_polls:    dd 0   ; how many PORTSC polls before PRC fired / timeout
global xhci_dbg_adstage, xhci_dbg_adcc1, xhci_dbg_adcc2, xhci_dbg_portsc
global xhci_dbg_rststage, xhci_dbg_portsc_pre, xhci_dbg_portsc_post
global xhci_dbg_speed_pre, xhci_dbg_speed_post, xhci_dbg_ped_ok, xhci_dbg_ccs_ok
global xhci_dbg_slotstate, xhci_dbg_portsc_written, xhci_dbg_portsc_immed
global xhci_dbg_portsc_wait, xhci_dbg_reset_polls
xhci_ctx_size:      db 32         ; 32 or 64 bytes per context entry
xhci_ctx_stride:    dd 32

xhci_hcsparams1:    dd 0
xhci_hcsparams2:    dd 0
xhci_hccparams1:    dd 0

; Command ring state
xhci_cmd_enqueue:   dd 0
xhci_cmd_cycle:     db 1
xhci_cmd_deadline:  dq 0          ; PIT deadline for xhci_submit_cmd timeout

; Event ring state
xhci_evt_dequeue:   dd 0
xhci_evt_cycle:     db 1

; Control EP0 ring state
xhci_ctrl_enqueue:  dd 0
xhci_ctrl_cycle:    db 1

; Interrupt IN ring state
global xhci_int_enqueue, xhci_int_cycle
xhci_int_enqueue:   dd 0
xhci_int_cycle:     db 1

; Port/device info
global xhci_port_num, xhci_port_speed, xhci_slot_id
xhci_port_num:      db 0          ; 1-based port number (current / slot1)
xhci_port1_num:     db 0          ; saved slot1 port (when slot2 is being init'd)
xhci_port_speed:    db 0          ; XHCI speed code
xhci_slot_id:       db 0          ; Assigned slot ID (slot 1 during init, then saved)
xhci_ep0_mps:       dw 64         ; EP0 max packet size
global xhci_int_ep_dci
xhci_int_ep_dci:    db 0          ; Interrupt endpoint DCI (slot 1)

; Slot 2 device state
global xhci_slot2_id, xhci_int_ep2_dci, xhci_int_enqueue2, xhci_int_cycle2
xhci_slot2_id:      db 0          ; Slot ID for second USB device
xhci_int_ep2_dci:   db 0          ; Interrupt endpoint DCI (slot 2)
xhci_int_enqueue2:  dd 0          ; Interrupt ring enqueue pointer (slot 2)
xhci_int_cycle2:    db 1          ; Interrupt ring cycle bit (slot 2)

; ============================================================================
; xhci_debug_dump - Dump XHCI state to buffer
; ============================================================================
%ifndef RELEASE_BUILD
global xhci_debug_dump
xhci_debug_dump:
    push rdi
    push rsi
    push rax
    push rbx
    push rcx
    push rdx

    mov rbx, rdi              ; RBX = write pointer

    ; Header
    lea rsi, [.hdr]
    call .copystr

    ; Active
    lea rsi, [.s_active]
    call .copystr
    movzx eax, byte [xhci_active]
    call .writehex8

    ; PCI Addr
    lea rsi, [.s_pci]
    call .copystr
    mov eax, [xhci_pci_addr]
    call .writehex32

    ; XHCI Operations
    lea rsi, [.s_op]
    call .copystr
    mov rsi, [xhci_op_base]
    test rsi, rsi
    jz .no_op
    
    ; USBCMD
    mov eax, [rsi + XHCI_OP_USBCMD]
    call .writehex32
    mov byte [rbx], ','
    inc rbx
    ; USBSTS
    mov eax, [rsi + XHCI_OP_USBSTS]
    call .writehex32
    jmp .op_done
.no_op:
    lea rsi, [.s_null]
    call .copystr
.op_done:

    ; Slot/Port
    lea rsi, [.s_slot]
    call .copystr
    movzx eax, byte [xhci_slot_id]
    call .writehex8
    mov byte [rbx], '/'
    inc rbx
    movzx eax, byte [xhci_port_num]
    call .writehex8

    ; Endpoint DCI
    lea rsi, [.s_ep]
    call .copystr
    movzx eax, byte [xhci_int_ep_dci]
    call .writehex8

    ; CMD Ring
    lea rsi, [.s_cmd]
    call .copystr
    mov eax, [xhci_cmd_enqueue]
    call .writehex8
    mov byte [rbx], ':'
    inc rbx
    movzx eax, byte [xhci_cmd_cycle]
    call .writehex8

    ; EVT Ring
    lea rsi, [.s_evt]
    call .copystr
    mov eax, [xhci_evt_dequeue]
    call .writehex8
    mov byte [rbx], ':'
    inc rbx
    movzx eax, byte [xhci_evt_cycle]
    call .writehex8

    ; INT Ring
    lea rsi, [.s_int]
    call .copystr
    mov eax, [xhci_int_enqueue]
    call .writehex8
    mov byte [rbx], ':'
    inc rbx
    movzx eax, byte [xhci_int_cycle]
    call .writehex8

    ; Null terminate
    mov byte [rbx], 0

    pop rdx
    pop rcx
    pop rbx
    pop rax
    pop rsi
    pop rdi
    ret

; -- internal helpers --
.copystr:
    lodsb
    test al, al
    jz .cs_done
    mov [rbx], al
    inc rbx
    jmp .copystr
.cs_done:
    ret

.writehex8:
    push rax
    shr al, 4
    call .nib
    pop rax
    push rax
    and al, 0x0F
    call .nib
    pop rax
    ret

.writehex32:
    push rax
    shr eax, 24
    call .nib
    pop rax
    push rax
    shr eax, 16
    and al, 0xF
    call .nib
    pop rax
    push rax
    shr eax, 8
    and al, 0xF
    call .nib
    pop rax
    push rax
    shr al, 4
    call .nib
    pop rax
    push rax
    and al, 0xF
    call .nib
    pop rax
    ret
    
.nib:
    cmp al, 10
    jb .nib_digit
    add al, 'A' - 10
    jmp .nib_out
.nib_digit:
    add al, '0'
.nib_out:
    mov [rbx], al
    inc rbx
    ret

.hdr      db " -- XHCI Debug --", 0
.s_active db " Active:", 0
.s_pci    db " PCI:", 0
.s_op     db " CMD/STS:", 0
.s_null   db " NULL", 0
.s_slot   db " S/P:", 0
.s_ep     db " EP:", 0
.s_cmd    db " C:", 0
.s_evt    db " E:", 0
.s_int    db " I:", 0
%endif

szXhciStart db "XHCI: Scanning...", 0
szXhciFound db "XHCI: Controller Found.", 0
szXhciFail  db "XHCI: Init Failed!", 0
