; ============================================================================
; amd_smu.asm - SMU (MP1) mailbox driver + Task H (PPSMC_MSG_PowerUpGfx)
; ----------------------------------------------------------------------------
; Wave 1.E + Task H. Reaches the SMU through the NBIO SMN proxy (see
; amd_smn.asm) because on APUs (Phoenix/Strix) the SMU's C2PMSG_*
; registers are NOT in the GPU's BAR0.
;
; Linux source-of-truth:
;   drivers/gpu/drm/amd/include/yellow_carp_offset.h
;     MP1_BASE__INST0_SEG1 = 0x0243FC00   ← the SMN-aliased segment
;     (Phoenix / Hawk Point family - gfx 11.0.1, PCI id 1002:1900 etc.)
;   drivers/gpu/drm/amd/include/asic_reg/mp/mp_13_0_4_offset.h
;     regMP1_SMN_C2PMSG_66 = 0x0282 (dword), _82 = 0x0292, _90 = 0x029A
;     All three have _BASE_IDX = 1, i.e. they live in SEG1.
;
;   drivers/gpu/drm/amd/pm/swsmu/smu13/smu_v13_0_4_ppt.c
;     send_msg_with_param() uses these registers verbatim.
;
; SMN address = MP1_BASE_SMN + (reg_dword * 4).
; Earlier guess 0x03B10000 was wrong - Phoenix SEG bases come from
; yellow_carp_offset.h, not the mp_13_0_4 header (which only carries
; dword offsets + BASE_IDX, with the actual bases resolved per-ASIC).
;
; Protocol (unchanged from dGPU):
;   1. Poll C2PMSG_90 until non-zero  (drain prior result)
;   2. Write 0 to C2PMSG_90           (clear)
;   3. Write argument to C2PMSG_82
;   4. Write message ID to C2PMSG_66  (kicks SMU)
;   5. Poll C2PMSG_90 until non-zero  (result code, expect 0x01 = OK)
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"
%include "amdgpu_regs.inc"
%include "amdgpu_ppsmc.inc"

section .text

global smu_msg_send
global smu_powerup_gfx
global smu_get_version
global smu_last_result
global smu_last_msg_id

extern smn_r32
extern smn_w32
extern gpu_mmio_r32
extern gpu_mmio_w32
extern gpu_mmio_wait_eq
extern tick_count

; --- MP1 SMN addresses (Strix Point, mp_13_0_4 SEG4) ----------------------
; VERIFIED 2026-05-26 on Strix Point hardware: 0x03B10000 (SEG4 alias) is
; what the SMU answers at. Do NOT swap this to 0x0243FC00 - that's MP0/PSP,
; not MP1/SMU. Touching MP1 at the PSP base produces silence (no ack).
%define MP1_BASE_SMN     0x03B10000
%define SMN_MP1_C2PMSG_66  (MP1_BASE_SMN + 0x0282 * 4)     ; 0x03B10A08
%define SMN_MP1_C2PMSG_82  (MP1_BASE_SMN + 0x0292 * 4)     ; 0x03B10A48
%define SMN_MP1_C2PMSG_90  (MP1_BASE_SMN + 0x029A * 4)     ; 0x03B10A68

; Healthy firmware acks within milliseconds; 200 PIT ticks (~10 ms at 50 Hz)
; is generous.
%define SMU_TIMEOUT_TICKS  200

; ---------------------------------------------------------------------------
; uint32 smu_msg_send(uint32 msg_id /*edi*/, uint32 arg /*esi*/)
;   Returns PPSMC_Result_* in eax, or 0 on timeout. Latches the full response
;   value into smu_last_result and the message ID into smu_last_msg_id.
; ---------------------------------------------------------------------------
smu_msg_send:
    push rbx
    push r12
    push r13
    mov  r12d, edi                  ; msg
    mov  r13d, esi                  ; arg
    mov  [smu_last_msg_id], r12d

    ; (1) Snapshot prior response for diag, then proceed. Linux's
    ; __smu_cmn_send_msg reads C2PMSG_90 once (informational) and then
    ; unconditionally clears it - it does NOT wait for non-zero. The old
    ; "wait until non-zero" guard would block forever on a clean SMU where
    ; C2PMSG_90 == 0, never reaching the C2PMSG_66 kick. That's exactly
    ; what wedged stage H on a cold boot (see docs/gpu-bringup-verified.md
    ; - the prior success relied on warm-reboot residue in C2PMSG_90).
    mov  edi, SMN_MP1_C2PMSG_90
    call smn_r32
    mov  [smu_prior_resp], eax

    ; (2) clear response
    mov  edi, SMN_MP1_C2PMSG_90
    xor  esi, esi
    call smn_w32

    ; (3) write argument
    mov  edi, SMN_MP1_C2PMSG_82
    mov  esi, r13d
    call smn_w32

    ; (4) write message ID - kicks SMU
    mov  edi, SMN_MP1_C2PMSG_66
    mov  esi, r12d
    call smn_w32

    ; (5) wait for response
    mov  ecx, SMU_TIMEOUT_TICKS
    call .wait_resp_nonzero
    test al, al
    jz   .timeout

    mov  edi, SMN_MP1_C2PMSG_90
    call smn_r32
    mov  [smu_last_result], eax
    pop  r13
    pop  r12
    pop  rbx
    ret

.timeout:
    mov  dword [smu_last_result], 0
    xor  eax, eax
    pop  r13
    pop  r12
    pop  rbx
    ret

; Local helper: poll SMN_MP1_C2PMSG_90 until non-zero, timeout in ecx ticks.
; al=1 hit, al=0 timeout. Clobbers rax,rbx,rcx,rdi.
.wait_resp_nonzero:
    push rcx
    mov  ebx, ecx
    mov  ecx, [tick_count]
    add  ebx, ecx
.wn_loop:
    mov  edi, SMN_MP1_C2PMSG_90
    call smn_r32
    test eax, eax
    jnz  .wn_hit
    mov  ecx, [tick_count]
    cmp  ecx, ebx
    jb   .wn_loop
    xor  al, al
    pop  rcx
    ret
.wn_hit:
    mov  al, 1
    pop  rcx
    ret

; ---------------------------------------------------------------------------
; uint8 smu_powerup_gfx(void)   - Task H (APU variant)
;
;   On Strix Point GFX is already powered by ABL at boot - there is no
;   PowerUpGfx message. The H stage instead:
;
;     1. TestMessage - mailbox handshake sanity. smu_v13_0_4 firmware
;        replies with PPSMC_Result_OK (1) in C2PMSG_90 and overwrites
;        C2PMSG_82 with the result code (1), NOT arg+1. So success here
;        means "smu_last_result == OK"; we record the C2PMSG_82 reply
;        in smu_test_echo purely for diagnostics.
;     2. DisallowGfxOff - pin GFX in the active state so our subsequent
;        GMC/CP register pokes don't race against power-gating.
;        Non-fatal: if rejected, GFX may still be active.
;     3. GFX scratch round-trip - confirms GC MMIO is live.
; ---------------------------------------------------------------------------
%define GFX_SCRATCH_DW    ((GC_BASE/4) + mmSCRATCH_REG0)
%define GFX_SCRATCH_PROBE 0xCAFEF00D

smu_powerup_gfx:
    push rbx

    ; (1) TestMessage handshake - only checks for OK ack.
    mov  edi, PPSMC_MSG_TestMessage
    xor  esi, esi
    call smu_msg_send
    cmp  eax, PPSMC_Result_OK
    jne  .smu_fail

    ; Snapshot the arg reg so we can see what convention the SMU uses.
    mov  edi, SMN_MP1_C2PMSG_82
    call smn_r32
    mov  [smu_test_echo], eax

    ; (2) DisallowGfxOff - best-effort. Don't fail the stage on this.
    mov  edi, PPSMC_MSG_DisallowGfxOff
    xor  esi, esi
    call smu_msg_send
    mov  [smu_disallow_result], eax

    ; (3) Round-trip GFX scratch. 0xFFFFFFFF = block clock-gated / in reset.
    mov  edi, GFX_SCRATCH_DW
    call gpu_mmio_r32
    cmp  eax, 0xFFFFFFFF
    je   .gfx_dead

    mov  edi, GFX_SCRATCH_DW
    mov  esi, GFX_SCRATCH_PROBE
    call gpu_mmio_w32

    mov  edi, GFX_SCRATCH_DW
    call gpu_mmio_r32
    cmp  eax, GFX_SCRATCH_PROBE
    jne  .gfx_dead

    mov  byte [gpu_bringup_state], GPU_STATE_GFX_POWERED
    mov  al, 1
    pop  rbx
    ret

.smu_fail:
.gfx_dead:
    xor  al, al
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint32 smu_get_version(void) - diag / mailbox sanity check
; ---------------------------------------------------------------------------
smu_get_version:
    mov  edi, PPSMC_MSG_GetSmuVersion
    xor  esi, esi
    call smu_msg_send
    cmp  eax, PPSMC_Result_OK
    jne  .err
    mov  edi, SMN_MP1_C2PMSG_82
    call smn_r32
    ret
.err:
    xor  eax, eax
    ret

; ---------------------------------------------------------------------------
section .data
align 4
smu_last_result:        dd 0
smu_last_msg_id:        dd 0
smu_test_echo:          dd 0     ; TestMessage reply (should be 0x12345679)
smu_disallow_result:    dd 0     ; DisallowGfxOff result code
smu_prior_resp:         dd 0     ; C2PMSG_90 value snapshot before sending
