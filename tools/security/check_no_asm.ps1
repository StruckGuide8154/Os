param(
    [switch]$StrictExtensions,
    [switch]$InventoryGuard
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
        if ($parent -eq $dir) {
            break
        }
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

function Remove-NxhLineNoise {
    param([AllowEmptyString()][string]$Line)

    $result = New-Object System.Text.StringBuilder
    $inString = $false
    $quote = ''
    $escaped = $false

    foreach ($ch in $Line.ToCharArray()) {
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($ch -eq '\') {
                $escaped = $true
            } elseif ($ch -eq $quote) {
                $inString = $false
                $quote = ''
            }
            [void]$result.Append(' ')
            continue
        }

        if ($ch -eq '#') {
            break
        }

        if ($ch -eq '"' -or $ch -eq "'") {
            $inString = $true
            $quote = $ch
            [void]$result.Append(' ')
            continue
        }

        [void]$result.Append($ch)
    }

    return $result.ToString()
}

$root = Get-RepoRoot
$findings = New-Object System.Collections.Generic.List[object]

$securityModuleDir = Join-Path $root 'src\tools\security'
$expectedSecurityModules = @(
    'compatibility_check.ghl',
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

if (-not (Test-Path -LiteralPath $securityModuleDir -PathType Container)) {
    $findings.Add([pscustomobject]@{
        Rule = 'missing-security-module-dir'
        Location = 'src/tools/security'
        Text = 'Expected GHL security policy module directory is missing.'
    })
} else {
    foreach ($moduleName in $expectedSecurityModules) {
        $modulePath = Join-Path $securityModuleDir $moduleName
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            $findings.Add([pscustomobject]@{
                Rule = 'missing-security-module'
                Location = "src/tools/security/$moduleName"
                Text = 'Expected GHL security policy module is missing.'
            })
        }
    }
}

$ignoredPrefixes = @('.git', '.claude', 'sandbox_shadow', 'worktrees')
# Archival reference assembly that is NOT trusted-path source. `deprecated/` is
# the retired-subsystem archive; `docs/gpu-driver/reference-780M-asm` is the
# documentation-only reference copy of the retired AMD 780M iGPU assembly (moved
# out of deprecated/ into docs as a read-only reference). Both are archival, not
# active source, so a listed extension there is quarantined, never new work.
$quarantinePrefixes = @('build', 'dist', 'deprecated', 'docs/gpu-driver/reference-780M-asm')
$trustedNxhPrefixes = @(
    'src/boot/ghl',
    'src/kernel/grithlk',
    'src/tools/security',
    'src/user/grithl',
    'src/user/templates'
)
$roadmapPath = Join-Path $root 'docs\ghl-beyond-zero-trust-todo.md'

# Exclude git-ignored paths (generated/secret files such as tools/quantum/seed.inc)
# so the scan does not drift between a local working tree and a clean CI checkout.
$ignoredByGit = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
try {
    foreach ($g in (& git -C $root ls-files --others --ignored --exclude-standard 2>$null)) {
        if ($g) { [void]$ignoredByGit.Add(($g -replace '\\', '/')) }
    }
} catch { }

$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
    $repoPath = Get-RepoPath -Root $root -Path $_.FullName
    [pscustomobject]@{
        FullName = $_.FullName
        RepoPath = $repoPath
        Extension = $_.Extension.ToLowerInvariant()
    }
} | Where-Object {
    (-not (Test-UnderPrefix -Path $_.RepoPath -Prefixes $ignoredPrefixes)) -and
    (-not $ignoredByGit.Contains($_.RepoPath))
}

if ($StrictExtensions) {
    foreach ($file in $files) {
        if ($file.Extension -in @('.asm', '.inc') -and
            -not (Test-UnderPrefix -Path $file.RepoPath -Prefixes $quarantinePrefixes)) {
            $findings.Add([pscustomobject]@{
                Rule = 'strict-extension'
                Location = $file.RepoPath
                Text = 'Active .asm/.inc file outside deprecated/build/dist quarantine.'
            })
        }
    }
}

if ($InventoryGuard) {
    $inventoryPath = Join-Path $root 'tools\security\legacy_asm_inventory.txt'
    if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
        $findings.Add([pscustomobject]@{
            Rule = 'missing-legacy-inventory'
            Location = 'tools/security/legacy_asm_inventory.txt'
            Text = 'Legacy assembly quarantine inventory is missing.'
        })
    } else {
        $inventory = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $invLine = 0
        foreach ($line in Get-Content -LiteralPath $inventoryPath) {
            $invLine++
            $entry = $line.Trim()
            if ($entry.Length -eq 0 -or $entry.StartsWith('#')) { continue }
            # Structured record: path | subsystem | risk | status | replacement
            $cols = $entry.Split('|')
            if ($cols.Count -lt 5) {
                $findings.Add([pscustomobject]@{
                    Rule = 'malformed-inventory-entry'
                    Location = "tools/security/legacy_asm_inventory.txt:$invLine"
                    Text = 'Expected "path | subsystem | risk | status | replacement".'
                })
                continue
            }
            $path = ($cols[0].Trim() -replace '\\', '/')
            $risk = $cols[2].Trim()
            $status = $cols[3].Trim()
            $replacement = ($cols[4].Trim() -replace '\\', '/')
            if ($risk -notin @('high', 'medium', 'low')) {
                $findings.Add([pscustomobject]@{
                    Rule = 'invalid-inventory-risk'
                    Location = "tools/security/legacy_asm_inventory.txt:$invLine"
                    Text = "Expected risk high|medium|low, got '$risk'."
                })
            }
            if ($status -notin @('legacy', 'migrating')) {
                $findings.Add([pscustomobject]@{
                    Rule = 'invalid-inventory-status'
                    Location = "tools/security/legacy_asm_inventory.txt:$invLine"
                    Text = "Expected status legacy|migrating, got '$status'."
                })
            }
            if ($status -eq 'migrating') {
                if ($replacement -eq '' -or $replacement -eq 'TBD') {
                    $findings.Add([pscustomobject]@{
                        Rule = 'missing-migration-replacement'
                        Location = "tools/security/legacy_asm_inventory.txt:$invLine"
                        Text = 'Migrating inventory entries must name a concrete replacement file.'
                    })
                } else {
                    $replacementPath = Join-Path $root ($replacement -replace '/', '\')
                    if (-not (Test-Path -LiteralPath $replacementPath -PathType Leaf)) {
                        $findings.Add([pscustomobject]@{
                            Rule = 'missing-migration-replacement'
                            Location = "tools/security/legacy_asm_inventory.txt:$invLine"
                            Text = "Migrating replacement '$replacement' does not exist."
                        })
                    }
                }
            }
            [void]$inventory.Add($path)
        }

        # New legacy .asm/.inc outside the quarantine prefixes must be listed.
        foreach ($file in $files) {
            if ($file.Extension -notin @('.asm', '.inc')) { continue }
            if (Test-UnderPrefix -Path $file.RepoPath -Prefixes $quarantinePrefixes) { continue }
            if (-not $inventory.Contains($file.RepoPath)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'new-legacy-extension'
                    Location = $file.RepoPath
                    Text = 'New active .asm/.inc not in legacy inventory. New work must be GHL/GritHLK.'
                })
            }
        }

        # Inventory must shrink monotonically: entries that no longer exist on
        # disk are stale and must be pruned (a migration completed).
        $present = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $files) {
            if ($file.Extension -in @('.asm', '.inc')) { [void]$present.Add($file.RepoPath) }
        }
        foreach ($entry in $inventory) {
            if (-not $present.Contains($entry)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'stale-inventory-entry'
                    Location = $entry
                    Text = 'Inventory lists a legacy file that no longer exists. Prune this line.'
                })
            }
        }
    }
}

$inlineAsmPattern = [regex]'(?i)(^|[^A-Za-z0-9_])(__asm|inline\s+asm|asm\s*\{|asm)(?=$|[^A-Za-z0-9_])'

foreach ($file in $files) {
    if ($file.Extension -ne '.ghl') {
        continue
    }
    if (-not (Test-UnderPrefix -Path $file.RepoPath -Prefixes $trustedNxhPrefixes)) {
        continue
    }
    if (Test-UnderPrefix -Path $file.RepoPath -Prefixes $quarantinePrefixes) {
        continue
    }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber++
        $code = Remove-NxhLineNoise -Line $line
        if ($inlineAsmPattern.IsMatch($code)) {
            $findings.Add([pscustomobject]@{
                Rule = 'ghl-inline-asm'
                Location = "$($file.RepoPath):$lineNumber"
                Text = $line.Trim()
            })
        }
    }
}

if (Test-Path -LiteralPath $roadmapPath) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $roadmapPath) {
        $lineNumber++
        if ($line -match '(?i)(tools/security/[^`\s]*\.py|Python)') {
            $findings.Add([pscustomobject]@{
                Rule = 'roadmap-python-security-tooling'
                Location = "docs/ghl-beyond-zero-trust-todo.md:$lineNumber"
                Text = $line.Trim()
            })
        }
    }
}

Write-Host "[bootstrap-host-scan] GHL no-ASM guard"
Write-Host "Repo root: $root"
$modeLabel = if ($StrictExtensions) { 'strict extensions' } else { 'quarantine legacy extensions' }
if ($InventoryGuard) { $modeLabel += ' + inventory guard' }
Write-Host "Mode: $modeLabel"

if ($findings.Count -eq 0) {
    Write-Host 'Result: PASS'
    exit 0
}

Write-Host "Result: FAIL ($($findings.Count) finding(s))"
foreach ($finding in $findings) {
    Write-Host "[$($finding.Rule)] $($finding.Location)"
    Write-Host "  $($finding.Text)"
}

exit 1
