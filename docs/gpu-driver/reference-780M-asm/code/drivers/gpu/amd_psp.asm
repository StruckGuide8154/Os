; ============================================================================
; amd_psp.asm - PSP SOS GPCOM ring primitive (Wave 3 scaffold)
; ----------------------------------------------------------------------------
; The LOAD_IP_FW command is a PSP SOS command submitted through the KM/GPCOM
; ring. It is not the bootloader mailbox protocol on C2PMSG_33/35/36.
;
; This module owns:
;   * probing SOS liveness/status via MP0 C2PMSG registers over the SMN proxy
;   * creating the KM/GPCOM ring via C2PMSG_69/70/71 + C2PMSG_64
;   * submitting a pre-built psp_gfx_cmd_resp through the ring
;   * setting up the TMR used by later LOAD_IP_FW commands
;
; References:
;   Linux psp_v14_0.c::psp_v14_0_is_sos_alive
;   Linux psp_v14_0.c::psp_v14_0_ring_create
;   Linux amdgpu_psp.c::psp_ring_cmd_submit / psp_prep_tmr_cmd_buf
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"
%include "amdgpu_regs.inc"
%include "amdgpu_psp.inc"

section .text

global psp_init
global psp_submit_cmd
global psp_zero_cmd
global psp_boot_status
global psp_solution_status
global psp_c2pmsg64_raw
global psp_c2pmsg67_raw
global psp_c2pmsg33_raw
global psp_c2pmsg35_raw
global psp_sos_version
global psp_last_cmd
global psp_last_resp
global psp_last_fence
global psp_substep
global psp_ring_state
global psp_tmr_status

extern smn_r32
extern smn_w32
extern tick_count

; PSP (MP0) access path - UNRESOLVED on Strix Point.
;
; Attempt 1: SMN proxy at 0x03800000 - every read returned 0x13 (stale SMU
;            bus data). Wrong segment.
; Attempt 2: Direct BAR0 MMIO at byte offset MP0_BASE (0x58000) - appeared
;            to wedge NBIO/SMN on the next boot, with SMU SMN reads returning
;            FFFFFFFF until full power cycle. Wrong offset.
;
; Linux psp_v14_0 uses regMPASP_SMN_C2PMSG_* for Strix-era MP0. The matching
; mp_14_0_2_offset.h entries have BASE_IDX 0, which is SMN segment 0x00016000
; in the NBIO proxy address space. Keep this indirect path; speculative direct
; BAR0 MP0 access can hang the bus.
%define MP0_BASE_SMN          0x00016000
%define MP0_C2PMSG_64_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_64 * 4)
%define MP0_C2PMSG_67_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_67 * 4)
%define MP0_C2PMSG_69_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_69 * 4)
%define MP0_C2PMSG_70_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_70 * 4)
%define MP0_C2PMSG_71_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_71 * 4)
%define MP0_C2PMSG_33_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_33 * 4)
%define MP0_C2PMSG_35_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_35 * 4)
%define MP0_C2PMSG_58_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_58 * 4)
%define MP0_C2PMSG_81_DW      (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_81 * 4)
%define MP0_C2PMSG_103_DW     (MP0_BASE_SMN + mmMP0_SMN_C2PMSG_103 * 4)

%define PSP_TIMEOUT_TICKS     1000
%define PSP_C2P64_READY_MASK  0x80000000
%define PSP_C2P64_READY_VALUE 0x80000000
%define PSP_C2P64_OK_MASK     0x8000FFFF
%define PSP_C2P64_OK_VALUE    0x80000000

; ---------------------------------------------------------------------------
; void psp_zero_cmd(void)
;   Clears the command buffer and writes the common psp_gfx_cmd_resp header.
; ---------------------------------------------------------------------------
psp_zero_cmd:
    push rdi
    push rcx
    mov  rdi, GPU_PSP_CMD_BASE
    mov  rcx, PSP_GFX_CMD_RESP_SIZE / 8
    xor  rax, rax
    cld
    rep  stosq
    mov  rdi, GPU_PSP_CMD_BASE
    mov  dword [rdi + PSP_CMD_BUF_SIZE], PSP_GFX_CMD_RESP_SIZE
    mov  dword [rdi + PSP_CMD_BUF_VERSION], PSP_GFX_CMD_BUF_VERSION
    pop  rcx
    pop  rdi
    ret

; ---------------------------------------------------------------------------
; uint8 psp_init(void)
;   Preconditions: gpu_bringup_state == GPU_STATE_RING_ALLOCATED.
;   Postcondition: GPU_STATE_PSP_READY after ring create + SETUP_TMR ack.
; ---------------------------------------------------------------------------
psp_init:
    push rbx
    push rcx
    push rdi
    push rsi

    mov  byte [psp_substep], 0
    cmp  byte [gpu_bringup_state], GPU_STATE_RING_ALLOCATED
    je   .need_init
    cmp  byte [gpu_bringup_state], GPU_STATE_PSP_READY
    jb   .fail
    mov  al, 1
    jmp  .out

.need_init:
    ; Snapshot PSP status up front. SOS alive is C2PMSG_81 != 0 in Linux,
    ; but keep the bootloader mailbox and SOS version too so hardware photos
    ; can distinguish "not ready" from "wrong MP0 SMN window".
    mov  edi, MP0_C2PMSG_33_DW
    call smn_r32
    mov  [psp_c2pmsg33_raw], eax

    mov  edi, MP0_C2PMSG_35_DW
    call smn_r32
    mov  [psp_c2pmsg35_raw], eax

    mov  edi, MP0_C2PMSG_58_DW
    call smn_r32
    mov  [psp_sos_version], eax

    mov  edi, MP0_C2PMSG_81_DW
    call smn_r32
    mov  [psp_solution_status], eax
    test eax, eax
    jz   .fail
    mov  byte [psp_substep], 1

    mov  edi, MP0_C2PMSG_103_DW
    call smn_r32
    mov  [psp_boot_status], eax

    ; Clear ring/fence/cmd storage.
    mov  rdi, GPU_PSP_RING_BASE
    mov  rcx, GPU_PSP_RING_SIZE / 8
    xor  rax, rax
    cld
    rep  stosq
    mov  rdi, GPU_PSP_FENCE_ADDR
    mov  rcx, 4096 / 8
    rep  stosq
    call psp_zero_cmd
    mov  byte [psp_substep], 2

    ; Wait for TrustOS ready. Linux psp_v14_0 waits only on bit 31 before
    ; issuing ring-create; lower status bits are checked after commands.
    call psp_wait_c2p64_ready
    test al, al
    jz   .fail
    mov  byte [psp_substep], 3

    ; Create KM/GPCOM ring.
    mov  edi, MP0_C2PMSG_69_DW
    mov  esi, GPU_PSP_RING_BASE
    call smn_w32
    mov  edi, MP0_C2PMSG_70_DW
    xor  esi, esi
    call smn_w32
    mov  edi, MP0_C2PMSG_71_DW
    mov  esi, GPU_PSP_RING_SIZE
    call smn_w32
    mov  edi, MP0_C2PMSG_64_DW
    mov  esi, PSP_RING_TYPE_KM << 16
    call smn_w32
    mov  byte [psp_substep], 4

    call psp_wait_c2p64_ok
    test al, al
    jz   .fail
    mov  byte [psp_ring_state], 1
    mov  byte [psp_substep], 5

    ; SETUP_TMR: PSP will protect/use this GPU-visible system-memory range.
    call psp_zero_cmd
    mov  rbx, GPU_PSP_CMD_BASE
    mov  dword [rbx + PSP_CMD_ID], PSP_GFX_CMD_SETUP_TMR
    mov  dword [rbx + PSP_TMR_BUF_ADDR_LO], GPU_PSP_TMR_BASE
    mov  dword [rbx + PSP_TMR_BUF_ADDR_HI], 0
    mov  dword [rbx + PSP_TMR_BUF_SIZE], GPU_PSP_TMR_SIZE
    mov  dword [rbx + PSP_TMR_FLAGS], 2       ; virt_phy_addr
    mov  dword [rbx + PSP_TMR_SYS_ADDR_LO], GPU_PSP_TMR_BASE
    mov  dword [rbx + PSP_TMR_SYS_ADDR_HI], 0
    mov  edi, PSP_GFX_CMD_SETUP_TMR
    call psp_submit_cmd
    test al, al
    jz   .fail
    mov  rbx, GPU_PSP_CMD_BASE
    mov  eax, [rbx + PSP_CMD_RESP_STATUS]
    mov  [psp_tmr_status], eax
    cmp  dword [psp_tmr_status], 0
    jne  .fail

    mov  byte [gpu_bringup_state], GPU_STATE_PSP_READY
    mov  byte [psp_substep], 6
    mov  al, 1
    jmp  .out

.fail:
    xor  al, al
.out:
    pop  rsi
    pop  rdi
    pop  rcx
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint8 psp_submit_cmd(uint32 cmd_id /*edi*/)
;   Submits GPU_PSP_CMD_BASE through the KM/GPCOM ring and waits for the fence.
;   Caller must have populated the command buffer payload already.
; ---------------------------------------------------------------------------
psp_submit_cmd:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12

    mov  [psp_last_cmd], edi

    ; Read current WPTR, which is in DWORDs, then choose frame address.
    mov  edi, MP0_C2PMSG_67_DW
    call smn_r32
    mov  [psp_c2pmsg67_raw], eax
    mov  ebx, eax
    and  ebx, (GPU_PSP_RING_SIZE / 4) - 1
    shl  ebx, 2
    mov  r12, GPU_PSP_RING_BASE
    add  r12, rbx

    ; Clear and fill one 64-byte rb frame.
    mov  rdi, r12
    mov  rcx, PSP_GFX_RB_FRAME_SIZE / 8
    xor  rax, rax
    cld
    rep  stosq
    mov  dword [r12 + PSP_FRAME_CMD_ADDR_LO], GPU_PSP_CMD_BASE
    mov  dword [r12 + PSP_FRAME_CMD_ADDR_HI], 0
    mov  dword [r12 + PSP_FRAME_CMD_SIZE], PSP_GFX_CMD_RESP_SIZE
    mov  dword [r12 + PSP_FRAME_FENCE_ADDR_LO], GPU_PSP_FENCE_ADDR
    mov  dword [r12 + PSP_FRAME_FENCE_ADDR_HI], 0
    inc  dword [psp_last_fence]
    mov  eax, [psp_last_fence]
    mov  [r12 + PSP_FRAME_FENCE_VALUE], eax
    mov  byte [r12 + PSP_FRAME_VMID], 0

    ; Update write pointer in DWORDs.
    mov  eax, [psp_c2pmsg67_raw]
    add  eax, PSP_GFX_RB_FRAME_SIZE / 4
    and  eax, (GPU_PSP_RING_SIZE / 4) - 1
    mov  edi, MP0_C2PMSG_67_DW
    mov  esi, eax
    call smn_w32

    ; Wait for fence == last_fence.
    mov  ebx, [tick_count]
    add  ebx, PSP_TIMEOUT_TICKS
.wait_fence:
    mov  rdx, GPU_PSP_FENCE_ADDR
    mov  eax, [rdx]
    cmp  eax, [psp_last_fence]
    je   .done
    mov  ecx, [tick_count]
    cmp  ecx, ebx
    jb   .wait_fence
    xor  al, al
    jmp  .out

.done:
    mov  rdx, GPU_PSP_CMD_BASE
    mov  eax, [rdx + PSP_CMD_RESP_STATUS]
    mov  [psp_last_resp], eax
    mov  al, 1
.out:
    pop  r12
    pop  rsi
    pop  rdi
    pop  rdx
    pop  rcx
    pop  rbx
    ret

; Local helper: poll C2PMSG_64 for TrustOS/ring mailbox ready.
psp_wait_c2p64_ready:
    push rbx
    push rcx
    push rdi
    mov  ebx, [tick_count]
    add  ebx, PSP_TIMEOUT_TICKS
.loop:
    mov  edi, MP0_C2PMSG_64_DW
    call smn_r32
    mov  [psp_c2pmsg64_raw], eax
    mov  ecx, eax
    and  ecx, PSP_C2P64_READY_MASK
    cmp  ecx, PSP_C2P64_READY_VALUE
    je   .hit
    mov  ecx, [tick_count]
    cmp  ecx, ebx
    jb   .loop
    xor  al, al
    jmp  .wout
.hit:
    mov  al, 1
.wout:
    pop  rdi
    pop  rcx
    pop  rbx
    ret

; Local helper: poll C2PMSG_64 for command response success.
psp_wait_c2p64_ok:
    push rbx
    push rcx
    push rdi
    mov  ebx, [tick_count]
    add  ebx, PSP_TIMEOUT_TICKS
.loop:
    mov  edi, MP0_C2PMSG_64_DW
    call smn_r32
    mov  [psp_c2pmsg64_raw], eax
    mov  ecx, eax
    and  ecx, PSP_C2P64_OK_MASK
    cmp  ecx, PSP_C2P64_OK_VALUE
    je   .hit
    mov  ecx, [tick_count]
    cmp  ecx, ebx
    jb   .loop
    xor  al, al
    jmp  .wout
.hit:
    mov  al, 1
.wout:
    pop  rdi
    pop  rcx
    pop  rbx
    ret

; ---------------------------------------------------------------------------
section .data
align 4
psp_boot_status:        dd 0
psp_solution_status:    dd 0
psp_c2pmsg64_raw:       dd 0
psp_c2pmsg67_raw:       dd 0
psp_c2pmsg33_raw:       dd 0
psp_c2pmsg35_raw:       dd 0
psp_sos_version:        dd 0
psp_last_cmd:           dd 0
psp_last_resp:          dd 0
psp_last_fence:         dd 0
psp_tmr_status:         dd 0
align 1
psp_ring_state:         db 0
psp_substep:            db 0
