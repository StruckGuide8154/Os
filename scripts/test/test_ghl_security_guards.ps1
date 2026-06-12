$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

$NoAsmGuard = Join-Path $Root 'tools\security\check_no_asm.ps1'
$PrivacyGuard = Join-Path $Root 'tools\security\check_release_privacy.ps1'
$BuildIntegrityGuard = Join-Path $Root 'tools\security\check_build_integrity.ps1'
$PresubmitGuard = Join-Path $Root 'tools\security\check_ghl_presubmit.ps1'
$FixtureGuard = Join-Path $Root 'scripts\test\test_ghl_security_fixtures.ps1'
$InvariantGuard = Join-Path $Root 'scripts\test\test_ghl_invariants.ps1'
$MetaTest = Join-Path $Root 'scripts\test\test_enforcement_meta.ps1'
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

Write-Host '[ghl-security] PASS' -ForegroundColor Green
