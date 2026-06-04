; Populate app_blob_base_v / size_v from VBE_INFO+0x20/+0x28 (filled by the
; UEFI loader after reading APPS.BIN). Falls back to the (now-zeroed) embedded
; symbols if no blob was loaded ??? in that case the apps are effectively absent
; but the kernel still boots.
FN_BEGIN app_blob_init, 0, 0, FN_RET_SCALAR
    push rax
    push rcx
    mov rax, [abs VBE_INFO_ADDR + VBE_APPS_BASE_OFF]
    mov rcx, [abs VBE_INFO_ADDR + VBE_APPS_SIZE_OFF]
    test rax, rax
    jnz .have_loaded
    ; Fallback: embedded symbols (bytes zeroed post-build, but size still valid)
    lea rax, [rel app_blob_start]
    lea rcx, [rel app_blob_end]
    sub rcx, rax
.have_loaded:
    mov [rel app_blob_base_v], rax
    mov [rel app_blob_size_v], rcx
    add rax, rcx
    mov [rel app_blob_end_v], rax
    mov rax, [abs VBE_INFO_ADDR + VBE_APP_ARENA_BASE_OFF]
    test rax, rax
    jnz .have_arena_base
    mov rax, APP_DATA_ADDR
.have_arena_base:
    mov [rel l3_app_arena_base_v], rax
    mov rcx, [abs VBE_INFO_ADDR + VBE_APP_ARENA_SIZE_OFF]
    test rcx, rcx
    jnz .have_arena_size
    mov rcx, MAX_WINDOWS * APP_SLOT_SIZE
.have_arena_size:
    mov [rel l3_app_arena_size_v], rcx
    pop rcx
    pop rax
    ret

; l3_prepare_test_callback - copy demo user code into slot app arena
; EDI = slot, RAX = entry pointer in APP_DATA space
FN_BEGIN l3_prepare_test_callback, 0, 0, FN_RET_SCALAR
    mov eax, edi
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    mov rdi, rax
    mov r8, rax
    lea rsi, [rel l3_test_blob]
    mov ecx, l3_test_blob_end - l3_test_blob
    rep movsb
    mov rax, r8
    ret

; enter_usermode - generic helper
; RDI = user RIP, RSI = slot
FN_DECL enter_usermode, 0, 0, FN_RET_SCALAR
    mov r10, rdi
    mov r11d, esi
    cmp r11d, MAX_WINDOWS
    jb .slot_ok
    xor r11d, r11d
.slot_ok:
    mov edi, r11d
    call l3_apply_slot_isolation
    mov edi, r11d
    call l3_apply_wx_policy
    ; FS/GS sanitization (security_todo.md ??3). IRETQ reloads CS/SS but NOT
    ; DS/ES/FS/GS, so without this the kernel data selector would stay in
    ; fs/gs across the entry into ring 3. Load ring-3 selectors first; clobbers
    ; ax only and nothing live here depends on it. (r10 = user RIP, r11d = slot
    ; are untouched.)
    SANITIZE_SEG_USER_EXIT
    push qword GDT64_USER_DATA
    mov edi, r11d
    call l3_user_stack_top
    push rax
    pushfq
    pop rax
    and rax, ~0x100
    or  rax, 0x200
    push rax
    push qword GDT64_USER_CODE
    push r10
    ; KPTI (security_todo.md ??3): swap to the kernel-unmapped user-view PML4
    ; before returning to ring 3 so the kernel address space is not present
    ; while user code runs (defeats Meltdown-class speculative leaks). No-op
    ; unless -dENABLE_KPTI AND kpti_init has armed it. rax is dead here (its
    ; RFLAGS value is already pushed above). NOTE: for the LIVE path the iret
    ; frame just pushed must reside in the trampoline window the user view keeps
    ; mapped ??? that stack-relocation is the documented scoped-out wiring in
    ; kpti.inc; until kpti_active is set this is inert.
    KPTI_SWITCH_TO_USER_CR3 rax
    iretq

; l3_runtime_ptr - EDI=slot -> RAX=runtime ptr
FN_BEGIN l3_runtime_ptr, 0, 0, FN_RET_SCALAR
    mov eax, edi
    imul rax, L3_RT_SIZE
    lea rdx, [rel l3_runtime]
    add rax, rdx
    ret

; l3_slot_base - EDI=slot -> RAX=APP_DATA slot base
FN_BEGIN l3_slot_base, 0, 0, FN_RET_SCALAR
    mov eax, edi
    imul rax, APP_SLOT_SIZE
    add rax, [rel l3_app_arena_base_v]
    ret

; l3_user_stack_top - EDI=slot -> RAX=top of user stack.
; Per-slot offset is sampled in l3_randomize_user_stack_top (called from
; l3_copy_app_blob_to_slot on every slot (re)init). A zero entry means the
; slot has not been initialized yet; fall back to the fixed legacy top so
; pre-slot-load callers (e.g. enter_usermode used by early tests) still work.
FN_BEGIN l3_user_stack_top, 0, 0, FN_RET_SCALAR
    mov ecx, edi
    cmp ecx, MAX_WINDOWS
    jb .l3_ust_slot_ok
    xor ecx, ecx
.l3_ust_slot_ok:
    mov rax, [rel l3_slot_ustack_off + rcx*8]
    test rax, rax
    jnz .l3_ust_have_off
    mov rax, L3_SLOT_USTACK_TOP_HIGH
.l3_ust_have_off:
    mov edx, ecx
    imul rdx, APP_SLOT_SIZE
    add rax, rdx
    add rax, [rel l3_app_arena_base_v]
    and rax, -16
    ret

; l3_randomize_user_stack_top - EDI=slot.
; Samples a fresh 16B-aligned in-slot stack-top offset in
; [L3_SLOT_USTACK_TOP_LOW, L3_SLOT_USTACK_TOP_HIGH] from RDTSC ^ RDRAND
; (RDRAND failure falls back to RDTSC, matching kernel_canary_init). Stores
; the offset in l3_slot_ustack_off[slot] for the slot's lifetime.
FN_BEGIN l3_randomize_user_stack_top, 0, 0, FN_RET_VOID
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    mov r8d, edi
%ifdef NEXUS_NO_MEM_RANDOM
    mov ecx, r8d
    mov qword [rel l3_slot_ustack_off + rcx*8], L3_SLOT_USTACK_TOP_HIGH
    jmp .lrust_done
%endif
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rbx, rax
    mov eax, 1
    cpuid
    test ecx, 1 << 30
    jz .lrust_no_rdrand
    mov ecx, 8
.lrust_try_rdrand:
    rdrand rax
    jc .lrust_have_rdrand
    dec ecx
    jnz .lrust_try_rdrand
    jmp .lrust_no_rdrand
.lrust_have_rdrand:
    xor rbx, rax
.lrust_no_rdrand:
    ; Reduce rbx to [0, RANGE] then align down to 16B and add LOW.
    mov rax, rbx
    xor rdx, rdx
    mov rcx, L3_SLOT_USTACK_TOP_RANGE + 1
    div rcx                              ; rdx = rbx mod (RANGE+1)
    and rdx, -16
    add rdx, L3_SLOT_USTACK_TOP_LOW
    mov ecx, r8d
    mov [rel l3_slot_ustack_off + rcx*8], rdx
.lrust_done:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    FN_END l3_randomize_user_stack_top
    ret

; l3_syscall_stack_top - EDI=slot -> RAX=top of syscall stack
FN_BEGIN l3_syscall_stack_top, 0, 0, FN_RET_SCALAR
    mov eax, edi
    imul rax, L3_SYSCALL_STACK_STRIDE
    mov rdx, L3_SYSCALL_STACK_ADDR
    add rax, rdx
    add rax, L3_SYSCALL_STACK_STRIDE       ; top = base + (i+1)*STRIDE; syscall stack is the top 4 KiB of the slot
    and rax, -16
    ret
