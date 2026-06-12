; ============================================================================
; Grit design-system resources
; ============================================================================
bits 64

%include "constants.inc"

NIC1_MAGIC equ 0x3143494E

section .text
global nx_icon_blit

extern bb_addr
extern scr_width
extern scr_height
extern scr_pitch_q

; Draw a 32bpp NIC icon with binary alpha.
; RDI = icon buffer, ESI = dst x, EDX = dst y
nx_icon_blit:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    cmp dword [rdi], NIC1_MAGIC
    jne .done
    cmp byte [rdi + 8], 32
    jne .done

    mov r12, rdi                ; icon
    movsxd r13, esi             ; x
    movsxd r14, edx             ; y
    movzx r15d, word [r12 + 4]  ; width
    movzx ebp, word [r12 + 6]   ; height

    ; Whole-icon bounds check. Current chrome/icon placements are all in-bounds;
    ; rejecting off-screen icons keeps the blitter small and deterministic.
    cmp r13, 0
    jl .done
    cmp r14, 0
    jl .done
    mov eax, r13d
    add eax, r15d
    cmp eax, [scr_width]
    jg .done
    mov eax, r14d
    add eax, ebp
    cmp eax, [scr_height]
    jg .done

    mov rax, r14
    imul rax, [scr_pitch_q]
    lea rax, [rax + r13 * 4]
    mov rbx, [bb_addr]
    add rbx, rax                ; row destination
    lea r12, [r12 + 16]         ; source pixels

.row:
    mov r10, rbx
    mov r11, r12
    mov ecx, r15d
.px:
    mov eax, [r11]
    test eax, 0xFF000000
    jz .skip
    mov [r10], eax
.skip:
    add r11, 4
    add r10, 4
    dec ecx
    jnz .px

    mov eax, r15d
    shl eax, 2
    add r12, rax
    add rbx, [scr_pitch_q]
    dec ebp
    jnz .row

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

section .rodata
global nx_palette_light
global nx_palette_dark
global nx_icon_about_16, nx_icon_about_32, nx_icon_about_48
global nx_icon_close_16, nx_icon_close_32, nx_icon_close_48
global nx_icon_explorer_16, nx_icon_explorer_32, nx_icon_explorer_48
global nx_icon_file_16, nx_icon_file_32, nx_icon_file_48
global nx_icon_folder_16, nx_icon_folder_32, nx_icon_folder_48
global nx_icon_notepad_16, nx_icon_notepad_32, nx_icon_notepad_48
global nx_icon_paint_16, nx_icon_paint_32, nx_icon_paint_48
global nx_icon_settings_16, nx_icon_settings_32, nx_icon_settings_48
global nx_icon_start_16, nx_icon_start_32, nx_icon_start_48
global nx_icon_taskmgr_16, nx_icon_taskmgr_32, nx_icon_taskmgr_48
global nx_icon_terminal_16, nx_icon_terminal_32, nx_icon_terminal_48

align 8
nx_palette_light:
    incbin "src/resources/design-system/palette_light.npl"
align 8
nx_palette_dark:
    incbin "src/resources/design-system/palette_dark.npl"

align 8
nx_icon_about_16:
    incbin "src/resources/design-system/icons/about.nic"
align 8
nx_icon_about_32:
    incbin "src/resources/design-system/icons/about-32.nic"
align 8
nx_icon_about_48:
    incbin "src/resources/design-system/icons/about-48.nic"

align 8
nx_icon_close_16:
    incbin "src/resources/design-system/icons/close.nic"
align 8
nx_icon_close_32:
    incbin "src/resources/design-system/icons/close-32.nic"
align 8
nx_icon_close_48:
    incbin "src/resources/design-system/icons/close-48.nic"

align 8
nx_icon_explorer_16:
    incbin "src/resources/design-system/icons/explorer.nic"
align 8
nx_icon_explorer_32:
    incbin "src/resources/design-system/icons/explorer-32.nic"
align 8
nx_icon_explorer_48:
    incbin "src/resources/design-system/icons/explorer-48.nic"

align 8
nx_icon_file_16:
    incbin "src/resources/design-system/icons/file.nic"
align 8
nx_icon_file_32:
    incbin "src/resources/design-system/icons/file-32.nic"
align 8
nx_icon_file_48:
    incbin "src/resources/design-system/icons/file-48.nic"

align 8
nx_icon_folder_16:
    incbin "src/resources/design-system/icons/folder.nic"
align 8
nx_icon_folder_32:
    incbin "src/resources/design-system/icons/folder-32.nic"
align 8
nx_icon_folder_48:
    incbin "src/resources/design-system/icons/folder-48.nic"

align 8
nx_icon_notepad_16:
    incbin "src/resources/design-system/icons/notepad.nic"
align 8
nx_icon_notepad_32:
    incbin "src/resources/design-system/icons/notepad-32.nic"
align 8
nx_icon_notepad_48:
    incbin "src/resources/design-system/icons/notepad-48.nic"

align 8
nx_icon_paint_16:
    incbin "src/resources/design-system/icons/paint.nic"
align 8
nx_icon_paint_32:
    incbin "src/resources/design-system/icons/paint-32.nic"
align 8
nx_icon_paint_48:
    incbin "src/resources/design-system/icons/paint-48.nic"

align 8
nx_icon_settings_16:
    incbin "src/resources/design-system/icons/settings.nic"
align 8
nx_icon_settings_32:
    incbin "src/resources/design-system/icons/settings-32.nic"
align 8
nx_icon_settings_48:
    incbin "src/resources/design-system/icons/settings-48.nic"

align 8
nx_icon_start_16:
    incbin "src/resources/design-system/icons/start.nic"
align 8
nx_icon_start_32:
    incbin "src/resources/design-system/icons/start-32.nic"
align 8
nx_icon_start_48:
    incbin "src/resources/design-system/icons/start-48.nic"

align 8
nx_icon_taskmgr_16:
    incbin "src/resources/design-system/icons/taskmgr.nic"
align 8
nx_icon_taskmgr_32:
    incbin "src/resources/design-system/icons/taskmgr-32.nic"
align 8
nx_icon_taskmgr_48:
    incbin "src/resources/design-system/icons/taskmgr-48.nic"

align 8
nx_icon_terminal_16:
    incbin "src/resources/design-system/icons/terminal.nic"
align 8
nx_icon_terminal_32:
    incbin "src/resources/design-system/icons/terminal-32.nic"
align 8
nx_icon_terminal_48:
    incbin "src/resources/design-system/icons/terminal-48.nic"
