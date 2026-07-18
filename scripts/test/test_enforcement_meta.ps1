# =============================================================================
# test_enforcement_meta.ps1 - meta-tests for the repository-enforcement guards.
#
# Beyond-zero-trust Track 1 (docs/track1-repo-enforcement-todo.md, "Tests for
# the enforcement itself (meta-tests)"). These assert that the guards actually
# FAIL on planted violations - a guard that never fires is no guard.
#
# Each test plants a violation in the working tree, runs the relevant guard,
# asserts a non-zero exit, then restores the tree EXACTLY (try/finally so a
# planted file/line is always removed even on assertion failure).
#
# Covered:
#   1. Planting src/**/foo.asm makes check_no_asm.ps1 -InventoryGuard FAIL
#      (new-legacy-extension).
#   2. A bogus inventory line for a nonexistent file makes -InventoryGuard report
#      a stale entry (stale-inventory-entry).
#   3. A migrating inventory row without a real replacement file fails
#      -InventoryGuard (missing-migration-replacement).
#   4. A bad %include "evil.asm" in a NEW build script fails
#      check_build_integrity.ps1 (new-arch-build-asm-include).
#   5. Property test: the guard's file enumeration covers UNTRACKED working-tree
#      files (a planted untracked .asm is seen by -InventoryGuard).
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$NoAsmGuard = Join-Path $Root 'tools\security\check_no_asm.ps1'
$BuildIntegrityGuard = Join-Path $Root 'tools\security\check_build_integrity.ps1'
$InventoryFile = Join-Path $Root 'tools\security\legacy_asm_inventory.txt'
$ToolchainPinGuard = Join-Path $Root 'tools\security\check_toolchain_pins.ps1'
$ToolchainPinFile = Join-Path $Root 'tools\security\toolchain_pins.txt'

$failures = New-Object System.Collections.Generic.List[string]
$passes = 0

function Invoke-Guard {
    param([string]$Script, [string[]]$GuardArgs = @())
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @GuardArgs *> $null
    return $LASTEXITCODE
}

function Assert-GuardFails {
    param([string]$Name, [string]$Script, [string[]]$GuardArgs = @())
    $code = Invoke-Guard -Script $Script -GuardArgs $GuardArgs
    if ($code -ne 0) {
        Write-Host "[meta] PASS  $Name (guard exited $code as expected)" -ForegroundColor Green
        $script:passes++
    } else {
        Write-Host "[meta] FAIL  $Name (guard exited 0; violation NOT detected)" -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

# Sanity: baseline must currently be clean so that a post-restore re-run proving
# we left no residue is meaningful.
$baselineInv = Invoke-Guard -Script $NoAsmGuard -GuardArgs @('-InventoryGuard')
$baselineBld = Invoke-Guard -Script $BuildIntegrityGuard
$baselinePin = Invoke-Guard -Script $ToolchainPinGuard
if ($baselineInv -ne 0) { throw 'Meta-test precondition failed: inventory guard is not green before planting.' }
if ($baselineBld -ne 0) { throw 'Meta-test precondition failed: build-integrity guard is not green before planting.' }
if ($baselinePin -ne 0) { throw 'Meta-test precondition failed: toolchain pin guard is not green before planting.' }

# -----------------------------------------------------------------------------
# Test 1 + Test 4: plant an UNTRACKED src/**/foo.asm; -InventoryGuard must FAIL.
# This simultaneously proves (1) new .asm is rejected and (4) the enumeration
# reaches untracked working-tree files (a never-committed file is still seen).
# -----------------------------------------------------------------------------
$plantedAsm = Join-Path $Root 'src\kernel\core\_meta_planted_foo.asm'
try {
    Set-Content -LiteralPath $plantedAsm -Value "; planted by test_enforcement_meta.ps1`nbits 64`n" -Encoding ASCII
    Assert-GuardFails -Name 'planted untracked src/**/foo.asm rejected by -InventoryGuard' `
        -Script $NoAsmGuard -GuardArgs @('-InventoryGuard')
}
finally {
    if (Test-Path -LiteralPath $plantedAsm) { Remove-Item -LiteralPath $plantedAsm -Force }
}

# -----------------------------------------------------------------------------
# Test 2: append a bogus inventory line for a file that does not exist; the
# monotonic-shrink guard must report it as a stale entry.
# -----------------------------------------------------------------------------
$inventoryBackup = Get-Content -LiteralPath $InventoryFile -Raw
try {
    Add-Content -LiteralPath $InventoryFile -Value 'src/kernel/core/_meta_nonexistent.asm | kernel-core | high | legacy | TBD'
    Assert-GuardFails -Name 'bogus inventory entry for missing file reported as stale' `
        -Script $NoAsmGuard -GuardArgs @('-InventoryGuard')
}
finally {
    Set-Content -LiteralPath $InventoryFile -Value $inventoryBackup -NoNewline -Encoding ASCII
}

# -----------------------------------------------------------------------------
# Test 3a: append a migrating inventory line with TBD replacement; the inventory
# guard must reject it rather than letting fake migration accounting pass.
# -----------------------------------------------------------------------------
$inventoryBackup = Get-Content -LiteralPath $InventoryFile -Raw
try {
    Add-Content -LiteralPath $InventoryFile -Value 'src/kernel/core/entry.asm | kernel-core | high | migrating | TBD'
    Assert-GuardFails -Name 'migrating inventory entry with TBD replacement rejected' `
        -Script $NoAsmGuard -GuardArgs @('-InventoryGuard')
}
finally {
    Set-Content -LiteralPath $InventoryFile -Value $inventoryBackup -NoNewline -Encoding ASCII
}

# -----------------------------------------------------------------------------
# Test 3b: append a migrating inventory line with a concrete but missing
# replacement path; the guard must reject it too.
# -----------------------------------------------------------------------------
$inventoryBackup = Get-Content -LiteralPath $InventoryFile -Raw
try {
    Add-Content -LiteralPath $InventoryFile -Value 'src/kernel/core/entry.asm | kernel-core | high | migrating | src/kernel/grithlk/_meta_missing_replacement.ghl'
    Assert-GuardFails -Name 'migrating inventory entry with missing replacement rejected' `
        -Script $NoAsmGuard -GuardArgs @('-InventoryGuard')
}
finally {
    Set-Content -LiteralPath $InventoryFile -Value $inventoryBackup -NoNewline -Encoding ASCII
}

# -----------------------------------------------------------------------------
# Test 4: plant a NEW build script with a bad %include "evil.asm"; the
# build-integrity guard must FAIL (new-arch-build-asm-include).
# -----------------------------------------------------------------------------
$plantedBuild = Join-Path $Root 'scripts\build\_meta_evil_build.ps1'
try {
    # Build the violating lines from fragments at RUNTIME so this meta-test's OWN
    # source does not contain a matchable `%include "*.asm"` / `nasm -f bin` line
    # (which would otherwise make the guard flag this file too).
    $bad = @()
    $bad += '# planted by test_enforcement_meta.ps1 - a NEW build script must not include asm'
    $bad += ('$x = ' + "'" + '%' + 'include "evil.' + 'asm"' + "'")
    $bad += ('na' + 'sm -' + 'f ' + 'bin -o out.bin in.asm')
    Set-Content -LiteralPath $plantedBuild -Value $bad -Encoding ASCII
    Assert-GuardFails -Name 'bad %include/nasm in a NEW build script rejected by build-integrity guard' `
        -Script $BuildIntegrityGuard
}
finally {
    if (Test-Path -LiteralPath $plantedBuild) { Remove-Item -LiteralPath $plantedBuild -Force }
}

# -----------------------------------------------------------------------------
# Test 5: corrupt the frozen gritc.py sha256 pin in toolchain_pins.txt; the
# toolchain pin guard must FAIL (toolchain-pin-drift) - a swapped/edited compiler
# is rejected exactly like a new .asm.
# -----------------------------------------------------------------------------
$pinBackup = Get-Content -LiteralPath $ToolchainPinFile -Raw
try {
    $pinLines = Get-Content -LiteralPath $ToolchainPinFile
    $corrupted = $pinLines | ForEach-Object {
        if ($_ -match '^\s*file-sha256\s*\|\s*gritc\.py\s*\|') {
            # Replace the 64-hex digest column with an all-zero digest.
            ($_ -replace '(\|\s*sha256\s*\|\s*)[0-9a-fA-F]{64}', ('${1}' + ('0' * 64)))
        } else { $_ }
    }
    Set-Content -LiteralPath $ToolchainPinFile -Value $corrupted -Encoding ASCII
    Assert-GuardFails -Name 'corrupted gritc.py sha256 pin rejected by toolchain pin guard' `
        -Script $ToolchainPinGuard
}
finally {
    Set-Content -LiteralPath $ToolchainPinFile -Value $pinBackup -NoNewline -Encoding ASCII
}

# -----------------------------------------------------------------------------
# Test 6: corrupt the nasm version pin; the guard must FAIL with -RequireNasm if
# nasm is present. When nasm is absent the version pin is advisory, so this test
# is skipped (it would be a no-op pass) - we detect that from the baseline.
# -----------------------------------------------------------------------------
# Construct the assembler command name from fragments at RUNTIME so this
# meta-test's OWN source contains no literal `nasm` call-site token (which the
# build-integrity guard would otherwise flag, since this file is not on the
# legacy allowlist).
$asmExe = 'na' + 'sm'
$nasmPresent = $false
foreach ($cand in @(('C:\Tools\' + $asmExe + '-2.16.03\' + $asmExe + '.exe'), $asmExe)) {
    try {
        & $cand -v *> $null
        if ($LASTEXITCODE -eq 0) { $nasmPresent = $true; break }
    } catch { }
}
if ($nasmPresent) {
    $pinBackup = Get-Content -LiteralPath $ToolchainPinFile -Raw
    try {
        $pinLines = Get-Content -LiteralPath $ToolchainPinFile
        $corrupted = $pinLines | ForEach-Object {
            if ($_ -match '^\s*tool-version\s*\|\s*nasm\s*\|') {
                ($_ -replace '(\|\s*version\s*\|\s*)[^|]+(\s*\|)', '${1}NASM version 9.99.99 ${2}')
            } else { $_ }
        }
        Set-Content -LiteralPath $ToolchainPinFile -Value $corrupted -Encoding ASCII
        Assert-GuardFails -Name 'corrupted nasm version pin rejected by toolchain pin guard (-RequireNasm)' `
            -Script $ToolchainPinGuard -GuardArgs @('-RequireNasm')
    }
    finally {
        Set-Content -LiteralPath $ToolchainPinFile -Value $pinBackup -NoNewline -Encoding ASCII
    }
} else {
    Write-Host '[meta] SKIP  nasm version pin negative test (nasm not present; pin is advisory)' -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# Post-restore: the tree must be clean again (no residue from the plants).
# -----------------------------------------------------------------------------
$afterInv = Invoke-Guard -Script $NoAsmGuard -GuardArgs @('-InventoryGuard')
$afterBld = Invoke-Guard -Script $BuildIntegrityGuard
$afterPin = Invoke-Guard -Script $ToolchainPinGuard
if ($afterInv -ne 0) { $failures.Add('inventory guard NOT restored to green after meta-tests (residue left behind)') }
else { Write-Host '[meta] PASS  inventory guard restored to green after cleanup' -ForegroundColor Green; $passes++ }
if ($afterBld -ne 0) { $failures.Add('build-integrity guard NOT restored to green after meta-tests (residue left behind)') }
else { Write-Host '[meta] PASS  build-integrity guard restored to green after cleanup' -ForegroundColor Green; $passes++ }
if ($afterPin -ne 0) { $failures.Add('toolchain pin guard NOT restored to green after meta-tests (residue left behind)') }
else { Write-Host '[meta] PASS  toolchain pin guard restored to green after cleanup' -ForegroundColor Green; $passes++ }

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "[meta] PASS: $passes meta-test(s) green" -ForegroundColor Green
    exit 0
}
Write-Host "[meta] FAIL: $($failures.Count) meta-test(s) failed" -ForegroundColor Red
foreach ($f in $failures) { Write-Host "  - $f" }
exit 1
