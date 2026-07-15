; ============================================================================
; Grit v3.0 - Realtek RTL8152/RTL8156 USB Ethernet backend
; ----------------------------------------------------------------------------
; Raw USB path for Realtek r8152-family NICs passed through to QEMU with WinUSB
; / Zadig. This is intentionally small, but it includes the pieces the RTL8139
; path cannot provide: vendor OCP register access, xHCI bulk endpoints, Realtek
; TX/RX descriptors, ARP, and ICMP echo.
; ============================================================================
bits 64

%include "constants.inc"
%include "net_driver.inc"

; The tx path stores an 8-byte Realtek TX descriptor at RTL8156_TX_BUF_ADDR then
; the Ethernet frame (up to NET_ETH_FRAME_MAX) at +8, all inside the reserved DMA
; window that ends where the scratch region begins. Pin the invariant so a future
; memory-map change that shrinks this window fails the build instead of silently
; reintroducing the DMA overrun the tx bounds check closes.
%if ((RTL8156_SCRATCH_ADDR - RTL8156_TX_BUF_ADDR) < (NET_ETH_FRAME_MAX + 8))
  %error "RTL8156 TX DMA window smaller than NET_ETH_FRAME_MAX + descriptor"
%endif

extern xhci_init
extern xhci_active
extern xhci_find_port
extern xhci_find_port_next
extern xhci_enable_slot
extern xhci_address_device
extern xhci_port_num
extern xhci_max_ports
extern xhci_op_base
extern usb_slot1_port
extern usb_slot2_port
extern xhci_nic_mode
extern usb_hid_port_owned
extern xhci_queue_ctrl_trb
extern xhci_ring_doorbell
extern xhci_poll_event
extern xhci_flush_events
extern xhci_slot_id
extern xhci_int_ep_dci
extern xhci_ctx_stride
extern xhci_port_speed
extern xhci_dbg_adcc1
extern xhci_dbg_adcc2
extern xhci_dbg_adstage
extern xhci_dbg_slotstate
extern tick_count
extern cpu_tsc_per_tick
extern debug_print
extern usb_poll_mouse
extern net_rx_frame

; --- Driver capability gate (security_todo.md §8) ---------------------------
; This driver performs NO direct MMIO of its own: every register poke reaches
; the controller through the xHCI doorbell/ring path (xhci.asm) at offsets
; inside xhci_mmio_base. Its "regions I may touch" capability descriptor is
; therefore the xHCI BAR, declared under MMIO_DRV_RTL8156 by mmio_drv_caps_init
; (mmio_bounds.inc). Should this driver ever gain a direct MMIO store, bracket
; it with `mmio_bounds_assert(addr, len, MMIO_DRV_RTL8156)` against that
; registered window. The id is reserved here so the registry already covers it.
MMIO_DRV_RTL8156_DESC equ MMIO_DRV_RTL8156

section .text

RTL8156_VENDOR_REALTEK equ 0x0BDA
RTL8156_REQ_REGS       equ 0x05
RTL8156_REQT_READ      equ 0xC0
RTL8156_REQT_WRITE     equ 0x40
RTL8156_BYTE_DWORD     equ 0xFF
RTL8156_MCU_USB        equ 0x0000
RTL8156_MCU_PLA        equ 0x0100

RTL8156_PLA_IDR        equ 0xC000
RTL8156_PLA_RCR        equ 0xC010
RTL8156_PLA_CR         equ 0xE813
RTL8156_PLA_MISC_1     equ 0xE85A
RTL8156_PLA_TCR0       equ 0xE610
RTL8156_PLA_RMS        equ 0xC016        ; RX max frame size (Linux: must be set)
RTL8156_PLA_MAR        equ 0xCD00        ; multicast filter (8 bytes)
RTL8156_USB_USB_CTRL   equ 0xD406
RTL8156_USB_UPT_RXDMA_OWN equ 0xD437
; RX buffer / early-timeout knobs. Without these the chip never flushes a
; partial burst out the bulk IN endpoint even when aggregation is disabled,
; so the host's IN tokens come back empty forever.
RTL8156_USB_RX_BUF_TH      equ 0xCC00
RTL8156_USB_RX_EARLY_SIZE  equ 0xCC10
RTL8156_USB_RX_EARLY_TIMEOUT equ 0xCC4C
RTL8156_PLA_PHYSTATUS  equ 0xC0D8       ; PHY/link status (low 3 bits = state)
RTL8156_PHY_STAT_MASK  equ 0x07
RTL8156_PHY_STAT_LAN_ON equ 0x03         ; link is up (PHY_STAT_LAN_ON, Linux r8152)
; PHY MDIO access uses an indirect window: write a 4K page base to
; PLA_OCP_GPHY_BASE (0xE86C), then read/write the corresponding offset in
; the 0xB000-0xBFFF mirror. To reach PHY MII reg N: ocp_addr = 0xA400+N*2,
; base = ocp_addr & 0xF000 = 0xA000, index = 0xB000 | (ocp_addr & 0x0FFF).
; NOTE: the base-select register is 0xE86C (Linux r8152 PLA_OCP_GPHY_BASE).
; A previous value of 0xB12C was wrong: writing the PHY page base there left
; the OCP window pointed at an unmapped page, so every MII reg read back 0
; (symptom: BMCR *and* BMSR both 0x0000 right after writing BMCR).
RTL8156_PLA_OCP_GPHY_BASE equ 0xE86C
RTL8156_OCP_BASE_PHY   equ 0xA000        ; (the PHY OCP page base)
RTL8156_PHY_REG0_OFFSET equ 0x400        ; PHY MII reg 0 (BMCR) lives here in the page
RTL8156_BYTE_EN_WORD   equ 0x33          ; OCP byte-enable for 16-bit write
RTL8156_BYTE_EN_BYTE   equ 0x11          ; byte-enable for 8-bit write
RTL8156_MII_BMCR       equ 0x00          ; MII basic-mode control reg
RTL8156_MII_BMSR       equ 0x01          ; MII basic-mode status reg
RTL8156_BMCR_ANE       equ 0x1000
RTL8156_BMCR_RAN       equ 0x0200
RTL8156_BMCR_RESET     equ 0x8000        ; PHY soft-reset; self-clears when done
RTL8156_BMSR_LSTATUS   equ 0x0004        ; link status (latched, sticky-low)
RTL8156_BMSR_ANEGCOMP  equ 0x0020        ; auto-neg complete
; Power-up registers (Linux r8152 r8153_first_init).
RTL8156_PLA_OOB_CTRL   equ 0xE84C
RTL8156_NOW_IS_OOB     equ 0x80
RTL8156_PLA_SFF_STS_7  equ 0xE78A        ; r8152.c PLA_SFF_STS_7 (was wrongly 0xE648 - LINK_LIST_READY lives here)
RTL8156_PLA_BOOT_CTRL  equ 0xE004        ; r8152.c PLA_BOOT_CTRL
RTL8156_AUTOLOAD_DONE  equ 0x0002        ; r8152.c AUTOLOAD_DONE (bit 1)
RTL8156_MCU_BORW_EN    equ 0x4000
RTL8156_RE_INIT_LL     equ 0x8000
RTL8156_LINK_LIST_READY equ 0x0002

RTL8156_CR_RE          equ 0x08
RTL8156_CR_TE          equ 0x04
RTL8156_RCR_AAP        equ 0x00000001
RTL8156_RCR_APM        equ 0x00000002
RTL8156_RCR_AM         equ 0x00000004
RTL8156_RCR_AB         equ 0x00000008
RTL8156_RX_AGG_DISABLE equ 0x0010
RTL8156_RXDY_GATED_EN  equ 0x00080000
RTL8156_OWN_UPDATE_CLEAR equ 0x03000000

RTL8156_TX_FS          equ 0x80000000
RTL8156_TX_LS          equ 0x40000000
RTL8156_RX_LEN_MASK    equ 0x00007FFF

%include "src/kernel/drivers/rtl8156_ping.inc"
%include "src/kernel/drivers/rtl8156_init.inc"
%include "src/kernel/drivers/rtl8156_phy.inc"
%include "src/kernel/drivers/rtl8156_eps.inc"
%include "src/kernel/drivers/rtl8156_txrx.inc"
%include "src/kernel/drivers/rtl8156_usb.inc"
%include "src/kernel/drivers/rtl8156_debug.inc"
%include "src/kernel/drivers/rtl8156_data.inc"
