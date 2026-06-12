<#
.SYNOPSIS
    Dirty-output guard: fails if a new-architecture build/test run leaks stray
    assembly (.asm/.inc/.s) into watched locations (build/, dist/, or active
    source paths under src/).

.DESCRIPTION
    Part of the Track 1 "P0 - CI surfacing" enforcement
    (docs/track1-repo-enforcement-todo.md). The new (GHL/GritHLK) trusted path
    must not regenerate raw assembly into watched, tracked locations. This guard
    detects such leakage in one of two modes:

      -Snapshot <file>   Capture the current set of watched .asm/.inc/.s files to
                         a JSON snapshot. Run this BEFORE the build/test command.

      -Compare <file>    Re-scan after the build/test command and FAIL if any
                         watched .asm/.inc/.s file appears that was not in the
                         snapshot. Run this AFTER the command.

    With neither switch (default), it falls back to a git-status check: it FAILS
    on any *untracked* .asm/.inc/.s file under the watched prefixes. This is the
    cheap CI default - a clean tree plus this check proves the run added no stray
    assembly to watched paths.

    Watched prefixes: build, dist, src.

.NOTES
    Owned by the CI-surfacing track. Does not modify any guard *rule* scripts.
#>
param(
    [string]$Snapshot,
    [string]$Compare,
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

function Get-RepoPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return ($fullPath.Substring($rootPath.Length).TrimStart('\', '/') -replace '\\', '/')
}

function Test-UnderPrefix {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Prefixes
    )
    foreach ($prefix in $Prefixes) {
        $normalized = $prefix.TrimEnd('/')
        if ($Path -eq $normalized -or $Path.StartsWith("$normalized/")) {
            return $true
        }
    }
    return $false
}

$WatchedPrefixes = @('build', 'dist', 'src')
$WatchedExtensions = @('.asm', '.inc', '.s')

if ($RepoRoot) {
    $root = [System.IO.Path]::GetFullPath($RepoRoot)
} else {
    $root = Get-RepoRoot
}

# Enumerate every watched .asm/.inc/.s file currently on disk (tracked or not).
function Get-WatchedAsmFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($prefix in $WatchedPrefixes) {
        $base = Join-Path $Root $prefix
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $ext = $_.Extension.ToLowerInvariant()
            if ($ext -in $WatchedExtensions) {
                [void]$set.Add((Get-RepoPath -Root $Root -Path $_.FullName))
            }
        }
    }
    return $set
}

if ($Snapshot) {
    $files = @(Get-WatchedAsmFiles -Root $root)
    $dir = Split-Path -Path $Snapshot -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    ($files | ConvertTo-Json -Compress) | Set-Content -LiteralPath $Snapshot -Encoding utf8
    Write-Host "[dirty-output] snapshot: $($files.Count) watched .asm/.inc/.s file(s) -> $Snapshot"
    exit 0
}

if ($Compare) {
    if (-not (Test-Path -LiteralPath $Compare)) {
        Write-Host "[dirty-output] FAIL: snapshot file not found: $Compare"
        exit 1
    }
    $raw = Get-Content -LiteralPath $Compare -Raw
    $before = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($raw -and $raw.Trim().Length -gt 0) {
        # ConvertFrom-Json returns an Object[] for a JSON list. Assign to a
        # variable first so foreach unrolls it (piping the cmdlet output directly
        # passes the whole array as a single pipeline item).
        $parsed = ConvertFrom-Json $raw
        foreach ($p in $parsed) { [void]$before.Add([string]$p) }
    }
    $after = Get-WatchedAsmFiles -Root $root
    $new = @()
    foreach ($p in $after) {
        if (-not $before.Contains($p)) { $new += $p }
    }
    if ($new.Count -eq 0) {
        Write-Host "[dirty-output] PASS: no new watched .asm/.inc/.s appeared (before=$($before.Count), after=$($after.Count))"
        exit 0
    }
    Write-Host "[dirty-output] FAIL: $($new.Count) new watched .asm/.inc/.s file(s) appeared after the run:"
    foreach ($p in $new) { Write-Host "  + $p" }
    exit 1
}

# Default mode: untracked-file check via git status. A clean run leaves no
# untracked .asm/.inc/.s under the watched prefixes.
$gitOut = & git -C $root status --porcelain --untracked-files=all
$untracked = @()
foreach ($line in $gitOut) {
    if ($line.Length -lt 4) { continue }
    $code = $line.Substring(0, 2)
    $path = $line.Substring(3).Trim('"')
    if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
    $path = $path -replace '\\', '/'
    if ($code -ne '??') { continue }   # only brand-new untracked files
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -notin $WatchedExtensions) { continue }
    if (-not (Test-UnderPrefix -Path $path -Prefixes $WatchedPrefixes)) { continue }
    $untracked += $path
}

if ($untracked.Count -eq 0) {
    Write-Host "[dirty-output] PASS: no untracked .asm/.inc/.s under build/, dist/, or src/"
    exit 0
}

Write-Host "[dirty-output] FAIL: $($untracked.Count) untracked .asm/.inc/.s file(s) under watched paths:"
foreach ($p in $untracked) { Write-Host "  + $p" }
exit 1
