; ============================================================================
; amd_dcn_fw.asm - DMCUB firmware blob loader & parser
;
; Phase 1 (this file): read-only. Locates the firmware on the ramdisk,
; reads it into a buffer, validates the dmcub_firmware_header_v1_0, and
; scans for the dmub_fw_meta_info magic (0x444D5542) to surface
; fw_region_size / trace_buffer_size / shared_state_size / fw_version.
;
; Phase 2 (future): use the parsed metadata to size GPU-visible work
; regions, copy fw_inst_const into CW0 area, program windows CW0-CW7,
; soft-reset DMCUB, release, poll boot_status for MAILBOX_READY.
;
; Reference: Linux drivers/gpu/drm/amd/display/dmub/src/dmub_srv.c and
; drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c. See also
; assets/firmware/README.md for blob layout.
; ============================================================================

[BITS 64]

section .text

extern fat16_file_count
extern fat16_get_entry
extern fat16_read_file

global amd_dcn_fw_probe

; Buffer for raw firmware blob. 1MB is enough for the largest known
; DMCUB image (~522KB for DCN 3.5). Above BOOT_ANIM_BUF region.
%define AMD_DCN_FW_BUF       0x7000000
%define AMD_DCN_FW_BUF_SIZE  0x100000          ; 1MB

%define DMUB_FW_META_MAGIC   0x444D5542         ; 'DMUB' little-endian
%define DMUB_FW_PSP_HDR      0x100              ; PSP header bytes
%define DMUB_FW_PSP_FOOTER   0x100              ; PSP footer bytes
%define DMUB_FW_META_SIZE    64                 ; union dmub_fw_meta is 64B
%define DMUB_FW_META_TAIL    0x24               ; DMUB_FW_META_OFFSET from end

; Common firmware header layout (40 bytes total). Offsets within blob:
%define DMCUB_HDR_SIZE_BYTES         0
%define DMCUB_HDR_HEADER_SIZE        4
%define DMCUB_HDR_HVER_MAJ           8           ; uint16
%define DMCUB_HDR_HVER_MIN           10
%define DMCUB_HDR_IP_MAJ             12
%define DMCUB_HDR_IP_MIN             14
%define DMCUB_HDR_UCODE_VER          16
%define DMCUB_HDR_UCODE_SIZE         20
%define DMCUB_HDR_UCODE_OFF          24
%define DMCUB_HDR_CRC32              28
%define DMCUB_HDR_INST_CONST_BYTES   32
%define DMCUB_HDR_BSS_DATA_BYTES     36

; meta_info field offsets (relative to magic):
%define DMUB_META_MAGIC               0
%define DMUB_META_FW_REGION_SIZE      4
%define DMUB_META_TRACE_BUFFER_SIZE   8
%define DMUB_META_FW_VERSION          12
%define DMUB_META_DAL_FW              16
%define DMUB_META_SHARED_STATE_SIZE   20
%define DMUB_META_SHARED_FEATURES     24
%define DMUB_META_FEATURE_BITS        28

; ----------------------------------------------------------------------------
; amd_dcn_fw_probe
;  Find DCN35DMC.BIN on the ramdisk, read+parse, populate globals.
;  Safe to call multiple times; second call reuses results.
;  No DMCUB writes - purely read-only.
; ----------------------------------------------------------------------------
amd_dcn_fw_probe:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12

    cmp byte [amd_dcn_fw_probed], 0
    jne .done                          ; idempotent
    mov byte [amd_dcn_fw_probed], 1

    ; Locate "DCN35DMC.BIN" → 11-byte 8.3 name "DCN35DMCBIN"
    call fat16_file_count
    mov ecx, eax
    xor ebx, ebx
.find_loop:
    cmp ebx, ecx
    jge .not_found
    mov edi, ebx
    call fat16_get_entry
    test rax, rax
    jz .not_found
    lea rsi, [rel amd_dcn_fw_name]
    mov rdi, rax
    push rcx
    mov ecx, 11
    repe cmpsb
    pop rcx
    je .found
    inc ebx
    jmp .find_loop

.not_found:
    mov dword [amd_dcn_fw_status], 0x00000001   ; bit0 = not found
    jmp .done

.found:
    mov byte [amd_dcn_fw_status + 0], 0          ; clear, set bit1 below
    or dword [amd_dcn_fw_status], 0x00000002    ; bit1 = found on FS

    ; Read into AMD_DCN_FW_BUF (rdi=entry from rax-1 step; recompute)
    mov edi, ebx
    call fat16_get_entry
    test rax, rax
    jz .done                ; race shouldn't happen but bail safely
    mov rdi, rax
    mov rsi, AMD_DCN_FW_BUF
    mov edx, AMD_DCN_FW_BUF_SIZE
    call fat16_read_file
    cmp eax, 64
    jl .read_failed                     ; need at least header bytes
    mov [amd_dcn_fw_size], eax
    or dword [amd_dcn_fw_status], 0x00000004    ; bit2 = read ok
    jmp .parse_header

.read_failed:
    or dword [amd_dcn_fw_status], 0x00000008    ; bit3 = read failed
    jmp .done

.parse_header:
    mov rbx, AMD_DCN_FW_BUF
    mov eax, [rbx + DMCUB_HDR_INST_CONST_BYTES]
    mov [amd_dcn_fw_inst_const_bytes], eax
    mov eax, [rbx + DMCUB_HDR_BSS_DATA_BYTES]
    mov [amd_dcn_fw_bss_data_bytes], eax
    mov eax, [rbx + DMCUB_HDR_UCODE_OFF]
    mov [amd_dcn_fw_ucode_off], eax
    mov eax, [rbx + DMCUB_HDR_UCODE_SIZE]
    mov [amd_dcn_fw_ucode_size], eax
    movzx eax, word [rbx + DMCUB_HDR_HVER_MAJ]
    movzx edx, word [rbx + DMCUB_HDR_HVER_MIN]
    shl edx, 16
    or eax, edx
    mov [amd_dcn_fw_hver], eax
    movzx eax, word [rbx + DMCUB_HDR_IP_MAJ]
    movzx edx, word [rbx + DMCUB_HDR_IP_MIN]
    shl edx, 16
    or eax, edx
    mov [amd_dcn_fw_ipver], eax

    ; Scan for meta magic.
    ; ptr0    = ucode_off + PSP_HDR              (start of fw_inst_const)
    ; size0   = inst_const_bytes - PSP_HDR       (post-header inst_const)
    ; effsz   = size0 - PSP_FOOTER               (drop PSP footer)
    ; meta_at = ptr0 + effsz - i - 64 for i in 0..15
    ;
    ; Stored offsets are FILE OFFSETS (from buf start).
    mov r8d, [amd_dcn_fw_ucode_off]
    add r8d, DMUB_FW_PSP_HDR                    ; r8 = inst_const file off
    mov r9d, [amd_dcn_fw_inst_const_bytes]
    sub r9d, DMUB_FW_PSP_HDR                    ; r9 = inst_const usable size
    js .meta_not_found
    mov r10d, r9d
    sub r10d, DMUB_FW_PSP_FOOTER                ; r10 = scan-region size
    js .meta_not_found
    sub r10d, DMUB_FW_META_SIZE                 ; r10 -= 64
    js .meta_not_found

    xor r11d, r11d                              ; i = 0
.meta_scan:
    cmp r11d, 16
    jge .meta_not_found
    mov r12d, r10d
    sub r12d, r11d                              ; offset within inst_const
    add r12d, r8d                               ; absolute file offset
    ; Bounds check
    mov edx, [amd_dcn_fw_size]
    sub edx, DMUB_FW_META_SIZE
    cmp r12d, edx
    jg .meta_next
    mov rdx, AMD_DCN_FW_BUF
    add rdx, r12
    cmp dword [rdx + DMUB_META_MAGIC], DMUB_FW_META_MAGIC
    je .meta_found
.meta_next:
    inc r11d
    jmp .meta_scan

.meta_not_found:
    or dword [amd_dcn_fw_status], 0x00000010    ; bit4 = meta not found
    jmp .done

.meta_found:
    or dword [amd_dcn_fw_status], 0x00000020    ; bit5 = meta found
    mov [amd_dcn_fw_meta_off], r12d
    mov eax, [rdx + DMUB_META_FW_REGION_SIZE]
    mov [amd_dcn_fw_region_size], eax
    mov eax, [rdx + DMUB_META_TRACE_BUFFER_SIZE]
    mov [amd_dcn_fw_trace_buf_size], eax
    mov eax, [rdx + DMUB_META_FW_VERSION]
    mov [amd_dcn_fw_version], eax
    movzx eax, byte [rdx + DMUB_META_DAL_FW]
    mov [amd_dcn_fw_dal_fw], al
    mov eax, [rdx + DMUB_META_SHARED_STATE_SIZE]
    mov [amd_dcn_fw_shared_state_size], eax
    movzx eax, word [rdx + DMUB_META_SHARED_FEATURES]
    mov [amd_dcn_fw_shared_features], ax
    mov eax, [rdx + DMUB_META_FEATURE_BITS]
    mov [amd_dcn_fw_feature_bits], eax

.done:
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Globals
; ============================================================================
global amd_dcn_fw_probed
global amd_dcn_fw_status
global amd_dcn_fw_size
global amd_dcn_fw_ucode_off
global amd_dcn_fw_ucode_size
global amd_dcn_fw_inst_const_bytes
global amd_dcn_fw_bss_data_bytes
global amd_dcn_fw_hver
global amd_dcn_fw_ipver
global amd_dcn_fw_meta_off
global amd_dcn_fw_region_size
global amd_dcn_fw_trace_buf_size
global amd_dcn_fw_version
global amd_dcn_fw_dal_fw
global amd_dcn_fw_shared_state_size
global amd_dcn_fw_shared_features
global amd_dcn_fw_feature_bits

section .data
align 16
amd_dcn_fw_name: db "DCN35DMCBIN", 0       ; FAT 8.3 form

amd_dcn_fw_probed:             db 0
amd_dcn_fw_dal_fw:             db 0
amd_dcn_fw_shared_features:    dw 0
                               db 0, 0     ; pad
amd_dcn_fw_status:             dd 0
amd_dcn_fw_size:               dd 0
amd_dcn_fw_ucode_off:          dd 0
amd_dcn_fw_ucode_size:         dd 0
amd_dcn_fw_inst_const_bytes:   dd 0
amd_dcn_fw_bss_data_bytes:     dd 0
amd_dcn_fw_hver:               dd 0       ; lo16=major hi16=minor
amd_dcn_fw_ipver:              dd 0       ; lo16=major hi16=minor
amd_dcn_fw_meta_off:           dd 0
amd_dcn_fw_region_size:        dd 0
amd_dcn_fw_trace_buf_size:     dd 0
amd_dcn_fw_version:            dd 0
amd_dcn_fw_shared_state_size:  dd 0
amd_dcn_fw_feature_bits:       dd 0
