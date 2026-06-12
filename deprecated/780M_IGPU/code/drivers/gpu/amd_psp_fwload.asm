; ============================================================================
; amd_psp_fwload.asm - PSP signed firmware loader (Wave 3 K/L)
; ----------------------------------------------------------------------------
; Task K: load the RLC-G signed blob (GC115RLC.BIN) via PSP GFX_CMD_LOAD_IP_FW.
; Task L: load CP PFP, ME, MEC signed blobs (GC115PFP/ME/MEC.BIN) the same way.
;
; All loaders share `_psp_load_one`: locate an 8.3 file on the FAT16 ramdisk,
; copy verbatim to GPU_PSP_FW_STAGING_BASE, build a LOAD_IP_FW command, and
; submit it through the PSP GPCOM ring.
;
; The PSP parses the AMD-signed blob header itself. Do not strip, wrap, or
; rewrite the linux-firmware binary.
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"
%include "amdgpu_psp.inc"

section .text

global psp_load_rlc
global psp_load_cp
global psp_fw_substep
global psp_fw_status
global psp_rlc_size
global psp_rlc_ack
global psp_rlc_fw_addr_lo
global psp_rlc_fw_addr_hi
global psp_cp_ack
global psp_pfp_size
global psp_pfp_ack
global psp_me_size
global psp_me_ack
global psp_mec_size
global psp_mec_ack
global psp_cp_substep
global psp_cp_last_type

extern fat16_file_count
extern fat16_get_entry
extern fat16_read_file
extern psp_init
extern psp_zero_cmd
extern psp_submit_cmd

; Firmware status bits (shared across blob types; the per-blob substep + ack
; words narrow down which load failed).
%define PSP_FW_STATUS_NOT_FOUND      0x00000001
%define PSP_FW_STATUS_FOUND          0x00000002
%define PSP_FW_STATUS_READ_OK        0x00000004
%define PSP_FW_STATUS_READ_FAIL      0x00000008
%define PSP_FW_STATUS_TOO_LARGE      0x00000010
%define PSP_FW_STATUS_PSP_REJECT     0x00000020

; ---------------------------------------------------------------------------
; uint8 _psp_load_one(name_ptr /*rsi*/, fw_type /*edi*/,
;                     out_size_ptr /*r8*/, out_ack_ptr /*r9*/)
;   Locate the 11-char 8.3 file named at [rsi], read it into staging, and
;   submit LOAD_IP_FW with the given type. Writes blob size to [r8] and the
;   PSP response status to [r9]. Returns al=1 on PSP ack==0, else al=0.
;   Caller is responsible for OR-ing failure flags into psp_fw_status.
; ---------------------------------------------------------------------------
_psp_load_one:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15

    mov  r12, rsi                       ; save name ptr
    mov  r13d, edi                      ; save fw type
    mov  r14, r8                        ; save out_size_ptr
    mov  r15, r9                        ; save out_ack_ptr

    ; Locate file on FAT16 ramdisk by 11-char name compare.
    call fat16_file_count
    mov  ecx, eax
    xor  ebx, ebx
.find_loop:
    cmp  ebx, ecx
    jge  .not_found
    mov  edi, ebx
    call fat16_get_entry
    test rax, rax
    jz   .not_found
    mov  rsi, r12
    mov  rdi, rax
    push rcx
    mov  ecx, 11
    repe cmpsb
    pop  rcx
    je   .found
    inc  ebx
    jmp  .find_loop

.not_found:
    or   dword [psp_fw_status], PSP_FW_STATUS_NOT_FOUND
    jmp  .fail

.found:
    or   dword [psp_fw_status], PSP_FW_STATUS_FOUND

    ; Re-resolve the entry for fat16_read_file (it wants the entry ptr).
    mov  edi, ebx
    call fat16_get_entry
    test rax, rax
    jz   .fail
    mov  rdi, rax
    mov  rsi, GPU_PSP_FW_STAGING_BASE
    mov  edx, GPU_PSP_FW_STAGING_SIZE
    call fat16_read_file
    test eax, eax
    jz   .read_fail
    cmp  eax, GPU_PSP_FW_STAGING_SIZE
    ja   .too_large

    ; Store blob size.
    mov  [r14], eax
    mov  ebx, eax                       ; ebx = size, preserved across psp call
    or   dword [psp_fw_status], PSP_FW_STATUS_READ_OK

    ; Build LOAD_IP_FW command.
    call psp_zero_cmd
    mov  rdi, GPU_PSP_CMD_BASE
    mov  dword [rdi + PSP_CMD_ID], PSP_GFX_CMD_LOAD_IP_FW
    mov  dword [rdi + PSP_IP_FW_ADDR_LO], GPU_PSP_FW_STAGING_BASE
    mov  dword [rdi + PSP_IP_FW_ADDR_HI], 0
    mov  [rdi + PSP_IP_FW_SIZE], ebx
    mov  [rdi + PSP_IP_FW_TYPE], r13d

    mov  edi, PSP_GFX_CMD_LOAD_IP_FW
    call psp_submit_cmd
    test al, al
    jz   .psp_reject

    mov  rdi, GPU_PSP_CMD_BASE
    mov  eax, [rdi + PSP_CMD_RESP_STATUS]
    mov  [r15], eax
    test eax, eax
    jnz  .psp_reject

    mov  al, 1
    jmp  .out

.read_fail:
    or   dword [psp_fw_status], PSP_FW_STATUS_READ_FAIL
    jmp  .fail
.too_large:
    or   dword [psp_fw_status], PSP_FW_STATUS_TOO_LARGE
    jmp  .fail
.psp_reject:
    or   dword [psp_fw_status], PSP_FW_STATUS_PSP_REJECT
.fail:
    xor  al, al
.out:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rsi
    pop  rdi
    pop  rdx
    pop  rcx
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint8 psp_load_rlc(void) - Task K
;   Preconditions: GPU_STATE_RING_ALLOCATED or later. psp_init advances to
;   GPU_STATE_PSP_READY before LOAD_IP_FW is submitted.
; ---------------------------------------------------------------------------
psp_load_rlc:
    push rbx
    mov  byte [psp_fw_substep], 0
    cmp  byte [gpu_bringup_state], GPU_STATE_RLC_LOADED
    jae  .already

    call psp_init
    test al, al
    jz   .fail
    mov  byte [psp_fw_substep], 1

    lea  rsi, [rel psp_rlc_fw_name]
    mov  edi, PSP_GFX_FW_TYPE_RLC_G
    lea  r8,  [rel psp_rlc_size]
    lea  r9,  [rel psp_rlc_ack]
    call _psp_load_one
    test al, al
    jz   .fail
    mov  byte [psp_fw_substep], 4

    ; Snapshot the FW addr-back the PSP returns (informational; some types
    ; report where the firmware landed in TMR).
    mov  rdi, GPU_PSP_CMD_BASE
    mov  eax, [rdi + PSP_CMD_RESP_FW_ADDR_LO]
    mov  [psp_rlc_fw_addr_lo], eax
    mov  eax, [rdi + PSP_CMD_RESP_FW_ADDR_HI]
    mov  [psp_rlc_fw_addr_hi], eax

    mov  byte [gpu_bringup_state], GPU_STATE_RLC_LOADED
.already:
    mov  al, 1
    pop  rbx
    ret
.fail:
    xor  al, al
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint8 psp_load_cp(void) - Task L
;   Load PFP, ME, MEC in that order. State advances to GPU_STATE_CP_LOADED on
;   success. CP halts are not touched here; that is cp_gfx_start_nop's job.
; ---------------------------------------------------------------------------
psp_load_cp:
    push rbx

    mov  byte [psp_cp_substep], 0
    cmp  byte [gpu_bringup_state], GPU_STATE_CP_LOADED
    jae  .already
    cmp  byte [gpu_bringup_state], GPU_STATE_RLC_LOADED
    jb   .fail

    call psp_init
    test al, al
    jz   .fail
    mov  byte [psp_cp_substep], 1

    ; PFP
    mov  dword [psp_cp_last_type], PSP_GFX_FW_TYPE_CP_PFP
    lea  rsi, [rel psp_pfp_fw_name]
    mov  edi, PSP_GFX_FW_TYPE_CP_PFP
    lea  r8,  [rel psp_pfp_size]
    lea  r9,  [rel psp_pfp_ack]
    call _psp_load_one
    test al, al
    jz   .fail
    mov  byte [psp_cp_substep], 2

    ; ME
    mov  dword [psp_cp_last_type], PSP_GFX_FW_TYPE_CP_ME
    lea  rsi, [rel psp_me_fw_name]
    mov  edi, PSP_GFX_FW_TYPE_CP_ME
    lea  r8,  [rel psp_me_size]
    lea  r9,  [rel psp_me_ack]
    call _psp_load_one
    test al, al
    jz   .fail
    mov  byte [psp_cp_substep], 3

    ; MEC
    mov  dword [psp_cp_last_type], PSP_GFX_FW_TYPE_CP_MEC
    lea  rsi, [rel psp_mec_fw_name]
    mov  edi, PSP_GFX_FW_TYPE_CP_MEC
    lea  r8,  [rel psp_mec_size]
    lea  r9,  [rel psp_mec_ack]
    call _psp_load_one
    test al, al
    jz   .fail
    mov  byte [psp_cp_substep], 4

    ; Mirror the last ack into the legacy psp_cp_ack symbol so callers can
    ; check a single field for "all three accepted".
    mov  eax, [psp_mec_ack]
    mov  [psp_cp_ack], eax

    mov  byte [gpu_bringup_state], GPU_STATE_CP_LOADED
.already:
    mov  al, 1
    pop  rbx
    ret
.fail:
    xor  al, al
    pop  rbx
    ret

; ---------------------------------------------------------------------------
section .data
align 16
psp_rlc_fw_name:        db "GC115RLCBIN", 0
psp_pfp_fw_name:        db "GC115PFPBIN", 0
psp_me_fw_name:         db "GC115ME BIN", 0     ; 8.3 padded: "GC115ME " + "BIN"
psp_mec_fw_name:        db "GC115MECBIN", 0

align 4
psp_fw_status:          dd 0
psp_rlc_size:           dd 0
psp_rlc_ack:            dd 0
psp_rlc_fw_addr_lo:     dd 0
psp_rlc_fw_addr_hi:     dd 0
psp_cp_ack:             dd 0
psp_pfp_size:           dd 0
psp_pfp_ack:            dd 0
psp_me_size:            dd 0
psp_me_ack:             dd 0
psp_mec_size:           dd 0
psp_mec_ack:            dd 0
psp_cp_last_type:       dd 0
align 1
psp_fw_substep:         db 0
psp_cp_substep:         db 0
