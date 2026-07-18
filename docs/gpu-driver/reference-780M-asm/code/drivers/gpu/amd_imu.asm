; ============================================================================
; amd_imu.asm - IMU + RLC backdoor autoload scaffolding (Phoenix, gfx_11_0_3)
; ----------------------------------------------------------------------------
; Read-only by default. Provides a builder that scans the FAT16 ramdisk for
; Phoenix GFX firmware blobs and constructs a `psp_gfx_uc_info[]` TOC plus
; concatenated blob region in the existing PSP firmware staging area. No
; hardware contact: IMU GTS registers are NOT written, IMU reset is NOT
; released. The "kick" entry point exists as a stub for the next session
; once real FW blobs are on disk.
;
; Why this lives separate from amd_psp_fwload.asm:
;   amd_psp_fwload assumes PSP LOAD_IP_FW via GPCOM ring. On Phoenix (Ryzen
;   780M), the canonical Linux path is IMU autoload after PSP bootloader has
;   loaded SOS via direct BAR0 MMIO (mp_13_0_5). The two paths share the
;   same FW blob acquisition but diverge in how the firmware gets into the
;   GPU. Keep them in separate files so the abandoned NBIO path can be
;   deleted later without touching this one.
;
; Filename → FW-type mapping
; --------------------------
; The FAT16 ramdisk holds 8.3 names. Linux firmware filenames are too long
; for 8.3 ("gc_11_0_3_pfp.bin" is 17 chars), so the build pipeline renames
; them to a fixed-width "PHXxxx BIN" alias. The mapping table below is the
; single source of truth for that aliasing.
;
; Source: drivers/gpu/drm/amd/amdgpu/psp_gfx_if.h
;         enum psp_gfx_fw_type values
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"
%include "amdgpu_psp.inc"
%include "amdgpu_regs.inc"

section .text

global imu_autoload_build
global imu_autoload_kick
global imu_autoload_status

global imu_autoload_count        ; uint32 - entries successfully placed
global imu_autoload_total_size   ; uint32 - TOC + payload, bytes
global imu_autoload_toc_addr     ; uint64 - phys addr of the TOC
global imu_autoload_missing      ; uint32 - bitmask of expected types absent
global imu_autoload_last_type    ; uint32 - last type scanned (diag)
global imu_autoload_fat_count    ; uint32 - fat16_file_count at scan time
global imu_autoload_first_name   ; 16 bytes - first dir entry name (diag)

extern fat16_file_count
extern fat16_get_entry
extern fat16_read_file
extern gpu_mmio_r32
extern gpu_mmio_w32
extern tick_count
extern gpu_bringup_state

; --- IMU register absolute dword offsets within BAR0 ----------------------
%define GFX_IMU_FW_GTS_LO_DW    ((GC_BASE/4) + mmGFX_IMU_FW_GTS_LO)
%define GFX_IMU_FW_GTS_HI_DW    ((GC_BASE/4) + mmGFX_IMU_FW_GTS_HI)
%define GFX_IMU_CORE_CTRL_DW    ((GC_BASE/4) + mmGFX_IMU_CORE_CTRL)
%define RLC_BOOTLOAD_STATUS_DW  ((GC_BASE/4) + mmRLC_RLCS_BOOTLOAD_STATUS)

; IMU bootload poll budget (~50 ms at 50 Hz PIT = 2 ticks; bump to 100 to
; tolerate slow blob copies). Hardware Linux waits ~1 s in worst case.
%define IMU_BOOTLOAD_TIMEOUT_TICKS  50

; --- Build configuration --------------------------------------------------
; The TOC lives at the very start of the staging region; blobs are packed
; after it, each 4 KiB-aligned (so IMU can DMA them with simple page
; boundaries). The existing GPU_PSP_FW_STAGING_SIZE (512 KiB) is too small
; for the full Phoenix FW set (~3 MiB) but works as a scaffolding-only
; bound. Expand later by repurposing the dormant TMR region.
%define IMU_TOC_RESERVE      0x1000      ; 4 KiB reserved for psp_gfx_uc_info[]
%define IMU_BLOB_ALIGN       0x1000      ; 4 KiB blob alignment

; Required-blob bitmask. If any of these are missing, IMU autoload cannot
; bring CP up. The bit numbers are arbitrary (internal to this driver) -
; one bit per blob we try to load.
%define IMU_REQ_PFP          (1 << 0)
%define IMU_REQ_ME           (1 << 1)
%define IMU_REQ_MEC          (1 << 2)
%define IMU_REQ_RLC          (1 << 3)
%define IMU_REQ_IMU          (1 << 4)
%define IMU_REQ_MES          (1 << 5)
%define IMU_REQ_ALL          (IMU_REQ_PFP | IMU_REQ_ME | IMU_REQ_MEC | \
                              IMU_REQ_RLC | IMU_REQ_IMU | IMU_REQ_MES)

; ---------------------------------------------------------------------------
; uint8 imu_autoload_build(void)
;   Walks the FAT16 root. For each filename matching one of fw_name_table,
;   reads the blob into GPU_PSP_FW_STAGING_BASE+offset and writes one
;   psp_gfx_uc_info entry into the TOC. Returns 1 if at least one blob
;   landed, 0 if none found. Sets imu_autoload_missing to the bitmask of
;   expected types that were absent.
;
;   Side effects: writes to [GPU_PSP_FW_STAGING_BASE, +TOC+payload]. No
;   MMIO. Safe to call before SMU is up.
; ---------------------------------------------------------------------------
imu_autoload_build:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    ; Reset diag state.
    mov  dword [imu_autoload_count], 0
    mov  dword [imu_autoload_total_size], 0
    mov  dword [imu_autoload_missing], IMU_REQ_ALL
    mov  dword [imu_autoload_last_type], 0
    mov  qword [imu_autoload_toc_addr], GPU_PSP_FW_STAGING_BASE
    mov  dword [imu_autoload_fat_count], 0
    mov  qword [imu_autoload_first_name], 0
    mov  qword [imu_autoload_first_name + 8], 0

    ; Diag: capture fat16_file_count and the first dir entry's 11-byte name.
    call fat16_file_count
    mov  [imu_autoload_fat_count], eax
    test eax, eax
    jz   .diag_done
    xor  edi, edi
    call fat16_get_entry
    test rax, rax
    jz   .diag_done
    ; Copy 11 bytes of the FAT entry name into imu_autoload_first_name.
    mov  rcx, [rax]
    mov  [imu_autoload_first_name], rcx
    mov  ecx, [rax + 8]
    mov  [imu_autoload_first_name + 8], ecx
.diag_done:

    ; Zero the TOC reserve so trailing entries cleanly read id=0 (terminator).
    mov  rdi, GPU_PSP_FW_STAGING_BASE
    mov  ecx, IMU_TOC_RESERVE / 8
    xor  rax, rax
    cld
    rep  stosq

    ; r12 = next TOC entry slot (advances by PSP_UC_INFO_STRIDE).
    ; r13 = next blob write offset (advances by aligned blob size).
    mov  r12, GPU_PSP_FW_STAGING_BASE
    mov  r13, IMU_TOC_RESERVE

    ; Iterate the name table. Each entry is 16 bytes:
    ;   [0..10]  11-byte 8.3 alias
    ;   [11]     padding
    ;   [12]     fw_type (uint8)
    ;   [13]     req_bit (uint8) - which IMU_REQ_* bit this represents
    ;   [14..15] padding
    lea  r14, [rel fw_name_table]
.tbl_loop:
    movzx eax, byte [r14 + 12]
    test eax, eax
    jz   .tbl_done                  ; type=0 terminates table

    mov  [imu_autoload_last_type], eax

    ; Locate the file on FAT16.
    call _imu_find_by_name          ; rsi = name @ r14, returns rax=entry or 0
    test rax, rax
    jz   .skip_entry

    ; Read blob into staging at r13.
    mov  rdi, rax                   ; entry ptr
    mov  rsi, GPU_PSP_FW_STAGING_BASE
    add  rsi, r13                   ; dest = base + offset
    mov  edx, GPU_PSP_FW_STAGING_SIZE
    sub  edx, r13d                  ; cap to remaining space
    js   .skip_entry                ; out of room
    jz   .skip_entry
    call fat16_read_file
    test eax, eax
    jz   .skip_entry

    ; Preserve blob size across the bookkeeping that clobbers eax.
    mov  r15d, eax                  ; r15 = blob size

    ; Write TOC entry: id, offset, size, reserved=0
    movzx ecx, byte [r14 + 12]
    mov  [r12 + PSP_UC_INFO_ID], ecx
    mov  [r12 + PSP_UC_INFO_OFFSET], r13d
    mov  [r12 + PSP_UC_INFO_SIZE], r15d
    mov  dword [r12 + PSP_UC_INFO_RESERVED], 0
    add  r12, PSP_UC_INFO_STRIDE

    ; Account for placed blob: clear its req bit, bump count + total_size.
    ; byte [r14+13] holds the BIT INDEX (0..5), not a mask. Shift 1 left.
    movzx ecx, byte [r14 + 13]
    mov  eax, 1
    shl  eax, cl
    not  eax
    and  [imu_autoload_missing], eax
    inc  dword [imu_autoload_count]

    ; Advance r13 by aligned blob size.
    add  r13, r15
    add  r13, IMU_BLOB_ALIGN - 1
    and  r13, ~(IMU_BLOB_ALIGN - 1)

.skip_entry:
    add  r14, 16
    jmp  .tbl_loop

.tbl_done:
    mov  [imu_autoload_total_size], r13d

    ; Success = at least one blob placed.
    cmp  dword [imu_autoload_count], 0
    sete al
    xor  al, 1                      ; al=1 if count>0

    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rdx
    pop  rcx
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint8 imu_autoload_kick(void)
;   Real implementation. Writes the autoload buffer base to GFX_IMU_FW_GTS_*,
;   releases IMU core reset, and polls RLC_RLCS_BOOTLOAD_STATUS bit 31
;   (BOOTLOAD_COMPLETE) with a finite timeout.
;
;   Status byte semantics:
;     0 = untouched (build not yet attempted)
;     1 = blocked: required blobs absent
;     2 = kicked but bootload timed out
;     3 = bootload reported complete
;
;   On status==3, advances gpu_bringup_state to GPU_STATE_CP_LOADED so the
;   existing cp_gfx_start_nop path can run unchanged. (The state name is
;   legacy from the PSP-LOAD_IP_FW era; here it means "ucode is in IC".)
;
;   PROVISIONAL: GFX_IMU_FW_GTS_LO/HI/CORE_CTRL register offsets are
;   guessed from gc_11_0_0 templates and may be wrong. If kick wedges,
;   strip the IMU kick out of gfx_bringup, decode the live offsets from
;   the discovery table, and try again.
; ---------------------------------------------------------------------------
imu_autoload_kick:
    push rbx
    push rcx
    push rdi
    push rsi

    cmp  dword [imu_autoload_missing], 0
    jne  .blocked

    ; (1) Program FW directory phys address (the start of our staging
    ;     region - which is where imu_autoload_build placed the TOC).
    mov  rax, GPU_PSP_FW_STAGING_BASE
    mov  edi, GFX_IMU_FW_GTS_LO_DW
    mov  esi, eax
    call gpu_mmio_w32
    mov  rax, GPU_PSP_FW_STAGING_BASE
    shr  rax, 32
    mov  edi, GFX_IMU_FW_GTS_HI_DW
    mov  esi, eax
    call gpu_mmio_w32

    ; (2) Release IMU core reset. Bit 0 = CORE_RESET_N (active high; 1 to
    ;     bring the core out of reset).
    mov  edi, GFX_IMU_CORE_CTRL_DW
    mov  esi, 1
    call gpu_mmio_w32

    ; (3) Poll BOOTLOAD_STATUS bit 31.
    mov  ebx, [tick_count]
    add  ebx, IMU_BOOTLOAD_TIMEOUT_TICKS
.poll:
    mov  edi, RLC_BOOTLOAD_STATUS_DW
    call gpu_mmio_r32
    test eax, 0x80000000
    jnz  .complete
    mov  ecx, [tick_count]
    cmp  ecx, ebx
    jb   .poll

    ; Timeout.
    mov  byte [imu_autoload_status], 2
    xor  al, al
    pop  rsi
    pop  rdi
    pop  rcx
    pop  rbx
    ret

.complete:
    mov  byte [imu_autoload_status], 3
    mov  byte [gpu_bringup_state], GPU_STATE_CP_LOADED
    mov  al, 1
    pop  rsi
    pop  rdi
    pop  rcx
    pop  rbx
    ret

.blocked:
    mov  byte [imu_autoload_status], 1
    xor  al, al
    pop  rsi
    pop  rdi
    pop  rcx
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; Internal: _imu_find_by_name
;   r14 → pointer to a 16-byte fw_name_table entry (first 11 bytes are the
;   alias). Returns rax = 32-byte FAT16 dir-entry ptr, or 0 if not found.
;   Clobbers rax, rbx, rcx, rdx, rdi, rsi (callees may clobber more).
; ---------------------------------------------------------------------------
_imu_find_by_name:
    push r8
    push r9
    push r10
    call fat16_file_count
    mov  r9d, eax                   ; r9 = count
    xor  r10d, r10d                 ; r10 = idx
.fnd:
    cmp  r10d, r9d
    jae  .none
    mov  edi, r10d
    call fat16_get_entry
    test rax, rax
    jz   .next
    ; Compare 11 bytes [rax] vs [r14].
    push rcx
    push rsi
    push rdi
    mov  rsi, r14
    mov  rdi, rax
    mov  ecx, 11
    repe cmpsb
    pop  rdi
    pop  rsi
    pop  rcx
    je   .hit                       ; rax already = entry
.next:
    inc  r10d
    jmp  .fnd
.none:
    xor  rax, rax
.hit:
    pop  r10
    pop  r9
    pop  r8
    ret

; ===========================================================================
section .data
align 16

; fw_name_table - 11-byte 8.3 alias, pad, fw_type, req_bit, pad pad.
; Entries terminated by a row with fw_type == 0.
;
; Alias convention: "PHXxxx  BIN" where xxx is a short tag. Rename the
; linux-firmware blobs to these names when copying to the ramdisk:
;
;   gc_11_0_3_pfp.bin       -> PHXPFP.BIN
;   gc_11_0_3_me.bin        -> PHXME.BIN
;   gc_11_0_3_mec.bin       -> PHXMEC.BIN
;   gc_11_0_3_rlc.bin       -> PHXRLC.BIN   (or use existing GC115RLC.BIN if family matches)
;   gc_11_0_3_imu.bin       -> PHXIMU.BIN
;   gc_11_0_3_mes_2.bin     -> PHXMES.BIN
;   amdgpu/sdma_6_0_2.bin   -> PHXSDMA.BIN
fw_name_table:
    ;     |--- 11 bytes 8.3 ---|pad|type                |req_bit            |pad pad
    db "PHXPFP  BIN",         0,  PSP_GFX_FW_TYPE_CP_PFP, 0  ; req_bit set below
    db 0, 0
    db "PHXME   BIN",         0,  PSP_GFX_FW_TYPE_CP_ME,  1
    db 0, 0
    db "PHXMEC  BIN",         0,  PSP_GFX_FW_TYPE_CP_MEC, 2
    db 0, 0
    db "PHXRLC  BIN",         0,  PSP_GFX_FW_TYPE_RLC_G,  3
    db 0, 0
    db "PHXIMU  BIN",         0,  PSP_GFX_FW_TYPE_IMU_I,  4
    db 0, 0
    db "PHXMES  BIN",         0,  PSP_GFX_FW_TYPE_CP_MES, 5
    db 0, 0
    ; Terminator - type=0 stops _imu_find_by_name walk.
    db "           ",         0,  0,                       0
    db 0, 0

; Fix PHXPFP req_bit to 0 (the inline initialiser above had a typo of "0"
; for the first row; replaced here via duplicate-label trick at runtime).
; Note: the data above intentionally encodes req_bit at byte 13; bit 0=PFP,
; 1=ME, 2=MEC, 3=RLC, 4=IMU, 5=MES. The first row's req_bit needs to be 0
; to match IMU_REQ_PFP = (1<<0); the inline value above is already 0.

align 4
imu_autoload_count:        dd 0
imu_autoload_total_size:   dd 0
imu_autoload_missing:      dd IMU_REQ_ALL
imu_autoload_last_type:    dd 0
imu_autoload_fat_count:    dd 0
align 8
imu_autoload_first_name:   times 16 db 0
align 8
imu_autoload_toc_addr:     dq 0
align 1
imu_autoload_status:       db 0           ; 0=untouched, 1=blocked, 2=would-kick
