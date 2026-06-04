; ============================================================================
; NexusOS v3.0 - Read-only kernel after init (security_todo.md §9)
; ----------------------------------------------------------------------------
; After kernel_main finishes setup, mark the kernel's executable image
; read-only at the page-table level so any kernel-side self-modification
; (a rogue write into .text, a code-patching exploit primitive) page-faults
; instead of succeeding.
;
; LAYOUT (see kernel_build.asm): NASM `-f bin` concatenates section content as
; [.text | .data | .rodata | .bss]. The executable image is therefore exactly
; [_start .. _kernel_text_end). Writable globals (.data) live PAST that label,
; so locking the .text span never faults a legitimate global write. (.rodata,
; which sits after .data, is left writable here: it cannot be isolated from
; .data at page granularity without 4 KiB-splitting the straddling boundary,
; which the flat-bin layout doesn't page-align. Scoping to .text covers the
; self-modifying-code threat this TODO targets.)
;
; PAGE GRANULARITY: the boot page tables (paging.asm / uefi setup_paging) map
; the low region with 2 MiB large pages in PD0. We clear the WRITABLE (RW, bit
; 1) bit on every 2 MiB PDE FULLY contained in [_start, _kernel_text_end).
; The two partial edges (the 2 MiB page holding _start, and the one holding
; _kernel_text_end) stay writable: the first also covers sub-1MB boot scratch,
; the last also covers the start of .data. So this protects the bulk interior
; of kernel .text — the large, gadget-rich body — while never locking a page
; that also backs writable data.
;
; CR0.WP: the UEFI loader cleared CR0.WP (to write the firmware-RO 0x100000),
; and the kernel never re-set it, so today a supervisor write ignores the RW
; bit entirely. This routine SETS CR0.WP so the cleared RW bits actually trap
; ring-0 writes. Safe because the only kernel pages that become read-only are
; the ones cleared here; every other kernel PDE stays WRITABLE.
;
; One-shot + idempotent (kl_done guard). Called from kmain at the very end of
; init, just before the main loop.
; ============================================================================
bits 64

%include "constants.inc"      ; PAGE_TABLE_ADDR, KERNEL_LOAD_ADDR
%include "trace.inc"

PAGE_WRITABLE_BIT equ 1       ; RW = bit 1 in a PDE/PTE
PDE_2MB           equ 0x200000

extern _start
extern _kernel_text_end
; Nested-kernel monitor (nk_monitor.asm): the ONLY WP-toggle site. Lockdown is
; the monitor's first client — it brackets its .text PDE edits in a window and
; relies on nk_pt_window_end to set CR0.WP for the first time + flush the TLB.
extern nk_pt_window_begin
extern nk_pt_window_end
extern nk_engage_wp

section .text

; ----------------------------------------------------------------------------
; kernel_lockdown_ro - clear RW on every 2 MiB PDE fully inside kernel .text,
; then enable CR0.WP. Flushes the TLB so the protection is live on return.
; ----------------------------------------------------------------------------
FN_BEGIN kernel_lockdown_ro, 0, 0, FN_RET_VOID
    cmp byte [rel kl_done], 0
    jne .ret
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    ; Open the monitor window: masks interrupts and clears CR0.WP so the PDE
    ; edits below are permitted (and, post-Phase-2, so they're permitted even
    ; once the page tables are mapped read-only). nk_pt_window_end re-arms WP.
    call nk_pt_window_begin

    ; Compute the 2 MiB-aligned interior [lo, hi) of the .text span:
    ;   lo = round_up(_start, 2MiB)
    ;   hi = round_down(_kernel_text_end, 2MiB)
    lea rax, [rel _start]
    add rax, PDE_2MB - 1
    and rax, ~(PDE_2MB - 1)
    mov rsi, rax                         ; rsi = lo (first fully-covered 2MiB base)

    lea rax, [rel _kernel_text_end]
    and rax, ~(PDE_2MB - 1)
    mov rdi, rax                         ; rdi = hi (exclusive 2MiB boundary)

    cmp rsi, rdi
    jae .apply_wp                        ; nothing fully enclosed (tiny image)

    ; Walk CR3 -> PML4[0] -> PDPT[0] -> PD0 base (follow pointers; base differs
    ; between BIOS and UEFI paging). Kernel .text is well under 1 GiB even when
    ; KASLR-slid, so every covered PDE lives in PD0 (PDPT[0]).
    mov rbx, PAGE_TABLE_ADDR             ; CR3 / PML4 physical base
    mov r8, [rbx]                        ; PML4[0]
    and r8, ~0xFFF
    mov r9, [r8]                         ; PDPT[0]
    and r9, ~0xFFF                       ; r9 = PD0 physical base

.pde_loop:
    cmp rsi, rdi
    jae .apply_wp
    ; pde_idx = (2MiB base) >> 21
    mov rax, rsi
    shr rax, 21
    cmp rax, 512
    jae .next_pde                        ; defensive: outside PD0
    ; Only clear RW on a PRESENT large (PS) page — leave anything unexpected
    ; (e.g. a PDE already split to a 4 KiB PT) untouched.
    mov rdx, [r9 + rax*8]
    test rdx, 0x01                       ; PRESENT?
    jz .next_pde
    test rdx, 0x80                       ; PS (2 MiB large page)?
    jz .next_pde
    and rdx, ~PAGE_WRITABLE_BIT          ; clear RW -> read-only
    mov [r9 + rax*8], rdx
.next_pde:
    add rsi, PDE_2MB
    jmp .pde_loop

.apply_wp:
    ; Close the monitor window (restores pre-window WP=0 + flush + IF), then
    ; perform the deliberate one-time WP off->on engage so supervisor writes now
    ; honor the read-only .text PDEs cleared above. Both WP toggles live in the
    ; monitor (nk_monitor.asm) — this routine never touches CR0 directly.
    call nk_pt_window_end
    call nk_engage_wp

    mov byte [rel kl_done], 1

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.ret:
    FN_END kernel_lockdown_ro
    ret

section .bss
kl_done: resb 1
