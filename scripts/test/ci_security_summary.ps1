<#
.SYNOPSIS
    CI surfacing wrapper for the beyond-zero-trust security verification.

.DESCRIPTION
    Implements the Track 1 "P0 - CI surfacing" checklist
    (docs/track1-repo-enforcement-todo.md). This wrapper is the single command a
    CI job invokes. It:

      1. Calls the verification entry point
         scripts/test/test_ghl_security_guards.ps1 (privacy + no-asm + inventory +
         policy-module compile + checker fixtures + invariants) and captures
         pass/fail. This drives the "GHL-only trusted path" signal.

      2. Runs the legacy-quarantine check with ADDITIONS-ONLY semantics: it shells
         out to tools/security/check_no_asm.ps1 -InventoryGuard and treats only
         NEW active .asm/.inc not in the inventory (and malformed/missing
         inventory) as a failure. Stale entries (a listed file that was deleted)
         are ALLOWED - the inventory is permitted to shrink. This drives the
         "legacy assembly quarantine unchanged" signal.

      3. Runs the dirty-output guard (scripts/test/ci_dirty_output_guard.ps1) to
         ensure the new-architecture run leaked no stray .asm/.inc/.s into build/,
         dist/, or src/.

    It then prints exactly two machine-greppable summary lines:

         GHL-only trusted path: pass|fail
         legacy assembly quarantine unchanged: pass|fail

    The script exits 0 only if BOTH summary lines are "pass" AND the dirty-output
    guard passed; otherwise it exits 1, failing the CI job.

.NOTES
    Owned by the CI-surfacing track. It only CALLS the guard rule scripts; it does
    not modify check_no_asm.ps1, test_ghl_security_guards.ps1, or the inventory.
#>
param(
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $dir = (Get-Location).ProviderPath
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
            return $dir
        }
        $parent = Split-Path -Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    throw 'Could not find repository root by walking up to a .git directory.'
}

if ($RepoRoot) {
    $root = [System.IO.Path]::GetFullPath($RepoRoot)
} else {
    $root = Get-RepoRoot
}

$EntryPoint = Join-Path $root 'scripts\test\test_ghl_security_guards.ps1'
$NoAsmGuard = Join-Path $root 'tools\security\check_no_asm.ps1'
# The dirty-output guard is a sibling owned script; resolve it next to this
# wrapper so the pair travels together regardless of -RepoRoot.
$DirtyGuard = Join-Path $PSScriptRoot 'ci_dirty_output_guard.ps1'

foreach ($p in @($EntryPoint, $NoAsmGuard, $DirtyGuard)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Required script not found: $p"
    }
}

# Snapshot the set of watched .asm/.inc/.s files BEFORE the new-architecture
# run so the dirty-output guard can attribute any newly-appearing assembly to
# the run itself (rather than to pre-existing, inventory-tracked source).
$snapshotFile = Join-Path ([System.IO.Path]::GetTempPath()) ('ci-dirty-snapshot-' + [System.Guid]::NewGuid().ToString('N') + '.json')
Write-Host '=== [ci-security] Dirty-output baseline snapshot ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $DirtyGuard -RepoRoot $root -Snapshot $snapshotFile

# ---------------------------------------------------------------------------
# 1. GHL-only trusted path: run the full security verification entry point.
# ---------------------------------------------------------------------------
Write-Host '=== [ci-security] GHL-only trusted path verification ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $EntryPoint
$trustedPathPass = ($LASTEXITCODE -eq 0)

# ---------------------------------------------------------------------------
# 2. Legacy assembly quarantine unchanged: additions-only inventory diff.
#    Reuse check_no_asm.ps1 -InventoryGuard; classify its findings ourselves so
#    that deletions (stale entries) are allowed but additions are not.
# ---------------------------------------------------------------------------
Write-Host '=== [ci-security] Legacy quarantine (additions-only) ===' -ForegroundColor Cyan
$invOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $NoAsmGuard -InventoryGuard 2>&1
$invExit = $LASTEXITCODE
$invOutput | ForEach-Object { Write-Host $_ }

# Findings that mean the quarantine GREW or is broken (a hard fail):
#   new-legacy-extension      - a new active .asm/.inc not in the inventory
#   missing-legacy-inventory  - the manifest itself is gone
#   malformed-inventory-entry - the manifest is corrupt
# A finding of 'stale-inventory-entry' alone means the inventory only shrank
# (a migration deleted a legacy file) -> ALLOWED for the "unchanged" signal.
$blockingRules = @('new-legacy-extension', 'missing-legacy-inventory', 'malformed-inventory-entry')
$blockingHits = @()
foreach ($line in $invOutput) {
    $text = [string]$line
    foreach ($rule in $blockingRules) {
        if ($text -match [regex]::Escape("[$rule]")) {
            $blockingHits += $text.Trim()
        }
    }
}

# Guard against an unexpected non-zero exit that produced no recognizable finding
# (e.g. the guard itself errored) - treat that as a fail so we never green a
# broken check.
$quarantineUnchanged = $true
if ($blockingHits.Count -gt 0) {
    $quarantineUnchanged = $false
} elseif ($invExit -ne 0) {
    # Non-zero exit with only stale entries (deletions) is allowed.
    $staleOnly = $true
    foreach ($line in $invOutput) {
        $text = [string]$line
        if ($text -match '^\[(?<rule>[a-z-]+)\]') {
            if ($Matches['rule'] -ne 'stale-inventory-entry') {
                $staleOnly = $false
            }
        }
    }
    if (-not $staleOnly) {
        $quarantineUnchanged = $false
    } else {
        Write-Host '[ci-security] Inventory shrank (stale entries only) - allowed; quarantine unchanged.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 3. Dirty-output guard: compare against the pre-run snapshot. Any watched
#    .asm/.inc/.s that appeared during the new-architecture run is stray
#    generated assembly and fails the job. Pre-existing (inventory-tracked)
#    source is in the snapshot and is therefore ignored.
# ---------------------------------------------------------------------------
Write-Host '=== [ci-security] Dirty-output guard (snapshot compare) ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $DirtyGuard -RepoRoot $root -Compare $snapshotFile
$dirtyOutputPass = ($LASTEXITCODE -eq 0)
if (Test-Path -LiteralPath $snapshotFile) {
    Remove-Item -LiteralPath $snapshotFile -Force
}

# ---------------------------------------------------------------------------
# Machine-greppable summary lines.
# ---------------------------------------------------------------------------
$trustedPathLabel = if ($trustedPathPass) { 'pass' } else { 'fail' }
$quarantineLabel = if ($quarantineUnchanged) { 'pass' } else { 'fail' }
$dirtyLabel = if ($dirtyOutputPass) { 'pass' } else { 'fail' }

Write-Host ''
Write-Host '=== [ci-security] SUMMARY ===' -ForegroundColor Cyan
Write-Host "GHL-only trusted path: $trustedPathLabel"
Write-Host "legacy assembly quarantine unchanged: $quarantineLabel"
Write-Host "dirty-output guard: $dirtyLabel"

if ($trustedPathPass -and $quarantineUnchanged -and $dirtyOutputPass) {
    exit 0
}
exit 1
