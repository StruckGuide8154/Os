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
extern tick_count               ; core/pit.asm - PIT tick (100Hz, 10ms/tick); used
                                ; for real-time bounded delays in AP bring-up
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
    ; ---- Batched parallel bring-up (was: serial per-AP INIT-SIPI-SIPI+wait) --
    ; The old path called smp_start_one in a loop: each AP paid its own 3 inter-
    ; IPI delays AND a full alive-wait before the next AP was even touched, so
    ; the ~10 ms INIT delay + wait was multiplied by the core count (the bulk of
    ; the ~600 ms L0 stage under TCG). We now drive the canonical INIT-SIPI-SIPI
    ; as three batched phases: assert/deassert/SIPI are issued to every target AP
    ; back-to-back, and the mandatory inter-phase delays (10 ms after INIT, ~200 us
    ; after SIPI #1) are paid ONCE for the whole fan-out. All APs then come up in
    ; parallel and we wait on the aggregate started-count once. Targeted physical
    ; destination (not an all-excluding-self broadcast) so RELEASE_BUILD's "start
    ; exactly one AP" intent is preserved. Trampoline self-identifies by APIC id,
    ; so the BSP no longer pre-stages per-AP stack/state pointers.
    mov rdi, [lapic_base]
    ; Phase 1: INIT assert to every target AP.
    mov ecx, 1
.p1:
    cmp ecx, [smp_target_cores]
    jae .p1_done
    call smp_apicid_for          ; ecx -> eax = target apic id
    mov r8d, eax
    mov r9d, LAPIC_ICR_INIT_ASSERT
    call smp_send_ipi
    inc ecx
    jmp .p1
.p1_done:
    mov edx, 2                   ; >=10 ms: wait two PIT edges (10 ms/tick)
    call smp_wait_pit_edges
    ; Phase 2: INIT de-assert + STARTUP (SIPI #1) to every target AP.
    mov ecx, 1
.p2:
    cmp ecx, [smp_target_cores]
    jae .p2_done
    call smp_apicid_for
    mov r8d, eax
    mov r9d, LAPIC_ICR_INIT_DEASSERT
    call smp_send_ipi
    mov r9d, LAPIC_ICR_STARTUP
    call smp_send_ipi
    inc ecx
    jmp .p2
.p2_done:
    call smp_short_delay         ; ~200 us inter-SIPI gap (paid once)
    ; Phase 3: STARTUP (SIPI #2) to every target AP. Per the Intel algorithm a
    ; second SIPI is sent in case an AP missed the first; modern parts/QEMU
    ; usually start on #1, so most APs are already live and ignore this.
    mov ecx, 1
.p3:
    cmp ecx, [smp_target_cores]
    jae .p3_done
    call smp_apicid_for
    mov r8d, eax
    mov r9d, LAPIC_ICR_STARTUP
    call smp_send_ipi
    inc ecx
    jmp .p3
.p3_done:
    call smp_wait_all_alive      ; single bounded wait for the whole fan-out
    ; Reflect the check-in count in smp_started_cores (was incremented per-AP by
    ; the removed smp_wait_alive). +1 for the BSP. alive/parked are recomputed
    ; authoritatively by smp_count_states below from the per-core state records.
    mov eax, [smp_ap_started_count]
    inc eax
    mov [smp_started_cores], eax
.done:
    call smp_count_states
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; smp_apicid_for(ecx=dense core index) -> eax = target APIC id. Mirrors the old
; smp_start_one mapping: madt_lapic_ids[idx] when a MADT is present, else the
; index itself (contiguous-id fallback for MADT-less boots).
smp_apicid_for:
    cmp dword [abs madt_enabled_cpu_count], 2
    jb .aif_fallback
    movzx eax, byte [madt_lapic_ids + rcx]
    ret
.aif_fallback:
    mov eax, ecx
    ret

; smp_send_ipi(rdi=lapic_base, r8d=apic id, r9d=ICR-low command). Waits (bounded)
; for any in-flight IPI to drain, programs ICR-high with the physical destination,
; then writes ICR-low to fire. Clobbers eax only.
smp_send_ipi:
    push rcx
    mov ecx, 0x100000            ; bounded delivery-status drain
.si_wait:
    mov eax, [rdi + 0x300]
    test eax, 0x1000             ; delivery status pending?
    jz .si_go
    pause
    dec ecx
    jnz .si_wait
.si_go:
    mov eax, r8d
    shl eax, 24
    mov [rdi + 0x310], eax       ; ICR high = dest apic id << 24
    mov [rdi + 0x300], r9d       ; ICR low = command (fires the IPI)
    pop rcx
    ret

; smp_wait_pit_edges(edx = number of PIT tick edges to wait, ~10 ms each).
; Real-time delay off the already-running PIT (sti ran at K8, before this).
; A pause-loop safety cap guarantees forward progress even if the PIT were
; wedged, so a stuck timer can never hang boot here.
smp_wait_pit_edges:
    push rax
    push r8
    push r9
    mov r8, [tick_count]
    mov r9d, edx                 ; zero-extends edx into r9
    add r8, r9                   ; target tick
    mov r9, 0x4000000            ; safety cap
.wpe:
    mov rax, [tick_count]
    cmp rax, r8
    jae .wpe_done
    pause
    dec r9
    jnz .wpe
.wpe_done:
    pop r9
    pop r8
    pop rax
    ret

; smp_wait_all_alive - wait until every target AP has checked in
; (smp_ap_started_count >= target-1) OR a generous PIT-edge timeout elapses, then
; return. Bounded + fail-soft: a no-show AP is simply not counted by the
; subsequent smp_count_states, exactly as the old per-AP timeout behaved, but the
; whole fan-out is awaited ONCE in parallel instead of serially.
smp_wait_all_alive:
    push rax
    push rcx
    push r8
    push r9
    mov ecx, [smp_target_cores]
    dec ecx                      ; expected AP count = target - 1
    mov r8, [tick_count]
    add r8, 30                   ; ~300 ms aggregate timeout
    mov r9, 0x8000000            ; pause-loop safety cap (wedged-PIT guard)
.waa:
    mov eax, [smp_ap_started_count]
    cmp eax, ecx
    jae .waa_done
    mov rax, [tick_count]
    cmp rax, r8
    jae .waa_done
    pause
    dec r9
    jnz .waa
.waa_done:
    pop r9
    pop r8
    pop rcx
    pop rax
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
    mov dword [abs smp_ap_started_count], 0  ; APs lock-inc this as they check in
    ret

smp_copy_trampoline:
    mov rsi, ap_tramp_start
    mov rdi, SMP_TRAMPOLINE_ADDR
    mov rcx, ap_tramp_end - ap_tramp_start
    rep movsb
    wbinvd
    ret

; (smp_start_one / smp_wait_alive removed: the serial per-AP INIT-SIPI-SIPI+wait
; was replaced by the batched parallel phases in smp_ap_startup above, and the AP
; trampoline now self-identifies by APIC id rather than reading a BSP-staged
; per-AP stack/state pointer.)

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
    ; --- Self-identify: APIC id -> dense core index --------------------------
    ; The BSP no longer stages this AP's stack/state pointer (that only worked
    ; when APs were started one at a time). With the batched parallel bring-up,
    ; several APs execute this trampoline concurrently, so each one must derive
    ; its OWN identity. Read this core's APIC id and map it to its dense index
    ; via madt_lapic_ids - the exact mapping the BSP used and that wd_core_index
    ; relies on - then compute its private stack and per-core state record. An
    ; AP that is not in the target set (or that wrongly resolves to index 0, the
    ; BSP slot) parks rather than scribbling on another core's state: a spurious
    ; or injected SIPI cannot hijack a live slot.
    ; KASLR-safe addressing: this is the trampoline COPY running at the low fixed
    ; SMP_TRAMPOLINE_ADDR, so RIP-relative is wrong; relocated kernel symbols
    ; (madt_*, lapic_base, smp_*) are loaded as imm64 addresses into a register
    ; first (the KASLR relocator fixes up those imm64s) then dereffed - the same
    ; pattern the original trampoline used for smp_ap_started_count. smp_core_states
    ; and the SMP_* sizes are fixed low equ constants and are used directly.
    ; Read this core's APIC id via CPUID.1:EBX[31:24], NOT the LAPIC MMIO ID
    ; register: the boot page tables (CR3 here) do not map the LAPIC MMIO page
    ; (0xFEE00xxx) until mmio_register_lapic runs later, and the AP has no IDT
    ; yet, so an MMIO read here #PFs straight into a triple fault. The CPUID
    ; initial APIC id equals the LAPIC ID register value and madt_lapic_ids[]
    ; for xAPIC, so the mapping below is identical to wd_core_index's.
    mov eax, 1
    cpuid
    shr ebx, 24
    mov esi, ebx                   ; esi = this core's APIC id
    mov r8, smp_target_cores       ; &smp_target_cores (relocated)
    mov r9, madt_enabled_cpu_count ; &madt_enabled_cpu_count (relocated)
    mov r10, madt_lapic_ids        ; &madt_lapic_ids[0] (relocated)
    xor ecx, ecx                   ; index scan cursor
.ap_id_scan:
    cmp ecx, [r8]                  ; smp_target_cores
    jae .ap_park                   ; not a targeted core -> park
    cmp dword [r9], 2
    jb .ap_id_fallback             ; MADT-less: id == index (contiguous fallback)
    movzx eax, byte [r10 + rcx]
    jmp .ap_id_cmp
.ap_id_fallback:
    mov eax, ecx
.ap_id_cmp:
    cmp eax, esi
    je .ap_id_found
    inc ecx
    jmp .ap_id_scan
.ap_id_found:
    test ecx, ecx
    jz .ap_park                    ; index 0 is the BSP - an AP must never claim it
    ; private stack = SMP_CORE_STACK_BASE + (index+1)*SMP_CORE_STACK_SIZE
    mov eax, ecx
    inc eax
    imul eax, eax, SMP_CORE_STACK_SIZE
    mov rsp, SMP_CORE_STACK_BASE
    add rsp, rax
    ; per-core state record = smp_core_states + index*SMP_CORE_STATE_SIZE
    mov eax, ecx
    imul eax, eax, SMP_CORE_STATE_SIZE
    mov rdi, smp_core_states
    add rdi, rax
    mov [rdi + 4], ecx             ; record dense core index (read back below)
    mov [rdi + 8], esi             ; record APIC id
    ; Enable SSE on this AP so offloaded compute jobs (e.g. SVG rasterisation,
    ; which is often vectorised) do not #UD: CR0.EM=0, CR0.MP=1, CR4.OSFXSR=1.
    mov rax, cr0
    and eax, ~4                 ; clear EM (bit 2)
    or eax, 2                   ; set MP (bit 1)
    mov cr0, rax
    mov rax, cr4
    or eax, 0x200               ; set OSFXSR (bit 9)
    mov cr4, rax
    inc qword [rdi + 16]        ; first liveness beat
    mov rax, smp_ap_started_count
    lock inc dword [rax]        ; aggregate check-in; smp_wait_all_alive waits on this
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
.ap_park:
    ; Untargeted / unidentifiable AP (spurious or injected SIPI, or a core
    ; outside the started set): halt safely without touching any core's state.
    cli
.ap_park_hlt:
    hlt
    jmp .ap_park_hlt
align 8
ap_gdt:
    dq 0
    dq GDT_DESC_CODE32
    dq GDT_DESC_DATA32
    dq GDT_DESC_CODE64
ap_gdt_ptr:
    dw ap_gdt_ptr - ap_gdt - 1
    dq SMP_TRAMPOLINE_ADDR + ap_gdt - ap_tramp_start
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
    ; --- 0. Sanitize CR4 to a known-clean base, then re-derive SMEP/SMAP. ---
    ; UEFI may leave SMEP / SMAP / PCIDE / LA57 / PKE set when it hands off,
    ; and the trampoline only forced PAE on. We start from a clean CR4 (clear
    ; the inherited bits) and then, under ENABLE_SMAP, re-enable SMEP/SMAP per
    ; CPUID exactly as the BSP's smap_smep_init does. This MUST be symmetric
    ; with the BSP: every worker AP runs ring-3 callbacks (smp_worker_loop ->
    ; cb_run_guarded -> call_app_l3), so leaving SMEP/SMAP off here would let a
    ; callback execute on a core with the kernel/user boundary hardening
    ; disabled - a confused-deputy / ret2usr hole the BSP does not have.
    ; The historical reason this code disabled SMAP (call_app_l3's shadow-window
    ; write #PF'ing a USER page from kernel mode) is gone: l3_prepare_callback
    ; now brackets every user write with smap_open/smap_close (stac/clac), so
    ; SMAP no longer faults the AP. mirrors src/boot/uefi_loader.asm + smap.inc.
    mov rax, cr4
    btr rax, 7                        ; PGE   off
    btr rax, 12                       ; LA57  off
    btr rax, 17                       ; PCIDE off
    btr rax, 20                       ; SMEP  off (re-derived from CPUID below)
    btr rax, 21                       ; SMAP  off (re-derived from CPUID below)
    btr rax, 22                       ; PKE   off
    bts rax, 5                        ; PAE   on
    bts rax, 9                        ; OSFXSR on
    bts rax, 10                       ; OSXMMEXCPT on
%ifdef ENABLE_SMAP
    ; CPUID.(7,0).EBX: SMEP = bit 7 -> CR4 bit 20, SMAP = bit 20 -> CR4 bit 21.
    ; Only set the bits this part actually advertises so non-SMAP silicon still
    ; boots. rax carries the CR4 image being built; preserve it across cpuid.
    push rax
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov ecx, ebx                      ; stash feature bits (clobbered registers)
    pop rax
    bt  ecx, 7
    jnc .ap_no_smep
    bts rax, 20                       ; CR4.SMEP
.ap_no_smep:
    bt  ecx, 20
    jnc .ap_no_smap
    bts rax, 21                       ; CR4.SMAP
.ap_no_smap:
%endif
    mov cr4, rax
%ifdef ENABLE_SMAP
    ; Arm SMAP with AC clear so any later stray kernel user-deref on this core
    ; faults until a stac bracket opens the window (matches smap_smep_init's
    ; closing clac on the BSP).
    clac
%endif
    ; CR0.WP: enforce supervisor write-protect on this core (security fix #2).
    ; CR0.WP makes ring-0 honor read-only PTEs - it is the mechanism behind
    ; kernel_lockdown_ro (.text RO) and nk_protect_page_tables (page tables RO).
    ; WP is PER-CORE: the BSP sets it at lockdown via nk_engage_wp, but APs come
    ; out of the trampoline with WP=0 (the UEFI loader cleared it to write the
    ; firmware-RO 0x100000). Without this, a kernel write primitive running on a
    ; worker AP (which the AP DOES run: render/callback jobs) bypasses both the
    ; RO .text lockdown and the nested-kernel page-table protection. Arm it now,
    ; before the BSP's later lockdown marks those pages RO. APs never legitimately
    ; write .text or page tables (the nk WP-toggle window is BSP-only), so WP=1
    ; here is purely protective and cannot fault the AP's own job path.
    mov rax, cr0
    bts rax, 16                       ; CR0.WP
    mov cr0, rax
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
    ; Read PAT back and record it in this AP's per-core state slot (offset 24,
    ; AP_STATE_OFF_PAT) so the BSP can emit it after startup and a test can
    ; assert every core agrees on the WC layout. ecx still = IA32_PAT_MSR.
    rdmsr                             ; edx:eax = this CPU's live PAT
    push rbx
    mov ebx, edi                      ; edi = this AP's core index (preserved)
    imul ebx, ebx, SMP_CORE_STATE_SIZE
    lea rcx, [smp_core_states + rbx]   ; smp_core_states is an absolute equ
    mov [rcx + AP_STATE_OFF_PAT],     eax
    mov [rcx + AP_STATE_OFF_PAT + 4], edx
    pop rbx
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
