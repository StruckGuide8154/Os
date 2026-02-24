; ============================================================================
; NexusOS v3.0 - ACPI EC Battery Driver
;
; EC I/O: 0x62 = data port, 0x66 = command/status port
; Protocol: wait IBF=0, write 0x80 to cmd port, wait IBF=0,
;           write reg addr to data port, wait OBF=1, read data from data port
;
; Acer Nitro ANV16-42 (ITE EC) register layout (probed at init):
;
;   Layout A (common Acer Nitro ITE, older):
;     0xA2 = battery remaining % (0-100)
;     0xA3 = battery status (bit1=charging, bit0=discharging)
;     0xA4 = AC adapter (bit0=1 = AC plugged)
;
;   Layout B (Acer Nitro 2023/2024 ITE8696/ITE8297):
;     0x42 = battery remaining % (0-100)
;     0x40 = battery status flags (bit0=discharging, bit1=charging)
;     0x41 = AC adapter (bit0=1 = AC plugged)
;
;   Layout C (some Acer with design/full/remaining in mWh):
;     0xB4 = design capacity low byte
;     0xB5 = design capacity high byte
;     0xB2 = remaining capacity low byte
;     0xB3 = remaining capacity high byte
;     0xA0 = status (bit0=discharging, bit1=charging)
;     0xA1 = AC present (bit0=1 = AC)
;
; We probe layout A first, then B, then C.
;
; Exported:
;   battery_state   (byte): 0=unknown, 1=AC, 2=discharging, 3=charging
;   battery_percent (byte): 0-100
;   battery_init    : call once at boot
;   battery_poll    : call from main loop (throttled internally)
; ============================================================================
bits 64

%include "constants.inc"

EC_DATA     equ 0x62
EC_CMD      equ 0x66
EC_IBF      equ (1 << 1)   ; Input buffer full  (busy, can't write)
EC_OBF      equ (1 << 0)   ; Output buffer full (data ready to read)
EC_READ_CMD equ 0x80       ; EC "read register" command

; Layout A registers
EC_REG_A_BAT_CAP    equ 0xA2
EC_REG_A_BAT_FLAGS  equ 0xA3
EC_REG_A_AC_STATUS  equ 0xA4

; Layout B registers (Acer Nitro 2023/2024)
EC_REG_B_BAT_CAP    equ 0x42
EC_REG_B_BAT_FLAGS  equ 0x40
EC_REG_B_AC_STATUS  equ 0x41

; Layout C registers (mWh-based)
EC_REG_C_REM_LO     equ 0xB2
EC_REG_C_REM_HI     equ 0xB3
EC_REG_C_DES_LO     equ 0xB4
EC_REG_C_DES_HI     equ 0xB5
EC_REG_C_STATUS     equ 0xA0
EC_REG_C_AC         equ 0xA1

BAT_STATE_UNKNOWN  equ 0
BAT_STATE_AC       equ 1
BAT_STATE_DISCHARGE equ 2
BAT_STATE_CHARGING equ 3

EC_LAYOUT_NONE  equ 0
EC_LAYOUT_A     equ 1
EC_LAYOUT_B     equ 2
EC_LAYOUT_C     equ 3

section .text

global battery_init
global battery_poll

extern acpi_ec_read

; ============================================================================
; ec_read_reg - wrapper for the ACPI EC read function
; Input:  DL = register address
; Output: AL = register value, CF=0 on success; CF=1 on timeout
; ============================================================================
ec_read_reg:
    mov cl, dl
    call acpi_ec_read
    ret

; ============================================================================
; battery_probe_layout - probe EC to find correct register layout
; Sets bat_layout and primes battery_state/battery_percent
; Returns: AL = layout found (0=none)
; ============================================================================
battery_probe_layout:
    push rbx
    push rdx

    ; --- Try Layout A: reg 0xA2 should be 0-100 ---
    mov dl, EC_REG_A_BAT_CAP
    call ec_read_reg
    jc .try_layout_b
    movzx ebx, al
    cmp bl, 0
    jl .try_layout_b
    cmp bl, 100
    jbe .layout_a_cap_ok
    ; Value > 100 - could be mWh or wrong register - not layout A
    jmp .try_layout_b
.layout_a_cap_ok:
    ; Verify AC register too - bit0 should be 0 or 1
    mov dl, EC_REG_A_AC_STATUS
    call ec_read_reg
    jc .try_layout_b
    and al, 0xFE             ; mask off bit0 - rest should be 0 or predictable
    ; Accept layout A
    mov byte [bat_layout], EC_LAYOUT_A
    mov al, EC_LAYOUT_A
    jmp .probe_done

.try_layout_b:
    ; --- Try Layout B: reg 0x42 should be 0-100 ---
    mov dl, EC_REG_B_BAT_CAP
    call ec_read_reg
    jc .try_layout_c
    movzx ebx, al
    cmp bl, 100
    ja .try_layout_c
    ; Looks like a valid percentage
    mov byte [bat_layout], EC_LAYOUT_B
    mov al, EC_LAYOUT_B
    jmp .probe_done

.try_layout_c:
    ; --- Try Layout C: read design cap (16-bit) and remaining cap ---
    mov dl, EC_REG_C_DES_LO
    call ec_read_reg
    jc .probe_fail
    movzx ebx, al            ; design_lo
    mov dl, EC_REG_C_DES_HI
    call ec_read_reg
    jc .probe_fail
    movzx eax, al
    shl eax, 8
    or ebx, eax              ; ebx = design capacity (mWh/10 typically)
    ; Must be non-zero and reasonable (e.g. 200-10000 range = 2Wh-100Wh)
    cmp ebx, 10
    jl .probe_fail
    cmp ebx, 65000
    jg .probe_fail
    ; Store design capacity for % calculation
    mov [bat_design_cap], bx
    mov byte [bat_layout], EC_LAYOUT_C
    mov al, EC_LAYOUT_C
    jmp .probe_done

.probe_fail:
    mov byte [bat_layout], EC_LAYOUT_NONE
    xor al, al

.probe_done:
    pop rdx
    pop rbx
    ret

; ============================================================================
; battery_do_read - read all EC registers and update state
; Uses layout stored in bat_layout
; ============================================================================
battery_do_read:
    push rax
    push rbx
    push rdx

    movzx eax, byte [bat_layout]
    cmp al, EC_LAYOUT_A
    je .read_layout_a
    cmp al, EC_LAYOUT_B
    je .read_layout_b
    cmp al, EC_LAYOUT_C
    je .read_layout_c
    jmp .done              ; EC_LAYOUT_NONE

; --- Layout A: 0xA2=cap%, 0xA3=flags, 0xA4=AC ---
.read_layout_a:
    mov dl, EC_REG_A_AC_STATUS
    call ec_read_reg
    jc .done
    movzx ebx, al               ; bit0=AC present

    mov dl, EC_REG_A_BAT_CAP
    call ec_read_reg
    jc .done
    cmp al, 100
    jbe .la_cap_ok
    mov al, 100
.la_cap_ok:
    mov [battery_percent], al

    mov dl, EC_REG_A_BAT_FLAGS
    call ec_read_reg
    jc .done
    movzx eax, al               ; bit1=charging

    jmp .determine_state

; --- Layout B: 0x40=flags, 0x41=AC, 0x42=cap% ---
.read_layout_b:
    mov dl, EC_REG_B_AC_STATUS
    call ec_read_reg
    jc .done
    movzx ebx, al               ; bit0=AC present

    mov dl, EC_REG_B_BAT_CAP
    call ec_read_reg
    jc .done
    cmp al, 100
    jbe .lb_cap_ok
    mov al, 100
.lb_cap_ok:
    mov [battery_percent], al

    mov dl, EC_REG_B_BAT_FLAGS
    call ec_read_reg
    jc .done
    movzx eax, al               ; bit1=charging

    jmp .determine_state

; --- Layout C: mWh-based, compute % from remaining/design ---
.read_layout_c:
    mov dl, EC_REG_C_AC
    call ec_read_reg
    jc .done
    movzx ebx, al               ; bit0=AC present

    mov dl, EC_REG_C_REM_LO
    call ec_read_reg
    jc .done
    movzx ecx, al
    mov dl, EC_REG_C_REM_HI
    call ec_read_reg
    jc .done
    movzx eax, al
    shl eax, 8
    or ecx, eax                 ; ecx = remaining mWh/10

    ; Compute percent: remaining * 100 / design
    movzx eax, word [bat_design_cap]
    test eax, eax
    jz .done
    mov eax, ecx
    imul eax, 100
    xor edx, edx
    movzx ecx, word [bat_design_cap]
    div ecx                     ; eax = percent
    cmp eax, 100
    jbe .lc_cap_ok
    mov eax, 100
.lc_cap_ok:
    mov [battery_percent], al

    mov dl, EC_REG_C_STATUS
    call ec_read_reg
    jc .done
    movzx eax, al               ; bit1=charging

    ; Fall through to determine_state

; --- Determine state from EBX (AC bit0) and EAX (charging bit1) ---
.determine_state:
    test bl, 0x01               ; AC present?
    jz .on_battery

    test al, 0x02               ; Charging?
    jnz .state_charging

    mov byte [battery_state], BAT_STATE_AC
    jmp .done

.state_charging:
    mov byte [battery_state], BAT_STATE_CHARGING
    jmp .done

.on_battery:
    mov byte [battery_state], BAT_STATE_DISCHARGE

.done:
    pop rdx
    pop rbx
    pop rax
    ret

; ============================================================================
; battery_init
; ============================================================================
battery_init:
    push rax
    push rdx

    mov byte [battery_state], BAT_STATE_UNKNOWN
    mov byte [battery_percent], 0
    mov byte [bat_ec_ok], 0
    mov byte [bat_layout], EC_LAYOUT_NONE
    mov dword [bat_poll_counter], 0

    ; Serial: 'B'
    mov dx, 0x3F8
    mov al, 'B'
    out dx, al

    ; Probe EC to find working register layout
    call battery_probe_layout
    test al, al
    jz .ec_fail

    mov byte [bat_ec_ok], 1
    call battery_do_read

    mov dx, 0x3F8
    mov al, 'b'
    out dx, al
    jmp .ret

.ec_fail:
    ; EC didn't respond - assume AC power (safe for desktop use)
    mov byte [battery_state], BAT_STATE_AC
    mov byte [battery_percent], 100
    mov dx, 0x3F8
    mov al, '!'
    out dx, al

.ret:
    pop rdx
    pop rax
    ret

; ============================================================================
; battery_poll - throttled poll, call every main loop iteration
; ============================================================================
battery_poll:
    cmp byte [bat_ec_ok], 0
    je .skip

    inc dword [bat_poll_counter]
    cmp dword [bat_poll_counter], 300   ; ~3 seconds at ~100fps
    jl .skip
    mov dword [bat_poll_counter], 0
    call battery_do_read
.skip:
    ret

section .data

global battery_state
global battery_percent

battery_state:    db BAT_STATE_UNKNOWN
battery_percent:  db 0
bat_ec_ok:        db 0
bat_layout:       db EC_LAYOUT_NONE
bat_design_cap:   dw 0           ; Layout C: design capacity (mWh/10)
bat_poll_counter: dd 0
