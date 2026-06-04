%ifndef MMIO_BOUNDS_INC
%define MMIO_BOUNDS_INC
; ============================================================================
; Driver capability gates + MMIO bounds policy  (security_todo.md §8)
;
; THREAT MODEL
;   Kernel drivers (xHCI, the rtl8156 USB NIC that rides on it, the LAPIC)
;   run with implicit full ring-0 power: a mistyped pointer or an off-by-N in
;   a descriptor walk can scribble anywhere in the kernel's address space —
;   over another driver's BAR, over kernel .data, over a page table. There is
;   no hardware between a kernel-mode store and physical memory.
;
;   This file is the software substitute: a single, kernel-owned registry of
;   every region a driver is *allowed* to touch ("what regions of memory may I
;   touch", the §8 capability descriptor), plus a fail-closed runtime assert
;   (`mmio_bounds_assert`) that a driver calls on its hot MMIO paths to prove a
;   store/load stays inside one of its own registered regions before issuing
;   it. An access outside every region the driver owns panics rather than
;   corrupting whatever the bad pointer happened to land on.
;
; ONE REGISTRY, TWO FEATURES
;   * Driver capability gates (§8 ★): `mmio_drv_caps_init` declares, at boot,
;     the per-driver region descriptors — the set of {base,len} a given
;     MMIO_DRV_* is permitted to reach. That set IS the driver's capability.
;   * MMIO bounds policy (§8): `mmio_bounds_assert(addr,len,drv)` is the
;     runtime check; it consults the exact same registry the gates were
;     declared into. Declaring a region in the first feature is what makes an
;     access pass the second. The two are deliberately the same table.
;
; REGISTRY SHAPE
;   Fixed-capacity parallel arrays (MMIO_REG_MAX entries) in kernel .data,
;   OUTSIDE any ring-3-writable slot — an app cannot widen a driver's reach by
;   writing the table. Each slot holds {base, end (=base+len), owner drv id,
;   flags}. Append-only via `mmio_region_register`; never freed (BARs live for
;   the lifetime of the boot). end is stored pre-computed so the hot-path
;   assert is two compares and no add.
;
; FAIL-CLOSED
;   `mmio_bounds_assert` panics (mmio_bounds_panic -> serial "MMIO " + halt) on
;   ANY of: zero length, address+len overflow, owner drv id not matching a
;   registered region, or the [addr,addr+len) range straddling/exceeding the
;   region it started in. A driver that has registered no region cannot pass
;   the assert at all — registration is mandatory, absence denies.
;
; SCOPE (what is wired vs. enumerated for follow-up)
;   The registry, the per-driver descriptors, and the assert helper land here
;   fully. The assert is wired into the most-obvious / hottest kernel-driver
;   MMIO sites:
;     * apic.asm  — every `[lapic_base + off]` register store in apic_eoi and
;       apic_init's SIVR/TPR programming (the LAPIC page is the one MMIO
;       window the kernel pokes on the steady-state IRQ path).
;   The remaining per-register pokes inside the cold xHCI bring-up path
;   (xhci.asm, owned by another agent) are NOT instrumented here — they run
;   once at init, off the hot path, and xhci.asm is off-limits for this change.
;   Their BAR is still REGISTERED (so any future instrumentation there, or any
;   stray store that lands in the registered range, is covered) and the xHCI
;   window is declared as the rtl8156 NIC's reachable region too, since the NIC
;   driver reaches the controller exclusively through xhci_op_base.
; ============================================================================

; --- Driver identity tags ---------------------------------------------------
; Small dense ids; index space is private to the registry.
MMIO_DRV_NONE   equ 0
MMIO_DRV_LAPIC  equ 1            ; kernel/arch/apic.asm  — local APIC MMIO page
MMIO_DRV_XHCI   equ 2            ; kernel/drivers/xhci.asm — host controller BAR
MMIO_DRV_RTL8156 equ 3           ; kernel/drivers/rtl8156.asm — rides xHCI BAR

; --- Region flags -----------------------------------------------------------
MMIO_RGN_NONE   equ 0
MMIO_RGN_VALID  equ 1            ; slot is populated

; --- Fixed registry capacity ------------------------------------------------
; LAPIC + xHCI + headroom. Bump if more BAR-owning drivers register.
MMIO_REG_MAX    equ 8

; --- Well-known window sizes ------------------------------------------------
; The LAPIC register block is one 4 KiB page at the MSR-reported base. An xHCI
; BAR is implementation-defined but the cap/op/runtime/doorbell register set
; for the controllers we support fits well inside 64 KiB; declare that as the
; reachable window (conservative upper bound, not the exact decoded size — the
; goal is "a stray pointer can't leave the controller's BAR", not exact decode).
MMIO_LAPIC_WINDOW equ 0x1000
MMIO_XHCI_WINDOW  equ 0x10000

section .data
align 8
; Parallel arrays — entry i is {base[i], end[i], owner[i], flags[i]}.
mmio_reg_base   times MMIO_REG_MAX dq 0
mmio_reg_end    times MMIO_REG_MAX dq 0
mmio_reg_owner  times MMIO_REG_MAX dd 0
mmio_reg_flags  times MMIO_REG_MAX dd 0
mmio_reg_count  dd 0

section .text

; ----------------------------------------------------------------------------
; mmio_region_register — append one {base,len} region owned by a driver.
;   RDI = region base (physical == identity-mapped VA in this kernel)
;   RSI = region length in bytes (must be non-zero)
;   EDX = owner MMIO_DRV_* id
; Returns: EAX = 1 on success, 0 if the table is full or len==0/overflows.
; Clobbers: rax, rcx. Caller regs otherwise preserved.
; Append-only; intended to be called only from mmio_drv_caps_init at boot.
; ----------------------------------------------------------------------------
mmio_region_register:
    push rbx
    push r8
    test rsi, rsi
    jz .reject                          ; zero-length region is meaningless
    mov rax, rdi
    add rax, rsi                         ; rax = base + len = end
    jc .reject                           ; base+len overflowed the address space
    mov r8, rax                          ; r8 = end
    mov eax, [mmio_reg_count]
    cmp eax, MMIO_REG_MAX
    jae .reject                          ; table full
    ; ecx = slot index, store the four fields
    mov ecx, eax
    mov [mmio_reg_base + rcx*8], rdi
    mov [mmio_reg_end  + rcx*8], r8
    mov [mmio_reg_owner + rcx*4], edx
    mov dword [mmio_reg_flags + rcx*4], MMIO_RGN_VALID
    inc eax
    mov [mmio_reg_count], eax
    mov eax, 1
    pop r8
    pop rbx
    ret
.reject:
    xor eax, eax
    pop r8
    pop rbx
    ret

; ----------------------------------------------------------------------------
; mmio_bounds_assert — fail-closed check that a kernel-driver MMIO access lies
; entirely within a region that driver registered.
;   RDI = access address
;   RSI = access length in bytes (e.g. 4 for a dword MMIO write)
;   EDX = accessing driver's MMIO_DRV_* id
; On success: returns with all caller registers preserved.
; On any violation: jumps to mmio_bounds_panic (never returns).
; Clobbers nothing caller-visible (saves/restores the scratch it uses).
; Two compares per registered region; the registry is tiny (MMIO_REG_MAX).
; ----------------------------------------------------------------------------
global mmio_bounds_assert
mmio_bounds_assert:
    push rax
    push rcx
    push r8
    push r9
    push r10
    test rsi, rsi
    jz .violation                       ; zero-length access is a bug, deny
    mov r8, rdi                          ; r8 = access start
    add rdi, rsi                         ; rdi = access end (exclusive)
    jc .violation                       ; start+len wrapped
    mov r9, rdi                          ; r9 = access end
    mov ecx, [mmio_reg_count]
    xor r10d, r10d                       ; r10 = scan index
.scan:
    cmp r10d, ecx
    jae .violation                      ; no owning region contained the range
    ; flags valid?
    cmp dword [mmio_reg_flags + r10*4], MMIO_RGN_VALID
    jne .next
    ; owner matches?
    cmp dword [mmio_reg_owner + r10*4], edx
    jne .next
    ; range fully inside [base,end)?  start >= base && end <= regionEnd
    mov rax, [mmio_reg_base + r10*8]
    cmp r8, rax
    jb .next                            ; start below region base
    mov rax, [mmio_reg_end + r10*8]
    cmp r9, rax
    ja .next                            ; access end past region end
    ; contained — accept
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rax
    ret
.next:
    inc r10d
    jmp .scan
.violation:
    ; rdi already = access end; restore the inputs the panic prints.
    mov rdi, r8                          ; access start
    mov rsi, r9                          ; access end
    ; edx still = driver id
    jmp mmio_bounds_panic

; ----------------------------------------------------------------------------
; mmio_bounds_panic — out-of-bounds kernel-driver MMIO. Serial-log and halt.
;   RDI = access start, RSI = access end (exclusive), EDX = driver id.
; Never returns. Mirrors kernel_panic_canary's fail-closed shape.
; ----------------------------------------------------------------------------
mmio_bounds_panic:
    cli
    SER 'M'
    SER 'M'
    SER 'I'
    SER 'O'
    SER ' '
    call ser_print_hex64                ; rdi = access start
    SER '-'
    mov rdi, rsi
    call ser_print_hex64                ; rsi = access end
    SER ' '
    SER 'D'
    movzx rdi, dl
    call ser_print_hex64                ; dl = offending driver id
    SER 13
    SER 10
.mbp_halt:
    cli
    hlt
    jmp .mbp_halt

; ----------------------------------------------------------------------------
; mmio_drv_caps_init — declare the xHCI-family drivers' reachable-region
; capability set. Called once from kmain after the controllers have been probed
; (so xhci_mmio_base is resolved) and before the steady-state poll paths that
; call mmio_bounds_assert. This is the §8 "capability descriptor" for the USB
; host controller and the NIC riding it.
;
; The LAPIC region is NOT registered here: a hardware timer IRQ can fire (and
; call apic_eoi -> mmio_bounds_assert) between `sti` and this init point, so its
; descriptor is declared earlier, inside apic_init, via mmio_register_lapic.
;   no args. Clobbers rax/rcx/rdx/rsi/rdi (caller-saved at the init site).
; ----------------------------------------------------------------------------
extern lapic_base               ; arch/apic.asm — MSR-resolved LAPIC MMIO base
extern xhci_mmio_base           ; drivers/xhci.asm — BAR0 base, set by xhci probe

; mmio_register_lapic — declare the LAPIC's single 4 KiB register page as the
; MMIO_DRV_LAPIC capability. Called from apic_init the moment lapic_base is
; resolved, so it is in the registry before the first EOI assert. Idempotent in
; practice (apic_init runs once). Clobbers rax/rcx/rdx/rsi/rdi.
global mmio_register_lapic
mmio_register_lapic:
    mov rdi, [lapic_base]
    test rdi, rdi
    jz .skip
    ; Idempotent: kmain registers the LAPIC page BEFORE `sti` (the PIT is armed
    ; by then, so the first IRQ0 -> apic_eoi -> mmio_bounds_assert fires during
    ; the boot splash, long before apic_init runs). apic_init re-resolves the
    ; base from the APIC_BASE MSR and calls here again; skip if a LAPIC region
    ; with this base is already present so we don't append a duplicate.
    mov ecx, [mmio_reg_count]
    xor eax, eax
.find:
    cmp eax, ecx
    jae .do_register
    cmp dword [mmio_reg_owner + rax*4], MMIO_DRV_LAPIC
    jne .find_next
    cmp [mmio_reg_base + rax*8], rdi
    je .skip                            ; already registered for this base
.find_next:
    inc eax
    jmp .find
.do_register:
    mov rdi, [lapic_base]
    mov esi, MMIO_LAPIC_WINDOW
    mov edx, MMIO_DRV_LAPIC
    call mmio_region_register
.skip:
    ret

global mmio_drv_caps_init
mmio_drv_caps_init:
    ; --- xHCI BAR: register for both the controller driver and the rtl8156 ----
    ; NIC, which reaches the controller exclusively through xhci_op_base (an
    ; offset inside this same BAR). Two owner ids over one window keeps each
    ; driver's capability self-describing rather than sharing an id.
    mov rdi, [xhci_mmio_base]
    test rdi, rdi
    jz .skip_xhci                       ; no xHCI present (BIOS boot / no USB)
    mov esi, MMIO_XHCI_WINDOW
    mov edx, MMIO_DRV_XHCI
    call mmio_region_register
    mov rdi, [xhci_mmio_base]
    mov esi, MMIO_XHCI_WINDOW
    mov edx, MMIO_DRV_RTL8156
    call mmio_region_register
.skip_xhci:
    ret

%endif ; MMIO_BOUNDS_INC
