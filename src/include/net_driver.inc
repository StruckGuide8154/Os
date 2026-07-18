; ============================================================================
; Grit network driver ABI
; ----------------------------------------------------------------------------
; A NIC driver should stay hardware-only:
;   - probe/init the device
;   - expose its MAC
;   - transmit one complete Ethernet frame
;   - pump receive completions and pass complete Ethernet frames upward
;
; Protocol ownership lives in src/kernel/net:
;   Ethernet -> ARP -> IPv4 -> UDP/TCP/DHCP/DNS/ICMP
;
; Driver ops table layout:
;   dq name_ptr
;   dd driver_id
;   dd priority          ; larger wins when multiple NICs are active
;   dq init_fn           ; () -> EAX=1 active, 0 unavailable
;   dq active_flag_ptr   ; byte, 1 active
;   dq mac_ptr           ; six bytes
;   dq tx_frame_fn       ; RDI=Ethernet frame, ECX=len -> EAX=1 queued/sent
;   dq poll_rx_fn        ; non-blocking RX pump, returns EAX=1 if work
;   dq legacy_ping_fn    ; temporary until ICMP is fully generic
;   dq legacy_dhcp_fn    ; temporary until DHCP is fully generic
;   dq legacy_dhcp_start_fn
;   dq info_block_ptr    ; NET_NIC_INFO_* byte/dword fields below
; ============================================================================

NET_NIC_OP_NAME             equ 0
NET_NIC_OP_ID               equ 8
NET_NIC_OP_PRIORITY         equ 12
NET_NIC_OP_INIT             equ 16
NET_NIC_OP_ACTIVE_PTR       equ 24
NET_NIC_OP_MAC_PTR          equ 32
NET_NIC_OP_TX_FRAME         equ 40
NET_NIC_OP_POLL_RX          equ 48
NET_NIC_OP_LEGACY_PING4     equ 56
NET_NIC_OP_LEGACY_DHCP      equ 64
NET_NIC_OP_LEGACY_DHCP_START equ 72
NET_NIC_OP_INFO_PTR         equ 80
NET_NIC_OP_SIZE             equ 88

NET_NIC_INFO_DHCP_BOUND     equ 0
NET_NIC_INFO_DHCP_STATE     equ 1
NET_NIC_INFO_LAST_TTL       equ 2
NET_NIC_INFO_RESERVED       equ 3
NET_NIC_INFO_DHCP_IP        equ 4
NET_NIC_INFO_DHCP_ROUTER    equ 8
NET_NIC_INFO_DHCP_SERVER    equ 12
NET_NIC_INFO_GUEST_IP       equ 16
NET_NIC_INFO_NEXT_HOP_IP    equ 20
NET_NIC_INFO_DNS_SERVER     equ 24
NET_NIC_INFO_SIZE           equ 28

NET_NIC_NONE                equ 0
NET_NIC_RTL8156             equ 1
NET_NIC_RTL8139             equ 2
NET_NIC_VIRTIO              equ 3

NET_ETH_TYPE_IPV4           equ 0x0008
NET_ETH_TYPE_ARP            equ 0x0608
NET_IP_PROTO_ICMP           equ 1
NET_IP_PROTO_TCP            equ 6
NET_IP_PROTO_UDP            equ 17

; --- Transmit frame-length contract (GSEC net) -------------------------------
; Every driver tx_frame_fn copies the caller-supplied frame into a fixed kernel
; DMA buffer with a `rep movsb` sized by the caller's length. That length MUST
; be range-checked against these bounds - once here at the generic dispatcher
; (net_nic_tx_frame) AND again in each concrete driver wrapper - before the copy,
; or a corrupt/oversized length overruns the DMA buffer into adjacent kernel
; memory (proven with a guard-page PoC on both rtl8139 and rtl8156).
;   MIN = a complete Ethernet header (dst6 + src6 + ethertype2). Hardware pads
;         short frames up to 60 bytes, so 14 is the smallest well-formed frame.
;   MAX = 1522 = 1500 payload + 14 header + 4 (802.1Q VLAN tag) + 4 FCS. This is
;         the largest standard (non-jumbo) frame; the TX DMA windows are sized
;         well above it (see the per-driver static asserts). The zero-asm GHL
;         drivers (rtl8156.ghl / virtio_net.ghl) enforce their own 1514 payload
;         cap independently; this shared bound stays >= that so it never rejects
;         a frame those paths would accept.
NET_ETH_FRAME_MIN           equ 14
NET_ETH_FRAME_MAX           equ 1522

; --- SplitMix64 PRNG finaliser constants (TCP ISN / ephemeral source port) ---
; Used by net_tcp_rng_* (src/kernel/net/tcp.asm). SplitMix64 is the reference
; finaliser published with Java 8's SplittableRandom (Steele, Lea & Flood,
; OOPSLA 2014, "Fast Splittable Pseudorandom Number Generators", §4 / Fig.1).
;   GOLDEN: 2^64/phi rounded to an odd integer - the per-draw state increment.
;   MIX1/MIX2: the two odd multiplicative mixing constants in the finaliser.
SPLITMIX64_GOLDEN           equ 0x9E3779B97F4A7C15
SPLITMIX64_MIX1             equ 0xBF58476D1CE4E5B9
SPLITMIX64_MIX2             equ 0x94D049BB133111EB

; --- DNS public fallback resolver -------------------------------------------
; Google Public DNS primary anycast address 8.8.8.8, in Grit A.B.C.D-packed
; scalar form. Tried by net_dns_query_a (src/kernel/net/dns.asm) when the
; DHCP-provided resolver does not answer. RFC 8482-class always-on resolver.
NET_DNS_FALLBACK_IP         equ 0x08080808

; ============================================================================
; Installable-driver device-class ABI v1
;
; Stable broker-facing records shared by network, input, storage, audio,
; display, power, and WLAN class services. Drivers exchange typed records and
; opaque handles; raw kernel addresses and function pointers never cross the
; process boundary.
; ============================================================================
DEVCLASS_ABI_MAJOR       equ 1
DEVCLASS_ABI_MINOR       equ 0
DEVCLASS_ABI_VERSION     equ ((DEVCLASS_ABI_MAJOR << 16) | DEVCLASS_ABI_MINOR)

; Class identifiers are stable package ABI, not concrete driver identifiers.
DEVCLASS_NET_L2          equ 1
DEVCLASS_INPUT_POINTER   equ 2
DEVCLASS_INPUT_KEYBOARD  equ 3
DEVCLASS_BLOCK           equ 4
DEVCLASS_AUDIO_PCM       equ 5
DEVCLASS_DISPLAY_SCANOUT equ 6
DEVCLASS_POWER_BATTERY   equ 7
DEVCLASS_WLAN_RADIO      equ 8

; Opaque handle: low 32 bits index, high 32 bits generation. Rebinding or
; restart increments generation, making every stale consumer handle fail.
DEV_HANDLE_INDEX_MASK    equ 0xFFFFFFFF
DEV_HANDLE_GEN_SHIFT     equ 32
DEV_HANDLE_INVALID       equ 0

; Common 40-byte message header. Payload follows immediately and is bounded by
; DEVMSG_PAYLOAD_LEN before a class broker reads it.
DEVMSG_ABI_VERSION       equ 0
DEVMSG_CLASS             equ 4
DEVMSG_OPCODE            equ 6
DEVMSG_FLAGS             equ 8
DEVMSG_PAYLOAD_LEN       equ 12
DEVMSG_DEVICE_HANDLE     equ 16
DEVMSG_REQUEST_ID        equ 24
DEVMSG_STATUS            equ 32
DEVMSG_RESERVED          equ 36
DEVMSG_HEADER_SIZE       equ 40

DEVMSG_F_RESPONSE        equ 0x0001
DEVMSG_F_EVENT           equ 0x0002
DEVMSG_F_OPTIONAL_FIELDS equ 0x0004

DEV_STATUS_OK            equ 0
DEV_STATUS_INVALID       equ -1
DEV_STATUS_ABI           equ -2
DEV_STATUS_DENIED        equ -3
DEV_STATUS_STALE         equ -4
DEV_STATUS_BUSY          equ -5
DEV_STATUS_GONE          equ -6

; Common 32-byte bounded-ring descriptor. OFFSET is relative to a broker-
; granted shared region, never an address. COOKIE is returned unchanged.
DEVRING_OPCODE           equ 0
DEVRING_FLAGS            equ 2
DEVRING_OFFSET           equ 4
DEVRING_LENGTH           equ 8
DEVRING_GENERATION       equ 12
DEVRING_DEVICE_HANDLE    equ 16
DEVRING_COOKIE           equ 24
DEVRING_DESC_SIZE        equ 32

DEVRING_F_DRIVER_OWNS    equ 0x0001
DEVRING_F_BROKER_OWNS    equ 0x0002
DEVRING_F_END_OF_BATCH   equ 0x0004

; net.l2 v1: the network stack sees one ordinary link regardless of whether
; the provider is Ethernet, Wi-Fi, USB, PCIe, or virtual hardware.
NETL2_OP_GET_INFO        equ 1
NETL2_OP_TX_FRAME        equ 2
NETL2_OP_RX_FRAME        equ 3
NETL2_OP_LINK_EVENT      equ 4
NETL2_OP_GET_COUNTERS    equ 5
NETL2_MAX_FRAME          equ 9216

; wlan.radio stays private to the Wi-Fi service/supplicant. It does not expose
; credentials or chipset-specific commands to applications or the IP stack.
WLAN_OP_GET_CAPS         equ 1
WLAN_OP_SCAN_START       equ 2
WLAN_OP_SCAN_RESULT      equ 3
WLAN_OP_ASSOCIATE        equ 4
WLAN_OP_DISCONNECT       equ 5
WLAN_OP_TX_80211         equ 6
WLAN_OP_RX_80211         equ 7
WLAN_OP_RADIO_EVENT      equ 8
