; ---------------------------------------------------------------------------
; fbperf_init -- one-time. Reads CPUID/CR0/CR3/CR4, PAT, MTRR registers,
; walks the framebuffer's mapping, and computes a WC reprogram plan.
; ---------------------------------------------------------------------------
fbperf_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11

%ifdef RELEASE_BUILD
    ; Release boot only needs the WC plan and clean counters. The full CPUID /
    ; MSR / MTRR / page-table diagnostic snapshot is preserved for debug builds
    ; and for SYS_SYSINFO-triggered investigation, but it is not part of the
    ; visible desktop boot path.
    mov  dword [fbperf_wc_plan_pat],     0x00070106
    mov  dword [fbperf_wc_plan_pat + 4], 0x00070106
    mov  qword [fbperf_flips_total], 0
    mov  qword [fbperf_full_flips], 0
    mov  qword [fbperf_rect_flips], 0
    mov  qword [fbperf_bytes_total], 0
    mov  qword [fbperf_full_bytes], 0
    mov  qword [fbperf_rect_bytes], 0
    mov  qword [fbperf_tsc_total], 0
    mov  qword [fbperf_tsc_min], 0
    mov  qword [fbperf_tsc_max], 0
    mov  qword [fbperf_tsc_last], 0
    mov  qword [fbperf_dirty_rect_sum], 0
    mov  qword [fbperf_tsc_at_begin], 0
    cmp  byte [fbperf_init_done], 0
    jne  .release_skip_wc_clear
    mov  byte [fbperf_wc_armed], 0
    mov  byte [fbperf_wc_activated], 0
.release_skip_wc_clear:
    mov  byte [fbperf_init_done], 1
    pop  r11
    pop  r10
    pop  r9
    pop  r8
    pop  rsi
    pop  rdi
    pop  rdx
    pop  rcx
    pop  rbx
    pop  rax
    ret
%endif

    ; --- CPUID.01H -> EDX bit12=MTRR, bit16=PAT ---
    mov  eax, 1
    xor  ecx, ecx
    cpuid
    xor  eax, eax
    test edx, 1 << 16
    jz   .no_pat
    mov  eax, 1
.no_pat:
    mov  [fbperf_cpuid_pat_supported], eax
    xor  eax, eax
    test edx, 1 << 12
    jz   .no_mtrr_flag
    mov  eax, 1
.no_mtrr_flag:
    mov  [fbperf_cpuid_mtrr_supported], eax

    ; --- Control regs (always safe) ---
    mov  rax, cr0
    mov  [fbperf_cr0], rax
    mov  rax, cr3
    mov  [fbperf_cr3], rax
    mov  rax, cr4
    mov  [fbperf_cr4], rax

    ; --- IA32_PAT (MSR 0x277) - only if CPUID says PAT supported ---
    cmp  dword [fbperf_cpuid_pat_supported], 0
    je   .skip_pat_read
    mov  ecx, 0x277
    rdmsr
    mov  [fbperf_pat_msr],     eax
    mov  [fbperf_pat_msr + 4], edx
.skip_pat_read:

    ; --- IA32_MTRRCAP (0xFE) - only if CPUID says MTRR supported ---
    cmp  dword [fbperf_cpuid_mtrr_supported], 0
    je   .skip_mtrr_read
    mov  ecx, 0xFE
    rdmsr
    mov  [fbperf_mtrrcap], eax
    and  eax, 0xFF
    mov  [fbperf_mtrr_var_count], eax

    ; --- IA32_MTRR_DEF_TYPE (0x2FF) ---
    mov  ecx, 0x2FF
    rdmsr
    mov  [fbperf_mtrr_def_type], eax
    jmp  .have_mtrr
.skip_mtrr_read:
    mov  dword [fbperf_mtrr_var_count], 0
.have_mtrr:

    ; --- Variable MTRRs (0x200..0x200+2*N-1) ---
    mov  r10d, [fbperf_mtrr_var_count]
    cmp  r10d, FBPERF_MAX_VAR_MTRR
    jbe  .var_count_ok
    mov  r10d, FBPERF_MAX_VAR_MTRR
.var_count_ok:
    xor  r11d, r11d
.var_loop:
    cmp  r11d, r10d
    jge  .var_done
    ; ecx = 0x200 + r11*2 (base MSR for variable MTRR pair)
    mov  ecx, 0x200
    mov  ebx, r11d
    shl  ebx, 1
    add  ecx, ebx
    rdmsr                           ; eax:edx = base
    mov  ebx, r11d
    shl  ebx, 4                     ; *16 bytes per entry
    lea  rdi, [rel fbperf_mtrr_var]
    mov  [rdi + rbx],     eax
    mov  [rdi + rbx + 4], edx
    ; Mask MSR is base+1
    mov  ecx, 0x200
    mov  ebx, r11d
    shl  ebx, 1
    add  ecx, ebx
    inc  ecx
    rdmsr
    mov  ebx, r11d
    shl  ebx, 4
    lea  rdi, [rel fbperf_mtrr_var]
    mov  [rdi + rbx + 8],  eax
    mov  [rdi + rbx + 12], edx
    inc  r11d
    jmp  .var_loop
.var_done:

    ; --- Walk page tables for fb_addr ---
    mov  rsi, [fb_addr]
    mov  [fbperf_walk_addr], rsi
    call fbperf_walk_pt              ; fills fb_pte_value, fb_pte_level, fb_caching_type

    ; --- Compute WC reprogram plan ---
    ; New PAT MSR: keep slots 0..6 as default, set slot 7 to WC (0x01).
    ; Default reset PAT is 0007040600070406 (slots: 6,4,7,0,6,4,7,0). We
    ; instead build the canonical "Linux" PAT used by every modern kernel:
    ;   slot 0 = WB   (0x06)
    ;   slot 1 = WC   (0x01)
    ;   slot 2 = UC-  (0x07)
    ;   slot 3 = UC   (0x00)
    ;   slot 4 = WB   (0x06)
    ;   slot 5 = WC   (0x01)
    ;   slot 6 = UC-  (0x07)
    ;   slot 7 = UC   (0x00)
    ; That makes (PWT=1,PCD=0,PAT=0) -> WC, which is the bit pattern we can
    ; safely set on the FB PDE/PTE without touching PCD/PWT semantics for
    ; the rest of the address space.
    mov  dword [fbperf_wc_plan_pat],     0x00070106
    mov  dword [fbperf_wc_plan_pat + 4], 0x00070106

    ; --- Zero perf counters & WC flags. BSS is not guaranteed cleared on real
    ; AMD hardware (QEMU happens to zero it; UEFI firmware doesn't always), so
    ; without this explicit clear, flips_total / tsc_total / wc_armed pick up
    ; random RAM contents and every measurement is unreadable garbage.
    mov  qword [fbperf_flips_total], 0
    mov  qword [fbperf_full_flips], 0
    mov  qword [fbperf_rect_flips], 0
    mov  qword [fbperf_bytes_total], 0
    mov  qword [fbperf_full_bytes], 0
    mov  qword [fbperf_rect_bytes], 0
    mov  qword [fbperf_tsc_total], 0
    mov  qword [fbperf_tsc_min], 0
    mov  qword [fbperf_tsc_max], 0
    mov  qword [fbperf_tsc_last], 0
    mov  qword [fbperf_dirty_rect_sum], 0
    mov  qword [fbperf_tsc_at_begin], 0
    ; Zero WC tracking flags ONLY on the very first init -- this routine is
    ; also called for a "refresh" snapshot after fbperf_wc_activate has set
    ; the flags, so unconditional zeroing would wipe the activated=1 signal.
    cmp  byte [fbperf_init_done], 0
    jne  .skip_wc_clear
    mov  byte [fbperf_wc_armed], 0
    mov  byte [fbperf_wc_activated], 0
.skip_wc_clear:

    mov  byte  [fbperf_init_done], 1

    pop  r11
    pop  r10
    pop  r9
    pop  r8
    pop  rsi
    pop  rdi
    pop  rdx
    pop  rcx
    pop  rbx
    pop  rax
    ret

; ---------------------------------------------------------------------------
; fbperf_walk_pt -- walk page tables for [fbperf_walk_addr].
; Stores: fb_pte_value, fb_pte_level (4..1), fb_caching_type (0..7).
; Levels: 4 = walk failed at PML4, 3 = leaf at PDPT (1GB), 2 = leaf at PD (2MB),
;         1 = leaf at PT (4KB), 0 = not present.
; Caching: derived from PAT/PCD/PWT bits per the PAT-enabled rules.
; ---------------------------------------------------------------------------
fbperf_walk_pt:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov  qword [fbperf_fb_pte_value], 0
    mov  dword [fbperf_fb_pte_level], 0
    mov  dword [fbperf_fb_caching_type], 0xFF

    mov  rsi, [fbperf_walk_addr]
    test rsi, rsi
    jz   .done

    ; CR3 base (mask off low 12 PCID/flags bits)
    mov  rax, cr3
    mov  rcx, 0x000FFFFFFFFFF000
    and  rax, rcx
    mov  rbx, rax                  ; rbx = PML4 phys/identity-mapped

    ; PML4 index = (addr >> 39) & 0x1FF
    mov  rax, rsi
    shr  rax, 39
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    mov  [fbperf_pml4e], rdi
    test rdi, 1                    ; Present?
    jz   .level4_miss
    test rdi, 1 << 7               ; PS? (PML4 should never have PS=1)
    jnz  .leaf_pml4

    mov  rbx, rdi
    mov  r8, 0x000FFFFFFFFFF000
    and  rbx, r8

    ; PDPT index
    mov  rax, rsi
    shr  rax, 30
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    mov  [fbperf_pdpte], rdi
    test rdi, 1
    jz   .level3_miss
    test rdi, 1 << 7
    jnz  .leaf_pdpt

    mov  rbx, rdi
    mov  r8, 0x000FFFFFFFFFF000
    and  rbx, r8

    ; PD index
    mov  rax, rsi
    shr  rax, 21
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    mov  [fbperf_pde], rdi
    test rdi, 1
    jz   .level2_miss
    test rdi, 1 << 7
    jnz  .leaf_pd

    mov  rbx, rdi
    mov  r8, 0x000FFFFFFFFFF000
    and  rbx, r8

    ; PT index
    mov  rax, rsi
    shr  rax, 12
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    mov  [fbperf_pte], rdi
    test rdi, 1
    jz   .level1_miss
    ; Leaf at PT level. PAT bit = bit 7.
    mov  dword [fbperf_fb_pte_level], 1
    mov  [fbperf_fb_pte_value], rdi
    ; PAT bit at 7, PCD at 4, PWT at 3
    mov  rax, rdi
    mov  rcx, rax
    shr  rcx, 7
    and  rcx, 1                    ; PAT
    shl  rcx, 2
    mov  rdx, rax
    shr  rdx, 4
    and  rdx, 1                    ; PCD
    shl  rdx, 1
    or   rcx, rdx
    mov  rdx, rax
    shr  rdx, 3
    and  rdx, 1                    ; PWT
    or   rcx, rdx
    call fbperf_decode_caching
    jmp  .done

.leaf_pdpt:
    mov  dword [fbperf_fb_pte_level], 3
    mov  [fbperf_fb_pte_value], rdi
    ; PS=1 leaf: PAT bit moves to bit 12 (since lower 30 bits are page offset)
    mov  rax, rdi
    mov  rcx, rax
    shr  rcx, 12
    and  rcx, 1                    ; PAT
    shl  rcx, 2
    mov  rdx, rax
    shr  rdx, 4
    and  rdx, 1
    shl  rdx, 1
    or   rcx, rdx
    mov  rdx, rax
    shr  rdx, 3
    and  rdx, 1
    or   rcx, rdx
    call fbperf_decode_caching
    jmp  .done

.leaf_pd:
    mov  dword [fbperf_fb_pte_level], 2
    mov  [fbperf_fb_pte_value], rdi
    ; PS=1 PD leaf: PAT at bit 12
    mov  rax, rdi
    mov  rcx, rax
    shr  rcx, 12
    and  rcx, 1
    shl  rcx, 2
    mov  rdx, rax
    shr  rdx, 4
    and  rdx, 1
    shl  rdx, 1
    or   rcx, rdx
    mov  rdx, rax
    shr  rdx, 3
    and  rdx, 1
    or   rcx, rdx
    call fbperf_decode_caching
    jmp  .done

.leaf_pml4:
    mov  dword [fbperf_fb_pte_level], 4
    mov  [fbperf_fb_pte_value], rdi
    jmp  .done
.level4_miss:
    mov  dword [fbperf_fb_pte_level], 40
    jmp  .done
.level3_miss:
    mov  dword [fbperf_fb_pte_level], 30
    jmp  .done
.level2_miss:
    mov  dword [fbperf_fb_pte_level], 20
    jmp  .done
.level1_miss:
    mov  dword [fbperf_fb_pte_level], 10
.done:
    pop  r9
    pop  r8
    pop  rdi
    pop  rsi
    pop  rdx
    pop  rcx
    pop  rbx
    pop  rax
    ret

; rcx = PAT slot index (0..7). Reads fbperf_pat_msr, decodes the 3-bit memory
; type at that slot, stores it into fbperf_fb_caching_type.
fbperf_decode_caching:
    push rax
    push rbx
    push rcx
    push rdx
    and  rcx, 7
    mov  rbx, rcx
    shl  rbx, 3                    ; slot * 8 bits
    mov  rax, [fbperf_pat_msr]
    mov  cl, bl
    shr  rax, cl
    and  rax, 7
    mov  [fbperf_fb_caching_type], eax
    pop  rdx
    pop  rcx
    pop  rbx
    pop  rax
    ret