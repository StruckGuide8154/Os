$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

$NoAsmGuard = Join-Path $Root 'tools\security\check_no_asm.ps1'
$PrivacyGuard = Join-Path $Root 'tools\security\check_release_privacy.ps1'
$BuildIntegrityGuard = Join-Path $Root 'tools\security\check_build_integrity.ps1'
$PresubmitGuard = Join-Path $Root 'tools\security\check_ghl_presubmit.ps1'
$FixtureGuard = Join-Path $Root 'scripts\test\test_ghl_security_fixtures.ps1'
$InvariantGuard = Join-Path $Root 'scripts\test\test_ghl_invariants.ps1'
$MetaTest = Join-Path $Root 'scripts\test\test_enforcement_meta.ps1'
$UserspaceDriverGuard = Join-Path $Root 'scripts\test\test_userspace_drivers.ps1'
$NoShippedSecretsTest = Join-Path $Root 'scripts\test\test_no_shipped_secrets.ps1'
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$LibDir = Join-Path $Root 'src\user\grithl\lib'
$SecurityModuleDir = Join-Path $Root 'src\tools\security'

$ExpectedSecurityModules = @(
    'compatibility_check.ghl',
    'fme_memory_encryption_check.ghl',
    'invariant_check.ghl',
    'no_asm_guard.ghl',
    'policy_graph_check.ghl',
    'release_privacy_guard.ghl',
    'revocation_check.ghl',
    'schema_canonical_check.ghl',
    'signed_artifact_check.ghl',
    'signed_envelope.ghl',
    'threshold_check.ghl'
)

if (-not (Test-Path -LiteralPath $NoAsmGuard)) {
    throw "Missing GHL no-ASM guard: $NoAsmGuard"
}
if (-not (Test-Path -LiteralPath $PrivacyGuard)) {
    throw "Missing release privacy guard: $PrivacyGuard"
}
if (-not (Test-Path -LiteralPath $BuildIntegrityGuard)) {
    throw "Missing build-graph integrity guard: $BuildIntegrityGuard"
}
if (-not (Test-Path -LiteralPath $PresubmitGuard)) {
    throw "Missing GHL presubmit guard: $PresubmitGuard"
}
if (-not (Test-Path -LiteralPath $FixtureGuard)) {
    throw "Missing GHL security fixture guard: $FixtureGuard"
}
if (-not (Test-Path -LiteralPath $MetaTest)) {
    throw "Missing enforcement meta-test: $MetaTest"
}
if (-not (Test-Path -LiteralPath $NoShippedSecretsTest)) {
    throw "Missing no-shipped-secrets test: $NoShippedSecretsTest"
}
if (-not (Test-Path -LiteralPath $InvariantGuard)) {
    throw "Missing GHL invariant guard: $InvariantGuard"
}
if (-not (Test-Path -LiteralPath $Compiler)) {
    throw "Missing GritHL compiler: $Compiler"
}
if (-not (Test-Path -LiteralPath $LibDir -PathType Container)) {
    throw "Missing GritHL library directory: $LibDir"
}
if (-not (Test-Path -LiteralPath $SecurityModuleDir -PathType Container)) {
    throw "Missing GHL security module directory: $SecurityModuleDir"
}

Write-Host '[ghl-security] === Bootstrap host-scanning guards ===' -ForegroundColor Cyan

Write-Host '[ghl-security] Checking release privacy...' -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $PrivacyGuard
if ($LASTEXITCODE -ne 0) {
    throw 'Release privacy guard failed.'
}

Write-Host '[ghl-security] Checking GHL no-ASM trusted path...' -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $NoAsmGuard
if ($LASTEXITCODE -ne 0) {
    throw 'GHL no-ASM guard failed.'
}

Write-Host '[ghl-security] Checking legacy assembly inventory (no new .asm/.inc)...' -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $NoAsmGuard -InventoryGuard
if ($LASTEXITCODE -ne 0) {
    throw 'Legacy assembly inventory guard failed (new or stale .asm/.inc).'
}

Write-Host '[ghl-security] Checking build-graph integrity (legacy vs new-architecture)...' -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $BuildIntegrityGuard
if ($LASTEXITCODE -ne 0) {
    throw 'Build-graph integrity guard failed (asm/include/nasm leak, generated-as-source, or deprecated import).'
}

Write-Host '[ghl-security] Checking GHL source presubmit rules...' -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $PresubmitGuard
if ($LASTEXITCODE -ne 0) {
    throw 'GHL presubmit guard failed (raw emitter, inc-public-api, intrinsic, threat-note, release-logging, or raw-user-data).'
}

$missingModules = @()
foreach ($moduleName in $ExpectedSecurityModules) {
    $modulePath = Join-Path $SecurityModuleDir $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        $missingModules += $moduleName
    }
}
if ($missingModules.Count -gt 0) {
    throw "Missing expected GHL security module(s): $($missingModules -join ', ')"
}

$securityModules = @(Get-ChildItem -LiteralPath $SecurityModuleDir -Filter '*.ghl' -File | Sort-Object Name)
if ($securityModules.Count -eq 0) {
    throw "No GHL security policy modules found in $SecurityModuleDir"
}

Write-Host '[ghl-security] === GHL policy-module verification ===' -ForegroundColor Cyan
Write-Host "[ghl-security] Compiling $($securityModules.Count) GHL security module(s) with --target kernel --forbid-asm --deny-unsafe" -ForegroundColor Yellow

$OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ghl-security-modules-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
try {
    foreach ($module in $securityModules) {
        $outPath = Join-Path $OutDir ([System.IO.Path]::ChangeExtension($module.Name, '.asm'))
        Write-Host "[ghl-security] compile policy module $($module.Name)" -ForegroundColor Yellow
        & python $Compiler $module.FullName -o $outPath -L $LibDir --embed --target kernel --forbid-asm --deny-unsafe
        if ($LASTEXITCODE -ne 0) {
            throw "GHL policy module compile failed: $($module.Name)"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $OutDir) {
        Remove-Item -LiteralPath $OutDir -Recurse -Force
    }
}

Write-Host '[ghl-security] === GHL checker fixture verification ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $FixtureGuard
if ($LASTEXITCODE -ne 0) {
    throw 'GHL security fixture guard failed.'
}

Write-Host '[ghl-security] === seL4 validity invariant verification ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $InvariantGuard
if ($LASTEXITCODE -ne 0) {
    throw 'GHL invariant guard failed.'
}

Write-Host '[ghl-security] === Track-2 signed-envelope reject matrix (real reader executed) ===' -ForegroundColor Cyan
$EnvelopeEval = Join-Path $Root 'scripts\test\eval_envelope.py'
if (-not (Test-Path -LiteralPath $EnvelopeEval)) {
    throw "Missing envelope reject-matrix evaluator: $EnvelopeEval"
}
& python $EnvelopeEval
if ($LASTEXITCODE -ne 0) {
    throw 'Signed-envelope reject-matrix evaluation failed.'
}

Write-Host '[ghl-security] === Track-2 envelope fuzz + differential + canonical round-trip ===' -ForegroundColor Cyan
$EnvelopeFuzz = Join-Path $Root 'scripts\test\fuzz_envelope.py'
if (-not (Test-Path -LiteralPath $EnvelopeFuzz)) {
    throw "Missing envelope fuzz/differential suite: $EnvelopeFuzz"
}
& python $EnvelopeFuzz
if ($LASTEXITCODE -ne 0) {
    throw 'Signed-envelope fuzz/differential/property suite failed.'
}

Write-Host '[ghl-security] === Track-2 Ed25519 threshold-signature crypto (real GHL verifier) ===' -ForegroundColor Cyan
$Ed25519Eval = Join-Path $Root 'scripts\test\eval_ed25519.py'
if (-not (Test-Path -LiteralPath $Ed25519Eval)) {
    throw "Missing Ed25519 verifier evaluator: $Ed25519Eval"
}
& python $Ed25519Eval
if ($LASTEXITCODE -ne 0) {
    throw 'Ed25519 verifier evaluation failed.'
}

Write-Host '[ghl-security] === Enforcement meta-tests (the guards have negative tests) ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $MetaTest
if ($LASTEXITCODE -ne 0) {
    throw 'Enforcement meta-tests failed.'
}

Write-Host '[ghl-security] === Track-8 user-space-driver enforcement (G2: no in-kernel drivers) ===' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $UserspaceDriverGuard)) {
    throw "Missing Track-8 user-space-driver guard: $UserspaceDriverGuard"
}
& powershell -NoProfile -ExecutionPolicy Bypass -File $UserspaceDriverGuard
if ($LASTEXITCODE -ne 0) {
    throw 'Track-8 user-space-driver enforcement failed (new in-kernel driver or inventory drift).'
}
& powershell -NoProfile -ExecutionPolicy Bypass -File $UserspaceDriverGuard -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw 'Track-8 user-space-driver guard negative self-test failed (guard does not trip on a planted violation).'
}

Write-Host '[ghl-security] === Track-8 driver-host broker compiles (--target kernel --forbid-asm) ===' -ForegroundColor Cyan
$DriverHostModule = Join-Path $Root 'src\kernel\grithlk\driver_host.ghl'
if (-not (Test-Path -LiteralPath $DriverHostModule)) {
    throw "Missing driver-host broker module: $DriverHostModule"
}
$DhOut = Join-Path ([System.IO.Path]::GetTempPath()) ('driver_host-' + [System.Guid]::NewGuid().ToString('N') + '.asm')
& python $Compiler $DriverHostModule -o $DhOut -L $LibDir --embed --target kernel --forbid-asm
if ($LASTEXITCODE -ne 0) {
    throw 'Driver-host broker module failed to compile (--target kernel --forbid-asm).'
}
if (Test-Path -LiteralPath $DhOut) { Remove-Item -LiteralPath $DhOut -Force }

Write-Host '[ghl-security] === Track-8 HDA audio class driver compiles broker-only (--target driver) ===' -ForegroundColor Cyan
$HdaModule = Join-Path $Root 'src\drivers\audio\hda.ghl'
if (-not (Test-Path -LiteralPath $HdaModule)) {
    throw "Missing HDA class driver module: $HdaModule"
}
$HdaOut = Join-Path ([System.IO.Path]::GetTempPath()) ('hda-' + [System.Guid]::NewGuid().ToString('N') + '.asm')
& python $Compiler $HdaModule -o $HdaOut -L $LibDir --target driver
if ($LASTEXITCODE -ne 0) {
    throw 'HDA audio class driver failed to compile (--target driver; G1 ambient-authority gate).'
}
if (Test-Path -LiteralPath $HdaOut) { Remove-Item -LiteralPath $HdaOut -Force }

Write-Host '[ghl-security] === Track-8 Rung 2/3 device drivers compile broker-only (--target driver) ===' -ForegroundColor Cyan
$Track8Drivers = @(
    (Join-Path $Root 'src\drivers\acpi_ec\battery.ghl'),   # Rung 2: EC battery, PIO-only
    (Join-Path $Root 'src\drivers\net\rtl8156.ghl')        # Rung 3: USB NIC, DMA descriptor rings
)
foreach ($drvModule in $Track8Drivers) {
    if (-not (Test-Path -LiteralPath $drvModule)) {
        throw "Missing Track-8 driver module: $drvModule"
    }
    $drvOut = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFileNameWithoutExtension($drvModule) + '-' + [System.Guid]::NewGuid().ToString('N') + '.asm')
    & python $Compiler $drvModule -o $drvOut -L $LibDir --target driver
    if ($LASTEXITCODE -ne 0) {
        throw "Track-8 driver failed to compile (--target driver; G1 ambient-authority gate): $drvModule"
    }
    if (Test-Path -LiteralPath $drvOut) { Remove-Item -LiteralPath $drvOut -Force }
}

Write-Host '[ghl-security] === Track-5 monitor-HAL detect/select/second-stage/IOMMU (real GHL math) ===' -ForegroundColor Cyan
$MonHalEval = Join-Path $Root 'scripts\test\eval_mon_hal.py'
if (-not (Test-Path -LiteralPath $MonHalEval)) {
    throw "Missing Track-5 monitor-HAL eval: $MonHalEval"
}
& python $MonHalEval
if ($LASTEXITCODE -ne 0) {
    throw 'Track-5 monitor-HAL model failed (detect, select+fallback, second-stage W^X/carve-out, or IOMMU DMA-confinement math).'
}

Write-Host '[ghl-security] === Track-5 G1 Intel VT-x kernel-as-guest VMXON/VMCS capture (real GHL math) ===' -ForegroundColor Cyan
$MonHalVmxEval = Join-Path $Root 'scripts\test\eval_mon_hal_vmx.py'
if (-not (Test-Path -LiteralPath $MonHalVmxEval)) {
    throw "Missing Track-5 VT-x VMXON/VMCS eval: $MonHalVmxEval"
}
& python $MonHalVmxEval
if ($LASTEXITCODE -ne 0) {
    throw 'Track-5 G1 VT-x model failed (VMXON-region/VMCS-header math, VMCS field encoding, CR0/CR4 fixed-bit legality, or kernel-as-guest capture invariant).'
}

Write-Host '[ghl-security] === Track-5 G1 REAL VT-x back-end compiles (kernel_vmx intrinsics) ===' -ForegroundColor Cyan
# The back-end emits real VMXON/VMCS/VMLAUNCH; VMX #UDs on TCG so it is NOT run
# here (verified tested-accel per scripts/test/run_vmx_accel.md). This guard
# proves the module + the new kernel_vmx/sgdt/sidt/str intrinsics keep compiling
# in kernel emit mode, so the privileged path can never silently rot.
$VmxBackend = Join-Path $Root 'src\kernel\grithlk\mon_hal_vmx_backend.ghl'
if (-not (Test-Path -LiteralPath $VmxBackend)) {
    throw "Missing Track-5 VT-x back-end: $VmxBackend"
}
$VmxBeOut = Join-Path ([System.IO.Path]::GetTempPath()) ('mon_hal_vmx_backend-' + [System.Guid]::NewGuid().ToString('N') + '.asm')
& python $Compiler $VmxBackend -o $VmxBeOut -L $LibDir --target kernel
if ($LASTEXITCODE -ne 0) {
    throw 'Track-5 G1 REAL VT-x back-end failed to compile (--target kernel; kernel_vmx intrinsics).'
}
if (Test-Path -LiteralPath $VmxBeOut) { Remove-Item -LiteralPath $VmxBeOut -Force }

Write-Host '[ghl-security] === No private QRNG bytes in release artifacts ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $NoShippedSecretsTest
if ($LASTEXITCODE -ne 0) {
    throw 'No-shipped-secrets scanner test failed.'
}

Write-Host '[ghl-security] PASS' -ForegroundColor Green
