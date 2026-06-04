; ============================================================================
; NexusOS v3.0 - Security feature status inventory
; ----------------------------------------------------------------------------
; Read-only snapshot of every hardening feature's RUNTIME state, taken once at
; the very end of kmain (after lockdown + the nested-kernel page-table monitor
; have engaged) and published through SYS_SYSINFO selectors 200..240 for the
; Settings app's Security tab.
;
; DESIGN: this module NEVER changes whether a feature is on. It only reads the
; status that each feature already records (cet_*, kpti_active, nk_pt_protected,
; kl_done) plus a couple of cheap runtime probes (CR4 for SMAP, the kernel's own
; load address for KASLR). So a feature that fails to engage (e.g. the NK
; monitor bailing because the boot paging layout changed, or lockdown not
; completing) is REPORTED here as SECST_FAILED instead of bricking the box —
; the user sees it in Settings and the system stays usable. Tamper checks that
; must fail closed (measured boot, app-blob MAC) still panic in their own code;
; if we reached this snapshot they passed, so they read SECST_ACTIVE.
;
; Per-feature status codes (mirrored in src/user/nexushl/apps/settings.nxh):
;   0 SECST_OFF      - not compiled in / disabled for this build
;   1 SECST_ACTIVE   - fully armed
;   2 SECST_SOFTWARE - hardware unavailable, software fallback is active
;   3 SECST_UNSUPP   - hardware unsupported and no fallback applies
;   4 SECST_FAILED   - compiled + attempted but did not engage (degraded, not fatal)
;
; Feature index order (selector 210+i). The Settings app hardcodes the matching
; names in the same order — keep the two in lockstep.
;   0  SMEP / SMAP
;   1  CET hardware shadow stack
;   2  KPTI (kernel page-table isolation)
;   3  Per-slot syscall permutation
;   4  KASLR (random kernel base)
;   5  Kernel shadow stack (software, always on)
;   6  Page-table monitor (nested kernel)
;   7  Measured boot
;   8  Read-only kernel (.text lockdown)
;   9  Signed app blob
; ============================================================================
bits 64

%include "constants.inc"      ; KERNEL_LOAD_ADDR
%include "trace.inc"

SECST_OFF       equ 0
SECST_ACTIVE    equ 1
SECST_SOFTWARE  equ 2
SECST_UNSUPP    equ 3
SECST_FAILED    equ 4

SEC_FEATURE_COUNT equ 10

; CET status flags (defined unconditionally in cet.inc's .data).
extern cet_shstk_armed
extern cet_sw_shstk_armed
extern cet_supported
; Lockdown / monitor completion flags.
extern kl_done
extern nk_pt_protected
extern _start

section .text

; ----------------------------------------------------------------------------
; security_status_init - snapshot every feature's state into the status table.
;   Called once from kmain after kernel_lockdown_ro + nk_protect_page_tables so
;   their done/bail flags are final. Writes only to .bss (writable after
;   lockdown). Clobbers rax/rcx (caller-saved at the kmain init site).
; ----------------------------------------------------------------------------
global security_status_init
security_status_init:
    push rax
    push rcx

    ; --- [0] SMEP / SMAP -------------------------------------------------
    ; CR4.SMAP (bit 21) is the load-bearing user-deref guard. If SMAP was
    ; compiled in (-dENABLE_SMAP) but the bit is clear, the CPU/VM lacks SMAP.
%ifdef ENABLE_SMAP
    mov rax, cr4
    bt  rax, 21
    jc  .smap_active
    mov byte [rel security_status_table + 0], SECST_UNSUPP
    jmp .smap_done
.smap_active:
    mov byte [rel security_status_table + 0], SECST_ACTIVE
.smap_done:
%endif

    ; --- [1] CET hardware shadow stack -----------------------------------
    cmp byte [rel cet_shstk_armed], 0
    jne .cet_hw
    cmp byte [rel cet_sw_shstk_armed], 0
    jne .cet_sw
    cmp byte [rel cet_supported], 0
    je  .cet_unsupp
    jmp .cet_done                       ; supported but not armed -> OFF
.cet_hw:
    mov byte [rel security_status_table + 1], SECST_ACTIVE
    jmp .cet_done
.cet_sw:
    mov byte [rel security_status_table + 1], SECST_SOFTWARE
    jmp .cet_done
.cet_unsupp:
    mov byte [rel security_status_table + 1], SECST_UNSUPP
.cet_done:

    ; --- [2] KPTI --------------------------------------------------------
%ifdef ENABLE_KPTI
    extern kpti_active
    cmp byte [rel kpti_active], 0
    jne .kpti_on
    mov byte [rel security_status_table + 2], SECST_FAILED
    jmp .kpti_done
.kpti_on:
    mov byte [rel security_status_table + 2], SECST_ACTIVE
.kpti_done:
%endif

    ; --- [3] Per-slot syscall permutation --------------------------------
%ifdef ENABLE_SYSCALL_PERM
    mov byte [rel security_status_table + 3], SECST_ACTIVE
%endif

    ; --- [4] KASLR -------------------------------------------------------
    ; The kernel never sees -dENABLE_KASLR (loader-only flag), so detect it
    ; directly: a RIP-relative _start that resolves anywhere other than the
    ; link-time KERNEL_LOAD_ADDR means the loader slid us.
    lea rax, [rel _start]
    mov rcx, KERNEL_LOAD_ADDR
    cmp rax, rcx
    je  .kaslr_done
    mov byte [rel security_status_table + 4], SECST_ACTIVE
.kaslr_done:

    ; --- [5] Kernel software shadow stack (always compiled) --------------
    mov byte [rel security_status_table + 5], SECST_ACTIVE

    ; --- [6] Page-table monitor (nested kernel) --------------------------
    cmp byte [rel nk_pt_protected], 0
    jne .nk_on
    mov byte [rel security_status_table + 6], SECST_FAILED
    jmp .nk_done
.nk_on:
    mov byte [rel security_status_table + 6], SECST_ACTIVE
.nk_done:

    ; --- [7] Measured boot (fail-closed; reaching here == passed) --------
    mov byte [rel security_status_table + 7], SECST_ACTIVE

    ; --- [8] Read-only kernel lockdown -----------------------------------
    cmp byte [rel kl_done], 0
    jne .kl_on
    mov byte [rel security_status_table + 8], SECST_FAILED
    jmp .kl_st_done
.kl_on:
    mov byte [rel security_status_table + 8], SECST_ACTIVE
.kl_st_done:

    ; --- [9] Signed app blob (fail-closed; reaching here == verified) ----
    mov byte [rel security_status_table + 9], SECST_ACTIVE

    ; --- Summary: any feature in the FAILED state? -----------------------
    lea rcx, [rel security_status_table]
    xor eax, eax
.scan:
    cmp eax, SEC_FEATURE_COUNT
    jae .scan_done
    cmp byte [rcx + rax], SECST_FAILED
    jne .scan_next
    mov byte [rel security_any_failed], 1
.scan_next:
    inc eax
    jmp .scan
.scan_done:

    ; --- Debug-build marker (gates the Settings Debug tab) ---------------
%ifndef RELEASE_BUILD
    mov byte [rel security_debug_build], 1
%endif

    mov byte [rel security_status_ready], 1
    pop rcx
    pop rax
    ret

; ----------------------------------------------------------------------------
; security_status_query - SYS_SYSINFO selectors 200..240. rdi = selector.
;   Returns the scalar in rax (the sc_sysinfo dispatcher stores it). Selectors:
;     200 = debug-build flag (1 if this is a debug image)
;     201 = feature count
;     202 = "any feature failed" flag
;     203 = "status ready" flag (0 until security_status_init has run)
;     210+i = status code of feature i
;   Anything else in range returns 0.
; ----------------------------------------------------------------------------
global security_status_query
security_status_query:
    cmp rdi, 200
    je  .q_debug
    cmp rdi, 201
    je  .q_count
    cmp rdi, 202
    je  .q_anyfail
    cmp rdi, 203
    je  .q_ready
    cmp rdi, 210
    jb  .q_zero
    mov rax, rdi
    sub rax, 210
    cmp rax, SEC_FEATURE_COUNT
    jae .q_zero
    lea rcx, [rel security_status_table]
    movzx eax, byte [rcx + rax]
    ret
.q_debug:
    movzx eax, byte [rel security_debug_build]
    ret
.q_count:
    mov eax, SEC_FEATURE_COUNT
    ret
.q_anyfail:
    movzx eax, byte [rel security_any_failed]
    ret
.q_ready:
    movzx eax, byte [rel security_status_ready]
    ret
.q_zero:
    xor eax, eax
    ret

section .bss
global security_status_table
security_status_table:  resb SEC_FEATURE_COUNT
security_any_failed:    resb 1
security_debug_build:   resb 1
security_status_ready:  resb 1
