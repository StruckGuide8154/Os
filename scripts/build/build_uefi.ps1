param(
    [switch]$Release,
    [ValidateRange(1, 4294967295)]
    [uint32]$ReleaseVersion = 20260613,
    [switch]$Trace,
    [ValidateSet('Default', 'Cache32Max')]
    [string]$PerfProfile = 'Default',
    [switch]$NoFbWc,         # Phase A baseline: skip fbperf WC arm+activate
    [switch]$NoMemRandom,    # Diagnostic: deterministic memory layout (KASLR off, per-slot code/user-stack slides off) plus boot milestone logs.
    [switch]$NoKaslr,        # Disable KASLR (random kernel base per boot). KASLR is on by default since 2026-05-27 after multi-boot QEMU verification.
    [switch]$ShadowStackPoc, # Build-gated kernel shadow-stack proof harness (debug only). Trips KEPILOGUE on a corrupted return address at boot; never ship.
    [switch]$ProbeNkPt,      # Nested-kernel monitor negative test (debug only). After nk_protect_page_tables runs, kmain does ONE un-bracketed write to the now-read-only PML4; expect a ring-0 #PF caught by isr_common_stub (proves page-table self-protection is live). Never ship.
    [switch]$SecurityRegression, # Security PoC regression suite (debug only). Compile-gates every ring-3 PoC harness in src/user/poc/ (catches mitigation-ABI drift at build time) AND builds the kernel shadow-stack trip into the image (asserted at boot by scripts/test/test_security_regression.ps1). Never ship.
    [switch]$NoSmap,         # Disable CR4.SMEP/SMAP enforcement. SMAP is ON by default (CPUID-gated at runtime); pass -NoSmap only for CPUs/emulators that lack SMAP and where the run target can't expose +smap.
    [switch]$Cet,            # Compatibility alias for default CET inventory/status plumbing. Hardware CR4.CET/IA32_S_CET arming is intentionally inert until the full supervisor SSP wiring lands. SHSTK/IBT *detection* is always compiled regardless of this flag.
    # NOTE: -Cet is retained for old scripts only; CET inventory/status is default-on.
    [switch]$NoCet,          # Disable CET inventory/status plumbing. The independent software kernel shadow stack remains compiled in.
    [switch]$CetIbt,         # Reserved for the later IBT arm path. Requires CET plumbing, but is inert today: CR4.CET is not armed and endbr64 markers are not yet emitted at indirect-branch targets.
    [switch]$Kpti,           # Kernel Page-Table Isolation (security_todo.md §3). Compiles the user-view-PML4 builder + CR3-swap entry/exit macros (src/include/kpti.inc). OFF by default -> macros emit nothing, no kpti.inc code/data, default image byte-for-byte unchanged. Even with -Kpti the feature is a runtime no-op (kpti_active=0) until the SYSCALL (syscall.asm) + IRQ/exception (isr.asm) CR3-swap points and the kmain kpti_init flip are wired -- see the scoped-out note in kpti.inc. The usermode.asm iretq exits are already wired (inert until armed). Compile-gate verification only for now.
    [switch]$NoKpti,         # Disable KPTI. Default ON: user-view CR3 while ring 3 runs, full kernel CR3 on entry.
    [switch]$NoSyscallPerm,  # Disable heterogeneous syscall numbering per slot (security_todo.md §12). ON by default: per-launch keyed-random permutation of the syscall table; the loader rewrites each app's compiled SYS_* immediates (via the .scfix fixup table) to the slot's forward-permuted numbers, and the dispatcher applies the kernel-side inverse mapping on entry. Pass -NoSyscallPerm to fall back to identity numbering.
    [switch]$AppO0,          # Compile GritHL user apps with gritc --O0 instead of the default lossless -O1 optimizer.
    [switch]$AppO2,          # Compile GritHL user apps with gritc --O2 (lossless register allocator, implies O1).
    [switch]$AppO3,          # Compile GritHL user apps with gritc --O3 (lossless density passes on the O2 stream, implies O2).
    [switch]$BootAnim,       # Play the pre-GUI /BOOTANIM.NBA splash at boot. OFF by default (deterministic boot). Defines GRIT_BOOT_ANIM so the gated boot_anim_play() call site compiles in. The BOOTANIM.NBA asset is always built (Media Player demo content) regardless of this flag.
    [switch]$BootTrace,      # Debug-only pre-GUI freeze tracer. Paints a marching grid of colored framebuffer blocks - one per boot stage - from the UEFI loader (top band) through every kmain stage (lower band). On a real-hardware hang before the GUI, the last/rightmost block is the last stage that COMPLETED. Defines GRIT_BOOT_TRACE for both loader + kernel. Not allowed with -Release.
    [switch]$SyscallTrace,   # Emit a per-syscall serial trace ('s'<num>...). OFF by default: it floods COM1 on syscall-heavy apps (e.g. Task Manager polls per-core util/mhz every frame) and serial-out is slow enough to make the app crawl. Pass -SyscallTrace only when debugging the dispatcher.
    [switch]$CopyToE         # Copy built ESP\EFI tree to E:\ for boot from removable media.
    # GFX/DCN bring-up flags (-Gfx, -GfxWave3, -GfxWave3L, -GfxImuKick,
    # -DiagLegacy) were retired 2026-05-26 along with the AMD 780M iGPU
    # subsystem. Source preserved under deprecated/780M_IGPU/.
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

$NASM = 'C:\Tools\nasm-2.16.03\nasm.exe'
$SRC_DIR = Join-Path $Root 'src'
$BUILD_DIR = Join-Path $Root 'build'
$INCLUDE_DIR = Join-Path $SRC_DIR 'include'
$USER_LIB_DIR = Join-Path $SRC_DIR 'user\lib'
$ESP = Join-Path $BUILD_DIR 'esp\EFI\BOOT'
$ConstantsPath = Join-Path $INCLUDE_DIR 'constants.inc'
$KernelDefines = @()
$LoaderDefines = @()

function Get-AsmEqu {
    param([string]$Path, [string]$Name)

    $line = Select-String -Path $Path -Pattern "^\s*$Name\s+equ\s+(.+?)(?:\s*;.*)?$" |
        Select-Object -First 1
    if (-not $line) { throw "Missing $Name in $Path" }

    $expr = $line.Matches[0].Groups[1].Value.Trim()
    if ($expr -match '^0x[0-9A-Fa-f]+$') { return [Convert]::ToInt64($expr, 16) }
    if ($expr -match '^\d+$') { return [int64]$expr }
    throw "Unsupported $Name expression in ${Path}: $expr"
}
if (-not $Release) {
    $KernelDefines += '-dENABLE_DEBUG_SERIAL'
    # Per-syscall serial trace is OFF by default - it floods COM1 and slows
    # syscall-heavy apps to a crawl. Opt in with -SyscallTrace when needed.
    if ($SyscallTrace) { $KernelDefines += '-dENABLE_USER_DEBUG_SYSCALL' }
}
else {
    $KernelDefines += '-dRELEASE_BUILD'
    $LoaderDefines += '-dRELEASE_BUILD'
}
if ($BootAnim) {
    $KernelDefines += '-dGRIT_BOOT_ANIM'
    Write-Host '  (BOOTANIM: pre-GUI splash ENABLED via -BootAnim)' -ForegroundColor Magenta
}
if ($BootTrace) {
    if ($Release) {
        Write-Host '  FAILED - -BootTrace is a debug-only freeze tracer; do not combine with -Release.' -ForegroundColor Red
        exit 1
    }
    $KernelDefines += '-dGRIT_BOOT_TRACE'
    $LoaderDefines += '-dGRIT_BOOT_TRACE'
    Write-Host '  (BOOTTRACE: per-stage progress blocks ENABLED via -BootTrace -- loader top band + kernel lower band)' -ForegroundColor Magenta
}
if ($PerfProfile -eq 'Cache32Max') {
    $KernelDefines += '-dGRIT_CACHE32_MAX'
    $LoaderDefines += '-dGRIT_CACHE32_MAX'
}
if ($NoFbWc) {
    $KernelDefines += '-dFBPERF_NO_WC'
    Write-Host '  (FBPERF: WC activation DISABLED -- Phase A baseline build)' -ForegroundColor Magenta
}
if ($NoMemRandom) {
    $KernelDefines += '-dGRIT_NO_MEM_RANDOM'
    $KernelDefines += '-dGRIT_BOOT_DIAG_LOG'
    Write-Host '  (MEMRND: DISABLED via -NoMemRandom -- KASLR, per-slot code slide, and user-stack top randomization forced deterministic)' -ForegroundColor Yellow
}
if ($SecurityRegression -and $Release) {
    Write-Host '  FAILED - -SecurityRegression is a debug-only harness; do not combine with -Release.' -ForegroundColor Red
    exit 1
}
# -SecurityRegression is a superset of -ShadowStackPoc: it builds the kernel
# shadow-stack trip into the image (so the run harness can assert it fires) AND
# compile-gates every ring-3 PoC below.
if ($ShadowStackPoc -or $SecurityRegression) {
    $KernelDefines += '-dENABLE_SHADOW_STACK_POC'
    Write-Host '  (SHADOW: kernel shadow-stack PoC trip ENABLED -- debug only)' -ForegroundColor Magenta
}
if ($ProbeNkPt) {
    $KernelDefines += '-dPROBE_NK_PT'
    Write-Host '  (NKPT: nested-kernel page-table protection NEGATIVE TEST ENABLED -- expect a deliberate #PF at boot; debug only)' -ForegroundColor Magenta
}
if (-not $NoSmap) {
    $KernelDefines += '-dENABLE_SMAP'
    Write-Host '  (SMAP: CR4.SMEP/SMAP enforcement + stac/clac user-access brackets ENABLED -- default; -NoSmap to disable)' -ForegroundColor Magenta
} else {
    Write-Host '  (SMAP: DISABLED via -NoSmap -- CR4 left as loaders configured it)' -ForegroundColor Yellow
}
# CET (security_todo.md §3). Detection (cet_detect) is ALWAYS compiled; -Cet
# default-on CET path records that the software kernel shadow stack is the active
# protection. Hardware CR4.CET/S_CET/SSP arming is intentionally inert until the
# full supervisor SSP wiring lands. -NoCet opts out of this status plumbing.
if ($CetIbt -and $NoCet) {
    Write-Host '  FAILED - -CetIbt requires CET; remove -NoCet.' -ForegroundColor Red
    exit 1
}
if (-not $NoCet) {
    $KernelDefines += '-dENABLE_CET'
    if ($Cet) {
        Write-Host '  (CET: -Cet accepted for compatibility; CET inventory/status plumbing is already ON by default)' -ForegroundColor Gray
    }
    Write-Host '  (CET: inventory/status ENABLED by default -- hardware arming inert, software kernel shadow stack remains active; -NoCet to suppress CET status)' -ForegroundColor Magenta
    if ($CetIbt) {
        $KernelDefines += '-dENABLE_CET_IBT'
        Write-Host '  (CET: -CetIbt accepted as reserved plumbing -- CR4.CET/S_CET arming and endbr64 markers pending)' -ForegroundColor Magenta
    }
} else {
    Write-Host '  (CET: status plumbing DISABLED via -NoCet -- SHSTK/IBT detection still compiled, software kernel shadow stack unchanged)' -ForegroundColor Yellow
}
# Heterogeneous syscall numbering per slot (security_todo.md §12). ON by
# default: the loader rewrites every app's compiled SYS_* immediate (located via
# the build-emitted .scfix fixup table) to that slot's FORWARD-permuted number,
# and the dispatcher applies the per-slot INVERSE map on entry (branch-free; the
# lfence-before-indirect-jmp barrier is preserved). Slot 0 stays identity
# (fail-safe). -NoSyscallPerm falls back to identity numbering.
if (-not $NoSyscallPerm) {
    $KernelDefines += '-dENABLE_SYSCALL_PERM'
    Write-Host '  (SYSCALLPERM: per-slot syscall-number permutation ENABLED -- default; loader rewrites SYS_* immediates, dispatcher inverse-maps; -NoSyscallPerm to disable)' -ForegroundColor Magenta
} else {
    Write-Host '  (SYSCALLPERM: DISABLED via -NoSyscallPerm -- identity syscall numbering)' -ForegroundColor Yellow
}
# KPTI (security_todo.md §3). -Kpti compiles the user-view-PML4 builder + the
# CR3-swap entry/exit macro bodies (src/include/kpti.inc).
#
# OFF BY DEFAULT (reverted from default-on 2026-06-01): the entry/exit
# trampolines were never relocated into the low-2 MiB user-view window that
# kpti_init maps, so once KPTI_SWITCH_TO_USER_CR3 installs the user view the
# next kernel .text instruction (and the IDT) are UNMAPPED -> ring-0 #PF on
# fetch -> #DF -> triple fault on the first ring-3 round-trip (timer IRQ /
# syscall return). kpti.inc's own header documents this exact hazard and says
# KPTI must stay OFF until the trampoline relocation lands. Verified via a
# QEMU -d int trace: RIP==CR2 in kernel .text under CR3==kpti_user_cr3.
# Pass -Kpti to force-compile it anyway (will triple-fault until relocated).
if ($Kpti -and -not $NoKpti) {
    $KernelDefines += '-dENABLE_KPTI'
    Write-Host '  (KPTI: FORCE-ENABLED via -Kpti -- WARNING: entry-stub relocation incomplete; this build WILL triple-fault on the first ring-3 round-trip)' -ForegroundColor Red
} else {
    Write-Host '  (KPTI: OFF -- entry/exit trampoline not yet relocated below 2 MiB (see kpti.inc); kernel fully mapped while ring 3 runs. -Kpti to force-enable)' -ForegroundColor Yellow
}
if (-not ($NoKaslr -or $NoMemRandom)) {
    # Loader-only switch: kernel assembles transparently at the chosen ORG;
    # only the loader's slide-picker is gated.
    $LoaderDefines += '-dENABLE_KASLR'
    Write-Host '  (KASLR: enabled - kernel will load at a random base each boot)' -ForegroundColor Magenta
} else {
    Write-Host '  (KASLR: DISABLED -- slide forced to 0)' -ForegroundColor Yellow
}
$KernelDefines += '-dGRIT_SMP'
$KernelDefines += '-dGRIT_CACHE32_AP_STARTUP'
$KernelDefines += '-dGRIT_ENABLE_RING3_AP'
# UEFI starts AP workers in both profiles. Keep ring-3 callback routing
# enabled with AP startup so app work runs on each process home_core instead
# of falling through dispatch_app_callback's BSP-only fallback.
if ($Trace) {
    $KernelDefines += '-dENABLE_TRACE'
    $KernelDefines += '-dENABLE_SIG_SECTION'
}

Write-Host ''
Write-Host '  Grit UEFI Build System' -ForegroundColor Cyan
Write-Host '  =========================' -ForegroundColor Cyan
Write-Host ("  Mode: " + ($(if ($Release) { 'release' } else { 'debug' }))) -ForegroundColor DarkGray
Write-Host "  Perf: $PerfProfile" -ForegroundColor DarkGray
Write-Host ("  Trace: " + ($(if ($Trace) { 'on' } else { 'off' }))) -ForegroundColor DarkGray
Write-Host ''

New-Item -Path $ESP -ItemType Directory -Force | Out-Null
if ($Release) {
    # Do not let debug-profile leftovers survive into a public release directory.
    Remove-Item -LiteralPath (Join-Path $ESP 'BOOTCFG.TXT') -Force -ErrorAction SilentlyContinue
}

# 0. Embed SVG wallpaper sources into wallpaper.ghl so the native GritHL
# renderer (svg_render) has the current SVG strings. Run on every build so
# edits to src/resources/wallpapers/*.svg are picked up automatically.
$WallpaperTool = Join-Path $Root 'tools\gen_wallpaper_strings.py'
if (Test-Path $WallpaperTool) {
    & python $WallpaperTool
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED wallpaper string gen' -ForegroundColor Red; exit 1 }
}

# 0b. Compile GritHL apps -> build/ghl/*.asm (included by src/user/apps.asm)
$NxhBuildArgs = @()
if ($Release) { $NxhBuildArgs += '-Release' }
if ($AppO0) { $NxhBuildArgs += '-O0' }
if ($AppO2) { $NxhBuildArgs += '-O2' }
if ($AppO3) { $NxhBuildArgs += '-O3' }
& powershell -NoProfile -File (Join-Path $Root 'scripts\build\build_ghl.ps1') @NxhBuildArgs
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED GritHL compile' -ForegroundColor Red; exit 1 }

# 0b2. Compile GritHLK kernel modules -> build/ghl/*.asm (%include'd by
# kernel_build.asm). These use gritc.py's kernel emit mode (--target kernel):
# plain NASM, bare labels, direct in-unit calls, no app-blob framing. Currently
# the serial-diagnostic leaf cluster (PoC). Regenerated every build so the
# .ghl source stays the source of truth for the generated .asm.
$GritcPy   = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$NxhLibDir = Join-Path $Root 'src\user\grithl\lib'
$NxhkOutDir = Join-Path $Root 'build\ghl'
$SafetyOutDir = Join-Path $NxhkOutDir 'safety'
New-Item -Path $NxhkOutDir -ItemType Directory -Force | Out-Null
New-Item -Path $SafetyOutDir -ItemType Directory -Force | Out-Null
$KernelModules = @(
    @{ src = 'src\kernel\grithlk\kernel_console.ghl'; out = 'build\ghl\kernel_console.asm' },
    @{ src = 'src\kernel\grithlk\context_menu.ghl'; out = 'build\ghl\context_menu.asm' },
    @{ src = 'src\kernel\grithlk\kernel_lifecycle.ghl'; out = 'build\ghl\kernel_lifecycle.asm' },
    @{ src = 'src\kernel\grithlk\serial_poll.ghl'; out = 'build\ghl\serial_poll.asm' },
    @{ src = 'src\kernel\grithlk\input_dispatch.ghl'; out = 'build\ghl\input_dispatch.asm' },
    @{ src = 'src\kernel\grithlk\render.ghl'; out = 'build\ghl\render.asm' },
    @{ src = 'src\kernel\grithlk\usermode_translate.ghl'; out = 'build\ghl\usermode_translate.asm' },
    @{ src = 'src\kernel\grithlk\watchdog.ghl'; out = 'build\ghl\watchdog.asm' },
    @{ src = 'src\kernel\grithlk\bounded_lock.ghl'; out = 'build\ghl\bounded_lock.asm' },
    @{ src = 'src\kernel\grithlk\frame_present.ghl'; out = 'build\ghl\frame_present.asm' },
    @{ src = 'src\kernel\grithlk\frame_pacing.ghl'; out = 'build\ghl\frame_pacing.asm' },
    @{ src = 'src\kernel\grithlk\boot_anim.ghl'; out = 'build\ghl\boot_anim.asm' },
    @{ src = 'src\kernel\grithlk\serial_diag.ghl'; out = 'build\ghl\serial_diag.asm' },
    @{ src = 'src\kernel\grithlk\syscall_data.ghl'; out = 'build\ghl\syscall_data.asm' },
    @{ src = 'src\kernel\grithlk\boot_diag.ghl';   out = 'build\ghl\boot_diag.asm' },
    @{ src = 'src\kernel\grithlk\boot_timing.ghl'; out = 'build\ghl\boot_timing.asm' },
    @{ src = 'src\kernel\grithlk\debug_overlay.ghl'; out = 'build\ghl\debug_overlay.asm' },
    @{ src = 'src\kernel\grithlk\cpu_acct.ghl';    out = 'build\ghl\cpu_acct.asm' },
    @{ src = 'src\kernel\grithlk\serial_console.ghl'; out = 'build\ghl\serial_console.asm' },
    @{ src = 'src\kernel\grithlk\crypto.ghl'; out = 'build\ghl\crypto.asm' },
    @{ src = 'src\kernel\grithlk\ram_volatile.ghl'; out = 'build\ghl\ram_volatile.asm' },
    @{ src = 'src\kernel\grithlk\ram_atrest.ghl'; out = 'build\ghl\ram_atrest.asm' },
    @{ src = 'src\kernel\grithlk\mon_hal_vmx_backend.ghl'; out = 'build\ghl\mon_hal_vmx_backend.asm' },
    @{ src = 'src\kernel\grithlk\syscall_validate.ghl'; out = 'build\ghl\syscall_validate.asm' },
    @{ src = 'src\kernel\grithlk\syscall_secure.ghl'; out = 'build\ghl\syscall_secure.asm' },
    @{ src = 'src\kernel\grithlk\wm_helpers.ghl'; out = 'build\ghl\wm_helpers.asm' },
    @{ src = 'src\kernel\grithlk\usb_hid_helpers.ghl'; out = 'build\ghl\usb_hid_helpers.asm' },
    @{ src = 'src\kernel\grithlk\usermode_callbacks.ghl'; out = 'build\ghl\usermode_callbacks.asm' },
    @{ src = 'src\kernel\grithlk\rtl8156_dhcp_build.ghl'; out = 'build\ghl\rtl8156_dhcp_build.asm' },
    @{ src = 'src\kernel\grithlk\rtl8156_arp.ghl'; out = 'build\ghl\rtl8156_arp.asm' },
    @{ src = 'src\kernel\grithlk\rtl8156_dhcp_parse.ghl'; out = 'build\ghl\rtl8156_dhcp_parse.asm' },
    @{ src = 'src\kernel\grithlk\rtl8156_dhcp_sm.ghl'; out = 'build\ghl\rtl8156_dhcp_sm.asm' },
    @{ src = 'src\kernel\grithlk\dns.ghl'; out = 'build\ghl\dns.asm' },
    @{ src = 'src\kernel\grithlk\net_dhcp_dispatch.ghl'; out = 'build\ghl\net_dhcp_dispatch.asm' },
    @{ src = 'src\kernel\grithlk\boot_features.ghl'; out = 'build\ghl\boot_features.asm' },
    @{ src = 'src\kernel\grithlk\cursor.ghl'; out = 'build\ghl\cursor.asm' },
    @{ src = 'src\kernel\grithlk\eth.ghl'; out = 'build\ghl\eth.asm' },
    @{ src = 'src\kernel\grithlk\arp.ghl'; out = 'build\ghl\arp.asm' },
    @{ src = 'src\kernel\grithlk\ip.ghl'; out = 'build\ghl\ip.asm' },
    @{ src = 'src\kernel\grithlk\udp.ghl'; out = 'build\ghl\udp.asm' },
    @{ src = 'src\kernel\grithlk\math.ghl'; out = 'build\ghl\math.asm' },
    @{ src = 'src\kernel\grithlk\string.ghl'; out = 'build\ghl\string.asm' },
    @{ src = 'src\kernel\grithlk\font.ghl'; out = 'build\ghl\font.asm' },
    # Zero-asm XML 1.0 parser (ported from lib/xml*.asm/.inc). ~3 MiB per-slot
    # DOM lives in `.bss` via the compiler `reserve` primitive (zero image cost).
    @{ src = 'src\kernel\grithlk\xml.ghl'; out = 'build\ghl\xml.asm' },
    # Track 2 signed-envelope enforcement: the structural + semantic policy
    # kernels (shared with the host checker fixtures) and the in-kernel reader
    # that walks envelope bytes and calls them (envelope_verify).
    @{ src = 'src\tools\security\signed_envelope.ghl'; out = 'build\ghl\signed_envelope.asm' },
    @{ src = 'src\tools\security\signed_artifact_check.ghl'; out = 'build\ghl\signed_artifact_check.asm' },
    @{ src = 'src\tools\security\threshold_check.ghl'; out = 'build\ghl\threshold_check.asm' },
    @{ src = 'src\kernel\grithlk\envelope_reader.ghl'; out = 'build\ghl\envelope_reader.asm' },
    # Real Ed25519 threshold-signature crypto for the envelope
    # (envelope_verify_signed = structure + semantics + signatures).
    @{ src = 'src\kernel\grithlk\ed25519_check.ghl'; out = 'build\ghl\ed25519_check.asm' },
    # CMOS RTC wallclock (unix seconds) for the gate's verifier context.
    @{ src = 'src\kernel\grithlk\rtc_time.ghl'; out = 'build\ghl\rtc_time.asm' },
    # Persistent anti-rollback floors (data.img FLOOR_LBA sector, fail-soft).
    @{ src = 'src\kernel\grithlk\floor_store.ghl'; out = 'build\ghl\floor_store.asm' },
    # Track 2 artifact admission gate: binds envelope_verify_signed into the
    # boot-chain (SYSSIG.ENV) + update-path (KUPDATE.ENV) call sites, with the
    # verified-artifact hash cache in front of the Ed25519 crypto.
    @{ src = 'src\kernel\grithlk\envelope_gate.ghl'; out = 'build\ghl\envelope_gate.asm' },
    # Zero-asm FAT16 filesystem driver (replaces fat16.asm + 4 .inc). Big FAT/
    # root/file caches live in `.bss` via `reserve` (zero image bytes). Provides
    # the SYS_FS_* worker globals + per-slot cwd ownership and TOCTOU snapshot.
    @{ src = 'src\kernel\grithlk\fat16_core.ghl'; out = 'build\ghl\fat16_core.asm' },
    # Zero-asm SMP work queue (replaces proc/workqueue.asm + workqueue_api.inc +
    # workqueue_worker.inc). Lock-free atomic_cmpxchg claim, APERF/MPERF MHz
    # accounting, and a SECURE job-ID allow-list (wq_job_table) dispatched via the
    # bounds-checked call_table - no raw function pointers on the queue.
    @{ src = 'src\kernel\grithlk\workqueue.ghl'; out = 'build\ghl\workqueue.asm' },
    # Zero-asm ring-3 callback dispatch + deadman + priority manager (replaces
    # proc/process_callbacks.inc + process_data.inc). save_landing/jump_landing
    # deadman, tail_jump l3_return_guard, AP routing by job ID through the queue.
    @{ src = 'src\kernel\grithlk\callback_dispatch.ghl'; out = 'build\ghl\callback_dispatch.asm' }
)
foreach ($m in $KernelModules) {
    $mSrc = Join-Path $Root $m.src
    $mOut = Join-Path $Root $m.out
    $mSafety = Join-Path $SafetyOutDir (([IO.Path]::GetFileNameWithoutExtension($m.out)) + '.safety.json')
    Write-Host "  compile (kernel) $($m.src)" -ForegroundColor Yellow
    # --forbid-asm enforces the zero-asm invariant: every GritHLK kernel module
    # is fully structured. A reintroduced `asm`/`asm{}` escape fails the build.
    & python $GritcPy $mSrc -o $mOut -L $NxhLibDir --embed --target kernel --forbid-asm --safety-manifest $mSafety
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED GritHLK kernel-module compile' -ForegroundColor Red; exit 1 }
}

$SafetyManifests = @(Get-ChildItem -Path $SafetyOutDir -Filter '*.safety.json' -ErrorAction SilentlyContinue | ForEach-Object {
    Get-Content -Raw -Path $_.FullName | ConvertFrom-Json
})
if ($SafetyManifests.Count -gt 0) {
    $SafetySummaryPath = Join-Path $SafetyOutDir 'kernel-safety-summary.json'
    $UnsafeModules = @($SafetyManifests | Where-Object { $_.unsafe.declared.Count -gt 0 })
    $BroadModules = @($SafetyManifests | Where-Object { $_.unsafe.broad.Count -gt 0 })
    $PrivModules = @($SafetyManifests | Where-Object { $_.unsafe.privileged.Count -gt 0 })
    $AllEffects = @($SafetyManifests | ForEach-Object { $_.functions | ForEach-Object { $_.effects } } | Where-Object { $_ } | Sort-Object -Unique)
    $ExternContracts = @($SafetyManifests | ForEach-Object {
        $moduleName = $_.module
        $_.functions | ForEach-Object {
            $fnName = $_.name
            $_.extern_contract_required | ForEach-Object {
                [pscustomobject]@{ module = $moduleName; function = $fnName; target = $_ }
            }
        }
    })
    $LegacyInventoryPath = Join-Path $Root 'tools\security\legacy_asm_inventory.txt'
    $LegacyInventory = @()
    if (Test-Path $LegacyInventoryPath) {
        $LegacyInventory = @(Get-Content -Path $LegacyInventoryPath | ForEach-Object {
            $line = $_.Trim()
            if (-not $line -or $line.StartsWith('#')) { return }
            $parts = @($line -split '\|' | ForEach-Object { $_.Trim() })
            if ($parts.Count -lt 4) { return }
            [pscustomobject]@{
                path = $parts[0]
                domain = $parts[1]
                risk = $parts[2]
                status = $parts[3]
                target = if ($parts.Count -ge 5) { $parts[4] } else { '' }
            }
        })
    }
    $UnmigratedLegacy = @($LegacyInventory | Where-Object { $_.status -eq 'legacy' })
    $MigratingLegacy = @($LegacyInventory | Where-Object { $_.status -eq 'migrating' })
    $UnmigratedHigh = @($UnmigratedLegacy | Where-Object { $_.risk -eq 'high' })
    $UnmigratedByDomain = @($UnmigratedLegacy | Group-Object domain | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ domain = $_.Name; count = $_.Count }
    })
    $UnmigratedByRisk = @($UnmigratedLegacy | Group-Object risk | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ risk = $_.Name; count = $_.Count }
    })
    $Summary = [pscustomobject]@{
        schema = 'gritc-kernel-safety-summary-v1'
        generatedBy = 'scripts/build/build_uefi.ps1'
        moduleCount = $SafetyManifests.Count
        unsafeModuleCount = $UnsafeModules.Count
        broadOverrideModuleCount = $BroadModules.Count
        privilegedOverrideModuleCount = $PrivModules.Count
        effectCount = $AllEffects.Count
        effects = $AllEffects
        externContractCount = $ExternContracts.Count
        externContracts = $ExternContracts
        legacyInventory = [pscustomobject]@{
            source = $LegacyInventoryPath
            total = $LegacyInventory.Count
            unmigratedCount = $UnmigratedLegacy.Count
            migratingCount = $MigratingLegacy.Count
            highRiskUnmigratedCount = $UnmigratedHigh.Count
            unmigratedByDomain = $UnmigratedByDomain
            unmigratedByRisk = $UnmigratedByRisk
            unmigrated = $UnmigratedLegacy
            migrating = $MigratingLegacy
        }
        modules = @($SafetyManifests | Sort-Object module | ForEach-Object {
            $moduleEffects = @($_.functions | ForEach-Object { $_.effects } | Where-Object { $_ } | Sort-Object -Unique)
            $moduleExternContracts = @($_.functions | ForEach-Object { $_.extern_contract_required } | Where-Object { $_ } | Sort-Object -Unique)
            [pscustomobject]@{
                module = $_.module
                source = $_.input
                unsafe = @($_.unsafe.declared | ForEach-Object { $_.cap })
                broad = @($_.unsafe.broad)
                privileged = @($_.unsafe.privileged)
                effects = $moduleEffects
                externContracts = $moduleExternContracts
                externCount = $_.symbols.externs.Count
                globalCount = $_.symbols.globals.Count
                functionCount = $_.functions.Count
            }
        })
    }
    $ascii = [System.Text.Encoding]::ASCII
    [System.IO.File]::WriteAllBytes($SafetySummaryPath, $ascii.GetBytes((($Summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine)))
    Write-Host ("  GritHLK safety: {0}/{1} modules declare temporary unsafe caps; broad={2}, privileged={3}" -f `
        $UnsafeModules.Count, $SafetyManifests.Count, $BroadModules.Count, $PrivModules.Count) -ForegroundColor Yellow
    Write-Host ("  GritHLK effects: {0} inferred effect kind(s); extern ABI contracts needed={1}" -f `
        $AllEffects.Count, $ExternContracts.Count) -ForegroundColor Yellow
    if ($LegacyInventory.Count -gt 0) {
        Write-Host ("  Legacy migration: {0}/{1} unmigrated; migrating={2}; high-risk unmigrated={3}" -f `
            $UnmigratedLegacy.Count, $LegacyInventory.Count, $MigratingLegacy.Count, $UnmigratedHigh.Count) -ForegroundColor Yellow
        $RiskText = @($UnmigratedByRisk | ForEach-Object { "$($_.risk)=$($_.count)" }) -join ', '
        if ($RiskText) {
            Write-Host "  Legacy migration by risk: $RiskText" -ForegroundColor DarkYellow
        }
    }
    Write-Host "  Safety summary: $SafetySummaryPath" -ForegroundColor DarkGray
    $SafetyBudgetPath = Join-Path $Root 'tools\security\ghlk_safety_budget.json'
    if (Test-Path $SafetyBudgetPath) {
        $Budget = Get-Content -Raw -Path $SafetyBudgetPath | ConvertFrom-Json
        $BudgetFailures = @()
        if ($UnsafeModules.Count -gt $Budget.maxUnsafeModuleCount) {
            $BudgetFailures += "unsafe modules $($UnsafeModules.Count) > budget $($Budget.maxUnsafeModuleCount)"
        }
        if ($BroadModules.Count -gt $Budget.maxBroadOverrideModuleCount) {
            $BudgetFailures += "broad overrides $($BroadModules.Count) > budget $($Budget.maxBroadOverrideModuleCount)"
        }
        if ($PrivModules.Count -gt $Budget.maxPrivilegedOverrideModuleCount) {
            $BudgetFailures += "privileged overrides $($PrivModules.Count) > budget $($Budget.maxPrivilegedOverrideModuleCount)"
        }
        if ($AllEffects.Count -gt $Budget.maxEffectCount) {
            $BudgetFailures += "effect kinds $($AllEffects.Count) > budget $($Budget.maxEffectCount)"
        }
        if ($ExternContracts.Count -gt $Budget.maxExternContractCount) {
            $BudgetFailures += "extern ABI contracts $($ExternContracts.Count) > budget $($Budget.maxExternContractCount)"
        }
        if ($BudgetFailures.Count -gt 0) {
            Write-Host '  FAILED GritHLK safety budget:' -ForegroundColor Red
            foreach ($failure in $BudgetFailures) { Write-Host "    $failure" -ForegroundColor Red }
            exit 1
        }
        Write-Host "  GritHLK safety budget: PASS ($SafetyBudgetPath)" -ForegroundColor Green
    }
    $Preview = @($UnsafeModules | Sort-Object module | Select-Object -First 10)
    foreach ($sm in $Preview) {
        $caps = @($sm.unsafe.declared | ForEach-Object { $_.cap }) -join ','
        Write-Host ("    unsafe {0}: {1}" -f $sm.module, $caps) -ForegroundColor DarkYellow
    }
    if ($UnsafeModules.Count -gt $Preview.Count) {
        Write-Host ("    ... {0} more unsafe module(s) in summary" -f ($UnsafeModules.Count - $Preview.Count)) -ForegroundColor DarkYellow
    }
    $UnmigratedPreview = @($UnmigratedLegacy | Sort-Object @{Expression={ if ($_.risk -eq 'high') { 0 } elseif ($_.risk -eq 'medium') { 1 } else { 2 } }}, domain, path | Select-Object -First 10)
    foreach ($entry in $UnmigratedPreview) {
        Write-Host ("    unmigrated {0}/{1}: {2}" -f $entry.risk, $entry.domain, $entry.path) -ForegroundColor DarkYellow
    }
    if ($UnmigratedLegacy.Count -gt $UnmigratedPreview.Count) {
        Write-Host ("    ... {0} more unmigrated legacy file(s) in safety summary" -f ($UnmigratedLegacy.Count - $UnmigratedPreview.Count)) -ForegroundColor DarkYellow
    }
}
$CoverageTool = Join-Path $Root 'tools\check_coverage.py'
if (Test-Path $CoverageTool) {
    & python $CoverageTool
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED signature coverage' -ForegroundColor Red; exit 1 }
}

# 0c. Generate boot animation -> build/BOOTANIM.NBA (raw BGRA frames + header).
$BootAnimTool = Join-Path $Root 'tools\gen_boot_anim.py'
if (Test-Path $BootAnimTool) {
    & python $BootAnimTool
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED boot anim gen' -ForegroundColor Red; exit 1 }
}

# 0d. Security PoC regression compile-gate (-SecurityRegression).
# Assemble every ring-3 PoC harness in src/user/poc/ as a standalone flat
# binary. These exercise landed mitigations through the syscall ABI
# (SYS_WX_INSTALL_MANIFEST, SYS_MPROTECT_WX / MPROT_WX_MODE_XRO, SYS_WX_JIT_ALIAS,
# SYS_PRINT, SYS_EXIT). If a future change regresses any of that ABI the PoC
# stops assembling and the build fails HERE -- a mitigation regression breaks
# the build instead of hiding until a manual audit (security_todo.md §13).
if ($SecurityRegression) {
    Write-Host '[0d] Security regression: compile-gating ring-3 PoC harnesses...' -ForegroundColor Yellow
    $PocSrcDir = Join-Path $SRC_DIR 'user\poc'
    $PocBuildDir = Join-Path $BUILD_DIR 'poc'
    New-Item -Path $PocBuildDir -ItemType Directory -Force | Out-Null
    # Ring-3 harnesses that anchor manifest offsets against app_blob_start and
    # must keep assembling against the current syscall ABI. shadow_stack_poc.asm
    # and exploit_poc_syscall9.asm are kernel-side / reference-only and are not
    # in this list (the shadow harness is asserted at runtime instead).
    $PocHarnesses = @(
        'wx_poc_manifestless_blob.asm',
        'wx_poc_write_x.asm',
        'wx_poc_exec_w.asm',
        'wx_poc_pos.asm',
        'wx_jit_alias_pos.asm',
        'wx_jit_alias_fuzz.asm',
        'stack_overflow_poc.asm'
    )
    foreach ($poc in $PocHarnesses) {
        $pocPath = Join-Path $PocSrcDir $poc
        if (-not (Test-Path $pocPath)) {
            Write-Host "  FAILED - PoC harness missing: $poc" -ForegroundColor Red
            exit 1
        }
        # Generate a tiny standalone wrapper that supplies app_blob_start, then
        # %includes the harness. Includes resolve via -I to the poc dir.
        $wrapPath = Join-Path $PocBuildDir ('wrap_' + ($poc -replace '\.asm$', '') + '.asm')
        $outBin = Join-Path $PocBuildDir (($poc -replace '\.asm$', '') + '.bin')
        @(
            'bits 64',
            '%include "poc_standalone_prelude.inc"',
            ('%include "' + $poc + '"')
        ) | Set-Content -Path $wrapPath -Encoding ASCII
        $ErrorActionPreference = 'Continue'
        & $NASM @KernelDefines -f bin -o $outBin `
            -I "$INCLUDE_DIR\" -I "$USER_LIB_DIR\" -I "$PocSrcDir\" $wrapPath 2>&1 |
        ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAILED - PoC harness no longer assembles (mitigation-ABI regression?): $poc" -ForegroundColor Red
            exit 1
        }
        Write-Host "  OK - $poc" -ForegroundColor Green
    }
    Write-Host "  All $($PocHarnesses.Count) ring-3 PoC harnesses assemble; kernel shadow-stack trip armed." -ForegroundColor Green
}

# 1. Debug loaders have no artifact manifest. Release loaders are assembled
# only after every payload exists, then signed as the external trust anchor.
if (-not $Release) {
    Write-Host '[1/2] Assembling UEFI Loader...' -ForegroundColor Yellow
    $ErrorActionPreference = 'Continue'
    & $NASM @LoaderDefines -f bin -o "$ESP\BOOTX64.EFI" "$SRC_DIR\boot\uefi_loader.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED' -ForegroundColor Red; exit 1 }
    $sz = (Get-Item "$ESP\BOOTX64.EFI").Length
    Write-Host "  OK - BOOTX64.EFI ($sz bytes)" -ForegroundColor Green
}

# 2. Assemble Kernel TWICE for diff-relocation KASLR.
#
# Even when -Kaslr is OFF on the loader side we still wrap the kernel in the
# KASLR container so the loader has a uniform input format. With KASLR off the
# loader picks slide=0, which must reproduce the legacy "loaded at 0x100000"
# behavior byte-for-byte at runtime.
#
# Pass A: ORG = 0x100000 (the runtime base when slide=0)
# Pass B: ORG = 0x200000 (slide of +0x100000)
# Differ on exactly the qwords that hold absolute label references; the
# extractor diffs them into a fixup table and wraps Pass A as the payload.
# Generate a PUBLIC commitment to the private quantum seed. Only SHA-256(seed)
# enters KERNEL.BIN; KERNEL.ENV later signs the whole container. Runtime secrets
# mix this public salt with fresh boot entropy. Raw seed bytes never ship.
$qseedBin = Join-Path $Root 'tools\quantum\seed.bin'
$qseedInc = Join-Path $BUILD_DIR 'qrng_commitment.inc'
# Minimum extracted-seed length. Only SHA-256(seed) ships, so the exact size is
# a build-diversity choice, not a crypto constraint; we just require enough bytes
# to commit to. (Was a hard ==1024 gate; relaxed to accept shorter real seeds.)
$QSEED_MIN = 32
if (Test-Path $qseedBin) {
    $bytes = [System.IO.File]::ReadAllBytes($qseedBin)
    if ($bytes.Length -lt $QSEED_MIN) { throw "seed.bin must be at least $QSEED_MIN bytes, got $($bytes.Length)" }
    $commitment = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    Write-Host '  (QRNG: embedding only SHA-256(seed); raw seed remains off-image)' -ForegroundColor Green
    $hdr = '; Auto-generated PUBLIC SHA-256 commitment to private seed.bin'
} else {
    $commitment = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::ASCII.GetBytes('GRIT-QRNG-NO-PRIVATE-SEED-v1'))
    Write-Host '  (QRNG: seed.bin absent -- embedding public no-seed domain commitment)' -ForegroundColor DarkYellow
    $hdr = '; Auto-generated PUBLIC no-private-seed domain commitment'
}
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($hdr)
[void]$sb.AppendLine('; Public salt/domain separator only; contributes no secret entropy.')
[void]$sb.AppendLine('qrng_commitment:')
for ($i = 0; $i -lt $commitment.Length; $i += 16) {
    $row = for ($j = $i; $j -lt [Math]::Min($i + 16, $commitment.Length); $j++) { '0x{0:x2}' -f $commitment[$j] }
    [void]$sb.AppendLine('    db ' + ($row -join ', '))
}
[void]$sb.AppendLine("qrng_commitment_len equ $($commitment.Length)")
[System.IO.File]::WriteAllText($qseedInc, $sb.ToString(), [System.Text.Encoding]::ASCII)

Write-Host '[2/2] Assembling Kernel (two-pass for KASLR fixup table)...' -ForegroundColor Yellow
$kernelA = Join-Path $BUILD_DIR 'KERNEL.A.RAW'
$kernelB = Join-Path $BUILD_DIR 'KERNEL.B.RAW'

$ErrorActionPreference = 'Continue'
& $NASM -O0 @KernelDefines -w-pp-macro-redef-multi -w-other -w-ea-absolute -f bin -o $kernelA -I "$INCLUDE_DIR\" -I "$USER_LIB_DIR\" -I "$SRC_DIR\boot\" -I "$BUILD_DIR\" "$SRC_DIR\kernel\kernel_build.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED (pass A)' -ForegroundColor Red; exit 1 }
$szA = (Get-Item $kernelA).Length
Write-Host "  OK - pass A @0x100000 ($szA bytes)" -ForegroundColor Green

$ErrorActionPreference = 'Continue'
& $NASM -O0 @KernelDefines '-dKERNEL_BASE_OVERRIDE=0x200000' -w-pp-macro-redef-multi -w-other -w-ea-absolute -f bin -o $kernelB -I "$INCLUDE_DIR\" -I "$USER_LIB_DIR\" -I "$SRC_DIR\boot\" -I "$BUILD_DIR\" "$SRC_DIR\kernel\kernel_build.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED (pass B)' -ForegroundColor Red; exit 1 }
$szB = (Get-Item $kernelB).Length
Write-Host "  OK - pass B @0x200000 ($szB bytes)" -ForegroundColor Green
if ($szA -ne $szB) {
    Write-Host "  FAILED - pass A/B size mismatch ($szA vs $szB). ORG-dependent sizing in kernel sources?" -ForegroundColor Red
    exit 1
}

# 2a. Sign the user blob (security_todo.md §9). Compute the kernel-held-key MAC
# over the embedded blob [app_blob_start, app_blob_end), EXCLUDING the absolute
# qwords that the loader relocates under KASLR (derived by diffing the two ORG
# passes), and patch the expected MAC + the sliding-offset exclusion table into
# BOTH raw passes identically. The patched bytes are constant across A/B, so
# they stay non-fixup; the runtime verifier folds 0x00 over the same excluded
# windows, making the MAC slide-independent and matching by construction. Must
# run after both passes assemble and before the KASLR diff (2c) so the patched
# bytes are inside the wrapped payload.
Write-Host '[2a] Signing user blob (kernel-held-key MAC)...' -ForegroundColor Yellow
& python (Join-Path $Root 'tools\build\patch_blob_sig.py') --a $kernelA --b $kernelB
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - blob signing' -ForegroundColor Red; exit 1 }

# 2a2. Build-patch the additive per-app integrity manifest. This keeps the old
# whole-blob HMAC path intact (phase 1), while producing the per-segment SHA-256
# table future boot/launch verification code will consume.
Write-Host '[2a2] Patching per-app integrity manifest...' -ForegroundColor Yellow
$syssigPayload = Join-Path $BUILD_DIR 'syssig_payload.bin'
& python (Join-Path $Root 'tools\build\gen_app_manifest.py') --a $kernelA --b $kernelB --export-table $syssigPayload
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - app manifest patch' -ForegroundColor Red; exit 1 }

# 2a3. Track 2 (signed everything): wrap the integrity table in a quorum-signed
# v1 envelope -> ESP\SYSSIG.ENV. The kernel's boot-chain call site
# (envelope_gate.ghl syssig_verify_boot, kmain K5) verifies it fail-closed via
# envelope_verify_signed and requires the payload to be byte-identical to the
# in-image app_integrity_table. DEV role keys sign here; production signing
# replaces this step with the HSM signer.
Write-Host '[2a3] Signing SYSSIG.ENV (Track 2 envelope)...' -ForegroundColor Yellow
$policyDepPath = Join-Path $BUILD_DIR 'release_policy_dependency.bin'
$policyInputs = @(
    (Join-Path $Root 'src\include\syscall_caps.inc'),
    (Join-Path $Root 'src\tools\security\policy_graph_check.ghl'),
    (Join-Path $Root 'src\kernel\grithlk\boot_features.ghl'),
    (Join-Path $Root 'src\kernel\grithlk\envelope_gate.ghl')
)
$policyStream = [System.IO.MemoryStream]::new()
foreach ($policyInput in $policyInputs) {
    $policyBytes = [System.IO.File]::ReadAllBytes($policyInput)
    $policyStream.Write($policyBytes, 0, $policyBytes.Length)
}
$policyHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($policyStream.ToArray())
[System.IO.File]::WriteAllBytes($policyDepPath, $policyHash)
& python (Join-Path $Root 'scripts\build\write_envelope.py') `
    --payload $syssigPayload --out "$ESP\SYSSIG.ENV" `
    --type app --device-id 1 --policy-dep $policyDepPath --require-policy-dep
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - SYSSIG.ENV signing' -ForegroundColor Red; exit 1 }
$sz = (Get-Item "$ESP\SYSSIG.ENV").Length
Write-Host "  OK - SYSSIG.ENV ($sz bytes)" -ForegroundColor Green

# 2b. Extract APPS.BIN from pass A BEFORE wrapping. The extractor scans for
# byte markers in the raw kernel image; the KASLR container header would shift
# those offsets out from under any downstream consumer that expects them.
Write-Host '[2b] Extracting APPS.BIN (from pass A)...' -ForegroundColor Yellow
& powershell -NoProfile -File (Join-Path $Root 'tools\build\extract_apps.ps1') `
    -KernelPath $kernelA `
    -OutPath "$ESP\APPS.BIN"
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED' -ForegroundColor Red; exit 1 }
$sz = (Get-Item "$ESP\APPS.BIN").Length
Write-Host "  OK - APPS.BIN ($sz bytes)" -ForegroundColor Green

# Recompute every canonical per-app digest from the exact APPS.BIN that will be
# released. A stale/partial manifest is a hard build failure, never a boot-time
# diagnostic surprise.
& python (Join-Path $Root 'tools\build\gen_app_manifest.py') `
    --a $kernelA --b $kernelB --verify-blob "$ESP\APPS.BIN"
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - released APPS.BIN manifest mismatch' -ForegroundColor Red; exit 1 }

# 2c. Diff A vs B, wrap pass A + fixup table into KERNEL.BIN.
# In -Kaslr mode the loader uses the embedded app blob because it is covered
# by the same kernel fixup table; APPS.BIN remains the non-KASLR app source.
Write-Host '[2c] Building KASLR fixup table and wrapping KERNEL.BIN...' -ForegroundColor Yellow
& python (Join-Path $Root 'tools\build\extract_kaslr_fixups.py') `
    --a $kernelA --b $kernelB --out "$ESP\KERNEL.BIN"
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED' -ForegroundColor Red; exit 1 }
$sz = (Get-Item "$ESP\KERNEL.BIN").Length
Write-Host "  OK - KERNEL.BIN ($sz bytes, wrapped)" -ForegroundColor Green

# A public commitment is expected; its private preimage must never occur in a
# release image. Run this before signing so no leaking build can be blessed.
if (Test-Path $qseedBin) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\security\check_no_shipped_secrets.ps1') `
        -ArtifactPath "$ESP\KERNEL.BIN" -SecretPath $qseedBin
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - private QRNG seed leaked into KERNEL.BIN' -ForegroundColor Red; exit 1 }
}

# 2c2. Track 2 loader-side kernel envelope: sign the SHA-256 of the final
# KERNEL.BIN container as a KERNEL-class envelope -> ESP\KERNEL.ENV. The
# kernel's K5 call site (kernel_env_verify_boot) re-hashes the pristine
# loader-read container bytes and verifies fail-closed.
Write-Host '[2c2] Signing KERNEL.ENV (Track 2 kernel envelope)...' -ForegroundColor Yellow
$kimgHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.IO.File]::ReadAllBytes("$ESP\KERNEL.BIN"))
$kimgHashPath = Join-Path $BUILD_DIR 'kernel_env_payload.bin'
[System.IO.File]::WriteAllBytes($kimgHashPath, $kimgHash)
& python (Join-Path $Root 'scripts\build\write_envelope.py') `
    --payload $kimgHashPath --out "$ESP\KERNEL.ENV" `
    --type kernel --device-id 1 --policy-dep $policyDepPath --require-policy-dep
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - KERNEL.ENV signing' -ForegroundColor Red; exit 1 }
$sz = (Get-Item "$ESP\KERNEL.ENV").Length
Write-Host "  OK - KERNEL.ENV ($sz bytes)" -ForegroundColor Green

# 3. Create data disk image with FAT16 filesystem (for ATA PIO access by kernel)
Write-Host '[3/3] Creating FAT16 data disk (data.img)...' -ForegroundColor Yellow
$dataImgPath = Join-Path $BUILD_DIR 'data.img'
$targetSize = 24 * 1024 * 1024   # 24MB - Phoenix GFX firmware set (~2.5MB) + DCN/RLC blobs + BOOTANIM
$imgBytes = New-Object byte[] $targetSize

# FAT16 partition starts where the kernel's FAT16_PART_LBA points. Read both
# source constants so BIOS, UEFI, the kernel block layer, and DATA.IMG cannot
# silently drift when the kernel reservation changes.
$kernelStartSector = Get-AsmEqu $ConstantsPath 'KERNEL_START_SECTOR'
$kernelSectors = Get-AsmEqu $ConstantsPath 'KERNEL_SECTORS'
$fatPartStart = ($kernelStartSector + $kernelSectors) * 512
$fatPartSectors = [int](($targetSize - $fatPartStart) / 512)

$bytesPerSect = 512
$sectPerClus = 4
$reservedSects = 1
$numFats = 2
$rootEntries = 512
$rootSectors = ($rootEntries * 32) / $bytesPerSect
$fatEntries = [int](($fatPartSectors - $reservedSects - $rootSectors) / $sectPerClus)
if ($fatEntries -gt 65520) { $fatEntries = 65520 }
$fatSizeSects = [int][Math]::Ceiling(($fatEntries * 2) / $bytesPerSect)
$dataSectors = $fatPartSectors - $reservedSects - ($numFats * $fatSizeSects) - $rootSectors
$totalClusters = [int]($dataSectors / $sectPerClus)

# Write BPB
$bpbOff = $fatPartStart
$imgBytes[$bpbOff + 0] = 0xEB; $imgBytes[$bpbOff + 1] = 0x3C; $imgBytes[$bpbOff + 2] = 0x90
$oem = [System.Text.Encoding]::ASCII.GetBytes("GRIT    ")
[Array]::Copy($oem, 0, $imgBytes, $bpbOff + 3, 8)
$imgBytes[$bpbOff + 11] = [byte]($bytesPerSect -band 0xFF)
$imgBytes[$bpbOff + 12] = [byte](($bytesPerSect -shr 8) -band 0xFF)
$imgBytes[$bpbOff + 13] = [byte]$sectPerClus
$imgBytes[$bpbOff + 14] = [byte]($reservedSects -band 0xFF)
$imgBytes[$bpbOff + 15] = [byte](($reservedSects -shr 8) -band 0xFF)
$imgBytes[$bpbOff + 16] = [byte]$numFats
$imgBytes[$bpbOff + 17] = [byte]($rootEntries -band 0xFF)
$imgBytes[$bpbOff + 18] = [byte](($rootEntries -shr 8) -band 0xFF)
if ($fatPartSectors -le 65535) {
    $imgBytes[$bpbOff + 19] = [byte]($fatPartSectors -band 0xFF)
    $imgBytes[$bpbOff + 20] = [byte](($fatPartSectors -shr 8) -band 0xFF)
}
$imgBytes[$bpbOff + 21] = 0xF8
$imgBytes[$bpbOff + 22] = [byte]($fatSizeSects -band 0xFF)
$imgBytes[$bpbOff + 23] = [byte](($fatSizeSects -shr 8) -band 0xFF)
$imgBytes[$bpbOff + 24] = 63; $imgBytes[$bpbOff + 25] = 0
$imgBytes[$bpbOff + 26] = 16; $imgBytes[$bpbOff + 27] = 0
$imgBytes[$bpbOff + 510] = 0x55; $imgBytes[$bpbOff + 511] = 0xAA

# FAT tables
$fat1Off = $fatPartStart + ($reservedSects * $bytesPerSect)
$imgBytes[$fat1Off + 0] = 0xF8; $imgBytes[$fat1Off + 1] = 0xFF
$imgBytes[$fat1Off + 2] = 0xFF; $imgBytes[$fat1Off + 3] = 0xFF
$fat2Off = $fat1Off + ($fatSizeSects * $bytesPerSect)
$rootDirOff = $fat2Off + ($fatSizeSects * $bytesPerSect)
$dataOff = $rootDirOff + ($rootSectors * $bytesPerSect)

function Write-DirEntry($offset, $name, $ext, $attr, $cluster, $size) {
    $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($name.PadRight(8))
    [Array]::Copy($nameBytes, 0, $imgBytes, $offset, 8)
    $extBytes = [System.Text.Encoding]::ASCII.GetBytes($ext.PadRight(3))
    [Array]::Copy($extBytes, 0, $imgBytes, $offset + 8, 3)
    $imgBytes[$offset + 11] = [byte]$attr
    $imgBytes[$offset + 26] = [byte]($cluster -band 0xFF)
    $imgBytes[$offset + 27] = [byte](($cluster -shr 8) -band 0xFF)
    $imgBytes[$offset + 28] = [byte]($size -band 0xFF)
    $imgBytes[$offset + 29] = [byte](($size -shr 8) -band 0xFF)
    $imgBytes[$offset + 30] = [byte](($size -shr 16) -band 0xFF)
    $imgBytes[$offset + 31] = [byte](($size -shr 24) -band 0xFF)
}

$nextFreeCluster = 2
function Write-FileData($data) {
    $bytesWritten = 0
    $firstCluster = $script:nextFreeCluster
    $prevCluster = -1
    $clusterSize = $sectPerClus * $bytesPerSect
    while ($bytesWritten -lt $data.Length) {
        $cluster = $script:nextFreeCluster
        $script:nextFreeCluster++
        if ($prevCluster -ge 2) {
            $fatOff = $fat1Off + ($prevCluster * 2)
            $imgBytes[$fatOff] = [byte]($cluster -band 0xFF)
            $imgBytes[$fatOff + 1] = [byte](($cluster -shr 8) -band 0xFF)
        }
        $clusterOff = $dataOff + (($cluster - 2) * $clusterSize)
        $remaining = $data.Length - $bytesWritten
        $writeLen = [Math]::Min($remaining, $clusterSize)
        [Array]::Copy($data, $bytesWritten, $imgBytes, $clusterOff, $writeLen)
        $bytesWritten += $writeLen
        $prevCluster = $cluster
    }
    if ($prevCluster -ge 2) {
        $fatOff = $fat1Off + ($prevCluster * 2)
        $imgBytes[$fatOff] = 0xFF; $imgBytes[$fatOff + 1] = 0xFF
    }
    return $firstCluster
}

$entryIdx = 0
Write-DirEntry ($rootDirOff + $entryIdx * 32) "GRIT" "   " 0x08 0 0
$entryIdx++

$readmeText = "Welcome to Grit v3.0!`r`nThis is a 64-bit operating system written entirely in x86-64 assembly.`r`n`r`nFeatures:`r`n- Graphical desktop environment`r`n- Window manager with drag support`r`n- File explorer with real FAT16 filesystem`r`n- Built-in text editor (Notepad)`r`n- Terminal with basic commands`r`n`r`nEnjoy exploring!`r`n"
$readmeData = [System.Text.Encoding]::ASCII.GetBytes($readmeText)
$readmeCluster = Write-FileData $readmeData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "README" "TXT" 0x20 $readmeCluster $readmeData.Length
$entryIdx++

$helloText = "Hello from Grit!`r`nThis file is stored on a real FAT16 filesystem.`r`nYou can edit this in Notepad and save it back.`r`n"
$helloData = [System.Text.Encoding]::ASCII.GetBytes($helloText)
$helloCluster = Write-FileData $helloData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "HELLO" "TXT" 0x20 $helloCluster $helloData.Length
$entryIdx++

$notesText = "My Notes`r`n========`r`n`r`nTODO:`r`n- Learn assembly programming`r`n- Build an OS from scratch`r`n- Add more features`r`n"
$notesData = [System.Text.Encoding]::ASCII.GetBytes($notesText)
$notesCluster = Write-FileData $notesData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "NOTES" "TXT" 0x20 $notesCluster $notesData.Length
$entryIdx++

$sysText = "Grit System Information`r`n==========================`r`nKernel: Grit v3.0`r`nArch: x86-64`r`nDisplay: 1024x768 32bpp`r`nFS: FAT16`r`n"
$sysData = [System.Text.Encoding]::ASCII.GetBytes($sysText)
$sysCluster = Write-FileData $sysData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "SYSTEM" "TXT" 0x20 $sysCluster $sysData.Length
$entryIdx++

# BMP image
$bmpWidth = 16; $bmpHeight = 16
$bmpRowSize = $bmpWidth * 3
if ($bmpRowSize % 4 -ne 0) { $bmpRowSize += 4 - ($bmpRowSize % 4) }
$bmpDataSize = $bmpRowSize * $bmpHeight
$bmpFileSize = 54 + $bmpDataSize
$bmpData = New-Object byte[] $bmpFileSize
$bmpData[0] = 0x42; $bmpData[1] = 0x4D
$bmpData[2] = [byte]($bmpFileSize -band 0xFF)
$bmpData[3] = [byte](($bmpFileSize -shr 8) -band 0xFF)
$bmpData[10] = 54; $bmpData[14] = 40
$bmpData[18] = [byte]$bmpWidth; $bmpData[22] = [byte]$bmpHeight
$bmpData[26] = 1; $bmpData[28] = 24
for ($y = 0; $y -lt $bmpHeight; $y++) {
    for ($x = 0; $x -lt $bmpWidth; $x++) {
        $off = 54 + ($y * $bmpRowSize) + ($x * 3)
        $bmpData[$off] = 0xFF; $bmpData[$off+1] = 0xFF; $bmpData[$off+2] = 0xFF
        if ($x -eq 0 -or $x -eq 15 -or $y -eq 0 -or $y -eq 15) {
            $bmpData[$off] = 0xAA; $bmpData[$off+1] = 0x55; $bmpData[$off+2] = 0x00
        }
        if ($y -ge 3 -and $y -le 12 -and $x -ge 3 -and $x -le 12) {
            if ($x -eq 3 -or $x -eq 12 -or ($x - 3) -eq (12 - $y)) {
                $bmpData[$off] = 0x00; $bmpData[$off+1] = 0x88; $bmpData[$off+2] = 0x00
            }
        }
    }
}
$logoCluster = Write-FileData $bmpData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "LOGO" "BMP" 0x20 $logoCluster $bmpData.Length
$entryIdx++

# Wallpaper SVG sample for Media Player. 8.3 name: RIBBONS.SVG
$ribbonsSvgPath = Join-Path $Root 'src\resources\wallpapers\glass-ribbons.svg'
if (Test-Path $ribbonsSvgPath) {
    $ribbonsSvgData = [System.IO.File]::ReadAllBytes($ribbonsSvgPath)
    $ribbonsSvgCluster = Write-FileData $ribbonsSvgData
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "RIBBONS" "SVG" 0x20 $ribbonsSvgCluster $ribbonsSvgData.Length
    $entryIdx++
    Write-Host "  + RIBBONS.SVG ($($ribbonsSvgData.Length) bytes)" -ForegroundColor DarkGray
}

# Boot animation file
$bootAnimPath = Join-Path $BUILD_DIR 'BOOTANIM.NBA'
if (Test-Path $bootAnimPath) {
    $bootAnimData = [System.IO.File]::ReadAllBytes($bootAnimPath)
    $bootAnimCluster = Write-FileData $bootAnimData
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "BOOTANIM" "NBA" 0x20 $bootAnimCluster $bootAnimData.Length
    $entryIdx++
    Write-Host "  + BOOTANIM.NBA ($($bootAnimData.Length) bytes)" -ForegroundColor DarkGray
}

# AMD DCN/Phoenix firmware blob copy retired 2026-05-26 along with the
# 780M iGPU subsystem. Source preserved under deprecated/780M_IGPU/firmware/.

# Copy FAT1 to FAT2
[Array]::Copy($imgBytes, $fat1Off, $imgBytes, $fat2Off, $fatSizeSects * $bytesPerSect)

try {
    [System.IO.File]::WriteAllBytes($dataImgPath, $imgBytes)
    Write-Host "  OK - data.img ($totalClusters clusters, $($entryIdx - 1) files)" -ForegroundColor Green
} catch [System.IO.IOException] {
    if (-not (Test-Path $dataImgPath)) { throw }
    Write-Host "  WARN - data.img locked by another process; keeping existing image" -ForegroundColor Yellow
}

# 3b. Copy the FAT16 partition slice to ESP\EFI\BOOT\DATA.IMG.
#
# On real hardware the kernel has no legacy IDE controller, so it cannot
# read the QEMU-only `data.img` via ATA PIO. The UEFI loader instead reads
# this file from the boot ESP into RAM and the kernel's ramdisk shim
# (src/kernel/drivers/ramdisk.asm) serves fat16 sector I/O from there.
# See docs/ramdisk.md for the full contract.
#
# We ship only the partition (skip the (KERNEL_START_SECTOR + KERNEL_SECTORS)
# zero header) so the on-USB file is as small as possible. The kernel's
# fat16 driver adds FAT16_PART_LBA to every LBA it computes; the ramdisk
# is registered at LBA base = FAT16_PART_LBA, which makes byte offset 0
# of DATA.IMG correspond to BPB sector 0 - identical to QEMU's mapping.
$espDataImgPath = Join-Path $ESP 'DATA.IMG'
$espDataImgBytes = New-Object byte[] ($fatPartSectors * $bytesPerSect)
[Array]::Copy($imgBytes, $fatPartStart, $espDataImgBytes, 0, $espDataImgBytes.Length)
try {
    [System.IO.File]::WriteAllBytes($espDataImgPath, $espDataImgBytes)
    Write-Host ("  OK - DATA.IMG ($([math]::Round($espDataImgBytes.Length / 1MB,2)) MiB on ESP)") -ForegroundColor Green
} catch [System.IO.IOException] {
    if (-not (Test-Path $espDataImgPath)) { throw }
    Write-Host "  WARN - ESP\DATA.IMG locked; keeping existing copy" -ForegroundColor Yellow
}

# Guard: if DATA.IMG exceeds the loader's DATA_IMG_MAX_SIZE (32 MiB today)
# the kernel will reject it at boot. Catch that at build time instead.
$dataImgMax = 32 * 1024 * 1024
if ($espDataImgBytes.Length -gt $dataImgMax) {
    Write-Host "  FAILED - DATA.IMG ($($espDataImgBytes.Length) bytes) exceeds DATA_IMG_MAX_SIZE ($dataImgMax). Bump src/include/boot_memory.inc." -ForegroundColor Red
    exit 1
}

if ($Release) {
    Write-Host '[release] Pinning payloads into BOOTX64.EFI...' -ForegroundColor Yellow
    $loaderManifest = Join-Path $BUILD_DIR 'loader_manifest.inc'
    & python (Join-Path $Root 'tools\build\gen_loader_manifest.py') `
        --esp $ESP --out $loaderManifest --version $ReleaseVersion
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - loader manifest generation' -ForegroundColor Red; exit 1 }

    $ErrorActionPreference = 'Continue'
    & $NASM @LoaderDefines -f bin -o "$ESP\BOOTX64.EFI" "$SRC_DIR\boot\uefi_loader.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - release loader assembly' -ForegroundColor Red; exit 1 }

    $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'
    $signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'
    if (-not (Test-Path $openssl)) { Write-Host '  FAILED - openssl.exe is required for release signing' -ForegroundColor Red; exit 1 }
    if (-not (Test-Path $signtool)) { Write-Host '  FAILED - signtool.exe is required for release signing' -ForegroundColor Red; exit 1 }

    $signDir = Join-Path $BUILD_DIR 'secureboot'
    New-Item -Path $signDir -ItemType Directory -Force | Out-Null
    $keyPem = Join-Path $signDir 'grit-test-db.key.pem'
    $certPem = Join-Path $signDir 'grit-test-db.cert.pem'
    $certDer = Join-Path $signDir 'GRIT_TEST_DB.cer'
    $pfxPath = Join-Path $signDir 'grit-test-db.pfx'
    $passwordPath = Join-Path $signDir 'pfx-password.txt'
    if (-not (Test-Path $pfxPath)) {
        $pfxPassword = [Guid]::NewGuid().ToString('N')
        [System.IO.File]::WriteAllText($passwordPath, $pfxPassword, [System.Text.Encoding]::ASCII)
        & $openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes `
            -keyout $keyPem -out $certPem -days 3650 `
            -subj '/CN=Grit Secure Boot Test DB/' `
            -addext 'keyUsage=critical,digitalSignature' `
            -addext 'extendedKeyUsage=codeSigning'
        if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - Secure Boot certificate generation' -ForegroundColor Red; exit 1 }
        & $openssl pkcs12 -export -out $pfxPath -inkey $keyPem -in $certPem -passout "pass:$pfxPassword"
        if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - PFX generation' -ForegroundColor Red; exit 1 }
        & $openssl x509 -in $certPem -outform DER -out $certDer
        if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - enrollment certificate export' -ForegroundColor Red; exit 1 }
    }
    if (-not (Test-Path $passwordPath)) { Write-Host '  FAILED - signing password is missing' -ForegroundColor Red; exit 1 }
    $pfxPassword = [System.IO.File]::ReadAllText($passwordPath).Trim()
    & $signtool sign /fd SHA256 /f $pfxPath /p $pfxPassword "$ESP\BOOTX64.EFI"
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED - BOOTX64.EFI signing' -ForegroundColor Red; exit 1 }
    Write-Host "  OK - signed BOOTX64.EFI; enroll $certDer in the firmware db for testing" -ForegroundColor Green

    Write-Host '[release] Scanning public artifacts...' -ForegroundColor Yellow
    # --allow-test-cert: this build self-signs with the development Secure Boot
    # test-DB cert (above). A production release omits this flag so the gate
    # rejects the test cert and demands the production signing cert.
    & python (Join-Path $Root 'tools\security\check_release_artifacts.py') --esp $ESP --allow-test-cert
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  FAILED - release artifact security scan' -ForegroundColor Red
        exit 1
    }
}

Write-Host ''
Write-Host '  BUILD SUCCESSFUL' -ForegroundColor Green
Write-Host ''
Write-Host "  Output: $ESP\" -ForegroundColor White
Write-Host '    BOOTX64.EFI  (UEFI bootloader)' -ForegroundColor Gray
Write-Host '    KERNEL.BIN   (Grit kernel)' -ForegroundColor Gray
Write-Host '    APPS.BIN     (GritHL app blob)' -ForegroundColor Gray
Write-Host '    DATA.IMG     (FAT16 ramdisk for real hardware)' -ForegroundColor Gray
Write-Host "    $dataImgPath  (FAT16 data disk for QEMU IDE)" -ForegroundColor Gray
Write-Host ''

# ---------------------------------------------------------------------------
# Copy built ESP tree to E:\ so the user can boot from removable media.
# Runs by default; pass -CopyToE:$false to skip (e.g. when E: is unmounted).
# ---------------------------------------------------------------------------
if ($CopyToE -or -not $PSBoundParameters.ContainsKey('CopyToE')) {
    if (Test-Path 'E:\') {
        Write-Host '[copy] Mirroring ESP -> E:\EFI\BOOT\ ...' -ForegroundColor Yellow
        try {
            $eEfi = 'E:\EFI\BOOT'
            New-Item -Path $eEfi -ItemType Directory -Force | Out-Null
            Copy-Item "$ESP\BOOTX64.EFI" $eEfi -Force
            Copy-Item "$ESP\KERNEL.BIN"  $eEfi -Force
            Copy-Item "$ESP\APPS.BIN"    $eEfi -Force
            Copy-Item "$ESP\SYSSIG.ENV"  $eEfi -Force
            Copy-Item "$ESP\KERNEL.ENV"  $eEfi -Force
            Copy-Item "$ESP\DATA.IMG"    $eEfi -Force
            Write-Host '  OK - E:\EFI\BOOT\ updated (boot-ready)' -ForegroundColor Green
        } catch {
            Write-Host "  WARN - copy to E:\ failed: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host '  (skip E:\ copy - drive not mounted)' -ForegroundColor DarkGray
    }
}
