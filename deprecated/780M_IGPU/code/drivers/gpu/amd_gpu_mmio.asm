; ============================================================================
; amd_gpu_mmio.asm - MMIO read/write helpers + state for GFX bring-up
; ----------------------------------------------------------------------------
; Wave-1 primitive shared by SMU, GMC, CP-ring, and orchestrator modules.
; Reads/writes 32-bit MMIO using the BAR0 already mapped by amd_display.
;
; Addressing model
; ----------------
; All other gpu/* modules pass an *absolute dword offset within BAR0*:
;
;   abs_dword_offset = IP_BLOCK_BASE_BYTES / 4 + reg_dword
;
; (IP_BLOCK_BASE values live in src/include/amdgpu_regs.inc as byte offsets.)
; Multiplying by 4 here gives the byte offset within BAR0; we add the BAR0
; base captured at gpu_mmio_init time and do a plain 32-bit load/store.
;
; BAR0 has been verified by the DCN probe to be UC-mapped via the explicit
; alias set up in amd_display.asm; no PAT or fencing issues here.
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"

section .text

global gpu_mmio_init
global gpu_mmio_r32
global gpu_mmio_w32
global gpu_mmio_wait_eq

extern tick_count

; ---------------------------------------------------------------------------
; uint8 gpu_mmio_init(void)
;   Pick up BAR0 from the DCN probe (same device, different IP windows) and
;   record it in gpu_bar0_base. Idempotent. Returns 1 on success, 0 if no
;   BAR0 is available yet (caller must run pci_gpu_scan first).
; ---------------------------------------------------------------------------
gpu_mmio_init:
    push rbx
    mov  al, [gpu_bringup_state]
    cmp  al, GPU_STATE_OFF
    jne  .already

    mov  rax, [amd_display_bar0]
    mov  rbx, 0xFFFFFFFFFFFFFFF0
    and  rax, rbx
    test rax, rax
    jz   .no_bar
    mov  [gpu_bar0_base], rax
    mov  byte [gpu_bringup_state], GPU_STATE_MMIO_READY
.already:
    mov  al, 1
    pop  rbx
    ret
.no_bar:
    xor  al, al
    pop  rbx
    ret

; ---------------------------------------------------------------------------
; uint32 gpu_mmio_r32(uint32 abs_dword_offset /*edi*/)
; ---------------------------------------------------------------------------
gpu_mmio_r32:
    mov  rax, [gpu_bar0_base]
    test rax, rax
    jz   .nobar
    mov  ecx, edi
    shl  rcx, 2                     ; dword -> byte offset
    add  rax, rcx
    mov  eax, [rax]
    ret
.nobar:
    mov  eax, 0xFFFFFFFF             ; convention: "uninitialised" sentinel
    ret

; ---------------------------------------------------------------------------
; void gpu_mmio_w32(uint32 abs_dword_offset /*edi*/, uint32 val /*esi*/)
; ---------------------------------------------------------------------------
gpu_mmio_w32:
    mov  rax, [gpu_bar0_base]
    test rax, rax
    jz   .nobar
    mov  ecx, edi
    shl  rcx, 2
    add  rax, rcx
    mov  [rax], esi
.nobar:
    ret

; ---------------------------------------------------------------------------
; uint8 gpu_mmio_wait_eq(uint32 offset /*edi*/, uint32 mask /*esi*/,
;                        uint32 value /*edx*/, uint32 timeout_ticks /*ecx*/)
;
;   Poll until (read32(offset) & mask) == value, or timeout. Returns 1 on
;   match, 0 on timeout. All timeouts are PIT-tick based per the project
;   invariant (real HW vs QEMU diverges ~5000x on raw loops).
; ---------------------------------------------------------------------------
gpu_mmio_wait_eq:
    push rbx
    push r12
    push r13
    push r14
    mov  r12d, edi                  ; offset
    mov  r13d, esi                  ; mask
    mov  r14d, edx                  ; expected value
    mov  ebx,  ecx                  ; timeout

    mov  ecx, [tick_count]
    add  ebx, ecx                   ; deadline
.poll:
    mov  edi, r12d
    call gpu_mmio_r32
    and  eax, r13d
    cmp  eax, r14d
    je   .hit
    mov  ecx, [tick_count]
    cmp  ecx, ebx
    jb   .poll
    xor  al, al
    jmp  .done
.hit:
    mov  al, 1
.done:
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret

; ---------------------------------------------------------------------------
section .data
align 8
gpu_bar0_base:        dq 0
gpu_doorbell_base:    dq 0
gpu_bringup_state:    db GPU_STATE_OFF
