# =============================================================================
# check_build_integrity.ps1 - build-graph quarantine enforcement.
#
# Beyond-zero-trust Track 1 (docs/track1-repo-enforcement-todo.md, "P0 - finish
# repository enforcement" + "Enforcement-shape correctness").
#
# This guard splits the repo's build surface into two modes and forbids the NEW
# architecture from inheriting the LEGACY architecture's NASM/%include
# assumptions:
#
#   legacy-maintenance mode  - an EXPLICIT allowlist of quarantined build
#       artifacts (the legacy build scripts + the kernel/app aggregators) that
#       are PERMITTED to invoke nasm, use `-f bin`, and `%include "*.asm/*.inc"`.
#       This is the quarantine, not new work.
#
#   new-architecture mode    - every other tracked build/orchestration script.
#       These MUST NOT introduce nasm, `-f bin`, or `%include "*.asm/*.inc"`:
#       new trusted-path work is GHL/GritHLK, compiled by gritc.py.
#
# Rules:
#   [new-arch-build-asm-include]  %include "*.asm"/"*.inc", a `nasm` invocation,
#       or `-f bin` in a build/orchestration script OUTSIDE the legacy allowlist.
#   [generated-artifact-as-source] a tracked SOURCE file references a generated
#       artifact (build/ghl/**/*.asm or build/ghl/generated_apps.inc) via a real
#       %include directive, outside the legacy aggregator allowlist - i.e. the
#       generated output is being treated as a source of truth.
#   [deprecated-import] anything under deprecated/ is imported/included/compiled/
#       linked, or named as an allowlist source, by a tracked non-deprecated file.
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
        if ($Path -eq $normalized -or $Path.StartsWith("$normalized/")) { return $true }
    }
    return $false
}

$root = Get-RepoRoot
$findings = New-Object System.Collections.Generic.List[object]

# Directories never scanned (VCS / tooling / generated / archival output).
# NOTE: deprecated/ is NOT ignored here - we must scan non-deprecated files for
# references INTO deprecated/, and skip only files that live under deprecated/.
$ignoredPrefixes = @('.git', '.claude', 'sandbox_shadow', 'build', 'dist', '__pycache__', 'worktrees')

# -----------------------------------------------------------------------------
# LEGACY-MAINTENANCE ALLOWLIST (the quarantine).
#
# These files are the ONLY build-graph members permitted to invoke nasm, use
# `-f bin`, or `%include "*.asm/*.inc"`. They are the legacy build scripts and
# the legacy aggregators that wire the generated artifacts into the single NASM
# translation unit. Adding a NEW file here is a reviewed inventory edit, not a
# silent default.
# -----------------------------------------------------------------------------
$legacyBuildScripts = @(
    'scripts/build/build_uefi.ps1',
    'scripts/build/build_bios.ps1',
    'scripts/build/build_ghl.ps1',
    # Legacy diagnostic build: assembles the quarantined legacy
    # src/diag/uefi_mouse_probe.asm (inventory-listed) into a standalone probe
    # EFI. Builds existing legacy assembly, not new-architecture work.
    'scripts/build/build_probe.ps1',
    # Compiler self-verification harness: compiles .ghl fixtures and asserts the
    # gritc-generated .asm assembles under NASM. NASM here verifies the legacy
    # backend output, it is not new-architecture build work - legitimately
    # legacy-maintenance, so it is allowlisted with the legacy build graph.
    'scripts/test/test_gritc_security.ps1',
    # Legacy boot-artifact byte-parity harness: re-assembles the legacy boot
    # .asm (UEFI loader / mbr / stage2) under NASM and SHA256-compares against a
    # recorded baseline. Pure legacy-maintenance verification of quarantined
    # boot assembly; allowlisted with the legacy build graph.
    'scripts/test/boot_parity.ps1'
)

# Legacy aggregators that are PERMITTED to %include the generated build/ghl
# artifacts. They are the integration point of the generated-output -> NASM-image
# build step; everything else must treat build/ghl as output, never source.
$legacyAggregators = @(
    'src/kernel/kernel_build.asm',
    'src/user/apps.asm',
    # Dedicated signed driver-package linker wrapper. Like kernel_build.asm it
    # only aggregates gritc output into the flat image; the .ghl remains source.
    'src/drivers/driver_blob.asm'
)

# The full legacy quarantine: build scripts + aggregators. Files here are exempt
# from BOTH the new-arch-build-asm-include rule and the generated-artifact rule.
$legacyAllowlist = @($legacyBuildScripts + $legacyAggregators)

# -----------------------------------------------------------------------------
# Enumerate scannable files (working-tree, includes untracked so a planted file
# cannot sneak through). Same enumeration discipline as check_no_asm.ps1.
# -----------------------------------------------------------------------------
$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
    $repoPath = Get-RepoPath -Root $root -Path $_.FullName
    [pscustomobject]@{
        FullName  = $_.FullName
        RepoPath  = $repoPath
        Extension = $_.Extension.ToLowerInvariant()
        Length    = $_.Length
    }
} | Where-Object {
    -not (Test-UnderPrefix -Path $_.RepoPath -Prefixes $ignoredPrefixes)
}

# -----------------------------------------------------------------------------
# Patterns.
# -----------------------------------------------------------------------------
# %include of a legacy assembly/include artifact (any path).
$asmIncludePattern   = [regex]'(?i)^\s*%include\s+"[^"]*\.(asm|inc)"'
# %include specifically of a generated build/ghl artifact (source-of-truth abuse).
$genIncludePattern   = [regex]'(?i)^\s*%include\s+"(build/ghl/[^"]*\.(asm|inc)|[^"]*generated_apps\.inc)"'
# nasm INVOCATION in a build/orchestration script (the legacy assembler).
# Matches true call sites only, never the prose word "NASM" in a message string
# or a comment:
#   * a $NASM / $Nasm script variable used as the assembler handle, or
#   * the call operator `& [...]nasm[.exe]`, or
#   * a line whose first token is the lowercase command `nasm`.
$nasmInvokePattern   = [regex]'(?i:\$nasm\b|&\s*[''"]?[^''"\s]*nasm(\.exe)?\b)|^\s*(?-i:nasm)(\.exe)?(?=$|\s)'
# `-f bin` flat-binary output (the legacy raw-image format).
$fBinPattern         = [regex]'(?i)(^|\s)-f\s+bin(?=$|\s)'
# A reference to anything under deprecated/ being consumed (not merely mentioned
# in prose): include/import/compile/link/source-arg forms.
$deprecatedRefPattern = [regex]'(?i)(%include\s+"[^"]*deprecated/|(?:^|[\s"''(/\\])deprecated/[^\s"'']*\.(asm|inc|ghl|py|ps1))'

# Build/orchestration script extensions for the new-arch include/nasm rule.
$buildScriptExts = @('.ps1', '.py')
$binaryExts = @('.png', '.jpg', '.jpeg', '.gif', '.bin', '.efi', '.img', '.pyc', '.ico', '.bmp', '.svg', '.nba', '.ttf', '.woff',
                '.zip', '.7z', '.gz', '.xz', '.zst', '.tar', '.iso', '.raw', '.lst', '.pdf', '.exe', '.dll', '.pt', '.pth', '.onnx')
# No legitimate build/orchestration script is anywhere near this large; without
# a cap, Get-Content materializes any big unlisted binary (e.g. a dataset zip
# dropped in the tree) as a UTF-16 string array — hundreds of MB per guard run.
$maxScanBytes = 4MB

foreach ($file in $files) {
    $isLegacyAllow      = Test-UnderPrefix -Path $file.RepoPath -Prefixes $legacyAllowlist
    $isLegacyAggregator = Test-UnderPrefix -Path $file.RepoPath -Prefixes $legacyAggregators
    $isDeprecatedSelf   = Test-UnderPrefix -Path $file.RepoPath -Prefixes @('deprecated')

    if ($file.Extension -in $binaryExts) { continue }
    if ($file.Length -gt $maxScanBytes) { continue }

    $lines = $null
    try { $lines = Get-Content -LiteralPath $file.FullName -ErrorAction Stop } catch { continue }
    if ($null -eq $lines) { continue }

    $isBuildOrchestration =
        Test-UnderPrefix -Path $file.RepoPath -Prefixes @('scripts/build', 'scripts/test', 'tools/build')

    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo++
        $stripped = $line.TrimStart()
        $isComment = $stripped.StartsWith('#') -or $stripped.StartsWith(';')

        # -- Rule: new-architecture build script must not use nasm/-f bin/%include.
        if ($file.Extension -in $buildScriptExts -and -not $isLegacyAllow -and $isBuildOrchestration -and -not $isComment) {
            if ($asmIncludePattern.IsMatch($line)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'new-arch-build-asm-include'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "%include of legacy .asm/.inc in a non-legacy build script: $($line.Trim())"
                })
            }
            if ($nasmInvokePattern.IsMatch($line)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'new-arch-build-asm-include'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "nasm invocation in a non-legacy build script: $($line.Trim())"
                })
            }
            if ($fBinPattern.IsMatch($line)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'new-arch-build-asm-include'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "-f bin flat-binary output in a non-legacy build script: $($line.Trim())"
                })
            }
        }

        # -- Rule: generated artifact referenced as source of truth.
        # A generated build/ghl artifact (.asm) or generated_apps.inc may only be
        # %include'd by the legacy aggregators. Any other source treating it as
        # input is treating build output as source of truth.
        if (-not $isLegacyAggregator -and -not $isComment) {
            if ($genIncludePattern.IsMatch($line)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'generated-artifact-as-source'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "Generated build/ghl artifact consumed as source of truth: $($line.Trim())"
                })
            }
        }

        # -- Rule: nothing under deprecated/ may be imported/included/compiled.
        # The deprecated/ tree is archival-only. A file UNDER deprecated/ may
        # reference its siblings; a non-deprecated file may not reach into it.
        if (-not $isDeprecatedSelf -and -not $isComment) {
            if ($deprecatedRefPattern.IsMatch($line)) {
                $findings.Add([pscustomobject]@{
                    Rule = 'deprecated-import'
                    Location = "$($file.RepoPath):$lineNo"
                    Text = "Archival deprecated/ tree consumed by active code: $($line.Trim())"
                })
            }
        }
    }
}

Write-Host '[bootstrap-host-scan] build-graph integrity guard'
Write-Host "Repo root: $root"
Write-Host "Legacy build-script allowlist: $($legacyBuildScripts -join ', ')"
Write-Host "Legacy aggregator allowlist: $($legacyAggregators -join ', ')"

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
