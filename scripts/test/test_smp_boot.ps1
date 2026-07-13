param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$LogPath = Join-Path $Root 'build\cache32_serial.log'

Remove-Item -Path $LogPath -Force -ErrorAction SilentlyContinue
$cacheArgs = @()
if ($SkipBuild) { $cacheArgs += '-SkipBuild' }
$cacheArgs += '-SkipBenchmark'
powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_cache32_boot.ps1') @cacheArgs
if ($LASTEXITCODE -ne 0) {
    throw "Cache32Max boot log refresh failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path $LogPath)) {
    throw 'Cache32Max boot log refresh did not create cache32_serial.log.'
}

$serial = Get-Content -Path $LogPath -Raw
if ($serial -notlike '*SMP:*') {
    throw 'Missing SMP serial marker.'
}

$matches = [regex]::Matches($serial, 'SMP:([0-9A-F]{16})/([0-9A-F]{16})/([0-9A-F]{16})/([0-9A-F]{16})/([0-9A-F]{16})')
if ($matches.Count -eq 0) {
    throw 'Missing extended SMP counters.'
}

$last = $matches[$matches.Count - 1]
$detected = [Convert]::ToInt64($last.Groups[1].Value, 16)
$target = [Convert]::ToInt64($last.Groups[2].Value, 16)
$started = [Convert]::ToInt64($last.Groups[3].Value, 16)
$alive = [Convert]::ToInt64($last.Groups[4].Value, 16)

if ($target -gt 1 -and ($started -le 1 -or $alive -le 1)) {
    throw "AP startup did not start QEMU APs: target=$target started=$started alive=$alive."
}

# Per-core IA32_PAT uniformity (framebuffer Write-Combining safety). Every core
# that came up must have programmed the canonical PAT where slot 1 = WC, so the
# FB leaf PTE patched by fbperf_wc_activate (PAT index 1) is interpreted as WC
# on every core - not just the BSP. A divergent PAT on an AP that runs the FB
# blit job re-introduces the aliased-memory-type tearing this guards against.
$CanonicalPat = '0007010600070106'
$patLines = [regex]::Matches($serial, 'APAT:([0-9A-F]{16})/([0-9A-F]{16})')
if ($patLines.Count -eq 0) {
    throw 'Missing per-core APAT markers (perfdiag_print_ap_pat did not run).'
}
foreach ($m in $patLines) {
    $coreIdx = [Convert]::ToInt64($m.Groups[1].Value, 16)
    $pat = $m.Groups[2].Value
    if ($pat -ne $CanonicalPat) {
        throw "Core $coreIdx has non-canonical IA32_PAT=$pat (expected $CanonicalPat); framebuffer WC would alias memory types across cores."
    }
}
# At least the started cores must each have emitted a PAT line.
if ($started -gt 1 -and $patLines.Count -lt $started) {
    throw "Only $($patLines.Count) cores reported PAT but $started started; some AP did not record its PAT."
}
Write-Host "[smp] per-core PAT uniform across $($patLines.Count) core(s): $CanonicalPat" -ForegroundColor Green

Write-Host '[smp] PASS' -ForegroundColor Green
