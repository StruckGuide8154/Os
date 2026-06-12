; ============================================================================
; GritOS ICMP protocol module
; ----------------------------------------------------------------------------
; ICMP ping is exposed through net_ping_ipv4 in nic.asm, which selects the
; active backend and preserves the existing syscall contract. Echo builders
; and reply parsing can move here after the raw TX/RX contract is finalized.
; ============================================================================
bits 64

section .text
