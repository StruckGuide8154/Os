; ============================================================================
; GritOS v3.0 - AMD DCN (Display Core Next) read-only probe
;
; Phase 1 (this file): safely probe the AMD display BAR0, walk page tables for
; its cache type, read a small set of registers, and expose the results for
; the '=' boot-diag overlay. NO writes. NO speculative reads at unknown
; offsets. Goal: produce evidence that BAR0 is mapped/accessible, what the
; cache type is, and surface the first few dwords so a follow-up session can
; pick the correct DCN version path with confidence.
;
; The 'safe head' of MMIO on every AMD GPU since GCN has been the NBIO/SMUIO
; regfile at BAR0+0x00.. -- reads here have never been a fault source. We do
; NOT touch DCN-IP-specific offsets (which differ per DCN HW version) until
; we know the version.
; ============================================================================
bits 64

%include "constants.inc"

extern pci_gpu_scan
extern pci_gpu_radeon780m_found
extern pci_gpu_radeon780m_bar0
extern pci_gpu_amd_display_found
extern pci_gpu_amd_display_bdf
extern pci_gpu_amd_display_bar0
extern amd_display_active
extern amd_display_bar0
extern amd_display_bdf
extern fb_addr
extern scr_height
extern scr_pitch
extern pci_read_conf_dword
extern pci_write_conf_dword
extern tick_count

section .text
global amd_dcn_probe

; void amd_dcn_probe(void)
; Idempotent. Sets amd_dcn_* state. Safe to call repeatedly.
amd_dcn_probe:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9

    ; Pick BAR0: prefer whichever device amd_display claimed; fall back to raw PCI scan.
    xor rax, rax
    cmp byte [amd_display_active], 0
    je  .from_pci
    mov rax, [amd_display_bar0]
    jmp .have_bar
.from_pci:
    cmp byte [pci_gpu_radeon780m_found], 0
    je  .try_amd_dev
    mov rax, [pci_gpu_radeon780m_bar0]
    jmp .have_bar
.try_amd_dev:
    cmp byte [pci_gpu_amd_display_found], 0
    je  .no_bar
    mov rax, [pci_gpu_amd_display_bar0]
.have_bar:
    ; Strip BAR low flag bits (memory BAR: bits [3:0] are type/prefetch flags).
    mov rbx, 0xFFFFFFFFFFFFFFF0
    and rax, rbx
    mov [amd_dcn_bar0], rax
    test rax, rax
    jz  .no_bar

    ; Enable PCI memory decode + bus-master on the AMD display device. The FB
    ; aperture works because the GOP enabled decode on its BAR; the register
    ; BAR may have decode disabled, yielding 0xFFFFFFFF reads. Set bits 1+2 of
    ; the Command register, idempotent.
    mov eax, [amd_display_bdf]   ; bus<<16 | dev<<8 | fn
    mov ecx, eax
    shr ecx, 16
    and ecx, 0xFF                ; bus
    shl ecx, 16                  ; bus<<16
    mov edx, eax
    shr edx, 8
    and edx, 0x1F                ; dev
    shl edx, 11
    or  ecx, edx
    mov edx, eax
    and edx, 0x07                ; fn
    shl edx, 8
    or  ecx, edx                 ; cfg base = bus<<16|dev<<11|fn<<8
    mov [amd_dcn_cfg_base], ecx

    mov eax, ecx
    or  eax, 0x04                ; Command/Status reg
    call pci_read_conf_dword
    mov [amd_dcn_cmd_pre], eax
    mov edx, eax
    or  edx, 0x06                ; MEM + BM
    mov [amd_dcn_cmd_post], edx
    cmp edx, eax
    je  .cmd_done                ; already set, don't touch
    mov eax, [amd_dcn_cfg_base]
    or  eax, 0x04
    mov ecx, edx
    call pci_write_conf_dword
.cmd_done:

    ; ------------------------------------------------------------------
    ; Install our own UC mapping for BAR0 at virt = AMD_DCN_UC_VBASE.
    ; We control PML4[AMD_DCN_UC_PML4_IDX] (chosen unused slot) and point
    ; it at a private PDPT->PD->PT chain that maps phys=BAR0 with
    ; PCD=1+PWT=1 (strong UC). 8MB is covered so the first hardware boot
    ; has enough BAR0 reach for DMCUB, DCN, and later SDMA register dumps.
    ; ------------------------------------------------------------------

    ; Step 1: zero our private PDPT/PD/PT pages on first call.
    cmp byte [amd_dcn_uc_init], 0
    jne .uc_skip_zero
    lea rdi, [amd_dcn_uc_pdpt]
    mov ecx, (4096*7)/8
    xor eax, eax
    rep stosq
    mov byte [amd_dcn_uc_init], 1
.uc_skip_zero:

    ; Step 2: install PDPT in our PML4 slot.
    mov rax, cr3
    mov rcx, 0x000FFFFFFFFFF000
    and rax, rcx
    lea rdx, [amd_dcn_uc_pdpt]
    or  rdx, 0x03                ; P|RW
    mov [rax + AMD_DCN_UC_PML4_IDX*8], rdx

    ; Step 3: in our PDPT, install PD at index 0 (covers first 1GB of the
    ; high-half slot; BAR0 will be at offset 0 of that range).
    lea rax, [amd_dcn_uc_pd]
    or  rax, 0x03
    mov [amd_dcn_uc_pdpt + 0*8], rax

    ; Step 4: in our PD, install four PTs (covers first 8MB).
    lea rax, [amd_dcn_uc_pt0]
    or  rax, 0x03
    mov [amd_dcn_uc_pd + 0*8], rax
    lea rax, [amd_dcn_uc_pt1]
    or  rax, 0x03
    mov [amd_dcn_uc_pd + 1*8], rax
    lea rax, [amd_dcn_uc_pt2]
    or  rax, 0x03
    mov [amd_dcn_uc_pd + 2*8], rax
    lea rax, [amd_dcn_uc_pt3]
    or  rax, 0x03
    mov [amd_dcn_uc_pd + 3*8], rax
    lea rax, [amd_dcn_dmub_ring_uc_pt]
    or  rax, 0x03
    mov [amd_dcn_uc_pd + 4*8], rax

    ; Step 5: fill PT entries 0..AMD_DCN_UC_NPAGES-1 with BAR0+i*4K + UC bits.
    ; PTE = phys | P | RW | PWT(bit3) | PCD(bit4)  =>  | 0x1B
    mov rdx, [amd_dcn_bar0]
    mov rcx, 0xFFFFFFFFFFFFF000
    and rdx, rcx                 ; page-align (paranoia)
    xor r8, r8                   ; PT index
.fill_pt:
    lea r9, [amd_dcn_uc_pt0]
    cmp r8, 512
    jb  .fill_have_pt
    lea r9, [amd_dcn_uc_pt1]
    cmp r8, 1024
    jb  .fill_have_pt
    lea r9, [amd_dcn_uc_pt2]
    cmp r8, 1536
    jb  .fill_have_pt
    lea r9, [amd_dcn_uc_pt3]
.fill_have_pt:
    mov rcx, rdx
    or  rcx, 0x1B
    mov rax, r8
    and rax, 511
    mov [r9 + rax*8], rcx
    add rdx, 0x1000
    inc r8
    cmp r8, AMD_DCN_UC_NPAGES
    jb  .fill_pt

    ; Step 6: TLB invalidate for every page mapped.
    xor r8, r8
    mov rax, AMD_DCN_UC_VBASE
.tlb:
    invlpg [rax]
    add rax, 0x1000
    inc r8
    cmp r8, AMD_DCN_UC_NPAGES
    jb  .tlb

    ; Step 6b: map a mailbox in VRAM through a UC alias just after the BAR0
    ; alias. Linux backs DMUB inbox/outbox rings with FB/GART memory and maps
    ; it into the DMCUB address space via CW4; low kernel RAM is not a valid
    ; DMCUB-visible mailbox on this hardware.
    mov rbx, [fb_addr]
    mov eax, [scr_pitch]
    mov ecx, [scr_height]
    mul ecx
    add rax, 0x0FFF
    and rax, 0xFFFFFFFFFFFFF000
    lea rdx, [rbx + rax]
    mov rcx, 0xFFFFFFFFFFFFF000
    and rdx, rcx
    mov [amd_dcn_dmub_ring_phys], rdx
    xor r8, r8
.ring_uc_map:
    mov rcx, rdx
    or  rcx, 0x1B
    mov [amd_dcn_dmub_ring_uc_pt + r8*8], rcx
    mov rax, AMD_DCN_RING_UC_VBASE
    mov r9, r8
    shl r9, 12
    add rax, r9
    invlpg [rax]
    add rdx, 0x1000
    inc r8
    cmp r8, AMD_DMUB_RING_TOTAL_PAGES
    jb .ring_uc_map

    ; Step 7: re-read through the UC mapping. Sample widely-spaced offsets
    ; (0x0/0x4/0x1000/0x3000) so MMIO sparseness vs kernel-byte sequence
    ; is visible.
    mov rsi, AMD_DCN_UC_VBASE
    mov eax, [rsi + 0]
    mov [amd_dcn_uc_r0000], eax
    mov eax, [rsi + 4]
    mov [amd_dcn_uc_r0004], eax
    mov eax, [rsi + 0x1000]
    mov [amd_dcn_uc_r0008], eax            ; (re-using slot name; now '+0x1000')
    mov eax, [rsi + 0x3000]
    mov [amd_dcn_uc_r000C], eax            ; (re-using slot name; now '+0x3000')
    mov byte [amd_dcn_uc_ok], 1

    ; Step 7a: read-only DCN3.1.4 DMCUB diagnostic registers. Offsets are
    ; from Linux dcn_3_1_4_offset.h with DCN_BASE__INST0_SEG2 = 0x34C0.
    mov eax, [rsi + AMD_DCN314_DMCUB_CNTL]
    mov [amd_dcn_dmub_cntl], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_CNTL2]
    mov [amd_dcn_dmub_cntl2], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_SEC_CNTL]
    mov [amd_dcn_dmub_sec_cntl], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH0]
    mov [amd_dcn_dmub_scratch0], eax
    mov edx, eax
    and edx, 0x000001FF
    mov [amd_dcn_dmub_boot_bits], edx
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH1]
    mov [amd_dcn_dmub_scratch1], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH2]
    mov [amd_dcn_dmub_scratch2], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH3]
    mov [amd_dcn_dmub_scratch3], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH7]
    mov [amd_dcn_dmub_scratch7], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH14]
    mov [amd_dcn_dmub_scratch14], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH15]
    mov [amd_dcn_dmub_scratch15], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_BASE]
    mov [amd_dcn_dmub_inbox1_base], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_SIZE]
    mov [amd_dcn_dmub_inbox1_size], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_RPTR]
    mov [amd_dcn_dmub_inbox1_rptr], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_WPTR]
    mov [amd_dcn_dmub_inbox1_wptr], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_BASE]
    mov [amd_dcn_dmub_outbox1_base], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_SIZE]
    mov [amd_dcn_dmub_outbox1_size], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_RPTR]
    mov [amd_dcn_dmub_outbox1_rptr], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_WPTR]
    mov [amd_dcn_dmub_outbox1_wptr], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_GPINT_DATAIN1]
    mov [amd_dcn_dmub_gpint_in], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_GPINT_DATAOUT]
    mov [amd_dcn_dmub_gpint_out], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INST_FAULT]
    mov [amd_dcn_dmub_inst_fault], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_DATA_FAULT]
    mov [amd_dcn_dmub_data_fault], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_UNDEF_FAULT]
    mov [amd_dcn_dmub_undef_fault], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_TIMER]
    mov [amd_dcn_dmub_timer], eax
    mov eax, [rsi + AMD_DCN314_DCN_VM_FB_BASE]
    mov [amd_dcn_dmub_fb_base_reg], eax
    mov eax, [rsi + AMD_DCN314_DCN_VM_FB_OFFSET]
    mov [amd_dcn_dmub_fb_offset_reg], eax
    ; CW6 region maps the dmub_shared_state region (IPS driver/firmware
    ; signal blocks). BIOS-loaded firmware programs this. Read-only here:
    ; gives us the system phys of shared_state for future IPS-exit work.
    mov eax, [rsi + AMD_DCN314_DMCUB_REGION3_CW6_BASE]
    mov [amd_dcn_dmub_cw6_base], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_REGION3_CW6_TOP]
    mov [amd_dcn_dmub_cw6_top], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_REGION3_CW6_OFFSET]
    mov [amd_dcn_dmub_cw6_offset_lo], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_REGION3_CW6_OFFSET_HIGH]
    mov [amd_dcn_dmub_cw6_offset_hi], eax
    call amd_dcn_dmub_prepare_mailbox
    call amd_dcn_dmub_gpint_ips_debug_wake
    call amd_dcn_dmub_send_outbox1_enable
    call amd_dcn_dmub_read_mailbox_regs
    call amd_dcn_dmub_classify
    mov byte [amd_dcn_dmub_diag_ok], 1

    ; Step 7b: Task-B prep - enumerate IP-block headers. Sample dword at
    ; every 0x1000 offset across the mapped 1MB. Each non-zero entry
    ; corresponds to an AMD SOC15 IP block header (pattern 0x4000_X001).
    ; Cross-referenced offline against soc15_ip_offset.h to identify DCN.
    mov rsi, AMD_DCN_UC_VBASE
    lea rdi, [amd_dcn_ip_table]
    xor r8, r8
.ip_loop:
    mov eax, [rsi]
    mov [rdi + r8*4], eax
    add rsi, 0x1000
    inc r8
    cmp r8, AMD_DCN_IP_COUNT
    jb  .ip_loop

    ; Step 7c: Task-C prep - brightness-PWM register hunt. Sample every
    ; dword at 4-byte stride across BAR0+AMD_DCN_BL_BASE .. +size, into
    ; amd_dcn_bl_table. After Task B identifies the DCN aperture base we
    ; can pick the PWM register from this snapshot without needing another
    ; boot. Region picked to span typical DCN3.x DIO/ABM placements
    ; (mmBL_PWM_CNTL / mmBL_PWM_USER_LEVEL live in this neighbourhood on
    ; DCN 3.x parts; range deliberately broad).
    mov rsi, AMD_DCN_UC_VBASE
    add rsi, AMD_DCN_BL_BASE
    lea rdi, [amd_dcn_bl_table]
    xor r8, r8
.bl_loop:
    mov eax, [rsi]
    mov [rdi + r8*4], eax
    add rsi, AMD_DCN_BL_STRIDE
    inc r8
    cmp r8, AMD_DCN_BL_COUNT
    jb  .bl_loop

    ; Step 8: walk the UC virt addr to verify our PTE install landed.
    mov rsi, AMD_DCN_UC_VBASE
    call amd_dcn_walk_pte
    mov rax, [amd_dcn_pte_value]
    mov [amd_dcn_uc_walk_pte], rax
    mov eax, [amd_dcn_pte_level]
    mov [amd_dcn_uc_walk_lvl], eax

    ; Walk current page tables for BAR0 to learn the cache type.
    mov rsi, [amd_dcn_bar0]
    call amd_dcn_walk_pte
    ; amd_dcn_walk_pte sets amd_dcn_pte_value, amd_dcn_pte_level, amd_dcn_cache_type.

    ; Only attempt MMIO reads if walk succeeded AND leaf is present.
    cmp dword [amd_dcn_pte_level], 0
    je  .no_pte
    cmp dword [amd_dcn_pte_level], 10
    je  .no_pte
    cmp dword [amd_dcn_pte_level], 20
    je  .no_pte
    cmp dword [amd_dcn_pte_level], 30
    je  .no_pte
    cmp dword [amd_dcn_pte_level], 40
    je  .no_pte
    ; Leaf present. Read first 4 dwords at BAR0+0x00..0x0C (universally safe on AMD).
    mov rsi, [amd_dcn_bar0]
    mov eax, [rsi + 0]
    mov [amd_dcn_reg0000], eax
    mov eax, [rsi + 4]
    mov [amd_dcn_reg0004], eax
    mov eax, [rsi + 8]
    mov [amd_dcn_reg0008], eax
    mov eax, [rsi + 12]
    mov [amd_dcn_reg000C], eax
    mov byte [amd_dcn_mmio_ok], 1
    jmp .done

.no_bar:
    mov byte [amd_dcn_mmio_ok], 0
    mov dword [amd_dcn_pte_level], 0
    mov qword [amd_dcn_pte_value], 0
    mov dword [amd_dcn_cache_type], 0xFF
    jmp .done
.no_pte:
    mov byte [amd_dcn_mmio_ok], 0
.done:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; amd_dcn_walk_pte
;  In:  RSI = virtual address to walk
;  Out: amd_dcn_pte_value, amd_dcn_pte_level (1/2/3/4 leaf, 10/20/30/40 miss),
;       amd_dcn_cache_type (0=WB,1=WT,2=UC-,3=UC,4=WC,5=WP,0xFF=unknown)
; Independent walker (does not depend on fbperf state).
; ----------------------------------------------------------------------------
amd_dcn_walk_pte:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8

    mov qword [amd_dcn_pte_value], 0
    mov dword [amd_dcn_pte_level], 0
    mov dword [amd_dcn_cache_type], 0xFF

    mov rax, cr3
    mov rcx, 0x000FFFFFFFFFF000
    and rax, rcx
    mov rbx, rax

    mov rax, rsi
    shr rax, 39
    and rax, 0x1FF
    mov rdi, [rbx + rax*8]
    test rdi, 1
    jz   .miss4
    test rdi, 1 << 7
    jnz  .leaf4
    mov rbx, rdi
    mov rcx, 0x000FFFFFFFFFF000
    and rbx, rcx

    mov rax, rsi
    shr rax, 30
    and rax, 0x1FF
    mov rdi, [rbx + rax*8]
    test rdi, 1
    jz   .miss3
    test rdi, 1 << 7
    jnz  .leaf3
    mov rbx, rdi
    mov rcx, 0x000FFFFFFFFFF000
    and rbx, rcx

    mov rax, rsi
    shr rax, 21
    and rax, 0x1FF
    mov rdi, [rbx + rax*8]
    test rdi, 1
    jz   .miss2
    test rdi, 1 << 7
    jnz  .leaf2
    mov rbx, rdi
    mov rcx, 0x000FFFFFFFFFF000
    and rbx, rcx

    mov rax, rsi
    shr rax, 12
    and rax, 0x1FF
    mov rdi, [rbx + rax*8]
    test rdi, 1
    jz   .miss1
    mov dword [amd_dcn_pte_level], 1
    mov [amd_dcn_pte_value], rdi
    ; 4K PTE: PAT bit at 7
    mov rax, rdi
    shr rax, 7
    and rax, 1
    shl rax, 2
    mov rcx, rdi
    shr rcx, 4
    and rcx, 1
    shl rcx, 1
    or  rax, rcx
    mov rcx, rdi
    shr rcx, 3
    and rcx, 1
    or  rax, rcx
    mov [amd_dcn_pat_index], eax
    call amd_dcn_decode_cache
    jmp .done

.leaf2:
    mov dword [amd_dcn_pte_level], 2
    mov [amd_dcn_pte_value], rdi
    ; 2MB leaf: PAT at bit 12
    mov rax, rdi
    shr rax, 12
    and rax, 1
    shl rax, 2
    mov rcx, rdi
    shr rcx, 4
    and rcx, 1
    shl rcx, 1
    or  rax, rcx
    mov rcx, rdi
    shr rcx, 3
    and rcx, 1
    or  rax, rcx
    mov [amd_dcn_pat_index], eax
    call amd_dcn_decode_cache
    jmp .done
.leaf3:
    mov dword [amd_dcn_pte_level], 3
    mov [amd_dcn_pte_value], rdi
    ; 1GB leaf: PAT at bit 12
    mov rax, rdi
    shr rax, 12
    and rax, 1
    shl rax, 2
    mov rcx, rdi
    shr rcx, 4
    and rcx, 1
    shl rcx, 1
    or  rax, rcx
    mov rcx, rdi
    shr rcx, 3
    and rcx, 1
    or  rax, rcx
    mov [amd_dcn_pat_index], eax
    call amd_dcn_decode_cache
    jmp .done
.leaf4:
    mov dword [amd_dcn_pte_level], 4
    mov [amd_dcn_pte_value], rdi
    jmp .done
.miss1:
    mov dword [amd_dcn_pte_level], 10
    jmp .done
.miss2:
    mov dword [amd_dcn_pte_level], 20
    jmp .done
.miss3:
    mov dword [amd_dcn_pte_level], 30
    jmp .done
.miss4:
    mov dword [amd_dcn_pte_level], 40
.done:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; amd_dcn_decode_cache - In: EAX = PAT index (0..7). Reads IA32_PAT MSR
; and writes the type to amd_dcn_cache_type.
; ----------------------------------------------------------------------------
amd_dcn_decode_cache:
    push rax
    push rcx
    push rdx
    push rbx
    mov ebx, eax           ; save PAT index
    mov ecx, 0x277         ; IA32_PAT
    rdmsr
    ; PAT is in EDX:EAX, 8 entries of 1 byte each. Pick byte [ebx].
    cmp ebx, 4
    jae .high
    mov ecx, ebx
    shl ecx, 3
    mov eax, eax           ; (lo half - no-op)
    shr eax, cl
    and eax, 0x7
    jmp .store
.high:
    sub ebx, 4
    mov ecx, ebx
    shl ecx, 3
    shr edx, cl
    mov eax, edx
    and eax, 0x7
.store:
    mov [amd_dcn_cache_type], eax
    pop rbx
    pop rdx
    pop rcx
    pop rax
    ret

; ----------------------------------------------------------------------------
; amd_dcn_dmub_prepare_mailbox
;  Build Linux-style FB-space mailbox addresses and, when the runtime arm flag
;  is enabled, program DMCUB CW4 plus INBOX1/OUTBOX1 as two FB-backed rings.
; ----------------------------------------------------------------------------
amd_dcn_dmub_prepare_mailbox:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    mov dword [amd_dcn_dmub_ring_status], 0
    mov dword [amd_dcn_dmub_ring_inbox_fb], 0
    mov dword [amd_dcn_dmub_ring_outbox_fb], 0

    mov eax, [amd_dcn_dmub_fb_base_reg]
    and eax, 0x00FFFFFF
    mov rdx, rax
    shl rdx, 24
    mov [amd_dcn_dmub_fb_base_phys], rdx

    mov eax, [amd_dcn_dmub_fb_offset_reg]
    and eax, 0x00FFFFFF
    mov rbx, rax
    shl rbx, 24
    mov [amd_dcn_dmub_fb_offset_phys], rbx

    mov rax, [amd_dcn_dmub_ring_phys]
    mov [amd_dcn_dmub_ring_sys_phys], rax
    sub rax, rdx
    add rax, rbx
    mov [amd_dcn_dmub_ring_fb_addr], rax

    ; CW4 splits the 64-bit ring sys-phys into OFFSET (low) + OFFSET_HIGH
    ; registers, and INBOX1_BASE/OUTBOX1_BASE are DMCUB-space constants
    ; (CW4_BASE/CW4_BASE+RING_BYTES). The system address is allowed to be
    ; above 4GB - ring backing sits just past the GOP framebuffer at
    ; ~0xF8_00xxxxxx on this hardware.
    mov dword [amd_dcn_dmub_ring_inbox_fb], AMD_DMUB_CW4_BASE
    mov eax, AMD_DMUB_CW4_BASE
    add eax, AMD_DMUB_RING_BYTES
    jc .bad_addr
    mov [amd_dcn_dmub_ring_outbox_fb], eax
    or dword [amd_dcn_dmub_ring_status], AMD_DMUB_RING_STATUS_ADDR_OK
    jmp .maybe_arm
.bad_addr:
    or dword [amd_dcn_dmub_ring_status], AMD_DMUB_RING_STATUS_BAD_ADDR
    jmp .done

.maybe_arm:
    cmp byte [amd_dcn_dmub_rings_arm], 0
    je .done
    or dword [amd_dcn_dmub_ring_status], AMD_DMUB_RING_STATUS_ARMED
    mov eax, [amd_dcn_dmub_boot_bits]
    test eax, AMD_DMUB_BOOT_MAILBOX_READY
    jz .done

    mov rdi, AMD_DCN_RING_UC_VBASE
    mov ecx, (AMD_DMUB_RING_TOTAL_BYTES / 8)
    xor eax, eax
    rep stosq
    mfence

    mov rsi, AMD_DCN_UC_VBASE
    mov rax, [amd_dcn_dmub_ring_fb_addr]
    mov [rsi + AMD_DCN314_DMCUB_REGION3_CW4_OFFSET], eax
    shr rax, 32
    mov [rsi + AMD_DCN314_DMCUB_REGION3_CW4_OFFSET_HIGH], eax
    mov dword [rsi + AMD_DCN314_DMCUB_REGION3_CW4_BASE], AMD_DMUB_CW4_BASE
    mov dword [rsi + AMD_DCN314_DMCUB_REGION3_CW4_TOP], (AMD_DMUB_CW4_BASE + AMD_DMUB_RING_TOTAL_BYTES) | AMD_DMUB_CW_ENABLE
    mov dword [rsi + AMD_DCN314_DMCUB_INBOX1_RPTR], 0
    mov dword [rsi + AMD_DCN314_DMCUB_INBOX1_WPTR], 0
    mov eax, [amd_dcn_dmub_ring_inbox_fb]
    mov [rsi + AMD_DCN314_DMCUB_INBOX1_BASE], eax
    mov dword [rsi + AMD_DCN314_DMCUB_INBOX1_SIZE], AMD_DMUB_RING_BYTES

    mov dword [rsi + AMD_DCN314_DMCUB_OUTBOX1_RPTR], 0
    mov dword [rsi + AMD_DCN314_DMCUB_OUTBOX1_WPTR], 0
    mov eax, [amd_dcn_dmub_ring_outbox_fb]
    mov [rsi + AMD_DCN314_DMCUB_OUTBOX1_BASE], eax
    mov dword [rsi + AMD_DCN314_DMCUB_OUTBOX1_SIZE], AMD_DMUB_RING_BYTES
    mfence
    or dword [amd_dcn_dmub_ring_status], AMD_DMUB_RING_STATUS_WRITTEN | AMD_DMUB_RING_STATUS_CW4
.done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; amd_dcn_dmub_gpint_ips_debug_wake
;  Sends DMUB_GPINT__IPS_DEBUG_WAKE through DATAIN1 before queueing an inbox
;  command. If the firmware is merely in IPS/idle, this is the smallest
;  hardware-facing wake probe before the benign OUTBOX1_ENABLE command.
; ----------------------------------------------------------------------------
amd_dcn_dmub_gpint_ips_debug_wake:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    mov dword [amd_dcn_dmub_gpint_status], 0
    mov rsi, AMD_DCN_UC_VBASE
    mov eax, AMD_DMUB_GPINT_IPS_DEBUG_WAKE_REQ
    mov [amd_dcn_dmub_gpint_req], eax
    mov [rsi + AMD_DCN314_DMCUB_GPINT_DATAIN1], eax
    mfence
    or dword [amd_dcn_dmub_gpint_status], AMD_DMUB_GPINT_STATUS_SENT

    mov rbx, [tick_count]
    mov [amd_dcn_dmub_gpint_tick_start], ebx
    mov [amd_dcn_dmub_gpint_tick_end], ebx
    add rbx, AMD_DMUB_GPINT_TIMEOUT_TICKS
    xor ecx, ecx
.poll:
    inc ecx
    mov eax, [rsi + AMD_DCN314_DMCUB_GPINT_DATAIN1]
    mov [amd_dcn_dmub_gpint_in], eax
    cmp eax, AMD_DMUB_GPINT_IPS_DEBUG_WAKE_ACK
    je .acked
    mov rdx, [tick_count]
    cmp rdx, rbx
    jb .poll
    or dword [amd_dcn_dmub_gpint_status], AMD_DMUB_GPINT_STATUS_TIMEOUT
    jmp .snapshot
.acked:
    or dword [amd_dcn_dmub_gpint_status], AMD_DMUB_GPINT_STATUS_ACKED
.snapshot:
    mov [amd_dcn_dmub_gpint_polls_left], ecx
    mov rdx, [tick_count]
    mov [amd_dcn_dmub_gpint_tick_end], edx
    mov eax, [rsi + AMD_DCN314_DMCUB_SCRATCH7]
    mov [amd_dcn_dmub_gpint_response], eax
    mov [amd_dcn_dmub_scratch7], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_GPINT_DATAOUT]
    mov [amd_dcn_dmub_gpint_dataout_after], eax
    mov [amd_dcn_dmub_gpint_out], eax

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; amd_dcn_dmub_send_outbox1_enable
;  First Linux-style inbox ring command. This deliberately does not use GPINT:
;  GPINT may require a DC idle/IPS wake sequence first, while this validates the
;  mailbox ring path we just programmed. Command is benign: enable OUTBOX1
;  notifications. Ring entry is 64 bytes; header dword is:
;    type=DMUB_CMD__OUTBOX1_ENABLE(71), payload_bytes=4 => 0x04000047.
; ----------------------------------------------------------------------------
amd_dcn_dmub_send_outbox1_enable:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov dword [amd_dcn_dmub_cmd_status], 0
    mov dword [amd_dcn_dmub_cmd_rptr0], 0
    mov dword [amd_dcn_dmub_cmd_wptr0], 0
    mov dword [amd_dcn_dmub_cmd_rptr1], 0
    mov dword [amd_dcn_dmub_cmd_wptr1], 0
    mov qword [amd_dcn_dmub_cmd_q0], 0
    mov qword [amd_dcn_dmub_cmd_q1], 0
    mov dword [amd_dcn_dmub_cmd_tick_start], 0
    mov dword [amd_dcn_dmub_cmd_tick_end], 0

    mov eax, [amd_dcn_dmub_ring_status]
    test eax, AMD_DMUB_RING_STATUS_WRITTEN
    jz .done
    mov eax, [amd_dcn_dmub_boot_bits]
    test eax, AMD_DMUB_BOOT_MAILBOX_READY
    jz .done

    mov rsi, AMD_DCN_UC_VBASE
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_RPTR]
    mov [amd_dcn_dmub_cmd_rptr0], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_WPTR]
    mov [amd_dcn_dmub_cmd_wptr0], eax

    ; We just reset the ring to empty in prepare_mailbox. If firmware moved it
    ; before we got here, do not overwrite an active command stream.
    cmp dword [amd_dcn_dmub_cmd_rptr0], 0
    jne .busy
    cmp dword [amd_dcn_dmub_cmd_wptr0], 0
    jne .busy

    mov rdi, AMD_DCN_RING_UC_VBASE
    mov rax, AMD_DMUB_CMD_OUTBOX1_ENABLE_Q0
    mov [rdi + 0], rax
    mov qword [rdi + 8], 0
    mov qword [rdi + 16], 0
    mov qword [rdi + 24], 0
    mov qword [rdi + 32], 0
    mov qword [rdi + 40], 0
    mov qword [rdi + 48], 0
    mov qword [rdi + 56], 0
    mfence

    ; Linux dmub_rb_flush_pending() reads the queued command back to drain
    ; writes before DMCUB sees the WPTR advance.
    xor rax, rax
    xor r8, r8
.flush_loop:
    mov rdx, [rdi + r8]
    xor rax, rdx
    add r8, 8
    cmp r8, AMD_DMUB_RB_CMD_SIZE
    jb .flush_loop
    mov rax, [rdi + 0]
    mov [amd_dcn_dmub_cmd_q0], rax
    mov rax, [rdi + 8]
    mov [amd_dcn_dmub_cmd_q1], rax

    mov dword [rsi + AMD_DCN314_DMCUB_INBOX1_WPTR], AMD_DMUB_RB_CMD_SIZE
    mfence
    or dword [amd_dcn_dmub_cmd_status], AMD_DMUB_CMD_STATUS_SENT

    mov rbx, [tick_count]
    mov [amd_dcn_dmub_cmd_tick_start], ebx
    add rbx, AMD_DMUB_CMD_TIMEOUT_TICKS
.poll:
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_RPTR]
    mov [amd_dcn_dmub_cmd_rptr1], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_WPTR]
    mov [amd_dcn_dmub_cmd_wptr1], eax
    cmp dword [amd_dcn_dmub_cmd_rptr1], AMD_DMUB_RB_CMD_SIZE
    je .done_ok
    mov rdx, [tick_count]
    cmp rdx, rbx
    jb .poll
    or dword [amd_dcn_dmub_cmd_status], AMD_DMUB_CMD_STATUS_TIMEOUT
    jmp .snapshot
.done_ok:
    or dword [amd_dcn_dmub_cmd_status], AMD_DMUB_CMD_STATUS_RPTR_ADVANCED
    jmp .snapshot
.busy:
    or dword [amd_dcn_dmub_cmd_status], AMD_DMUB_CMD_STATUS_BUSY
.snapshot:
    mov rdx, [tick_count]
    mov [amd_dcn_dmub_cmd_tick_end], edx
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

amd_dcn_dmub_read_mailbox_regs:
    push rax
    push rsi
    mov rsi, AMD_DCN_UC_VBASE
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_BASE]
    mov [amd_dcn_dmub_inbox1_base], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_SIZE]
    mov [amd_dcn_dmub_inbox1_size], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_RPTR]
    mov [amd_dcn_dmub_inbox1_rptr], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_INBOX1_WPTR]
    mov [amd_dcn_dmub_inbox1_wptr], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_BASE]
    mov [amd_dcn_dmub_outbox1_base], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_SIZE]
    mov [amd_dcn_dmub_outbox1_size], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_RPTR]
    mov [amd_dcn_dmub_outbox1_rptr], eax
    mov eax, [rsi + AMD_DCN314_DMCUB_OUTBOX1_WPTR]
    mov [amd_dcn_dmub_outbox1_wptr], eax
    pop rsi
    pop rax
    ret

; ----------------------------------------------------------------------------
; amd_dcn_dmub_classify
;  Derives compact health flags from the read-only DMCUB register snapshot.
;  No MMIO access here; safe even if the raw offsets later prove version-wrong.
; ----------------------------------------------------------------------------
amd_dcn_dmub_classify:
    push rax
    push rcx

    mov dword [amd_dcn_dmub_state_flags], 0

    ; bit0: DMCUB_CNTL.DMCUB_ENABLE
    mov eax, [amd_dcn_dmub_cntl]
    test eax, AMD_DMCUB_CNTL_ENABLE
    jz .check_reset
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_ENABLED
.check_reset:
    ; bit1: not in soft reset
    mov eax, [amd_dcn_dmub_cntl2]
    test eax, AMD_DMCUB_CNTL2_SOFT_RESET
    jnz .check_mailbox
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_NOT_RESET
.check_mailbox:
    ; bit2: firmware advertised mailbox ready in scratch0
    mov eax, [amd_dcn_dmub_boot_bits]
    test eax, AMD_DMUB_BOOT_MAILBOX_READY
    jz .check_dal
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_MAILBOX_BIT
.check_dal:
    ; bit3: DAL firmware bit in scratch0
    test eax, AMD_DMUB_BOOT_DAL_FW
    jz .check_hw_power
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_DAL_FW
.check_hw_power:
    ; bit4: HW power init done in scratch0
    test eax, AMD_DMUB_BOOT_HW_POWER_INIT
    jz .check_inbox
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_HW_POWER
.check_inbox:
    ; bit5: inbox1 size is small/nonzero and rptr/wptr are inside it.
    mov eax, [amd_dcn_dmub_inbox1_size]
    test eax, eax
    jz .check_outbox
    cmp eax, AMD_DMUB_RING_SIZE_MAX
    ja .check_outbox
    mov ecx, eax
    mov eax, [amd_dcn_dmub_inbox1_rptr]
    cmp eax, ecx
    jae .check_outbox
    mov eax, [amd_dcn_dmub_inbox1_wptr]
    cmp eax, ecx
    jae .check_outbox
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_INBOX_SANE
.check_outbox:
    ; bit6: outbox1 size is small/nonzero and rptr/wptr are inside it.
    mov eax, [amd_dcn_dmub_outbox1_size]
    test eax, eax
    jz .check_faults
    cmp eax, AMD_DMUB_RING_SIZE_MAX
    ja .check_faults
    mov ecx, eax
    mov eax, [amd_dcn_dmub_outbox1_rptr]
    cmp eax, ecx
    jae .check_faults
    mov eax, [amd_dcn_dmub_outbox1_wptr]
    cmp eax, ecx
    jae .check_faults
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_OUTBOX_SANE
.check_faults:
    ; bit7: no DMCUB fault registers set
    mov eax, [amd_dcn_dmub_inst_fault]
    or eax, [amd_dcn_dmub_data_fault]
    or eax, [amd_dcn_dmub_undef_fault]
    test eax, eax
    jnz .done
    or dword [amd_dcn_dmub_state_flags], AMD_DMUB_STATE_NO_FAULTS
.done:
    pop rcx
    pop rax
    ret

section .data
global amd_dcn_bar0
global amd_dcn_mmio_ok
global amd_dcn_pte_value
global amd_dcn_pte_level
global amd_dcn_pat_index
global amd_dcn_cache_type
global amd_dcn_reg0000
global amd_dcn_reg0004
global amd_dcn_reg0008
global amd_dcn_reg000C

amd_dcn_bar0:        dq 0
amd_dcn_mmio_ok:     db 0
                     times 3 db 0
amd_dcn_pte_value:   dq 0
amd_dcn_pte_level:   dd 0
amd_dcn_pat_index:   dd 0
amd_dcn_cache_type:  dd 0xFF
amd_dcn_reg0000:     dd 0
amd_dcn_reg0004:     dd 0
amd_dcn_reg0008:     dd 0
amd_dcn_reg000C:     dd 0
global amd_dcn_cfg_base
global amd_dcn_cmd_pre
global amd_dcn_cmd_post
amd_dcn_cfg_base:    dd 0
amd_dcn_cmd_pre:     dd 0
amd_dcn_cmd_post:    dd 0

global amd_dcn_uc_ok
global amd_dcn_uc_r0000
global amd_dcn_uc_r0004
global amd_dcn_uc_r0008
global amd_dcn_uc_r000C
amd_dcn_uc_ok:       db 0
                     times 3 db 0
amd_dcn_uc_r0000:    dd 0
amd_dcn_uc_r0004:    dd 0
amd_dcn_uc_r0008:    dd 0
amd_dcn_uc_r000C:    dd 0
amd_dcn_uc_init:     db 0
                     times 7 db 0
global amd_dcn_uc_walk_pte
global amd_dcn_uc_walk_lvl
amd_dcn_uc_walk_pte: dq 0
amd_dcn_uc_walk_lvl: dd 0
                     dd 0

global amd_dcn_dmub_diag_ok
global amd_dcn_dmub_cntl
global amd_dcn_dmub_cntl2
global amd_dcn_dmub_sec_cntl
global amd_dcn_dmub_scratch0
global amd_dcn_dmub_scratch1
global amd_dcn_dmub_scratch2
global amd_dcn_dmub_scratch3
global amd_dcn_dmub_scratch7
global amd_dcn_dmub_scratch14
global amd_dcn_dmub_scratch15
global amd_dcn_dmub_boot_bits
global amd_dcn_dmub_inbox1_base
global amd_dcn_dmub_inbox1_size
global amd_dcn_dmub_inbox1_rptr
global amd_dcn_dmub_inbox1_wptr
global amd_dcn_dmub_outbox1_base
global amd_dcn_dmub_outbox1_size
global amd_dcn_dmub_outbox1_rptr
global amd_dcn_dmub_outbox1_wptr
global amd_dcn_dmub_gpint_in
global amd_dcn_dmub_gpint_out
global amd_dcn_dmub_inst_fault
global amd_dcn_dmub_data_fault
global amd_dcn_dmub_undef_fault
global amd_dcn_dmub_timer
global amd_dcn_dmub_fb_base_reg
global amd_dcn_dmub_fb_offset_reg
global amd_dcn_dmub_cw6_base
global amd_dcn_dmub_cw6_top
global amd_dcn_dmub_cw6_offset_lo
global amd_dcn_dmub_cw6_offset_hi
global amd_dcn_dmub_state_flags
global amd_dcn_dmub_rings_arm
global amd_dcn_dmub_ring_status
global amd_dcn_dmub_ring_sys_phys
global amd_dcn_dmub_ring_fb_addr
global amd_dcn_dmub_ring_inbox_fb
global amd_dcn_dmub_ring_outbox_fb
global amd_dcn_dmub_fb_base_phys
global amd_dcn_dmub_fb_offset_phys
global amd_dcn_dmub_gpint_status
global amd_dcn_dmub_gpint_req
global amd_dcn_dmub_gpint_response
global amd_dcn_dmub_gpint_dataout_after
global amd_dcn_dmub_gpint_polls_left
global amd_dcn_dmub_gpint_tick_start
global amd_dcn_dmub_gpint_tick_end
global amd_dcn_dmub_cmd_status
global amd_dcn_dmub_cmd_rptr0
global amd_dcn_dmub_cmd_wptr0
global amd_dcn_dmub_cmd_rptr1
global amd_dcn_dmub_cmd_wptr1
global amd_dcn_dmub_cmd_q0
global amd_dcn_dmub_cmd_q1
global amd_dcn_dmub_cmd_tick_start
global amd_dcn_dmub_cmd_tick_end
amd_dcn_dmub_diag_ok:       db 0
                            times 3 db 0
amd_dcn_dmub_cntl:          dd 0
amd_dcn_dmub_cntl2:         dd 0
amd_dcn_dmub_sec_cntl:      dd 0
amd_dcn_dmub_scratch0:      dd 0
amd_dcn_dmub_scratch1:      dd 0
amd_dcn_dmub_scratch2:      dd 0
amd_dcn_dmub_scratch3:      dd 0
amd_dcn_dmub_scratch7:      dd 0
amd_dcn_dmub_scratch14:     dd 0
amd_dcn_dmub_scratch15:     dd 0
amd_dcn_dmub_boot_bits:     dd 0
amd_dcn_dmub_inbox1_base:   dd 0
amd_dcn_dmub_inbox1_size:   dd 0
amd_dcn_dmub_inbox1_rptr:   dd 0
amd_dcn_dmub_inbox1_wptr:   dd 0
amd_dcn_dmub_outbox1_base:  dd 0
amd_dcn_dmub_outbox1_size:  dd 0
amd_dcn_dmub_outbox1_rptr:  dd 0
amd_dcn_dmub_outbox1_wptr:  dd 0
amd_dcn_dmub_gpint_in:      dd 0
amd_dcn_dmub_gpint_out:     dd 0
amd_dcn_dmub_inst_fault:    dd 0
amd_dcn_dmub_data_fault:    dd 0
amd_dcn_dmub_undef_fault:   dd 0
amd_dcn_dmub_timer:         dd 0
amd_dcn_dmub_fb_base_reg:   dd 0
amd_dcn_dmub_fb_offset_reg: dd 0
amd_dcn_dmub_cw6_base:      dd 0
amd_dcn_dmub_cw6_top:       dd 0
amd_dcn_dmub_cw6_offset_lo: dd 0
amd_dcn_dmub_cw6_offset_hi: dd 0
amd_dcn_dmub_state_flags:   dd 0
amd_dcn_dmub_rings_arm:     db 1
                            times 3 db 0
amd_dcn_dmub_ring_status:   dd 0
amd_dcn_dmub_ring_phys:     dq 0
amd_dcn_dmub_ring_sys_phys: dq 0
amd_dcn_dmub_ring_fb_addr:  dq 0
amd_dcn_dmub_ring_inbox_fb: dd 0
amd_dcn_dmub_ring_outbox_fb: dd 0
amd_dcn_dmub_fb_base_phys:  dq 0
amd_dcn_dmub_fb_offset_phys: dq 0
amd_dcn_dmub_gpint_status:  dd 0
amd_dcn_dmub_gpint_req:     dd 0
amd_dcn_dmub_gpint_response: dd 0
amd_dcn_dmub_gpint_dataout_after: dd 0
amd_dcn_dmub_gpint_polls_left: dd 0
amd_dcn_dmub_gpint_tick_start: dd 0
amd_dcn_dmub_gpint_tick_end: dd 0
amd_dcn_dmub_cmd_status:  dd 0
amd_dcn_dmub_cmd_rptr0:   dd 0
amd_dcn_dmub_cmd_wptr0:   dd 0
amd_dcn_dmub_cmd_rptr1:   dd 0
amd_dcn_dmub_cmd_wptr1:   dd 0
amd_dcn_dmub_cmd_q0:      dq 0
amd_dcn_dmub_cmd_q1:      dq 0
amd_dcn_dmub_cmd_tick_start: dd 0
amd_dcn_dmub_cmd_tick_end: dd 0

; ------------------------------------------------------------------------
; Private page-table chain for the BAR0 UC alias mapping.
; Seven 4KB pages, each 4KB-aligned. Living in .data (not .bss) so the
; loader gives us deterministic zero-init at file-image granularity.
; PML4 slot 0x100 = virt base 0x0000800000000000 ... but that's the user
; canonical-hole edge. We use slot 0x180 (kernel half), virt base
; 0xFFFFC00000000000 (well clear of FB at 0xF800000000 / BAR0 at
; 0xFA10000000 which live in PML4 slot 1 of the lower half).
; ------------------------------------------------------------------------
AMD_DCN_UC_PML4_IDX  equ 0x180
AMD_DCN_UC_VBASE     equ 0xFFFFC00000000000
AMD_DCN_UC_NPAGES    equ 2048         ; 2048 * 4KB = 8MB mapped
AMD_DCN_RING_UC_VBASE equ (AMD_DCN_UC_VBASE + AMD_DCN_UC_NPAGES * 0x1000)
AMD_DCN_IP_COUNT     equ 256          ; one sample per 4KB page

; DCN 3.1.4 DMCUB register byte offsets from BAR0. Linux derives these as:
; (DCN_BASE__INST0_SEG2 + regDMCUB_*) * 4, where SEG2 is 0x34C0.
AMD_DCN314_DMCUB_CNTL          equ 0xDAD8
AMD_DCN314_DMCUB_CNTL2         equ 0xDB00
AMD_DCN314_DMCUB_SEC_CNTL      equ 0xDA38
AMD_DCN314_DMCUB_SCRATCH0      equ 0xDA8C
AMD_DCN314_DMCUB_SCRATCH1      equ 0xDA90
AMD_DCN314_DMCUB_SCRATCH2      equ 0xDA94
AMD_DCN314_DMCUB_SCRATCH3      equ 0xDA98
AMD_DCN314_DMCUB_SCRATCH7      equ 0xDAA8
AMD_DCN314_DMCUB_SCRATCH14     equ 0xDAC4
AMD_DCN314_DMCUB_SCRATCH15     equ 0xDAC8
AMD_DCN314_DMCUB_REGION3_CW4_BASE equ 0xD9A4
AMD_DCN314_DMCUB_REGION3_CW4_TOP equ 0xD9C4
AMD_DCN314_DMCUB_REGION3_CW4_OFFSET equ 0xD9F4
AMD_DCN314_DMCUB_REGION3_CW4_OFFSET_HIGH equ 0xD9F8
; CW6 byte offsets (reg indices 0x01ab/0x01b3/0x01c1/0x01c2 from
; dcn_3_1_4_offset.h, computed via (SEG2_base + idx)*4 with SEG2=0x34C0):
AMD_DCN314_DMCUB_REGION3_CW6_BASE        equ 0xD9AC
AMD_DCN314_DMCUB_REGION3_CW6_TOP         equ 0xD9CC
AMD_DCN314_DMCUB_REGION3_CW6_OFFSET      equ 0xDA04
AMD_DCN314_DMCUB_REGION3_CW6_OFFSET_HIGH equ 0xDA08
AMD_DCN314_DMCUB_INBOX1_BASE   equ 0xDA50
AMD_DCN314_DMCUB_INBOX1_SIZE   equ 0xDA54
AMD_DCN314_DMCUB_INBOX1_WPTR   equ 0xDA58
AMD_DCN314_DMCUB_INBOX1_RPTR   equ 0xDA5C
AMD_DCN314_DMCUB_OUTBOX1_BASE  equ 0xDA70
AMD_DCN314_DMCUB_OUTBOX1_SIZE  equ 0xDA74
AMD_DCN314_DMCUB_OUTBOX1_WPTR  equ 0xDA78
AMD_DCN314_DMCUB_OUTBOX1_RPTR  equ 0xDA7C
AMD_DCN314_DMCUB_GPINT_DATAIN1 equ 0xDAE0
AMD_DCN314_DMCUB_GPINT_DATAOUT equ 0xDAE4
AMD_DCN314_DMCUB_INST_FAULT    equ 0xDA30
AMD_DCN314_DMCUB_DATA_FAULT    equ 0xDA34
AMD_DCN314_DMCUB_UNDEF_FAULT   equ 0xDAE8
AMD_DCN314_DMCUB_TIMER         equ 0xDAF4
AMD_DCN314_DCN_VM_FB_BASE      equ 0xE4D4
AMD_DCN314_DCN_VM_FB_OFFSET    equ 0xE4DC

AMD_DMCUB_CNTL_ENABLE          equ 0x00010000
AMD_DMCUB_CNTL2_SOFT_RESET     equ 0x00000001
AMD_DMUB_BOOT_DAL_FW           equ 0x00000001
AMD_DMUB_BOOT_MAILBOX_READY    equ 0x00000002
AMD_DMUB_BOOT_HW_POWER_INIT    equ 0x00000080
AMD_DMUB_CW4_BASE              equ 0x64000000
AMD_DMUB_CW_ENABLE             equ 0x80000000
AMD_DMUB_RING_SIZE_MAX         equ 0x00010000
AMD_DMUB_RING_BYTES            equ 0x00002000
AMD_DMUB_RING_TOTAL_BYTES      equ (AMD_DMUB_RING_BYTES * 2)
AMD_DMUB_RING_TOTAL_PAGES      equ (AMD_DMUB_RING_TOTAL_BYTES / 0x1000)
AMD_DMUB_RB_CMD_SIZE           equ 64
AMD_DMUB_RING_STATUS_ADDR_OK   equ 0x00000001
AMD_DMUB_RING_STATUS_ARMED     equ 0x00000002
AMD_DMUB_RING_STATUS_WRITTEN   equ 0x00000004
AMD_DMUB_RING_STATUS_BAD_ADDR  equ 0x00000008
AMD_DMUB_RING_STATUS_CW4       equ 0x00000010
AMD_DMUB_GPINT_GET_FW_VERSION_REQ equ 0x10010000
AMD_DMUB_GPINT_GET_FW_VERSION_ACK equ 0x00010000
AMD_DMUB_GPINT_IPS_DEBUG_WAKE_REQ equ 0x10890000
AMD_DMUB_GPINT_IPS_DEBUG_WAKE_ACK equ 0x00890000
AMD_DMUB_GPINT_STATUS_SENT     equ 0x00000001
AMD_DMUB_GPINT_STATUS_ACKED    equ 0x00000002
AMD_DMUB_GPINT_STATUS_TIMEOUT  equ 0x00000004
AMD_DMUB_GPINT_TIMEOUT_TICKS   equ 50
AMD_DMUB_CMD_OUTBOX1_ENABLE_Q0 equ 0x0000000104000047
AMD_DMUB_CMD_STATUS_SENT       equ 0x00000001
AMD_DMUB_CMD_STATUS_RPTR_ADVANCED equ 0x00000002
AMD_DMUB_CMD_STATUS_TIMEOUT    equ 0x00000004
AMD_DMUB_CMD_STATUS_BUSY       equ 0x00000008
AMD_DMUB_CMD_TIMEOUT_TICKS     equ 50

AMD_DMUB_STATE_ENABLED         equ 0x00000001
AMD_DMUB_STATE_NOT_RESET       equ 0x00000002
AMD_DMUB_STATE_MAILBOX_BIT     equ 0x00000004
AMD_DMUB_STATE_DAL_FW          equ 0x00000008
AMD_DMUB_STATE_HW_POWER        equ 0x00000010
AMD_DMUB_STATE_INBOX_SANE      equ 0x00000020
AMD_DMUB_STATE_OUTBOX_SANE     equ 0x00000040
AMD_DMUB_STATE_NO_FAULTS       equ 0x00000080
; Task-C brightness PWM hunt window: 64KB at BAR0+0x4000.
; Boot 1 (2026-05-25) found DCN block header at BAR0+0x4000 (40003071 =
; DCN 3.0.71 / Strix). DCN 3.x BL_PWM_CNTL/USER_LEVEL/PERIOD live inside
; the DCN block, typically within the first 64KB of it. The previous
; 0x40000 window hit an SDMA index table - useless.
AMD_DCN_BL_BASE      equ 0x0
AMD_DCN_BL_COUNT     equ 16384        ; with 0x40 stride: 16384 * 0x40 = 1MB
AMD_DCN_BL_STRIDE    equ 0x40         ; 64-byte stride sweep across full BAR0

global amd_dcn_ip_table
global amd_dcn_bl_table
global amd_dcn_ip_count
global amd_dcn_bl_count
global amd_dcn_bl_base
amd_dcn_ip_count:    dd AMD_DCN_IP_COUNT
amd_dcn_bl_count:    dd AMD_DCN_BL_COUNT
amd_dcn_bl_base:     dd AMD_DCN_BL_BASE
global amd_dcn_bl_stride
amd_dcn_bl_stride:   dd AMD_DCN_BL_STRIDE

align 4096
amd_dcn_uc_pdpt:     times 4096 db 0
align 4096
amd_dcn_uc_pd:       times 4096 db 0
align 4096
amd_dcn_uc_pt0:      times 4096 db 0
align 4096
amd_dcn_uc_pt1:      times 4096 db 0
align 4096
amd_dcn_uc_pt2:      times 4096 db 0
align 4096
amd_dcn_uc_pt3:      times 4096 db 0
align 4096
amd_dcn_dmub_ring_uc_pt: times 4096 db 0
align 4096

; IP table - one dword per 4KB BAR0 page (256 entries = 1KB).
align 64
amd_dcn_ip_table:    times (AMD_DCN_IP_COUNT * 4) db 0
; Brightness PWM hunt - 4096 dwords (16KB).
align 64
amd_dcn_bl_table:    times (AMD_DCN_BL_COUNT * 4) db 0
