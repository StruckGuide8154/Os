; ============================================================================
; NexusOS v3.0 - Physical Page Allocator
; Bitmap-based, 4KB pages, initialized from E820 memory map
; ============================================================================
bits 64

%include "constants.inc"

section .text

; --- Initialize page allocator from E820 map ---
global memory_init
memory_init:
    push rbx
    push r12
    push r13
    push r14

    ; Clear the entire bitmap (mark all pages as USED initially)
    mov rdi, PAGE_BITMAP_ADDR
    mov al, 0xFF             ; All bits set = all pages used
    mov rcx, 0x100000        ; 1MB of bitmap = covers 32GB of RAM
    rep stosb


    test r12, r12
    jz .done

.entry_loop:
    ; Read entry
    mov rax, [r13]            ; Base address
    mov rbx, [r13 + 8]       ; Length
    mov ecx, [r13 + 16]      ; Type

    ; Only process type 1 (usable memory)
    cmp ecx, 1
    jne .next_entry

    ; Skip memory below 1MB (reserved for boot structures)
    cmp rax, 0x100000
    jge .process_range
    ; Adjust: if range extends above 1MB, clip it
    mov rdx, rax
    add rdx, rbx             ; End address
    cmp rdx, 0x100000
    jle .next_entry
    ; Clip start to 1MB
    sub rdx, 0x100000
    mov rbx, rdx             ; New length
    mov rax, 0x100000        ; New base

.process_range:
    ; Skip pages used by kernel and system structures (below 0xD00000)
    cmp rax, 0xD00000
    jge .mark_free
    mov rdx, rax
    add rdx, rbx
    cmp rdx, 0xD00000
    jle .next_entry
    ; Clip
    sub rdx, 0xD00000
    mov rbx, rdx
    mov rax, 0xD00000

.mark_free:
    ; Mark pages in this range as free
    ; RAX = base (page-aligned), RBX = length
    shr rax, 12              ; Convert to page number
    mov rdx, rbx
    shr rdx, 12              ; Convert to page count
    test rdx, rdx
    jz .next_entry

.free_loop:
    ; Clear bit in bitmap to mark page as free
    mov rcx, rax
    shr rcx, 3               ; Byte index (saved in RCX)
    mov r14, rax
    and r14, 7               ; Bit index (in R14)
    push rcx                 ; Save byte index
    mov r8b, 1
    mov cl, r14b             ; Shift count
    shl r8b, cl
    not r8b
    pop rcx                  ; Restore byte index
    and [PAGE_BITMAP_ADDR + rcx], r8b

    inc rax                  ; Next page
    dec rdx
    jnz .free_loop

    ; Note: free_page_count is recounted properly in count_free_pages below

.next_entry:
    add r13, 24              ; Next E820 entry (24 bytes each)
    dec r12
    jnz .entry_loop

.done:
    ; Recount free pages properly
    call count_free_pages

    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --- Allocate one physical page ---
; Returns: RAX = physical address of 4KB page, or 0 if out of memory
global page_alloc
page_alloc:
    push rbx
    push rcx
    push rdx

    ; Scan bitmap for first free bit (0 = free)
    mov rdi, PAGE_BITMAP_ADDR
    mov rcx, 0x100000        ; Bitmap size in bytes

.scan:
    cmp byte [rdi], 0xFF     ; All used?
    jne .found_byte
    inc rdi
    dec rcx
    jnz .scan
    ; Out of memory
    xor rax, rax
    jmp .alloc_done

.found_byte:
    ; Find which bit is 0 in this byte
    mov al, [rdi]
    mov rbx, rdi
    sub rbx, PAGE_BITMAP_ADDR  ; Byte offset
    shl rbx, 3                 ; * 8 = base page number for this byte

    xor ecx, ecx
.find_bit:
    bt eax, ecx
    jnc .got_bit
    inc ecx
    cmp ecx, 8
    jl .find_bit
    ; Shouldn't reach here
    xor rax, rax
    jmp .alloc_done

.got_bit:
    ; Mark as used
    bts dword [rdi], ecx

    ; Calculate physical address
    add rbx, rcx              ; Page number
    shl rbx, 12               ; * 4096 = physical address
    mov rax, rbx

    dec qword [free_page_count]

.alloc_done:
    pop rdx
    pop rcx
    pop rbx
    ret

; --- Free a physical page ---
; RDI = physical address
global page_free
page_free:
    push rax
    push rcx

    shr rdi, 12              ; Convert to page number
    mov rax, rdi
    shr rax, 3               ; Byte index
    mov rcx, rdi
    and rcx, 7               ; Bit index

    ; Clear the bit (mark as free)
    ; RAX = byte index, CL = bit index (from and rcx, 7 above)
    mov r8b, 1
    shl r8b, cl
    not r8b
    and [PAGE_BITMAP_ADDR + rax], r8b

    inc qword [free_page_count]

    pop rcx
    pop rax
    ret

; --- Count free pages ---
count_free_pages:
    push rbx
    push rcx

    xor rax, rax             ; Counter
    mov rdi, PAGE_BITMAP_ADDR
    mov rcx, 0x100000        ; Bitmap bytes

.count_loop:
    mov bl, [rdi]
    not bl                   ; Invert: 1 = free
    ; Count set bits (popcount)
    xor edx, edx
.popcount:
    test bl, bl
    jz .next_byte
    mov r8b, bl
    dec r8b
    and bl, r8b              ; Clear lowest set bit
    inc rax
    jmp .popcount

.next_byte:
    inc rdi
    dec rcx
    jnz .count_loop

    mov [free_page_count], rax

    pop rcx
    pop rbx
    ret

; --- Get free page count ---
global memory_get_free
memory_get_free:
    mov rax, [free_page_count]
    ret

section .data
global free_page_count
free_page_count: dq 0
