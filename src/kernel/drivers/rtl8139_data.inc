section .data
sz_net_start db "NET: RTL8139 init", 0
sz_net_ready db "NET: RTL8139 ready", 0
sz_net_fail  db "NET: RTL8139 unavailable", 0
sz_arp_ok    db "NET: ARP gateway resolved", 0
sz_ping_ok   db "NET: ICMP echo reply from 10.0.2.2", 0
sz_ping_fail db "NET: ICMP ping failed", 0
ser_net_init db "[RTL INIT]", 10, 0
ser_net_ready db "[RTL READY]", 10, 0
ser_net_init_fail db "[RTL INIT FAIL]", 10, 0
ser_link_wait db "[LINK WAIT]", 10, 0
ser_link_up db "[LINK UP]", 10, 0
ser_link_timeout db "[LINK TIMEOUT]", 10, 0
ser_arp_send db "[ARP SEND]", 10, 0
ser_arp_ok db "[ARP OK]", 10, 0
ser_icmp_send db "[ICMP SEND]", 10, 0
ser_icmp_ok db "[ICMP OK]", 10, 0
ser_icmp_fail db "[ICMP FAIL]", 10, 0
ser_dhcp_start_8139 db "[DHCP DISC]", 10, 0
ser_dhcp_offer_8139 db "[DHCP OFFER]", 10, 0
ser_dhcp_ack_8139 db "[DHCP ACK]", 10, 0
ser_dhcp_fail_8139 db "[DHCP FAIL]", 10, 0
ser_dhcp_udp_hit db "[UDP]", 10, 0
ser_tx_len_reject db "[RTL8139 TX LEN REJECT]", 10, 0

section .bss
global rtl_active
global rtl_dhcp_bound
global rtl_dhcp_state
global rtl_dhcp_ip
global rtl_dhcp_router
global rtl_dhcp_server
global rtl_dhcp_dns
global rtl_guest_ip
global rtl_next_hop_ip
rtl_active:       resb 1
rtl_io_base:      resw 1
rtl_rx_off:       resw 1
rtl_pci_addr:     resd 1
global rtl8139_net_mac
rtl8139_net_mac:
rtl_mac:          resb 6
rtl_gw_mac:       resb 6
rtl_have_gw_mac:  resb 1
rtl_ping_reply:   resb 1
global rtl_ping_last_ttl
rtl_ping_last_ttl: resb 1
rtl_ping_seq:     resw 1
rtl_guest_ip:     resd 1
rtl_next_hop_ip:  resd 1
rtl_target_ip:    resd 1
global rtl_ping_start_tick
rtl_ping_start_tick: resq 1
rtl_dhcp_bound:          resb 1
global rtl_dhcp_offer_seen
rtl_dhcp_offer_seen:     resb 1
global rtl_dhcp_ack_seen
rtl_dhcp_ack_seen:       resb 1
rtl_dhcp_msg_type:       resb 1
global rtl_dhcp_xid
rtl_dhcp_xid:            resd 1
rtl_dhcp_state:          resb 1
rtl_dhcp_ip:             resd 1
rtl_dhcp_server:         resd 1
rtl_dhcp_router:         resd 1
rtl_dhcp_dns:            resd 1
rtl_dhcp_candidate_ip:   resd 1
rtl_dhcp_candidate_server: resd 1
rtl_dhcp_candidate_router: resd 1
rtl_dhcp_candidate_dns:  resd 1
global rtl8139_net_info
rtl8139_net_info:
    resb NET_NIC_INFO_SIZE
