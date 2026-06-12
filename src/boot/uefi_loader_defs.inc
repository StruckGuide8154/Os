; ============================================================================
; GritOS v3.0 - UEFI Bootloader (BOOTX64.EFI)
; Loads KERNEL.BIN from EFI partition, sets up GOP/paging, jumps to kernel.
; ============================================================================
bits 64
default rel

%include "src/include/boot_memory.inc"
; UEFI / PE-COFF / FAT32 ABI constants (offsets, PE header magics, GOP/SFS/file
; member offsets, FAT32 layout, KASLR PRNG) - named + spec-cited in the header,
; referenced throughout the loader (maintainability-todo.md §4.2).
%include "src/include/uefi_abi.inc"

; --- PE image layout (loader-specific geometry; the ABI magics live in
;     uefi_abi.inc). These sizes are derived from the FileAlignment-padded
;     section sizes of this exact two-section image, not from the spec. ---
%define HDR_SZ       0x200             ; raw header size (one 512 B block)
%define TEXT_RAW     0x10000           ; .text raw/virtual size (64 KiB)
%define TEXT_VA      0x1000            ; .text RVA (one 4 KiB page in)
%define RELOC_FOFF   (HDR_SZ + TEXT_RAW)
%define RELOC_FSZ    0x200
%define RELOC_VA     0x11000           ; .reloc RVA (TEXT_VA + TEXT_RAW)
%define RELOC_VSZ    0x0C
%define IMAGE_SZ     0x12000           ; SizeOfImage (RELOC_VA + one page)

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
