; ============================================================================
; Grit Diagnostic - UEFI GPU Probe (BOOTX64.EFI)
; ----------------------------------------------------------------------------
; First real-silicon checkpoint for the general AMD GPU driver work
; (docs/gpu-driver/TODO.md). Runs standalone in UEFI Boot Services (no FAT16,
; no kernel, no desktop) inside a Hyper-V DDA-assigned VM with the real
; AMD Radeon 780M (VEN_1002/DEV_1900) passed through.
;
; What it proves, read-only:
;   1. EFI_PCI_IO_PROTOCOL enumeration finds the passed-through 780M at all
;      (confirms DDA delivered a live, config-space-readable PCI function).
;   2. Pci.Read confirms VendorID/DeviceID match.
;   3. Mem.Read against BAR0 (via PciIo, no manual BAR mapping) returns
;      non-garbage dwords - confirms the MMIO BAR is actually reachable.
;   4. The verified SMN indirect-access sequence from
;      docs/gpu-driver/reference-780M-asm/code/drivers/gpu/amd_smn.asm
;      (BAR0+0x38 INDEX2 / BAR0+0x3C DATA2) round-trips on real silicon.
;
; This intentionally does NOT touch PSP/GMC/CP-ring (write paths) - those are
; a separate, incremental phase once this read path is confirmed working.
;
; Serial trace on COM1 (0x3F8), mirrored on-screen via ConOut so a VMConnect
; screenshot is enough to read results without a serial capture pipe.
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
%define ST_RUNTSVC   88
%define ST_BOOTSVC   96
%define BS_LOCHNDL   312
%define BS_OPENPROT  280
%define BS_HNDLPROT  152
%define BS_WATCHDOG  256
%define BS_STALL     248
%define RT_RESET     104

; EFI_LOADED_IMAGE_PROTOCOL
%define LI_DEVHANDLE 24

; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
%define SFS_OPENVOL  8

; EFI_FILE_PROTOCOL
%define FILE_OPEN    8
%define FILE_CLOSE   16
%define FILE_READ    32
%define FILE_WRITE   40
%define FILE_FLUSH   80

; ConOut (EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL)
%define CO_RESET     0
%define CO_OUTPUT    8
%define CO_SETATTR   40
%define CO_CLEAR     48

; EFI_PCI_IO_PROTOCOL vtable offsets (see UEFI spec 14.4)
%define PCIIO_MEM_READ   16
%define PCIIO_MEM_WRITE  24
%define PCIIO_PCI_READ   48
%define PCIIO_PCI_WRITE  56

%define WIDTH_UINT32 2

PE_SIGNATURE   equ 0x00004550
SECCHAR_TEXT   equ 0xE0000060
SECCHAR_RELOC  equ 0x42000040

; EFI_PCI_IO_PROTOCOL_GUID  4CF5B200-68B8-4CA5-9EEC-B23E3F50029A
EFI_PCIIO_GUID_D1 equ 0x4CF5B200
; EFI_LOADED_IMAGE_PROTOCOL_GUID  5B1B31A1-9562-11d2-8E3F-00A0C969723B
EFI_LOADEDIMG_GUID_D1 equ 0x5B1B31A1
; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID  964E5B22-6459-11D2-8E39-00A0C969723B
EFI_SFS_GUID_D1 equ 0x964E5B22

; --- ASCII log-buffer append helpers (for the on-disk result file) ---
%macro LOGS 1
    push rsi
    jmp %%skip
  %%lstr: db %1, 0
  %%skip:
    lea rsi, [%%lstr]
    call log_append_str
    pop rsi
%endmacro

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

; ============================================================================
; PE/COFF HEADER
; ============================================================================
section .text start=0
    dw 0x5A4D
    times 29 dw 0
    dd pe_hdr

pe_hdr:
    dd PE_SIGNATURE
    dw 0x8664
    dw 2
    dd 0, 0, 0
    dw opt_end - opt_hdr
    dw 0x0206

opt_hdr:
    dw 0x020B
    db 1, 0
    dd TEXT_RAW, 0, 0, TEXT_VA, TEXT_VA
    dq IMAGE_BASE
    dd 0x1000, 0x200
    dw 0,0, 0,0, 0,0
    dd 0, IMAGE_SZ, HDR_SZ, 0
    dw 10, 0
    dq IMAGE_BASE, IMAGE_BASE, IMAGE_BASE, IMAGE_BASE
    dd 0, 6
    dd 0,0, 0,0, 0,0, 0,0, 0,0
    dd RELOC_VA, RELOC_VSZ
opt_end:

    db '.text',0,0,0
    dd TEXT_RAW, TEXT_VA, TEXT_RAW, HDR_SZ
    dd 0, 0
    dw 0, 0
    dd SECCHAR_TEXT

    db '.reloc',0,0
    dd RELOC_VSZ, RELOC_VA, RELOC_FSZ, RELOC_FOFF
    dd 0, 0
    dw 0, 0
    dd SECCHAR_RELOC

    times (HDR_SZ - ($ - $$)) db 0

; ============================================================================
; ENTRY  RCX=ImageHandle  RDX=SystemTable
; ============================================================================
_start:
    sub rsp, 40
    mov [v_handle], rcx
    mov [v_systab], rdx

    SER 'P'
    mov rax, [rdx + ST_BOOTSVC]
    mov [v_bs], rax
    mov rax, [rdx + ST_CONOUT]
    mov [v_conout], rax

    SDBG "gpu_probe: start"

    ; Disable watchdog so we don't get killed mid-probe
    mov rcx, [v_bs]
    mov rax, [rcx + BS_WATCHDOG]
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call rax

    mov rcx, [v_conout]
    mov rax, [rcx + CO_RESET]
    mov rcx, [v_conout]
    xor edx, edx
    call rax
    mov rcx, [v_conout]
    mov rax, [rcx + CO_SETATTR]
    mov rcx, [v_conout]
    mov edx, 0x1F
    call rax
    mov rcx, [v_conout]
    mov rax, [rcx + CO_CLEAR]
    mov rcx, [v_conout]
    call rax

    lea rsi, [s_banner]
    call ucs_print
    call ucs_newline
    LOGS "Grit GPU Probe - AMD 780M passthrough recon"
    call log_append_nl

    ; ------------------------------------------------------------------
    ; LocateHandleBuffer(ByProtocol, PciIoGuid, NULL, &count, &handles)
    ; ------------------------------------------------------------------
    SER 'L'
    mov qword [v_nhandles], 0
    mov qword [v_handles], 0

    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCHNDL]
    sub rsp, 48
    mov ecx, 2                                ; ByProtocol
    lea rdx, [guid_pciio]
    xor r8d, r8d
    lea r9, [v_nhandles]
    lea r10, [v_handles]
    mov [rsp+32], r10                         ; 5th param (stack): &Buffer
    call rax
    add rsp, 48
    test rax, rax
    jnz .no_pci

    lea rsi, [s_pci_count]
    call ucs_print
    mov edi, [v_nhandles]
    call ucs_print_uint
    call ucs_newline
    LOGS "PciIo handles found: "
    mov edi, [v_nhandles]
    call log_append_uint32
    call log_append_nl

    mov r12, [v_nhandles]
    mov r13, [v_handles]
    test r12, r12
    jz .no_pci

    ; ------------------------------------------------------------------
    ; Walk handles, OpenProtocol(PciIo), Pci.Read config dword 0
    ; (VendorID low16 | DeviceID high16), match 0x19001002 (AMD 780M).
    ; ------------------------------------------------------------------
.scan_loop:
    test r12, r12
    jz .not_found

    mov rcx, [r13]
    mov rdx, [v_bs]
    mov rax, [rdx + BS_OPENPROT]
    lea rdx, [guid_pciio]
    lea r8, [v_pciio]
    mov r9, [v_handle]
    sub rsp, 48
    mov qword [rsp+32], 0
    mov qword [rsp+40], 2                     ; EFI_OPEN_PROTOCOL_GET_PROTOCOL
    call rax
    add rsp, 48
    test rax, rax
    jnz .scan_next

    ; Pci.Read(This, Uint32, Offset=0, Count=1, &v_vendev)
    ; Config-space accessor: (This, Width, Offset, Count, Buffer) - 5 params,
    ; no BarIndex. RCX,RDX,R8,R9 = This,Width,Offset,Count; Buffer on stack.
    mov rbx, [v_pciio]
    mov rcx, rbx
    mov edx, WIDTH_UINT32
    xor r8d, r8d                              ; Offset = 0 (VendorID/DeviceID)
    mov r9, 1                                 ; Count = 1
    mov rax, [rbx + PCIIO_PCI_READ]
    sub rsp, 48
    lea r10, [v_vendev]
    mov [rsp+32], r10                         ; 5th param (stack): Buffer
    call rax
    add rsp, 48
    test rax, rax
    jnz .scan_next

    mov eax, [v_vendev]
    cmp eax, 0x19001002                       ; DeviceID<<16 | VendorID
    je .found

.scan_next:
    add r13, 8
    dec r12
    jmp .scan_loop

.found:
    SER 'F'
    mov byte [v_found], 1
    lea rsi, [s_found]
    call ucs_print
    mov edi, [v_vendev]
    call ucs_print_hex32
    call ucs_newline
    LOGS "MATCH 780M (VEN1002/DEV1900), vendev="
    mov edi, [v_vendev]
    call log_append_hex32
    call log_append_nl

    ; ------------------------------------------------------------------
    ; Mem.Read BAR0 dwords 0..3 (first 16 bytes) - confirms BAR0 is
    ; actually mapped and readable through the passthrough path.
    ; ------------------------------------------------------------------
    mov dword [v_bar_idx], 0
.bar_dump:
    mov eax, [v_bar_idx]
    cmp eax, 4
    jae .bar_done
    mov rbx, [v_pciio]
    mov rcx, rbx
    mov edx, WIDTH_UINT32
    mov r8, 0                                 ; BarIndex 0
    mov r9, rax
    imul r9, 4                                ; Offset = dword index * 4
    mov rax, [rbx + PCIIO_MEM_READ]
    sub rsp, 48
    mov qword [rsp+32], 1
    lea r10, [v_scratch]
    mov [rsp+40], r10
    call rax
    add rsp, 48

    lea rsi, [s_bar_dw]
    call ucs_print
    mov edi, [v_bar_idx]
    call ucs_print_uint
    lea rsi, [s_eq]
    call ucs_print
    mov edi, [v_scratch]
    call ucs_print_hex32
    call ucs_newline
    LOGS "  BAR0 dw"
    mov edi, [v_bar_idx]
    call log_append_uint32
    LOGS " = "
    mov edi, [v_scratch]
    call log_append_hex32
    call log_append_nl

    inc dword [v_bar_idx]
    jmp .bar_dump
.bar_done:

    ; ------------------------------------------------------------------
    ; SMN proxy smoke-test: write32(BAR0+0x38, 0) ; read32(BAR0+0x3C)
    ; Verified sequence from amd_smn.asm (NBIO PCIE_INDEX2/DATA2).
    ; A non-zero, non-0xFFFFFFFF result confirms the indirect-access
    ; path works on real silicon through the passthrough BAR.
    ; ------------------------------------------------------------------
    SER 'M'
    mov rbx, [v_pciio]
    mov rcx, rbx
    mov edx, WIDTH_UINT32
    mov r8, 0
    mov r9, 0x38                              ; PCIE_INDEX2 byte offset
    mov rax, [rbx + PCIIO_MEM_WRITE]
    sub rsp, 48
    mov qword [rsp+32], 1
    mov dword [v_scratch], 0
    lea r10, [v_scratch]
    mov [rsp+40], r10
    call rax
    add rsp, 48

    mov rbx, [v_pciio]
    mov rcx, rbx
    mov edx, WIDTH_UINT32
    mov r8, 0
    mov r9, 0x3C                              ; PCIE_DATA2 byte offset
    mov rax, [rbx + PCIIO_MEM_READ]
    sub rsp, 48
    mov qword [rsp+32], 1
    lea r10, [v_scratch]
    mov [rsp+40], r10
    call rax
    add rsp, 48

    lea rsi, [s_smn]
    call ucs_print
    mov edi, [v_scratch]
    call ucs_print_hex32
    call ucs_newline
    LOGS "SMN proxy DATA2 readback = "
    mov edi, [v_scratch]
    call log_append_hex32
    call log_append_nl

    lea rsi, [s_done]
    call ucs_print
    call ucs_newline
    LOGS "PROBE COMPLETE - see values above"
    call log_append_nl
    jmp .write_and_reset

.not_found:
    SER 'x'
    lea rsi, [s_notfound]
    call ucs_print
    call ucs_newline
    LOGS "780M NOT found among PciIo handles (check DDA assignment)"
    call log_append_nl
    jmp .write_and_reset

.no_pci:
    SER 'X'
    lea rsi, [s_nopci]
    call ucs_print
    call ucs_newline
    LOGS "LocateHandleBuffer(PciIo) FAILED - no PCI protocol at all"
    call log_append_nl

; ============================================================================
; WRITE_AND_RESET - flush v_logbuf to \GPURESULT.LOG on the boot volume via
; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL, then ResetSystem(Cold) back to Windows.
; Falls through to the serial/screen hang loop if any step fails, so a
; failure is still visible instead of a silent stuck black screen.
; ============================================================================
.write_and_reset:
    SER 'W'
    ; HandleProtocol(ImageHandle, LoadedImageGUID, &v_loadedimg)
    mov rcx, [v_handle]
    mov rdx, [v_bs]
    mov rax, [rdx + BS_HNDLPROT]
    lea rdx, [guid_loadedimg]
    lea r8, [v_loadedimg]
    call rax
    test rax, rax
    jnz .hang

    ; OpenProtocol(LoadedImage->DeviceHandle, SFS_GUID, &v_sfs, ...)
    mov rbx, [v_loadedimg]
    mov rcx, [rbx + LI_DEVHANDLE]
    mov rdx, [v_bs]
    mov rax, [rdx + BS_OPENPROT]
    lea rdx, [guid_sfs]
    lea r8, [v_sfs]
    mov r9, [v_handle]
    sub rsp, 48
    mov qword [rsp+32], 0
    mov qword [rsp+40], 2                     ; GET_PROTOCOL
    call rax
    add rsp, 48
    test rax, rax
    jnz .hang

    ; OpenVolume(sfs, &v_root)
    mov rbx, [v_sfs]
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    test rax, rax
    jnz .hang

    ; Root->Open(Root, &v_file, L"\GPURESULT.LOG", CREATE|READ|WRITE, 0)
    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file]
    lea r8, [s_fname]
    mov r9, 0x8000000000000003                ; CREATE | READ | WRITE
    sub rsp, 48
    mov qword [rsp+32], 0                     ; Attributes
    call [rbx + FILE_OPEN]
    add rsp, 48
    test rax, rax
    jnz .hang

    ; File->Write(File, &writesize, v_logbuf)
    mov rax, [v_logpos]
    mov [v_writesz], rax
    mov rbx, [v_file]
    mov rcx, rbx
    lea rdx, [v_writesz]
    lea r8, [v_logbuf]
    call [rbx + FILE_WRITE]
    mov [v_writestatus], rax
    mov rax, [v_writesz]
    mov [v_writesz_after], rax

%ifdef DEBUG_NO_RESET
    SER 'S'
    mov edi, [v_writestatus]
    ; can't call ucs_print_hex32 easily here without conout state issues;
    ; just serial-dump nibbles.
    mov ecx, 28
.dbg_hx:
    mov eax, edi
    shr eax, cl
    and eax, 0xF
    cmp al, 10
    jb .dbg_dg
    add al, 'A' - 10
    jmp .dbg_pr
.dbg_dg:
    add al, '0'
.dbg_pr:
    push rax
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rax
    sub ecx, 4
    jns .dbg_hx
    SER ':'
    mov edi, [v_writesz_after]
    mov ecx, 28
.dbg_hx2:
    mov eax, edi
    shr eax, cl
    and eax, 0xF
    cmp al, 10
    jb .dbg_dg2
    add al, 'A' - 10
    jmp .dbg_pr2
.dbg_dg2:
    add al, '0'
.dbg_pr2:
    push rax
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rax
    sub ecx, 4
    jns .dbg_hx2
    SDBG " <- write status:size_after"
%endif

    mov rbx, [v_file]
    mov rcx, rbx
    call [rbx + FILE_FLUSH]
    mov [v_flushstatus], rax

    mov rbx, [v_file]
    mov rcx, rbx
    call [rbx + FILE_CLOSE]
    mov [v_closestatus], rax

%ifdef DEBUG_NO_RESET
    ; Same-session re-open verification: proves the create+write actually
    ; landed in OVMF's live filesystem state, independent of whether the
    ; host-side image file gets flushed before QEMU tears down.
    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file2]
    lea r8, [s_fname]
    mov r9, 1                                 ; READ only, no CREATE
    sub rsp, 48
    mov qword [rsp+32], 0
    call [rbx + FILE_OPEN]
    add rsp, 48
    mov [v_reopenstatus], rax

    test rax, rax
    jnz .reopen_failed

    mov rbx, [v_file2]
    mov rcx, rbx
    lea rdx, [v_readsz]
    mov qword [v_readsz], 32
    lea r8, [v_readbuf]
    call [rbx + FILE_READ]
    mov [v_readstatus], rax

    mov rbx, [v_file2]
    mov rcx, rbx
    call [rbx + FILE_CLOSE]

    SDBG "reopen: file exists in live FS state, read attempted"
    jmp .reopen_done
.reopen_failed:
    SDBG "reopen: FAILED - file does not exist even in live FS state"
.reopen_done:

    ; Give the block backend time to settle before we tear down.
    mov rcx, [v_bs]
    mov rax, [rcx + BS_STALL]
    mov ecx, 2000000                          ; 2 seconds
    call rax
%endif

    SER 'w'
    SDBG "gpu_probe: log written, resetting to Windows"

%ifdef DEBUG_NO_RESET
    jmp .hang
%endif

    ; RS->ResetSystem(EfiResetCold, EFI_SUCCESS, 0, NULL)
    mov rax, [v_systab]
    mov rax, [rax + ST_RUNTSVC]
    mov rcx, rax
    mov rax, [rcx + RT_RESET]
    xor ecx, ecx                              ; EfiResetCold = 0
    xor edx, edx                              ; EFI_SUCCESS = 0
    xor r8d, r8d
    xor r9d, r9d
    call rax
    ; ResetSystem does not return. If we're still here, something is wrong -
    ; fall through to the hang loop rather than looping a failed reset.

.hang:
    SDBG "gpu_probe: done, halting (spin)"
.hang_loop:
    mov rcx, [v_bs]
    mov rax, [rcx + BS_STALL]
    mov ecx, 500000
    call rax
    SER '.'
    jmp .hang_loop

; ============================================================================
; UCS-2 print helpers (ConOut->OutputString)
; ============================================================================
ucs_print:
    push rcx
    push rax
    mov rcx, [v_conout]
    mov rax, [rcx + CO_OUTPUT]
    mov rcx, [v_conout]
    mov rdx, rsi
    call rax
    pop rax
    pop rcx
    ret

ucs_newline:
    lea rsi, [s_crlf]
    call ucs_print
    ret

; print unsigned 32-bit decimal in edi
ucs_print_uint:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    lea rsi, [v_numbuf + 20]
    mov word [rsi], 0
    mov eax, edi
    mov ebx, 10
    test eax, eax
    jnz .loop
    sub rsi, 2
    mov word [rsi], '0'
    jmp .out
.loop:
    test eax, eax
    jz .out
    xor edx, edx
    div ebx
    add edx, '0'
    sub rsi, 2
    mov [rsi], dx
    jmp .loop
.out:
    push rsi
    pop rsi
    call ucs_print
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; print 32-bit hex in edi, prefixed 0x
ucs_print_hex32:
    push rax
    push rcx
    push rdx
    push rsi
    lea rsi, [s_0x]
    call ucs_print
    mov ecx, 28
.hx:
    mov eax, edi
    shr eax, cl
    and eax, 0xF
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .store
.digit:
    add al, '0'
.store:
    mov [v_hexch], al
    mov word [v_hexch+2], 0
    push rdi
    push rcx
    lea rsi, [v_hexch]
    call ucs_print
    pop rcx
    pop rdi
    sub ecx, 4
    jns .hx
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================================================
; ASCII log buffer helpers - append-only, backs the on-disk result file.
; ============================================================================
log_append_str:
    push rax
    push rdi
    mov rdi, [v_logpos]
.ls_loop:
    mov al, [rsi]
    test al, al
    jz .ls_done
    mov [v_logbuf + rdi], al
    inc rsi
    inc rdi
    cmp rdi, 4000
    jae .ls_done
    jmp .ls_loop
.ls_done:
    mov [v_logpos], rdi
    pop rdi
    pop rax
    ret

log_append_nl:
    push rsi
    lea rsi, [s_a_crlf]
    call log_append_str
    pop rsi
    ret

; append unsigned 32-bit decimal in edi
log_append_uint32:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [v_a_numbuf + 12]
    mov byte [rsi], 0
    mov eax, edi
    mov ebx, 10
    test eax, eax
    jnz .lu_loop
    dec rsi
    mov byte [rsi], '0'
    jmp .lu_out
.lu_loop:
    test eax, eax
    jz .lu_out
    xor edx, edx
    div ebx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    jmp .lu_loop
.lu_out:
    call log_append_str
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; append 32-bit hex in edi, prefixed 0x
log_append_hex32:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    LOGS "0x"
    mov ecx, 28
.lh_hx:
    mov eax, edi
    shr eax, cl
    and eax, 0xF
    cmp al, 10
    jb .lh_digit
    add al, 'A' - 10
    jmp .lh_store
.lh_digit:
    add al, '0'
.lh_store:
    mov [v_a_hexch], al
    mov byte [v_a_hexch+1], 0
    lea rsi, [v_a_hexch]
    call log_append_str
    sub ecx, 4
    jns .lh_hx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

section .data
align 4
v_handle:     dq 0
v_systab:     dq 0
v_bs:         dq 0
v_conout:     dq 0
v_nhandles:   dq 0
v_handles:    dq 0
v_pciio:      dq 0
v_vendev:     dd 0
v_found:      db 0
v_scratch:    dd 0
v_bar_idx:    dd 0
v_hexch:      dw 0, 0
v_numbuf:     times 24 db 0
v_a_hexch:    db 0, 0
v_a_numbuf:   times 16 db 0
v_logpos:     dq 0
v_loadedimg:  dq 0
v_sfs:        dq 0
v_root:       dq 0
v_file:       dq 0
v_writesz:    dq 0
v_writestatus: dq 0
v_writesz_after: dq 0
v_flushstatus: dq 0
v_closestatus: dq 0
v_file2:      dq 0
v_reopenstatus: dq 0
v_readstatus: dq 0
v_readsz:     dq 0
v_readbuf:    times 32 db 0
s_a_crlf:     db 13, 10, 0
v_logbuf:     times 4000 db 0

s_banner:    ustr "Grit GPU Probe - AMD 780M passthrough recon"
s_pci_count: ustr "PciIo handles found: "
s_found:     ustr "MATCH 780M (VEN1002/DEV1900), vendev="
s_notfound:  ustr "780M NOT found among PciIo handles (check DDA assignment)"
s_nopci:     ustr "LocateHandleBuffer(PciIo) FAILED - no PCI protocol at all"
s_bar_dw:    ustr "  BAR0 dw"
s_eq:        ustr " = "
s_smn:       ustr "SMN proxy DATA2 readback = "
s_done:      ustr "PROBE COMPLETE - see values above"
s_0x:        ustr "0x"
s_crlf:      dw 13, 10, 0

; EFI_PCI_IO_PROTOCOL_GUID  4CF5B200-68B8-4CA5-9EEC-B23E3F50029A
align 8
guid_pciio:
    dd EFI_PCIIO_GUID_D1
    dw 0x68b8, 0x4ca5
    db 0x9e, 0xec, 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a

; EFI_LOADED_IMAGE_PROTOCOL_GUID  5B1B31A1-9562-11d2-8E3F-00A0C969723B
guid_loadedimg:
    dd EFI_LOADEDIMG_GUID_D1
    dw 0x9562, 0x11d2
    db 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID  964E5B22-6459-11D2-8E39-00A0C969723B
guid_sfs:
    dd EFI_SFS_GUID_D1
    dw 0x6459, 0x11d2
    db 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

s_fname: dw '\','G','P','U','R','E','S','U','L','T','.','L','O','G',0

times (HDR_SZ + TEXT_RAW - ($ - $$)) db 0

; .reloc
    dd 0x1000, 12
    dw 0, 0

times (HDR_SZ + TEXT_RAW + RELOC_FSZ - ($ - $$)) db 0
