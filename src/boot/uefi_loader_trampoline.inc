; ============================================================================
; TRAMPOLINE  - copied to 0x8000, runs after ExitBootServices
; In:  RSI = payload source           (within UEFI-allocated buffer)
;      RDI = destination base         (KERN_DEST + slide)
;      RCX = payload byte count
;      R8  = fixup table source       (u32 offsets, within UEFI buffer)
;      R9  = fixup count
;      R10 = slide value              (added to each [dest+offset] qword)
;      R11 = entry offset             (jump target = dest_base + R11)
;
; The UEFI-allocated buffer that holds the original wrapped kernel (R8's
; backing) does NOT overlap [RDI, RDI+RCX) — UEFI's AllocateAnyPages places
; it well above the kernel destination window — so fixup reads remain valid
; after the copy.
; ============================================================================
align 16
trampoline:
    ; Preserve dest base + fixup-walk regs across rep movsq.
    mov r12, rdi                ; dest base (preserved)
    mov r13, r8                 ; fixup table cursor (preserved)
    mov r14, r9                 ; remaining fixup count (preserved)

    add rcx, 7
    shr rcx, 3                  ; round up to qwords
    rep movsq

    ; Walk fixups: for each u32 off in [r13 .. r13 + r14*4): [r12+off] += r10
    test r10, r10
    jz   .tramp_no_fixups       ; slide=0 -> nothing to patch
    test r14, r14
    jz   .tramp_no_fixups
.tramp_fix_loop:
    mov  eax, [r13]             ; u32 offset (zero-extended)
    add  [r12 + rax], r10
    add  r13, 4
    dec  r14
    jnz  .tramp_fix_loop
.tramp_no_fixups:

    wbinvd
    ; Switch to our own page tables (with User bits for ring 3)
    mov rax, PT_BASE
    mov cr3, rax
    add r12, r11                ; entry = dest_base + entry_offset
    jmp r12
trampoline_end:
