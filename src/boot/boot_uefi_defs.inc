; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI PE constants and macros
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

; ============================================================================
; NexusOS v2.0 - UEFI Graphical Operating System
; 100% x86-64 Assembly. No C. No Rust. No libraries.
; Features: GOP framebuffer, 8x8 bitmap font, graphical desktop + text shell
; ============================================================================
bits 64
default rel

%define HEADER_SIZE   0x200
%define TEXT_RAWSIZE  0x10000
%define TEXT_VADDR    0x1000
%define TEXT_VSIZE    0x10000
%define RELOC_FOFF    (HEADER_SIZE + TEXT_RAWSIZE)
%define RELOC_FSIZE   0x200
%define RELOC_VADDR   0x11000
%define RELOC_VSIZE   0x0C
%define IMAGE_SIZE    0x12000

; Colors (text mode)
%define LCYAN   0x0B
%define YELLOW  0x0E
%define WHITE   0x0F
%define LGRAY   0x07
%define LGREEN  0x0A
%define LRED    0x0C
%define LMAG    0x0D

; UEFI offsets
%define ST_CONIN    48
%define ST_CONOUT   64
%define ST_RUNTIME  88
%define ST_BOOTSERV 96
%define ST_FW_VEND  24
%define CO_STR  8
%define CO_ATTR 40
%define CO_CLR  48
%define CI_KEY  8
%define BS_WAITEVT  232
%define BS_STALL    248
%define BS_WATCHDOG 256
%define BS_CHKEVT   264
%define BS_LOCATE   320
%define RS_TIME     24
%define RS_RESET    104

; GOP offsets
%define GOP_QUERY   0
%define GOP_SET     8
%define GOP_BLT     16
%define GOP_MODE    24
; GOP Mode
%define GOPM_MAX    0
%define GOPM_CUR    4
%define GOPM_INFO   8
%define GOPM_FBBASE 24
%define GOPM_FBSIZE 32
; GOP Mode Info
%define GOPI_HRES   4
%define GOPI_VRES   8
%define GOPI_PFMT   12
%define GOPI_PPSL   28

; UCS-2 macro
%macro u 1+
  %assign %%i 1
  %strlen %%len %1
  %rep %%len
    %substr %%c %1 %%i
    dw %%c
    %assign %%i %%i+1
  %endrep
  dw 0
%endmacro

; ============================================================================
; PE/COFF HEADER
