; ============================================================================
; Grit Diagnostic - UEFI Mouse Probe (BOOTX64.EFI)
; ----------------------------------------------------------------------------
; Goal: find a UEFI pointer protocol path that actually delivers mouse and
; touchpad movement on the Acer Nitro V16 AI (AMD Ryzen AI 9 HX / Strix Point /
; Radeon 890M). The current Grit kernel cannot drive xHCI input on that
; hardware. UEFI firmware drivers DO work (mouse + touchpad work in BIOS), so
; this probe stays inside UEFI Boot Services forever and tries every protocol
; UEFI exposes for pointer input.
;
; Methods attempted:
;   1. EFI_SIMPLE_POINTER_PROTOCOL  via LocateProtocol
;   2. EFI_SIMPLE_POINTER_PROTOCOL  via LocateHandleBuffer -> OpenProtocol
;      (some firmwares only attach SPP to specific device handles)
;   3. EFI_ABSOLUTE_POINTER_PROTOCOL via LocateProtocol  (touchscreen / touchpad)
;   4. EFI_ABSOLUTE_POINTER_PROTOCOL via LocateHandleBuffer enumeration
;
; Display: GOP framebuffer cleared to black. A square at the cursor position
; moves whenever any pointer source reports motion. A row of coloured dots
; along the top indicates which probe paths succeeded:
;     red   = SPP via LocateProtocol         (slot 0)
;     orange= SPP via handle enumeration     (slot 1)
;     green = Absolute Pointer LocateProtocol(slot 2)
;     cyan  = Absolute Pointer handle enum   (slot 3)
;   dim grey if not found, bright if found, blink if GetState returns "ready".
;
; Serial trace on COM1 (0x3F8) for each step for headless diagnosis.
; ============================================================================
bits 64
default rel

%define HDR_SZ       0x200
%define TEXT_RAW     0x10000
%define TEXT_VA      0x1000
%define RELOC_FOFF   (HDR_SZ + TEXT_RAW)
%define RELOC_FSZ    0x200
%define RELOC_VA     0x11000
%define RELOC_VSZ    0x0C
%define IMAGE_SZ     0x12000
%define IMAGE_BASE   0x400000

; UEFI table offsets
%define ST_CONOUT    64
%define ST_BOOTSVC   96
%define BS_LOCHNDL   312
%define BS_LOCATE    320
%define BS_HNDLPROT  152
%define BS_OPENPROT  280
%define BS_WATCHDOG  256
%define BS_STALL     248
%define BS_CHECKEVT  120
%define BS_CONNECT   264
%define BS_DISCONN   272
%define BS_CLOSEPROT 288

; GOP
%define GOP_QUERY    0
%define GOP_SET      8
%define GOP_MODE     24
%define GOPM_MAX     0
%define GOPM_CUR     4
%define GOPM_FBBASE  24
%define GOPI_HRES    4
%define GOPI_VRES    8
%define GOPI_PPSL    32

; Simple Pointer Protocol vtable offsets
%define SPP_RESET    0
%define SPP_GETSTATE 8
%define SPP_WAITKEY  16
%define SPP_MODE     24

; Absolute Pointer Protocol vtable offsets
%define APP_RESET    0
%define APP_GETSTATE 8
%define APP_WAITKEY  16
%define APP_MODE     24

; ConOut (EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL)
%define CO_RESET     0
%define CO_OUTPUT    8
%define CO_SETATTR   40
%define CO_CLEAR     48
%define CO_SETCURPOS 56
%define CO_ENABLECUR 64

; ============================================================================
; NAMED CONSTANTS (replacing bare 5+ hex-digit "magic" literals)
; Values copied verbatim from their original literals. Do not alter a digit.
; ----------------------------------------------------------------------------
; PE/COFF header fields
PE_SIGNATURE          equ 0x00004550   ; "PE\0\0" optional-header signature
SECCHAR_TEXT          equ 0xE0000060   ; .text  flags: CODE|EXEC|READ (+MEM_...)
SECCHAR_RELOC         equ 0x42000040   ; .reloc flags: INITDATA|DISCARDABLE|READ

; --- BGRA pixel colors (0x00RRGGBB / GOP BltPixel layout) ---
COLOR_TEST_RECT_GREEN equ 0x0000FF00   ; T07 test-rect green (line 320)
COLOR_BG_DARK_SLATE   equ 0x00000810   ; very dark blue-grey screen clear
COLOR_CURSOR_MAGENTA  equ 0x00FF00FF   ; bright magenta cursor / async bar
COLOR_BG_UEFI_BLUE    equ 0x000000A8   ; UEFI EFI_BACKGROUND_BLUE (BGRA) erase
COLOR_DARK_RED        equ 0x00800000   ; slot0 idle (dark red)
COLOR_BRIGHT_RED      equ 0x00FF0000   ; slot0 active (bright red)
COLOR_DIM_GREY        equ 0x00303030   ; status slot "not found" dim grey
COLOR_DARK_ORANGE     equ 0x00803000   ; slot1 idle (dark orange)
COLOR_BRIGHT_ORANGE   equ 0x00FF8000   ; slot1 active (bright orange)
COLOR_DARK_GREEN      equ 0x00006000   ; slot2 idle (dark green)
COLOR_BRIGHT_GREEN    equ 0x0000FF00   ; slot2 active (bright green)
COLOR_DARK_CYAN       equ 0x00006080   ; slot3 idle (dark cyan)
COLOR_BRIGHT_CYAN     equ 0x0000FFFF   ; slot3 active / cb indicator (bright cyan)
COLOR_DARK_YELLOW     equ 0x00606000   ; slot4 idle (dark yellow)
COLOR_YELLOW          equ 0x00FFFF00   ; slot4 active / HITS bar (yellow)
COLOR_PANEL_BG        equ 0x00080808   ; usb panel clear strip (near-black)
COLOR_RC_GREEN        equ 0x0000C000   ; RC square pass (green)
COLOR_RC_RED          equ 0x00C00000   ; RC square fail (red)
COLOR_WHITE           equ 0x00FFFFFF   ; byte-bar b0 / report white
COLOR_BAR_RED         equ 0x00FF4040   ; byte-bar b1 (red)
COLOR_BAR_GREEN       equ 0x0040FF40   ; byte-bar b2 (green)
COLOR_BAR_CYAN        equ 0x0040FFFF   ; byte-bar b3 (cyan)
COLOR_CB_DARK_GREY    equ 0x00202020   ; async cb indicator dark grey (never fired)
COLOR_BLACK           equ 0x00000000   ; dead-code report-bar background (black)

; --- EFI GUID data1 (first 32-bit field of each protocol GUID) ---
EFI_GOP_GUID_D1       equ 0x9042a9de   ; EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID data1
EFI_SPP_GUID_D1       equ 0x31878c87   ; EFI_SIMPLE_POINTER_PROTOCOL_GUID data1
EFI_APP_GUID_D1       equ 0x8d59d32b   ; EFI_ABSOLUTE_POINTER_PROTOCOL_GUID data1
EFI_USBIO_GUID_D1     equ 0x2b2f68d6   ; EFI_USB_IO_PROTOCOL_GUID data1
; ============================================================================

; --- Serial helpers ---
%macro SER 1
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, %1
    out dx, al
    pop rdx
    pop rax
%endmacro

%macro SDBG 1
    push rax
    push rdx
    mov dx, 0x3F8
    %strlen %%n %1
    %assign %%i 1
    %rep %%n
      %substr %%c %1 %%i
      mov al, %%c
      out dx, al
      %assign %%i %%i+1
    %endrep
    mov al, 13
    out dx, al
    mov al, 10
    out dx, al
    pop rdx
    pop rax
%endmacro

; --- UCS-2 string macro ---
%macro ustr 1+
  %assign %%i 1
  %strlen %%n %1
  %rep %%n
    %substr %%c %1 %%i
    dw %%c
    %assign %%i %%i+1
  %endrep
  dw 0
%endmacro

; --- On-screen step tracer.  Emits an inline UCS-2 string, jumps over it,
; prints it via ConOut and stalls so each step is readable one-at-a-time. ---
%macro TRACE 1
    push rsi
    jmp %%skip
  %%tstr:
    ustr %1
  %%skip:
    lea rsi, [%%tstr]
    call trace_step
    pop rsi
%endmacro

; --- TRACE only during the first few frames (v_frame < 3) ---
%macro TRACEF 1
    cmp dword [v_frame], 3
    jae %%done
    TRACE %1
  %%done:
%endmacro

; ============================================================================
; PE/COFF HEADER
; ============================================================================
%include "src/diag/uefi_mouse_probe_boot.inc"
%include "src/diag/uefi_mouse_probe_pointers.inc"
%include "src/diag/uefi_mouse_probe_panels.inc"
%include "src/diag/uefi_mouse_probe_usb.inc"
%include "src/diag/uefi_mouse_probe_data.inc"
