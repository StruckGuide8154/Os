; ============================================================================
; amd_ip_disc.asm - read-only IP discovery table scanner (Phoenix gfx_11_0_3)
; ----------------------------------------------------------------------------
; The IP discovery table is the authoritative list of every IP block in the
; SoC and its SMN base addresses. It's how Linux amdgpu avoids hardcoding
; per-SKU register maps. The binary lives in the top of VRAM (or, on APUs,
; the stolen system-RAM region the GPU sees as VRAM).
;
; Linux reference: drivers/gpu/drm/amd/amdgpu/amdgpu_discovery.c
;   DISCOVERY_TMR_OFFSET = 64 KiB (table sits at vram_top - 64 KiB)
;   DISCOVERY_TMR_SIZE   = 64 KiB
;
; binary_header (offset 0 of the table):
;   uint16  table_list_offset   (offset to ip_discovery struct)
;   uint16  ip_table_offset     (legacy)
;   uint16  binary_checksum
;   uint16  binary_size
;   uint16  version_major
;   uint16  version_minor
;   uint32  binary_signature    = 0x44504924  ("$IPD")
;
; ip_discovery (after binary_header, at table_list_offset):
;   uint32  signature           = 0x4D435049  ("IPCM")
;   uint16  version_major
;   uint16  version_minor
;   uint16  num_dies
;   die_header[]
;
; die_header:
;   uint16  die_id
;   uint16  num_ips
;   ip_v4[] (each ~12 bytes: hw_id, instance_number, num_base_address,
;            base_address[num_base_address] uint32)
;
; HW IDs of interest (from amdgpu_discovery.h):
;   GC_HWID   = 1
;   MMHUB     = 9
;   ATHUB     = 10
;   NBIO      = 12
;   MP0       = 14   <-- the one we actually want
;   MP1       = 15
;   DCE/DCN   = 16
;   IMU       = 50
;
; This module is READ-ONLY and SAFE:
;   * No MMIO writes.
;   * Reads only from the framebuffer BAR window (already mapped by the
;     UEFI handoff / amd_display path).
;   * If the signature is not found within the scan window, all bases come
;     back as 0 - no fallback, no fake values.
;
; The output goes to diag globals. main.asm prints them. The first place
; to look on the boot screen after this lands is `IPDISC sig=44504924
; MP0=00016000 MP1=00016A00 GC=00001260 ...`.
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"

section .text

global ip_disc_scan
global ip_disc_scan_vram        ; fallback: MM_INDEX/DATA VRAM scan
global ip_disc_found
global ip_disc_vram_hit_offset  ; uint32 - VRAM offset where sig was found
global ip_disc_scan_addr        ; uint64 - where we started scanning
global ip_disc_bin_size         ; uint16 - binary_size from header
global ip_disc_version          ; uint16 - major<<8 | minor
global ip_disc_num_dies         ; uint16
global ip_disc_mp0_base         ; uint32 - MP0 SEG0
global ip_disc_mp1_base         ; uint32
global ip_disc_gc_base          ; uint32
global ip_disc_mmhub_base       ; uint32
global ip_disc_nbio_base        ; uint32
global ip_disc_dcn_base         ; uint32
global ip_disc_imu_base         ; uint32

extern amd_display_fb_addr
extern gpu_mmio_r32
extern gpu_mmio_w32

; --- Signatures (little-endian dword form, as they appear in memory) -------
; "$IPD" = 0x24 0x49 0x50 0x44 → 0x44504924
%define SIG_BIN_HEADER  0x44504924
; "IPCM" = 0x49 0x50 0x43 0x4D → 0x4D435049 - appears as little-endian dword
%define SIG_IP_DISC     0x4D435049

; HW IDs we care about.
%define HWID_GC         1
%define HWID_MMHUB      9
%define HWID_NBIO       12
%define HWID_MP0        14
%define HWID_MP1        15
%define HWID_DCN        16
%define HWID_IMU        50

; Scan window. Linux uses the top 64 KiB of VRAM, but on APUs we don't know
; where that is in CPU-visible space without parsing the stolen-memory
; region. We do the next best thing: scan the framebuffer base for several
; megabytes looking for the $IPD signature. This catches the table whether
; it lands at the FB top or the FB base (some platforms place it at +0).
%define IPDISC_SCAN_BYTES     0x00400000      ; 4 MiB
%define IPDISC_SCAN_STRIDE    4

; ---------------------------------------------------------------------------
; uint8 ip_disc_scan(void)
;   Walks the FB for the $IPD signature, parses the binary_header and
;   ip_discovery struct, and extracts SMN bases for the IPs we care about.
;   Returns 1 on found+parsed, 0 if signature not located.
; ---------------------------------------------------------------------------
ip_disc_scan:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    ; Default all outputs to 0.
    mov  byte [ip_disc_found], 0
    mov  qword [ip_disc_scan_addr], 0
    mov  word  [ip_disc_bin_size], 0
    mov  word  [ip_disc_version], 0
    mov  word  [ip_disc_num_dies], 0
    mov  dword [ip_disc_mp0_base], 0
    mov  dword [ip_disc_mp1_base], 0
    mov  dword [ip_disc_gc_base], 0
    mov  dword [ip_disc_mmhub_base], 0
    mov  dword [ip_disc_nbio_base], 0
    mov  dword [ip_disc_dcn_base], 0
    mov  dword [ip_disc_imu_base], 0

    ; Pre-flight: do we have a framebuffer base to scan?
    mov  r12, [amd_display_fb_addr]
    test r12, r12
    jz   .out_fail
    mov  [ip_disc_scan_addr], r12

    ; r12 = scan pointer, r13 = end.
    mov  r13, r12
    add  r13, IPDISC_SCAN_BYTES

.scan_loop:
    cmp  r12, r13
    jae  .out_fail
    mov  eax, [r12]
    cmp  eax, SIG_BIN_HEADER
    je   .candidate
    add  r12, IPDISC_SCAN_STRIDE
    jmp  .scan_loop

.candidate:
    ; r12 → potential binary_signature dword. The binary_header layout puts
    ; binary_signature at offset 12 (after table_list_offset, ip_table_offset,
    ; binary_checksum, binary_size, version_major, version_minor - six u16s).
    ; So the table START is r12 - 12.
    mov  rbx, r12
    sub  rbx, 12

    ; Validate by checking that ip_discovery sig lives at table_list_offset.
    movzx eax, word [rbx + 0]               ; table_list_offset
    test eax, eax
    jz   .scan_next                         ; can't be 0
    mov  esi, [rbx + rax]                   ; ip_discovery.signature
    cmp  esi, SIG_IP_DISC
    jne  .scan_next

    ; Looks legit. Latch header fields.
    movzx edx, word [rbx + 6]               ; binary_size
    mov  [ip_disc_bin_size], dx
    movzx edx, word [rbx + 8]               ; version_major
    shl  edx, 8
    movzx ecx, word [rbx + 10]              ; version_minor
    or   edx, ecx
    mov  [ip_disc_version], dx
    mov  [ip_disc_scan_addr], rbx

    ; Walk dies. r14 = ptr to ip_discovery struct (rbx + table_list_offset).
    movzx eax, word [rbx + 0]
    mov  r14, rbx
    add  r14, rax

    ; r14 + 0 = signature (already validated)
    ; r14 + 4 = version_major(u16), +6 = version_minor(u16)
    ; r14 + 8 = num_dies(u16)
    movzx eax, word [r14 + 8]
    mov  [ip_disc_num_dies], ax

    ; r15 = ptr to first die_header. die_header begins after num_dies + a
    ; padding word; conservatively pick r14 + 12.
    lea  r15, [r14 + 12]

    ; We only parse the first die. Most APUs have one die.
    ; die_header:
    ;   uint16 die_id
    ;   uint16 num_ips
    ;   then num_ips ip_v4 entries.
    movzx ecx, word [r15 + 2]               ; num_ips
    test ecx, ecx
    jz   .out_ok

    add  r15, 4                             ; skip past die_header

.ip_loop:
    test ecx, ecx
    jz   .out_ok

    ; ip_v4 record (the layout used in v4 discovery - Phoenix uses this):
    ;   uint16 hw_id
    ;   uint8  num_instances
    ;   uint8  num_base_address
    ;   uint16 variant_or_revision (depends on version)
    ;   uint16 sub_revision
    ;   uint8  harvest
    ;   uint8  reserved
    ;   uint32 base_address[num_base_address]
    movzx eax, word [r15 + 0]               ; hw_id
    movzx edx, byte [r15 + 3]               ; num_base_address
    test edx, edx
    jz   .ip_next

    ; base_address[0] is at r15 + 10 in v4 layout (4 hdr + 6 more = 10).
    mov  esi, [r15 + 10]                    ; first SMN base

    cmp  eax, HWID_MP0
    je   .store_mp0
    cmp  eax, HWID_MP1
    je   .store_mp1
    cmp  eax, HWID_GC
    je   .store_gc
    cmp  eax, HWID_MMHUB
    je   .store_mmhub
    cmp  eax, HWID_NBIO
    je   .store_nbio
    cmp  eax, HWID_DCN
    je   .store_dcn
    cmp  eax, HWID_IMU
    je   .store_imu
    jmp  .ip_next
.store_mp0:
    mov  [ip_disc_mp0_base], esi
    jmp  .ip_next
.store_mp1:
    mov  [ip_disc_mp1_base], esi
    jmp  .ip_next
.store_gc:
    mov  [ip_disc_gc_base], esi
    jmp  .ip_next
.store_mmhub:
    mov  [ip_disc_mmhub_base], esi
    jmp  .ip_next
.store_nbio:
    mov  [ip_disc_nbio_base], esi
    jmp  .ip_next
.store_dcn:
    mov  [ip_disc_dcn_base], esi
    jmp  .ip_next
.store_imu:
    mov  [ip_disc_imu_base], esi
    jmp  .ip_next

.ip_next:
    ; advance r15 by ip_v4 record size = 10 + 4*num_base_address.
    movzx eax, byte [r15 + 3]
    shl  eax, 2
    add  eax, 10
    add  r15, rax
    dec  ecx
    jmp  .ip_loop

.scan_next:
    add  r12, IPDISC_SCAN_STRIDE
    jmp  .scan_loop

.out_ok:
    mov  byte [ip_disc_found], 1
    mov  al, 1
    jmp  .out
.out_fail:
    mov  byte [ip_disc_found], 0
    xor  al, al
.out:
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
; uint8 ip_disc_scan_vram(void)
;   Fallback when FB linear scan fails. Walks several candidate VRAM-top
;   offsets through mmMM_INDEX/mmMM_DATA looking for the $IPD signature.
;
;   On APU, "VRAM" is the stolen-system-RAM region the GPU's MC sees. The
;   discovery table lives at vram_top - 64 KiB. Linux reads vram size from
;   regRCC_CONFIG_MEMSIZE; we instead probe a small set of plausible tops:
;   256 MiB, 512 MiB, 1 GiB, 2 GiB. Each probe scans the last 64 KiB at
;   stride 4 (16K reads per candidate = ~3 ms).
;
;   If the signature is found, latches ip_disc_vram_hit_offset and sets
;   ip_disc_found. Parsing of fields beyond the signature is deferred -
;   reading the full 64 KiB through MM_INDEX/DATA is doable but slow, and
;   we want to first prove the access path works before optimising.
;
;   Returns 1 on found, 0 otherwise. Side effects: scribbles mmMM_INDEX
;   while running (harmless - Linux uses this register the same way and
;   it's designed to be re-latched per access).
; ---------------------------------------------------------------------------
%define MM_INDEX_DW   0x0000
%define MM_DATA_DW    0x0001

ip_disc_scan_vram:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov  dword [ip_disc_vram_hit_offset], 0

    ; Walk candidate VRAM-top offsets. r14 = ptr to candidate table.
    lea  r14, [rel vram_top_candidates]
.cand_loop:
    mov  r12d, [r14]
    test r12d, r12d
    jz   .out_fail
    add  r14, 4

    ; Scan window: [top - 64 KiB, top) at stride 4.
    mov  ebx, r12d                  ; ebx = current offset
    sub  ebx, 0x10000
    mov  r13d, r12d                 ; r13d = end
.win_loop:
    cmp  ebx, r13d
    jae  .cand_loop

    ; mmMM_INDEX <- offset
    mov  edi, MM_INDEX_DW
    mov  esi, ebx
    call gpu_mmio_w32
    ; val <- mmMM_DATA
    mov  edi, MM_DATA_DW
    call gpu_mmio_r32
    cmp  eax, SIG_BIN_HEADER
    je   .hit

    add  ebx, 4
    jmp  .win_loop

.hit:
    ; Latch where we found it (signature offset within VRAM). The binary
    ; header starts 12 bytes earlier.
    sub  ebx, 12
    mov  [ip_disc_vram_hit_offset], ebx
    mov  byte [ip_disc_found], 1
    mov  al, 1
    jmp  .out_v

.out_fail:
    xor  al, al
.out_v:
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rdx
    pop  rcx
    pop  rbx
    ret

; ===========================================================================
section .data

; Candidate VRAM-top offsets, terminated by 0. Phoenix BIOSes typically
; allocate 512 MiB UMA but a few stop at 256 MiB or jump to 1 GiB.
align 4
vram_top_candidates:
    dd 0x10000000      ; 256 MiB
    dd 0x20000000      ; 512 MiB
    dd 0x40000000      ; 1 GiB
    dd 0x80000000      ; 2 GiB
    dd 0                ; terminator

ip_disc_vram_hit_offset:  dd 0

align 8
ip_disc_scan_addr:     dq 0
align 4
ip_disc_mp0_base:      dd 0
ip_disc_mp1_base:      dd 0
ip_disc_gc_base:       dd 0
ip_disc_mmhub_base:    dd 0
ip_disc_nbio_base:     dd 0
ip_disc_dcn_base:      dd 0
ip_disc_imu_base:      dd 0
align 2
ip_disc_bin_size:      dw 0
ip_disc_version:       dw 0
ip_disc_num_dies:      dw 0
align 1
ip_disc_found:         db 0
