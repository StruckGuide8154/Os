# =============================================================================
# check_ghl_presubmit.ps1 - GHL/GritHLK source presubmit rules.
#
# Beyond-zero-trust Track 1 (docs/track1-repo-enforcement-todo.md, "P0 - finish
# repository enforcement"). Fail-closed, conservative (low false-positive)
# presubmit checks on the GHL trusted-path source surface.
#
# Rules:
#   [ghl-raw-emitter-string]  A `.ghl` source line (outside the compiler backend
#       allowlist) that, after comment/string stripping, is a raw NASM
#       instruction (a bare mnemonic + operand). Raw instruction-emitter strings
#       are legitimate ONLY inside the gritc.py backend; .ghl source must be
#       structured. (This complements check_no_asm.ps1's `asm{}`-escape rule:
#       this catches bare mnemonics that are not wrapped in an asm escape.)
#   [inc-public-api]  A new public API (a non-comment `global`/`%define`/EXPORT
#       symbol) exposed through a `.inc` include file. New public surface must be
#       GHL, not a legacy `.inc`. Scoped to files NOT already frozen in the
#       legacy inventory, so existing legacy `.inc` exports are not re-flagged.
#   [undocumented-intrinsic]  gritc.py registers a CPU instruction intrinsic whose
#       name is NOT in this guard's frozen documented-intrinsic allowlist. Adding
#       an intrinsic requires documenting it (= adding it to the allowlist here),
#       mirroring the legacy-inventory freeze pattern.
#   [missing-threat-note]  A security policy module (src/tools/security/*.ghl)
#       whose header comment block carries no threat/security reasoning.
#   [release-logging-in-security]  A serial/console logging SINK at release scope
#       (outside a `cfg "ENABLE_*" { }` debug-gated block) in a security/policy/
#       crypto GHL module - these must not log on the release trusted path.
#   [raw-user-data-in-log]  A log/trace format string that interpolates raw user
#       data (a `${user...}` / `$appdata` / "user input"/"payload" placeholder)
#       in a trusted-path module.
#
# Findings model + PASS/FAIL summary + exit code mirror check_no_asm.ps1.
# Runnable standalone; wired into scripts/test/test_ghl_security_guards.ps1.
# =============================================================================

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

function Get-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return ($fullPath.Substring($rootPath.Length).TrimStart('\', '/') -replace '\\', '/')
}

function Test-UnderPrefix {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Prefixes)
    foreach ($prefix in $Prefixes) {
        $normalized = $prefix.TrimEnd('/')
        if ($Path -eq $normalized -or $Path.StartsWith("$normalized/")) { return $true }
    }
    return $false
}

# Strip line comments and string literals from an .ghl line, leaving only code
# tokens (mirrors check_no_asm.ps1's Remove-NxhLineNoise so the two guards agree
# on what is "code").
function Remove-NxhLineNoise {
    param([AllowEmptyString()][string]$Line)
    $result = New-Object System.Text.StringBuilder
    $inString = $false; $quote = ''; $escaped = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq $quote) { $inString = $false; $quote = '' }
            [void]$result.Append(' '); continue
        }
        if ($ch -eq '#') { break }
        if ($ch -eq '"' -or $ch -eq "'") { $inString = $true; $quote = $ch; [void]$result.Append(' '); continue }
        [void]$result.Append($ch)
    }
    return $result.ToString()
}

$root = Get-RepoRoot
$findings = New-Object System.Collections.Generic.List[object]

$ignoredPrefixes = @('.git', '.claude', 'sandbox_shadow', 'build', 'dist', 'deprecated', 'docs/gpu-driver/reference-780M-asm', '__pycache__', 'worktrees')

# GHL trusted-path source roots (.ghl lives here). Mirrors check_no_asm.ps1.
$trustedNxhPrefixes = @(
    'src/boot/ghl',
    'src/kernel/grithlk',
    'src/tools/security',
    'src/user/grithl',
    'src/user/templates'
)

# Security / policy / crypto GHL modules subject to the strictest no-release-log
# rule. The src/tools/security policy kernels explicitly state the trusted rule
# set must contain no host-only/logging policy; crypto.ghl is the kernel crypto
# leaf. Scoped tight so legitimate debug helpers in general GHLK modules are not
# flagged.
$securityModulePrefixes = @(
    'src/tools/security',
    'src/kernel/grithlk/crypto.ghl',
    'src/kernel/grithlk/syscall_secure.ghl'
)

# The compiler backend - the ONLY place raw instruction-emitter strings are
# legitimate (per gritc.py top-of-file contract).
$backendAllowlist = @('src/user/grithl/compiler/gritc.py')

# -----------------------------------------------------------------------------
# Documented-intrinsic freeze. Every CPU-instruction intrinsic gritc.py registers
# in _NULLARY_INTRINSICS must appear here (= be documented/reviewed). A new
# intrinsic name not in this set fails [undocumented-intrinsic]; documenting it
# means adding it here. Frozen 2026-06-04 against gritc.py.
# -----------------------------------------------------------------------------
$documentedIntrinsics = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
@(
    'cli','sti','hlt','swapgs','sysretq','iretq','ud2','ret_naked',
    'lfence','mfence','sfence','pause','wbinvd','nop','smap_open','smap_close',
    'rdtsc','rdrand','read_cr0','read_cr2','read_cr3','read_cr4',
    # str_sel = STR (store TR selector); documented/reviewed Track-5 VMX
    # guest-capture primitive (gritc.py _NULLARY_INTRINSICS).
    'str_sel',
    'read_rsp','pop_val','read_flags'
) | ForEach-Object { [void]$documentedIntrinsics.Add($_) }

# -----------------------------------------------------------------------------
# Load the legacy inventory path set, so the inc-public-api rule does not
# re-flag legacy `.inc` files already frozen in the quarantine. New public API
# exposed via a `.inc` NOT in the inventory is the real hazard.
# -----------------------------------------------------------------------------
$inventoryPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$inventoryFile = Join-Path $root 'tools\security\legacy_asm_inventory.txt'
if (Test-Path -LiteralPath $inventoryFile -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $inventoryFile) {
        $entry = $line.Trim()
        if ($entry.Length -eq 0 -or $entry.StartsWith('#')) { continue }
        $cols = $entry.Split('|')
        if ($cols.Count -lt 1) { continue }
        [void]$inventoryPaths.Add(($cols[0].Trim() -replace '\\', '/'))
    }
}

# -----------------------------------------------------------------------------
# Enumerate scannable files (working-tree incl. untracked).
# -----------------------------------------------------------------------------
$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
    $repoPath = Get-RepoPath -Root $root -Path $_.FullName
    [pscustomobject]@{
        FullName  = $_.FullName
        RepoPath  = $repoPath
        Extension = $_.Extension.ToLowerInvariant()
    }
} | Where-Object {
    -not (Test-UnderPrefix -Path $_.RepoPath -Prefixes $ignoredPrefixes)
}

# -----------------------------------------------------------------------------
# Raw NASM instruction mnemonics. A line that, stripped of comments/strings, is
# `<mnemonic>` optionally followed by whitespace + operands (and NOT immediately
# `(` - which would be an GHL call) is a raw emitter string. `call` is excluded:
# it is an GHL keyword (`call f(...)`); a raw `call` would be `call <ident>`
# WITHOUT parens, handled below.
# -----------------------------------------------------------------------------
$mnemonics = @(
    'mov','movzx','movsx','movsxd','lea','push','pop','pushfq','popfq',
    'add','sub','imul','mul','idiv','div','inc','dec','neg',
    'and','or','xor','not','shl','shr','sar','sal','rol','ror',
    'cmp','test','jmp','je','jne','jz','jnz','jg','jl','jge','jle','ja','jb','jae','jbe',
    'ret','retq','iret','int','int3','leave','enter','nop',
    'stosb','stosw','stosd','stosq','movsb','movsw','movsd','movsq','rep','repe','repne',
    'cdq','cqo','cdqe','xchg','bt','bts','btr','setz','setnz','sete','setne'
)
$mnAlt = ($mnemonics -join '|')
# mnemonic at start, then either end, or whitespace+operand that is NOT '(':
$rawAsmPattern = [regex]("^(?:$mnAlt)(\s+[^(\s][^;{]*)?\s*;?\s*$")
# bare `call IDENT` (no parens) - a raw call, distinct from GHL `call f(...)`.
$rawCallPattern = [regex]'^call\s+[A-Za-z_.][A-Za-z0-9_.]*\s*;?\s*$'

# Public-API export forms in an include file.
$incExportPattern = [regex]'(?i)^\s*(global\s+[A-Za-z_.]|%define\s+[A-Za-z_]|%macro\s+[A-Za-z_]|EXPORT\s+)'

# Logging sinks (serial/console) - the release-logging hazard surface.
$logSinkPattern = [regex]'(?i)\b(cb_ser|ser_print[a-z0-9_]*|serial_[a-z0-9_]+|klog[a-z0-9_]*|kprint[a-z0-9_]*)\s*\('

# Raw user-data placeholders that must never enter a log/trace format string.
$rawUserDataPattern = [regex]'(?i)\$\{?\s*(user(_?(input|data|payload|text|content))?|appdata|app_content|clipboard|window_title|keystroke)\b'

foreach ($file in $files) {
    if ($file.Extension -notin @('.ghl', '.inc', '.py')) { continue }

    $isTrustedNxh = ($file.Extension -eq '.ghl') -and (Test-UnderPrefix -Path $file.RepoPath -Prefixes $trustedNxhPrefixes)
    $isBackend = Test-UnderPrefix -Path $file.RepoPath -Prefixes $backendAllowlist
    $isSecurityModule = Test-UnderPrefix -Path $file.RepoPath -Prefixes $securityModulePrefixes
    $isPolicyModule = Test-UnderPrefix -Path $file.RepoPath -Prefixes @('src/tools/security')

    $lines = $null
    try { $lines = Get-Content -LiteralPath $file.FullName -ErrorAction Stop } catch { continue }
    if ($null -eq $lines) { continue }

    # --- Rule: undocumented intrinsic (gritc.py backend only). -----------------
    if ($isBackend) {
        $raw = ($lines -join "`n")
        $m = [regex]::Match($raw, '(?s)_NULLARY_INTRINSICS\s*=\s*\{(.*?)\n\}')
        if ($m.Success) {
            $body = $m.Groups[1].Value
            foreach ($km in [regex]::Matches($body, '"([a-z_0-9]+)"\s*:')) {
                $name = $km.Groups[1].Value
                if (-not $documentedIntrinsics.Contains($name)) {
                    $findings.Add([pscustomobject]@{
                        Rule = 'undocumented-intrinsic'
                        Location = "$($file.RepoPath) (intrinsic '$name')"
                        Text = "gritc intrinsic '$name' is not in the documented-intrinsic allowlist (document it in check_ghl_presubmit.ps1)."
                    })
                }
            }
        }
    }

    # --- Rule: missing threat-note header (policy modules). -------------------
    if ($isPolicyModule -and $file.Extension -eq '.ghl') {
        $headerKeywords = '(?i)(threat|attack|fail[- ]closed|trusted|reject|security|compromise|privacy|revocation|forbid|policy|invariant|signed|quorum|canonical|capability)'
        $headerHit = $false
        $scan = [Math]::Min(14, $lines.Count)
        for ($i = 0; $i -lt $scan; $i++) {
            if ($lines[$i].TrimStart().StartsWith('#') -and ($lines[$i] -match $headerKeywords)) { $headerHit = $true; break }
        }
        if (-not $headerHit) {
            $findings.Add([pscustomobject]@{
                Rule = 'missing-threat-note'
                Location = $file.RepoPath
                Text = 'Security policy module has no threat/security-reasoning header comment in its first 14 lines.'
            })
        }
    }

    # --- Per-line rules. ------------------------------------------------------
    $cfgDepth = 0       # depth inside a `cfg "ENABLE_*" { ... }` debug-gated block
    $cfgPending = $false
    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo++
        $code = Remove-NxhLineNoise -Line $line
        $trimCode = $code.Trim()

        # Track cfg-block scope (only meaningful for .ghl).
        if ($file.Extension -eq '.ghl') {
            if ($trimCode -match '^cfg\b') {
                if ($trimCode.Contains('{')) { $cfgDepth++ } else { $cfgPending = $true }
            } elseif ($cfgPending -and $trimCode.Contains('{')) {
                $cfgDepth++; $cfgPending = $false
            } elseif ($cfgDepth -gt 0) {
                $cfgDepth += ([regex]::Matches($trimCode, '\{')).Count
                $cfgDepth -= ([regex]::Matches($trimCode, '\}')).Count
                if ($cfgDepth -lt 0) { $cfgDepth = 0 }
            }
        }

        # Rule: raw emitter string in trusted .ghl (outside backend).
        if ($isTrustedNxh -and -not $isBackend -and $trimCode.Length -gt 0) {
            if ($rawAsmPattern.IsMatch($trimCode) -or $rawCallPattern.IsMatch($trimCode)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'ghl-raw-emitter-string'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "Raw NASM instruction in .ghl source: $($line.Trim())"
                })
            }
        }

        # Rule: public API exposed through a .inc include (non-inventory).
        if ($file.Extension -eq '.inc' -and -not $inventoryPaths.Contains($file.RepoPath)) {
            if ($incExportPattern.IsMatch($line)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'inc-public-api'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "New public API exposed via a .inc include (must be GHL): $($line.Trim())"
                })
            }
        }

        # Rule: release-time logging sink in a security/policy/crypto module.
        if ($isSecurityModule -and $file.Extension -eq '.ghl' -and $cfgDepth -eq 0) {
            if ($logSinkPattern.IsMatch($code)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'release-logging-in-security'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "Release-scope logging sink in a security module (gate behind cfg `"ENABLE_*`"): $($line.Trim())"
                })
            }
        }

        # Rule: raw user data in a log/trace format string (trusted-path source).
        if (($isTrustedNxh -or $isPolicyModule) -and $rawUserDataPattern.IsMatch($line) -and $logSinkPattern.IsMatch($line)) {
            $findings.Add([pscustomobject]@{
                Rule = 'raw-user-data-in-log'
                Location = "$($file.RepoPath):$lineNo"
                Text = "Raw user data interpolated into a log/trace sink: $($line.Trim())"
            })
        }
    }
}

Write-Host '[bootstrap-host-scan] GHL presubmit guard'
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
