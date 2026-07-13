; ============================================================================
; Grit installable-driver device-class ABI v1
;
; Stable broker-facing records shared by network, input, storage, audio,
; display, power, and WLAN class services. Drivers exchange typed records and
; opaque handles; raw kernel addresses and function pointers never cross the
; process boundary.
; ============================================================================
%ifndef DEVICE_CLASS_INC
%define DEVICE_CLASS_INC

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
DEVMSG_ABI_VERSION       equ 0    ; u32
DEVMSG_CLASS             equ 4    ; u16
DEVMSG_OPCODE            equ 6    ; u16
DEVMSG_FLAGS             equ 8    ; u32
DEVMSG_PAYLOAD_LEN       equ 12   ; u32
DEVMSG_DEVICE_HANDLE     equ 16   ; u64
DEVMSG_REQUEST_ID        equ 24   ; u64
DEVMSG_STATUS            equ 32   ; s32
DEVMSG_RESERVED          equ 36   ; u32, must be zero
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
DEVRING_OPCODE           equ 0    ; u16
DEVRING_FLAGS            equ 2    ; u16
DEVRING_OFFSET           equ 4    ; u32
DEVRING_LENGTH           equ 8    ; u32
DEVRING_GENERATION       equ 12   ; u32
DEVRING_DEVICE_HANDLE    equ 16   ; u64
DEVRING_COOKIE           equ 24   ; u64
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

%endif
