; ============================================================================
; NexusOS v3.0 - ACPI Embedded Controller Driver
; Safely reads/writes EC registers per ACPI Specification 12.2
; Handles EmbeddedControl region operations for battery, thermals, etc
; ============================================================================
bits 64

%include "constants.inc"

section .text
global acpi_ec_init
global acpi_ec_read
global acpi_ec_write

; ACPI EC Command/Status port normally 0x66
; ACPI EC Data port normally 0x62
EC_DATA_PORT equ 0x62
EC_CMD_PORT  equ 0x66

acpi_ec_init:
    ; Provide pointer to EC node from DSDT/ECDT
    ret

; ec_wait_ibf
; Waits until IBF=0
ec_wait_ibf:
    push rax
    push rcx
    mov ecx, 500000
.loop:
    in al, EC_CMD_PORT
    test al, 0x02
    jz .ok
    dec ecx
    jnz .loop
    pop rcx
    pop rax
    stc
    ret
.ok:
    pop rcx
    pop rax
    clc
    ret

; ec_wait_obf
; Waits until OBF=1
ec_wait_obf:
    push rax
    push rcx
    mov ecx, 500000
.loop:
    in al, EC_CMD_PORT
    test al, 0x01
    jnz .ok
    dec ecx
    jnz .loop
    pop rcx
    pop rax
    stc
    ret
.ok:
    pop rcx
    pop rax
    clc
    ret


acpi_ec_read:
    ; CL = register address
    ; Returns AL = data, CF=0 ok, CF=1 error
    push rcx
    push rdx

    ; Drain any stale OBF data first (avoids reading leftover bytes)
    mov edx, 8
.drain_obf:
    in al, EC_CMD_PORT
    test al, 0x01
    jz .drained
    in al, EC_DATA_PORT
    dec edx
    jnz .drain_obf
.drained:

    pop rdx
    
    call ec_wait_ibf
    jc .fail

    ; Send EC READ command (0x80)
    mov al, 0x80
    out EC_CMD_PORT, al
    
    call ec_wait_ibf
    jc .fail
    
    ; Send address
    mov al, cl
    out EC_DATA_PORT, al
    
    call ec_wait_obf
    jc .fail
    
    ; Read data
    in al, EC_DATA_PORT
    pop rcx
    clc
    ret
.fail:
    pop rcx
    stc
    ret

acpi_ec_write:
    ; CL = register address, DL = data
    push rcx
    
    call ec_wait_ibf
    jc .wfail

    ; Send EC WRITE command (0x81)
    mov al, 0x81
    out EC_CMD_PORT, al
    
    call ec_wait_ibf
    jc .wfail
    
    ; Send address
    mov al, cl
    out EC_DATA_PORT, al
    
    call ec_wait_ibf
    jc .wfail
    
    ; Send data
    mov al, dl
    out EC_DATA_PORT, al
    
    pop rcx
    clc
    ret
.wfail:
    pop rcx
    stc
    ret
