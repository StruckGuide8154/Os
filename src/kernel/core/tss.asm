; ============================================================================
; GritOS v3.0 - Task State Segment (64-bit)
; ============================================================================
bits 64

%include "constants.inc"

section .data
global tss64
align 16
tss64:
    dd 0            ; Reserved
tss64_rsp0:
    dq 0x200000     ; RSP0 fallback until tss_init installs the dedicated stack.
    dq 0            ; RSP1
    dq 0            ; RSP2
    dq 0            ; Reserved
    dq 0            ; IST1
    dq 0            ; IST2
    dq 0            ; IST3
    dq 0            ; IST4
    dq 0            ; IST5
    dq 0            ; IST6
    dq 0            ; IST7
    dq 0            ; Reserved
    dw 0            ; Reserved
    dw 104          ; I/O Map Base Address (points outside TSS = no I/O map)

section .text

; --- Initialize TSS in GDT and load it ---
global tss_init
tss_init:
    push rax
    push rbx
    push rdi

    lea rax, [rel tss_rsp0_stack_end]
    mov [rel tss64_rsp0], rax

    ; Get TSS address
    lea rax, [tss64]
    
    ; Find the TSS descriptor in GDT - read actual GDT base from GDTR
    sub rsp, 16
    sgdt [rsp]              ; store GDTR: [0-1]=limit, [2-9]=base
    mov rdi, [rsp + 2]      ; RDI = actual GDT base address
    add rsp, 16
    add rdi, 0x30           ; TSS descriptor at offset 0x30

    ; Fill TSS Descriptor (16 bytes)
    ; [0-1] Limit[15:0] = 103 (already set in gdt.asm)
    ; [2-3] Base[15:0]
    mov [rdi + 2], ax
    shr rax, 16
    ; [4] Base[23:16]
    mov [rdi + 4], al
    ; [5] Access: 0x89 (already set)
    ; [6] Flags + Limit High (already set)
    ; [7] Base[31:24]
    shr rax, 8
    mov [rdi + 7], al
    ; [8-11] Base[63:32]
    shr rax, 8
    mov [rdi + 8], eax
    ; [12-15] Reserved (0)

    ; Load TR register
    mov ax, 0x30            ; TSS Selector (Index 6 * 8)
    ltr ax

    pop rdi
    pop rbx
    pop rax
    ret

; ============================================================================
; Per-AP TSS infrastructure (Stage 2b)
; ----------------------------------------------------------------------------
; Every core that may enter ring 3 needs its own TSS so that a CPU exception
; while ring 3 is running can land on a clean ring-0 stack via TSS.RSP0
; (without this, an AP that takes a #PF in user code triple-faults). We pre-
; allocate (SMP_MAX_CORES - 1) AP TSS structures and matching RSP0 stacks;
; tss_init_for_core(idx) is called by an AP during long-mode init to:
;   1. patch the AP's TSS slot in the GDT (selector 0x30 + idx*16),
;   2. point that TSS's RSP0 at the AP's dedicated kernel stack,
;   3. ltr the AP-specific selector so the CPU register binds correctly.
;
; The BSP keeps using the legacy tss64 + selector 0x30; tss_init unchanged.
; ============================================================================

section .bss
alignb 16
tss_rsp0_stack:
    resb 16384
tss_rsp0_stack_end:

alignb 16
; Per-AP TSS structures. Each is 104 bytes per the SDM; we round to 112 for
; alignment. Slot N is used by AP with core index (N + 1) - slot 0 here is
; the AP whose core index is 1 (the first AP after the BSP).
ap_tss_pool:
    resb 112 * (SMP_MAX_CORES - 1 + 1)   ; +1 keeps NASM happy when MAX=1

alignb 16
; Per-AP RSP0 stacks. 16 KB each, mirroring the BSP's tss_rsp0_stack.
ap_rsp0_stacks:
    resb 16384 * (SMP_MAX_CORES - 1 + 1)

section .text

; --- tss_init_for_core --------------------------------------------------------
; Input:  EDI = core index (>= 1; core 0 is the BSP and uses tss_init)
; Effect: fills this AP's TSS, patches its GDT descriptor, and loads TR.
;
; Safe to call after gdt64_init has run on this core (so the GDT is loaded).
; Idempotent per core.
global tss_init_for_core
tss_init_for_core:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    ; idx-1 indexes into our AP pools (BSP isn't pooled).
    mov ecx, edi
    dec ecx                            ; ecx = AP slot

    ; Compute this AP's TSS base in ap_tss_pool.
    mov eax, ecx
    imul rax, 112
    lea rbx, [rel ap_tss_pool]
    add rbx, rax                       ; rbx = TSS structure
    ; Zero the structure.
    mov rdi, rbx
    push rcx
    mov ecx, 112 / 8
    xor eax, eax
    rep stosq
    pop rcx

    ; Compute this AP's RSP0 stack top.
    mov eax, ecx
    imul rax, 16384
    lea rsi, [rel ap_rsp0_stacks]
    add rsi, rax
    add rsi, 16384                     ; rsi = stack top (one past end)
    and rsi, -16

    ; Fill TSS.RSP0 at offset 4 of the TSS.
    mov [rbx + 4], rsi

    ; I/O-map base outside the TSS = no I/O permission map.
    mov word [rbx + 102], 104

    ; Patch the TSS descriptor for this core in the GDT.
    ; Selector for core N = 0x30 + (N - 1 + 1) * 16 = 0x30 + N * 16.
    ; The first AP slot (gdt64_tss_ap[0]) holds the descriptor for core 1.
    sub rsp, 16
    sgdt [rsp]
    mov rdi, [rsp + 2]                 ; GDT base
    add rsp, 16
    mov eax, ecx                       ; eax = AP slot index
    inc eax                            ; eax = core index
    imul rax, 16
    add rdi, 0x30
    add rdi, rax                       ; rdi = AP's TSS descriptor in GDT

    ; Wipe the slot first (it may still be the zero placeholder from gdt.asm).
    mov qword [rdi + 0], 0
    mov qword [rdi + 8], 0

    ; [0-1] Limit[15:0] = 103
    mov word [rdi + 0], 103
    ; [2-3] Base[15:0]
    mov rax, rbx
    mov [rdi + 2], ax
    ; [4] Base[23:16]
    shr rax, 16
    mov [rdi + 4], al
    ; [5] Access = 0x89 (Present, TSS Available)
    mov byte [rdi + 5], 0x89
    ; [6] Flags + Limit High = 0
    mov byte [rdi + 6], 0
    ; [7] Base[31:24]
    shr rax, 8
    mov [rdi + 7], al
    ; [8-11] Base[63:32]
    shr rax, 8
    mov [rdi + 8], eax

    ; Load TR with this core's selector.
    mov eax, ecx
    inc eax                            ; core index
    imul eax, 16
    add eax, 0x30
    ltr ax

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
