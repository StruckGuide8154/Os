; ============================================================================
; GritOS v3.0 - ACPI Embedded Controller Driver
; Safely reads/writes EC registers per ACPI Specification 12.2
; Handles EmbeddedControl region operations for battery, thermals, etc
; ============================================================================
bits 64

%include "constants.inc"

section .text
global acpi_ec_init
global acpi_ec_read
global acpi_ec_write
global acpi_ec_dump_zone
global acpi_ec_dump_low
global acpi_ec_dump_high
global acpi_ec_dump_mid
global acpi_ec_dump_ok

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

; ---------------------------------------------------------------------------
; acpi_ec_dump_zone
;   Reads two 32-byte zones of EC RAM into acpi_ec_dump_low (0x00..0x1F) and
;   acpi_ec_dump_high (0x70..0x8F). On most Acer/Insyde-based laptops these
;   cover lid switch (~0x10), AC adapter (~0x70), battery present/level, and
;   thermal/fan tach. We DUMP only -- no writes -- so the '=' overlay can
;   show raw bytes and we can identify offsets empirically.
;
;   Sets acpi_ec_dump_ok = 1 if at least the first read succeeded, else 0.
; ---------------------------------------------------------------------------
acpi_ec_dump_zone:
    push rax
    push rcx
    push rdx
    push rdi
    push rbx

    mov byte [acpi_ec_dump_ok], 0
    lea rdi, [acpi_ec_dump_low]
    mov ebx, 0x00              ; start offset
    mov ecx, 32                ; bytes to read
.lp1:
    push rcx
    mov cl, bl
    call acpi_ec_read
    jc  .fail_low
    mov [rdi], al
    pop rcx
    inc rdi
    inc ebx
    dec ecx
    jnz .lp1
    mov byte [acpi_ec_dump_ok], 1

    ; Mid zone 0x20..0x6F (80 bytes) - covers thermal/fan + likely
    ; brightness scratch byte that firmware updates on Fn-brightness keys.
    lea rdi, [acpi_ec_dump_mid]
    mov ebx, 0x20
    mov ecx, 80
.lpm:
    push rcx
    mov cl, bl
    call acpi_ec_read
    jc  .pop_skipm
    mov [rdi], al
.pop_skipm:
    pop rcx
    inc rdi
    inc ebx
    dec ecx
    jnz .lpm

    lea rdi, [acpi_ec_dump_high]
    mov ebx, 0x70
    mov ecx, 32
.lp2:
    push rcx
    mov cl, bl
    call acpi_ec_read
    jc  .pop_skip
    mov [rdi], al
.pop_skip:
    pop rcx
    inc rdi
    inc ebx
    dec ecx
    jnz .lp2
    jmp .done

.fail_low:
    pop rcx
.done:
    pop rbx
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

section .data
acpi_ec_dump_ok:   db 0
                   times 3 db 0
acpi_ec_dump_low:  times 32 db 0
acpi_ec_dump_mid:  times 80 db 0
acpi_ec_dump_high: times 32 db 0
