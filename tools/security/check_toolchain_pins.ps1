# =============================================================================
# check_toolchain_pins.ps1 - frozen-toolchain pin enforcement (Track 1, sec->10).
#
# Beyond-zero-trust Track 1 (docs/track1-repo-enforcement-todo.md, "Path to
# 10/10"): pin gritc.py (+ the host Ed25519 signer) by sha256 and nasm by
# version so a SWAPPED COMPILER is rejected exactly like a new .asm. The legacy
# inventory guards file extensions and the build graph; this guards the
# toolchain that produced them.
#
# Manifest: tools/security/toolchain_pins.txt
#   file-sha256 | id | sha256  | <digest>  | <repo-relative path>
#   tool-version| id | version | <token>   | <probe note>
#
# Rules (findings model + PASS/FAIL + exit code mirror check_no_asm.ps1):
#   [toolchain-pin-missing-manifest]  the manifest itself is absent.
#   [toolchain-pin-malformed]         a manifest line is not a 5-column record.
#   [toolchain-pin-missing-file]      a file-sha256 pin names a path that does
#                                     not exist.
#   [toolchain-pin-drift]             a pinned file's live sha256, or nasm's live
#                                     version token, differs from the frozen pin
#                                     -> a swapped/edited toolchain component.
#   [toolchain-pin-unknown-kind]      a record kind other than the two supported.
#
# -Update re-bakes the live values into the manifest (after an intentional,
# reviewed toolchain change). -RequireNasm makes an absent nasm a hard failure
# (default: nasm absence is advisory, so a pure-Python CI lane that never
# assembles still passes the gritc/ed25519 content pins).
# =============================================================================

param(
    [switch]$Update,
    [switch]$RequireNasm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $dir = (Get-Location).ProviderPath
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $parent = Split-Path -Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    throw 'Could not find repository root by walking up to a .git directory.'
}

function Get-FileSha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NasmVersionLine {
    # Returns the first line of `nasm -v`, or $null if nasm is not invokable.
    $candidates = @('C:\Tools\nasm-2.16.03\nasm.exe', 'nasm')
    foreach ($exe in $candidates) {
        try {
            $out = & $exe -v 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                return ([string]@($out)[0]).Trim()
            }
        } catch { }
    }
    return $null
}

$root = Get-RepoRoot
$manifestPath = Join-Path $root 'tools\security\toolchain_pins.txt'
$findings = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host '[bootstrap-host-scan] toolchain pin guard'
    Write-Host "Repo root: $root"
    Write-Host 'Result: FAIL (1 finding(s))'
    Write-Host '[toolchain-pin-missing-manifest] tools/security/toolchain_pins.txt'
    Write-Host '  Frozen toolchain manifest is missing.'
    exit 1
}

# Parse + (optionally) rewrite the manifest in place, preserving comments/blanks.
$rawLines = Get-Content -LiteralPath $manifestPath
$rewritten = New-Object System.Collections.Generic.List[string]
$lineNo = 0

foreach ($line in $rawLines) {
    $lineNo++
    $entry = $line.Trim()
    if ($entry.Length -eq 0 -or $entry.StartsWith('#')) {
        $rewritten.Add($line)
        continue
    }

    $cols = $entry.Split('|')
    if ($cols.Count -ne 5) {
        $findings.Add([pscustomobject]@{
            Rule = 'toolchain-pin-malformed'
            Location = "tools/security/toolchain_pins.txt:$lineNo"
            Text = 'Expected "kind | id | algo | value | path-or-note".'
        })
        $rewritten.Add($line)
        continue
    }

    $kind  = $cols[0].Trim()
    $id    = $cols[1].Trim()
    $algo  = $cols[2].Trim()
    $value = $cols[3].Trim()
    $note  = $cols[4].Trim()

    switch ($kind) {
        'file-sha256' {
            $filePath = Join-Path $root ($note -replace '/', '\')
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'toolchain-pin-missing-file'
                    Location = "tools/security/toolchain_pins.txt:$lineNo"
                    Text = "Pinned file '$note' ($id) does not exist."
                })
                $rewritten.Add($line)
                break
            }
            $live = Get-FileSha256Lower -Path $filePath
            if ($Update) {
                $rewritten.Add("file-sha256 | $id | sha256 | $live | $note")
            } else {
                if ($live -ne $value.ToLowerInvariant()) {
                    $findings.Add([pscustomobject]@{
                        Rule = 'toolchain-pin-drift'
                        Location = "tools/security/toolchain_pins.txt:$lineNo"
                        Text = "$id sha256 drift: pinned $value, live $live ($note). A swapped/edited toolchain component."
                    })
                }
                $rewritten.Add($line)
            }
        }
        'tool-version' {
            if ($id -ne 'nasm') {
                # Only nasm is modeled as an external version pin today.
                $findings.Add([pscustomobject]@{
                    Rule = 'toolchain-pin-unknown-kind'
                    Location = "tools/security/toolchain_pins.txt:$lineNo"
                    Text = "tool-version pin for unsupported tool '$id'."
                })
                $rewritten.Add($line)
                break
            }
            $liveVer = Get-NasmVersionLine
            if ($null -eq $liveVer) {
                if ($RequireNasm) {
                    $findings.Add([pscustomobject]@{
                        Rule = 'toolchain-pin-drift'
                        Location = "tools/security/toolchain_pins.txt:$lineNo"
                        Text = 'nasm is not invokable but -RequireNasm was set.'
                    })
                } else {
                    Write-Host "[toolchain-pin] nasm not present - version pin advisory (skipped). Pass -RequireNasm to harden." -ForegroundColor Yellow
                }
                $rewritten.Add($line)
                break
            }
            if ($Update) {
                $rewritten.Add("tool-version | nasm | version | $liveVer | $note")
            } else {
                # The pinned token must be a prefix of (or equal to) the live
                # first line, so "NASM version 2.16.03" matches the full
                # "NASM version 2.16.03 compiled on ..." banner.
                if (-not $liveVer.StartsWith($value)) {
                    $findings.Add([pscustomobject]@{
                        Rule = 'toolchain-pin-drift'
                        Location = "tools/security/toolchain_pins.txt:$lineNo"
                        Text = "nasm version drift: pinned '$value', live '$liveVer'."
                    })
                }
                $rewritten.Add($line)
            }
        }
        default {
            $findings.Add([pscustomobject]@{
                Rule = 'toolchain-pin-unknown-kind'
                Location = "tools/security/toolchain_pins.txt:$lineNo"
                Text = "Unknown pin kind '$kind'."
            })
            $rewritten.Add($line)
        }
    }
}

if ($Update) {
    Set-Content -LiteralPath $manifestPath -Value $rewritten -Encoding ASCII
    Write-Host "[toolchain-pin] Re-baked pins into tools/security/toolchain_pins.txt" -ForegroundColor Green
    exit 0
}

Write-Host '[bootstrap-host-scan] toolchain pin guard'
Write-Host "Repo root: $root"

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
