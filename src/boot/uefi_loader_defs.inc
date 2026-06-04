; ============================================================================
; NexusOS v3.0 - UEFI Bootloader (BOOTX64.EFI)
; Loads KERNEL.BIN from EFI partition, sets up GOP/paging, jumps to kernel.
; ============================================================================
bits 64
default rel

%include "src/include/boot_memory.inc"

; --- PE image layout ---
%define HDR_SZ       0x200
%define TEXT_RAW     0x10000
%define TEXT_VA      0x1000
%define RELOC_FOFF   (HDR_SZ + TEXT_RAW)
%define RELOC_FSZ    0x200
%define RELOC_VA     0x11000
%define RELOC_VSZ    0x0C
%define IMAGE_SZ     0x12000

; --- UEFI System Table offsets ---
%define ST_BOOTSVC   96

; --- Boot Services offsets ---
%define BS_ALLOCPG   40
%define BS_GETMMAP   56
%define BS_ALLOCPL   64
%define BS_HNDLPROT  152
%define BS_OPENPROT  280
%define BS_LOCHNDL   312
%define BS_LOCATE    320
%define BS_EXITBOOT  232
%define BS_WATCHDOG  256

; --- GOP offsets ---
%define GOP_QUERY    0
%define GOP_SET      8
%define GOP_MODE     24
%define GOPM_MAX     0
%define GOPM_CUR     4
%define GOPM_FBBASE  24
%define GOPI_HRES    4
%define GOPI_VRES    8
%define GOPI_PPSL    32

; --- Simple Filesystem / File offsets ---
%define SFS_OPENVOL  8
%define FP_OPEN      8
%define FP_CLOSE     16
%define FP_READ      32
%define FP_WRITE     40

; --- Physical memory aliases ---
%define VBE_INFO     VBE_INFO_ADDR
%define PT_BASE      PAGE_TABLE_ADDR
%define KERN_DEST    KERNEL_LOAD_ADDR
%define KERN_STACK   KERNEL_STACK_TOP
%define APPS_MAX_SZ  APPS_BLOB_MAX_SIZE

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

; --- Serial macros (COM1 = 0x3F8, clobber nothing) ---

%macro SER 1
%ifndef RELEASE_BUILD
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, %1
    out dx, al
    pop rdx
    pop rax
%endif
%endmacro

%macro SDBG 1
%ifndef RELEASE_BUILD
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
%endif
%endmacro

%macro SREG 2
%ifndef RELEASE_BUILD
  push rbx
  push rax
  push rcx
  push rdx
  mov rbx, %2
  mov dx, 0x3F8
  %strlen %%n %1
  %assign %%i 1
  %rep %%n
    %substr %%c %1 %%i
    mov al, %%c
    out dx, al
    %assign %%i %%i+1
  %endrep
  mov al, '='
  out dx, al
  mov ecx, 16
%%hl:
  rol rbx, 4
  mov al, bl
  and al, 0xF
  add al, '0'
  cmp al, '9'
  jle %%ok
  add al, 7
%%ok:
  out dx, al
  dec ecx
  jnz %%hl
  mov al, 13
  out dx, al
  mov al, 10
  out dx, al
  pop rdx
  pop rcx
  pop rax
  pop rbx
%endif
%endmacro
