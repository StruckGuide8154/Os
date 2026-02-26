; ============================================================================
; NexusOS v3.0 - UEFI Bootloader (BOOTX64.EFI)
; Loads KERNEL.BIN from EFI partition, sets up GOP/paging, jumps to kernel.
; ============================================================================
bits 64
default rel

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
%define ST_CONOUT    64
%define ST_BOOTSVC   96
%define CO_OUTSTR    8

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

; --- Physical memory map ---
%define VBE_INFO     0x9000
%define PT_BASE      0x70000
%define KERN_DEST    0x100000
%define KERN_STACK   0x200000

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

; SER char  - single character
%macro SER 1
  push rax
  push rdx
  mov dx, 0x3F8
  mov al, %1
  out dx, al
  pop rdx
  pop rax
%endmacro

; SDBG 'text'  - string + CRLF
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

; SREG 'tag', reg  - tag=hexvalue + CRLF
%macro SREG 2
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
%endmacro

; ============================================================================
; PE/COFF HEADER
; ============================================================================
section .text start=0
    dw 0x5A4D                       ; MZ
    times 29 dw 0
    dd pe_hdr

pe_hdr:
    dd 0x00004550                   ; "PE\0\0"
    dw 0x8664                       ; x86-64
    dw 2                            ; 2 sections
    dd 0, 0, 0
    dw opt_end - opt_hdr
    dw 0x0206

opt_hdr:
    dw 0x020B                       ; PE32+
    db 1, 0
    dd TEXT_RAW, 0, 0, TEXT_VA, TEXT_VA
    dq KERN_DEST                    ; Image base (preferred)
    dd 0x1000, 0x200                ; Section / file alignment
    dw 0,0, 0,0, 0,0
    dd 0, IMAGE_SZ, HDR_SZ, 0
    dw 10, 0                        ; Subsystem: EFI Application
    dq KERN_DEST, KERN_DEST, KERN_DEST, KERN_DEST
    dd 0, 6                         ; Data directory count
    dd 0,0, 0,0, 0,0, 0,0, 0,0
    dd RELOC_VA, RELOC_VSZ          ; Base reloc directory
opt_end:

    db '.text',0,0,0
    dd TEXT_RAW, TEXT_VA, TEXT_RAW, HDR_SZ
    dd 0, 0
    dw 0, 0
    dd 0xE0000060                   ; Code | Execute | Read | Write

    db '.reloc',0,0
    dd RELOC_VSZ, RELOC_VA, RELOC_FSZ, RELOC_FOFF
    dd 0, 0
    dw 0, 0
    dd 0x42000040                   ; Initialized data | Discardable | Read

    times (HDR_SZ - ($ - $$)) db 0

; ============================================================================
; ENTRY POINT
; RCX = ImageHandle   RDX = SystemTable
; ============================================================================
_start:
    ; Entry RSP = 16n-8.  sub 40 -> 16n-48 = 0 mod 16. Aligned for calls.
    sub rsp, 40
    mov [v_handle], rcx
    mov [v_systab], rdx

    mov rax, [rdx + ST_BOOTSVC]
    mov [v_bs], rax
    mov rax, [rdx + ST_CONOUT]
    mov [v_conout], rax



    ; Disable watchdog (4 args, all zero except handle)
    mov rcx, [v_bs]
    mov rax, [rcx + BS_WATCHDOG]
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call rax

    lea rdx, [s_banner]
    call print

    ; === S0: Claim fixed physical pages for kernel use ===
    SDBG 'S0-Claims'
    call claim_pages

    ; === S1: GOP graphics init ===
    SDBG 'S1-GOP'
    lea rdx, [s_gop]
    call print
    call gop_init
    test rax, rax
    jnz .gop_warn
    SREG 'GOP-FB', [v_fb]
    lea rdx, [s_ok]
    call print
    jmp .gop_done
.gop_warn:
    ; GOP unavailable - zero out VBE info and continue anyway
    SDBG 'GOP-SKIP'
    mov rdi, VBE_INFO
    xor eax, eax
    mov ecx, 24 / 4
    rep stosd
.gop_done:

    ; === S1.5: Locate EFI_SIMPLE_POINTER_PROTOCOL and save for kernel ===
    SDBG 'S1b-SPP'
    call locate_spp

    ; === S2: Load kernel from filesystem ===
    SDBG 'S2-Kernel'
    lea rdx, [s_kernel]
    call print
    call load_kernel
    test rax, rax
    jnz .fail_kernel
    mov rax, [v_ksize]
    SREG 'KERN-SZ', rax
    lea rdx, [s_ok]
    call print

    ; === S3: Build identity-mapped page tables ===
    SDBG 'S3-Paging'
    lea rdx, [s_paging]
    call print
    call setup_paging
    lea rdx, [s_ok]
    call print

    ; === S4: Exit boot services ===
    SDBG 'S4-ExitBS'
    lea rdx, [s_exit]
    call print
    call exit_boot_services
    test rax, rax
    jnz .fail_exit

    ; ================================================================
    ; POST-ExitBootServices: firmware is gone. Serial OUT only.
    ; ================================================================
    mov qword [v_conout], 0
    cli

    SER 'E'             ; E = ExitBootServices OK

    ; Fix CR4: clear LA57/PCIDE/SMEP/SMAP/PKE, enable PAE+SSE
    mov rax, cr4
    btr rax, 7          ; PGE   off
    btr rax, 12         ; LA57  off
    btr rax, 17         ; PCIDE off
    btr rax, 20         ; SMEP  off
    btr rax, 21         ; SMAP  off
    btr rax, 22         ; PKE   off
    bts rax, 5          ; PAE   on
    bts rax, 9          ; OSFXSR on
    bts rax, 10         ; OSXMMEXCPT on
    mov cr4, rax
    SER 'C'             ; C = CR4 fixed

    ; Fix EFER: set LME, clear NXE
    mov ecx, 0xC0000080
    rdmsr
    bts eax, 8          ; LME on
    btr eax, 11         ; NXE off
    wrmsr
    SER 'F'             ; F = EFER fixed

    ; Clear CR0.WP so we can write UEFI's read-only 0x100000
    mov rax, cr0
    btr rax, 16
    mov cr0, rax
    SER 'W'             ; W = WP cleared

    ; Copy GDT to 0x500 and trampoline to 0x8000 BEFORE anything
    ; else can corrupt the PE image we're still running from.
    cld
    lea rsi, [gdt64]
    mov rdi, 0x500
    mov rcx, gdt64_end - gdt64
    rep movsb

    lea rsi, [trampoline]
    mov rdi, 0x8000
    mov rcx, (trampoline_end - trampoline + 7) / 8
    rep movsq
    SER 'T'             ; T = GDT + trampoline copied

    ; Load GDT from 0x580 (fixed physical address)
    mov word  [0x580], gdt64_end - gdt64 - 1
    mov qword [0x582], 0x500
    lgdt [0x580]

    ; Far return to reload CS = 0x08
    lea rax, [.cs_reload]
    push qword 0x08
    push rax
    retfq

.cs_reload:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    SER 'G'             ; G = GDT + segments reloaded

    ; Switch to kernel stack
    mov rsp, KERN_STACK
    SER 'S'             ; S = stack set

    ; Set up trampoline args and jump (RSI=src, RDI=dest, RCX=size)
    mov rsi, [v_kernel_addr]
    mov rdi, KERN_DEST
    mov rcx, [v_ksize]
    SER 'J'             ; J = jumping to trampoline
    mov rax, 0x8000
    jmp rax

; --- Failure handlers ---
.fail_kernel:
    SREG 'FAIL-RSP', rsp
    lea rdx, [s_fail_kernel]
    jmp .do_fail
.fail_exit:
    SREG 'FAIL-RSP', rsp
    lea rdx, [s_fail_exit]
.do_fail:
    call print
.halt:
    cli
    hlt
    jmp .halt

; ============================================================================
; TRAMPOLINE  - copied to 0x8000, runs after ExitBootServices
; In:  RSI = kernel source address
;      RDI = KERN_DEST (0x100000)
;      RCX = byte count
; ============================================================================
align 16
trampoline:
    add rcx, 7
    shr rcx, 3              ; round up to qwords
    rep movsq
    wbinvd
    mov rax, KERN_DEST
    jmp rax
trampoline_end:

; ============================================================================
; PRINT  - ConOut->OutputString
; In: RDX = UCS-2 string pointer
; ============================================================================
print:
    ; Entry RSP=16n-8. push -> 16n-16. sub 32 -> 16n-48 = 0 mod 16.
    push rbx
    sub rsp, 32
    mov rbx, [v_conout]
    test rbx, rbx
    jz .skip
    mov rcx, rbx
    mov rax, [rbx + CO_OUTSTR]
    call rax
.skip:
    add rsp, 32
    pop rbx
    ret

; ============================================================================
; CLAIM_PAGES  - AllocateAddress for all fixed kernel memory regions
; Failures are tolerated (firmware may own 0x100000; trampoline handles it).
; ============================================================================
claim_pages:
    ; Entry RSP=16n-8. push -> 16n-16. sub 32 -> 16n-48 = 0 mod 16.
    push rbx
    sub rsp, 32

    %macro DO_CLAIM 2               ; addr, num_pages
      mov qword [v_tmp_addr], %1
      mov rcx, [v_bs]
      mov rax, [rcx + BS_ALLOCPG]
      mov ecx, 2                    ; AllocateAddress
      mov edx, 2                    ; EfiLoaderData
      mov r8, %2
      lea r9, [v_tmp_addr]
      call rax
      SREG 'CLM', rax
    %endmacro

    DO_CLAIM 0x9000,     1          ; VBE info block
    DO_CLAIM PT_BASE,    6          ; Page tables (2 pages needed, 6 claimed)
    DO_CLAIM 0x8000,     1          ; Trampoline
    ; NOTE: Do NOT claim KERN_DEST (0x100000) here — UEFI loaded our own
    ; PE image at ImageBase=0x100000.  Claiming it could corrupt memory
    ; protections on our code/data/stack while we're still executing.
    ; The trampoline copies the kernel there AFTER ExitBootServices.
    DO_CLAIM KERN_STACK, 16         ; Kernel stack + IDT space

    add rsp, 32
    pop rbx
    ret

; ============================================================================
; GOP_INIT  - find GOP, set best video mode (prefer 1024x768), fill VBE_INFO
; Returns: RAX = 0 success, 1 fail
; ============================================================================
gop_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; 5 pushes = 40 bytes. Entry 16n-8. After pushes: 16n-48.
    ; sub 80 -> 16n-128 = 0 mod 16. Aligned.
    sub rsp, 80
    ; [rsp +  0..31] shadow space
    ; [rsp + 32]     arg5 slot
    ; [rsp + 40]     arg6 slot
    ; [rsp + 48]     local: num_handles
    ; [rsp + 56]     local: handle_buffer ptr
    ; [rsp + 64]     local: info_size
    ; [rsp + 72]     local: info_ptr

    ; --- Try LocateProtocol(gop_guid, NULL, &v_gop) ---
    mov rax, [v_bs]
    mov rax, [rax + BS_LOCATE]
    lea rcx, [guid_gop]
    xor edx, edx
    lea r8, [v_gop]
    call rax
    SREG 'LOCATE', rax
    test rax, rax
    jz .found

    ; --- Fallback: LocateHandleBuffer + OpenProtocol ---
    SDBG 'GOP-HndBuf'
    mov qword [rsp+48], 0
    mov qword [rsp+56], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCHNDL]
    mov ecx, 2                      ; ByProtocol
    lea rdx, [guid_gop]
    xor r8d, r8d
    lea r9, [rsp+48]                ; &num_handles
    lea r10, [rsp+56]               ; &handle_buffer
    mov [rsp+32], r10               ; arg5
    call rax
    SREG 'LOCHNDL', rax
    test rax, rax
    jnz .fail

    cmp qword [rsp+48], 0
    je .fail

    ; OpenProtocol(handle[0], &guid, &v_gop, imghandle, NULL, GET_PROTOCOL=2)
    mov rsi, [rsp+56]
    mov rcx, [rsi]                  ; first handle
    mov rdx, [v_bs]
    mov rax, [rdx + BS_OPENPROT]
    lea rdx, [guid_gop]
    lea r8, [v_gop]
    mov r9, [v_handle]
    mov qword [rsp+32], 0           ; ControllerHandle
    mov qword [rsp+40], 2           ; Attributes: GET_PROTOCOL
    call rax
    SREG 'OPENPROT', rax
    test rax, rax
    jnz .fail

.found:
    mov rbx, [v_gop]
    SREG 'GOP-PTR', rbx
    test rbx, rbx
    jz .fail

    ; --- Iterate modes, find best match to 1024x768 ---
    mov rax, [rbx + GOP_MODE]
    mov r12d, [rax + GOPM_MAX]      ; max mode count
    SREG 'GOP-MAX', r12
    xor r13d, r13d                  ; current mode index
    mov r14d, 0xFFFFFFFF            ; best mode (none)
    mov r15d, 0x7FFFFFFF            ; best score (lower = closer to 1024x768)

.mode_loop:
    cmp r13d, r12d
    jge .select

    mov rcx, rbx
    mov edx, r13d
    lea r8, [rsp+64]
    lea r9, [rsp+72]
    mov rax, [rbx + GOP_QUERY]
    call rax
    test rax, rax
    jnz .next_mode

    mov rax, [rsp+72]
    test rax, rax
    jz .next_mode

    mov ecx, [rax + GOPI_HRES]
    mov edx, [rax + GOPI_VRES]

    ; Exact 1024x768 - pick immediately
    cmp ecx, 1024
    jne .score
    cmp edx, 768
    jne .score
    mov r14d, r13d
    jmp .select

.score:
    ; score = abs(w - 1024) + abs(h - 768)
    push rdx                        ; save height
    sub ecx, 1024
    mov eax, ecx
    cdq
    xor eax, edx
    sub eax, edx                    ; abs(w-1024)
    mov ecx, eax
    pop rdx
    sub edx, 768
    mov eax, edx
    cdq
    xor eax, edx
    sub eax, edx                    ; abs(h-768)
    add ecx, eax
    cmp ecx, r15d
    jae .next_mode
    mov r15d, ecx
    mov r14d, r13d

.next_mode:
    inc r13d
    jmp .mode_loop

.select:
    cmp r14d, 0xFFFFFFFF
    je .fail

    SREG 'GOP-SET', r14
    mov rcx, rbx
    mov edx, r14d
    mov rax, [rbx + GOP_SET]
    call rax
    SREG 'SET-RET', rax
    test rax, rax
    jnz .fail

    ; Get framebuffer base from MODE struct
    mov rax, [rbx + GOP_MODE]
    mov rcx, [rax + GOPM_FBBASE]
    mov [v_fb], rcx

    ; Re-query current mode for a fresh Info pointer (SetMode may invalidate old one)
    mov edx, [rax + GOPM_CUR]      ; current mode number
    mov rcx, rbx                    ; This = GOP
    lea r8, [rsp+64]
    lea r9, [rsp+72]
    mov rax, [rbx + GOP_QUERY]
    call rax

    mov rax, [rsp+72]               ; Info ptr
    test rax, rax
    jz .fallback

    mov ecx, [rax + GOPI_HRES]
    mov [v_scrw], ecx
    mov ecx, [rax + GOPI_VRES]
    mov [v_scrh], ecx
    mov ecx, [rax + GOPI_PPSL]
    mov [v_pitch], ecx
    jmp .fill_vbe

.fallback:
    mov dword [v_scrw],  1024
    mov dword [v_scrh],  768
    mov dword [v_pitch], 1024

.fill_vbe:
    ; Fill VBE info block at 0x9000:
    ;   [+0]  fb_addr   (qword)
    ;   [+8]  width     (dword)
    ;   [+12] height    (dword)
    ;   [+16] pitch_bytes (dword, pixels*4)
    ;   [+20] bpp       (dword)
    mov rdi, VBE_INFO
    mov rax, [v_fb]
    mov [rdi],    rax
    mov eax, [v_scrw]
    mov [rdi+8],  eax
    mov eax, [v_scrh]
    mov [rdi+12], eax
    mov eax, [v_pitch]
    shl eax, 2                      ; pixels/line -> bytes/line
    mov [rdi+16], eax
    mov dword [rdi+20], 32

    xor eax, eax
    jmp .done

.fail:
    SDBG 'GOP-FAIL'
    mov eax, 1

.done:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; LOAD_KERNEL  - open \EFI\BOOT\KERNEL.BIN via UEFI FS, read into RAM
; Uses LoadedImage protocol to get our boot device, then SFS from it.
; Returns: RAX = 0 success, 1 fail
; Writes:  v_kernel_addr, v_ksize
; ============================================================================
load_kernel:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; 5 pushes = 40 bytes. Entry 16n-8. After pushes: 16n-48.
    ; sub 96 -> 16n-144 = 0 mod 16. Aligned.
    sub rsp, 96
    ; [rsp +  0..31] shadow
    ; [rsp + 32]     arg5
    ; [rsp + 40]     arg6
    ; [rsp + 48]     local: scratch
    ; [rsp + 56]     local: scratch
    ; [rsp + 64]     local: read_size
    ; [rsp + 72..95] scratch

    ; --- Step 1: Get LoadedImage from our ImageHandle ---
    SDBG 'LK1-LIP'
    mov rcx, [v_bs]
    mov rax, [rcx + BS_HNDLPROT]    ; HandleProtocol
    mov rcx, [v_handle]              ; our ImageHandle
    lea rdx, [guid_lip]             ; LoadedImage GUID
    lea r8,  [v_lip]                ; &LoadedImage
    call rax
    test rax, rax
    jnz .fail

    ; --- Step 2: Get DeviceHandle from LoadedImage ---
    mov rax, [v_lip]
    mov rax, [rax + 24]             ; LIP->DeviceHandle (offset 24)
    mov [v_devhandle], rax
    SREG 'DEVH', rax
    test rax, rax
    jz .fail

    ; --- Step 3: Get SFS from DeviceHandle ---
    SDBG 'LK2-SFS'
    mov rcx, [v_bs]
    mov rax, [rcx + BS_HNDLPROT]    ; HandleProtocol
    mov rcx, [v_devhandle]           ; DeviceHandle
    lea rdx, [guid_sfs]             ; SFS GUID
    lea r8,  [v_sfs]                ; &SFS
    call rax
    SREG 'SFS-RET', rax
    test rax, rax
    jnz .fail

    ; --- Step 4: OpenVolume ---
    SDBG 'LK3-VOL'
    mov rbx, [v_sfs]
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    SREG 'VOL-RET', rax
    test rax, rax
    jnz .fail

    ; --- Step 5: Open \EFI\BOOT\KERNEL.BIN ---
    SDBG 'LK4-OPEN'
    mov rbx, [v_root]
    mov rcx, rbx                    ; This
    lea rdx, [v_file]               ; &NewHandle
    lea r8,  [s_kern_path]          ; FileName
    mov r9,  1                      ; EFI_FILE_MODE_READ
    mov qword [rsp+32], 0           ; Attributes
    mov rax, [rbx + FP_OPEN]
    call rax
    SREG 'OPEN-RET', rax
    test rax, rax
    jnz .fail

    SDBG 'KERN-FOUND'

    ; --- Step 6: Allocate memory for kernel anywhere UEFI permits ---
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    xor ecx, ecx                    ; AllocateAnyPages
    mov edx, 2                      ; EfiLoaderData
    mov r8,  0x200                  ; 512 pages = 2 MB
    lea r9,  [v_kernel_addr]
    call rax
    test rax, rax
    jnz .fail

    SREG 'KADDR', [v_kernel_addr]

    ; --- Step 7: Read kernel into allocated buffer ---
    mov qword [rsp+64], 0x200000    ; max read size (in/out)
    mov rbx, [v_file]
    mov rcx, rbx
    lea rdx, [rsp+64]               ; &ByteCount
    mov r8,  [v_kernel_addr]        ; buffer
    mov rax, [rbx + FP_READ]
    call rax
    test rax, rax
    jnz .fail

    mov rax, [rsp+64]
    mov [v_ksize], rax
    test rax, rax
    jz .fail

    ; --- Close file and root ---
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax

    mov rbx, [v_root]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax

    xor eax, eax
    jmp .done

.fail:
    SDBG 'KERN-FAIL'
    mov eax, 1

.done:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; SETUP_PAGING  - identity-map 512 GB using 1 GB pages
; PML4 at 0x70000, PDPT at 0x71000
; ============================================================================
setup_paging:
    push rbx
    push r12

    ; Clear 2 pages (PML4 + PDPT)
    mov rdi, PT_BASE
    xor eax, eax
    mov ecx, 2 * 4096 / 4
    rep stosd

    ; PML4[0] -> PDPT at 0x71000
    mov qword [PT_BASE], 0x71000 | 3

    ; PDPT[0..511]: 1 GB identity pages (Present | Writable | PS)
    mov rdi, PT_BASE + 0x1000
    xor rbx, rbx                    ; physical base = 0
    mov r12d, 512
.loop:
    mov rax, rbx
    or  rax, 0x83                   ; Present | Writable | Page Size (1 GB)
    mov [rdi], rax
    add rdi, 8
    add rbx, 0x40000000             ; +1 GB
    dec r12d
    jnz .loop

    pop r12
    pop rbx
    ret

; ============================================================================
; EXIT_BOOT_SERVICES  - get memory map and call ExitBootServices (3 retries)
; ============================================================================
; LOCATE_SPP  - Find EFI_SIMPLE_POINTER_PROTOCOL and store pointer in VBE block
; Failure is non-fatal: just leaves VBE_INFO+SPP_OFF as 0.
; ============================================================================
locate_spp:
    push rbx
    push r12
    ; 2 pushes = 16. Entry 16n-8. After pushes: 16n-24. sub 40 -> 16n-64 = 0 mod 16.
    sub rsp, 40

    ; LocateProtocol(GUID, NULL, &Interface)
    ; RCX=BS, RAX=LocateProtocol, then: RCX=&GUID, RDX=0, R8=&v_spp
    mov rbx, [v_bs]
    mov rax, [rbx + BS_LOCATE]       ; LocateProtocol
    lea rcx, [guid_spp]
    xor edx, edx                     ; Registration = NULL
    lea r8,  [v_spp]
    call rax
    SREG 'SPP-RET', rax
    test rax, rax
    jnz .no_spp

    ; Got the interface. Reset it so GetState returns fresh data.
    mov r12, [v_spp]
    SREG 'SPP-IF', r12
    test r12, r12
    jz .no_spp

    ; Call Reset(interface, ExtendedVerification=0)
    mov rax, [r12 + 0]               ; Reset is first vtable entry
    mov rcx, r12
    xor edx, edx
    call rax

    ; Write interface pointer into VBE info block so the kernel can find it
    mov qword [VBE_INFO + 0x18], r12
    SDBG 'SPP-OK'
    jmp .done

.no_spp:
    SDBG 'SPP-NONE'
    mov qword [VBE_INFO + 0x18], 0

.done:
    add rsp, 40
    pop r12
    pop rbx
    ret

; ============================================================================
; Returns: RAX = 0 success, 1 fail
; ============================================================================
exit_boot_services:
    push rbx
    push r12
    ; 2 pushes = 16 bytes. Entry 16n-8. After pushes: 16n-24.
    ; sub 104 -> 16n-128 = 0 mod 16. Aligned.
    sub rsp, 104
    ; [rsp +  0..31] shadow
    ; [rsp + 32]     arg5
    ; [rsp + 40]     scratch
    ; [rsp + 48]     local: mmap_size
    ; [rsp + 56]     local: map_key
    ; [rsp + 64]     local: desc_size
    ; [rsp + 72]     local: desc_version
    ; [rsp + 80]     local: mmap_buffer ptr

    ; Allocate memory map buffer (16 KB)
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPL]
    mov ecx, 2                      ; EfiLoaderData
    mov rdx, 16384
    lea r8, [rsp+80]
    call rax
    SREG 'ALLOC-MMAP', rax
    test rax, rax
    jnz .fail

    mov r12d, 3                     ; retry counter

.retry:
    SREG 'EBS-TRY', r12
    mov qword [rsp+48], 16384       ; reset mmap_size each attempt
    mov rcx, [v_bs]
    mov rax, [rcx + BS_GETMMAP]
    lea rcx, [rsp+48]               ; &mmap_size
    mov rdx, [rsp+80]               ; buffer
    lea r8,  [rsp+56]               ; &map_key
    lea r9,  [rsp+64]               ; &desc_size
    lea rbx, [rsp+72]
    mov [rsp+32], rbx               ; &desc_version (arg5)
    call rax
    test rax, rax
    jnz .fail

    ; *** No UEFI calls between GetMemoryMap and ExitBootServices ***
    SER 'X'                         ; X = GetMemoryMap OK, about to exit

    mov rcx, [v_bs]
    mov rax, [rcx + BS_EXITBOOT]
    mov rcx, [v_handle]
    mov rdx, [rsp+56]               ; map_key
    call rax
    test rax, rax
    jz .ok

    ; Map key stale (memory map changed) - retry
    SREG 'EBS-ERR', rax
    dec r12d
    jnz .retry
    jmp .fail

.ok:
    xor eax, eax
    jmp .done

.fail:
    SDBG 'EXITBS-FAIL'
    mov eax, 1

.done:
    add rsp, 104
    pop r12
    pop rbx
    ret

; ============================================================================
; GDT  (copied to 0x500 before any kernel activity)
; CS = 0x08 (64-bit code), DS/ES/SS = 0x10 (data)
; ============================================================================
align 16
gdt64:
    dq 0                            ; Null

gdt64_code:
    dw 0x0000, 0x0000               ; Limit, Base[15:0]
    db 0x00                         ; Base[23:16]
    db 10011010b                    ; P=1 DPL=0 S=1 Type=1010 (Code R/X)
    db 00100000b                    ; L=1 (64-bit), D=0
    db 0x00                         ; Base[31:24]

gdt64_data:
    dw 0x0000, 0x0000
    db 0x00
    db 10010010b                    ; P=1 DPL=0 S=1 Type=0010 (Data R/W)
    db 00000000b
    db 0x00

gdt64_end:

; ============================================================================
; Protocol GUIDs
; ============================================================================
align 4
guid_gop:
    dd 0x9042a9de
    dw 0x23dc, 0x4a38
    db 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a

guid_sfs:
    dd 0x964e5b22
    dw 0x6459, 0x11d2
    db 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

guid_lip:
    dd 0x5b1b31a1
    dw 0x9562, 0x11d2
    db 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

; EFI_SIMPLE_POINTER_PROTOCOL
guid_spp:
    dd 0x31878c87
    dw 0x0b75, 0x11d5
    db 0x9a, 0x4f, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d

; ============================================================================
; UCS-2 strings
; ============================================================================
align 2
s_banner:       ustr `NexusOS v3.0 UEFI Loader\r\n`
s_gop:          ustr `  [1/4] GOP Init...`
s_kernel:       ustr `  [2/4] Loading KERNEL.BIN...`
s_paging:       ustr `  [3/4] Page tables...`
s_exit:         ustr `  [4/4] ExitBootServices...`
s_ok:           ustr ` OK\r\n`
s_fail_kernel:  ustr ` FAIL: Kernel load\r\n`
s_fail_exit:    ustr ` FAIL: ExitBootServices\r\n`
s_kern_path:    ustr "\EFI\BOOT\KERNEL.BIN"

; ============================================================================
; Variables
; ============================================================================
align 8
v_handle:      dq 0
v_systab:      dq 0
v_bs:          dq 0
v_conout:      dq 0

v_gop:         dq 0
v_spp:         dq 0
v_fb:          dq 0
v_scrw:        dd 0
v_scrh:        dd 0
v_pitch:       dd 0

v_lip:         dq 0
v_devhandle:   dq 0
v_sfs:         dq 0
v_root:        dq 0
v_file:        dq 0
v_kernel_addr: dq 0
v_ksize:       dq 0
v_tmp_addr:    dq 0

; Pad text section to full raw size
times (HDR_SZ + TEXT_RAW - ($ - $$)) db 0

; ============================================================================
; .reloc section (minimal - one page entry, zero fixups)
; ============================================================================
    dd 0x1000, 12
    dw 0, 0

times (HDR_SZ + TEXT_RAW + RELOC_FSZ - ($ - $$)) db 0
