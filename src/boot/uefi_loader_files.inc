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
    mov rax, [rax + 24]
    mov [v_devhandle], rax
    test rax, rax
    jz .fail

    ; --- Step 3: Get SFS from DeviceHandle ---
    mov rcx, [v_bs]
    mov rax, [rcx + BS_HNDLPROT]
    mov rcx, [v_devhandle]
    lea rdx, [guid_sfs]
    lea r8,  [v_sfs]
    call rax
    test rax, rax
    jnz .fail

    ; --- Step 4: OpenVolume ---
    mov rbx, [v_sfs]
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    test rax, rax
    jnz .fail

    ; --- Step 5: Open \EFI\BOOT\KERNEL.BIN ---
    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file]
    lea r8,  [s_kern_path]
    mov r9,  1
    mov qword [rsp+32], 0
    mov rax, [rbx + FP_OPEN]
    call rax
    test rax, rax
    jnz .fail

    ; --- Step 6: Allocate memory for kernel anywhere UEFI permits ---
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    xor ecx, ecx                    ; AllocateAnyPages
    mov edx, 2                      ; EfiLoaderData
    mov r8,  KERNEL_LOAD_MAX_PAGES  ; 8192 pages = 32 MB
    lea r9,  [v_kernel_addr]
    call rax
    test rax, rax
    jnz .fail

    ; --- Step 7: Read kernel into allocated buffer ---
    mov qword [rsp+64], KERNEL_LOAD_MAX_BYTES  ; max read size (in/out)
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
; LOAD_APPS - open \EFI\BOOT\APPS.BIN, read into RAM at APPS_DEST.
; Writes blob base + size into boot info for the kernel to pick up.
; Non-fatal on failure: app blob boot-info fields stay 0.
; ============================================================================
load_apps:
    push rbx
    sub rsp, 48
    ; [rsp +  0..31] shadow
    ; [rsp + 32]     arg5 / scratch
    ; [rsp + 40]     local: read_size (in/out)

    ; Write safe defaults in case anything fails.
    mov qword [abs VBE_INFO + VBE_APPS_BASE_OFF], 0
    mov qword [abs VBE_INFO + VBE_APPS_SIZE_OFF], 0
    mov qword [v_apps_size], 0

    ; Reopen root volume (original root file was closed by load_kernel).
    mov rbx, [v_sfs]
    test rbx, rbx
    jz .fail
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    test rax, rax
    jnz .fail

    ; Open \EFI\BOOT\APPS.BIN
    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file]
    lea r8,  [s_apps_path]
    mov r9,  1
    mov qword [rsp+32], 0
    mov rax, [rbx + FP_OPEN]
    call rax
    test rax, rax
    jnz .fail

    ; Allocate APPS.BIN storage from firmware, then read file in.
    mov qword [v_tmp_addr], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    mov ecx, 0                      ; AllocateAnyPages
    mov edx, 2                      ; EfiLoaderData
    mov r8, APPS_MAX_SZ / 0x1000
    lea r9, [v_tmp_addr]
    call rax
    test rax, rax
    jnz .close_and_fail

    mov qword [rsp+40], APPS_MAX_SZ
    mov rbx, [v_file]
    mov rcx, rbx
    lea rdx, [rsp+40]
    mov r8, [v_tmp_addr]
    mov rax, [rbx + FP_READ]
    call rax
    test rax, rax
    jnz .close_and_fail

    mov rax, [rsp+40]               ; actual bytes read
    test rax, rax
    jz .close_and_fail
    mov [v_apps_size], rax
    mov rdx, [v_tmp_addr]
    mov [abs VBE_INFO + VBE_APPS_BASE_OFF], rdx
    mov [abs VBE_INFO + VBE_APPS_SIZE_OFF], rax

    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
    jmp .done

.close_and_fail:
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
.fail:
.done:
    add rsp, 48
    pop rbx
    ret

; ============================================================================
; LOAD_DATA_IMG - open \EFI\BOOT\DATA.IMG, read into firmware-allocated RAM,
; publish (base, size) in VBE_INFO so the kernel's ramdisk shim can take over
; block I/O for the FAT16 partition. See src/kernel/drivers/ramdisk.asm and
; docs/ramdisk.md for the contract. Non-fatal on every error: missing file,
; allocation failure, or oversize image all leave the ramdisk fields zero
; and the kernel falls back to ATA PIO.
; ============================================================================
%define DATA_IMG_MAX_SZ DATA_IMG_MAX_SIZE

load_data_img:
    push rbx
    sub rsp, 48
    ; [rsp +  0..31] shadow
    ; [rsp + 32]     arg5 / scratch
    ; [rsp + 40]     local: read_size (in/out)

    ; Safe defaults so a partial failure cannot leave stale pointers.
    mov qword [abs VBE_INFO + VBE_RAMDISK_BASE_OFF], 0
    mov qword [abs VBE_INFO + VBE_RAMDISK_SIZE_OFF], 0
    mov qword [v_data_size], 0

    ; Reopen root volume (previous opens have been closed).
    mov rbx, [v_sfs]
    test rbx, rbx
    jz .fail
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    test rax, rax
    jnz .fail

    ; Open \EFI\BOOT\DATA.IMG (read-only).
    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file]
    lea r8,  [s_data_path]
    mov r9,  1
    mov qword [rsp+32], 0
    mov rax, [rbx + FP_OPEN]
    call rax
    test rax, rax
    jnz .fail

    ; AllocatePages(AnyPages, EfiLoaderData, DATA_IMG_MAX_SZ / 4K, &addr).
    mov qword [v_tmp_addr], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    mov ecx, 0
    mov edx, 2
    mov r8, DATA_IMG_MAX_SZ / 0x1000
    lea r9, [v_tmp_addr]
    call rax
    test rax, rax
    jnz .close_and_fail

    mov qword [rsp+40], DATA_IMG_MAX_SZ
    mov rbx, [v_file]
    mov rcx, rbx
    lea rdx, [rsp+40]
    mov r8, [v_tmp_addr]
    mov rax, [rbx + FP_READ]
    call rax
    test rax, rax
    jnz .close_and_fail

    mov rax, [rsp+40]                       ; actual bytes read
    test rax, rax
    jz .close_and_fail
    mov [v_data_size], rax
    mov rdx, [v_tmp_addr]
    mov [abs VBE_INFO + VBE_RAMDISK_BASE_OFF], rdx
    mov [abs VBE_INFO + VBE_RAMDISK_SIZE_OFF], rax

    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
    jmp .done

.close_and_fail:
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
.fail:
.done:
    add rsp, 48
    pop rbx
    ret

; ============================================================================
; LOAD_BOOTCFG - open OPTIONAL \EFI\BOOT\BOOTCFG.TXT, read into firmware RAM,
; publish (base,size) in VBE_INFO so the kernel's boot_features.ghl parser can
; build the runtime feature-toggle bitmask. Non-fatal on EVERY error (missing
; file is the common case): leaves the boot-info fields zero, which the kernel
; treats as "no config -> default everything ON". Mirrors load_data_img.
; ============================================================================
load_bootcfg:
    push rbx
    sub rsp, 48

    mov qword [abs VBE_INFO + VBE_BOOTCFG_BASE_OFF], 0
    mov qword [abs VBE_INFO + VBE_BOOTCFG_SIZE_OFF], 0
    mov qword [v_bootcfg_size], 0

    mov rbx, [v_sfs]
    test rbx, rbx
    jz .bc_fail
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    test rax, rax
    jnz .bc_fail

    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file]
    lea r8,  [s_bootcfg_path]
    mov r9,  1
    mov qword [rsp+32], 0
    mov rax, [rbx + FP_OPEN]
    call rax
    test rax, rax
    jnz .bc_fail

    mov qword [v_tmp_addr], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    mov ecx, 0
    mov edx, 2
    mov r8, BOOTCFG_MAX_SIZE / 0x1000
    lea r9, [v_tmp_addr]
    call rax
    test rax, rax
    jnz .bc_close_and_fail

    mov qword [rsp+40], BOOTCFG_MAX_SIZE
    mov rbx, [v_file]
    mov rcx, rbx
    lea rdx, [rsp+40]
    mov r8, [v_tmp_addr]
    mov rax, [rbx + FP_READ]
    call rax
    test rax, rax
    jnz .bc_close_and_fail

    mov rax, [rsp+40]
    test rax, rax
    jz .bc_close_and_fail
    mov [v_bootcfg_size], rax
    mov rdx, [v_tmp_addr]
    mov [abs VBE_INFO + VBE_BOOTCFG_BASE_OFF], rdx
    mov [abs VBE_INFO + VBE_BOOTCFG_SIZE_OFF], rax

    SER 'C'                          ; C = BOOTCFG loaded
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
    jmp .bc_done

.bc_close_and_fail:
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
.bc_fail:
.bc_done:
    add rsp, 48
    pop rbx
    ret

; ============================================================================
; LOAD_OPT_FILE - generic optional-ESP-file slurp (Track 2 envelope files).
; Opens the UCS-2 path in RSI, reads up to RBP bytes into freshly allocated
; firmware pages, and publishes (base, size) at VBE_INFO + RDI (+ RDI+8).
; Non-fatal on EVERY error: leaves the two fields zero (the kernel decides
; whether a missing file is fatal). Mirrors load_bootcfg.
;   in: rsi = ustr path, rdi = VBE_INFO offset of base field, rbp = max bytes
; ============================================================================
load_opt_file:
    push rbx
    push rsi
    push rdi
    push rbp
    sub rsp, 56

    mov qword [VBE_INFO + rdi], 0
    mov qword [VBE_INFO + rdi + 8], 0

    mov rbx, [v_sfs]
    test rbx, rbx
    jz .of_fail
    mov rcx, rbx
    lea rdx, [v_root]
    mov rax, [rbx + SFS_OPENVOL]
    call rax
    test rax, rax
    jnz .of_fail

    mov rbx, [v_root]
    mov rcx, rbx
    lea rdx, [v_file]
    mov r8,  rsi                     ; UCS-2 path
    mov r9,  1                       ; EFI_FILE_MODE_READ
    mov qword [rsp+32], 0
    mov rax, [rbx + FP_OPEN]
    call rax
    test rax, rax
    jnz .of_fail

    mov qword [v_tmp_addr], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    mov ecx, 0                       ; AllocateAnyPages
    mov edx, 2                       ; EfiLoaderData
    mov r8, rbp
    shr r8, 12                       ; max bytes -> pages
    lea r9, [v_tmp_addr]
    call rax
    test rax, rax
    jnz .of_close_and_fail

    mov [rsp+40], rbp                ; in/out: bytes to read / bytes read
    mov rbx, [v_file]
    mov rcx, rbx
    lea rdx, [rsp+40]
    mov r8, [v_tmp_addr]
    mov rax, [rbx + FP_READ]
    call rax
    test rax, rax
    jnz .of_close_and_fail

    mov rax, [rsp+40]
    test rax, rax
    jz .of_close_and_fail
    mov rdx, [v_tmp_addr]
    mov [VBE_INFO + rdi], rdx
    mov [VBE_INFO + rdi + 8], rax

    SER 'V'                          ; V = optional envelope file loaded
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
    jmp .of_done

.of_close_and_fail:
    mov rbx, [v_file]
    mov rcx, rbx
    mov rax, [rbx + FP_CLOSE]
    call rax
.of_fail:
.of_done:
    add rsp, 56
    pop rbp
    pop rdi
    pop rsi
    pop rbx
    ret

; LOAD_ENVELOPES - load the Track 2 signed-envelope files (see boot_memory.inc).
load_envelopes:
    push rsi
    push rdi
    push rbp
    lea rsi, [s_syssig_path]
    mov edi, VBE_SYSSIG_BASE_OFF
    mov ebp, SYSSIG_MAX_SIZE
    call load_opt_file
    lea rsi, [s_kupdate_path]
    mov edi, VBE_KUPDATE_BASE_OFF
    mov ebp, KUPDATE_MAX_SIZE
    call load_opt_file
    lea rsi, [s_kquorum_path]
    mov edi, VBE_KQUORUM_BASE_OFF
    mov ebp, KQUORUM_MAX_SIZE
    call load_opt_file
    lea rsi, [s_kernenv_path]
    mov edi, VBE_KERNENV_BASE_OFF
    mov ebp, KERNENV_MAX_SIZE
    call load_opt_file
    ; Publish the PRISTINE KERNEL.BIN container bytes (read by load_kernel
    ; into firmware pages; the trampoline copies the payload OUT of this
    ; buffer, so it stays byte-identical to the at-rest file) for
    ; kernel_env_verify_boot's re-hash.
    mov rax, [v_kernel_addr]
    mov [abs VBE_INFO + VBE_KIMG_BASE_OFF], rax
    mov rax, [v_ksize]
    mov [abs VBE_INFO + VBE_KIMG_SIZE_OFF], rax
    pop rbp
    pop rdi
    pop rsi
    ret
