; ============================================================================
; GritOS v3.0 - AMD Display Mode-Setting Driver
; Passive AMD display provider for real hardware. The first supported hardware
; mode is the firmware/GOP mode handed to the kernel at boot; no AMD MMIO or
; register programming is attempted in this phase.
; ============================================================================
bits 64

%include "constants.inc"

extern pci_gpu_scan
extern pci_gpu_radeon780m_found
extern pci_gpu_radeon780m_bdf
extern pci_gpu_radeon780m_id
extern pci_gpu_radeon780m_class
extern pci_gpu_amd_display_found
extern pci_gpu_amd_display_bdf
extern pci_gpu_amd_display_id
extern pci_gpu_amd_display_class
extern pci_gpu_amd_display_bar0
extern pci_gpu_amd_display_cmd
extern pci_gpu_radeon780m_bar0
extern pci_gpu_radeon780m_cmd
extern fb_addr
extern scr_width
extern scr_height
extern scr_pitch
extern scr_pitch_q
extern fb_native_width
extern fb_native_height
extern frame_count
extern tick_count
extern start_tick
extern display_recompute_layout
extern raster_select_default_target
extern display_clear
extern wait_vsync

section .text

global amd_display_init
amd_display_init:
    push rax
    call pci_gpu_scan
    cmp byte [pci_gpu_radeon780m_found], 0
    jne .claim_780m
    cmp byte [pci_gpu_amd_display_found], 0
    jne .claim_amd
    mov byte [amd_display_active], 0
    mov dword [amd_display_status], AMD_DISPLAY_STATUS_NOT_FOUND
    mov dword [amd_display_bdf], 0
    mov dword [amd_display_id], 0
    mov dword [amd_display_class], 0
    mov qword [amd_display_bar0], 0
    mov dword [amd_display_cmd], 0
    jmp .done

.claim_780m:
    mov byte [amd_display_active], 1
    mov dword [amd_display_status], AMD_DISPLAY_STATUS_780M
    mov eax, [pci_gpu_radeon780m_bdf]
    mov [amd_display_bdf], eax
    mov eax, [pci_gpu_radeon780m_id]
    mov [amd_display_id], eax
    mov eax, [pci_gpu_radeon780m_class]
    mov [amd_display_class], eax
    mov rax, [pci_gpu_radeon780m_bar0]
    mov [amd_display_bar0], rax
    mov eax, [pci_gpu_radeon780m_cmd]
    mov [amd_display_cmd], eax
    jmp .latch_mode

.claim_amd:
    mov byte [amd_display_active], 1
    mov dword [amd_display_status], AMD_DISPLAY_STATUS_AMD_DISPLAY
    mov eax, [pci_gpu_amd_display_bdf]
    mov [amd_display_bdf], eax
    mov eax, [pci_gpu_amd_display_id]
    mov [amd_display_id], eax
    mov eax, [pci_gpu_amd_display_class]
    mov [amd_display_class], eax
    mov rax, [pci_gpu_amd_display_bar0]
    mov [amd_display_bar0], rax
    mov eax, [pci_gpu_amd_display_cmd]
    mov [amd_display_cmd], eax

.latch_mode:
    mov rax, [fb_addr]
    mov [amd_display_fb_addr], rax
    mov eax, [scr_width]
    mov [amd_display_mode_w], eax
    mov eax, [scr_height]
    mov [amd_display_mode_h], eax
    mov eax, [scr_pitch]
    mov [amd_display_mode_pitch], eax
    mov dword [amd_display_mode_bpp], 32
.done:
    pop rax
    ret

; EDI = width, ESI = height, EDX = bpp
; Returns:
;   0  accepted: requested mode is the current/native AMD firmware mode
;  -1  rejected: not an AMD display provider, invalid bpp, or unsupported mode
global amd_display_set_mode
amd_display_set_mode:
    cmp byte [amd_display_active], 1
    jne .fail
    cmp edx, 32
    jne .fail
    cmp edi, [fb_native_width]
    jne .fail
    cmp esi, [fb_native_height]
    jne .fail

    call wait_vsync
    mov dword [frame_count], 0
    mov rax, [tick_count]
    mov [start_tick], rax

    mov eax, [fb_native_width]
    mov [scr_width], eax
    mov eax, [fb_native_height]
    mov [scr_height], eax
    mov eax, [amd_display_mode_pitch]
    test eax, eax
    jnz .have_pitch
    mov eax, [scr_width]
    shl eax, 2
.have_pitch:
    mov [scr_pitch], eax
    mov [scr_pitch_q], rax

    call display_recompute_layout
    call raster_select_default_target
    xor edi, edi
    call display_clear
    xor eax, eax
    ret

.fail:
    mov rax, -1
    ret

section .data
AMD_DISPLAY_STATUS_NOT_FOUND   equ 0
AMD_DISPLAY_STATUS_780M        equ 1
AMD_DISPLAY_STATUS_AMD_DISPLAY equ 2

global amd_display_active
global amd_display_status
global amd_display_bdf
global amd_display_id
global amd_display_class
global amd_display_bar0
global amd_display_cmd
global amd_display_fb_addr
global amd_display_mode_w
global amd_display_mode_h
global amd_display_mode_pitch
global amd_display_mode_bpp
amd_display_active:     db 0
amd_display_status:     dd AMD_DISPLAY_STATUS_NOT_FOUND
amd_display_bdf:        dd 0
amd_display_id:         dd 0
amd_display_class:      dd 0
amd_display_bar0:       dq 0
amd_display_cmd:        dd 0
amd_display_fb_addr:    dq 0
amd_display_mode_w:     dd 0
amd_display_mode_h:     dd 0
amd_display_mode_pitch: dd 0
amd_display_mode_bpp:   dd 0
