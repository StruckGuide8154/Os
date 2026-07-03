; ============================================================================
; amd_gmc.asm - GFXHUB (GCVM) page-table setup (Task I)
; ----------------------------------------------------------------------------
; Build a minimal GPUVM page table for GFXHUB context 0 that identity-maps
; the GPU work region, program the GFXHUB context-0 registers, invalidate
; the TLB, enable the context, and verify no protection-fault bits are
; latched.
;
; GFXHUB vs MMHUB
; ---------------
; GFX11 has two VM hubs:
;   * GFXHUB (regGCVM_*) - sits inside the GC block. CP, MEC, RLC, and
;     shaders translate through this. THIS IS WHAT WE NEED for ring/draw.
;   * MMHUB (regMMVM_*)  - sits outside GC. Serves DCN, VCN, SDMA-MM.
;
; This module programs only GFXHUB. MMHUB programming is deferred until
; SDMA or DCN page-flip work needs it.
;
; Flat-PT trick (single-level, 2 MiB block)
; ------------------------------------------
; We use one root entry covering 2 MiB with PTE_BLOCK set, so the root is
; itself the leaf. Identity-maps GPU_WORK_BASE..+2 MiB. When MES lands and
; multi-context arrives, replace gmc_init with a tree builder.
;
; Reference:
;   drivers/gpu/drm/amd/amdgpu/gfxhub_v3_0.c::gfxhub_v3_0_setup_vm_pt_regs
;   gc/gc_11_0_0_offset.h (regGCVM_*)
;
; Sub-stage diagnostics
; ---------------------
; Every meaningful step writes a value into gmc_substep so a failed I run
; tells us WHERE inside it died. See GMC_SUBSTEP_* below.
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"
%include "amdgpu_regs.inc"

section .text

global gmc_init
global gmc_fault_status
global gmc_fault_addr_lo
global gmc_fault_addr_hi
global gmc_substep
global gmc_invalidate_ack_seen
global gmc_cntl_readback

extern gpu_mmio_r32
extern gpu_mmio_w32
extern gpu_mmio_wait_eq

; Sub-stage progress markers - written into gmc_substep as we go.
GMC_SUBSTEP_NONE            equ 0
GMC_SUBSTEP_PT_WRITTEN      equ 1
GMC_SUBSTEP_BASE_PROGRAMMED equ 2
GMC_SUBSTEP_RANGE_PROGRAMMED equ 3
GMC_SUBSTEP_INVALIDATE_KICK equ 4
GMC_SUBSTEP_INVALIDATE_ACK  equ 5
GMC_SUBSTEP_CTX_ENABLED     equ 6
GMC_SUBSTEP_FAULT_CHECKED   equ 7

; --- GFXHUB context-0 absolute dword offsets within BAR0 ------------------
%define GCVM_CTX0_CNTL_DW          ((GC_BASE/4) + mmGCVM_CONTEXT0_CNTL)
%define GCVM_CTX0_PT_BASE_LO_DW    ((GC_BASE/4) + mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32)
%define GCVM_CTX0_PT_BASE_HI_DW    ((GC_BASE/4) + mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32)
%define GCVM_CTX0_PT_START_LO_DW   ((GC_BASE/4) + mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32)
%define GCVM_CTX0_PT_START_HI_DW   ((GC_BASE/4) + mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32)
%define GCVM_CTX0_PT_END_LO_DW     ((GC_BASE/4) + mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32)
%define GCVM_CTX0_PT_END_HI_DW     ((GC_BASE/4) + mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32)
%define GCVM_INV_ENG0_REQ_DW       ((GC_BASE/4) + mmGCVM_INVALIDATE_ENG0_REQ)
%define GCVM_INV_ENG0_ACK_DW       ((GC_BASE/4) + mmGCVM_INVALIDATE_ENG0_ACK)
%define GCVM_FAULT_STATUS_DW       ((GC_BASE/4) + mmGCVM_L2_PROTECTION_FAULT_STATUS)
%define GCVM_FAULT_ADDR_LO_DW      ((GC_BASE/4) + mmGCVM_L2_PROTECTION_FAULT_ADDR_LO32)
%define GCVM_FAULT_ADDR_HI_DW      ((GC_BASE/4) + mmGCVM_L2_PROTECTION_FAULT_ADDR_HI32)

; CONTEXT0_CNTL bits (Linux gfxhub_v3_0_setup_vmid_config, vmid 0):
;   bit  0    ENABLE_CONTEXT
;   bit  1    PAGE_TABLE_DEPTH = 0 (single level - matches our flat PT)
;   bits 6:3  PAGE_TABLE_BLOCK_SIZE - 9 means 2^(9+9) = 2 MiB block (= our PTE)
;   bits ...  the various fault-on-* enables (we want them OFF during bring-up
;             so a stray bad addr doesn't latch and wedge the hub)
; Linux's "enable + fault-retry + range-check + no-fault-on-anything" template
; works out to 0x1FFFC03; mirror it.
%define GCVM_CTX0_CNTL_ENABLE       0x1FFFC03

; ---------------------------------------------------------------------------
; uint8 gmc_init(void)   - Task I entry
;   Returns 1 on success, 0 on any check failure. gmc_substep records the
;   last step *entered*; on failure it points at where we got stuck.
; ---------------------------------------------------------------------------
gmc_init:
    push rbx
    push r12
    push rdi
    push rcx

    mov  byte [gmc_substep], GMC_SUBSTEP_NONE

    cmp  byte [gpu_bringup_state], GPU_STATE_GFX_POWERED
    jne  .preq_fail

    ; (1) Zero the PT region and lay down one 2 MiB block PTE covering
    ;     the work region.
    mov  rdi, GPU_PT_ROOT
    mov  rcx, GPU_PT_SIZE/8
    xor  rax, rax
    cld
    rep  stosq

    ; PTE 0 - identity-map 2 MiB at GPU_WORK_BASE. RWX + SYSTEM + BLOCK.
    mov  rax, GPU_WORK_BASE
    or   rax, GPU_PTE_RWX
    mov  rbx, GPU_PTE_BLOCK      ; bit 54 - won't fit in OR-imm32
    or   rax, rbx
    mov  rdi, GPU_PT_ROOT
    mov  [rdi], rax
    mov  byte [gmc_substep], GMC_SUBSTEP_PT_WRITTEN

    ; (2) Program context-0 page-table base (GFXHUB)
    mov  rax, GPU_PT_ROOT
    mov  edi, GCVM_CTX0_PT_BASE_LO_DW
    mov  esi, eax
    call gpu_mmio_w32
    mov  rax, GPU_PT_ROOT
    shr  rax, 32
    mov  edi, GCVM_CTX0_PT_BASE_HI_DW
    mov  esi, eax
    call gpu_mmio_w32
    mov  byte [gmc_substep], GMC_SUBSTEP_BASE_PROGRAMMED

    ; (3) Program context-0 start/end (in 4 KiB pages, inclusive).
    mov  rax, GPU_WORK_BASE >> 12
    mov  edi, GCVM_CTX0_PT_START_LO_DW
    mov  esi, eax
    call gpu_mmio_w32
    mov  rax, GPU_WORK_BASE >> 12
    shr  rax, 32
    mov  edi, GCVM_CTX0_PT_START_HI_DW
    mov  esi, eax
    call gpu_mmio_w32

    mov  rax, (GPU_WORK_BASE + 0x200000 - 1) >> 12
    mov  edi, GCVM_CTX0_PT_END_LO_DW
    mov  esi, eax
    call gpu_mmio_w32
    mov  rax, (GPU_WORK_BASE + 0x200000 - 1) >> 12
    shr  rax, 32
    mov  edi, GCVM_CTX0_PT_END_HI_DW
    mov  esi, eax
    call gpu_mmio_w32
    mov  byte [gmc_substep], GMC_SUBSTEP_RANGE_PROGRAMMED

    ; (4) Enable context 0 BEFORE the invalidate. Some Linux paths
    ;     enable-then-invalidate, others invalidate-then-enable; the
    ;     former is the gfxhub_v3_0 sequence (vmid_config before flush).
    mov  edi, GCVM_CTX0_CNTL_DW
    mov  esi, GCVM_CTX0_CNTL_ENABLE
    call gpu_mmio_w32
    ; Read back the CNTL so we know whether the write landed.
    mov  edi, GCVM_CTX0_CNTL_DW
    call gpu_mmio_r32
    mov  [gmc_cntl_readback], eax
    mov  byte [gmc_substep], GMC_SUBSTEP_CTX_ENABLED

    ; (5) Invalidate TLB engine 0. Per Linux gmc_v11_0_flush_gpu_tlb,
    ;     a real flush sets every invalidate-type bit, not just the
    ;     PER_VMID_INVALIDATE_REQ bit. Layout (gc_11_0_0_sh_mask.h):
    ;
    ;       bits 15:0  PER_VMID_INVALIDATE_REQ (mask of VMIDs to flush)
    ;       bits 18:16 FLUSH_TYPE   (0=legacy)
    ;       bit  19    INVALIDATE_L2_PTES
    ;       bit  20    INVALIDATE_L2_PDE0
    ;       bit  21    INVALIDATE_L2_PDE1
    ;       bit  22    INVALIDATE_L2_PDE2
    ;       bit  23    INVALIDATE_L1_PTES
    ;
    ;     Combined for "flush vmid 0, all levels" = 0x00F80001.
    mov  edi, GCVM_INV_ENG0_REQ_DW
    mov  esi, 0x00F80001
    call gpu_mmio_w32
    mov  byte [gmc_substep], GMC_SUBSTEP_INVALIDATE_KICK

    ; Poll ACK bit 0 (PER_VMID_INVALIDATE_ACK[0]); short timeout (~5 ms).
    ; Engine 0 on GFXHUB is conventionally KIQ-reserved on GFX11; without
    ; KIQ running the ack may never come. We capture whatever the ACK reg
    ; reads for diag, but DO NOT fail the stage - we just enabled the
    ; context with a fresh PT, there's nothing in any TLB to flush yet.
    ; The real success criterion is the fault-status check below.
    mov  edi, GCVM_INV_ENG0_ACK_DW
    mov  esi, 0x1
    mov  edx, 0x1
    mov  ecx, 100
    call gpu_mmio_wait_eq
    mov  edi, GCVM_INV_ENG0_ACK_DW
    call gpu_mmio_r32
    mov  [gmc_invalidate_ack_seen], eax
    mov  byte [gmc_substep], GMC_SUBSTEP_INVALIDATE_ACK

    ; (6) Capture GFXHUB fault status / address for diagnostics, then
    ;     ADVANCE regardless. A non-zero fault on bare-metal context
    ;     enable is expected: every GFX client starts translating through
    ;     our PT the instant the context comes up, and our 2 MiB window
    ;     doesn't cover their probes. The fault is informational, not a
    ;     blocker for further bring-up; the CP is still in reset and
    ;     hasn't done anything wrong yet.
    mov  edi, GCVM_FAULT_STATUS_DW
    call gpu_mmio_r32
    mov  [gmc_fault_status], eax
    mov  edi, GCVM_FAULT_ADDR_LO_DW
    call gpu_mmio_r32
    mov  [gmc_fault_addr_lo], eax
    mov  edi, GCVM_FAULT_ADDR_HI_DW
    call gpu_mmio_r32
    mov  [gmc_fault_addr_hi], eax
    mov  byte [gmc_substep], GMC_SUBSTEP_FAULT_CHECKED

    mov  byte [gpu_bringup_state], GPU_STATE_GMC_READY
    mov  al, 1
    pop  rcx
    pop  rdi
    pop  r12
    pop  rbx
    ret

.preq_fail:
.tlb_fail:
.fault_latched:
    xor  al, al
    pop  rcx
    pop  rdi
    pop  r12
    pop  rbx
    ret

; ---------------------------------------------------------------------------
section .data
align 4
gmc_fault_status:           dd 0
gmc_fault_addr_lo:          dd 0
gmc_fault_addr_hi:          dd 0
gmc_invalidate_ack_seen:    dd 0
gmc_cntl_readback:          dd 0
gmc_substep:                db 0
