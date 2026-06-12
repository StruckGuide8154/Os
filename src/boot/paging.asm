; ============================================================================
; GritOS v3.0 - Page Table Setup (BIOS path)
; Identity-maps first 4GB. PD0..PD2 use 2MB pages; the app arena PDEs in PD0
; instead point at 4KB page tables so the kernel can toggle USER per slot
; (and W^X per page) at ring-3 entry. PD3 is relocated to 0x81000 because
; 0x75000..0x80FFF now holds the 12 app-arena PTs. A further PT page sits at
; SYSCALL_STACK_PT_BASE (0x82000); it is zeroed here and wired up later by
; l3_install_syscall_stack_pt to split the kernel-BSS PDE containing
; l3_syscall_stacks into 4 KiB pages with per-slot guard PTEs.
;
; Layout:
;   0x70000  PML4
;   0x71000  PDPT (PML4[0])
;   0x72000  PD0  (0..1 GB)
;   0x73000  PD1  (1..2 GB)
;   0x74000  PD2  (2..3 GB)
;   0x75000..0x80FFF  12 app-arena 4KB page tables (APP_ARENA_PT_BASE)
;   0x81000  PD3  (3..4 GB)
;   0x82000  syscall-stack PT (SYSCALL_STACK_PT_BASE, kernel-installed)
; ============================================================================
bits 16   ; We are in 16-bit Unreal Mode

%include "src/include/boot_memory.inc"

; Page-table entry flag bits (SDM Vol.3 §4.5; bit 63 = XD/NX, §4.6).
PAGE_PRESENT    equ 0x01
PAGE_WRITABLE   equ 0x02
PAGE_USER       equ 0x04     ; User-accessible (ring 3)
PAGE_LARGE      equ 0x80     ; 2MB page (PS bit in PD entry)
; Architectural page size (used as the 2 MiB physical stride below).
PAGE_SIZE_2M    equ 0x200000
; Page-table page physical addresses, contiguous from PAGE_TABLE_ADDR
; (boot_memory.inc = 0x70000). PD3 is relocated above the arena PTs.
PAGE_PML4_BASE  equ PAGE_TABLE_ADDR        ; 0x70000  PML4
PAGE_PDPT_BASE  equ (PAGE_TABLE_ADDR + 0x1000) ; 0x71000  PDPT (PML4[0])
PAGE_PD0_BASE   equ (PAGE_TABLE_ADDR + 0x2000) ; 0x72000  PD0 (0..1 GB)
PAGE_PD1_BASE   equ (PAGE_TABLE_ADDR + 0x3000) ; 0x73000  PD1 (1..2 GB)
PAGE_PD2_BASE   equ (PAGE_TABLE_ADDR + 0x4000) ; 0x74000  PD2 (2..3 GB)
APP_USER_PDE0   equ (APP_DATA_ADDR / PAGE_SIZE_2M)
APP_USER_PDE_COUNT equ ((APP_SLOT_COUNT * APP_SLOT_SIZE + 0x1FFFFF) / PAGE_SIZE_2M)
PD3_BASE        equ 0x81000

setup_paging:
    ; Clear page table region: PML4 + PDPT + PD0 + PD1 + PD2
    ; + APP_USER_PDE_COUNT arena PTs + PD3 + syscall-stack PT
    ; = 5 + 12 + 1 + 1 = 19 pages (0x70000..0x82FFF).
    mov edi, PAGE_PML4_BASE
    xor eax, eax
    mov ecx, (19 * 4096) / 4
    a32 rep stosd

    ; PML4[0] -> PDPT
    mov edi, PAGE_PML4_BASE
    mov eax, PAGE_PDPT_BASE | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER
    a32 mov [edi], eax

    ; PDPT[0] -> PD0 (covers 0-1GB)
    mov edi, PAGE_PDPT_BASE
    mov eax, PAGE_PD0_BASE | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER
    a32 mov [edi], eax

    ; PDPT[1] -> PD1 (covers 1-2GB)
    mov edi, PAGE_PDPT_BASE + 8
    mov eax, PAGE_PD1_BASE | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER
    a32 mov [edi], eax

    ; PDPT[2] -> PD2 (covers 2-3GB)
    mov edi, PAGE_PDPT_BASE + 16
    mov eax, PAGE_PD2_BASE | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER
    a32 mov [edi], eax

    ; PDPT[3] -> PD at PD3_BASE (covers 3-4GB). Moved from 0x75000 so the
    ; arena 4KB PTs at APP_ARENA_PT_BASE can occupy 0x75000..0x80FFF.
    mov edi, PAGE_PDPT_BASE + 24
    mov eax, PD3_BASE | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER
    a32 mov [edi], eax

    ; Fill PD tables with 2MB pages. Arena PDEs (in PD0) are rewritten below
    ; to point at 4KB PTs instead of being large pages.
    mov edi, PAGE_PD0_BASE      ; PD0 base (PD1/PD2 follow contiguously; PD3 is at PD3_BASE)
    mov eax, PAGE_PRESENT | PAGE_WRITABLE | PAGE_LARGE  ; Supervisor-only by default
    mov ecx, 512 * 3            ; 1536 entries (PD0..PD2)
    xor ebx, ebx                ; PDE index across the 0..3 GB map

.fill_pd:
    push eax
    cmp ebx, APP_USER_PDE0
    jb .write_entry
    mov edx, APP_USER_PDE0 + APP_USER_PDE_COUNT
    cmp ebx, edx
    jae .write_entry
    or eax, PAGE_USER
    ; Arena PDE: replace the 2MB-large mapping with a pointer to a 4KB page
    ; table. The kernel's l3_apply_slot_isolation toggles USER on the
    ; individual PTEs per active slot at ring-3 entry; here the PDE itself
    ; stays PRESENT|WRITABLE|USER (the PDE USER bit is the gate that lets
    ; the PTE USER bit reach ring 3 at all).
    mov eax, ebx
    sub eax, APP_USER_PDE0
    shl eax, 12
    add eax, APP_ARENA_PT_BASE
    or eax, PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER
.write_entry:
    a32 mov [edi], eax
    pop eax

    add eax, PAGE_SIZE_2M       ; Next 2MB page physical address
    add edi, 8                  ; Next PD entry (8 bytes each)
    inc ebx
    dec ecx
    jnz .fill_pd

    ; Fill PD3 (3..4 GB) at its relocated base. eax/ebx already advanced
    ; from the PD0..PD2 loop, so the next 2MB physical page lines up.
    mov edi, PD3_BASE
    mov ecx, 512
.fill_pd3:
    a32 mov [edi], eax
    add eax, PAGE_SIZE_2M
    add edi, 8
    dec ecx
    jnz .fill_pd3

    ; Populate the 12 app-arena 4KB page tables. Each PTE initially maps the
    ; corresponding 4KB physical page with PRESENT|WRITABLE|USER. The kernel's
    ; l3_apply_slot_isolation (src/kernel/proc/usermode.asm) clamps the USER
    ; bit to the running slot's pages on every ring-3 entry, so the initial
    ; USER mapping is safe - nothing executes in ring 3 before that clamp.
    mov edi, APP_ARENA_PT_BASE
    mov eax, APP_DATA_ADDR | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER
    mov ecx, APP_USER_PDE_COUNT * 512
.fill_pt:
    a32 mov [edi], eax
    add eax, 0x1000
    add edi, 8
    dec ecx
    jnz .fill_pt

    ; Per-slot stack guard: clear PAGE_PRESENT on the PTE one 4KB page below
    ; the user stack of every slot. An overflow past the stack bottom faults
    ; on this page rather than corrupting slot data below it.
    mov edi, APP_ARENA_PT_BASE + L3_SLOT_USER_STACK_GUARD_PTE * 8
    mov ecx, APP_SLOT_COUNT
.guard_pt:
    a32 mov eax, [edi]
    and eax, ~PAGE_PRESENT
    a32 mov [edi], eax
    add edi, 0x1000          ; next slot's PT (and same PTE index)
    dec ecx
    jnz .guard_pt

    ret
