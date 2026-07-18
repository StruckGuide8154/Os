; ============================================================================
; amdgpu_ppsmc.inc - PPSMC message IDs for AMD SMU mailbox
; ----------------------------------------------------------------------------
; Pure data. The PPSMC ("PowerPlay SMC") namespace is the message protocol
; between the host driver and the SMU microcontroller. Each SoC family ships
; a slightly different table; the values below are the smu_v13_0_4 / _0_5
; subset relevant to Strix Point (gfx1150).
;
; Source:
;   drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu_v13_0_4_ppsmc.h
;   drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu_v13_0_5_ppsmc.h
;
; Conventions
; -----------
;   * PPSMC_MSG_* are written to MP1_SMN_C2PMSG_66.
;   * Message argument (if any) goes to MP1_SMN_C2PMSG_82 *before* the message.
;   * Response is read from MP1_SMN_C2PMSG_90 after the SMU clears the prior
;     1 written there. Expected ack = 1 (PPSMC_Result_OK).
;
; Add IDs as bring-up reaches new SMU operations. Always cite the upstream
; header in a comment when adding.
; ============================================================================

%ifndef AMDGPU_PPSMC_INC
%define AMDGPU_PPSMC_INC

; --- Result codes (read from C2PMSG_90) -----------------------------------
PPSMC_Result_OK                 equ 0x01
PPSMC_Result_Failed             equ 0xFF
PPSMC_Result_UnknownCmd         equ 0xFE
PPSMC_Result_CmdRejectedPrereq  equ 0xFD
PPSMC_Result_CmdRejectedBusy    equ 0xFC

; --- Message IDs (smu_v13_0_4 - Strix Point / Phoenix APUs) ---------------
;
; Source: drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu_v13_0_4_ppsmc.h
;
; IMPORTANT: APUs have NO PowerUpGfx message. GFX is powered by ABL/PSP
; at boot and stays on; the driver only controls clock-gating via
; AllowGfxOff / DisallowGfxOff. Task H on this family is therefore:
;     1. TestMessage  - proves mailbox alive (echoes arg+1)
;     2. DisallowGfxOff - keep GFX from auto-gating during bring-up
;     3. GFX scratch round-trip - confirms MMIO is live
PPSMC_MSG_TestMessage              equ 0x01
PPSMC_MSG_GetSmuVersion            equ 0x02
PPSMC_MSG_GetDriverIfVersion       equ 0x03
PPSMC_MSG_PowerDownVcn             equ 0x04
PPSMC_MSG_PowerUpVcn               equ 0x05
PPSMC_MSG_SetHardMinVcn            equ 0x06
PPSMC_MSG_PrepareMp1ForUnload      equ 0x07
PPSMC_MSG_SetDriverDramAddrHigh    equ 0x08
PPSMC_MSG_SetDriverDramAddrLow     equ 0x09
PPSMC_MSG_TransferTableSmu2Dram    equ 0x0A
PPSMC_MSG_TransferTableDram2Smu    equ 0x0B
PPSMC_MSG_GfxDeviceDriverReset     equ 0x0C
PPSMC_MSG_GetEnabledSmuFeatures    equ 0x0D
PPSMC_MSG_AllowGfxOff              equ 0x12
PPSMC_MSG_DisallowGfxOff           equ 0x13
PPSMC_MSG_PowerGateMmHub           equ 0x19

%endif ; AMDGPU_PPSMC_INC
