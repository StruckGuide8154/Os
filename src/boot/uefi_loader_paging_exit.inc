; ============================================================================
; SETUP_PAGING  - identity-map 512 GB.
; The first 1 GB uses 2 MB pages so the app arena can be user-accessible
; while the rest stays supervisor-only; everything above 1 GB stays mapped
; with supervisor-only 1 GB pages.
; ============================================================================
setup_paging:
    push r14
    push r15
    %define UEFI_PAGE_PRESENT      0x01
    %define UEFI_PAGE_WRITABLE     0x02
    %define UEFI_PAGE_USER         0x04
    %define UEFI_PAGE_LARGE        0x80
    ; W^X: kernel text lives in [KTEXT_START, KTEXT_END). All other pages NX.
    %define UEFI_KTEXT_START_PAGE  0x100     ; PTE index of 0x100000
    %define UEFI_KTEXT_END_PAGE    0x200     ; executable kernel text through 2 MiB
    %define UEFI_PT0_BASE          0x74000   ; 4KB page table for PD0[0]
    %define UEFI_APP_PT_BASE       0x75000   ; 8 PTs (0x75000..0x7CFFF) for app arena
    push rbx
    push r12
    push r13

    ; Clear 19 pages (0x70000..0x82FFF):
    ;   PML4 + PDPT0 + PDPT1 + PD0 + PT0     = 5 pages
    ;   12 app-arena PTs at UEFI_APP_PT_BASE = 12 pages
    ;   gap page at 0x81000 (BIOS PD3 slot)  = 1 page
    ;   syscall-stack PT at 0x82000          = 1 page (kernel-installed)
    ; The 12 arena PTs give the app arena 4KB granularity for per-slot USER
    ; toggling and W^X; the syscall-stack PT is wired up later by the kernel.
    mov rdi, PT_BASE
    xor eax, eax
    mov ecx, 19 * 4096 / 4
    rep stosd

    ; PML4[0] -> PDPT0 at 0x71000 (covers 0-512 GB).
    ; Mark this branch user-accessible because PDPT0[0] contains the app arena.
    mov qword [abs PT_BASE], 0x71000 | 7
    ; PML4[1] -> PDPT1 at 0x72000 (covers 512-1024 GB), supervisor-only.
    mov qword [abs PT_BASE + 8], 0x72000 | 3

    ; PDPT0[0] -> PD0 at 0x73000 for the first 1 GB, with User set.
    mov qword [abs PT_BASE + 0x1000], 0x73000 | 7

    ; PDPT0[1..511]: 1 GB identity pages starting at 1 GB, supervisor-only, NX.
    mov rdi, PT_BASE + 0x1000 + 8
    mov rbx, 0x40000000             ; physical base = 1 GB
    mov r12d, 511
.loop_pdpt0:
    mov rax, rbx
    or  rax, 0x83                   ; Present | Writable | Page Size (1 GB)
    bts rax, 63                     ; NX (data only, no code execution)
    mov [rdi], rax
    add rdi, 8
    add rbx, 0x40000000             ; +1 GB
    dec r12d
    jnz .loop_pdpt0

    ; PD0[0]: point to fine-grained PT0 (4KB pages over 0..2MB) for W^X split.
    mov qword [abs PT_BASE + 0x3000], UEFI_PT0_BASE | (UEFI_PAGE_PRESENT | UEFI_PAGE_WRITABLE | UEFI_PAGE_USER)

    ; PT0[0..511]: 4KB identity pages over 0..2MB.
    ;   pages [KTEXT_START..KTEXT_END)  : executable (kernel code)
    ;   all other pages                  : NX + writable (data/stack/etc)
    ; All supervisor-only: ring 3 never accesses anything below 2MB. Marking
    ; these USER would expose the page tables (PT_BASE), GDT, IDT pointer and
    ; kernel text to ring-3 reads/writes.
    mov rdi, UEFI_PT0_BASE
    xor ebx, ebx                    ; ebx = PTE index
    xor eax, eax                    ; eax = physical base
.loop_pt0:
    mov rdx, rax
    or  edx, UEFI_PAGE_PRESENT | UEFI_PAGE_WRITABLE
    ; Trampoline at 0x8000 must stay executable: its final two instructions
    ; (mov rax,KERN_DEST / jmp rax) execute AFTER cr3 is reloaded with PT_BASE.
    cmp ebx, 8
    je .pt0_write
    cmp ebx, UEFI_KTEXT_START_PAGE
    jb .pt0_nx
    cmp ebx, UEFI_KTEXT_END_PAGE
    jae .pt0_nx
    jmp .pt0_write                  ; kernel text: executable
.pt0_nx:
    bts rdx, 63                     ; NX
    jmp .pt0_write
.pt0_write:
    mov [rdi], rdx
    add eax, 0x1000
    add rdi, 8
    inc ebx
    cmp ebx, 512
    jb .loop_pt0

    ; PD0[1..511]: 2 MB identity pages over 2MB..1GB, supervisor-only by default.
    ; App arena PDEs get USER bit (code runs here, no NX).
    ; All other PDEs are kernel data/heap/framebuffer: NX.
    mov rdi, PT_BASE + 0x3000 + 8
    mov rax, 0x200000
    or  rax, UEFI_PAGE_PRESENT | UEFI_PAGE_WRITABLE | UEFI_PAGE_LARGE
    mov ebx, 1
    mov r14, [abs VBE_INFO + VBE_APP_ARENA_BASE_OFF]
    shr r14, 21
    mov r15, [abs VBE_INFO + VBE_APP_ARENA_SIZE_OFF]
    add r15, 0x1FFFFF
    shr r15, 21
    add r15, r14
.loop_pd0:
    mov rdx, rax
    cmp rbx, r14
    jb .pd0_nx
    cmp rbx, r15
    jae .pd0_nx
    ; App arena: PDE points at a 4KB page table (not a 2MB large page) so the
    ; kernel can toggle the USER bit per slot and enforce W^X per page.
    ; PT for this PDE is at UEFI_APP_PT_BASE + (pde_index - r14) * 4KB.
    mov rdx, rbx
    sub rdx, r14
    shl rdx, 12
    add rdx, UEFI_APP_PT_BASE
    or  rdx, UEFI_PAGE_PRESENT | UEFI_PAGE_WRITABLE | UEFI_PAGE_USER
    jmp .pd0_write
.pd0_nx:
    ; Keep the loaded kernel image executable after the first 2 MiB. The
    ; trampoline jumps into KERNEL_LOAD_ADDR and the monolithic kernel's text
    ; spans multiple MiB once generated NexusHL apps are included.
    cmp ebx, 1
    jb .pd0_set_nx
    cmp ebx, 8
    jb .pd0_write
.pd0_set_nx:
    bts rdx, 63                     ; kernel data region: NX
.pd0_write:
    mov [rdi], rdx
    add rax, 0x200000
    add rdi, 8
    inc ebx
    cmp ebx, 512
    jb .loop_pd0

    ; Fill the app-arena 4KB page tables. The arena spans (r15-r14) PDEs,
    ; each PDE backed by 512 4KB PTEs. Physical base = r14 << 21.
    ; Every PTE starts Present|Writable|USER and executable; the kernel
    ; tightens USER (slot isolation) and NX (W^X) at runtime per slot.
    mov rdi, UEFI_APP_PT_BASE
    mov rax, r14
    shl rax, 21                     ; arena physical base
    or  rax, UEFI_PAGE_PRESENT | UEFI_PAGE_WRITABLE | UEFI_PAGE_USER
    mov rcx, r15
    sub rcx, r14                    ; arena PDE count
    shl rcx, 9                      ; * 512 PTEs per PDE
.loop_app_pt:
    mov [rdi], rax
    add rax, 0x1000
    add rdi, 8
    dec rcx
    jnz .loop_app_pt

    ; Per-slot stack guard pages: clear PAGE_PRESENT one 4KB page below
    ; each slot's user stack. Slot count = (r15 - r14) arena PDEs (one PDE
    ; per 2 MiB slot). See boot_memory.inc:L3_SLOT_USER_STACK_GUARD_OFF.
    mov rdi, UEFI_APP_PT_BASE + L3_SLOT_USER_STACK_GUARD_PTE * 8
    mov rcx, r15
    sub rcx, r14
.loop_guard_pt:
    mov rax, [rdi]
    and rax, ~UEFI_PAGE_PRESENT
    mov [rdi], rax
    add rdi, 0x1000          ; same PTE slot in the next slot's PT
    dec rcx
    jnz .loop_guard_pt

    ; PDPT1[0..511]: 1 GB identity pages starting at 512 GB, supervisor-only, NX.
    mov rdi, PT_BASE + 0x2000
    mov rbx, 0x8000000000           ; physical base = 512 GB
    mov r12d, 512
.loop2:
    mov rax, rbx
    or  rax, 0x83                   ; Present | Writable | Page Size (1 GB)
    bts rax, 63                     ; NX
    mov [rdi], rax
    add rdi, 8
    add rbx, 0x40000000             ; +1 GB
    dec r12d
    jnz .loop2

    pop r13
    pop r12
    pop rbx
    pop r15
    pop r14
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
    test rax, rax
    jnz .no_spp

    mov r12, [v_spp]
    test r12, r12
    jz .no_spp

    ; Call Reset(interface, ExtendedVerification=0)
    mov rax, [r12 + 0]               ; Reset is first vtable entry
    mov rcx, r12
    xor edx, edx
    call rax

    mov qword [abs VBE_INFO + VBE_SPP_OFF], r12
    jmp .done

.no_spp:
    mov qword [abs VBE_INFO + VBE_SPP_OFF], 0

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
    test rax, rax
    jnz .fail

    mov r12d, 3                     ; retry counter

.retry:
    mov qword [rsp+48], 16384
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

    call publish_e820_map

    ; *** No UEFI calls between GetMemoryMap and ExitBootServices ***
    SER 'X'                         ; X = GetMemoryMap OK, about to exit

    mov rcx, [v_bs]
    mov rax, [rcx + BS_EXITBOOT]
    mov rcx, [v_handle]
    mov rdx, [rsp+56]               ; map_key
    call rax
    test rax, rax
    jz .ok

    dec r12d
    jnz .retry
    jmp .fail

.ok:
    xor eax, eax
    jmp .done

.fail:
    mov eax, 1

.done:
    add rsp, 104
    pop r12
    pop rbx
    ret

; ============================================================================
; PUBLISH_E820_MAP - convert the UEFI memory map into the kernel's legacy
; E820 handoff block at E820_COUNT_ADDR/E820_MAP_ADDR.
;
; Input locals from exit_boot_services:
;   [rsp+48] mmap_size, [rsp+64] desc_size, [rsp+80] mmap_buffer
; ============================================================================
publish_e820_map:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov rsi, [rsp + 48 + 80]        ; caller rsp+48 after return addr + 9 pushes
    mov rbx, [rsp + 64 + 80]        ; descriptor size
    mov r10, [rsp + 80 + 80]        ; descriptor buffer
    xor r11d, r11d                  ; output entry count

    test rsi, rsi
    jz .done
    test rbx, rbx
    jz .done

    mov rdi, E820_MAP_ADDR
.loop:
    cmp rsi, rbx
    jb .done

    mov eax, [r10 + 0]              ; EFI_MEMORY_DESCRIPTOR.Type
    cmp eax, 7                      ; EfiConventionalMemory
    jne .next

    cmp r11d, 255                   ; 255 * 24 fits below the 0x8000 trampoline
    jae .done

    mov rax, [r10 + 8]              ; PhysicalStart
    mov [rdi + 0], rax
    mov rax, [r10 + 24]             ; NumberOfPages
    shl rax, 12
    mov [rdi + 8], rax
    mov dword [rdi + 16], 1         ; E820 usable RAM
    mov dword [rdi + 20], 0         ; ACPI extended attributes

    add rdi, 24
    inc r11d

.next:
    add r10, rbx
    sub rsi, rbx
    jmp .loop

.done:
    mov [abs E820_COUNT_ADDR], r11w

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
