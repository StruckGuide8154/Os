; ============================================================================
; amd_gfx.asm - GFX11 bring-up orchestrator (H → I → J wave runner)
; ----------------------------------------------------------------------------
; Single entry point that walks the bring-up state machine, calling each
; module in dependency order and short-circuiting on the first failure.
;
;   gfx_bringup() - call from main.asm AFTER:
;     * pci_gpu_scan completed
;     * amd_display_probe completed (BAR0 captured, decode enabled)
;
;   Hardware contact is ENTIRELY gated by this call. Nothing in gpu/* runs
;   unless this function is invoked. Stage failures leave the state machine
;   in a recoverable position so a future re-call after fixing prerequisites
;   resumes from the right step.
;
;   The function is intentionally tiny - it is the seam between "wave plan"
;   (docs/gpu-bringup.md) and the actual hardware sequence. Each Task gets
;   one call here and one global to flip.
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"

section .text

global gfx_bringup
global gfx_last_stage

extern gpu_mmio_init        ; amd_gpu_mmio
extern smu_powerup_gfx      ; amd_smu     (Task H)
extern gmc_init             ; amd_gmc     (Task I)
extern cp_ring_alloc        ; amd_cp_ring (Task J)
extern cp_ring_map_doorbell ; amd_cp_ring (Task J)
extern psp_load_rlc         ; amd_psp_fwload (Task K) - abandoned NBIO path
extern psp_load_cp          ; amd_psp_fwload (Task L) - abandoned NBIO path
extern cp_gfx_start_nop     ; amd_cp_ring    (Task L verify)
extern imu_autoload_build   ; amd_imu       - scan ramdisk + build TOC
extern imu_autoload_kick    ; amd_imu       - STUB until FW blobs present
extern ip_disc_scan         ; amd_ip_disc   - read-only IP discovery parse
extern ip_disc_scan_vram    ; amd_ip_disc   - MM_INDEX/DATA fallback
extern ip_disc_found        ; amd_ip_disc
; psp_probe_mp0 retired 2026-05-26: probed MP0 through the NBIO SMN proxy,
; but on Phoenix (Ryzen 780M, gfx_11_0_3 / mp_13_0_5) amdgpu reaches MP0 via
; *direct BAR0 MMIO*, not the SMN proxy. The probe could only ever return
; zeros and was pure noise. The Phoenix MP0 path lives in a Wave-3 PSP
; driver gated behind real FW blobs and IP-discovery-confirmed bases.

; ---------------------------------------------------------------------------
; uint8 gfx_bringup(void)
;   Returns the post-walk gpu_bringup_state value (cast to byte).
;   Caller can compare against GPU_STATE_RING_ALLOCATED for "full success".
;   gfx_last_stage records the *last attempted* stage for diagnostics -
;   useful from the boot overlay when a stage fails.
; ---------------------------------------------------------------------------
gfx_bringup:
    ; Stage 0 - MMIO seam
    mov  byte [gfx_last_stage], 0
    call gpu_mmio_init
    test al, al
    jz   .out

    ; Stage D - IP discovery scan (read-only). Populates ip_disc_* globals
    ; so the boot overlay can show the authoritative MP0/MP1/GC bases for
    ; this exact SoC. Never fails the bring-up - diag-only. If the FB
    ; linear scan misses, fall back to MM_INDEX/DATA VRAM scan.
    mov  byte [gfx_last_stage], 'D'
    call ip_disc_scan
    cmp  byte [ip_disc_found], 0
    jne  .ipd_done
    call ip_disc_scan_vram
.ipd_done:

    ; Stage H - SMU PowerUpGfx
    mov  byte [gfx_last_stage], 'H'
    call smu_powerup_gfx
    test al, al
    jz   .out

    ; Stage I - GMC context-0 page tables
    mov  byte [gfx_last_stage], 'I'
    call gmc_init
    test al, al
    jz   .out

    ; Stage J - CP ring + doorbell
    mov  byte [gfx_last_stage], 'J'
    call cp_ring_alloc
    test al, al
    jz   .out
    call cp_ring_map_doorbell
    ; Doorbell mapping is a soft failure: ring still works via register
    ; wptr writes. Don't propagate.

    ; Stage M - IMU autoload TOC build (read-only by default). Scans the
    ; FAT16 ramdisk for Phoenix FW blobs and lays out a psp_gfx_uc_info[]
    ; TOC + concatenated payload in GPU_PSP_FW_STAGING_BASE. With no blobs
    ; on disk this is a no-op that populates diag globals only.
    mov  byte [gfx_last_stage], 'M'
    call imu_autoload_build
%ifdef GRIT_GFX_IMU_KICK
    ; Stage N - IMU kick. Writes GFX_IMU_FW_GTS_*, releases IMU reset,
    ; polls RLC_RLCS_BOOTLOAD_STATUS. On success, gpu_bringup_state is
    ; advanced to GPU_STATE_CP_LOADED so the existing CP unhalt path
    ; below picks up.
    mov  byte [gfx_last_stage], 'N'
    call imu_autoload_kick
    test al, al
    jz   .out                       ; timeout or blocked - leave state put

    ; Stage P - CP F32 unhalt + PM4 NOP retire. The cp_gfx_start_nop in
    ; amd_cp_ring.asm clears CP_ME_CNTL halt bits, drops RB_NO_UPDATE,
    ; writes a 2-dword NOP at ring offset 0, bumps WPTR, and polls RPTR.
    ; A successful retire flips gpu_bringup_state to CP_RUNNING.
    mov  byte [gfx_last_stage], 'P'
    call cp_gfx_start_nop
    test al, al
    jz   .out
%endif

%ifdef GRIT_GFX_WAVE3_FIRE
    ; Stage K - PSP LOAD_IP_FW for RLC. Re-gated 2026-05-26 after the BAR0
    ; MMIO path was found to wedge NBIO/SMN on Strix when MP0_BASE was wrong.
    ; Until the correct MP0 access path on gfx1150 is identified, K stays
    ; opt-in (`-GfxWave3` flag) so default boots leave H/I/J intact.
    mov  byte [gfx_last_stage], 'K'
    call psp_load_rlc
    test al, al
    jz   .out
%endif

%ifdef GRIT_GFX_WAVE3_L_FIRE
    ; Stage L - CP firmware load (PFP/ME/MEC) then un-halt + NOP retire.
    ; Still gated until the three GC115{PFP,ME,MEC}.BIN blobs are present on
    ; the ramdisk and at least one hardware K-ack has been observed.
    mov  byte [gfx_last_stage], 'L'
    call psp_load_cp
    test al, al
    jz   .out
    call cp_gfx_start_nop
    test al, al
    jz   .out
%endif

.out:
    mov  al, [gpu_bringup_state]
    ret

; ---------------------------------------------------------------------------
section .data
align 1
gfx_last_stage:    db 0
