; ============================================================================
; amd_smn.asm - NBIO SMN (System Management Network) indirect access
; ----------------------------------------------------------------------------
; The SMU on AMD APUs (Phoenix, Strix, ...) is a SoC-level microcontroller
; that is NOT mapped into the GPU's BAR0 the way it is on discrete cards.
; To reach its mailbox registers we use the NBIO indirect-access pair:
;
;     PCIE_INDEX2   BAR0 byte offset 0x38  (dword 0x0E)
;     PCIE_DATA2    BAR0 byte offset 0x3C  (dword 0x0F)
;
; Sequence:
;     write32(BAR0+0x38, smn_addr)        ; latches the SMN target
;     read32 (BAR0+0x3C)         -> val   ; reads from that SMN address
;     write32(BAR0+0x3C, val)              ; writes to that SMN address
;
; Both INDEX2 and DATA2 live inside BAR0, so gpu_mmio_r32/w32 work.
; They are sticky across single accesses but not across context switches -
; we re-latch INDEX2 on every transaction. Bring-up is single-threaded so
; no locking is needed.
;
; References:
;   drivers/gpu/drm/amd/amdgpu/amdgpu_device.c (amdgpu_device_indirect_*)
;   drivers/gpu/drm/amd/amdgpu/nbio_v7_7.c     (PCIE_INDEX2/DATA2 offsets)
;
; The same proxy also reaches PSP, DF, and various NBIO/IOHC registers; we
; keep the helpers generic so future waves can reuse them.
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"

section .text

global smn_r32
global smn_w32
global smn_probe_last

extern gpu_mmio_r32
extern gpu_mmio_w32

; PCIE_INDEX2 / DATA2 - absolute dword offsets within BAR0.
; NBIO base for Strix (NBIO 7.7) is 0; the dword offsets are the canonical
; SOC15 values (regBIF_BX0_PCIE_INDEX2 = 0x0E, _DATA2 = 0x0F).
%define SMN_DW_INDEX2    0x0E
%define SMN_DW_DATA2     0x0F

; ---------------------------------------------------------------------------
; uint32 smn_r32(uint32 smn_addr /*edi*/)
;   Returns the 32-bit value at the given SMN address via NBIO proxy.
;   Stores the address read in smn_probe_last for diag.
; ---------------------------------------------------------------------------
smn_r32:
    push rbx
    mov  ebx, edi
    mov  [smn_probe_last], ebx

    ; INDEX2 ← smn_addr
    mov  edi, SMN_DW_INDEX2
    mov  esi, ebx
    call gpu_mmio_w32

    ; val ← DATA2
    mov  edi, SMN_DW_DATA2
    call gpu_mmio_r32
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; void smn_w32(uint32 smn_addr /*edi*/, uint32 val /*esi*/)
; ---------------------------------------------------------------------------
smn_w32:
    push rbx
    push r12
    mov  ebx, edi
    mov  r12d, esi
    mov  [smn_probe_last], ebx

    mov  edi, SMN_DW_INDEX2
    mov  esi, ebx
    call gpu_mmio_w32

    mov  edi, SMN_DW_DATA2
    mov  esi, r12d
    call gpu_mmio_w32
    pop  r12
    pop  rbx
    ret

; ---------------------------------------------------------------------------
section .data
align 4
smn_probe_last:   dd 0           ; last SMN address latched (for diag)
