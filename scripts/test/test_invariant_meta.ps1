# =============================================================================
# test_invariant_meta.ps1 - meta-tests for the Track-3 (seL4 validity) invariant
# proof machinery itself. A proof that never fails is no proof.
#
# These assert that the two "Path to 10/10" closures actually fire:
#
#   1. TRANSLATION VALIDATION catches model<->code drift: a PLANTED wrong
#      authority constant in the GHL predicate source makes
#      `eval_invariants.py --translation-validation` FAIL (the proven model
#      constant no longer matches the gritc-emitted immediate).
#
#   2. DYNAMIC BIT-WIDTH auto-extends the proof: a PLANTED new authority bit
#      (AUTH_BACKDOOR=128) that breaks an invariant only in the now-wider 8-bit
#      space makes `eval_invariants.py --exhaustive` FAIL - proving the proof
#      space widened automatically with the policy. (A control plant that adds a
#      new bit WITHOUT breaking anything must still PASS, proving the width grew
#      soundly rather than via a spurious failure.)
#
# Every plant is written to a TEMP copy of invariant_check.ghl and fed to the
# evaluator via the GHL_INVARIANT_MODULE override - the real source tree is
# never modified, so there is nothing to restore.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Evaluator = Join-Path $PSScriptRoot 'eval_invariants.py'
$RealModule = Join-Path $Root 'src\tools\security\invariant_check.ghl'

foreach ($p in @($Evaluator, $RealModule)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing required file: $p" }
}

$failures = New-Object System.Collections.Generic.List[string]
$passes = 0

function Invoke-Eval {
    param([string]$ModulePath, [string[]]$EvalArgs)
    $env:GHL_INVARIANT_MODULE = $ModulePath
    # python writes diagnostics to stderr; under $ErrorActionPreference='Stop' a
    # native stderr write surfaces as a NativeCommandError. Relax it locally and
    # rely solely on the process exit code.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & python $Evaluator @EvalArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
        Remove-Item Env:\GHL_INVARIANT_MODULE -ErrorAction SilentlyContinue
    }
}

function New-PlantedModule {
    param([scriptblock]$Mutate)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('inv-meta-' + [System.Guid]::NewGuid().ToString('N') + '.ghl')
    $src = Get-Content -LiteralPath $RealModule -Raw
    $src = & $Mutate $src
    # BOM-less UTF-8: gritc's lexer rejects a leading U+FEFF, and Set-Content
    # -Encoding UTF8 emits a BOM on Windows PowerShell 5.1.
    [System.IO.File]::WriteAllText($tmp, $src, (New-Object System.Text.UTF8Encoding($false)))
    return $tmp
}

function Assert-EvalFails {
    param([string]$Name, [string]$ModulePath, [string[]]$EvalArgs)
    $code = Invoke-Eval -ModulePath $ModulePath -EvalArgs $EvalArgs
    if ($code -ne 0) {
        Write-Host "[inv-meta] PASS  $Name (evaluator exited $code as expected)" -ForegroundColor Green
        $script:passes++
    } else {
        Write-Host "[inv-meta] FAIL  $Name (evaluator exited 0; drift NOT detected)" -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

function Assert-EvalPasses {
    param([string]$Name, [string]$ModulePath, [string[]]$EvalArgs)
    $code = Invoke-Eval -ModulePath $ModulePath -EvalArgs $EvalArgs
    if ($code -eq 0) {
        Write-Host "[inv-meta] PASS  $Name (evaluator exited 0 as expected)" -ForegroundColor Green
        $script:passes++
    } else {
        Write-Host "[inv-meta] FAIL  $Name (evaluator exited $code; expected clean pass)" -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

# Sanity: the REAL module must be green on both modes before we plant, so a
# planted FAIL is attributable to the plant and not a pre-existing break.
$baseTv = Invoke-Eval -ModulePath $RealModule -EvalArgs @('--translation-validation')
$baseEx = Invoke-Eval -ModulePath $RealModule -EvalArgs @('--exhaustive')
if ($baseTv -ne 0) { throw 'Meta precondition failed: real module fails translation-validation before planting.' }
if ($baseEx -ne 0) { throw 'Meta precondition failed: real module fails exhaustive proof before planting.' }

# -----------------------------------------------------------------------------
# Test 1: plant a WRONG authority constant. inv_scheduler_no_memory_grant is
# proven to deny AUTH_MEMORY_GRANT (bit 1); if the source const is changed to a
# different value, the gritc-emitted immediate no longer matches the proven
# model constant -> translation-validation must FAIL.
# -----------------------------------------------------------------------------
$plant1 = New-PlantedModule {
    param($s)
    # Change AUTH_MEMORY_GRANT from 1 to 1024: the emitted immediate becomes
    # 1024 while the binding still expects bit 1 to be the denied authority.
    # (Use a value not already a power-of-two bit in use to make the drift sharp.)
    $s -replace 'const AUTH_MEMORY_GRANT = 1;', 'const AUTH_MEMORY_GRANT = 1024;'
}
try {
    Assert-EvalFails -Name 'planted wrong authority constant caught by translation-validation' `
        -ModulePath $plant1 -EvalArgs @('--translation-validation')
} finally {
    if (Test-Path -LiteralPath $plant1) { Remove-Item -LiteralPath $plant1 -Force }
}

# -----------------------------------------------------------------------------
# Test 2: plant a NEW authority bit (AUTH_BACKDOOR=128, widening the space to 8
# bits) AND a predicate break that is ONLY reachable in the widened space
# (inv_subset wrongly accepts any child carrying the backdoor bit). The
# exhaustive checker must auto-widen to 8 bits and CATCH the break.
# -----------------------------------------------------------------------------
$plant2 = New-PlantedModule {
    param($s)
    $s = $s -replace 'const AUTH_GLOBAL = 64;', "const AUTH_GLOBAL = 64;`nconst AUTH_BACKDOOR = 128;"
    # Break inv_subset so it wrongly accepts ANY child carrying the backdoor bit.
    # That bit (128) is only reachable once the space auto-widens to 8 bits, so
    # the exhaustive checker can only catch this if the width grew with the new
    # constant. Insert the bad early-return right after the fn's opening brace.
    $s -replace '(fn inv_subset\(child_auth, parent_auth\) \{)', "`$1`n    if (child_auth & AUTH_BACKDOOR) != 0 { return 1; }"
}
try {
    Assert-EvalFails -Name 'planted new authority bit that breaks an invariant caught by auto-widened exhaustive proof' `
        -ModulePath $plant2 -EvalArgs @('--exhaustive')
} finally {
    if (Test-Path -LiteralPath $plant2) { Remove-Item -LiteralPath $plant2 -Force }
}

# -----------------------------------------------------------------------------
# Test 3 (control): plant a NEW authority bit that does NOT break anything. The
# space must still auto-widen to 8 bits and the proof must PASS - proving the
# widening is sound, not a source of spurious failures.
# -----------------------------------------------------------------------------
$plant3 = New-PlantedModule {
    param($s)
    $s -replace 'const AUTH_GLOBAL = 64;', "const AUTH_GLOBAL = 64;`nconst AUTH_BACKDOOR = 128;"
}
try {
    Assert-EvalPasses -Name 'benign new authority bit still proven over the auto-widened space' `
        -ModulePath $plant3 -EvalArgs @('--exhaustive')
} finally {
    if (Test-Path -LiteralPath $plant3) { Remove-Item -LiteralPath $plant3 -Force }
}

# -----------------------------------------------------------------------------
# Post: the real module must STILL be green (the override left no residue).
# -----------------------------------------------------------------------------
$afterTv = Invoke-Eval -ModulePath $RealModule -EvalArgs @('--translation-validation')
$afterEx = Invoke-Eval -ModulePath $RealModule -EvalArgs @('--exhaustive')
if ($afterTv -ne 0) { $failures.Add('real module not green on translation-validation after meta-tests') }
else { Write-Host '[inv-meta] PASS  real module still green on translation-validation' -ForegroundColor Green; $passes++ }
if ($afterEx -ne 0) { $failures.Add('real module not green on exhaustive proof after meta-tests') }
else { Write-Host '[inv-meta] PASS  real module still green on exhaustive proof' -ForegroundColor Green; $passes++ }

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "[inv-meta] PASS: $passes meta-test(s) green" -ForegroundColor Green
    exit 0
}
Write-Host "[inv-meta] FAIL: $($failures.Count) meta-test(s) failed" -ForegroundColor Red
foreach ($f in $failures) { Write-Host "  - $f" }
exit 1
