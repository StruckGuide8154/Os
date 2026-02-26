; ============================================================================
; NexusOS v3.0 - System Constants
; ============================================================================

; --- Memory Layout ---
STAGE2_LOAD_ADDR    equ 0x7E00       ; Stage 2 load address
E820_COUNT_ADDR     equ 0x1FF0       ; Number of E820 entries (dword)
E820_MAP_ADDR       equ 0x2000       ; E820 memory map entries
VBE_INFO_ADDR       equ 0x9000       ; VBE mode info block
BOOT_DRIVE_ADDR     equ 0x9100       ; Saved boot drive number (byte)
PAGE_TABLE_ADDR     equ 0x70000      ; PML4 page table base
KERNEL_LOAD_ADDR    equ 0x100000     ; 1MB - kernel load address
KERNEL_STACK_TOP    equ 0x200000     ; 2MB - top of kernel stack
IDT_ADDR            equ 0x200000     ; IDT location (same as stack top for now, risky? No, IDT is small)
; IDT is 256*16 = 4KB. If stack grows down from 2MB, IDT at 2MB grows up?
; IDT structure is fixed size.
; If Stack Top is 0x200000, IDT at 0x200000 overlaps stack top!
; Stack grows DOWN. IDT grows UP (fixed size).
; If IDT is at 0x200000, it occupies 0x200000 to 0x201000.
; If Stack starts at 0x200000, a push writes to 0x1FFFF8.
; So they don't overlap. This is safe.

KERNEL_DATA_ADDR    equ 0x210000     ; Kernel data/heap
PAGE_BITMAP_ADDR    equ 0x300000     ; Physical page bitmap
BACK_BUFFER_ADDR    equ 0x400000     ; Display back buffer
BACK_BUFFER_SAVE_ADDR equ 0xA00000     ; Saved back buffer (at 10MB)
CURSOR_BG_ADDR      equ 0x700000     ; Cursor background save area
WINDOW_POOL_ADDR    equ 0x710000     ; Window structure pool
EVENT_BUFFER_ADDR   equ 0x720000     ; Event buffers
APP_DATA_ADDR       equ 0x800000     ; Application data

; --- Stage 2 disk layout ---
STAGE2_SECTORS      equ 63           ; Sectors 1-63
KERNEL_START_SECTOR equ 64           ; Kernel starts at sector 64
KERNEL_SECTORS      equ 256          ; 128KB max kernel

; --- Screen ---
SCREEN_WIDTH        equ 1024
SCREEN_HEIGHT       equ 768
SCREEN_BPP          equ 32
SCREEN_PITCH        equ (SCREEN_WIDTH * 4)   ; 4096 bytes per scanline
FRAMEBUFFER_SIZE    equ (SCREEN_WIDTH * SCREEN_HEIGHT * 4)  ; 3145728 = ~3MB


; --- VBE info offsets (at VBE_INFO_ADDR) ---
VBE_FB_ADDR_OFF     equ 0x00         ; Framebuffer physical address (8 bytes)
VBE_WIDTH_OFF       equ 0x08         ; Screen width (4 bytes)
VBE_HEIGHT_OFF      equ 0x0C         ; Screen height (4 bytes)
VBE_PITCH_OFF       equ 0x10         ; Bytes per scanline (4 bytes)
VBE_BPP_OFF         equ 0x14         ; Bits per pixel (4 bytes)
VBE_SPP_OFF         equ 0x18         ; EFI_SIMPLE_POINTER_PROTOCOL interface ptr (qword, 0=none)

; --- Colors (32-bit 0x00RRGGBB, stored as BGRX in memory) ---
COLOR_BLACK         equ 0x00000000
COLOR_WHITE         equ 0x00FFFFFF
COLOR_DESKTOP_BG    equ 0x00335577   ; Blue-gray desktop
COLOR_TASKBAR_BG    equ 0x001A1A2E   ; Dark blue-gray taskbar
COLOR_TASKBAR_TOP   equ 0x002A2A4E   ; Taskbar top highlight
COLOR_TITLEBAR      equ 0x000055AA   ; Blue title bar (focused)
COLOR_TITLEBAR_UNF  equ 0x00555555   ; Gray title bar (unfocused)
COLOR_WINDOW_BG     equ 0x00F0F0F0   ; Light gray window background
COLOR_WINDOW_BORDER equ 0x00333333   ; Window border
COLOR_CLOSE_BTN     equ 0x00CC2222   ; Red close button
COLOR_CLOSE_HOVER   equ 0x00FF4444   ; Red close hover
COLOR_MIN_BTN       equ 0x00CCAA22   ; Yellow minimize button
COLOR_TEXT_WHITE     equ 0x00FFFFFF
COLOR_TEXT_BLACK     equ 0x00000000
COLOR_TEXT_GRAY      equ 0x00888888
COLOR_TEXT_TITLE     equ 0x00FFFFFF   ; Title bar text
COLOR_HIGHLIGHT      equ 0x003399FF   ; Selection highlight
COLOR_CURSOR         equ 0x00FFFFFF   ; Cursor color
COLOR_START_BTN      equ 0x00226622   ; Start button green
COLOR_START_HOVER    equ 0x00338833

; --- Window Manager ---
MAX_WINDOWS         equ 8
WINDOW_STRUCT_SIZE  equ 256          ; Bytes per window struct
TITLEBAR_HEIGHT     equ 24
BORDER_WIDTH        equ 2
CLOSE_BTN_SIZE      equ 18
MIN_BTN_SIZE        equ 18
MIN_WINDOW_W        equ 200
MIN_WINDOW_H        equ 100

; --- Taskbar ---
TASKBAR_HEIGHT      equ 36
TASKBAR_Y           equ (SCREEN_HEIGHT - TASKBAR_HEIGHT)
START_BTN_W         equ 70
START_BTN_H         equ 28
START_BTN_X         equ 4
START_BTN_Y         equ (TASKBAR_Y + 4)
CLOCK_WIDTH         equ 64
CLOCK_X             equ (SCREEN_WIDTH - CLOCK_WIDTH - 8)
CLOCK_Y             equ (TASKBAR_Y + 10)

; --- Keyboard ---
KB_BUFFER_SIZE      equ 64

; --- Mouse ---
MOUSE_BUFFER_SIZE   equ 64
CURSOR_WIDTH        equ 12
CURSOR_HEIGHT       equ 19

; --- PIT ---
PIT_FREQUENCY       equ 100          ; 100Hz = 10ms per tick
PIT_DIVISOR         equ 11932        ; 1193182 / 100

; --- PIC vectors ---
IRQ_BASE_MASTER     equ 32
IRQ_BASE_SLAVE      equ 40
IRQ_TIMER           equ 32           ; IRQ0 -> vector 32
IRQ_KEYBOARD        equ 33           ; IRQ1 -> vector 33
IRQ_CASCADE         equ 34           ; IRQ2 -> vector 34
IRQ_MOUSE           equ 44           ; IRQ12 -> vector 44

; --- Font ---
FONT_WIDTH          equ 8
FONT_HEIGHT         equ 16
FONT_FIRST_CHAR     equ 32           ; Space
FONT_LAST_CHAR      equ 126          ; Tilde
FONT_NUM_CHARS      equ 95           ; 126 - 32 + 1

; --- Window flags ---
WF_VISIBLE          equ 0x01
WF_FOCUSED          equ 0x02
WF_DRAGGING         equ 0x04
WF_MINIMIZED        equ 0x08
WF_ACTIVE           equ 0x10         ; Slot is in use

; --- Mouse event types ---
MEVT_MOVE           equ 1
MEVT_LCLICK         equ 2
MEVT_RCLICK         equ 3
MEVT_LRELEASE       equ 4
MEVT_RRELEASE       equ 5

; --- Key modifier flags ---
KMOD_SHIFT          equ 0x01
KMOD_CTRL           equ 0x02
KMOD_ALT            equ 0x04

; --- Virtual Key Codes (ASCII byte in kb_buffer for non-printable keys) ---
KEY_F1              equ 0xF1
KEY_F2              equ 0xF2
KEY_F3              equ 0xF3
KEY_F4              equ 0xF4
KEY_F5              equ 0xF5
KEY_F6              equ 0xF6
KEY_F7              equ 0xF7
KEY_F8              equ 0xF8
KEY_F9              equ 0xF9
KEY_F10             equ 0xFA
KEY_F11             equ 0xFB
KEY_F12             equ 0xFC

; --- USB/XHCI Memory Layout ---
XHCI_DCBAA_ADDR     equ 0x900000     ; Device Context Base Address Array
XHCI_CMD_RING_ADDR  equ 0x910000     ; Command Ring (4096 TRBs)
XHCI_ERST_ADDR      equ 0x920000     ; Event Ring Segment Table
XHCI_EVT_RING_ADDR  equ 0x930000     ; Event Ring (4096 TRBs)
XHCI_SCRATCH_ADDR   equ 0x940000     ; Scratchpad array + buffers
XHCI_DEV_CTX_ADDR   equ 0x950000     ; Output Device Context (slot 1)
XHCI_INPUT_CTX_ADDR equ 0x960000     ; Input Context
XHCI_CTRL_RING_ADDR equ 0x970000     ; Control EP0 Transfer Ring
XHCI_INT_RING_ADDR  equ 0x980000     ; Interrupt IN Transfer Ring
XHCI_CTRL_BUF_ADDR  equ 0x990000     ; Control transfer data buffers
XHCI_MOUSE_BUF_ADDR equ 0x9A0000     ; Mouse interrupt data buffers (slot 1)
; Slot 2 device support
XHCI_DEV_CTX2_ADDR  equ 0x9B0000     ; Output Device Context (slot 2)
XHCI_INT_RING2_ADDR equ 0x9C0000     ; Interrupt IN Transfer Ring (slot 2)
XHCI_MOUSE_BUF2_ADDR equ 0x9D0000   ; Mouse interrupt data buffers (slot 2)
XHCI_CTRL_RING2_ADDR equ 0x9E0000   ; Control EP0 Transfer Ring (slot 2)
XHCI_MEM_END        equ 0x9F0000     ; End of XHCI memory region

; --- XHCI Capability Register Offsets (from MMIO base) ---
XHCI_CAP_CAPLENGTH  equ 0x00
XHCI_CAP_HCSPARAMS1 equ 0x04
XHCI_CAP_HCSPARAMS2 equ 0x08
XHCI_CAP_HCCPARAMS1 equ 0x10
XHCI_CAP_DBOFF      equ 0x14
XHCI_CAP_RTSOFF     equ 0x18

; --- XHCI Operational Register Offsets (from OpBase) ---
XHCI_OP_USBCMD      equ 0x00
XHCI_OP_USBSTS      equ 0x04
XHCI_OP_PAGESIZE     equ 0x08
XHCI_OP_DNCTRL      equ 0x14
XHCI_OP_CRCR_LO     equ 0x18
XHCI_OP_CRCR_HI     equ 0x1C
XHCI_OP_DCBAAP_LO   equ 0x30
XHCI_OP_DCBAAP_HI   equ 0x34
XHCI_OP_CONFIG      equ 0x38

; --- XHCI Port Register Offsets (from OpBase + 0x400) ---
XHCI_PORTSC         equ 0x00
XHCI_PORT_REG_SIZE  equ 0x10         ; 16 bytes per port

; --- XHCI Runtime Register Offsets (from RtBase) ---
XHCI_RT_IR0_IMAN    equ 0x20
XHCI_RT_IR0_IMOD    equ 0x24
XHCI_RT_IR0_ERSTSZ  equ 0x28
XHCI_RT_IR0_ERSTBA_LO equ 0x30
XHCI_RT_IR0_ERSTBA_HI equ 0x34
XHCI_RT_IR0_ERDP_LO equ 0x38
XHCI_RT_IR0_ERDP_HI equ 0x3C

; --- USBCMD bits ---
XHCI_CMD_RS         equ (1 << 0)     ; Run/Stop
XHCI_CMD_HCRST      equ (1 << 1)     ; Host Controller Reset
XHCI_CMD_INTE       equ (1 << 2)     ; Interrupter Enable

; --- USBSTS bits ---
XHCI_STS_HCH        equ (1 << 0)     ; HC Halted
XHCI_STS_CNR        equ (1 << 11)    ; Controller Not Ready

; --- PORTSC bits ---
XHCI_PORTSC_CCS     equ (1 << 0)     ; Current Connect Status
XHCI_PORTSC_PED     equ (1 << 1)     ; Port Enabled/Disabled
XHCI_PORTSC_PR      equ (1 << 4)     ; Port Reset
XHCI_PORTSC_PLS_SHIFT equ 5          ; Port Link State shift
XHCI_PORTSC_PP      equ (1 << 9)     ; Port Power
XHCI_PORTSC_SPEED_SHIFT equ 10       ; Port Speed shift
XHCI_PORTSC_CSC     equ (1 << 17)    ; Connect Status Change
XHCI_PORTSC_PRC     equ (1 << 21)    ; Port Reset Change
; Bits that are RW1CS (write 1 to clear) - must preserve when writing other bits
XHCI_PORTSC_CHANGE_BITS equ ((1<<17)|(1<<18)|(1<<20)|(1<<21)|(1<<22)|(1<<23))

; --- TRB Types (shifted into bits 15:10 of dword 3) ---
TRB_NORMAL           equ (1 << 10)
TRB_SETUP            equ (2 << 10)
TRB_DATA             equ (3 << 10)
TRB_STATUS           equ (4 << 10)
TRB_LINK             equ (6 << 10)
TRB_ENABLE_SLOT      equ (9 << 10)
TRB_ADDRESS_DEV      equ (11 << 10)
TRB_CONFIG_EP        equ (12 << 10)
TRB_EVAL_CTX         equ (13 << 10)
TRB_TRANSFER_EVT     equ (32 << 10)
TRB_CMD_COMPLETION   equ (33 << 10)
TRB_PORT_STATUS_CHG  equ (34 << 10)

; --- TRB Flag Bits (dword 3) ---
TRB_CYCLE            equ (1 << 0)     ; Cycle bit
TRB_TC               equ (1 << 1)     ; Toggle Cycle (Link TRB)
TRB_IOC              equ (1 << 5)     ; Interrupt On Completion
TRB_IDT              equ (1 << 6)     ; Immediate Data
TRB_BSR              equ (1 << 9)     ; Block Set Address Request

; --- TRB Setup stage Transfer Type (bits 17:16 of dword 3) ---
TRB_TRT_NO_DATA      equ (0 << 16)
TRB_TRT_OUT          equ (2 << 16)
TRB_TRT_IN           equ (3 << 16)

; --- TRB Data stage Direction (bit 16 of dword 3) ---
TRB_DIR_OUT          equ (0 << 16)
TRB_DIR_IN           equ (1 << 16)

; --- Ring sizes ---
XHCI_RING_SIZE       equ 4096         ; TRBs per ring (64KB)
XHCI_TRB_SIZE        equ 16           ; Bytes per TRB

; --- USB Standard Request Codes ---
USB_REQ_GET_DESC     equ 0x06
USB_REQ_SET_CONFIG   equ 0x09
USB_REQ_SET_IFACE    equ 0x0B

; --- USB HID Request Codes ---
USB_HID_SET_PROTOCOL equ 0x0B

; --- USB Descriptor Types ---
USB_DESC_DEVICE      equ 0x01
USB_DESC_CONFIG      equ 0x02
USB_DESC_INTERFACE   equ 0x04
USB_DESC_ENDPOINT    equ 0x05
USB_DESC_HID         equ 0x21

; --- USB Endpoint Types ---
USB_EP_CONTROL       equ 0
USB_EP_ISOCH         equ 1
USB_EP_BULK          equ 2
USB_EP_INTERRUPT     equ 3

; --- XHCI Endpoint Types (for Endpoint Context) ---
XHCI_EP_NOT_VALID    equ 0
XHCI_EP_ISOCH_OUT    equ 1
XHCI_EP_BULK_OUT     equ 2
XHCI_EP_INT_OUT      equ 3
XHCI_EP_CONTROL      equ 4
XHCI_EP_ISOCH_IN     equ 5
XHCI_EP_BULK_IN      equ 6
XHCI_EP_INT_IN       equ 7

; --- XHCI Port Speeds ---
XHCI_SPEED_FULL      equ 1
XHCI_SPEED_LOW       equ 2
XHCI_SPEED_HIGH      equ 3
XHCI_SPEED_SUPER     equ 4
