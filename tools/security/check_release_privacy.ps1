param(
    [string]$Root,
    [switch]$IncludeDocs
)

$ErrorActionPreference = 'Stop'

function Find-RepoRoot {
    param([string]$Start)

    $dir = (Resolve-Path -Path $Start).Path
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir -or [string]::IsNullOrWhiteSpace($parent)) {
            throw "Unable to find repository root from $Start"
        }
        $dir = $parent
    }
}

function Convert-ToRelativePath {
    param(
        [string]$Base,
        [string]$Path
    )

    $baseFull = (Resolve-Path -LiteralPath $Base).Path.TrimEnd('\', '/')
    $pathFull = (Resolve-Path -LiteralPath $Path).Path
    if ($pathFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($baseFull.Length).TrimStart('\', '/')
    }
    return $pathFull
}

function Is-CommentOnlyLine {
    param(
        [string]$Line,
        [string]$Extension
    )

    $trimmed = $Line.TrimStart()
    if ($trimmed.Length -eq 0) { return $true }
    if ($Extension -in @('.ghl', '.py', '.ps1')) {
        return $trimmed.StartsWith('#')
    }
    return $false
}

function Is-PolicyDocLine {
    param([string]$Line)

    $trimmed = $Line.Trim()
    if ($trimmed.Length -eq 0) { return $true }
    if ($Line -match '^\s{2,}\S') { return $true }
    if ($trimmed -match '^(#|>|- \[[ xX]\]|-|\*)\s*') { return $true }
    return $trimmed -match '(?i)\b(policy|todo|roadmap|require|must|should|reject|block|allow|remove|compile out|diagnostic mode|release privacy|no private logging)\b'
}

function Add-ScanFile {
    param(
        [System.Collections.Generic.List[System.IO.FileInfo]]$Files,
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $file = Get-Item -LiteralPath $Path
        if (-not $Files.Contains($file)) { [void]$Files.Add($file) }
    }
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $RepoRoot = Find-RepoRoot -Start (Get-Location).Path
} else {
    $RepoRoot = Find-RepoRoot -Start $Root
}

$expectedSecurityModules = @(
    'compatibility_check.ghl',
    'no_asm_guard.ghl',
    'policy_graph_check.ghl',
    'release_privacy_guard.ghl',
    'revocation_check.ghl',
    'schema_canonical_check.ghl',
    'signed_artifact_check.ghl',
    'threshold_check.ghl'
)

$scanFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$findings = [System.Collections.Generic.List[object]]::new()

$securityModuleDir = Join-Path $RepoRoot 'src\tools\security'
if (-not (Test-Path -LiteralPath $securityModuleDir -PathType Container)) {
    [void]$findings.Add([pscustomobject]@{
        Rule = 'missing-security-module-dir'
        Path = 'src/tools/security'
        Line = 0
        Message = 'Expected GHL security policy module directory is missing.'
        Text = 'src/tools/security'
    })
} else {
    foreach ($moduleName in $expectedSecurityModules) {
        $modulePath = Join-Path $securityModuleDir $moduleName
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            [void]$findings.Add([pscustomobject]@{
                Rule = 'missing-security-module'
                Path = "src/tools/security/$moduleName"
                Line = 0
                Message = 'Expected GHL security policy module is missing.'
                Text = $moduleName
            })
        }
    }
}

$sourceRoots = @(
    'src\kernel\grithlk',
    'src\tools\security',
    'src\user\grithl'
)

foreach ($sourceRoot in $sourceRoots) {
    $full = Join-Path $RepoRoot $sourceRoot
    if (Test-Path -LiteralPath $full -PathType Container) {
        Get-ChildItem -LiteralPath $full -Recurse -File -Include '*.ghl', '*.py', '*.json', '*.toml', '*.yaml', '*.yml', '*.manifest', '*.txt' |
            ForEach-Object { [void]$scanFiles.Add($_) }
    }
}

foreach ($scriptRoot in @('scripts\build', 'scripts\test')) {
    $full = Join-Path $RepoRoot $scriptRoot
    if (Test-Path -LiteralPath $full -PathType Container) {
        Get-ChildItem -LiteralPath $full -Recurse -File -Include '*.ps1', '*.py', '*.json', '*.toml', '*.yaml', '*.yml', '*.manifest', '*.txt' |
            ForEach-Object { [void]$scanFiles.Add($_) }
    }
}

foreach ($manifestPath in @(
    'src\user\grithl\manifest.json',
    'src\kernel\grithlk\manifest.json',
    'src\user\grithl\compiler\manifest.json'
)) {
    Add-ScanFile -Files $scanFiles -Path (Join-Path $RepoRoot $manifestPath)
}

if ($IncludeDocs) {
    $docs = Join-Path $RepoRoot 'docs'
    if (Test-Path -LiteralPath $docs -PathType Container) {
        Get-ChildItem -LiteralPath $docs -File -Include '*ghl*.md', '*grithl*.md', '*security*.md', '*zero-trust*.md' |
            ForEach-Object { [void]$scanFiles.Add($_) }
    }
}

$scanFiles = $scanFiles |
    Sort-Object FullName -Unique |
    Where-Object {
        $_.FullName -notmatch '\\(\.git|\.claude|build|dist|deprecated|sandbox_shadow|__pycache__)\\'
    }

$privacyPatterns = @(
    @{
        Id = 'telemetry'
        Pattern = '(?i)\btelemetry\b'
        Message = 'Telemetry references must not enter the release trusted path.'
    },
    @{
        Id = 'analytics'
        Pattern = '(?i)\banalytics?\b'
        Message = 'Analytics collection is not allowed in release trusted-path code.'
    },
    @{
        Id = 'crash-upload'
        Pattern = '(?i)\b(crash\s*(upload|report|dump)|upload\s*crash|dump\s*upload)\b'
        Message = 'Crash upload/report/dump handling can leak memory or identifiers.'
    },
    @{
        Id = 'unique-install-id'
        Pattern = '(?i)\b(unique\s+(installation|install|device)\s+(id|identifier)|installation\s+identifier|install\s+identifier)\b'
        Message = 'Unique installation identifiers are release privacy hazards.'
    },
    @{
        Id = 'background-callback'
        Pattern = '(?i)\b(background\s+callback|callback\s+in\s+background|phone\s*home)\b'
        Message = 'Background callbacks must not be added to release builds.'
    },
    @{
        Id = 'raw-user-data'
        Pattern = '(?i)\b(raw\s+user\s+data|user\s+payload|message\s+payload|app\s+content|private\s+logging|payload\s+logging)\b'
        Message = 'Raw user data or payload logging is forbidden in release mode.'
    },
    @{
        Id = 'input-capture-log'
        Pattern = '(?i)\b(key(?:stroke)?\s+logging|log(?:ging)?\s+key(?:stroke)?s?|clipboard\s+logging|log(?:ging)?\s+clipboard|window[- ]title\s+logging|log(?:ging)?\s+window[- ]title)\b'
        Message = 'Keystroke, clipboard, and window-title logging are release privacy hazards.'
    },
    @{
        Id = 'filesystem-path-log'
        Pattern = '(?i)\b(filesystem\s+path\s+logging|file\s+path\s+logging|log(?:ging)?\s+file\s+paths?)\b'
        Message = 'Filesystem path logging must be explicitly diagnostic-scoped.'
    }
)

$releaseDefinePatterns = @(
    'ENABLE_DEBUG_SERIAL',
    'ENABLE_TRACE',
    'ENABLE_USER_DEBUG_SYSCALL',
    'ENABLE_L3_CALL_TRACE',
    'GRIT_BOOT_DIAG_LOG'
)

foreach ($file in $scanFiles) {
    $relative = Convert-ToRelativePath -Base $RepoRoot -Path $file.FullName
    $extension = $file.Extension.ToLowerInvariant()
    $isDoc = $extension -eq '.md'
    $lines = Get-Content -LiteralPath $file.FullName

    $releaseScopeDepth = 0
    $pendingReleaseIf = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineNumber = $i + 1
        $line = $lines[$i]
        $trimmed = $line.Trim()

        if ($isDoc -and (Is-PolicyDocLine -Line $line)) { continue }
        if (-not $isDoc -and (Is-CommentOnlyLine -Line $line -Extension $extension)) { continue }

        foreach ($rule in $privacyPatterns) {
            if ($line -match $rule.Pattern) {
                [void]$findings.Add([pscustomobject]@{
                    Rule = $rule.Id
                    Path = $relative
                    Line = $lineNumber
                    Message = $rule.Message
                    Text = $trimmed
                })
            }
        }

        if ($extension -eq '.ps1') {
            if ($line -match '(?i)\bif\s*\(\s*\$Release\s*\)') {
                $pendingReleaseIf = $true
            }

            if ($pendingReleaseIf -and $line.Contains('{')) {
                $releaseScopeDepth = 1
                $pendingReleaseIf = $false
            } elseif ($releaseScopeDepth -gt 0) {
                $releaseScopeDepth += ([regex]::Matches($line, '\{')).Count
                $releaseScopeDepth -= ([regex]::Matches($line, '\}')).Count
                if ($releaseScopeDepth -lt 0) { $releaseScopeDepth = 0 }
            }

            if ($releaseScopeDepth -gt 0) {
                foreach ($define in $releaseDefinePatterns) {
                    if ($line -match [regex]::Escape($define)) {
                        [void]$findings.Add([pscustomobject]@{
                            Rule = 'release-debug-define'
                            Path = $relative
                            Line = $lineNumber
                            Message = "Release branch references debug/diagnostic define $define."
                            Text = $trimmed
                        })
                    }
                }
            }

            if ($line -match '(?i)\$KernelDefines\s*\+=.*ENABLE_(DEBUG_SERIAL|TRACE|USER_DEBUG_SYSCALL|L3_CALL_TRACE)') {
                $nearby = ($lines[[Math]::Max(0, $i - 3)..$i] -join "`n")
                if ($nearby -notmatch '(?i)if\s*\(\s*-not\s+\$Release\s*\)') {
                    [void]$findings.Add([pscustomobject]@{
                        Rule = 'unguarded-debug-define'
                        Path = $relative
                        Line = $lineNumber
                        Message = 'Debug/trace define is not visibly guarded by -not $Release.'
                        Text = $trimmed
                    })
                }
            }
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host "[bootstrap-host-scan] release privacy guard" -ForegroundColor Cyan
    Write-Host "[release-privacy] FAIL: $($findings.Count) finding(s)" -ForegroundColor Red
    foreach ($finding in ($findings | Sort-Object Path, Line, Rule)) {
        if ($finding.Line -gt 0) {
            Write-Host ("{0}:{1}: [{2}] {3}" -f $finding.Path, $finding.Line, $finding.Rule, $finding.Message)
        } else {
            Write-Host ("{0}: [{1}] {2}" -f $finding.Path, $finding.Rule, $finding.Message)
        }
        Write-Host ("  {0}" -f $finding.Text)
    }
    exit 1
}

Write-Host "[bootstrap-host-scan] release privacy guard" -ForegroundColor Cyan
Write-Host "[release-privacy] PASS: scanned $($scanFiles.Count) file(s)"
