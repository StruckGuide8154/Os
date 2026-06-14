$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$LogPath = Join-Path $Root 'build\cache32_serial.log'

if (-not (Test-Path $LogPath)) {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_cache32_boot.ps1')
}

$serial = Get-Content -Path $LogPath -Raw
$markers = @('CPU:', 'CACHE:', 'FREQ:', 'BENCH:')
if ($serial -notlike '*BENCH:*') {
    Write-Host '[cpu-profile] Running benchmark command over serial...' -ForegroundColor Yellow
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_cache32_boot.ps1')
    $serial = Get-Content -Path $LogPath -Raw
}

$missing = @()
foreach ($marker in $markers) {
    if ($serial -notlike "*$marker*") { $missing += $marker }
}
if ($missing.Count -gt 0) {
    throw "Missing CPU profile markers: $($missing -join ', ')"
}
Write-Host '[cpu-profile] PASS' -ForegroundColor Green
