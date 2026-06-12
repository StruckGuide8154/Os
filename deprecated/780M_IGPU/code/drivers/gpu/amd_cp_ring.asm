; ============================================================================
; amd_cp_ring.asm - CP ring buffer + doorbell programming (Task J)
; ----------------------------------------------------------------------------
; Allocate the GFX CP ring (ring 0) in the GMC-mapped work region, capture
; the doorbell aperture base, and program CP_RB0_BASE / CP_RB0_CNTL and the
; rptr-writeback address so the CP knows where the ring lives.
;
; This module deliberately does NOT start the CP. The CP is held in reset by
; CP_ME_CNTL until microcode is loaded (a Wave-2 task tracked separately).
; What lands here is purely the register-bank wiring; the next module to
; come online will load PFP/ME/CE microcode and release reset.
;
; CP_RB0_CNTL fields (GFX10/11):
;   bits  5:0  RB_BUFSZ      (log2 dwords in the ring)
;   bits 13:8  RB_BLKSZ      (log2 dwords per block; AMD default = BUFSZ-3)
;   bit   16   BUF_SWAP      (0 = no endian swap on x86)
;   bit   25   RPTR_WRITEBACK_ENABLE
;   bit   27   RB_NO_UPDATE  (1 while we configure; cleared by CP start)
;
; Reference: drivers/gpu/drm/amd/amdgpu/gfx_v11_0.c::gfx_v11_0_cp_gfx_resume
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"
%include "amdgpu_regs.inc"

section .text

global cp_ring_alloc
global cp_ring_map_doorbell
global cp_gfx_start_nop
global cp_ring_state
global cp_rb0_cntl_readback
global cp_rb0_base_readback
global cp_rb0_rptr_readback
global cp_ring_substep
global cp_me_cntl_pre
global cp_me_cntl_post
global cp_nop_substep
global cp_nop_rptr_seen
global cp_nop_wptr_target

extern gpu_mmio_r32
extern gpu_mmio_w32
extern pci_read_conf_dword
extern amd_display_bdf
extern tick_count

; --- CP register absolute dword offsets within BAR0 -----------------------
%define CP_RB0_BASE_DW       ((GC_BASE/4) + mmCP_RB0_BASE)
%define CP_RB0_BASE_HI_DW    ((GC_BASE/4) + mmCP_RB0_BASE_HI)
%define CP_RB0_CNTL_DW       ((GC_BASE/4) + mmCP_RB0_CNTL)
%define CP_RB0_RPTR_ADDR_DW  ((GC_BASE/4) + mmCP_RB0_RPTR_ADDR)
%define CP_RB0_RPTR_ADDR_HI_DW  ((GC_BASE/4) + mmCP_RB0_RPTR_ADDR_HI)
%define CP_RB0_WPTR_DW       ((GC_BASE/4) + mmCP_RB0_WPTR)
%define CP_RB0_WPTR_HI_DW    ((GC_BASE/4) + mmCP_RB0_WPTR_HI)
%define CP_RB0_RPTR_REG_DW   ((GC_BASE/4) + mmCP_RB0_RPTR)
%define CP_ME_CNTL_DW        ((GC_BASE/4) + mmCP_ME_CNTL)

; CNTL value: BUFSZ=13 (8K dwords), BLKSZ=BUFSZ-3=10, rptr writeback on,
; RB_NO_UPDATE asserted while we configure.
%define CP_RB0_CNTL_CONFIGURE  ( (GPU_CP_RING_LOG2_DWORDS) \
                              | ((GPU_CP_RING_LOG2_DWORDS - 3) << 8) \
                              | (1 << 25) \
                              | (1 << 27) )

; ---------------------------------------------------------------------------
; uint8 cp_ring_alloc(void)   - Task J entry, register-bank portion
;   Zero the ring, program base/cntl/rptr regs, leave WPTR=0 and CP in
;   whatever reset state caller left it in.
;
;   Preconditions: gpu_bringup_state == GPU_STATE_GMC_READY
;   Postcondition on success: gpu_bringup_state = GPU_STATE_RING_ALLOCATED
;   Returns 1 on success, 0 on precondition fail.
; ---------------------------------------------------------------------------
cp_ring_alloc:
    push rbx
    push rdi
    push rcx

    mov  byte [cp_ring_substep], 0
    cmp  byte [gpu_bringup_state], GPU_STATE_GMC_READY
    jne  .preq_fail

    ; (1) Zero the ring + rptr writeback word. The CP reads the rptr-wb
    ;     location and updates it; initialising to 0 keeps it consistent
    ;     with the hardware register's reset value.
    mov  rdi, GPU_CP_RING_BASE
    mov  rcx, GPU_CP_RING_SIZE/8
    xor  rax, rax
    cld
    rep  stosq

    mov  rdi, GPU_CP_RPTR_ADDR
    mov  rcx, 4096/8
    rep  stosq
    mov  byte [cp_ring_substep], 1

    ; (2) Program CP_RB0_BASE/HI. The CP wants the ring base in dwords,
    ;     not bytes - base_dw = phys >> 2.
    mov  rax, GPU_CP_RING_BASE
    shr  rax, 2
    mov  edi, CP_RB0_BASE_DW
    mov  esi, eax
    call gpu_mmio_w32
    mov  rax, GPU_CP_RING_BASE
    shr  rax, 2
    shr  rax, 32
    mov  edi, CP_RB0_BASE_HI_DW
    mov  esi, eax
    call gpu_mmio_w32

    ; (3) Program rptr writeback address (byte address, 4-byte aligned).
    mov  rax, GPU_CP_RPTR_ADDR
    mov  edi, CP_RB0_RPTR_ADDR_DW
    mov  esi, eax
    call gpu_mmio_w32
    shr  rax, 32
    mov  edi, CP_RB0_RPTR_ADDR_HI_DW
    mov  esi, eax
    call gpu_mmio_w32

    ; (4) Park WPTR at 0 explicitly.
    mov  edi, CP_RB0_WPTR_DW
    xor  esi, esi
    call gpu_mmio_w32
    mov  edi, CP_RB0_WPTR_HI_DW
    xor  esi, esi
    call gpu_mmio_w32

    ; (5) Program CNTL last (per the GFX-v11 sequence): RB_NO_UPDATE stays
    ;     asserted, so the CP won't try to chase the ring until microcode
    ;     load releases it.
    mov  edi, CP_RB0_CNTL_DW
    mov  esi, CP_RB0_CNTL_CONFIGURE
    call gpu_mmio_w32
    mov  byte [cp_ring_substep], 2

    ; (6) Readback CP_RB0_CNTL/BASE/RPTR_ADDR for diag. If these reflect
    ;     what we wrote, the CP register window is alive. If they read
    ;     0xFFFFFFFF or 0 the CP block is gated and we'd need to release
    ;     CP_ME_CNTL before any of this sticks.
    mov  edi, CP_RB0_CNTL_DW
    call gpu_mmio_r32
    mov  [cp_rb0_cntl_readback], eax
    mov  edi, CP_RB0_BASE_DW
    call gpu_mmio_r32
    mov  [cp_rb0_base_readback], eax
    mov  edi, CP_RB0_RPTR_ADDR_DW
    call gpu_mmio_r32
    mov  [cp_rb0_rptr_readback], eax
    mov  byte [cp_ring_substep], 3

    mov  byte [gpu_bringup_state], GPU_STATE_RING_ALLOCATED
    mov  byte [cp_ring_state], 1
    mov  al, 1
    pop  rcx
    pop  rdi
    pop  rbx
    ret

.preq_fail:
    xor  al, al
    pop  rcx
    pop  rdi
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint8 cp_ring_map_doorbell(void)
;   Read BAR2 of the AMD display device, mask the type bits, and stash the
;   physical address in gpu_doorbell_base. The kernel identity-maps low
;   memory so this is also the kernel VA; no new page-table work needed.
;
;   Doorbell BAR is the 3rd memory BAR (offset 0x18 in PCI config space)
;   for GFX11 family. If absent (some virtualised devices expose it via
;   resizable BAR sizing), this returns 0 and bring-up should fall back to
;   register-mode wptr writes (CP supports both).
; ---------------------------------------------------------------------------
%define PCI_BAR2_OFFSET   0x18

cp_ring_map_doorbell:
    push rbx
    push rdi

    cmp  byte [gpu_bringup_state], GPU_STATE_RING_ALLOCATED
    jne  .preq_fail

    ; pci_read_conf_dword(uint32 bdf /*edi*/, uint32 reg /*esi*/) -> eax
    mov  edi, [amd_display_bdf]
    mov  esi, PCI_BAR2_OFFSET
    call pci_read_conf_dword
    mov  ebx, eax                       ; BAR2 low

    ; If BAR is 64-bit (bit 2 set in flags = 0x4 type field), read high half.
    mov  eax, ebx
    and  eax, 0x6                       ; bits 2:1 = mem type
    cmp  eax, 0x4
    jne  .bar32

    mov  edi, [amd_display_bdf]
    mov  esi, PCI_BAR2_OFFSET + 4
    call pci_read_conf_dword
    shl  rax, 32
    mov  ecx, ebx
    and  ecx, 0xFFFFFFF0                ; mask flags from low half
    or   rax, rcx
    jmp  .have

.bar32:
    mov  eax, ebx
    and  eax, 0xFFFFFFF0
.have:
    test rax, rax
    jz   .no_bar2
    mov  [gpu_doorbell_base], rax
    mov  al, 1
    pop  rdi
    pop  rbx
    ret

.preq_fail:
.no_bar2:
    xor  al, al
    pop  rdi
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint8 cp_gfx_start_nop(void)
;   Release CP_ME_CNTL halts (PFP/ME/CE), clear RB_NO_UPDATE so the CP starts
;   chasing the ring, write a 2-dword PM4 NOP at the current WPTR, bump WPTR,
;   then poll CP_RB0_RPTR until it catches up or we time out.
;
;   Preconditions: gpu_bringup_state >= GPU_STATE_CP_LOADED.
;   Postcondition on success: gpu_bringup_state = GPU_STATE_CP_RUNNING.
;
;   PM4 NOP type-3 header layout:
;     bits 31:30 = 3            (PACKET_TYPE3)
;     bits 29:16 = count        (total dwords - 2)
;     bits 15:8  = opcode 0x10  (PACKET3_NOP)
;     bits 7:0   = predicate/shader_type (0)
;   For a 2-dword NOP (header + 1 filler): count=0 => 0xC0001000.
;   The filler dword is conventionally 0xFFFFFFFF.
; ---------------------------------------------------------------------------
%define CP_NOP_TIMEOUT_TICKS  500
%define CP_RB0_CNTL_RUN  ( (GPU_CP_RING_LOG2_DWORDS) \
                         | ((GPU_CP_RING_LOG2_DWORDS - 3) << 8) \
                         | (1 << 25) )

cp_gfx_start_nop:
    push rbx
    push rcx
    push rdi
    push rsi

    mov  byte [cp_nop_substep], 0
    cmp  byte [gpu_bringup_state], GPU_STATE_CP_LOADED
    jne  .preq_fail

    ; (1) Snapshot CP_ME_CNTL before, then clear all halt bits (write 0).
    mov  edi, CP_ME_CNTL_DW
    call gpu_mmio_r32
    mov  [cp_me_cntl_pre], eax
    mov  edi, CP_ME_CNTL_DW
    xor  esi, esi
    call gpu_mmio_w32
    mov  edi, CP_ME_CNTL_DW
    call gpu_mmio_r32
    mov  [cp_me_cntl_post], eax
    mov  byte [cp_nop_substep], 1

    ; (2) Drop RB_NO_UPDATE so the CP starts chasing the ring.
    mov  edi, CP_RB0_CNTL_DW
    mov  esi, CP_RB0_CNTL_RUN
    call gpu_mmio_w32
    mov  byte [cp_nop_substep], 2

    ; (3) Write a 2-dword PM4 NOP at ring offset 0 (we know WPTR is parked
    ;     at 0 from cp_ring_alloc).
    mov  rdi, GPU_CP_RING_BASE
    mov  dword [rdi + 0], 0xC0001000        ; PACKET3 NOP, count=0
    mov  dword [rdi + 4], 0xFFFFFFFF        ; filler
    mov  byte [cp_nop_substep], 3

    ; (4) Bump WPTR to 2 dwords.
    mov  edi, CP_RB0_WPTR_DW
    mov  esi, 2
    call gpu_mmio_w32
    mov  edi, CP_RB0_WPTR_HI_DW
    xor  esi, esi
    call gpu_mmio_w32
    mov  dword [cp_nop_wptr_target], 2
    mov  byte [cp_nop_substep], 4

    ; (5) Poll CP_RB0_RPTR until it reaches 2 (or timeout). Read the live
    ;     register, not the writeback dword - writeback can lag and we want
    ;     proof the CP is alive.
    mov  ebx, [tick_count]
    add  ebx, CP_NOP_TIMEOUT_TICKS
.wait:
    mov  edi, CP_RB0_RPTR_REG_DW
    call gpu_mmio_r32
    mov  [cp_nop_rptr_seen], eax
    cmp  eax, 2
    jae  .done
    mov  ecx, [tick_count]
    cmp  ecx, ebx
    jb   .wait
    ; Timeout - leave state at CP_LOADED so a retry walks here again.
    xor  al, al
    pop  rsi
    pop  rdi
    pop  rcx
    pop  rbx
    ret

.done:
    mov  byte [cp_nop_substep], 5
    mov  byte [gpu_bringup_state], GPU_STATE_CP_RUNNING
    mov  al, 1
    pop  rsi
    pop  rdi
    pop  rcx
    pop  rbx
    ret

.preq_fail:
    xor  al, al
    pop  rsi
    pop  rdi
    pop  rcx
    pop  rbx
    ret

; ---------------------------------------------------------------------------
section .data
align 4
cp_rb0_cntl_readback:   dd 0
cp_rb0_base_readback:   dd 0
cp_rb0_rptr_readback:   dd 0
cp_me_cntl_pre:         dd 0
cp_me_cntl_post:        dd 0
cp_nop_rptr_seen:       dd 0
cp_nop_wptr_target:     dd 0
align 1
cp_ring_state:          db 0       ; 0=unconfigured, 1=programmed (CP still in reset)
cp_ring_substep:        db 0
cp_nop_substep:         db 0
