; ============================================================================
; Grit v3.0 - RTL8139 Ethernet + minimal ARP/ICMP probe
; ----------------------------------------------------------------------------
; QEMU user-net default: guest 10.0.2.15, gateway 10.0.2.2.
; Provides a serial-triggered ICMP echo request path for basic network bring-up.
; ============================================================================
bits 64

%include "constants.inc"
%include "net_driver.inc"

extern pci_read_conf_dword
extern pci_write_conf_dword
extern tick_count
extern debug_print
extern net_rx_frame

section .text

RTL_VENDOR      equ 0x10EC
RTL_DEVICE      equ 0x8139

RTL_IDR0        equ 0x00
RTL_TSD0        equ 0x10
RTL_TSAD0       equ 0x20
RTL_RBSTART     equ 0x30
RTL_CR          equ 0x37
RTL_CAPR        equ 0x38
RTL_CBR         equ 0x3A
RTL_IMR         equ 0x3C
RTL_ISR         equ 0x3E
RTL_TCR         equ 0x40
RTL_RCR         equ 0x44
RTL_CONFIG1     equ 0x52
RTL_MSR         equ 0x58       ; Media Status Register
RTL_BMCR        equ 0x62       ; MII Basic Mode Control
RTL_BMSR        equ 0x64       ; MII Basic Mode Status

RTL_MSR_LINKB   equ 0x04       ; 0 = link up (active-low)
RTL_BMCR_ANE    equ 0x1000     ; auto-negotiation enable
RTL_BMCR_RAN    equ 0x0200     ; restart auto-neg
RTL_BMSR_ANC    equ 0x0020     ; auto-neg complete
RTL_BMSR_LINK   equ 0x0004     ; link status

RTL_CR_BUFE     equ 0x01
RTL_CR_TE       equ 0x04
RTL_CR_RE       equ 0x08
RTL_CR_RST      equ 0x10

RTL_RX_BUF_ADDR equ 0x01B00000
RTL_TX_BUF_ADDR equ 0x01B04000
RTL_RX_BUF_LEN  equ 8192
; Reserved TX DMA window: everything from the TX buffer up to the next reserved
; region (the RTL8156 bulk-IN ring). The tx path copies at most NET_ETH_FRAME_MAX
; bytes here; pin the invariant so a future memory-map change that shrinks this
; window below the max frame fails the build instead of silently reintroducing
; the DMA overrun this bounds check closes.
RTL_TX_BUF_LEN  equ (RTL8156_BULK_IN_RING_ADDR - RTL_TX_BUF_ADDR)
%if (RTL_TX_BUF_LEN < NET_ETH_FRAME_MAX)
  %error "RTL8139 TX DMA window smaller than NET_ETH_FRAME_MAX"
%endif
%include "src/kernel/drivers/rtl8139_init.inc"
%include "src/kernel/drivers/rtl8139_tx_rx.inc"
%include "src/kernel/drivers/rtl8139_dhcp.inc"
%include "src/kernel/drivers/rtl8139_data.inc"
