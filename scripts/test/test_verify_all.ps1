$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [switch]$RequireCleanOutput
    )

    Write-Host "[verify] $Name" -ForegroundColor Yellow
    $output = & $Action 2>&1
    if ($output) {
        $output | Out-Host
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
    if ($RequireCleanOutput) {
        $joined = ($output | Out-String)
        if ($joined -match '(?im)\bwarning:|\berror:') {
            throw "$Name emitted assembler warnings or errors."
        }
    }
    Write-Host "[verify] $Name OK" -ForegroundColor Green
}

Invoke-Step 'Source guards' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_source_guards.ps1')
}

Invoke-Step 'Installable driver framework' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_driver_framework.ps1')
}

Invoke-Step 'XML/SVG contracts' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\check_xml_svg_contracts.ps1')
}

Invoke-Step 'GritHL XML/SVG fixtures' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_ghl_fixtures.ps1')
}

Invoke-Step 'Generated source map' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\generate_source_map.ps1')
}

Invoke-Step 'Complexity dashboard' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\complexity_dashboard.ps1')
}

Invoke-Step 'Invariant registry' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\check_invariants.ps1')
}

Invoke-Step 'Docs references' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\check_docs.ps1')
}

Invoke-Step 'Complexity thresholds' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\check_complexity_thresholds.ps1')
}

Invoke-Step 'Ownership registry' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\check_ownership.ps1')
}

Invoke-Step 'BIOS build' -RequireCleanOutput {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_bios.ps1')
}

Invoke-Step 'BIOS release build' -RequireCleanOutput {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_bios.ps1') -Release
}

Invoke-Step 'UEFI build' -RequireCleanOutput {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_uefi.ps1')
}

Invoke-Step 'UEFI release build' -RequireCleanOutput {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_uefi.ps1') -Release
}

Invoke-Step 'UEFI smoke boot' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_smoke_uefi.ps1')
}

Invoke-Step 'L3 app marker validation' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_l3_app_markers.ps1')
}

Invoke-Step 'Explorer marker validation' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_explorer_app_markers.ps1')
}

Invoke-Step 'Cache32Max BIOS boot' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_cache32_boot.ps1')
}

Invoke-Step 'SMP marker validation' {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\test\test_smp_boot.ps1')
}

Write-Host '[verify] PASS' -ForegroundColor Green
