; ============================================================================
; amd_psp_probe.asm - Read-only MP0 SMN segment probe
; ----------------------------------------------------------------------------
; The MP0 SMN segment for Strix Point (gfx1150) hasn't been confirmed yet.
; Earlier guesses:
;   * 0x03800000 - reads returned 0x13 (stale SMU bus data, segment unmapped)
;   * BAR0+0x58000 direct MMIO - wedged NBIO; do NOT repeat that experiment
;
; This probe reads C2PMSG_{33,58,64,81} from six candidate SMN segments via
; the NBIO indirect proxy (BAR0[0x38/0x3C]). The proxy is safe even against
; unmapped segments - DATA2 just returns last-bus-data - so no faults can
; escape regardless of which segment turns out to be real.
;
; The "live" MP0 segment will distinguish itself by:
;   * C2PMSG_58 (sos_version) holding a version-shaped value (e.g. 0x002700xx)
;     instead of a uniform stale value across all four registers
;   * C2PMSG_81 (solution_status) non-zero
;   * C2PMSG_64 having bit 31 set (Trust OS ready handshake)
;   * The four readings DIFFERING from each other (a stale segment makes all
;     four reads return the same value)
;
; The MP1/SMU segment (0x03B10000) is included as a control: its readings
; should look like SMU state (PPSMC results etc.), not PSP state. Confirms
; the proxy itself is alive.
; ============================================================================

[BITS 64]

%include "amdgpu_gfx.inc"
%include "amdgpu_regs.inc"

section .text

global psp_probe_mp0
global psp_probe_segments
global psp_probe_results
global psp_probe_count
global psp_probe_done

extern smn_r32

PSP_PROBE_COUNT  equ 6
PSP_PROBE_STRIDE equ 16          ; 4 dwords stored per segment row

; ---------------------------------------------------------------------------
; uint8 psp_probe_mp0(void)
;   Idempotent. Always returns 1. Read-only: no SMN writes, only proxy reads.
; ---------------------------------------------------------------------------
psp_probe_mp0:
    push rbx
    push rcx
    push rdi
    push r12
    push r13

    ; No idempotency guard - re-probe every call so '=' presses give fresh
    ; data. 24 SMN reads is cheap.
    xor  r12d, r12d                     ; segment index
.seg_loop:
    cmp  r12d, PSP_PROBE_COUNT
    jae  .finished

    ; r13 = segment base byte addr
    lea  rcx, [rel psp_probe_segments]
    mov  r13d, [rcx + r12*4]

    ; row offset = r12 * PSP_PROBE_STRIDE
    mov  rbx, r12
    shl  rbx, 4                         ; *16
    lea  rcx, [rel psp_probe_results]
    add  rcx, rbx

    ; C2PMSG_33
    mov  edi, r13d
    add  edi, mmMP0_SMN_C2PMSG_33 * 4
    call smn_r32
    mov  [rcx + 0], eax

    ; C2PMSG_58 (SOS version - the killer signal)
    mov  edi, r13d
    add  edi, mmMP0_SMN_C2PMSG_58 * 4
    call smn_r32
    mov  [rcx + 4], eax

    ; C2PMSG_64 (Trust OS ready handshake)
    mov  edi, r13d
    add  edi, mmMP0_SMN_C2PMSG_64 * 4
    call smn_r32
    mov  [rcx + 8], eax

    ; C2PMSG_81 (solution status)
    mov  edi, r13d
    add  edi, mmMP0_SMN_C2PMSG_81 * 4
    call smn_r32
    mov  [rcx + 12], eax

    inc  r12d
    jmp  .seg_loop

.finished:
    mov  byte [psp_probe_done], 1
    mov  al, 1
    pop  r13
    pop  r12
    pop  rdi
    pop  rcx
    pop  rbx
    ret

; ---------------------------------------------------------------------------
section .data
align 4
psp_probe_segments:
    dd 0x00016000        ; Strix MPASP - mp_14_0_2 regMPASP_* BASE_IDX 0
    dd 0x0243FC00        ; Phoenix MP0 - yellow_carp_offset.h BASE_IDX 1
    dd 0x00DC0000        ; SEG2 - control
    dd 0x00E00000        ; SEG3 - control
    dd 0x00E40000        ; SEG4 - control
    dd 0x03B10000        ; legacy guess - keep as known-bad sentinel
psp_probe_count:    dd PSP_PROBE_COUNT
align 16
psp_probe_results:  times (PSP_PROBE_COUNT * PSP_PROBE_STRIDE) db 0
align 1
psp_probe_done:     db 0
