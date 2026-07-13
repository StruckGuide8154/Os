$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

function Assert-Match {
    param(
        [string[]]$Path,
        [string]$Pattern,
        [string]$Message
    )

    $content = ($Path | ForEach-Object { Get-Content -Path $_ -Raw }) -join "`n"
    if ($content -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotMatch {
    param(
        [string[]]$Path,
        [string]$Pattern,
        [string]$Message
    )

    $content = ($Path | ForEach-Object { Get-Content -Path $_ -Raw }) -join "`n"
    if ($content -match $Pattern) {
        throw $Message
    }
}

$syscallPath = @(
    (Join-Path $Root 'src\kernel\proc\syscall.asm')
    (Get-ChildItem (Join-Path $Root 'src\kernel\proc\syscall_*.inc') | ForEach-Object FullName)
)
$syscallValidationPath = @(
    (Join-Path $Root 'src\kernel\proc\syscall_validation.inc')
    (Join-Path $Root 'src\kernel\grithlk\syscall_validate.ghl')
)
$syscallUserPath = Join-Path $Root 'src\include\syscall_user.inc'
$displayPath = @(
    (Join-Path $Root 'src\kernel\drivers\display.asm')
    (Get-ChildItem (Join-Path $Root 'src\kernel\drivers\display_*.inc') | ForEach-Object FullName)
)
$usermodePath = @(
    (Join-Path $Root 'src\kernel\proc\usermode.asm')
    # Callback entry/return migrated to structured GritHLK; keep guards on the
    # source of truth rather than requiring the retired assembly spelling.
    (Join-Path $Root 'src\kernel\grithlk\usermode_callbacks.ghl')
    (Join-Path $Root 'src\kernel\grithlk\usermode_translate.ghl')
)
$windowPath = @(
    (Join-Path $Root 'src\kernel\gui\window.asm')
    (Get-ChildItem (Join-Path $Root 'src\kernel\gui\window_*.inc') | ForEach-Object FullName)
    (Join-Path $Root 'src\kernel\grithlk\wm_helpers.ghl')
)
$processCallbacksPath = Join-Path $Root 'src\kernel\grithlk\callback_dispatch.ghl'
$inputDispatchPath = Join-Path $Root 'src\kernel\grithlk\input_dispatch.ghl'
$appsPath = Join-Path $Root 'build\ghl\explorer.asm'
$wrapperPath = Join-Path $Root 'src\user\apps.asm'
$launchPath = @(
    (Get-ChildItem (Join-Path $Root 'src\user\apps\launch*.inc') | ForEach-Object FullName)
)
$pagingPath = Join-Path $Root 'src\boot\paging.asm'
$userWindowPath = Join-Path $Root 'src\user\lib\grit_window.inc'
$paintPath = Join-Path $Root 'src\user\grithl\apps\paint.ghl'
$ghlBuildPath = Join-Path $Root 'scripts\build\build_ghl.ps1'
$ghlNotepadPath = Join-Path $Root 'src\user\grithl\apps\notepad.ghl'
$ghlExplorerPath = Join-Path $Root 'src\user\grithl\apps\explorer.ghl'
$ghlMediaPath = Join-Path $Root 'src\user\grithl\apps\media.ghl'
$ghlWallpaperPath = Join-Path $Root 'src\user\grithl\apps\wallpaper.ghl'
$mediaViewerPath = @(
    (Get-ChildItem (Join-Path $Root 'src\user\apps\media_viewer*.inc') | ForEach-Object FullName)
)
$bootAnimGenPath = Join-Path $Root 'tools\gen_boot_anim.py'
$uefiBuildPath = Join-Path $Root 'scripts\build\build_uefi.ps1'
$biosBuildPath = Join-Path $Root 'scripts\build\build_bios.ps1'
# FAT16 is now a zero-asm GHL driver (src/kernel/grithlk/fat16_core.ghl); the
# legacy src/kernel/fs/fat16*.asm/.inc were deleted in the FS zero-asm migration.
$fat16Path = @(
    (Join-Path $Root 'src\kernel\grithlk\fat16_core.ghl')
)

Write-Host '[guards] Checking user/kernel structure...' -ForegroundColor Yellow
Assert-Match $wrapperPath 'src/user/apps/common\.inc' 'apps.asm must include the split user app tree.'
Assert-Match $wrapperPath 'build/ghl/generated_apps\.inc' 'apps.asm must include GritHL generated app output.'
Assert-NotMatch $wrapperPath 'src/user/apps/notepad\.inc' 'Notepad must ship through the GritHL SDK path, not the old hand-written include.'
Assert-Match $wrapperPath 'app_blob_start:' 'apps.asm must expose app_blob_start for syscall validation.'
Assert-Match $wrapperPath 'app_blob_end:' 'apps.asm must expose app_blob_end for syscall validation.'
Assert-Match $pagingPath 'mov eax, PAGE_PRESENT \| PAGE_WRITABLE \| PAGE_LARGE' 'Paging must map kernel memory supervisor-only by default.'
Assert-Match $pagingPath 'or eax, PAGE_USER' 'Paging must explicitly mark only the user app arena as user-accessible.'

Write-Host '[guards] Checking syscall hardening...' -ForegroundColor Yellow
Assert-Match $syscallPath 'syscall_validation\.inc' 'syscall.asm must include the syscall validation owner file.'
Assert-Match $syscallPath '\.sc_print:[\s\S]*call sc_validate_user_cstring' 'SYS_PRINT must validate user strings.'
Assert-Match $syscallPath '\.sc_gui_text:[\s\S]*call sc_validate_user_cstring' 'SYS_GUI_TEXT must validate user strings.'
Assert-Match $syscallPath '\.sc_wm_create:[\s\S]*call sc_validate_callback_target' 'SYS_WM_CREATE must validate callback targets.'
Assert-Match $syscallPath '\.sc_fs_read:[\s\S]*call sc_resolve_dir_entry_arg' 'SYS_FS_READ must resolve dir-entry handles through the per-slot handle table.'
Assert-Match $syscallPath '\.sc_fs_write:[\s\S]*call sc_validate_user_io_range' 'SYS_FS_WRITE must validate user buffers.'
Assert-Match $syscallPath '\.sc_fs_delete:[\s\S]*call sc_resolve_dir_entry_arg[\s\S]*call fat16_delete_entry' 'SYS_FS_DELETE must resolve handles through the handle table before mutating the FAT16 cache.'
Assert-Match $syscallPath '\.sc_fs_rename:[\s\S]*call sc_resolve_dir_entry_arg[\s\S]*call sc_validate_user_range[\s\S]*call fat16_rename_entry' 'SYS_FS_RENAME must resolve handles through the handle table and validate the 11-byte user name.'
Assert-Match $syscallPath '\.sc_fs_mkdir:[\s\S]*call sc_validate_user_range[\s\S]*call fat16_mkdir' 'SYS_FS_MKDIR must validate the 11-byte user name.'
Assert-Match $syscallPath '\.sc_open_file_np:[\s\S]*\.sc_open_file_np_media:[\s\S]*call kernel_open_file_in_media' 'SYS_OPEN_FILE_NP must redirect known media formats to Media Player.'
Assert-Match $syscallPath '\.sc_app_open:[\s\S]*call sc_validate_user_cstring[\s\S]*call kernel_open_app_command' 'SYS_APP_OPEN must validate the user command string before launching apps.'
Assert-Match $syscallUserPath '%macro SYS_APP_OPEN 1[\s\S]*APP_SYSNO 23[\s\S]*syscall' 'SYS_APP_OPEN user wrapper must call syscall 23 through the permutation macro.'
Assert-Match $syscallPath 'APP_MAX_ID\s+equ 11' 'SYS_APP_LAUNCH must allow the Media Player app id without exposing parked app ids.'
Assert-Match $syscallPath 'SC_VALIDATE_FRAME_OFF equ 72[\s\S]*add eax, SC_VALIDATE_FRAME_OFF[\s\S]*mov rdi, \[rsp \+ rax\]' 'Table-driven syscall validation must read the selected arg from the saved register slot through the helper call frame (constant-time displacement).'
Assert-Match $syscallPath '\.check_ptr_sibling:[\s\S]*push rdx[\s\S]*push rdi[\s\S]*push r8[\s\S]*add eax, SC_VALIDATE_FRAME_OFF \+ 16[\s\S]*mov rsi, \[rsp \+ rax\]' 'Sibling-length validation must account for all three saved qwords and the absent helper return address when reading the syscall frame.'
Assert-Match $syscallPath 'SC_DESC_WRITE_SHIFT\s+equ 48[\s\S]*%define SC_DESC_WRITE\(arg_idx\)' 'Pointer descriptors must reserve the upper-qword write-direction bitmap.'
Assert-Match $syscallPath '\.check_ptr_do:[\s\S]*bt r13, rax[\s\S]*call sc_validate_user_range[\s\S]*\.check_ptr_do_write:[\s\S]*call sc_validate_user_write' 'Pointer direction must make the dispatcher select the slot-only output validator.'
Assert-Match $syscallPath 'sc_fs_read[^\r\n]*SC_DESC_WRITE\(1\)[\s\S]*sc_fs_format_name[^\r\n]*SC_DESC_WRITE\(1\)[\s\S]*sc_fs_entry_info[^\r\n]*SC_DESC_WRITE\(1\)[\s\S]*sc_wm_list[^\r\n]*SC_DESC_WRITE\(0\)' 'All filesystem/window-manager output buffers must be write-directed in the syscall table.'
Assert-Match $syscallPath 'sc_xml_tag_name[^\r\n]*SC_DESC_WRITE\(1\)[\s\S]*sc_xml_attr[^\r\n]*SC_DESC_WRITE\(3\)[\s\S]*sc_xml_text[^\r\n]*SC_DESC_WRITE\(1\)[\s\S]*sc_xml_text_run[^\r\n]*SC_DESC_WRITE\(2\)[\s\S]*sc_xml_namespace[^\r\n]*SC_DESC_WRITE\(3\)[\s\S]*sc_xml_node_namespace[^\r\n]*SC_DESC_WRITE\(1\)[\s\S]*sc_xml_entity_value[^\r\n]*SC_DESC_WRITE\(2\)' 'All XML output buffers must be write-directed in the syscall table while XML name/value inputs remain read-directed.'
Assert-NotMatch $syscallPath 'sc_fs_write[^\r\n]*SC_DESC_WRITE|sc_xml_parse[^\r\n]*SC_DESC_WRITE|sc_blend_span_argb[^\r\n]*SC_DESC_WRITE' 'Input-only syscall pointers must retain read direction so legitimate shared-blob inputs remain supported.'
Assert-Match $syscallPath '\.sc_wm_handlers:[\s\S]*cmp rdi, MAX_WINDOWS[\s\S]*jae \.sc_wm_handlers_reject' 'SYS_WM_HANDLERS must reject out-of-range window ids.'
Assert-Match $syscallPath '\.sc_wm_handlers:[\s\S]*call sc_validate_callback_target' 'SYS_WM_HANDLERS must validate handler targets.'
Assert-Match $syscallPath '\.sc_wm_handlers:[\s\S]*mov rsi, \[rsp \+ ALL_RSI\][\s\S]*mov rdx, \[rsp \+ ALL_RDX\][\s\S]*call cpi_sign_callback[\s\S]*mov \[rax \+ WIN_OFF_CLICKFN\], r10' 'SYS_WM_HANDLERS must reload handler pointers after validation clobbers RSI/RDX, then store the CPI-signed callback.'
Assert-Match $syscallPath '\.sc_display_set_mode:[\s\S]*BOOT_BACK_BUFFER_SIZE / 4[\s\S]*\.sc_display_set_mode_reject' 'SYS_DISPLAY_SET_MODE must reject modes that exceed the boot back buffer.'
Assert-NotMatch $syscallPath 'APP_BMP_FILE_BUF|APP_CANVAS_BUF' 'Kernel syscall validation must not whitelist shared global app scratch buffers anymore.'
Assert-Match $syscallValidationPath '(sc_validate_user_range:|fn sc_validate_user_range)[\s\S]*app_blob_base_v[\s\S]*app_blob_end_v' 'User range validation must allow current slot and built-in user blob.'
Assert-Match (Join-Path $Root 'src\kernel\proc\handle_table.inc') 'handle_resolve:[\s\S]*HANDLE_MAGIC[\s\S]*HANDLE_TABLE_CAP[\s\S]*HANDLE_ENT_GEN_OFF' 'Handle resolution must check magic, index range, kind tag, and stored generation.'
Assert-Match $syscallPath 'sc_resolve_dir_entry_arg:[\s\S]*HANDLE_KIND_DIR_ENTRY[\s\S]*call handle_resolve[\s\S]*call fat16_get_entry' 'Dir-entry handle resolution must go through the handle table and fat16_get_entry - no kernel VA may flow through the syscall boundary.'
Assert-NotMatch $syscallPath 'call\s+sc_validate_dir_entry_handle|call\s+sc_dir_entry_handle_to_kernel' 'Legacy snapshot-pointer dir-entry validators must stay removed - no syscall handler may call them.'
Assert-NotMatch $syscallValidationPath '^sc_validate_dir_entry_handle:' 'Legacy sc_validate_dir_entry_handle definition must stay removed from syscall_validation.inc.'
Assert-Match $syscallValidationPath '(sc_validate_callback_target:|fn sc_validate_callback_target)[\s\S]*call sc_validate_user_range' 'Callback targets must validate through user range validation.'
Assert-Match $displayPath '(display_set_mode:|FN_BEGIN display_set_mode)[\s\S]*BOOT_BACK_BUFFER_SIZE / 4[\s\S]*\.set_fail' 'display_set_mode must reject modes that exceed the boot back buffer.'
Assert-Match $fat16Path 'fn fat16_mkdir\([\s\S]*fat16_flush_fats\(\);[\s\S]*fat16_flush_current_dir\(\);' 'FAT16 mkdir must create persistent directories through FAT and directory flushes.'
Assert-Match $fat16Path 'fn fat16_delete_entry\([\s\S]*fat16_flush_fats\(\);[\s\S]*fat16_flush_current_dir\(\);' 'FAT16 delete must persist FAT and directory changes.'
Assert-Match $fat16Path 'fn fat16_rename_entry\([\s\S]*fat16_flush_current_dir\(\);' 'FAT16 rename must persist directory metadata.'

Write-Host '[guards] Checking L3 callback isolation...' -ForegroundColor Yellow
Assert-Match $usermodePath '(fn call_app_l3\(\) naked|call_app_l3:|FN_DECL call_app_l3)[\s\S]*(save_rsp\(lq\(&cb_rt\) \+ L3_RT_KERNEL_RSP\)|call l3_runtime_ptr[\s\S]*mov \[r12 \+ L3_RT_KERNEL_RSP\], rsp)' 'L3 callbacks must save kernel return state in slot-local runtime storage.'
Assert-Match $usermodePath '(fn l3_prepare_callback\([\s\S]*l3_install_app_done_trampoline[\s\S]*fn call_app_l3\(\) naked[\s\S]*iretq\(\)|(?:call_app_l3:|FN_DECL call_app_l3)[\s\S]*call l3_install_app_done_trampoline[\s\S]*iretq)' 'L3 callbacks must enter ring 3 through the app-done trampoline and iretq.'
Assert-Match $usermodePath '(FN_BEGIN l3_translate_target|fn l3_translate_target\()[\s\S]*l3_app_arena_base_v' 'L3 target translation must recognize callback pointers from app slots.'
Assert-Match $usermodePath '(FN_BEGIN l3_translate_target[\s\S]*and rax, APP_SLOT_SIZE - 1[\s\S]*cmp rax, \[rel app_blob_size_v\]|fn l3_translate_target\([\s\S]*\(target - abase\) & SLOT_MASK[\s\S]*bo >= lq\(&app_blob_size_v\))' 'L3 target translation must preserve only the app-blob offset from slot-local callback pointers.'
Assert-Match $usermodePath '(fn call_app_l3_return\(\) naked|call_app_l3_return:|FN_DECL call_app_l3_return)[\s\S]*l3_runtime_ptr[\s\S]*(write_rsp\(lq\(lq\(&cb_rt\) \+ L3_RT_KERNEL_RSP\)\)|mov rsp, \[r12 \+ L3_RT_KERNEL_RSP\])' 'L3 return must restore kernel stack from slot-local runtime storage.'
Assert-Match $syscallPath '(syscall_entry:|FN_(BEGIN|DECL) syscall_entry)[\s\S]*mov \[rbx \+ L3_RT_USER_RSP\], rsp[\s\S]*mov \[rbx \+ L3_RT_USER_RIP\], rcx' 'Syscall entry must save user RIP/RSP in slot-local runtime storage before leaving the user stack.'
Assert-Match $syscallPath '(syscall_entry:|FN_(BEGIN|DECL) syscall_entry)[\s\S]*imul rsp, rsp, L3_SYSCALL_STACK_STRIDE[\s\S]*mov rbx, L3_SYSCALL_STACK_ADDR[\s\S]*add rsp, rbx' 'Syscall entry must switch to a slot-local kernel syscall stack before dispatch.'

Write-Host '[guards] Checking multicore app routing build flags...' -ForegroundColor Yellow
Assert-Match $uefiBuildPath "GRIT_CACHE32_AP_STARTUP'[\s\S]*GRIT_ENABLE_RING3_AP" 'UEFI AP startup builds must enable ring-3 AP callback routing.'
Assert-Match $biosBuildPath "PerfProfile -eq 'Cache32Max'[\s\S]*GRIT_SMP'[\s\S]*GRIT_CACHE32_AP_STARTUP'[\s\S]*GRIT_ENABLE_RING3_AP" 'BIOS Cache32Max AP startup builds must enable SMP, AP startup, and ring-3 AP callback routing.'
Assert-Match $usermodePath '(FN_BEGIN call_app_l3_packed|fn call_app_l3_packed\()' 'AP-routed callbacks require the packed call_app_l3 thunk.'
Assert-Match $windowPath 'call dispatch_app_callback' 'Window manager callbacks must go through dispatch_app_callback.'
Assert-Match $inputDispatchPath '(call\s+dispatch_app_callback|dispatch_app_callback\()' 'Main-loop app input callbacks must go through dispatch_app_callback.'

Write-Host '[guards] Checking window bounds fix...' -ForegroundColor Yellow
Assert-Match $windowPath '(wm_close_window:|FN_BEGIN wm_close_window)[\s\S]*cmp rdi, MAX_WINDOWS[\s\S]*jae \.close_ret' 'wm_close_window must use an unsigned bounds check.'
Assert-Match $windowPath 'wm_close_window[\s\S]*call wm_focus_top_active[\s\S]*wm_focus_top_active:' 'Closing the focused window must transfer focus to another active visible window.'
Assert-Match $windowPath 'Slot 0 = native GritHL wallpaper renderer[\s\S]*mov esi, CAP_CORE \| CAP_GUI[\s\S]*call cap_mask_store' 'Hidden wallpaper slot must receive authenticated GUI capabilities before it issues display and raster syscalls.'
Assert-Match $windowPath 'wallpaper_render_job:[\s\S]*app_callback_lock[\s\S]*call call_app_l3_packed' 'Wallpaper cache generation must retain the full authored SVG renderer.'
Assert-Match $processCallbacksPath 'if lb\(&wallpaper_render_active\) != 0 \{ return 0; \}[\s\S]*let res = cb_run_guarded' 'Callback dispatch must not spin the BSP on the wallpaper renderer callback lock.'
Assert-Match $windowPath '(wm_click_focus_before[\s\S]*call (call_app_l3|dispatch_app_callback)[\s\S]*cmp rax, \[wm_click_focus_before\][\s\S]*\.click_preserve_focus|let focus_before = lq\(&wm_focused_window\)[\s\S]*dispatch_app_callback\([\s\S]*if lq\(&wm_focused_window\) == focus_before)' 'Window click callbacks that launch/focus another window must not be overwritten by post-callback focus restore.'
Assert-Match $windowPath 'cmp rax, app_media_draw[\s\S]*call app_media_draw' 'Media Player draw must stay in kernel context because its blitter reads kernel framebuffer globals.'
Assert-Match $launchPath 'kernel_open_file_in_notepad:[\s\S]*WIN_OFF_X\], 560[\s\S]*WIN_OFF_Y' 'Notepad windows opened from Explorer must leave the Explorer list visible for more file opens.'
Assert-Match $launchPath 'kernel_open_file_in_media:[\s\S]*APP_SLOT_BMP_FILE_SZ[\s\S]*LAUNCH_NBA1_MAGIC[\s\S]*\.kom_nba_validate_loaded:[\s\S]*div ecx[\s\S]*APP_SLOT_BMP_FILE_OFF \+ 12' 'Media opener must clamp NBA frame_count to the bytes loaded into the selected slot/full-clip buffer.'
Assert-Match $mediaViewerPath 'app_hl_media_mp_frame - app_blob_start[\s\S]*nx_media_draw_nba_controls' 'Media Player NBA renderer must use per-window frame state and draw controls.'
Assert-Match $ghlMediaPath 'fn click\(win, cx, cy\)[\s\S]*APP_SLOT_BMP_FILE_OFF[\s\S]*mp_handle_click' 'Media Player click handler must delegate to media_player lib (mp_handle_click) so the timeline widget stays reusable across apps.'
Assert-Match $bootAnimGenPath 'poster if i == 0 else render_frame' 'BOOTANIM.NBA frame 0 must be a non-black poster for Media Player preview.'
Assert-Match $inputDispatchPath 'fn process_mouse\(\)[\s\S]*let moved = mouse_check_moved\(\)[\s\S]*lb\(&mouse_buttons\) == lb\(&process_mouse_last_buttons\)[\s\S]*sb\(&process_mouse_last_buttons, btn\)' 'Mouse processing must notice button-only changes so release events clear held-click state.'
Assert-Match $inputDispatchPath 'fn pk_key_lclick\(\)[\s\S]*sb\(&mouse_buttons, BTN_LEFT\)[\s\S]*wm_handle_mouse_event\([\s\S]*sb\(&mouse_buttons, 0\)[\s\S]*wm_handle_mouse_event\([^\r\n]*, 0\)' 'Keyboard/serial left-click must send both mouse down and mouse up so later Explorer clicks are not treated as a held button.'
Assert-Match $inputDispatchPath 'fn pm_idle_cursor\(\)[\s\S]*wm_drag_window_id[\s\S]*cursor_hide\(\)[\s\S]*cursor_draw' 'Drag input must redraw the cursor immediately instead of waiting for a compositor frame.'
Assert-Match $inputDispatchPath 'let r = wm_handle_mouse_event\(x, y, btn\);[\s\S]*if r != 0[\s\S]*pm_idle_cursor\(\)' 'WM-consumed drag events must still refresh the pointer.'
$framePresentPath = Join-Path $Root 'src\kernel\grithlk\frame_present.ghl'
Assert-Match $framePresentPath 'if lq\(&wm_drag_window_id\) != NO_DRAG \{ rf_draw_drag\(\); return; \}[\s\S]*if lb\(&wallpaper_render_active\) != 0' 'Window drag rendering must take priority over the wallpaper-busy fallback.'
Assert-NotMatch $framePresentPath 'fn rf_wallpaper_busy_present\(\)[\s\S]*cursor_hide\(\)[\s\S]*render_flush\(\)' 'Wallpaper-busy frames must not repeatedly hide and full-flush the cursor.'

Write-Host '[guards] Checking Explorer Enter stack fix...' -ForegroundColor Yellow
Assert-NotMatch $appsPath 'app_explorer_key:[\s\S]*?\.exp_key_enter:[\s\S]*?push rax[\s\S]*?\.exp_key_done:' 'Explorer Enter path must not push an unmatched rax before the shared epilogue.'

Write-Host '[guards] Checking slot-local app buffers...' -ForegroundColor Yellow
Assert-Match $userWindowPath 'APP_SLOT_BMP_FILE_OFF' 'User app constants must expose slot-local BMP storage.'
Assert-Match $userWindowPath 'APP_SLOT_PAINT_CANVAS_OFF' 'User app constants must expose slot-local paint canvas storage.'
Assert-NotMatch $userWindowPath 'APP_BMP_FILE_BUF|APP_PAINT_CANVAS_BUF' 'User app constants must not expose shared global scratch buffers.'
Assert-NotMatch $paintPath 'PAINT_CANVAS_BUF|0x930000' 'Paint app must not use shared global media buffers.'

Write-Host '[guards] Checking GritHL SDK wiring...' -ForegroundColor Yellow
Assert-Match $ghlBuildPath 'generated_apps\.inc' 'GritHL build must generate the app include consumed by apps.asm.'
Assert-Match $ghlBuildPath 'manifest\.json' 'GritHL build must publish an SDK manifest.'
Assert-Match $launchPath 'app_hl_notepad_draw' 'Notepad launch must install the GritHL draw callback.'
Assert-Match $launchPath 'app_hl_notepad_click' 'Notepad launch must install the GritHL click callback.'
Assert-Match $launchPath 'app_hl_notepad_key' 'Notepad launch must install the GritHL key callback.'
Assert-Match $launchPath 'app_hl_explorer_draw' 'Explorer launch must install the GritHL draw callback.'
Assert-Match $launchPath 'app_hl_explorer_click' 'Explorer launch must install the GritHL click callback.'
Assert-Match $launchPath 'app_hl_explorer_key' 'Explorer launch must install the GritHL key callback.'
Assert-Match $ghlNotepadPath 'WM passes coordinates relative to the client area' 'GritHL Notepad must document the WM client-coordinate ABI.'
Assert-Match $ghlExplorerPath 'szOpenerMedia[\s\S]*SYS_OPEN_FILE_MEDIA' 'Explorer Properties must expose Media Player for native media files.'
Assert-Match $launchPath 'kernel_open_file_in_notepad:[\s\S]*Notepad is a text editor[\s\S]*\.kop_check_nba[\s\S]*je \.kop_fail' 'Kernel Notepad opener must reject known binary media formats.'
Assert-Match $ghlWallpaperPath 'svg_desktop_background\(\)[\s\S]*SVG_BG_LIQUID_METAL[\s\S]*liquid_svg[\s\S]*SVG_BG_GLASS_RIBBONS[\s\S]*ribbons_svg[\s\S]*bloom_svg' 'Wallpaper renderer must dispatch all three Settings background IDs to distinct SVG sources.'
$wallpaperSources = Get-ChildItem -LiteralPath (Join-Path $Root 'src\resources\wallpapers') -Filter '*.svg'
foreach ($wallpaperSource in $wallpaperSources) {
    Assert-NotMatch $wallpaperSource.FullName '<filter\b|filter\s*=|filter\s*:' "Desktop wallpaper $($wallpaperSource.Name) must not use software SVG filters; full-screen filter tiling stalls interactive background changes."
}

Write-Host '[guards] Checking unified generated theme...' -ForegroundColor Yellow
$themeTool = Join-Path $Root 'tools\theme_tool.py'
& python $themeTool check
if ($LASTEXITCODE -ne 0) {
    throw 'Unified theme spec is invalid or generated kernel/app/NPL outputs are stale.'
}
$themeTestStderr = [System.IO.Path]::GetTempFileName()
try {
    $themeTests = Start-Process -FilePath 'python' `
        -ArgumentList @('-m', 'unittest', 'discover', '-s', (Join-Path $Root 'tests'), '-p', 'test_theme_tool.py') `
        -RedirectStandardError $themeTestStderr -NoNewWindow -Wait -PassThru
    Get-Content -LiteralPath $themeTestStderr | Write-Host
    if ($themeTests.ExitCode -ne 0) {
        throw 'Unified theme compiler negative tests failed.'
    }
} finally {
    Remove-Item -LiteralPath $themeTestStderr -Force -ErrorAction SilentlyContinue
}
$themeLibPath = Join-Path $Root 'src\user\grithl\lib\theme.ghl'
$themeGuiPath = Join-Path $Root 'src\user\grithl\lib\gui.ghl'
Assert-Match $themeLibPath 'theme_palette:\s*512;[\s\S]*theme_state:\s*8;' 'Theme palette must remain fixed-size zeroed app state.'
Assert-Match $themeLibPath 'if idx < 0[\s\S]*if idx >= TC_COUNT' 'Theme lookup must bounds-check both sides.'
Assert-NotMatch $themeGuiPath 'UI_REF_' 'GUI theme resolution must never infer semantic tokens by matching raw RGB values.'

Write-Host '[guards] Checking security modules carry a threat note...' -ForegroundColor Yellow
# Presubmit (ghl-beyond-zero-trust P0): every trusted security module under
# src/tools/security must declare, in a header comment, the adversary/threat it
# defends against. Catching a module that ships without one keeps the security
# surface self-documenting and forces authors to state intent. Marker: a line
# matching `# THREAT:` anywhere in the file header.
$securityModuleDir = Join-Path $Root 'src\tools\security'
$securityModules = @(Get-ChildItem -LiteralPath $securityModuleDir -File -Filter '*.ghl' | Sort-Object Name)
if ($securityModules.Count -eq 0) {
    throw "No GHL security modules found under $securityModuleDir -- guard cannot be trusted."
}
foreach ($mod in $securityModules) {
    Assert-Match $mod.FullName '(?m)^#\s*THREAT:\s*\S' "Security module $($mod.Name) is missing a `# THREAT:` header note describing the adversary it defends against."
}
Write-Host "[guards]   $($securityModules.Count) security module(s) carry a threat note." -ForegroundColor DarkGray

Write-Host '[guards] PASS' -ForegroundColor Green
