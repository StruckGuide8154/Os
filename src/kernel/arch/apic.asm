; ============================================================================
; Grit v3.0 - Local APIC Driver
; Used for handling hardware interrupts on modern systems
; ============================================================================
bits 64

%include "constants.inc"
%include "arch_regs.inc"

section .data
global lapic_base               ; isr_ap_tick (isr.asm) EOIs through this base
lapic_base dq LAPIC_DEFAULT_BASE

section .text
; auto-wrapped (FN_BEGIN emits global): global apic_init
; auto-wrapped (FN_BEGIN emits global): global apic_eoi
; auto-wrapped (FN_BEGIN emits global): global smp_ap_startup
global apic_wake_workers
global smp_started_cores
global smp_alive_cores
global smp_parked_cores
global smp_target_cores
global smp_core_states
extern madt_enabled_cpu_count
extern madt_lapic_ids
extern smp_worker_loop          ; proc/workqueue.asm - AP job-processing loop
extern ap_long_mode_init        ; kernel/arch/apic.asm - Stage 2b ring-3 prep

; --- Initialize Local APIC ---
FN_BEGIN apic_init, 0, 0, FN_RET_SCALAR
    ; Read APIC base from MSR 0x1B
    mov ecx, 0x1B
    rdmsr                   ; EAX = low 32 bits of APIC_BASE
    
%ifndef RELEASE_BUILD
    ; Debug: Print the MSR value bits 11:8 (bit 10 is x2apic). Raw OUT, so the
    ; whole block (not just the SER glyphs) must be release-gated.
    push rax
    push rdx
    SER 'M'
    SER 'S'
    SER 'R'
    mov edx, eax
    shr edx, 8
    and dl, 0x0F            ; Bits 11:8
    add dl, '0'
    mov al, dl
    mov edx, 0x3F8
    out dx, al           ; Output bit pattern (e.g. '8'=xAPIC, 'L'=x2APIC?)
    pop rdx
    pop rax
%endif

    ; Ensure APIC is enabled (bit 11) and x2APIC is disabled (bit 10) for now
    ; to keep the MMIO-based driver working.
    and ah, 11111011b       ; Clear bit 10 (x2APIC)
    bts eax, 11
    wrmsr

    ; Map the APIC base (combine EDX:EAX, mask out lower 12 bits).
    ; APIC_BASE MSR is 64-bit; on systems with APIC base above 4 GB the high
    ; bits live in EDX. Without combining, lapic_base would be wrong.
    shl rdx, 32
    or rax, rdx
    and rax, ~0xFFF
    mov [lapic_base], rax

    ; MMIO bounds policy (security_todo.md §8): declare the LAPIC's 4 KiB
    ; register page into the kernel MMIO registry NOW, the instant its base is
    ; resolved. A hardware timer IRQ can fire between kmain's `sti` and
    ; mmio_drv_caps_init, calling apic_eoi -> mmio_bounds_assert; registering
    ; here guarantees that early EOI finds its region instead of false-panicking.
    call mmio_register_lapic

    ; Spurious Interrupt Vector Register (SIVR)
    ; Enable APIC (bit 8) and set vector to 255
    mov rdi, [lapic_base]
    add rdi, 0x0F0
    mov esi, 4
    mov edx, MMIO_DRV_LAPIC
    call mmio_bounds_assert
    mov rdi, [lapic_base]
    mov dword [rdi + 0x0F0], 0x1FF

    ; Set Task Priority Register (TPR) to 0 to enable all interrupts
    ; On many UEFI systems this is 0xFF by default, which blocks all IRQs.
    mov rdi, [lapic_base]
    add rdi, 0x080
    mov esi, 4
    mov edx, MMIO_DRV_LAPIC
    call mmio_bounds_assert
    mov rdi, [lapic_base]
    mov dword [rdi + 0x080], 0

    ret

; --- Send End of Interrupt (EOI) ---
FN_BEGIN apic_eoi, 0, 0, FN_RET_SCALAR
    ; MMIO bounds policy (security_todo.md §8): assert the EOI register write
    ; lands inside the LAPIC's registered BAR before issuing it. This is the
    ; hottest kernel-driver MMIO store (every hardware IRQ ends here), so a
    ; corrupted lapic_base scribbling kernel data is caught here, fail-closed.
    mov rdi, [lapic_base]
    add rdi, 0x0B0                       ; EOI register address
    mov esi, 4                           ; dword store
    mov edx, MMIO_DRV_LAPIC
    call mmio_bounds_assert
    mov rdi, [lapic_base]
    mov dword [rdi + 0x0B0], 0
    ret

; --- Wake idle AP workqueue workers -----------------------------------------
; Sends a fixed IPI on vector 49 to every CPU except the caller. Idle APs use
; STI;HLT, so this is enough to leave hlt and rescan the queue.
apic_wake_workers:
    push rax
    push rcx
    push rdi
    mov rdi, [lapic_base]
    mov ecx, 100000
.wait_clear:
    mov eax, [rdi + 0x300]
    test eax, 0x1000                 ; delivery status pending
    jz .send
    pause
    loop .wait_clear
.send:
    mov dword [rdi + 0x300], LAPIC_ICR_WAKE_WORKERS ; all-excluding-self, assert, vector 49
    pop rdi
    pop rcx
    pop rax
    ret

; --- Tier-2 liveness watchdog: cross-core NMI + per-AP self-wake -------------
; (feedback_no_freeze_invariant / kernel_liveness_watchdog). Policy is in
; watchdog.ghl; these are the irreducible LAPIC/MMIO primitives it calls.

; wd_send_nmi_bsp() - deliver an NMI IPI to the BSP (physical destination). An
; idle AP calls this when the BSP heartbeat has been frozen past the deadline;
; NMI is non-maskable so it lands even while the BSP holds cli. The BSP apic id
; is madt_lapic_ids[0] (the boot processor is always enumerated first).
global wd_send_nmi_bsp
wd_send_nmi_bsp:
    push rax
    push rcx
    push rdi
    mov rdi, [lapic_base]
    mov ecx, 100000                  ; bounded wait for any pending IPI to drain
.wd_nmi_wait:
    mov eax, [rdi + 0x300]
    test eax, 0x1000                 ; delivery status pending?
    jz .wd_nmi_send
    pause
    loop .wd_nmi_wait
.wd_nmi_send:
    movzx eax, byte [madt_lapic_ids] ; BSP apic id
    shl eax, 24
    mov [rdi + 0x310], eax           ; ICR high = dest << 24
    mov dword [rdi + 0x300], LAPIC_ICR_NMI_PHYS
    pop rdi
    pop rcx
    pop rax
    ret

; wd_core_index() -> eax dense core index (0 = BSP). Maps this CPU's LAPIC id to
; its slot in madt_lapic_ids; on a miss (shouldn't happen) returns 0. Used by the
; bounded-lock registry to track per-core lock ownership without a per-CPU base.
global wd_core_index
wd_core_index:
    push rcx
    push rdx
    mov rdx, [lapic_base]
    mov edx, [rdx + 0x20]            ; LAPIC ID register
    shr edx, 24                      ; this core's apic id
    xor ecx, ecx
.wd_ci_scan:
    cmp ecx, [madt_enabled_cpu_count]
    jae .wd_ci_miss
    movzx eax, byte [madt_lapic_ids + rcx]
    cmp eax, edx
    je .wd_ci_found
    inc ecx
    jmp .wd_ci_scan
.wd_ci_miss:
    xor ecx, ecx                     ; default to BSP slot
.wd_ci_found:
    mov eax, ecx
    pop rdx
    pop rcx
    ret

; wd_arm_ap_tick() - arm a one-shot LAPIC timer (vector AP_WD_TICK_VEC) so this
; idle AP self-wakes from HLT at a bounded cadence and re-runs kwd_ap_watch.
; Divide-by-128; a fixed initial count gives a sub-second period on any plausible
; bus clock - far tighter than the ~5 s stall deadline, so the exact period is
; non-critical. One-shot: the worker loop re-arms before each HLT.
global wd_arm_ap_tick
wd_arm_ap_tick:
    push rax
    push rdi
    mov rdi, [lapic_base]
    mov dword [rdi + 0x3E0], 0x0A    ; divide configuration = /128
    mov dword [rdi + 0x320], AP_WD_TICK_VEC ; LVT timer: one-shot, unmasked
    mov dword [rdi + 0x380], 0x00200000     ; initial count -> one-shot fire
    pop rdi
    pop rax
    ret

%ifdef GRIT_CACHE32_AP_STARTUP
FN_BEGIN smp_ap_startup, 0, 0, FN_RET_SCALAR
    push rbx
    push rcx
    push rsi
    push rdi
    call smp_init_states
    call smp_copy_trampoline
    mov eax, [madt_enabled_cpu_count]
    test eax, eax
    jnz .have_count
    mov eax, SMP_MAX_CORES
    jmp .have_count
    test eax, eax
    jnz .have_count
    mov eax, 1
.have_count:
    cmp eax, SMP_MAX_CORES
    jbe .target_ok
    mov eax, SMP_MAX_CORES
.target_ok:
%ifdef RELEASE_BUILD
    ; Full AP fan-out is useful for diagnostics, but release boot only needs a
    ; worker fallback to be available. Starting one AP synchronously avoids
    ; spending hundreds of milliseconds walking every enabled CPU before GUI.
    cmp eax, 2
    jae .release_have_ap
    mov eax, 1
    jmp .store_target
.release_have_ap:
    mov eax, 2
    jmp .store_target
%endif
    cmp eax, 2
    jae .store_target
    mov eax, SMP_MAX_CORES
.store_target:
    mov [smp_target_cores], eax
    cmp eax, 2
    jb .done
    mov ecx, 1
.loop:
    cmp ecx, [smp_target_cores]
    jae .done
    call smp_start_one
    inc ecx
    jmp .loop
.done:
    call smp_count_states
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

smp_init_states:
    mov rdi, smp_core_states
    mov rcx, SMP_MAX_CORES * SMP_CORE_STATE_SIZE / 8
    xor rax, rax
    rep stosq
    mov dword [abs smp_core_states], 3
    mov dword [abs smp_core_states + 4], 0
    mov rax, [abs lapic_base]
    mov eax, [rax + 0x20]
    shr eax, 24
    mov [abs smp_core_states + 8], eax
    mov qword [abs smp_core_states + 16], 1
    mov dword [abs smp_started_cores], 1
    mov dword [abs smp_alive_cores], 1
    mov dword [abs smp_parked_cores], 1
    ret

smp_copy_trampoline:
    mov rsi, ap_tramp_start
    mov rdi, SMP_TRAMPOLINE_ADDR
    mov rcx, ap_tramp_end - ap_tramp_start
    rep movsb
    wbinvd
    ret

smp_start_one:
    push rcx
    mov eax, ecx
    imul eax, SMP_CORE_STATE_SIZE
    lea rbx, [smp_core_states + rax]
    mov dword [rbx + 0], 1
    mov [rbx + 4], ecx
    cmp dword [madt_enabled_cpu_count], 2
    jb .fallback_id
    movzx eax, byte [madt_lapic_ids + rcx]
    jmp .got_id
.fallback_id:
    mov eax, ecx
.got_id:
    mov [rbx + 8], eax
    mov qword [rbx + 16], 0
    mov rax, SMP_CORE_STACK_BASE
    mov edx, ecx
    inc edx
    imul edx, SMP_CORE_STACK_SIZE
    add rax, rdx
    mov [abs SMP_TRAMPOLINE_ADDR + ap_boot_stack_ptr - ap_tramp_start], rax
    mov [abs SMP_TRAMPOLINE_ADDR + ap_boot_state_ptr - ap_tramp_start], rbx
    wbinvd
    mov rdi, [abs lapic_base]
    mov eax, [rbx + 8]
    shl eax, 24
    mov [rdi + 0x310], eax
    mov dword [rdi + 0x300], LAPIC_ICR_INIT_ASSERT
    call smp_short_delay
    mov dword [rdi + 0x300], LAPIC_ICR_INIT_DEASSERT
    call smp_short_delay
    mov dword [rdi + 0x300], LAPIC_ICR_STARTUP
    call smp_short_delay
    mov dword [rdi + 0x300], LAPIC_ICR_STARTUP
    call smp_wait_alive
    pop rcx
    ret

smp_wait_alive:
%ifdef RELEASE_BUILD
    mov edx, 50000
%else
    mov edx, 2000000
%endif
.wait:
    cmp qword [rbx + 16], 0
    jne .alive
    dec edx
    jnz .wait
    mov dword [rbx + 0], 4
    ret
.alive:
    inc dword [smp_started_cores]
    ret

smp_count_states:
    xor eax, eax
    mov [smp_alive_cores], eax
    mov [smp_parked_cores], eax
    mov ecx, 0
.count:
    cmp ecx, [smp_target_cores]
    jae .done
    mov eax, ecx
    imul eax, SMP_CORE_STATE_SIZE
    cmp dword [smp_core_states + rax], 3
    jne .next
    inc dword [smp_alive_cores]
    inc dword [smp_parked_cores]
.next:
    inc ecx
    jmp .count
.done:
    ret

smp_short_delay:
    push rcx
%ifdef RELEASE_BUILD
    mov ecx, 20000
%else
    mov ecx, 200000
%endif
.d:
    pause
    loop .d
    pop rcx
    ret

[bits 16]
ap_tramp_start:
    cli
    lgdt [dword SMP_TRAMPOLINE_ADDR + ap_gdt_ptr - ap_tramp_start]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp 0x08:(SMP_TRAMPOLINE_ADDR + ap_pm32 - ap_tramp_start)
[bits 32]
ap_pm32:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov eax, cr4
    or eax, 0x20
    mov cr4, eax
    mov eax, PAGE_TABLE_ADDR
    mov cr3, eax
    mov ecx, IA32_EFER_MSR
    rdmsr
    or eax, 0x100
    wrmsr
    mov eax, cr0
    or eax, CR0_PG
    mov cr0, eax
    jmp 0x18:(SMP_TRAMPOLINE_ADDR + ap_lm64 - ap_tramp_start)
[bits 64]
ap_lm64:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, [abs SMP_TRAMPOLINE_ADDR + ap_boot_stack_ptr - ap_tramp_start]
    mov rdi, [abs SMP_TRAMPOLINE_ADDR + ap_boot_state_ptr - ap_tramp_start]
    ; Enable SSE on this AP so offloaded compute jobs (e.g. SVG rasterisation,
    ; which is often vectorised) do not #UD: CR0.EM=0, CR0.MP=1, CR4.OSFXSR=1.
    mov rax, cr0
    and eax, ~4                 ; clear EM (bit 2)
    or eax, 2                   ; set MP (bit 1)
    mov cr0, rax
    mov rax, cr4
    or eax, 0x200               ; set OSFXSR (bit 9)
    mov cr4, rax
    inc qword [rdi + 16]        ; first liveness beat - smp_wait_alive waits on this
    mov rax, smp_ap_started_count
    lock inc dword [rax]
    mov dword [rdi + 0], 3      ; state = PARKED/available (counted by smp_count_states)
    ; --- Stage 2b: prepare this AP to handle ring 3 -------------------------
    ; ap_long_mode_init lives in the kernel image at its real address (not in
    ; the trampoline copy), so jumping to it via absolute imm64 is correct.
    ; It loads the full GDT/IDT, ltrs this core's TSS selector, and sets the
    ; SYSCALL MSRs so dispatched app code can syscall normally. RDI carries
    ; this core's index (offset 4 of the per-core state record) so the init
    ; function can pick the right TSS slot. After it returns we continue to
    ; the worker loop exactly as before.
    push rdi                     ; preserve per-core state ptr across the call
    mov edi, [rdi + 4]           ; edi = this AP's core index
    mov rax, ap_long_mode_init
    call rax
    pop rdi
    ; Hand this AP to the SMP work queue. smp_worker_loop never returns: the
    ; core now pulls compute jobs from the queue instead of sitting in HLT.
    mov rax, smp_worker_loop
    jmp rax
align 8
ap_gdt:
    dq 0
    dq GDT_DESC_CODE32
    dq GDT_DESC_DATA32
    dq GDT_DESC_CODE64
ap_gdt_ptr:
    dw ap_gdt_ptr - ap_gdt - 1
    dq SMP_TRAMPOLINE_ADDR + ap_gdt - ap_tramp_start
ap_boot_stack_ptr:
    dq 0
ap_boot_state_ptr:
    dq 0
ap_tramp_end:

; ----------------------------------------------------------------------------
; ap_long_mode_init - one-time per-AP ring-3 enablement (Stage 2b)
; ----------------------------------------------------------------------------
; Called from the AP trampoline once this CPU is in long mode with paging.
; EDI = this AP's core index (>= 1). NEVER call from the BSP - the BSP runs
; gdt64_init / idt_init / tss_init / syscall_init explicitly during kmain.
;
; Steps:
;   1. Load the kernel's full GDT (gdt64_ptr) so ring-3 selectors and the
;      per-core TSS descriptor are visible to this CPU.
;   2. Reload segment registers from the new GDT. Kernel selectors are at
;      the same indices as the trampoline GDT (CS=0x08, DS=0x10) so this is
;      defensive rather than strictly required, but doing it explicitly
;      flushes the descriptor cache to the new GDT contents.
;   3. Load the kernel IDT (idt_ptr). APs do NOT service hardware IRQs (the
;      I/O APIC routes those to the BSP), but they MUST have an IDT loaded
;      so a CPU exception in ring 3 (e.g. #PF from a buggy callback) lands
;      in the kernel handler instead of triple-faulting.
;   4. Set up this AP's TSS via tss_init_for_core(idx). Each AP needs its
;      own TSS so its TSS.RSP0 is a private kernel stack - without that,
;      two cores taking exceptions simultaneously would clobber each other.
;   5. Program the SYSCALL MSRs (EFER.SCE, STAR, LSTAR, FMASK) on this CPU
;      via syscall_init_this_cpu. Each core has its own copy of these MSRs.
;
; Preserves no caller-visible registers; the trampoline saves/restores its
; bookkeeping (RDI = per-core state ptr) around the call.
; ----------------------------------------------------------------------------
%ifdef GRIT_CACHE32_AP_STARTUP
extern gdt64_ptr
extern idt_ptr
extern tss_init_for_core
extern syscall_init_this_cpu

global ap_long_mode_init
ap_long_mode_init:
    push rax
    push rcx
    push rdi
    mov ecx, edi                      ; save core index across the GDT load
    ; --- 0. Sanitize CR4 to match what the UEFI loader did for the BSP. ---
    ; UEFI may leave SMEP / SMAP / PCIDE / LA57 / PKE set when it hands off,
    ; and the trampoline only forced PAE on. With SMAP enabled in particular,
    ; the first time call_app_l3 writes the slot's shadow-window page from
    ; kernel mode the AP page-faults (kernel touching a USER-bit page) and
    ; without a recoverable #PF handler the AP triple-faults silently. This
    ; mirrors the sanitisation in src/boot/uefi_loader.asm.
    mov rax, cr4
    btr rax, 7                        ; PGE   off
    btr rax, 12                       ; LA57  off
    btr rax, 17                       ; PCIDE off
    btr rax, 20                       ; SMEP  off
    btr rax, 21                       ; SMAP  off
    btr rax, 22                       ; PKE   off
    bts rax, 5                        ; PAE   on
    bts rax, 9                        ; OSFXSR on
    bts rax, 10                       ; OSXMMEXCPT on
    mov cr4, rax
    ; EFER: enable NXE so kernel page tables with the NX bit are accepted.
    push rdx
    mov ecx, IA32_EFER_MSR
    rdmsr
    bts eax, 11                       ; NXE on
    wrmsr
    ; IA32_PAT: write the canonical Linux layout (slot 0=WB, slot 1=WC, ...)
    ; so the FB leaf PTE patched by fbperf_wc_activate is interpreted as WC
    ; on every core, not just the BSP. Each logical CPU has its own PAT MSR;
    ; APs come out of reset with the architectural default (slot 1 = WT),
    ; which would degrade any AP-side FB access to write-through. Slot 0=WB
    ; matches the default so this is safe to write before BSP has activated.
    mov ecx, IA32_PAT_MSR
    mov eax, IA32_PAT_CANONICAL_LO
    mov edx, IA32_PAT_CANONICAL_HI
    wrmsr
    pop rdx
    mov ecx, edi                      ; restore core index in ecx
    ; --- 1. Load the kernel GDT ---
    lea rax, [rel gdt64_ptr]
    lgdt [rax]
    ; --- 2. Reload segment registers from the new GDT ---
    mov ax, 0x10                      ; kernel data selector
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    ; Reload CS via push/retfq.
    lea rax, [rel .reloaded]
    push qword 0x08                   ; kernel code selector
    push rax
    retfq
.reloaded:
    ; --- 3. Load the kernel IDT ---
    lea rax, [rel idt_ptr]
    lidt [rax]
    ; --- 4. Per-core TSS ---
    mov edi, ecx
    call tss_init_for_core
    ; --- 5. SYSCALL MSRs on this CPU ---
    call syscall_init_this_cpu
    ; Let this AP receive workqueue wake IPIs while halted in the idle path.
    mov rdi, [lapic_base]
    mov dword [rdi + 0x0F0], 0x1FF
    mov dword [rdi + 0x080], 0
    pop rdi
    pop rcx
    pop rax
    ret
%endif

%else
smp_ap_startup:
    ret
%endif

section .data
align 64
smp_core_states: equ SMP_CORE_STATE_ADDR
smp_target_cores: dd SMP_MAX_CORES
smp_started_cores: dd 1
smp_alive_cores: dd 1
smp_parked_cores: dd 1
smp_ap_started_count: dd 0
