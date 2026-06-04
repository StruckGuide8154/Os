; ============================================================================
; NexusOS v3.0 - System Call Handler (64-bit Long Mode)
; Clean L3 syscall path. Saves user state before any helper calls.
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"
%include "l3_runtime.inc"
%include "trace.inc"
%include "syscall_caps.inc"
%include "kdomain_hmac.inc"       ; one domain-separated HMAC primitive (§13)
%include "shadow_stack.inc"
%include "syscall_trace.inc"
%include "qrng_seed.inc"          ; quantum entropy blob folded into the canary

; MSR Addresses for Syscall
IA32_EFER           equ 0xC0000080
IA32_STAR           equ 0xC0000081
IA32_LSTAR          equ 0xC0000082
IA32_FMASK          equ 0xC0000084

WIN_OFF_FLAGS       equ 40
WIN_OFF_KEYFN       equ 120
WIN_OFF_CLICKFN     equ 128
WIN_OFF_APPDATA     equ 136
WIN_OFF_DRAGFN      equ 144
WIN_OFF_RCLICKFN    equ 152
DIR_ENTRY_SIZE      equ 32
%ifdef NEXUS_CACHE32_MAX
FAT16_ROOT_CACHE    equ 0x1A11000
%else
FAT16_ROOT_CACHE    equ 0xD11000
%endif
FAT16_ROOT_CACHE_SZ equ 16384
; Upper bound on the valid-entry index ring 3 may request from SYS_FS_ENTRY.
; Matches the root-cache slot count (volume label / LFN / deleted entries are
; skipped by fat16_get_entry so the true count is lower; we just need a
; sanity ceiling before calling out).
FAT16_MAX_ENTRIES   equ FAT16_ROOT_CACHE_SZ / DIR_ENTRY_SIZE
; Size of the user-visible SYS_FS_ENTRY_INFO struct. Keep in sync with the
; layout documented in syscall_user.inc.
FS_ENTRY_INFO_SIZE  equ 20
SYSCALL_MAX_STR_LEN equ 256
APP_MIN_ID          equ 2
APP_MAX_ID          equ 11
APP_OPEN_CMD_MAX    equ 256
SYSCALL_ENTRY_SIZE  equ 24
SYSCALL_HANDLER_OFF equ 0
SYSCALL_ARGC_OFF    equ 8
SYSCALL_KIND_OFF    equ 9
; Single-byte cap mask packed into what used to be a padding byte.
SYSCALL_CAP_OFF     equ 13
; Single-byte per-entry flags packed into a former padding byte (offset 14).
; SC_FLAG_STRICT (security_todo.md §2, "Mandatory non-zero arg_desc for every
; PTR arg") opts a row into deny-on-unmigrated: any FN_KIND_PTR arg whose
; arg_desc nibble is still 0 (never migrated to a sibling-length descriptor)
; is rejected by the validator instead of falling back to the legacy 1-byte
; probe. Lets rows be flipped to strict one at a time as their descriptors
; land; un-flagged rows keep the legacy probe.
SYSCALL_FLAGS_OFF   equ 14
SC_FLAG_STRICT      equ 0x01
; Optional per-arg descriptor qword. 4 bits per arg (6 args = 24 bits used);
; nibble N != 0 means "byte length of this PTR arg lives in scalar arg
; (nibble - 1)". The validator pulls that sibling and uses it as the real
; range length, instead of the 1-byte probe. The "one missed handler is a
; bug" pattern goes away — the dispatcher always range-validates, even when
; the handler forgets. Reserved bits stay zero for future alignment/NUL-cap
; descriptors. Encode with SC_DESC_LEN / SC_DESC macros below.
SYSCALL_ARG_DESC_OFF equ 16

; Slot-internal layout — duplicate of usermode.asm's locals; see
; boot_memory.inc for the canonical definition. NASM `equ` cannot be
; %ifndef-guarded, so syscall.asm declares them locally instead of
; including a shared header.
L3_APP_CODE_OFF     equ 512
L3_SHADOW_WIN_OFF   equ (APP_SLOT_SIZE - 512)
L3_SYSCALL_FRAME_SLOT_OFF equ 120
L3_APP_CODE_OFF     equ 512
L3_SHADOW_WIN_OFF   equ (APP_SLOT_SIZE - 512)
L3_SLOT_MAGIC_OFF   equ 0
L3_SLOT_MAGIC       equ 0x30544F4C5358414E


; Variables moved to the end of file to avoid segment clobbering in monolithic build.

extern debug_print
extern scene_dirty
; Nested-kernel monitor (nk_monitor.asm): the WX page-flip syscalls edit
; APP_ARENA_PT_BASE PTEs, which live in the page-table region locked read-only
; in Phase 2 — bracket those writes in a WP-off window.
extern nk_pt_window_begin
extern nk_pt_window_end
extern fat16_file_count
extern fat16_get_entry
extern fat16_change_dir
extern fat16_read_file
extern fat16_format_name
extern fat16_write_file
extern fat16_delete_entry
extern fat16_rename_entry
extern fat16_mkdir
extern fat16_sync_root
extern wm_create_window_ex
extern wm_close_window
extern app_launch
extern kernel_open_file_in_notepad
extern kernel_open_file_in_media
extern nx_media_blit_scaled

; Bounds for the SYS_MEDIA_BLIT_SCALED syscall (sc_media_blit_scaled).
; Documented at the syscall's call site; centralised here so a future
; tuning pass (e.g. raising the limit for 8K still images) edits one place.
MEDIA_MAX_DIM   equ 4096
MEDIA_MAX_BYTES equ 64 * 1024 * 1024
extern kernel_open_app_command
extern display_set_mode
extern cursor_init
extern vsync_enabled
extern fps_show
extern display_stretch
extern fb_native_width
extern fb_native_height
extern amd_display_active
extern amd_display_status
extern amd_display_bdf
extern amd_display_id
extern amd_display_class
extern amd_display_bar0
extern amd_display_cmd
extern desktop_bg_theme
extern wallpaper_selected
extern wallpaper_cache_valid
extern wallpaper_cache_presented
extern wallpaper_render_active
extern render_rect
extern render_text
extern scr_width
extern scr_height
extern l3_current_slot
extern l3_runtime
extern l3_syscall_stacks
extern call_app_l3_return
extern ser_print_hex64
extern serial_puts
extern serial_putc
extern serial_crlf
extern app_blob_base_v
extern app_blob_end_v
extern l3_app_arena_base_v
extern l3_app_arena_size_v
extern l3_apply_wx_policy
extern l3_slot_live
extern l3_wx_manifest_ver
extern l3_wx_code_start
extern l3_wx_code_end
extern l3_slot_code_slide
extern trace_syscall
extern last_fps
extern free_page_count
extern boot_free_pages
extern total_usable_pages
extern cpu_tsc_per_tick
extern cpuid_logical_count
extern bsp_util
extern smp_core_states
extern madt_enabled_cpu_count
extern xml_parse
extern xml_root
extern xml_tag
extern xml_tag_name
extern xml_first_child
extern xml_next_sibling
extern xml_parent
extern xml_attr
extern xml_text
extern xml_free
extern xml_last_error
extern xml_node_count
extern xml_text_runs
extern xml_text_run
extern xml_namespace
extern xml_node_namespace
extern xml_entity_value
extern draw_line
extern fill_circle
extern fill_triangle
extern blend_pixel
extern blend_span
extern blend_span_argb
extern blend_span_argb_screen
extern blend_span_argb_multiply
extern raster_select_syscall_target
extern raster_select_default_target
extern raster_sc_release_target
extern net_ping_ipv4
extern net_info
extern net_dhcp_configure
extern net_dhcp_start
extern net_tcp_connect_ipv4
extern rtl8156_dhcp_state

L3_RT_ENTRY          equ 0
L3_RT_ARG0           equ 8
L3_RT_ARG1           equ 16
L3_RT_ARG2           equ 24
L3_RT_KERNEL_RSP     equ 32

section .text

FN_BEGIN syscall_init, 0, 0, FN_RET_VOID
    ; BSP path: do the per-CPU MSR setup, then print the LSTAR target so the
    ; serial log records where syscall_entry actually lives.
    call syscall_init_this_cpu
    push rdi
    push rax
    lea rax, [rel syscall_entry]
    SER 'L'
    mov rdi, rax
    call ser_print_hex64
    SER 13
    SER 10
    pop rax
    pop rdi
    FN_END syscall_init
    ret

; ----------------------------------------------------------------------------
; syscall_init_this_cpu - program the SYSCALL/SYSRET MSRs on the calling CPU.
; EFER, STAR, LSTAR, and FMASK are all per-CPU MSRs, so every core that will
; ever take a SYSCALL must run this once. The BSP calls it via syscall_init;
; each AP calls it from ap_long_mode_init (apic.asm) so an app callback
; dispatched to an AP in Stage 2c lands in syscall_entry just like on the BSP.
;
; Preserves every caller-visible register (rax/rcx/rdx clobbered internally
; for wrmsr; we save and restore them).
; ----------------------------------------------------------------------------
FN_BEGIN syscall_init_this_cpu, 0, 0, FN_RET_VOID
    push rax
    push rcx
    push rdx

    mov ecx, IA32_EFER
    rdmsr
    or eax, 1                      ; SCE: enable SYSCALL/SYSRET
    wrmsr

    mov ecx, IA32_STAR
    xor eax, eax
    mov edx, 0x001B0008            ; kernel CS=0x08, user CS base=0x1B
    wrmsr

    mov ecx, IA32_LSTAR
    lea rax, [rel syscall_entry]
    mov rdx, rax
    shr rdx, 32
    wrmsr

    mov ecx, IA32_FMASK
    mov eax, 0x00057700            ; mask IF, DF, AC etc on entry
    xor edx, edx
    wrmsr

    pop rdx
    pop rcx
    pop rax
    FN_END syscall_init_this_cpu
    ret

; auto-wrapped (FN_BEGIN emits global): global syscall_entry
%include "src/kernel/proc/syscall_validation.inc"
%include "src/kernel/proc/handle_table.inc"

FN_DECL syscall_entry, 0, 0, FN_RET_SCALAR
%include "src/kernel/proc/syscall_dispatch_core.inc"
%include "src/kernel/proc/syscall_handlers_gui_wm.inc"
%include "src/kernel/proc/syscall_handlers_sys_fs.inc"
%include "src/kernel/proc/syscall_handlers_xml_draw.inc"
%include "src/kernel/proc/syscall_handlers_wx_net.inc"
%include "src/kernel/proc/syscall_epilogue.inc"
%include "src/kernel/proc/syscall_support.inc"
%include "src/kernel/proc/syscall_security.inc"
%include "src/kernel/proc/syscall_data.inc"
%include "src/kernel/proc/syscall_perm.inc"
