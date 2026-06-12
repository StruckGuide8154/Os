; ============================================================================
; Grit v3.0 - Application Framework + Built-in Apps
; Split into per-app/source includes to keep userland code maintainable while
; preserving the monolithic kernel build.
; ============================================================================

%include "trace.inc"
; Syscall-immediate fixup table support (security_todo.md §12). Defines the
; APP_SYSNO macro every syscall site in this blob uses, plus the .scfix
; section the records accumulate into. app_blob_start (below) is the anchor
; the recorded offsets are relative to.
%include "app_sysno.inc"

; Neutralize extern/global so this file assembles both inside the monolithic
; kernel build AND as a standalone flat binary (APPS.BIN).
%ifmacro extern 1-*
%unmacro extern 1-*
%endif
%macro extern 1-*
%endmacro
%ifmacro global 1-*
%unmacro global 1-*
%endif
%macro global 1-*
%endmacro

; Redirect direct kernel render calls to local syscall wrappers so that
; when the blob is copied to a user slot and runs in Ring 3, all relative
; calls stay within the blob (correct rel32) and use the syscall ABI.
%define render_rect  app_sys_render_rect
%define render_text  app_sys_render_text

; Start of the syscall-immediate fixup table (security_todo.md §12). Every
; APP_SYSNO record appended by the app blob below lands in .scfix between this
; label and app_syscall_fixups_end; the loader walks [start, end). align=1 +
; defining the start label first keeps the records 5-byte packed (see the
; APP_SYSNO macro / app_sysno.inc).
[section .scfix align=1]
global app_syscall_fixups_start
app_syscall_fixups_start:
__SECT__

; Per-app integrity manifest format contract (segment labels + table macros).
%include "app_manifest.inc"

global app_blob_start
app_blob_start:
; 16-byte sentinel so a post-build extraction can locate this blob inside
; kernel.bin without needing NASM symbol maps.
db 0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F    ; "GRAPPBLO"
db 0x42, 0x53, 0x54, 0x52, 0x54, 0xDE, 0xAD, 0xBE    ; "BSTRT" + 0xDEADBE
; --- Segment 0: common glue (boot trampoline + common/state/launch) -------
app_seg_common_start:
global app_l3_done_trampoline
app_l3_done_trampoline:
    APP_SYSNO 10                         ; SYS_APP_DONE (permuted per-slot)
    syscall
    ud2
%include "src/user/apps/common.inc"
; state.inc must come BEFORE any large code blob: every symbol it defines
; (notepad_buf, np_line_len, ...) is accessed slot-relative as
; `slot_base + (sym - app_blob_start)`, so the offset MUST fit within
; APP_SLOT_SIZE (1 MB) AND L3_APP_BLOB_COPY_CAP. Pushed below the >1 MB of
; generated GritHL code it overflows the slot and every notepad ends up
; aliasing into the next slot's memory.
%include "src/user/apps/state.inc"
%include "src/user/apps/launch.inc"
app_seg_common_end:
; explorer.inc deleted - Explorer is now a pure-GritHL app built by
; build_ghl.ps1 and included via build/ghl/generated_apps.inc below.
; terminal.inc deleted - Terminal is now a pure-GritHL app
; (src/user/grithl/apps/terminal.ghl) built by build_ghl.ps1 and included via
; build/ghl/generated_apps.inc below.
%define DISABLE_FN_RUNTIME_TRACE
%include "build/ghl/generated_apps.inc"
%undef DISABLE_FN_RUNTIME_TRACE
; about.inc deleted - About is now a pure-GritHL app built by build_ghl.ps1
; and included via build/ghl/generated_apps.inc above.
app_seg_shell_start:
%include "src/user/apps/shell.inc"
app_seg_shell_end:
; paint.inc deleted - Paint is now a pure-GritHL app built by build_ghl.ps1
; and included via build/ghl/generated_apps.inc above.
%ifndef RELEASE_BUILD
app_seg_security_probe_start:
%include "src/user/apps/security_probe.inc"
app_seg_security_probe_end:
%endif
app_seg_media_viewer_start:
%include "src/user/apps/media_viewer.inc"
app_seg_media_viewer_end:
; End sentinel (16 bytes, distinct from start marker).
db 0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F    ; "GRAPPBLO"
db 0x42, 0x45, 0x4E, 0x44, 0x21, 0xCA, 0xFE, 0xBE    ; "BEND!" + 0xCAFEBE
global app_blob_end
app_blob_end:

; End of the syscall-immediate fixup table (see app_syscall_fixups_start).
[section .scfix align=1]
global app_syscall_fixups_end
app_syscall_fixups_end:
__SECT__

; ============================================================================
; Per-app integrity manifest table (docs/per-app-integrity-manifest.md).
; Lives OUTSIDE [app_blob_start, app_blob_end) so it is not covered by the
; whole-blob HMAC and so its build-patched bytes never perturb the blob digest.
; Offsets in each entry are blob-relative (= seg_start - app_blob_start), which
; is slide-independent. The build tool (gen_app_manifest.py) locates this table
; via APP_MANIFEST_MARKER, fills each entry's sha256[] and the trailing mac[].
; app_id/offset/size and count are assemble-time constants emitted here.
;
; app_id <-> segment mapping (see app_manifest.inc for id constants):
;   0   common glue (trampoline + common/state/launch)
;   2   explorer    3 terminal   4 notepad    5 settings   6 paint
;   7   about       9 taskmgr   10 ping      11 media (GritHL media app)
;   8   security_probe (debug only)
;   100 hello (debug only)  101 wallpaper  102 shell   103 media_viewer (asm app)
; The GritHL apps (2..11,100,101) are wrapped by app_seg_<name>_start/_end in
; build/ghl/generated_apps.inc (emitted by build_ghl.ps1).
; ============================================================================
section .data
global app_integrity_table
app_integrity_table:
    APP_MANIFEST_MARKER
%ifndef RELEASE_BUILD
    dd 15                                ; count (incl. security_probe)
%else
    dd 13                                ; count (debug-only apps excluded)
%endif
    ; --- entries (44 bytes each) ---
    APP_MANIFEST_ENTRY APP_SEG_COMMON,      app_seg_common_start,        app_seg_common_end
    APP_MANIFEST_ENTRY APP_EXPLORER,        app_seg_explorer_start,      app_seg_explorer_end
    APP_MANIFEST_ENTRY APP_TERMINAL,        app_seg_terminal_start,      app_seg_terminal_end
    APP_MANIFEST_ENTRY APP_NOTEPAD,         app_seg_notepad_start,       app_seg_notepad_end
    APP_MANIFEST_ENTRY APP_SETTINGS,        app_seg_settings_start,      app_seg_settings_end
    APP_MANIFEST_ENTRY APP_PAINT,           app_seg_paint_start,         app_seg_paint_end
    APP_MANIFEST_ENTRY APP_ABOUT,           app_seg_about_start,         app_seg_about_end
    APP_MANIFEST_ENTRY APP_TASKMGR,         app_seg_taskmgr_start,       app_seg_taskmgr_end
    APP_MANIFEST_ENTRY APP_PING,            app_seg_ping_start,          app_seg_ping_end
    APP_MANIFEST_ENTRY APP_MEDIA,           app_seg_media_start,         app_seg_media_end
%ifndef RELEASE_BUILD
    APP_MANIFEST_ENTRY APP_SEG_HELLO,       app_seg_hello_start,         app_seg_hello_end
%endif
    APP_MANIFEST_ENTRY APP_SEG_WALLPAPER,   app_seg_wallpaper_start,     app_seg_wallpaper_end
    APP_MANIFEST_ENTRY APP_SEG_SHELL,       app_seg_shell_start,         app_seg_shell_end
%ifndef RELEASE_BUILD
    APP_MANIFEST_ENTRY APP_SECURITY_PROBE,  app_seg_security_probe_start, app_seg_security_probe_end
%endif
    APP_MANIFEST_ENTRY APP_SEG_MEDIA_VIEWER, app_seg_media_viewer_start, app_seg_media_viewer_end
    ; --- pad unused entries to APP_MANIFEST_MAX ---
%ifndef RELEASE_BUILD
    times (APP_MANIFEST_MAX - 15) * APP_MANIFEST_ENTRY_SIZE db 0
%else
    times (APP_MANIFEST_MAX - 13) * APP_MANIFEST_ENTRY_SIZE db 0
%endif
    ; --- mac (build-tool filled) ---
    times 32 db 0
global app_integrity_table_end
app_integrity_table_end:
__SECT__
section .text
