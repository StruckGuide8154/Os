sz_r8156_init  db "NET: RTL8156 USB init", 0
sz_r8156_ready db "NET: RTL8156 USB ready", 0
sz_r8156_fail  db "NET: RTL8156 USB unavailable", 0
ser_dhcp_start db "[DHCP DISC]", 10, 0
ser_dhcp_offer db "[DHCP OFFER]", 10, 0
ser_dhcp_ack db "[DHCP ACK]", 10, 0
ser_dhcp_fail db "[DHCP FAIL]", 10, 0
ser_r8156_ping_fail db "[R8156 PING FAIL]", 10, 0
ser_link_wait_8156 db "[R8156 LINK WAIT]", 10, 0
ser_link_up_8156 db "[R8156 LINK UP]", 10, 0
ser_link_timeout_8156 db "[R8156 LINK TIMEOUT]", 10, 0
ser_phy_tag db "PHY:", 0
ser_mac_tag db "MAC:", 0
ser_oob_tag db "OOB:", 0
ser_al_done db "ALDONE:", 0
ser_sff7_tag db "SFF7:", 0
ser_ll_ready db "[LL READY]", 10, 0
ser_ll_timeout db "[LL TIMEOUT]", 10, 0
ser_tcr0_tag db "TCR0:", 0
ser_cr_tag db "CR:", 0
ser_bmcr_tag db "BMCR BMSR:", 0
ser_bmsr_tag db "BMSR:", 0
ser_tx_tag db "TX len=", 0
ser_tx_done db "TXok", 10, 0
ser_rx_tag db "RX len=", 0
ser_ep_tag db "[R8156 EP in/out mps]:", 0
ser_ep_ctx_in db "[R8156 IN ctx d0/d1]:", 0
; Static profiles used until DHCP is available. Values are little-endian IPv4
; in frame order: guest, next-hop gateway.
rtl8156_ip_profiles:
    dd 0x3264A8C0, 0x0164A8C0    ; 192.168.100.50 -> 192.168.100.1
    dd 0x3201A8C0, 0x0101A8C0    ; 192.168.1.50   -> 192.168.1.1
    dd 0x3200A8C0, 0x0100A8C0    ; 192.168.0.50   -> 192.168.0.1
    dd 0x3289A8C0, 0x0189A8C0    ; 192.168.137.50 -> 192.168.137.1
    dd 0x3200000A, 0x0100000A    ; 10.0.0.50      -> 10.0.0.1
RTL8156_IP_PROFILE_COUNT equ 5

section .bss
global rtl8156_active
global rtl8156_probed
global rtl8156_dbg_stage
global rtl8156_dhcp_bound
global rtl8156_dhcp_state
global rtl8156_dhcp_ip
global rtl8156_dhcp_router
global rtl8156_dhcp_server
global rtl8156_dhcp_dns
global rtl8156_guest_ip
global rtl8156_next_hop_ip
rtl8156_active:          resb 1
global rtl8156_deferred_init_pending
rtl8156_deferred_init_pending: resb 1
rtl8156_deferred_init_running: resb 1
rtl8156_deferred_init_done:    resb 1
rtl8156_init_allow_blocking:   resb 1
alignb 4
rtl8156_lock:            resd 1
; TX-completion mailbox. The main-loop poller routes bulk-OUT transfer
; events here so an in-progress wait_completion (driving a TX) can still
; observe them even though the event ring was drained by usb_poll_mouse.
global rtl8156_tx_done_set, rtl8156_tx_done_code
rtl8156_tx_done_set:  resb 1
alignb 4
rtl8156_tx_done_code: resd 1
rtl8156_probed:          resb 1
rtl8156_dbg_stage:       resb 1
rtl8156_phy_dbg_last:    resq 1
rtl8156_rx_poll_count:   resd 1
global rtl8156_last_vid, rtl8156_last_pid, rtl8156_last_portsc, rtl8156_last_bmsr
rtl8156_last_vid:        resw 1
rtl8156_last_pid:        resw 1
rtl8156_last_portsc:     resd 1
rtl8156_last_bmsr:       resw 1
rtl8156_product:         resw 1
rtl8156_bulk_in_addr:    resb 1
rtl8156_bulk_out_addr:   resb 1
rtl8156_bulk_in_dci:     resb 1
rtl8156_bulk_out_dci:    resb 1
rtl8156_bulk_in_mps:     resw 1
rtl8156_bulk_out_mps:    resw 1
rtl8156_bulk_in_burst:   resb 1
rtl8156_bulk_out_burst:  resb 1
rtl8156_bulk_in_enqueue: resd 1
rtl8156_bulk_out_enqueue: resd 1
rtl8156_bulk_in_cycle:   resb 1
rtl8156_bulk_out_cycle:  resb 1
rtl8156_probe_port_tries: resd 1
rtl8156_walk_port:        resb 1
global rtl8156_net_mac
rtl8156_net_mac:
rtl8156_mac:             resb 6
rtl8156_gw_mac:          resb 6
rtl8156_have_gw_mac:     resb 1
rtl8156_slot_id:         resb 1
global rtl8156_port
rtl8156_port:            resb 1
rtl8156_ping_reply:      resb 1
global rtl8156_ping_last_ttl
rtl8156_ping_last_ttl:   resb 1
global rtl8156_ping_seq
rtl8156_ping_seq:        resw 1
rtl8156_guest_ip:        resd 1
rtl8156_next_hop_ip:     resd 1
rtl8156_target_ip:       resd 1
rtl8156_dhcp_bound:      resb 1
rtl8156_dhcp_offer_seen: resb 1
rtl8156_dhcp_ack_seen:   resb 1
rtl8156_dhcp_msg_type:   resb 1
rtl8156_dhcp_xid:        resd 1
rtl8156_dhcp_state:      resb 1
rtl8156_dhcp_deadline:   resq 1
rtl8156_bulk_in_inflight: resb 1
rtl8156_dhcp_ip:         resd 1
rtl8156_dhcp_server:     resd 1
rtl8156_dhcp_router:     resd 1
rtl8156_dhcp_dns:        resd 1
rtl8156_dhcp_candidate_ip: resd 1
rtl8156_dhcp_candidate_server: resd 1
rtl8156_dhcp_candidate_router: resd 1
rtl8156_dhcp_candidate_dns: resd 1
global rtl8156_ping_start_tick, rtl8156_ping_start_tsc
rtl8156_ping_start_tick: resq 1
rtl8156_ping_start_tsc:  resq 1
; TSC captured at the instant the ICMP echo reply is parsed (set in
; rtl8156_dhcp_parse.ghl). Read by the ping RTT math so the round-trip is measured
; against reply arrival, not the userspace poll that notices it.
global rtl8156_ping_reply_tsc
rtl8156_ping_reply_tsc:  resq 1
rtl8156_ping_async_state: resb 1
rtl8156_ping_async_retries: resb 1
alignb 8
rtl8156_ping_async_deadline: resq 1
global rtl8156_net_info
rtl8156_net_info:
    resb NET_NIC_INFO_SIZE
