# ============================================================================
# test_userspace_drivers.ps1 - Track 8 enforcement guard (guarantee G2:
# "impossible to run a driver in the kernel").
#
# Two checks, both fail-closed:
#
#   1. FREEZE  - every `*.asm` under src/kernel/drivers/ must be on the frozen
#                inventory (tools/security/driver_inventory.txt). A NEW in-kernel
#                driver therefore cannot be added: it has no inventory line, so
#                the guard fails. New device code must be a ring-3 driver-host
#                process behind driver_host.ghl.
#
#   2. NO-DRIFT - every inventory line must still have a backing file, and the
#                in-kernel driver count must never EXCEED the inventory (shrink-
#                only). Migrating a driver = delete the .asm AND its line.
#
# This is the same shrink-only-quarantine pattern as the legacy .asm inventory,
# specialised to device drivers so the migration is monotonic and auditable.
#
#   -SelfTest : run the guard's NEGATIVE test - prove it FAILS on a planted new
#               in-kernel driver and on a stale inventory line (the doctrine:
#               every enforcement guard has a test that breaks it).
# ============================================================================
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'

# Core: evaluate the freeze + no-drift checks against a drivers dir and an
# inventory file. Returns the list of failure strings (empty = pass).
function Get-DriverGuardFailures {
    param([string]$DriversDir, [string]$InventoryFile)

    if (-not (Test-Path $InventoryFile)) {
        throw "driver_inventory.txt missing: $InventoryFile"
    }

    $frozen = @{}
    foreach ($line in Get-Content -Path $InventoryFile) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t.StartsWith('#')) { continue }
        $frozen[$t] = $true
    }

    $actual = @()
    if (Test-Path $DriversDir) {
        $actual = @(Get-ChildItem -Path $DriversDir -Filter '*.asm' | ForEach-Object { $_.BaseName })
    }

    $failures = @()

    # Check 1: FREEZE - no new in-kernel driver.
    foreach ($d in $actual) {
        if (-not $frozen.ContainsKey($d)) {
            $failures += "[new-in-kernel-driver] $d.asm is NOT on the frozen inventory. New device code must be a ring-3 driver-host process (docs/track8-userspace-drivers-todo.md), not an in-kernel driver."
        }
    }

    # Check 2a: NO-DRIFT - inventory lines must still back a file.
    $actualSet = @{}
    foreach ($d in $actual) { $actualSet[$d] = $true }
    foreach ($d in $frozen.Keys) {
        if (-not $actualSet.ContainsKey($d)) {
            $failures += "[stale-inventory-line] inventory lists '$d' but $d.asm does not exist. A migrated driver must be REMOVED from the inventory (it is shrink-only)."
        }
    }

    # Check 2b: shrink-only - count must never exceed the inventory.
    if ($actual.Count -gt $frozen.Count) {
        $failures += "[driver-count-grew] in-kernel driver count ($($actual.Count)) exceeds the frozen inventory ($($frozen.Count)). The in-kernel driver set may only shrink."
    }

    return $failures
}

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$DriversDir = Join-Path $Root 'src\kernel\drivers'
$InventoryFile = Join-Path $Root 'tools\security\driver_inventory.txt'

if ($SelfTest) {
    # Build a temp fixture mirroring the inventory, then prove each violation trips.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('drvguard-' + [System.Guid]::NewGuid().ToString('N'))
    $fxDrivers = Join-Path $tmp 'drivers'
    New-Item -ItemType Directory -Path $fxDrivers -Force | Out-Null
    $fxInv = Join-Path $tmp 'inventory.txt'
    try {
        # Inventory with two legit drivers; create matching files.
        Set-Content -Path $fxInv -Value @('# fixture', 'alpha', 'beta') -Encoding utf8
        New-Item -ItemType File -Path (Join-Path $fxDrivers 'alpha.asm') | Out-Null
        New-Item -ItemType File -Path (Join-Path $fxDrivers 'beta.asm') | Out-Null

        # (a) clean fixture must pass.
        $f = Get-DriverGuardFailures -DriversDir $fxDrivers -InventoryFile $fxInv
        if ($f.Count -ne 0) { throw "SelfTest: clean fixture should pass but reported: $($f -join '; ')" }

        # (b) plant a NEW in-kernel driver not on the inventory -> must fail.
        New-Item -ItemType File -Path (Join-Path $fxDrivers 'rogue.asm') | Out-Null
        $f = Get-DriverGuardFailures -DriversDir $fxDrivers -InventoryFile $fxInv
        if (-not ($f -match 'new-in-kernel-driver')) { throw "SelfTest: planting rogue.asm should trip [new-in-kernel-driver] but did not." }
        Remove-Item -Path (Join-Path $fxDrivers 'rogue.asm') -Force

        # (c) stale inventory line (file deleted) -> must fail.
        Remove-Item -Path (Join-Path $fxDrivers 'beta.asm') -Force
        $f = Get-DriverGuardFailures -DriversDir $fxDrivers -InventoryFile $fxInv
        if (-not ($f -match 'stale-inventory-line')) { throw "SelfTest: deleting beta.asm should trip [stale-inventory-line] but did not." }

        Write-Host "PASS: Track 8 G2 self-test - guard trips on new in-kernel driver AND stale inventory line." -ForegroundColor Green
        exit 0
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Recurse -Force }
    }
}

$failures = Get-DriverGuardFailures -DriversDir $DriversDir -InventoryFile $InventoryFile
if ($failures.Count -gt 0) {
    Write-Host "FAIL: Track 8 user-space-driver enforcement (G2)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  src/kernel/drivers/$_" -ForegroundColor Red }
    exit 1
}

$frozenCount = @(Get-Content -Path $InventoryFile | Where-Object { $_.Trim().Length -gt 0 -and -not $_.Trim().StartsWith('#') }).Count
Write-Host "PASS: Track 8 G2 - no new in-kernel drivers; inventory consistent ($frozenCount frozen, shrink-only)." -ForegroundColor Green
exit 0
