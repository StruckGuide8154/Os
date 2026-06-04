param(
    [switch]$Release,
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
    [switch]$Cet,            # Enable the hardware CET scaffold (CR4.CET + IA32_S_CET). CPUID-gated at runtime (no-op on CPUs/VMs without SHSTK, incl. QEMU TCG); complements the always-on software kernel shadow stack. SHSTK/IBT *detection* is always compiled regardless of this flag. The supervisor shadow-stack RET-check itself is NOT armed yet (needs a seeded PL0_SSP — documented follow-up in src/include/cet.inc).
    # NOTE: -Cet is retained for old scripts only; CET protection is default-on.
    [switch]$NoCet,          # Disable CET SHSTK protection. Default ON: hardware SHSTK when CPUID exposes it, software shadow-stack fallback otherwise.
    [switch]$CetIbt,         # Additionally arm the IBT-side S_CET bits when IBT is present. Requires -Cet. OFF by default: endbr64 markers are not yet emitted at indirect-branch targets, so enabling ENDBR_EN would #CP. Plumbing only.
    [switch]$Kpti,           # Kernel Page-Table Isolation (security_todo.md §3). Compiles the user-view-PML4 builder + CR3-swap entry/exit macros (src/include/kpti.inc). OFF by default -> macros emit nothing, no kpti.inc code/data, default image byte-for-byte unchanged. Even with -Kpti the feature is a runtime no-op (kpti_active=0) until the SYSCALL (syscall.asm) + IRQ/exception (isr.asm) CR3-swap points and the kmain kpti_init flip are wired -- see the scoped-out note in kpti.inc. The usermode.asm iretq exits are already wired (inert until armed). Compile-gate verification only for now.
    [switch]$NoKpti,         # Disable KPTI. Default ON: user-view CR3 while ring 3 runs, full kernel CR3 on entry.
    [switch]$NoSyscallPerm,  # Disable heterogeneous syscall numbering per slot (security_todo.md §12). ON by default: per-launch keyed-random permutation of the syscall table; the loader rewrites each app's compiled SYS_* immediates (via the .scfix fixup table) to the slot's forward-permuted numbers, and the dispatcher applies the kernel-side inverse mapping on entry. Pass -NoSyscallPerm to fall back to identity numbering.
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
$KernelDefines = @()
$LoaderDefines = @()
if (-not $Release) {
    $KernelDefines += '-dENABLE_DEBUG_SERIAL'
    $KernelDefines += '-dENABLE_USER_DEBUG_SYSCALL'
}
else {
    $KernelDefines += '-dRELEASE_BUILD'
}
if ($PerfProfile -eq 'Cache32Max') {
    $KernelDefines += '-dNEXUS_CACHE32_MAX'
    $LoaderDefines += '-dNEXUS_CACHE32_MAX'
}
if ($NoFbWc) {
    $KernelDefines += '-dFBPERF_NO_WC'
    Write-Host '  (FBPERF: WC activation DISABLED -- Phase A baseline build)' -ForegroundColor Magenta
}
if ($NoMemRandom) {
    $KernelDefines += '-dNEXUS_NO_MEM_RANDOM'
    $KernelDefines += '-dNEXUS_BOOT_DIAG_LOG'
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
# default-on SHSTK protection uses hardware support when present and the
# software shadow-stack fallback otherwise. -NoCet is the explicit opt-out.
if ($CetIbt -and $NoCet) {
    Write-Host '  FAILED - -CetIbt requires CET; remove -NoCet.' -ForegroundColor Red
    exit 1
}
if (-not $NoCet) {
    $KernelDefines += '-dENABLE_CET'
    if ($Cet) {
        Write-Host '  (CET: -Cet accepted for compatibility; SHSTK protection is already ON by default)' -ForegroundColor Gray
    }
    Write-Host '  (CET: SHSTK protection ENABLED by default -- hardware when CPUID exposes it, software fallback otherwise; -NoCet to disable)' -ForegroundColor Magenta
    if ($CetIbt) {
        $KernelDefines += '-dENABLE_CET_IBT'
        Write-Host '  (CET: IBT S_CET bits armed -- plumbing only, endbr64 markers pending)' -ForegroundColor Magenta
    }
} else {
    Write-Host '  (CET: DISABLED via -NoCet -- SHSTK/IBT detection still compiled)' -ForegroundColor Yellow
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
    Write-Host '  (KASLR: enabled — kernel will load at a random base each boot)' -ForegroundColor Magenta
} else {
    Write-Host '  (KASLR: DISABLED -- slide forced to 0)' -ForegroundColor Yellow
}
$KernelDefines += '-dNEXUS_SMP'
$KernelDefines += '-dNEXUS_CACHE32_AP_STARTUP'
$KernelDefines += '-dNEXUS_ENABLE_RING3_AP'
# UEFI starts AP workers in both profiles. Keep ring-3 callback routing
# enabled with AP startup so app work runs on each process home_core instead
# of falling through dispatch_app_callback's BSP-only fallback.
if ($Trace) {
    $KernelDefines += '-dENABLE_TRACE'
    $KernelDefines += '-dENABLE_SIG_SECTION'
}

Write-Host ''
Write-Host '  NexusOS UEFI Build System' -ForegroundColor Cyan
Write-Host '  =========================' -ForegroundColor Cyan
Write-Host ("  Mode: " + ($(if ($Release) { 'release' } else { 'debug' }))) -ForegroundColor DarkGray
Write-Host "  Perf: $PerfProfile" -ForegroundColor DarkGray
Write-Host ("  Trace: " + ($(if ($Trace) { 'on' } else { 'off' }))) -ForegroundColor DarkGray
Write-Host ''

New-Item -Path $ESP -ItemType Directory -Force | Out-Null

# 0. Embed SVG wallpaper sources into wallpaper.nxh so the native NexusHL
# renderer (svg_render) has the current SVG strings. Run on every build so
# edits to src/resources/wallpapers/*.svg are picked up automatically.
$WallpaperTool = Join-Path $Root 'tools\gen_wallpaper_strings.py'
if (Test-Path $WallpaperTool) {
    & python $WallpaperTool
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED wallpaper string gen' -ForegroundColor Red; exit 1 }
}

# 0b. Compile NexusHL apps -> build/nxh/*.asm (included by src/user/apps.asm)
& powershell -NoProfile -File (Join-Path $Root 'scripts\build\build_nxh.ps1')
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED NexusHL compile' -ForegroundColor Red; exit 1 }

# 0b2. Compile NexusHLK kernel modules -> build/nxh/*.asm (%include'd by
# kernel_build.asm). These use nxhc.py's kernel emit mode (--target kernel):
# plain NASM, bare labels, direct in-unit calls, no app-blob framing. Currently
# the serial-diagnostic leaf cluster (PoC). Regenerated every build so the
# .nxh source stays the source of truth for the generated .asm.
$NxhcPy   = Join-Path $Root 'src\user\nexushl\compiler\nxhc.py'
$NxhLibDir = Join-Path $Root 'src\user\nexushl\lib'
$NxhkOutDir = Join-Path $Root 'build\nxh'
New-Item -Path $NxhkOutDir -ItemType Directory -Force | Out-Null
$KernelModules = @(
    @{ src = 'src\kernel\nexushlk\kernel_console.nxh'; out = 'build\nxh\kernel_console.asm' },
    @{ src = 'src\kernel\nexushlk\context_menu.nxh'; out = 'build\nxh\context_menu.asm' },
    @{ src = 'src\kernel\nexushlk\kernel_lifecycle.nxh'; out = 'build\nxh\kernel_lifecycle.asm' },
    @{ src = 'src\kernel\nexushlk\serial_poll.nxh'; out = 'build\nxh\serial_poll.asm' },
    @{ src = 'src\kernel\nexushlk\input_dispatch.nxh'; out = 'build\nxh\input_dispatch.asm' },
    @{ src = 'src\kernel\nexushlk\frame_present.nxh'; out = 'build\nxh\frame_present.asm' },
    @{ src = 'src\kernel\nexushlk\serial_diag.nxh'; out = 'build\nxh\serial_diag.asm' },
    @{ src = 'src\kernel\nexushlk\boot_diag.nxh';   out = 'build\nxh\boot_diag.asm' },
    @{ src = 'src\kernel\nexushlk\debug_overlay.nxh'; out = 'build\nxh\debug_overlay.asm' },
    @{ src = 'src\kernel\nexushlk\cpu_acct.nxh';    out = 'build\nxh\cpu_acct.asm' },
    @{ src = 'src\kernel\nexushlk\serial_console.nxh'; out = 'build\nxh\serial_console.asm' },
    @{ src = 'src\kernel\nexushlk\real_boot_diag.nxh'; out = 'build\nxh\real_boot_diag.asm' },
    @{ src = 'src\kernel\nexushlk\real_boot_diag_core.nxh'; out = 'build\nxh\real_boot_diag_core.asm' },
    @{ src = 'src\kernel\nexushlk\real_boot_diag_fbperf.nxh'; out = 'build\nxh\real_boot_diag_fbperf.asm' },
    @{ src = 'src\kernel\nexushlk\real_boot_diag_legacy.nxh'; out = 'build\nxh\real_boot_diag_legacy.asm' },
    @{ src = 'src\kernel\nexushlk\real_boot_diag_gfx.nxh'; out = 'build\nxh\real_boot_diag_gfx.asm' }
)
foreach ($m in $KernelModules) {
    $mSrc = Join-Path $Root $m.src
    $mOut = Join-Path $Root $m.out
    Write-Host "  compile (kernel) $($m.src)" -ForegroundColor Yellow
    & python $NxhcPy $mSrc -o $mOut -L $NxhLibDir --embed --target kernel
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED NexusHLK kernel-module compile' -ForegroundColor Red; exit 1 }
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

# 1. Assemble UEFI Loader -> BOOTX64.EFI
Write-Host '[1/2] Assembling UEFI Loader...' -ForegroundColor Yellow
$ErrorActionPreference = 'Continue'
& $NASM @LoaderDefines -f bin -o "$ESP\BOOTX64.EFI" "$SRC_DIR\boot\uefi_loader.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) {
    Write-Host '  FAILED' -ForegroundColor Red
    exit 1
}
$sz = (Get-Item "$ESP\BOOTX64.EFI").Length
Write-Host "  OK - BOOTX64.EFI ($sz bytes)" -ForegroundColor Green

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
# Generate the quantum-entropy include the kernel folds into kernel_canary.
# The raw seed (tools/quantum/seed.bin) is a PRIVATE build secret and is NOT in
# the repo. If present we emit it; if absent we emit 1024 zero bytes, which
# XOR-fold to a no-op so a clean public checkout still builds and behaves
# exactly like the pre-quantum kernel (RDTSC^RDRAND only). Regenerate the seed
# with tools/quantum/qrng_seed.py.
$qseedBin = Join-Path $Root 'tools\quantum\seed.bin'
$qseedInc = Join-Path $BUILD_DIR 'qrng_seed.inc'
$QSEED_LEN = 1024
if (Test-Path $qseedBin) {
    $bytes = [System.IO.File]::ReadAllBytes($qseedBin)
    if ($bytes.Length -ne $QSEED_LEN) { throw "seed.bin must be $QSEED_LEN bytes, got $($bytes.Length)" }
    Write-Host "  (QRNG: folding $QSEED_LEN bytes of quantum entropy from tools/quantum/seed.bin)" -ForegroundColor Green
    $hdr = "; Auto-generated from tools/quantum/seed.bin (PRIVATE) -- DO NOT COMMIT"
} else {
    $bytes = New-Object byte[] $QSEED_LEN   # all zeros -> fold is a no-op
    Write-Host "  (QRNG: seed.bin absent -- emitting zero fallback; canary uses RDTSC^RDRAND only)" -ForegroundColor DarkYellow
    $hdr = "; Auto-generated ZERO FALLBACK (no tools/quantum/seed.bin present)"
}
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($hdr)
[void]$sb.AppendLine('qrng_seed_blob:')
for ($i = 0; $i -lt $bytes.Length; $i += 16) {
    $row = for ($j = $i; $j -lt [Math]::Min($i + 16, $bytes.Length); $j++) { '0x{0:x2}' -f $bytes[$j] }
    [void]$sb.AppendLine('    db ' + ($row -join ', '))
}
[void]$sb.AppendLine("qrng_seed_len equ $($bytes.Length)")
[System.IO.File]::WriteAllText($qseedInc, $sb.ToString(), [System.Text.Encoding]::ASCII)

Write-Host '[2/2] Assembling Kernel (two-pass for KASLR fixup table)...' -ForegroundColor Yellow
$kernelA = Join-Path $BUILD_DIR 'KERNEL.A.RAW'
$kernelB = Join-Path $BUILD_DIR 'KERNEL.B.RAW'

$ErrorActionPreference = 'Continue'
& $NASM -O0 @KernelDefines -w-pp-macro-redef-multi -f bin -o $kernelA -I "$INCLUDE_DIR\" -I "$USER_LIB_DIR\" -I "$SRC_DIR\boot\" -I "$BUILD_DIR\" "$SRC_DIR\kernel\kernel_build.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED (pass A)' -ForegroundColor Red; exit 1 }
$szA = (Get-Item $kernelA).Length
Write-Host "  OK - pass A @0x100000 ($szA bytes)" -ForegroundColor Green

$ErrorActionPreference = 'Continue'
& $NASM -O0 @KernelDefines '-dKERNEL_BASE_OVERRIDE=0x200000' -w-pp-macro-redef-multi -f bin -o $kernelB -I "$INCLUDE_DIR\" -I "$USER_LIB_DIR\" -I "$SRC_DIR\boot\" -I "$BUILD_DIR\" "$SRC_DIR\kernel\kernel_build.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
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

# 2c. Diff A vs B, wrap pass A + fixup table into KERNEL.BIN.
# In -Kaslr mode the loader uses the embedded app blob because it is covered
# by the same kernel fixup table; APPS.BIN remains the non-KASLR app source.
Write-Host '[2c] Building KASLR fixup table and wrapping KERNEL.BIN...' -ForegroundColor Yellow
& python (Join-Path $Root 'tools\build\extract_kaslr_fixups.py') `
    --a $kernelA --b $kernelB --out "$ESP\KERNEL.BIN"
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED' -ForegroundColor Red; exit 1 }
$sz = (Get-Item "$ESP\KERNEL.BIN").Length
Write-Host "  OK - KERNEL.BIN ($sz bytes, wrapped)" -ForegroundColor Green

# 3. Create data disk image with FAT16 filesystem (for ATA PIO access by kernel)
Write-Host '[3/3] Creating FAT16 data disk (data.img)...' -ForegroundColor Yellow
$dataImgPath = Join-Path $BUILD_DIR 'data.img'
$targetSize = 24 * 1024 * 1024   # 24MB — Phoenix GFX firmware set (~2.5MB) + DCN/RLC blobs + BOOTANIM
$imgBytes = New-Object byte[] $targetSize

# FAT16 partition starts where the kernel's FAT16_PART_LBA points. Keep this
# aligned with src/include/constants.inc: KERNEL_START_SECTOR + KERNEL_SECTORS.
$fatPartStart = (64 + 4096) * 512
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
$oem = [System.Text.Encoding]::ASCII.GetBytes("NEXUSOS ")
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
Write-DirEntry ($rootDirOff + $entryIdx * 32) "NEXUSOS" "   " 0x08 0 0
$entryIdx++

$readmeText = "Welcome to NexusOS v3.0!`r`nThis is a 64-bit operating system written entirely in x86-64 assembly.`r`n`r`nFeatures:`r`n- Graphical desktop environment`r`n- Window manager with drag support`r`n- File explorer with real FAT16 filesystem`r`n- Built-in text editor (Notepad)`r`n- Terminal with basic commands`r`n`r`nEnjoy exploring!`r`n"
$readmeData = [System.Text.Encoding]::ASCII.GetBytes($readmeText)
$readmeCluster = Write-FileData $readmeData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "README" "TXT" 0x20 $readmeCluster $readmeData.Length
$entryIdx++

$helloText = "Hello from NexusOS!`r`nThis file is stored on a real FAT16 filesystem.`r`nYou can edit this in Notepad and save it back.`r`n"
$helloData = [System.Text.Encoding]::ASCII.GetBytes($helloText)
$helloCluster = Write-FileData $helloData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "HELLO" "TXT" 0x20 $helloCluster $helloData.Length
$entryIdx++

$notesText = "My Notes`r`n========`r`n`r`nTODO:`r`n- Learn assembly programming`r`n- Build an OS from scratch`r`n- Add more features`r`n"
$notesData = [System.Text.Encoding]::ASCII.GetBytes($notesText)
$notesCluster = Write-FileData $notesData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "NOTES" "TXT" 0x20 $notesCluster $notesData.Length
$entryIdx++

$sysText = "NexusOS System Information`r`n==========================`r`nKernel: NexusOS v3.0`r`nArch: x86-64`r`nDisplay: 1024x768 32bpp`r`nFS: FAT16`r`n"
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

Write-Host ''
Write-Host '  BUILD SUCCESSFUL' -ForegroundColor Green
Write-Host ''
Write-Host "  Output: $ESP\" -ForegroundColor White
Write-Host '    BOOTX64.EFI  (UEFI bootloader)' -ForegroundColor Gray
Write-Host '    KERNEL.BIN   (NexusOS kernel)' -ForegroundColor Gray
Write-Host '    APPS.BIN     (NexusHL app blob)' -ForegroundColor Gray
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
            Copy-Item "$ESP\DATA.IMG"    $eEfi -Force
            Write-Host '  OK - E:\EFI\BOOT\ updated (boot-ready)' -ForegroundColor Green
        } catch {
            Write-Host "  WARN - copy to E:\ failed: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host '  (skip E:\ copy — drive not mounted)' -ForegroundColor DarkGray
    }
}
