; ============================================================================
; NexusOS kernel runtime state and cross-module constants.
; Split from the former src/kernel/core/main.asm owner file.
; ============================================================================
%include "constants.inc"
%include "macros.inc"
; smap.inc is included by usermode.asm too, but that include is reached AFTER
; the former monolithic owner in the old build, so pull it in here for the USER_ACCESS_*
; macros used by the media live-refresh scanner below. The SMAP_INC guard makes
; the later includes no-ops; this becomes the sole definition of smap_smep_init.
%include "smap.inc"
; CET (security_todo.md §3): SHSTK/IBT detection (always) + the gated hardware
; enable scaffold. Included here so cet_detect/cet_enable have a
; single definition site in the monolithic build, mirroring smap.inc above.
%include "cet.inc"
%include "kpti.inc"


; Window struct offsets
WIN_OFF_ID      equ 0
WIN_OFF_X       equ 8
WIN_OFF_Y       equ 16
WIN_OFF_W       equ 24
WIN_OFF_H       equ 32
WIN_OFF_FLAGS   equ 40
WIN_OFF_TITLE   equ 48
WIN_OFF_DRAWFN  equ 112
WIN_OFF_KEYFN   equ 120
WIN_OFF_CLICKFN equ 128
WIN_OFF_APPDATA equ 136
WIN_OFF_DRAGFN  equ 144         ; optional fn(win, client_x, client_y) fired while left button held

APP_SLOT_BMP_FILE_OFF equ 0x17D000
NBA1_MAGIC            equ 0x3141424E

; FPS overlay region
FPS_REGION_X    equ 8
FPS_REGION_Y    equ 8
FPS_REGION_W    equ 290
FPS_REGION_H    equ 40

extern fill_rect

%define OVL_X   8
%define OVL_Y   56
%define OVL_W   760
%define OVL_H   320

CTX_W   equ 100
CTX_H   equ 22

SVG_DUMP_W equ 160
SVG_DUMP_H equ 90

section .data
debug_y: dd 40
global gui_initialized
gui_initialized db 0
global main_loop_stage, main_loop_stage_done, main_loop_iters
main_loop_stage      db 0    ; stage we are about to enter
main_loop_stage_done db 0    ; last stage that completed
main_loop_iters      dd 0    ; full iterations of the .infinite loop
global scene_dirty
scene_dirty db 1
rf_last_mouse_x dd 0xFFFFFFFF
rf_last_mouse_y dd 0xFFFFFFFF
rf_last_fps     dd 0xFFFFFFFF

; Serial/SVG probe and network diagnostic messages.
svg_dump_hdr db "[SVGDUMP]", 10, 0
svg_dump_dim db "DIM ", 0
svg_dump_ftr db "[SVGEND]", 10, 0
net_ping_start_msg db "[NETPING START]", 10, 0
net_ping_ics_start_msg db "[NETPING ICS START]", 10, 0
net_ping_google_start_msg db "[NETPING GOOGLE START]", 10, 0
net_ping_ok_msg db "[NETPING OK]", 10, 0
net_ping_fail_msg db "[NETPING FAIL]", 10, 0



section .data
szFPSPrefix db "FPS:", 0
fps_str     times 16 db 0

; Real-hardware iGPU bring-up diagnostics. '=' appends these lines to the klog
; and opens the existing full-screen klog viewer; no USB/file write required.
s_diag_begin     db "IGPUDBG:BEGIN v1", 0
s_diag_end       db "IGPUDBG:END", 0
s_diag_boot      db "BOOT fb=", 0
s_diag_mem       db "MEM backbuf=", 0
s_diag_disp      db "DISP fb=", 0
s_diag_native    db "NATIVE ", 0
s_diag_pci       db "PCI gpuCount=", 0
s_diag_780m_line db "PCI780M bdf=", 0
s_diag_780m_bar  db "PCI780M bar0=", 0
s_diag_amd_line  db "PCIAMD bdf=", 0
s_diag_amddisp   db "AMDDISP active=", 0
s_diag_amdmode   db "AMDMODE ", 0
s_diag_loop      db "LOOP iters=", 0
s_diag_input     db "INPUT numlock=", 0
s_diag_w         db " w=", 0
s_diag_h         db " h=", 0
s_diag_x         db "x", 0
s_diag_pitch     db " pitch=", 0
s_diag_bpp       db " bpp=", 0
s_diag_sz        db " size=", 0
s_diag_apps      db " apps=", 0
s_diag_bb        db " bb=", 0
s_diag_vsync     db " vsync=", 0
s_diag_fps       db " fps=", 0
s_diag_780m      db " 780m=", 0
s_diag_amd       db " amd=", 0
s_diag_id        db " id=", 0
s_diag_class     db " class=", 0
s_diag_cmd       db " cmd=", 0
s_diag_status    db " status=", 0
s_diag_bdf       db " bdf=", 0
s_diag_fb        db " fb=", 0
s_diag_usbkb     db " usbKb=", 0
s_diag_usbkb2    db " usbKb2=", 0
s_diag_xhci      db " xhci=", 0
s_diag_fs        db "FS rdBase=", 0
s_diag_fs_sz     db " rdSize=", 0
s_diag_fs_tot    db " fatTot=", 0
s_diag_fs_n      db " files=", 0
s_diag_fs2       db "FS rdAct=", 0
s_diag_fs2_b0    db " rdQ0=", 0
s_diag_fs2_sb    db " sbQ0=", 0

s_fbp_hdr        db "FBPERF init=", 0
s_fbp_patok      db " patSup=", 0
s_fbp_cr4        db " cr4=", 0
s_fbp_pat        db "FBPERF PAT=", 0
s_fbp_mtrrcap    db " mtrrCap=", 0
s_fbp_mtrrdef    db " mtrrDef=", 0
s_fbp_mtrrn      db " varN=", 0
s_fbp_pteline    db "FBPERF leafLvl=", 0
s_fbp_pteval     db " leafVal=", 0
s_fbp_caching    db " cache=", 0
s_fbp_wcplan     db "FBPERF wcPlanPAT=", 0
s_fbp_wcarm      db " armed=", 0
s_fbp_wcact      db " activated=", 0
s_fbp_mtrri      db "FBPERF mtrr#", 0
s_fbp_mtrri_b    db " base=", 0
s_fbp_mtrri_m    db " mask=", 0
s_wcact_tag      db "[FBPERF] wc_activate rax=", 0
s_wcact_fail     db "[FBPERF] WC activation FAILED -- halting (see codes in fbperf.asm)", 0
s_fbp_flips      db "FBPERF flips=", 0
s_fbp_full       db " full=", 0
s_fbp_rect       db " rect=", 0
s_fbp_fbytes     db " fullB=", 0
s_fbp_rbytes     db " rectB=", 0
s_fbp_tbytes     db " totB=", 0
s_fbp_tsctot     db "FBPERF tscTot=", 0
s_fbp_tscmin     db " tscMin=", 0
s_fbp_tscmax     db " tscMax=", 0
s_fbp_tsclast    db " tscLast=", 0

; --- GFX11 bring-up diag labels ---
s_gfx_hdr     db "GFX state=", 0
s_gfx_stage   db " stage=", 0
s_gfx_smu     db " smu=", 0
s_gfx_fault   db " fault=", 0
s_gfx_bar     db "GFX bar0=", 0
s_gfx_db      db " db=", 0
s_gfx_smn     db "SMN c2p90=", 0
s_gfx_smn_idx db " c2p66=", 0
s_gfx_smn_arg db " c2p82=", 0
s_gfx_test    db "SMU test=", 0
s_gfx_dis     db " disGfx=", 0
s_gfx_msgid   db " lastMsg=", 0
s_gmc_sub     db "GMC step=", 0
s_gmc_ack     db " ack=", 0
s_gmc_cntl    db " cntl=", 0
s_gmc_faddr   db "GMC faddr=", 0
s_cp_sub      db "CP step=", 0
s_cp_cntl     db " cntl=", 0
s_cp_base     db " base=", 0
s_psp_step    db "PSP step=", 0
s_psp_fwstep  db " fwstep=", 0
s_psp_sol     db " sol=", 0
s_psp_boot    db " boot=", 0
s_psp_c33     db "PSP c33=", 0
s_psp_c35     db " c35=", 0
s_psp_sos     db " sos=", 0
s_psp_c64     db "PSP c64=", 0
s_psp_c67     db " c67=", 0
s_psp_cmd     db " cmd=", 0
s_psp_resp    db " resp=", 0
s_psp_tmr     db "PSP tmr=", 0
s_psp_fwstat  db " fwstat=", 0
s_psp_rlcsz   db " rlcSz=", 0
s_psp_rlcack  db " rlcAck=", 0
s_psp_rlcaddr db "PSP rlcAddr=", 0

; --- Task L (CP PFP/ME/MEC + un-halt + NOP) labels ---
s_l_step      db "L step=", 0
s_l_type      db " type=", 0
s_l_stage     db " stage=", 0
s_l_state     db " state=", 0
s_l_pfp       db "L pfpSz=", 0
s_l_me        db " meSz=", 0
s_l_mec       db "L mecSz=", 0
s_l_ack       db " ack=", 0
s_l_cme_pre   db "L cmePre=", 0
s_l_cme_post  db " cmePost=", 0
s_l_nop_sub   db " nop=", 0
s_l_rptr      db " rptr=", 0

; --- MP0 SMN segment probe labels ---
s_probe_hdr   db "MP0 PROBE done=", 0
s_probe_seg   db "seg=", 0
s_phx_note    db "PHX gfx_11_0_3: PSP via BAR0 MMIO (not SMN); awaiting IP-disc + FW blobs", 0
s_imu_hdr     db "IMU autoload n=", 0
s_imu_total   db " total=", 0
s_imu_miss    db " miss=", 0
s_imu_last    db " lastType=", 0
s_imu_kick    db " kick=", 0
s_fat_hdr     db "FAT n=", 0
s_fat_first   db " first=", 0
s_ipd_hdr     db "IPDISC found=", 0
s_ipd_at      db " at=", 0
s_ipd_ver     db " ver=", 0
s_ipd_dies    db " dies=", 0
s_ipd_mp0     db "IPDISC MP0=", 0
s_ipd_mp1     db " MP1=", 0
s_ipd_gc      db " GC=", 0
s_ipd_imu     db " IMU=", 0
s_ipd_vram    db " vramHit=", 0
s_probe_c33   db " c33=", 0
s_probe_c58   db " c58=", 0
s_probe_c64   db " c64=", 0
s_probe_c81   db " c81=", 0

; --- DCN read-only probe labels ---
s_dcn_hdr     db "DCN bar0=", 0
s_dcn_ok      db " mmio=", 0
s_dcn_lvl     db " pteLvl=", 0
s_dcn_pat     db " patIdx=", 0
s_dcn_cache   db " cache=", 0
s_dcn_pte     db "DCN pte=", 0
s_dcn_r0      db "DCN r00=", 0
s_dcn_r4      db " r04=", 0
s_dcn_r8      db " r08=", 0
s_dcn_rC      db " r0C=", 0
s_dcn_cfg     db "DCN cfg=", 0
s_dcn_cmd_pre db " cmdPre=", 0
s_dcn_cmd_post db " cmdPost=", 0
s_dcn_uc_hdr  db "DCN UC ok=", 0
s_dcn_uc_r0   db " r0000=", 0
s_dcn_uc_r4   db " r0004=", 0
s_dcn_uc_r8   db " r1000=", 0
s_dcn_uc_rC   db " r3000=", 0
s_dcn_uc_walk db "DCN UC walkLvl=", 0
s_dcn_uc_walk_p db " walkPte=", 0
s_dcn_ip_hdr  db "DCN IP table (off:val, non-zero only):", 0
s_dcn_ip_pfx  db "IP+", 0
s_dcn_eq      db "=", 0
s_dcn_sp      db " ", 0
s_dcn_bl_hdr  db "DCN BL hunt @BAR0+0x", 0
s_dcn_bl_pfx  db "BL+", 0
s_dmub_hdr    db "DMUB ok=", 0
s_dmub_cntl   db " cntl=", 0
s_dmub_cntl2  db " cntl2=", 0
s_dmub_sec    db " sec=", 0
s_dmub_scr0   db "DMUB scratch0=", 0
s_dmub_bits   db " bits=", 0
s_dmub_scr7   db " scratch7=", 0
s_dmub_timer  db " timer=", 0
s_dmub_state  db "DMUB state=", 0
s_dmub_s1     db " scratch1=", 0
s_dmub_s14    db " scratch14=", 0
s_dmub_s15    db " scratch15=", 0
s_dmub_fbraw  db "DMUB fbBaseReg=", 0
s_dmub_fboffraw db " fbOffReg=", 0
s_dmub_fbbase db " fbBase=", 0
s_dmub_fboff  db " fbOff=", 0
s_dmub_ring   db "DMUB ring arm=", 0
s_dmub_rstat  db " status=", 0
s_dmub_rphys  db " sys=", 0
s_dmub_rfb    db " fb=", 0
s_dmub_ring2  db "DMUB ring inFb=", 0
s_dmub_outfb  db " outFb=", 0
s_dmub_gpstat db " gpStat=", 0
s_dmub_gpreq  db " gpReq=", 0
s_dmub_gpresp db " gpResp=", 0
s_dmub_cw6      db "DMUB cw6 base=", 0
s_dmub_cw6_top  db " top=", 0
s_dmub_cw6_olo  db " offLo=", 0
s_dmub_cw6_ohi  db " offHi=", 0
s_fw_a          db "FW stat=", 0
s_fw_size       db " size=", 0
s_fw_inst       db " inst=", 0
s_fw_ver        db " ver=", 0
s_fw_b          db "FW region=", 0
s_fw_trace      db " trace=", 0
s_fw_ss         db " ss=", 0
s_fw_feat       db " feat=", 0
s_dmub_gp2    db "DMUB gp2 dataOut=", 0
s_dmub_gppolls db " polls=", 0
s_dmub_gpstart db " t0=", 0
s_dmub_gpend  db " t1=", 0
s_dmub_cmd    db "DMUB cmd stat=", 0
s_dmub_cmd_r0 db " r0=", 0
s_dmub_cmd_w0 db " w0=", 0
s_dmub_cmd_r1 db " r1=", 0
s_dmub_cmd_w1 db " w1=", 0
s_dmub_cmd2   db "DMUB cmd q0=", 0
s_dmub_cmd_q1 db " q1=", 0
s_dmub_inb    db "DMUB inb1 base=", 0
s_dmub_outb   db "DMUB outb1 base=", 0
s_dmub_size   db " size=", 0
s_dmub_rptr   db " rptr=", 0
s_dmub_wptr   db " wptr=", 0
s_dmub_gpint  db "DMUB gpint in=", 0
s_dmub_out    db " out=", 0
s_dmub_ifault db " iflt=", 0
s_dmub_dfault db " dflt=", 0
s_dmub_ufault db " uflt=", 0

; --- ACPI EC RAM labels ---
s_ec_hdr      db "EC dumpOk=", 0
s_ec_low      db "EC[00..1F]=", 0
s_ec_mid      db "EC[20..6F]=", 0
s_ec_high     db "EC[70..8F]=", 0

; --- USB-mouse debug overlay scratch + labels ---
ovl_buf     times 192 db 0
s_o_l1      db "xhci=", 0
s_o_noxhci  db "  noXHCI=", 0
s_o_mact    db "  mouseAct=", 0
s_o_retry   db "  retry=", 0
s_o_stage   db "  STAGE=", 0
s_o_stagemax db " max=", 0
s_o_fpn     db " fpCalls=", 0
s_o_hwslot  db "  hwSlot=", 0
s_o_port    db "port=", 0
s_o_spd     db "  speed=", 0
s_o_slot    db "  slot1=", 0
s_o_s2      db "  slot2act=", 0
s_o_ep      db "epAddr=", 0
s_o_mps     db "  maxpkt=", 0
s_o_proto   db "  hidProto=", 0
s_o_evt     db "xferEvt=", 0
s_o_rpt     db "  reports=", 0
s_o_err     db "  errs=", 0
s_o_ec      db "  errCode=", 0
s_o_adn     db "  adN=", 0
s_o_adcc    db " adCC=", 0
s_o_scr     db " scratch=", 0
s_o_scr_req db "/", 0
s_o_adst_h  db "adSt=", 0
s_o_cc1     db "  cc1=", 0
s_o_cc2     db "  cc2=", 0
s_o_portsc  db "  PORTSC=", 0
s_o_slotst  db "  slotSt=", 0
s_o_rst_h   db "rstSt=", 0
s_o_ped     db "  PED=", 0
s_o_ccs     db "  CCS=", 0
s_o_sppre   db "  spPre=", 0
s_o_sppost  db "  spPost=", 0
s_o_pscpre  db "  pscPre=", 0
s_o_pscpost db "  pscPost=", 0
s_o_wrt     db "wrt=", 0
s_o_imm     db "  imm=", 0
s_o_wait    db "  wait=", 0
s_o_polls   db "  pls=", 0
s_o_r0      db "report b0=", 0
s_o_r1      db "  dX=", 0
s_o_r2      db "  dY=", 0
s_o_r3      db "  b3=", 0
s_o_noctrl  db "PCI scan: no xHCI controller found", 0
s_o_ctrl    db "xHCI#", 0
s_o_cbus    db " bus=", 0
s_o_cdev    db " dev=", 0
s_o_cfn     db " fn=", 0
s_o_cports  db " ports=", 0
s_o_cmap    db " map=", 0
s_o_init    db "init#", 0
s_o_istage  db " stage=", 0
s_o_fp      db "findPort#", 0
s_o_ml_iters db "ML iters=", 0
s_o_ml_stage db "  stage=", 0
s_o_ml_done  db "  done=", 0
s_o_ml_tick  db "  tick=", 0
s_o_fmp     db " ports=", 0
s_o_fr      db " result=", 0
s_o_fmap    db " sees=", 0

ovl_ci      dd 0
ovl_li      dd 0
ovl_rec     dq 0
; PCI xHCI inventory: scanned once. Up to 4 controllers, 64-byte records:
;  +0 bus  +1 dev  +2 fn  +3 maxports  +4..: per-port speed code (0 = empty)
global usb_dbg_pci_done
usb_dbg_pci_done:  db 0
usb_dbg_xhci_n:    db 0
usb_dbg_xhci_rec:  times 4*64 db 0

; BSP CPU utilization accounting (see cpu_acct_* routines above).
global bsp_util
bsp_util         dd 0
acct_last_mark   dq 0
acct_work_start  dq 0
acct_busy_acc    dq 0
acct_idle_acc    dq 0
acct_win_tick    dq 0
acct_tsc_start   dq 0
taskmgr_last_refresh_tick dq 0

section .bss
serial_command_armed resb 1
ui_blink_phase resb 1
process_mouse_last_buttons resb 1
process_mouse_prev_buttons resb 1
