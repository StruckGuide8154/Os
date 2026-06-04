; ============================================================================
; NexusOS — Nested-Kernel Memory Monitor (portable, MMU + CR0.WP based)
; ----------------------------------------------------------------------------
; security_todo.md — "intra-kernel privilege separation without CPU lock-in."
;
; GOAL
;   Make the page tables tamper-resistant *from the kernel itself*, using only
;   mechanisms every 64-bit x86 has (paging + CR0.WP) — no CET, no VT-x, and
;   fully emulated by QEMU TCG. This is the Nested-Kernel design
;   (Dautenhahn et al., ASPLOS'15): a tiny audited "monitor" is the ONLY code
;   permitted to mutate page tables. The page-table pages are mapped read-only
;   (nk_protect_page_tables, Phase 2), so any *other* write to a PTE/PDE — a
;   stray overflow, a type confusion, a ROP chain trying to clear W^X or remap
;   .text — faults instead of succeeding. Enforcement is the MMU (per-access,
;   in hardware, zero hot-path cost); the monitor only runs on the rare
;   mapping-change path.
;
; THE WINDOW
;   Every legitimate page-table writer brackets its edits:
;       call nk_pt_window_begin     ; WP off — page tables writable
;       ... edit PTEs/PDEs ...
;       call nk_pt_window_end        ; WP on, TLB flushed, IF restored
;   With CR0.WP cleared inside the window, supervisor writes ignore the RW=0
;   bit and so can edit the (otherwise read-only) page tables. Outside the
;   window WP is set, so the same store faults. The ONLY `mov cr0` that toggles
;   WP in the post-init kernel lives in this file — that is the auditable TCB
;   boundary (see Phase 3 audit).
;
; PRESERVE, DON'T ASSUME
;   The window is opened both BEFORE the one-time WP engage (l3_install_syscall
;   _stack_pt runs during early init while CR0.WP is still 0) and AFTER it
;   (app-switch, SYS_MPROTECT_WX). So the window SAVES and RESTORES the prior
;   CR0.WP state rather than unconditionally setting it — early writers stay at
;   WP=0, post-engage writers return to WP=1, and neither path changes WP
;   timing. The deliberate one-time off->on transition is a separate primitive,
;   nk_engage_wp, called once by kernel_lockdown_ro. Both still live here, so
;   this file remains the single auditable home of every WP toggle.
;
; INTERRUPT FLAG
;   The window masks interrupts (cli) so no IRQ handler runs while WP is off.
;   It is opened from two kinds of context: with IF set (kmain init,
;   app-switch) and with IF clear (SYS_MPROTECT_WX runs in syscall context with
;   IF masked by FMASK). So `begin` SAVES the caller's IF and `end` restores it
;   conditionally — an unconditional sti would wrongly enable interrupts inside
;   a syscall.
;
; ASSUMPTIONS / SCOPE (v1)
;   * Windows do NOT nest. A writer brackets a tight PTE loop and never calls
;     another bracketed writer inside the window. (Asserted by inspection; the
;     saved-IF byte below is single-slot.)
;   * SMP: the saved-IF byte is global, not per-CPU. The existing PTE writers
;     already mutate the one shared PML4 without cross-core locking, so this is
;     no worse than the status quo; per-CPU/locked windowing is a Phase 3
;     follow-up. The protection itself (RO page tables + WP) is per-core: each
;     core runs with its own CR0.WP=1.
; ============================================================================
bits 64

%include "macros.inc"           ; FN_BEGIN / FN_END (via trace.inc) + SER
%include "boot_memory.inc"      ; PAGE_TABLE_ADDR, SYSCALL_STACK_PT_BASE

CR0_WP_BIT          equ 16      ; CR0.WP — when set, supervisor honors RW=0
NK_PAGE_WRITABLE    equ (1 << 1); RW bit in a PTE/PDE

; Physical extent of the page-table region to self-protect (Phase 2). The
; loader lays the tables out contiguously: PML4 0x70000, PDPT0 0x71000,
; PDPT1 0x72000, PD0 0x73000, PT0 0x74000, app PTs 0x75000..0x80FFF, and the
; syscall-stack PT at SYSCALL_STACK_PT_BASE (0x82000). [LO, HI) is exclusive.
NK_PT_REGION_LO     equ PAGE_TABLE_ADDR              ; 0x70000
NK_PT_REGION_HI     equ (SYSCALL_STACK_PT_BASE + 0x1000)  ; 0x83000

section .text

; ----------------------------------------------------------------------------
; nk_pt_window_begin — open a page-table edit window.
;   Saves the caller's IF and the current CR0.WP, masks interrupts, and clears
;   CR0.WP so the (read-only-mapped, post-Phase-2) page tables become writable
;   for the duration of the window. Preserves all registers and arithmetic
;   flags. Pairs 1:1 with nk_pt_window_end.
; ----------------------------------------------------------------------------
FN_BEGIN nk_pt_window_begin, 0, 0, FN_RET_VOID
    push rax
    push rdx
    ; Snapshot the caller's IF (RFLAGS bit 9) before masking.
    pushfq
    pop rax
    shr rax, 9
    and al, 1
    mov [rel nk_window_saved_if], al
    cli
    ; Snapshot the current CR0.WP, then clear it. Supervisor writes now ignore
    ; RW=0, so the page tables are editable for the window's duration.
    mov rax, cr0
    xor edx, edx
    bt  rax, CR0_WP_BIT
    setc dl
    mov [rel nk_window_saved_wp], dl
    btr rax, CR0_WP_BIT
    mov cr0, rax
    pop rdx
    pop rax
    FN_END nk_pt_window_begin
    ret

; ----------------------------------------------------------------------------
; nk_pt_window_end — close the window.
;   Restores CR0.WP to its pre-window state, flushes the TLB (so freshly-edited
;   PTEs are live), and restores the caller's interrupt flag. Preserves all
;   registers.
; ----------------------------------------------------------------------------
FN_BEGIN nk_pt_window_end, 0, 0, FN_RET_VOID
    push rax
    ; Restore WP to whatever it was on entry (set it only if it was set).
    mov rax, cr0
    cmp byte [rel nk_window_saved_wp], 0
    je .wp_done
    bts rax, CR0_WP_BIT
.wp_done:
    mov cr0, rax
    ; Flush the TLB so any PTE/PDE edited in the window takes effect now.
    mov rax, cr3
    mov cr3, rax
    pop rax
    ; Restore the caller's IF: sti only if it was set on entry. Done last so
    ; the cli..sti span exactly brackets the WP-off window.
    cmp byte [rel nk_window_saved_if], 0
    je .done
    sti
.done:
    FN_END nk_pt_window_end
    ret

; ----------------------------------------------------------------------------
; nk_engage_wp — the deliberate one-time CR0.WP off->on transition.
;   Called once by kernel_lockdown_ro after it has marked .text read-only, to
;   make supervisor writes start honoring RW=0 for the rest of the kernel's
;   life. Flushes the TLB. Preserves all registers. Kept here so EVERY CR0.WP
;   mutation in the post-boot kernel lives in this one file.
; ----------------------------------------------------------------------------
FN_BEGIN nk_engage_wp, 0, 0, FN_RET_VOID
    push rax
    mov rax, cr0
    bts rax, CR0_WP_BIT
    mov cr0, rax
    mov rax, cr3
    mov cr3, rax
    pop rax
    FN_END nk_engage_wp
    ret

; ----------------------------------------------------------------------------
; nk_protect_page_tables — Phase 2: map the page-table region itself read-only.
;   Walks CR3 -> PML4[0] -> PDPT0[0] -> PD0[0] -> PT0 (the 4 KiB table the
;   loader installs over physical 0..2 MiB) and clears RW on every PT0 entry
;   that maps a page in [NK_PT_REGION_LO, NK_PT_REGION_HI) — that range is
;   exactly the PML4/PDPTs/PD0/PT0/app-PTs/syscall-PT pages. After this, with
;   CR0.WP set, ANY page-table write from outside an nk_pt_window faults, so the
;   only code that can mutate a mapping is the audited monitor. Idempotent.
;
;   Runs inside its own window so it can edit PT0 — including PT0's own entry,
;   which it makes read-only (self-protecting). Called once from kmain right
;   after kernel_lockdown_ro has engaged CR0.WP. Bails (leaving tables
;   unprotected) if PD0[0] is a 2 MiB large page, i.e. there is no 4 KiB PT0 to
;   walk — that only happens if the boot paging layout changed out from under us.
;   Clobbers nothing (saves/restores rax-rdx).
; ----------------------------------------------------------------------------
FN_BEGIN nk_protect_page_tables, 0, 0, FN_RET_VOID
    cmp byte [rel nk_pt_protected], 0
    jne .npt_ret
    push rax
    push rbx
    push rcx
    push rdx
    ; Walk to PT0's physical base (reads — no window needed yet).
    mov rax, PAGE_TABLE_ADDR         ; PML4 phys (== CR3 base)
    mov rax, [rax]                   ; PML4[0]
    and rax, ~0xFFF                  ; -> next-level phys base (no NX set on these branch entries)
    mov rax, [rax]                   ; PDPT0[0]
    and rax, ~0xFFF                  ; -> next-level phys base (no NX set on these branch entries)
    mov rax, [rax]                   ; PD0[0]
    test rax, 0x80                   ; PS=1 -> 2 MiB large page, no PT0
    jnz .npt_bail
    and rax, ~0xFFF                  ; -> next-level phys base (no NX set on these branch entries)            ; rax = PT0 physical base
    mov rbx, rax

    call nk_pt_window_begin          ; WP off — PT0 (and itself) become editable
    mov rcx, NK_PT_REGION_LO >> 12   ; first PT0 index that maps the PT region
    mov rdx, NK_PT_REGION_HI >> 12   ; one past the last (exclusive)
.npt_loop:
    cmp rcx, rdx
    jae .npt_done
    mov rax, [rbx + rcx*8]
    test al, 1                       ; PRESENT? (skip any unexpected hole)
    jz .npt_skip
    btr rax, 1                       ; clear RW -> read-only
    mov [rbx + rcx*8], rax
.npt_skip:
    inc rcx
    jmp .npt_loop
.npt_done:
    call nk_pt_window_end            ; restore WP=1 + flush; page tables now RO
    mov byte [rel nk_pt_protected], 1
    SER 'N'
    SER 'K'
    SER 'P'
    SER '+'
    jmp .npt_pop
.npt_bail:
    ; No 4 KiB PT0 — cannot protect at page granularity. Leave WP/tables as-is
    ; and flag it on the debug serial so the regression is visible.
    SER 'N'
    SER 'K'
    SER 'P'
    SER '!'
.npt_pop:
    pop rdx
    pop rcx
    pop rbx
    pop rax
.npt_ret:
    FN_END nk_protect_page_tables
    ret

section .bss
nk_window_saved_if: resb 1      ; caller IF captured by _begin, consumed by _end
nk_window_saved_wp: resb 1      ; caller CR0.WP captured by _begin, restored by _end
nk_pt_protected:    resb 1      ; set once nk_protect_page_tables has run
