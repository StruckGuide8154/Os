; ============================================================================
; amdgpu_gfx.inc - shared layout, memory map, and extern table for GFX11
; ----------------------------------------------------------------------------
; This is the load-bearing seam between the gpu/* driver modules. Each module
; (amd_smu, amd_gmc, amd_cp_ring, amd_gfx) includes this header so it sees the
; same physical-memory map and the same set of cross-module externs.
;
; Memory map for the GPU work region
; ----------------------------------
; All GPU-visible buffers (page tables, ring buffer, EOP fence, future shader
; uploads) live in a contiguous physical block above the parked DMCUB region.
; The kernel identity-maps the low 512GB with 1GB pages on UEFI, so any
; physical address in this range is also its kernel virtual address.
;
;   0x10000000  GMC root page table     (4 KiB)
;   0x10001000  GMC L2 (id-mapped)      (4 KiB)
;   0x10002000  GMC L1 (id-mapped)      (4 KiB)
;   0x10010000  CP ring buffer          (64 KiB)
;   0x10020000  CP rptr writeback       (4 KiB)
;   0x10030000  EOP fence buffer        (4 KiB)
;   0x10040000  PSP GPCOM ring          (4 KiB)
;   0x10041000  PSP GPCOM cmd/resp      (4 KiB)
;   0x10042000  PSP fence               (4 KiB)
;   0x10100000  PSP TMR buffer          (512 KiB; Wave 3 K)
;   0x10180000  PSP firmware staging    (512 KiB; Wave 3 K)
;   0x10100000  Shader upload region    (1 MiB; future, overlaps dormant PSP)
;
; The region is reserved purely by convention; the rest of the kernel does
; not allocate above 0x07100000 today. If that changes, add an explicit
; reservation in src/include/boot_memory.inc.
; ============================================================================

%ifndef AMDGPU_GFX_INC
%define AMDGPU_GFX_INC

; --- Memory map -----------------------------------------------------------
GPU_WORK_BASE              equ 0x10000000

GPU_PT_ROOT                equ 0x10000000
GPU_PT_L2                  equ 0x10001000
GPU_PT_L1                  equ 0x10002000
GPU_PT_SIZE                equ 0x00001000

GPU_CP_RING_BASE           equ 0x10010000
GPU_CP_RING_SIZE           equ 0x00010000          ; 64 KiB, 8K dwords
GPU_CP_RING_LOG2_DWORDS    equ 13                  ; log2(GPU_CP_RING_SIZE/4)
GPU_CP_RPTR_ADDR           equ 0x10020000
GPU_CP_EOP_ADDR            equ 0x10030000

GPU_SHADER_UPLOAD_BASE     equ 0x10100000
GPU_SHADER_UPLOAD_SIZE     equ 0x00100000

GPU_PSP_RING_BASE          equ 0x10040000
GPU_PSP_RING_SIZE          equ 0x00001000          ; 64 frames * 64 bytes
GPU_PSP_CMD_BASE           equ 0x10041000
GPU_PSP_CMD_SIZE           equ 0x00000400          ; psp_gfx_cmd_resp
GPU_PSP_FENCE_ADDR         equ 0x10042000
GPU_PSP_TMR_BASE           equ 0x10100000
GPU_PSP_TMR_SIZE           equ 0x00080000          ; 512 KiB, page-aligned
GPU_PSP_FW_STAGING_BASE    equ 0x10180000
GPU_PSP_FW_STAGING_SIZE    equ 0x00080000          ; 512 KiB

; --- Page-table entry format (GFX10/11 GPUVM 1-level identity range) -----
;
; The GPUVM page table is a tree of 8-byte entries. For a single
; identity-mapped 2 MiB region we use one root entry → one L1 page that
; covers 1 GiB via 2 MiB leaf entries (PTE_BLOCK).
;
; PTE bit layout (subset we need):
;   bit  0   VALID
;   bit  1   SYSTEM       (1 = system RAM via host MC; 0 = VRAM)
;   bit  2   COHERENT
;   bit  4   EXECUTE
;   bit  5   READ
;   bit  6   WRITE
;   bit  7   FRAGMENT (size hint; 0 = single page)
;   bits 47:12 PFN (4 KiB-aligned physical address, shifted >> 12)
;   bit 54   PTE_BLOCK (large-page leaf bit at non-leaf levels)
GPU_PTE_VALID              equ (1 <<  0)
GPU_PTE_SYSTEM             equ (1 <<  1)
GPU_PTE_COHERENT           equ (1 <<  2)
GPU_PTE_EXECUTE            equ (1 <<  4)
GPU_PTE_READ               equ (1 <<  5)
GPU_PTE_WRITE              equ (1 <<  6)
GPU_PTE_BLOCK              equ (1 << 54)
GPU_PTE_RWX                equ GPU_PTE_VALID | GPU_PTE_SYSTEM | GPU_PTE_COHERENT \
                            | GPU_PTE_READ | GPU_PTE_WRITE | GPU_PTE_EXECUTE

; --- Doorbell aperture ----------------------------------------------------
;
; The doorbell BAR (BAR2 on most AMD GPUs) is a small MMIO window the CP
; samples for ring-tail writes. We capture its CPU-side base once at probe
; time and stash it in gpu_doorbell_base. Doorbell indices are dwords into
; this window; ring 0 (CP_GFX) lives at index 0.
GPU_DOORBELL_INDEX_CP_GFX  equ 0x0000

; --- Cross-module externs -------------------------------------------------
;
; Every gpu/* module pulls these in. Definitions live in amd_gpu_mmio.asm
; (state) and amd_gfx.asm (orchestrator). All getters are safe to call
; before bring-up; they return 0 / false on uninitialised state.

extern gpu_mmio_r32                 ; (uint32 abs_dword_offset) -> eax
extern gpu_mmio_w32                 ; (uint32 abs_dword_offset, uint32 val)
extern gpu_mmio_wait_eq             ; (offset, mask, value, timeout_ticks) -> al
extern gpu_bar0_base                ; uint64 - physical, post BAR0 mask
extern gpu_doorbell_base            ; uint64 - kernel VA of doorbell window
extern gpu_bringup_state            ; uint8  - see GPU_STATE_* below
extern amd_display_bar0             ; reused: same BAR0 as DCN probe

; --- Bring-up state machine ----------------------------------------------
GPU_STATE_OFF              equ 0
GPU_STATE_MMIO_READY       equ 1     ; gpu_mmio_* initialised
GPU_STATE_GFX_POWERED      equ 2     ; SMU PowerUpGfx ack received  (Task H)
GPU_STATE_GMC_READY        equ 3     ; Context 0 page tables loaded (Task I)
GPU_STATE_RING_ALLOCATED   equ 4     ; CP ring + doorbell programmed (Task J)
GPU_STATE_PSP_READY        equ 5     ; PSP GPCOM ring + TMR ready (Wave 3)
GPU_STATE_RLC_LOADED       equ 6     ; RLC signed blob accepted by PSP (Task K)
GPU_STATE_CP_LOADED        equ 7     ; PFP/ME/MEC accepted by PSP (Task L)
GPU_STATE_CP_RUNNING       equ 8     ; CP halts released, NOP retired (Task L verify)
GPU_STATE_FAILED           equ 0xFF

%endif ; AMDGPU_GFX_INC
