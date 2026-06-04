; ============================================================================
; NexusOS v3.0 - Application Framework + Built-in Apps
; Each app provides: draw_fn(rdi=window_ptr), click_fn(rdi=window_ptr,
;   rsi=client_x, rdx=client_y), key_fn(rdi=window_ptr, esi=key_event)
; Window struct offsets (from window.asm):
;   8:X 16:Y 24:W 32:H 40:Flags 48:Title 112:draw_fn 120:key_fn 128:click_fn 136:app_data
; ============================================================================
bits 64
default rel

section .text

%include "nexus_app.inc"
%include "nexus_window.inc"
%include "macros.inc"

; Ring 3 apps must not touch COM directly.
%unmacro SER 1
%macro SER 1
%endmacro

; Virtual filesystem entry size
VFS_ENTRY_SIZE  equ 32     ; 24 bytes name + 1 byte type + 7 bytes size

; Notepad constants
NP_MAX_LINES    equ 32
NP_MAX_COLS     equ 80
NP_BUF_SIZE     equ (NP_MAX_LINES * NP_MAX_COLS)
NP_MENU_H       equ 18
NP_EDIT_TOP     equ 20     ; offset from client top to editing area

; Terminal constants
TERM_MAX_HIST   equ 16     ; max history output lines
TERM_STATE_CURSOR   equ 0
TERM_STATE_INPUT    equ 8
TERM_STATE_ECHO     equ 72
TERM_INPUT_MAX      equ 63
TERM_CTX_X          equ 160
TERM_CTX_Y          equ 168
TERM_CTX_W          equ 176
TERM_CTX_H          equ 184
TERM_ECHO_MAX       equ 127

; Context menu
CTX_ITEM_H      equ 20
CTX_WIDTH       equ 140

section .text

extern wm_create_window_ex
extern fat16_file_count
extern fat16_get_entry
extern fat16_read_file
extern fat16_write_file
extern fat16_sync_root
extern fat16_change_dir
extern l3_slot_base
extern bb_addr
extern scr_pitch
extern mouse_debug_dump
extern xhci_debug_dump
extern i2c_hid_debug_dump
extern mouse_wait_input
extern fat16_debug_dump_root

section .data
kernel_render_rect_ptr dq render_rect
kernel_render_text_ptr dq render_text

section .text

%macro LOAD_ADDR 2
    call %%rip
%%rip:
    pop %1
    add %1, %2 - %%rip
%endmacro

app_sys_render_rect:
    APP_SYSNO 2
    mov r10, rcx
    syscall
    ret

app_sys_render_text:
    APP_SYSNO 3
    mov r10, rcx
    syscall
    ret


app_sys_fs_count:
    APP_SYSNO 4
    syscall
    ret

app_sys_fs_get_entry:
    APP_SYSNO 5
    syscall
    ret

app_sys_fs_change_dir:
    APP_SYSNO 6
    syscall
    ret

app_sys_fs_read:
    APP_SYSNO 8
    syscall
    ret

app_sys_fs_write_file:
    APP_SYSNO 13
    syscall
    ret

app_sys_fs_sync_root:
    APP_SYSNO 14
    syscall
    ret

app_sys_fs_delete:
    APP_SYSNO 19
    syscall
    ret

app_sys_fs_rename:
    APP_SYSNO 20
    syscall
    ret

app_sys_fs_mkdir:
    APP_SYSNO 21
    syscall
    ret

app_sys_wm_close_window:
    APP_SYSNO 15
    syscall
    ret

app_sys_display_set_mode:
    APP_SYSNO 16
    syscall
    ret

app_sys_cursor_init:
    APP_SYSNO 17
    syscall
    ret

%xdefine render_rect app_sys_render_rect
%xdefine render_text app_sys_render_text
%xdefine fat16_file_count app_sys_fs_count
%xdefine fat16_get_entry app_sys_fs_get_entry
%xdefine fat16_read_file app_sys_fs_read
%xdefine fat16_change_dir app_sys_fs_change_dir
%xdefine fat16_write_file app_sys_fs_write_file
%xdefine fat16_sync_root app_sys_fs_sync_root
%xdefine fat16_delete_entry app_sys_fs_delete
%xdefine fat16_rename_entry app_sys_fs_rename
%xdefine fat16_mkdir app_sys_fs_mkdir
%xdefine wm_close_window app_sys_wm_close_window
%xdefine display_set_mode app_sys_display_set_mode
%xdefine cursor_init app_sys_cursor_init

global app_l3_test_draw
global app_l3_test_click
global app_l3_test_key
; app_terminal_kernel_draw/key removed — Terminal migrated to NexusHL.

