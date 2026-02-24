; ============================================================================
; NexusOS v3.0 - Page Table Setup
; Identity-maps first 4GB using 2MB pages for long mode
; PML4 at 0x70000, PDPT at 0x71000, PD tables at 0x72000-0x75FFF
; ============================================================================
bits 16   ; We are in 16-bit Unreal Mode

PAGE_PRESENT    equ 0x01
PAGE_WRITABLE   equ 0x02
PAGE_LARGE      equ 0x80     ; 2MB page (PS bit in PD entry)

setup_paging:
    ; Clear page table area (24KB: 0x70000 - 0x75FFF)
    ; In 16-bit mode, STOSD uses DI (16-bit). We must enable 32-bit addressing override!
    ; With a32 prefix, it uses EDI which is valid in Unreal Mode.
    
    mov edi, 0x70000
    xor eax, eax
    mov ecx, (6 * 4096) / 4    ; 6 pages (PML4, PDPT, 4*PD), 4 bytes at a time
    
    ; Address-size override prefix (0x67) for 32-bit addressing in 16-bit mode
    ; This makes REP STOSD use ECX and EDI instead of CX and DI.
    a32 rep stosd

    ; Now setup pointers using 32-bit addressing override for MOV
    
    ; PML4[0] -> PDPT at 0x71000
    ; Using a32 prefix for implicit DS:EDI addressing
    mov edi, 0x70000
    mov eax, 0x71000 | PAGE_PRESENT | PAGE_WRITABLE
    a32 mov [edi], eax
    
    ; PDPT[0] -> PD at 0x72000 (covers 0-1GB)
    mov edi, 0x71000
    mov eax, 0x72000 | PAGE_PRESENT | PAGE_WRITABLE
    a32 mov [edi], eax

    ; PDPT[1] -> PD at 0x73000 (covers 1-2GB)
    mov edi, 0x71008
    mov eax, 0x73000 | PAGE_PRESENT | PAGE_WRITABLE
    a32 mov [edi], eax

    ; PDPT[2] -> PD at 0x74000 (covers 2-3GB)
    mov edi, 0x71010
    mov eax, 0x74000 | PAGE_PRESENT | PAGE_WRITABLE
    a32 mov [edi], eax

    ; PDPT[3] -> PD at 0x75000 (covers 3-4GB)
    mov edi, 0x71018
    mov eax, 0x75000 | PAGE_PRESENT | PAGE_WRITABLE
    a32 mov [edi], eax

    ; Fill PD tables with 2MB pages
    ; Each PD has 512 entries, each mapping 2MB = total 1GB per PD
    ; 4 PDs = 4GB total coverage
    
    mov edi, 0x72000            ; Start of PD tables
    mov eax, PAGE_PRESENT | PAGE_WRITABLE | PAGE_LARGE  ; Flags for 2MB page (address starts at 0)
    mov ecx, 512 * 4            ; 2048 entries total (4 PDs x 512)

.fill_pd:
    ; Write entry (low 32 bits)
    a32 mov [edi], eax
    
    ; Write entry (high 32 bits) -> 0
    ; (No need to write high dword explicitly as we zeroed the whole block earlier!)
    ; But we need to skip 8 bytes total per entry
    
    add eax, 0x200000           ; Next 2MB page physical address
    add edi, 8                  ; Next PD entry (8 bytes each)
    dec ecx
    jnz .fill_pd

    ret
