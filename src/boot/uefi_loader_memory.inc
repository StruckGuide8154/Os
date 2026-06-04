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
    %endmacro

    DO_CLAIM VBE_INFO,   1          ; Boot info block
    DO_CLAIM 0x1000,     1          ; E820 entry count page
    DO_CLAIM E820_MAP_ADDR, 4       ; BIOS-compatible memory map handoff
    DO_CLAIM PT_BASE,    19         ; PML4+PDPT0+PDPT1+PD0+PT0+12 app PTs (0x70000..0x80FFF)
                                    ; + 1 gap page at 0x81000 (BIOS PD3 slot, unused here)
                                    ; + syscall-stack PT at 0x82000 = 19 pages total
    DO_CLAIM SMP_TRAMPOLINE_ADDR, 1 ; Trampoline
    ; NOTE: Do NOT claim KERN_DEST (0x100000) here — UEFI loaded our own
    ; PE image at ImageBase=0x100000.  Claiming it could corrupt memory
    ; protections on our code/data/stack while we're still executing.
    ; The trampoline copies the kernel there AFTER ExitBootServices.
    DO_CLAIM KERN_STACK, 16         ; Kernel stack + IDT space

    add rsp, 32
    pop rbx
    ret

; ============================================================================
; ALLOC_BOOT_REGIONS - allocate variable physical regions and publish boot info
; ============================================================================
alloc_boot_regions:
    push rbx
    sub rsp, 40

    mov qword [abs VBE_INFO + VBE_BACKBUF_OFF], BACK_BUFFER_ADDR
    mov qword [abs VBE_INFO + VBE_BACKBUF_SIZE_OFF], BOOT_BACK_BUFFER_SIZE
    mov qword [abs VBE_INFO + VBE_APP_ARENA_BASE_OFF], APP_DATA_ADDR
    mov qword [abs VBE_INFO + VBE_APP_ARENA_SIZE_OFF], (APP_SLOT_SIZE * APP_SLOT_COUNT)

    ; App arena uses 2MB PDE permissions today, so keep it 2MB-aligned.
    mov qword [v_tmp_addr], APP_DATA_ADDR
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    mov ecx, 2                      ; AllocateAddress
    mov edx, 2                      ; EfiLoaderData
    mov r8, (APP_SLOT_SIZE * APP_SLOT_COUNT) / 0x1000
    lea r9, [v_tmp_addr]
    call rax
    test rax, rax
    jnz .alloc_backbuf
    mov rax, [v_tmp_addr]
    mov [abs VBE_INFO + VBE_APP_ARENA_BASE_OFF], rax

.alloc_backbuf:
    mov qword [v_tmp_addr], 0
    mov rcx, [v_bs]
    mov rax, [rcx + BS_ALLOCPG]
    mov ecx, 0                      ; AllocateAnyPages
    mov edx, 2                      ; EfiLoaderData
    mov r8, (BOOT_BACK_BUFFER_SIZE + 0xFFF) / 0x1000
    lea r9, [v_tmp_addr]
    call rax
    test rax, rax
    jnz .done

    mov rax, [v_tmp_addr]
    mov [abs VBE_INFO + VBE_BACKBUF_OFF], rax

.done:
    add rsp, 40
    pop rbx
    ret
