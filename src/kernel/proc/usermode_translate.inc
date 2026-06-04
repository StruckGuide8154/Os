FN_BEGIN l3_slot_resolve_app_ptr, 0, 0, FN_RET_SCALAR
    lea r8, [rel app_blob_start]
    lea r9, [rel app_blob_end]
    mov rax, rsi
    cmp rax, r8
    jb .slot_resolve_done
    cmp rax, r9
    jae .slot_resolve_done
    push rdx
    push rcx
    sub rax, r8
    mov edx, edi
    imul rdx, APP_SLOT_SIZE
    add rdx, [rel l3_app_arena_base_v]
    add rax, rdx
    ; Apply this slot's per-slot code slide.
    mov ecx, edi
    add rax, [rel l3_slot_code_slide + rcx*8]
    pop rcx
    pop rdx
.slot_resolve_done:
    ret

; l3_translate_target
; RDI = callback target. This may be either a canonical pointer inside the
; built-in app blob or a slot-local pointer handed to the kernel by ring-3
; code through SYS_WM_CREATE / SYS_WM_HANDLERS.
; RSI = slot app base
; Returns: RAX = translated user target (or original target if no mapping applies)
FN_BEGIN l3_translate_target, 0, 0, FN_RET_SCALAR
    lea r8, [rel app_blob_start]
    lea r9, [rel app_blob_end]
    mov rax, rdi
    cmp rax, r8
    jb .try_slot_local
    cmp rax, r9
    jae .try_slot_local

    sub rax, r8                         ; rax = blob-relative offset
    ; Add this (active) slot's per-slot code slide. Validate RSI before
    ; deriving the slot index; stale callback state must not index past
    ; l3_slot_code_slide.
    mov r10, rsi
    mov r11, [rel l3_app_arena_base_v]
    cmp r10, r11
    jb .translate_original
    sub r10, r11
    test r10, APP_SLOT_SIZE - 1
    jnz .translate_original
    cmp r10, [rel l3_app_arena_size_v]
    jae .translate_original
    shr r10, 21
    cmp r10d, MAX_WINDOWS
    jae .translate_original
    add rax, rsi                        ; + active slot base
    add rax, [rel l3_slot_code_slide + r10*8]
    jmp .translate_done

.try_slot_local:
    mov r8, [rel l3_app_arena_base_v]
    mov r9, r8
    add r9, [rel l3_app_arena_size_v]
    mov rax, rdi
    cmp rax, r8
    jb .translate_original
    cmp rax, r9
    jae .translate_original
    sub rax, r8
    and rax, APP_SLOT_SIZE - 1          ; in-slot offset
    ; With per-slot code slide, the valid live-blob window is
    ; [slide, slide + blob_size). Reject anything outside it.
    mov r10, rsi
    cmp r10, r8
    jb .translate_original
    sub r10, r8
    test r10, APP_SLOT_SIZE - 1
    jnz .translate_original
    cmp r10, [rel l3_app_arena_size_v]
    jae .translate_original
    shr r10, 21
    cmp r10d, MAX_WINDOWS
    jae .translate_original
    mov r11, [rel l3_slot_code_slide + r10*8]
    cmp rax, r11
    jb .translate_original
    sub rax, r11
    cmp rax, [rel app_blob_size_v]
    jae .translate_original
    add rax, r11                        ; restore in-slot offset (incl. slide)
    add rax, rsi
    jmp .translate_done

.translate_original:
    mov rax, rdi
.translate_done:
    ret

; call_app_l3_packed -- Stage 2c thunk for cross-core dispatch.
; RDI = pointer to a 32-byte packed-args block:
;       [0] = target function
;       [8] = arg0 (window ptr)
;       [16] = arg1
;       [24] = arg2
; Unpacks into the regs call_app_l3 expects and tail-calls it.
;
; This is the function Stage 2d will hand to process_submit_job so an AP can
; run the ring-3 transition on behalf of the owning PCB. Lives in usermode.asm
