
; ---------------------------------------------------------------------------
; fbperf_get(selector) -- userland accessor. Returns scalar in rax.
; ---------------------------------------------------------------------------
fbperf_get:
    push rdx
    mov  rax, -1
    cmp  rdi, 100
    je   .s_flips_total
    cmp  rdi, 101
    je   .s_full_flips
    cmp  rdi, 102
    je   .s_rect_flips
    cmp  rdi, 103
    je   .s_bytes_lo
    cmp  rdi, 104
    je   .s_bytes_hi
    cmp  rdi, 105
    je   .s_tsc_total_lo
    cmp  rdi, 106
    je   .s_tsc_total_hi
    cmp  rdi, 107
    je   .s_tsc_min
    cmp  rdi, 108
    je   .s_tsc_max
    cmp  rdi, 109
    je   .s_tsc_last
    cmp  rdi, 110
    je   .s_dirty_sum
    cmp  rdi, 111
    je   .s_full_bytes_lo
    cmp  rdi, 112
    je   .s_full_bytes_hi
    cmp  rdi, 113
    je   .s_rect_bytes_lo
    cmp  rdi, 114
    je   .s_rect_bytes_hi
    cmp  rdi, 115
    je   .s_cr0
    cmp  rdi, 116
    je   .s_cr3
    cmp  rdi, 117
    je   .s_cr4
    cmp  rdi, 118
    je   .s_cpuid_pat
    cmp  rdi, 119
    je   .s_mtrrcap
    cmp  rdi, 120
    je   .s_pat_lo
    cmp  rdi, 121
    je   .s_pat_hi
    cmp  rdi, 122
    je   .s_mtrr_def
    cmp  rdi, 123
    je   .s_mtrr_count
    cmp  rdi, 124
    je   .s_pte_lo
    cmp  rdi, 125
    je   .s_pte_hi
    cmp  rdi, 126
    je   .s_pte_level
    cmp  rdi, 127
    je   .s_caching
    cmp  rdi, 128
    je   .s_wc_plan_lo
    cmp  rdi, 129
    je   .s_wc_plan_hi
    cmp  rdi, 130
    je   .s_wc_armed
    cmp  rdi, 131
    je   .s_wc_activated
    cmp  rdi, 132
    je   .s_fb_addr_lo
    cmp  rdi, 133
    je   .s_fb_addr_hi
    cmp  rdi, 134
    je   .s_init_done
    cmp  rdi, 199
    je   .s_dump
    jmp  .done

.s_flips_total:    mov rax, [fbperf_flips_total]    ; jmp .done
                   jmp .done
.s_full_flips:     mov rax, [fbperf_full_flips]
                   jmp .done
.s_rect_flips:     mov rax, [fbperf_rect_flips]
                   jmp .done
.s_bytes_lo:       mov rax, [fbperf_bytes_total]
                   mov  eax, eax
                   jmp .done
.s_bytes_hi:       mov rax, [fbperf_bytes_total]
                   shr rax, 32
                   jmp .done
.s_tsc_total_lo:   mov rax, [fbperf_tsc_total]
                   mov  eax, eax
                   jmp .done
.s_tsc_total_hi:   mov rax, [fbperf_tsc_total]
                   shr rax, 32
                   jmp .done
.s_tsc_min:        mov rax, [fbperf_tsc_min]
                   jmp .done
.s_tsc_max:        mov rax, [fbperf_tsc_max]
                   jmp .done
.s_tsc_last:       mov rax, [fbperf_tsc_last]
                   jmp .done
.s_dirty_sum:      mov rax, [fbperf_dirty_rect_sum]
                   jmp .done
.s_full_bytes_lo:  mov rax, [fbperf_full_bytes]
                   mov eax, eax
                   jmp .done
.s_full_bytes_hi:  mov rax, [fbperf_full_bytes]
                   shr rax, 32
                   jmp .done
.s_rect_bytes_lo:  mov rax, [fbperf_rect_bytes]
                   mov eax, eax
                   jmp .done
.s_rect_bytes_hi:  mov rax, [fbperf_rect_bytes]
                   shr rax, 32
                   jmp .done
.s_cr0:            mov rax, [fbperf_cr0]
                   jmp .done
.s_cr3:            mov rax, [fbperf_cr3]
                   jmp .done
.s_cr4:            mov rax, [fbperf_cr4]
                   jmp .done
.s_cpuid_pat:      mov eax, [fbperf_cpuid_pat_supported]
                   jmp .done
.s_mtrrcap:        mov eax, [fbperf_mtrrcap]
                   jmp .done
.s_pat_lo:         mov eax, [fbperf_pat_msr]
                   jmp .done
.s_pat_hi:         mov eax, [fbperf_pat_msr + 4]
                   jmp .done
.s_mtrr_def:       mov eax, [fbperf_mtrr_def_type]
                   jmp .done
.s_mtrr_count:     mov eax, [fbperf_mtrr_var_count]
                   jmp .done
.s_pte_lo:         mov rax, [fbperf_fb_pte_value]
                   mov eax, eax
                   jmp .done
.s_pte_hi:         mov rax, [fbperf_fb_pte_value]
                   shr rax, 32
                   jmp .done
.s_pte_level:      mov eax, [fbperf_fb_pte_level]
                   jmp .done
.s_caching:        mov eax, [fbperf_fb_caching_type]
                   jmp .done
.s_wc_plan_lo:     mov eax, [fbperf_wc_plan_pat]
                   jmp .done
.s_wc_plan_hi:     mov eax, [fbperf_wc_plan_pat + 4]
                   jmp .done
.s_wc_armed:       movzx eax, byte [fbperf_wc_armed]
                   jmp .done
.s_wc_activated:   movzx eax, byte [fbperf_wc_activated]
                   jmp .done
.s_fb_addr_lo:     mov rax, [fb_addr]
                   mov eax, eax
                   jmp .done
.s_fb_addr_hi:     mov rax, [fb_addr]
                   shr rax, 32
                   jmp .done
.s_init_done:      movzx eax, byte [fbperf_init_done]
                   jmp .done
.s_dump:
    call fbperf_serial_dump
    xor  eax, eax
.done:
    pop  rdx
    ret

; ---------------------------------------------------------------------------
; fbperf_serial_dump -- emit a large [FBPERF] block over COM1
; ---------------------------------------------------------------------------
fbperf_serial_dump:
%ifdef RELEASE_BUILD
    ret
%else
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    push r12

    lea  rdi, [rel msg_banner]
    call serial_puts

    lea  rdi, [rel k_initdone]
    movzx esi, byte [fbperf_init_done]
    call fbperf_ser_kv

    mov  rsi, [fb_addr]
    lea  rdi, [rel k_fb_addr]
    call fbperf_ser_kv
    mov  rsi, [bb_addr]
    lea  rdi, [rel k_bb_addr]
    call fbperf_ser_kv
    movsxd rsi, dword [scr_width]
    lea  rdi, [rel k_scr_w]
    call fbperf_ser_kv
    movsxd rsi, dword [scr_height]
    lea  rdi, [rel k_scr_h]
    call fbperf_ser_kv
    movsxd rsi, dword [scr_pitch]
    lea  rdi, [rel k_scr_p]
    call fbperf_ser_kv

    mov  rsi, [fbperf_cr0]
    lea  rdi, [rel k_cr0]
    call fbperf_ser_kv
    mov  rsi, [fbperf_cr3]
    lea  rdi, [rel k_cr3]
    call fbperf_ser_kv
    mov  rsi, [fbperf_cr4]
    lea  rdi, [rel k_cr4]
    call fbperf_ser_kv

    mov  esi, [fbperf_cpuid_pat_supported]
    lea  rdi, [rel k_cpuidpat]
    call fbperf_ser_kv

    mov  rsi, [fbperf_pat_msr]
    lea  rdi, [rel k_pat]
    call fbperf_ser_kv

    mov  esi, [fbperf_mtrrcap]
    lea  rdi, [rel k_mtrrcap]
    call fbperf_ser_kv
    mov  esi, [fbperf_mtrr_def_type]
    lea  rdi, [rel k_mtrrdef]
    call fbperf_ser_kv
    mov  esi, [fbperf_mtrr_var_count]
    lea  rdi, [rel k_mtrrn]
    call fbperf_ser_kv

    ; Variable MTRRs (r12 = loop index, preserved across calls)
    xor  r12d, r12d
.mtrr_loop:
    cmp  r12d, [fbperf_mtrr_var_count]
    jge  .mtrr_done
    cmp  r12d, FBPERF_MAX_VAR_MTRR
    jge  .mtrr_done
    lea  rdi, [rel k_mtrrv]
    call serial_puts
    mov  rdi, r12
    call fbperf_ser_hex64
    mov  al, ' '
    call serial_putc
    mov  eax, r12d
    shl  eax, 4
    lea  rdx, [rel fbperf_mtrr_var]
    mov  rdi, [rdx + rax]          ; base
    call fbperf_ser_hex64
    mov  al, ' '
    call serial_putc
    mov  eax, r12d
    shl  eax, 4
    lea  rdx, [rel fbperf_mtrr_var]
    mov  rdi, [rdx + rax + 8]      ; mask
    call fbperf_ser_hex64
    call serial_crlf
    inc  r12d
    jmp  .mtrr_loop
.mtrr_done:

    ; Page walk results
    mov  rsi, [fbperf_pml4e]
    lea  rdi, [rel k_pml4]
    call fbperf_ser_kv
    mov  rsi, [fbperf_pdpte]
    lea  rdi, [rel k_pdpt]
    call fbperf_ser_kv
    mov  rsi, [fbperf_pde]
    lea  rdi, [rel k_pde]
    call fbperf_ser_kv
    mov  rsi, [fbperf_pte]
    lea  rdi, [rel k_pte]
    call fbperf_ser_kv
    mov  rsi, [fbperf_fb_pte_value]
    lea  rdi, [rel k_leafval]
    call fbperf_ser_kv
    movsxd rsi, dword [fbperf_fb_pte_level]
    lea  rdi, [rel k_leaflev]
    call fbperf_ser_kv
    movsxd rsi, dword [fbperf_fb_caching_type]
    lea  rdi, [rel k_caching]
    call fbperf_ser_kv

    ; WC plan
    mov  rsi, [fbperf_wc_plan_pat]
    lea  rdi, [rel k_wcplan]
    call fbperf_ser_kv
    movzx esi, byte [fbperf_wc_armed]
    lea  rdi, [rel k_wcarm]
    call fbperf_ser_kv
    movzx esi, byte [fbperf_wc_activated]
    lea  rdi, [rel k_wcact]
    call fbperf_ser_kv

    ; Runtime perf
    mov  rsi, [fbperf_flips_total]
    lea  rdi, [rel k_flips]
    call fbperf_ser_kv
    mov  rsi, [fbperf_full_flips]
    lea  rdi, [rel k_fullf]
    call fbperf_ser_kv
    mov  rsi, [fbperf_rect_flips]
    lea  rdi, [rel k_rectf]
    call fbperf_ser_kv
    mov  rsi, [fbperf_bytes_total]
    lea  rdi, [rel k_bytes]
    call fbperf_ser_kv
    mov  rsi, [fbperf_full_bytes]
    lea  rdi, [rel k_fullb]
    call fbperf_ser_kv
    mov  rsi, [fbperf_rect_bytes]
    lea  rdi, [rel k_rectb]
    call fbperf_ser_kv
    mov  rsi, [fbperf_tsc_total]
    lea  rdi, [rel k_tsctot]
    call fbperf_ser_kv
    mov  rsi, [fbperf_tsc_min]
    lea  rdi, [rel k_tscmin]
    call fbperf_ser_kv
    mov  rsi, [fbperf_tsc_max]
    lea  rdi, [rel k_tscmax]
    call fbperf_ser_kv
    mov  rsi, [fbperf_tsc_last]
    lea  rdi, [rel k_tsclast]
    call fbperf_ser_kv
    mov  rsi, [fbperf_dirty_rect_sum]
    lea  rdi, [rel k_dirty]
    call fbperf_ser_kv

    lea  rdi, [rel msg_end]
    call serial_puts

    pop  r12
    pop  rsi
    pop  rdi
    pop  rdx
    pop  rcx
    pop  rax
    ret
%endif

; ---------------------------------------------------------------------------
; fbperf_arm_wc -- set the arming flag. Activation still requires explicit
; call to fbperf_wc_activate. Two-step on purpose: arm in one boot, observe
; the dump, activate in a later boot.
; ---------------------------------------------------------------------------
fbperf_arm_wc:
    mov  byte [fbperf_wc_armed], 1
    ret

; ---------------------------------------------------------------------------
; fbperf_wc_activate -- write IA32_PAT and patch the FB leaf entry to use
; PAT slot 1 (WC under the canonical Linux PAT layout). NO-OP unless
; `fbperf_wc_armed` is set. Returns 0 on success, -1 if disarmed, -2 if the
; framebuffer isn't mapped (walk failed), -3 if leaf is at PML4.
;
; NOT WIRED INTO BOOT. Future session arms + activates after dump review.
; ---------------------------------------------------------------------------
fbperf_wc_activate:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp  byte [fbperf_wc_armed], 1
    jne  .disarmed

    ; Refresh walk just in case
    mov  rsi, [fb_addr]
    mov  [fbperf_walk_addr], rsi
    call fbperf_walk_pt

    mov  eax, [fbperf_fb_pte_level]
    test eax, eax
    jz   .not_mapped
    cmp  eax, 4
    je   .leaf_too_high
    cmp  eax, 10
    jae  .not_mapped

    ; --- Program IA32_PAT with the canonical layout ---
    ; WB->WC requires flushing any dirty WB cachelines for the FB range BEFORE
    ; the memtype changes; otherwise stale WB writes can race the new WC
    ; mapping and surface as tearing / stale pixels. wbinvd is a sledgehammer
    ; (whole-cache flush+invalidate, ~ms cost) but boot-time is fine, and it
    ; is a no-op for UC lines so it stays safe if the baseline wasn't WB.
    ; Intel SDM Vol 3A 11.11.8 "MP Initialization for MTRRs" describes the
    ; canonical disable-MTRR/wbinvd/wrmsr/enable-MTRR ritual; here we only
    ; touch PAT (not MTRRs), so the reduced sequence wbinvd -> wrmsr -> CR3
    ; reload suffices ON THIS CPU.
    ;
    ; IMPORTANT: the wbinvd, the IA32_PAT wrmsr, and the CR3 reload below are all
    ; per-logical-CPU and affect ONLY the core that runs this routine (the BSP).
    ; They do NOT shoot down other cores' TLBs and do NOT reprogram their PAT.
    ; This is therefore SAFE TO CALL ONLY BEFORE the APs are started: kmain
    ; activates WC here ahead of smp_ap_startup(), so every AP comes out of the
    ; trampoline walking the already-patched FB PTE and programs its own PAT to
    ; the same canonical layout (apic.asm ap_long_mode_init). Calling this after
    ; the APs are live would leave them with a stale TLB / divergent memory type
    ; for the FB page -> aliased memory types (SDM 11.12.4, undefined: tearing).
    wbinvd
    mov  ecx, 0x277
    mov  eax, [fbperf_wc_plan_pat]
    mov  edx, [fbperf_wc_plan_pat + 4]
    wrmsr

    ; --- Patch the leaf entry to use PAT slot 1 (PWT=1, PCD=0, PAT=0) ---
    ; That means: set bit 3 (PWT), clear bits 4 (PCD) and (PAT bit at level-
    ; specific position).
    mov  rsi, [fbperf_walk_addr]
    mov  rbx, cr3
    mov  rcx, 0x000FFFFFFFFFF000
    and  rbx, rcx

    ; Walk again, this time keep the *parent* table & index of the leaf.
    mov  rax, rsi
    shr  rax, 39
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    test rdi, 1
    jz   .not_mapped
    test rdi, 1 << 7
    jnz  .not_mapped               ; (PML4 leaf shouldn't happen)
    mov  rbx, rdi
    mov  r8, 0x000FFFFFFFFFF000
    and  rbx, r8

    mov  rax, rsi
    shr  rax, 30
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    test rdi, 1
    jz   .not_mapped
    test rdi, 1 << 7
    jz   .down_to_pd
    ; PDPT 1GB leaf: PAT bit at bit 12
    lea  rcx, [rbx + rax * 8]
    mov  rax, rdi
    or   rax, 1 << 3               ; set PWT
    and  rax, ~(1 << 4)            ; clear PCD
    and  rax, ~(1 << 12)           ; clear PAT
    mov  [rcx], rax
    jmp  .flush

.down_to_pd:
    mov  rbx, rdi
    mov  r8, 0x000FFFFFFFFFF000
    and  rbx, r8
    mov  rax, rsi
    shr  rax, 21
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    test rdi, 1
    jz   .not_mapped
    test rdi, 1 << 7
    jz   .down_to_pt
    ; PD 2MB leaf: PAT bit at bit 12
    lea  rcx, [rbx + rax * 8]
    mov  rax, rdi
    or   rax, 1 << 3
    and  rax, ~(1 << 4)
    and  rax, ~(1 << 12)
    mov  [rcx], rax
    jmp  .flush

.down_to_pt:
    mov  rbx, rdi
    mov  r8, 0x000FFFFFFFFFF000
    and  rbx, r8
    mov  rax, rsi
    shr  rax, 12
    and  rax, 0x1FF
    mov  rdi, [rbx + rax * 8]
    test rdi, 1
    jz   .not_mapped
    ; PT 4KB leaf: PAT bit at bit 7
    lea  rcx, [rbx + rax * 8]
    mov  rax, rdi
    or   rax, 1 << 3
    and  rax, ~(1 << 4)
    and  rax, ~(1 << 7)
    mov  [rcx], rax

.flush:
    ; Flush TLBs for the FB range. Cheapest: reload CR3.
    mov  rax, cr3
    mov  cr3, rax
    mov  byte [fbperf_wc_activated], 1
    xor  eax, eax
    jmp  .ret
.disarmed:
    mov  rax, -1
    jmp  .ret
.not_mapped:
    mov  rax, -2
    jmp  .ret
.leaf_too_high:
    mov  rax, -3
.ret:
    pop  rdi
    pop  rsi
    pop  rdx
    pop  rcx
    pop  rbx
    ret
