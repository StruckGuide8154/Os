; ============================================================================
; amdgpu_regs.inc - AMD GFX11 (GC 11.0/11.5, Strix Point gfx1150) register map
; ----------------------------------------------------------------------------
; Pure data. Mirrors the dword offsets from Linux kernel headers:
;
;   drivers/gpu/drm/amd/include/asic_reg/gc/gc_11_0_0_offset.h
;   drivers/gpu/drm/amd/include/asic_reg/mmhub/mmhub_3_0_0_offset.h
;   drivers/gpu/drm/amd/include/asic_reg/mp/mp_13_0_0_offset.h
;
; Conventions
; -----------
;   * Names match the Linux ``regFOO`` (without the ``reg`` prefix), as
;     ``mmFOO`` for "MMIO address" style.
;   * All values are DWORD offsets within their IP block's MMIO window.
;     Multiply by 4 for byte offsets relative to the block base.
;     PM4 SET_*_REG packets want the dword form directly (after
;     subtracting the appropriate window base - see tools/gpu/pm4.py).
;   * Block bases live below. They are absolute byte offsets within
;     BAR0 / MMIO space; combine with the per-IP dword offset to get
;     the final MMIO address for direct register pokes.
;
; This is a working subset, not an exhaustive port. Add registers as
; bring-up reaches new IPs (PSP front-door, GMC page tables, MEC ring
; setup, etc.). When adding, cite the upstream Linux header in a comment.
; ============================================================================

%ifndef AMDGPU_REGS_INC
%define AMDGPU_REGS_INC

; ----------------------------------------------------------------------------
; IP block bases (byte offsets within BAR0).
; Source: Linux drivers/gpu/drm/amd/include/discovery.h enumerated bases
;         resolved at runtime via IP discovery table. For Strix Point the
;         values below are the discovered defaults; verify against the live
;         IP discovery blob (ip_discovery.bin in VBIOS) before trusting on
;         a new SKU.
; ----------------------------------------------------------------------------
GC_BASE         equ 0x00001260 * 4          ; Graphics & Compute block
MMHUB_BASE      equ 0x0001A000 * 4          ; Memory hub
MP0_BASE        equ 0x00016000 * 4          ; PSP (Microcontroller Processor 0)
MP1_BASE        equ 0x00016A00 * 4          ; SMU (Microcontroller Processor 1)

; ----------------------------------------------------------------------------
; PM4 register-window dword bases (see tools/gpu/pm4.py).
; These are NOT byte offsets - they are subtracted from a target dword
; offset to form the index payload of SET_*_REG packets.
; ----------------------------------------------------------------------------
PM4_BASE_CONTEXT  equ 0x0000A000
PM4_BASE_SH       equ 0x00002C00
PM4_BASE_UCONFIG  equ 0x0000C000
PM4_BASE_CONFIG   equ 0x00002000

; ============================================================================
; GC 11.0 - graphics & compute
; Source: gc/gc_11_0_0_offset.h
; ============================================================================

; --- CP (Command Processor) -------------------------------------------------
mmCP_RB0_BASE                       equ 0x3040
mmCP_RB0_BASE_HI                    equ 0x30B1
mmCP_RB0_CNTL                       equ 0x3041
mmCP_RB0_RPTR                       equ 0x30C4
mmCP_RB0_RPTR_ADDR                  equ 0x3042
mmCP_RB0_RPTR_ADDR_HI               equ 0x3043
mmCP_RB0_WPTR                       equ 0x3074
mmCP_RB0_WPTR_HI                    equ 0x3075
mmCP_RB_VMID                        equ 0x30B2
mmCP_ME_CNTL                        equ 0x208D
mmCP_INT_CNTL_RING0                 equ 0x1E0A
mmCP_HQD_ACTIVE                     equ 0x1FAB
mmCP_HQD_VMID                       equ 0x1FAC
mmCP_MEC_CNTL                       equ 0x208E
mmCP_PFP_UCODE_ADDR                 equ 0x5814
mmCP_PFP_UCODE_DATA                 equ 0x5815
mmCP_ME_RAM_WADDR                   equ 0x5816
mmCP_ME_RAM_DATA                    equ 0x5817
mmCP_CE_UCODE_ADDR                  equ 0x5818
mmCP_CE_UCODE_DATA                  equ 0x5819
mmCP_MEC_ME1_UCODE_ADDR             equ 0x581A
mmCP_MEC_ME1_UCODE_DATA             equ 0x581B
mmCP_MEC_ME2_UCODE_ADDR             equ 0x581C
mmCP_MEC_ME2_UCODE_DATA             equ 0x581D

; --- RLC (Run-List Controller) ---------------------------------------------
mmRLC_CNTL                          equ 0x4B00
mmRLC_RLCS_GENERAL_0                equ 0x4C28
mmRLC_GPM_UCODE_ADDR                equ 0x5B61
mmRLC_GPM_UCODE_DATA                equ 0x5B62
mmRLC_GPU_CLOCK_COUNT_LSB           equ 0x4C04
mmRLC_GPU_CLOCK_COUNT_MSB           equ 0x4C05
mmRLC_SAFE_MODE                     equ 0x4C13
mmRLC_PG_CNTL                       equ 0x4C43

; --- GFXHUB (GCVM) - GFX-block-resident VM hub. CP/MEC/shaders translate
;     through this. Offsets are GC-block-relative dwords.
; Source: gc/gc_11_0_0_offset.h (regGCVM_*)
mmGCVM_CONTEXT0_CNTL                          equ 0x0BF0
mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32     equ 0x0BFC
mmGCVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32     equ 0x0BFD
mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32    equ 0x0C4C
mmGCVM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32    equ 0x0C4D
mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32      equ 0x0C9C
mmGCVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32      equ 0x0C9D
mmGCVM_INVALIDATE_ENG0_REQ                    equ 0x0D90
mmGCVM_INVALIDATE_ENG0_ACK                    equ 0x0DA0
mmGCVM_L2_PROTECTION_FAULT_STATUS             equ 0x0C31
mmGCVM_L2_PROTECTION_FAULT_ADDR_LO32          equ 0x0C34
mmGCVM_L2_PROTECTION_FAULT_ADDR_HI32          equ 0x0C35
mmGCVM_L2_PROTECTION_FAULT_CNTL               equ 0x0C30

; --- GRBM / SRBM scratch & status ------------------------------------------
mmGRBM_STATUS                       equ 0x0DA4
mmGRBM_STATUS2                      equ 0x0DA3
mmGRBM_SOFT_RESET                   equ 0x0DA8
mmGRBM_GFX_INDEX                    equ 0x2200
mmGRBM_CNTL                         equ 0x0DA0

; --- Scratch ---------------------------------------------------------------
mmSCRATCH_REG0                      equ 0x2040
mmSCRATCH_REG1                      equ 0x2041
mmSCRATCH_UMSK                      equ 0x2050
mmSCRATCH_ADDR                      equ 0x2051

; --- SPI (Shader Processor Interpolator) - shader programming -------------
mmSPI_SHADER_PGM_LO_VS              equ 0x2C4C
mmSPI_SHADER_PGM_HI_VS              equ 0x2C4D
mmSPI_SHADER_PGM_RSRC1_VS           equ 0x2C4E
mmSPI_SHADER_PGM_RSRC2_VS           equ 0x2C4F
mmSPI_SHADER_USER_DATA_VS_0         equ 0x2C60          ; ..._VS_31 = 0x2C7F

mmSPI_SHADER_PGM_LO_PS              equ 0x2C08
mmSPI_SHADER_PGM_HI_PS              equ 0x2C09
mmSPI_SHADER_PGM_RSRC1_PS           equ 0x2C0A
mmSPI_SHADER_PGM_RSRC2_PS           equ 0x2C0B
mmSPI_SHADER_USER_DATA_PS_0         equ 0x2C20          ; ..._PS_31 = 0x2C3F

mmSPI_PS_INPUT_ENA                  equ 0xA191
mmSPI_PS_INPUT_ADDR                 equ 0xA192
mmSPI_PS_IN_CONTROL                 equ 0xA193
mmSPI_PS_INPUT_CNTL_0               equ 0xA191          ; (window-relative, see header)
mmSPI_VS_OUT_CONFIG                 equ 0xA1B1
mmSPI_SHADER_POS_FORMAT             equ 0xA1C3
mmSPI_SHADER_Z_FORMAT               equ 0xA1C4
mmSPI_SHADER_COL_FORMAT             equ 0xA1C5

; --- PA (Primitive Assembler) / VGT (vertex grouper) ----------------------
mmPA_CL_VTE_CNTL                    equ 0xA206
mmPA_CL_CLIP_CNTL                   equ 0xA204
mmPA_SC_AA_CONFIG                   equ 0xA2F8
mmPA_SC_WINDOW_SCISSOR_TL           equ 0xA20F
mmPA_SC_WINDOW_SCISSOR_BR           equ 0xA210
mmVGT_PRIMITIVE_TYPE                equ 0xC242          ; uconfig window
mmVGT_INDEX_TYPE                    equ 0xC243
mmVGT_NUM_INDICES                   equ 0xC24C
mmVGT_DRAW_INITIATOR                equ 0xA1FC

; --- Color buffer (CB) / MRT0 ----------------------------------------------
mmCB_COLOR0_BASE                    equ 0xA318
mmCB_COLOR0_BASE_EXT                equ 0xA390
mmCB_COLOR0_VIEW                    equ 0xA31B
mmCB_COLOR0_INFO                    equ 0xA31C
mmCB_COLOR0_ATTRIB                  equ 0xA31D
mmCB_COLOR0_DCC_CONTROL             equ 0xA31E
mmCB_COLOR0_CMASK                   equ 0xA31F
mmCB_TARGET_MASK                    equ 0xA08E
mmCB_SHADER_MASK                    equ 0xA08F

; --- Depth buffer (DB) -----------------------------------------------------
mmDB_DEPTH_CONTROL                  equ 0xA200
mmDB_RENDER_CONTROL                 equ 0xA000
mmDB_Z_INFO                         equ 0xA010

; ============================================================================
; MMHUB 3.0 - memory hub (GPU MMU / page tables / VMIDs)
; Source: mmhub/mmhub_3_0_0_offset.h
; ============================================================================
mmMMHUB_CONTROL                                 equ 0x0068
mmMMVM_CONTEXT0_CNTL                            equ 0x0500
mmMMVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32       equ 0x050C
mmMMVM_CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32       equ 0x050D
mmMMVM_CONTEXT0_PAGE_TABLE_START_ADDR_LO32      equ 0x055C
mmMMVM_CONTEXT0_PAGE_TABLE_START_ADDR_HI32      equ 0x055D
mmMMVM_CONTEXT0_PAGE_TABLE_END_ADDR_LO32        equ 0x05AC
mmMMVM_CONTEXT0_PAGE_TABLE_END_ADDR_HI32        equ 0x05AD
mmMMVM_INVALIDATE_ENG0_REQ                      equ 0x06A0
mmMMVM_INVALIDATE_ENG0_ACK                      equ 0x06B0
mmMMVM_L2_PROTECTION_FAULT_STATUS               equ 0x0641
mmMMVM_L2_PROTECTION_FAULT_ADDR_LO32            equ 0x0644
mmMMVM_L2_PROTECTION_FAULT_ADDR_HI32            equ 0x0645
mmMMVM_L2_CNTL                                  equ 0x0500          ; (block-relative form)

; ============================================================================
; MP 13.0 - PSP / SMU mailbox
; Source: mp/mp_13_0_0_offset.h
; ============================================================================

; PSP (MP0) mailbox doorbell + status. Used for the PSP front-door
; firmware load (CP/RLC/SDMA ucode signed blobs).
mmMP0_SMN_C2PMSG_33                 equ 0x0061          ; PSP bootloader cmd
mmMP0_SMN_C2PMSG_35                 equ 0x0063          ; PSP bootloader addr lo
mmMP0_SMN_C2PMSG_36                 equ 0x0064          ; PSP bootloader addr hi
mmMP0_SMN_C2PMSG_58                 equ 0x007A          ; PSP SOS firmware version
mmMP0_SMN_C2PMSG_64                 equ 0x0080          ; PSP GFX ctrl cmd/resp
mmMP0_SMN_C2PMSG_67                 equ 0x0083          ; PSP GPCOM write pointer
mmMP0_SMN_C2PMSG_69                 equ 0x0085          ; PSP GPCOM ring addr lo
mmMP0_SMN_C2PMSG_70                 equ 0x0086          ; PSP GPCOM ring addr hi
mmMP0_SMN_C2PMSG_71                 equ 0x0087          ; PSP GPCOM ring size
mmMP0_SMN_C2PMSG_81                 equ 0x0091          ; PSP solution-state
mmMP0_SMN_C2PMSG_103                equ 0x00A7          ; PSP boot status

; SMU (MP1) mailbox.
mmMP1_SMN_C2PMSG_66                 equ 0x0282
mmMP1_SMN_C2PMSG_82                 equ 0x0292
mmMP1_SMN_C2PMSG_90                 equ 0x029A

; ============================================================================
; IMU + RLC autoload + CP RS64/F32 ucode-load registers (Phoenix gfx_11_0_3)
; ----------------------------------------------------------------------------
; PROVISIONAL - values lifted from gc_11_0_0_offset.h (Phoenix uses the same
; GC11.0 base map). Verify against an authoritative dump of the running
; Linux box before flipping any of these on. See docs/gpu-bringup.md.
;
; All offsets are DWORDs within the GC block (BASE_IDX 0 = GC_BASE).
; ============================================================================

; --- IMU (Integrated Microcontroller) - gfx_v11_0 -------------------------
; The IMU owns RLC backdoor autoload on APUs. It is the firmware that reads
; the autoload TOC out of DRAM (pointed at by GFX_IMU_FW_GTS_*) and pushes
; each blob into its destination SRAM (CP IRAM, RLC GPM/SRM, etc.).
mmGFX_IMU_FW_GTS_LO                 equ 0x4111      ; FW directory phys addr lo
mmGFX_IMU_FW_GTS_HI                 equ 0x4112      ; FW directory phys addr hi
mmGFX_IMU_CORE_CTRL                 equ 0x40B6      ; bit 0 = CORE_RESET_N
mmGFX_IMU_C2PMSG_0                  equ 0x40B0      ; IMU mailbox response
mmGFX_IMU_C2PMSG_15                 equ 0x40BF      ; IMU mailbox status

; --- RLC autoload status - gfx_v11_0_rlc_backdoor_autoload_check_complete -
; BOOTLOAD_STATUS bit 31 (BOOTLOAD_COMPLETE) flips when IMU has finished
; staging every TOC entry. Driver polls this register, not C2PMSG.
mmRLC_RLCS_BOOTLOAD_STATUS          equ 0x4E03

; --- CP IC (Instruction Cache) base - F32 ucode load --------------------
; Phoenix CP is F32, not RS64. Linux gfx_v11_0_cp_gfx_load_pfp_microcode
; programs IC_BASE_LO/HI/CNTL then writes the ucode block via the IC_DATA
; window (CP_PFP_UCODE_ADDR/DATA pair already in the header above).
mmCP_PFP_IC_BASE_LO                 equ 0x589A
mmCP_PFP_IC_BASE_HI                 equ 0x589B
mmCP_PFP_IC_BASE_CNTL               equ 0x589C
mmCP_ME_IC_BASE_LO                  equ 0x5895
mmCP_ME_IC_BASE_HI                  equ 0x5896
mmCP_ME_IC_BASE_CNTL                equ 0x5897
mmCP_MEC_IC_BASE_LO                 equ 0x589E
mmCP_MEC_IC_BASE_HI                 equ 0x589F

; --- RLC autoload kick / address pair (legacy; older path) -----------------
; Newer GFX11 uses IMU_FW_GTS_* instead. Kept here for compatibility with
; the older backdoor-autoload sequence some Linux versions still use.
mmRLC_AUTOLOAD_LO_ADDR              equ 0x4C9C      ; PROVISIONAL
mmRLC_AUTOLOAD_HI_ADDR              equ 0x4C9D      ; PROVISIONAL
mmRLC_AUTOLOAD_SIZE                 equ 0x4C9E      ; PROVISIONAL
mmRLC_BACKDOOR_AUTOLOAD_CONTROL     equ 0x4C9F      ; PROVISIONAL

; ============================================================================
; PSP (MP0) - Phoenix mp_13_0_5 BAR0-MMIO path
; ----------------------------------------------------------------------------
; On Phoenix APU, amdgpu reaches MP0 via DIRECT BAR0 MMIO (not the SMN proxy).
; The dword address is `MP0_BASE/4 + regMP0_SMN_C2PMSG_xx`. With MP0_BASE
; (byte) = 0x58000 we get MP0_BASE_DW = 0x16000.
;
; To form an absolute dword offset for gpu_mmio_r32/w32:
;   addr_dw = (MP0_BASE / 4) + mmMP0_SMN_C2PMSG_xx
; e.g. C2PMSG_33 → 0x16000 + 0x0061 = 0x16061  (byte 0x58184)
; ============================================================================
MP0_BASE_DW     equ (MP0_BASE / 4)

%endif ; AMDGPU_REGS_INC
