; ============================================================================
; GritOS DHCP protocol module
; ----------------------------------------------------------------------------
; DHCP app/syscall entry now routes through net_dhcp_start/net_dhcp_configure
; in nic.asm. The remaining per-backend packet builders and parsers are kept
; behind that dispatcher until they can be lifted one protocol at a time.
; ============================================================================
bits 64

section .text
