$ErrorActionPreference = 'Stop'

# seL4 validity track runner. Validates the machine-checkable invariant files,
# asserts every referenced predicate exists as a global in the GHL invariant
# kernel, and compiles that kernel --forbid-asm --deny-unsafe.

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$LibDir = Join-Path $Root 'src\user\grithl\lib'
$Module = Join-Path $Root 'src\tools\security\invariant_check.ghl'
$InvariantDir = Join-Path $Root 'tests\security\invariants'
$VectorDir = Join-Path $InvariantDir 'vectors'
$Evaluator = Join-Path $PSScriptRoot 'eval_invariants.py'

foreach ($p in @($Compiler, $Module)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing required file: $p" }
}
if (-not (Test-Path -LiteralPath $LibDir -PathType Container)) {
    throw "Missing GritHL library directory: $LibDir"
}
if (-not (Test-Path -LiteralPath $InvariantDir -PathType Container)) {
    throw "Missing invariant directory: $InvariantDir"
}

function Read-KeyValueFile {
    param([string]$Path)
    $map = @{}
    $lineNo = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        $lineNo++
        $trim = $line.Trim()
        if ($trim.Length -eq 0 -or $trim.StartsWith('#')) { continue }
        $parts = $trim.Split('=', 2)
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            throw "${Path}:$lineNo invalid line: $line"
        }
        $key = $parts[0].Trim()
        if ($map.ContainsKey($key)) { throw "${Path}:$lineNo duplicate key: $key" }
        $map[$key] = $parts[1].Trim()
    }
    return $map
}

# Collect the predicate names exported by the invariant kernel.
$exported = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($line in Get-Content -LiteralPath $Module) {
    $m = [regex]::Match($line.Trim(), '^global\s+([A-Za-z_][A-Za-z0-9_]*)\s*;')
    if ($m.Success) { [void]$exported.Add($m.Groups[1].Value) }
}
if ($exported.Count -eq 0) { throw "No exported predicates found in $Module" }

$invariants = @(Get-ChildItem -LiteralPath $InvariantDir -Recurse -File -Filter '*.invariant' | Sort-Object FullName)
if ($invariants.Count -eq 0) { throw "No invariant files found under $InvariantDir" }

Write-Host "[ghl-invariants] Validating $($invariants.Count) invariant(s)..." -ForegroundColor Yellow
$ids = New-Object 'System.Collections.Generic.HashSet[string]'
$invPredicate = @{}   # invariant id -> predicate name (cross-checked against vectors)
$validStatus = @('modeled', 'tested', 'proven')
foreach ($inv in $invariants) {
    $data = Read-KeyValueFile -Path $inv.FullName
    foreach ($required in @('invariant', 'title', 'statement', 'compromised', 'denied_authority', 'predicate', 'status')) {
        if (-not $data.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($data[$required])) {
            throw "$($inv.FullName) missing required key: $required"
        }
    }
    if (-not $ids.Add($data['invariant'])) {
        throw "$($inv.FullName) duplicate invariant id: $($data['invariant'])"
    }
    if ($validStatus -notcontains $data['status']) {
        throw "$($inv.FullName) status must be one of $($validStatus -join ', '); got: $($data['status'])"
    }
    if (-not $exported.Contains($data['predicate'])) {
        throw "$($inv.FullName) references predicate '$($data['predicate'])' not exported by invariant_check.ghl"
    }
    $invPredicate[$data['invariant']] = $data['predicate']
    Write-Host "[ghl-invariants]   $($data['invariant']) -> $($data['predicate']) [$($data['status'])]"
}

# --- Vectors: every invariant must have a .vectors file, and its invariant id +
# predicate must agree with the .invariant declaration. The evaluator below then
# actually EXECUTES the real predicate against each vector.
if (-not (Test-Path -LiteralPath $VectorDir -PathType Container)) {
    throw "Missing invariant vector directory: $VectorDir"
}
if (-not (Test-Path -LiteralPath $Evaluator -PathType Leaf)) {
    throw "Missing invariant evaluator: $Evaluator"
}
$vectorFiles = @(Get-ChildItem -LiteralPath $VectorDir -File -Filter '*.vectors' | Sort-Object FullName)
if ($vectorFiles.Count -eq 0) { throw "No .vectors files found under $VectorDir" }

# A .vectors file has repeated `case=` lines, so Read-KeyValueFile (which rejects
# duplicate keys) cannot parse it. Pull just the single-valued meta keys here; the
# Python evaluator owns full parsing + execution of the `case` lines.
function Get-VectorMeta {
    param([string]$Path)
    $meta = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trim = $line.Trim()
        if ($trim.Length -eq 0 -or $trim.StartsWith('#')) { continue }
        $parts = $trim.Split('=', 2)
        if ($parts.Count -ne 2) { continue }
        $key = $parts[0].Trim()
        if ($key -eq 'invariant' -or $key -eq 'predicate') {
            if ($meta.ContainsKey($key)) { throw "${Path}: duplicate key: $key" }
            $meta[$key] = $parts[1].Trim()
        }
    }
    return $meta
}

$vectorIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($vf in $vectorFiles) {
    $vdata = Get-VectorMeta -Path $vf.FullName
    foreach ($required in @('invariant', 'predicate')) {
        if (-not $vdata.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($vdata[$required])) {
            throw "$($vf.FullName) missing required key: $required"
        }
    }
    $vid = $vdata['invariant']
    if (-not $invPredicate.ContainsKey($vid)) {
        throw "$($vf.FullName) declares invariant '$vid' with no matching .invariant file"
    }
    if ($vdata['predicate'] -ne $invPredicate[$vid]) {
        throw "$($vf.FullName) predicate '$($vdata['predicate'])' disagrees with .invariant predicate '$($invPredicate[$vid])' for $vid"
    }
    [void]$vectorIds.Add($vid)
}
foreach ($id in $ids) {
    if (-not $vectorIds.Contains($id)) {
        throw "Invariant '$id' has no .vectors file under $VectorDir (positive + negative vectors required for 'tested')"
    }
}

# Read-KeyValueFile rejects repeated keys, so it cannot parse the multi-`case`
# vector files itself; the dedicated evaluator does that and EXECUTES the real
# GHL predicate source against every vector (accept must return 1, reject 0).
Write-Host '[ghl-invariants] evaluate vectors against real predicate source...' -ForegroundColor Yellow
& python $Evaluator
if ($LASTEXITCODE -ne 0) { throw 'invariant vector evaluation failed.' }

Write-Host '[ghl-invariants] prove bounded authority space exhaustively (bit-width derived from invariant_check.ghl)...' -ForegroundColor Yellow
& python $Evaluator --exhaustive
if ($LASTEXITCODE -ne 0) { throw 'invariant exhaustive authority check failed.' }

# Translation-validation (model <-> emitted code): compile invariant_check.ghl
# with the production gritc and confirm the PROVEN authority constants are the
# exact immediates emitted into the artifact - binds the proof to the compiled
# bits, closing the model<->code constant-drift gap (NOT a full refinement proof).
Write-Host '[ghl-invariants] translation-validate proven authority constants against gritc-emitted code...' -ForegroundColor Yellow
& python $Evaluator --translation-validation
if ($LASTEXITCODE -ne 0) { throw 'invariant translation-validation failed.' }

# P3 mapping: the authority bitmasks are DERIVED from the real signed policy
# (app manifests, policy graph, compiler unsafe caps, artifact-class quorums)
# and re-checked against the real predicates - never hand-asserted.
Write-Host '[ghl-invariants] derive authority bitmasks from real signed policy...' -ForegroundColor Yellow
& python (Join-Path $PSScriptRoot 'derive_authority.py')
if ($LASTEXITCODE -ne 0) { throw 'policy-derived authority check failed.' }

# Meta-tests: prove the closures actually fire - a planted wrong constant is
# caught by translation-validation, and a planted new authority bit that breaks
# an invariant is caught by the auto-widened exhaustive proof (a proof/guard
# that never fails is no proof).
Write-Host '[ghl-invariants] meta-test: planted drift must be caught (translation-validation + dynamic width)...' -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test_invariant_meta.ps1')
if ($LASTEXITCODE -ne 0) { throw 'invariant meta-tests failed.' }

$OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ghl-invariants-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
try {
    $outPath = Join-Path $OutDir 'invariant_check.asm'
    Write-Host '[ghl-invariants] compile invariant_check.ghl --forbid-asm --deny-unsafe' -ForegroundColor Yellow
    & python $Compiler $Module -o $outPath -L $LibDir --embed --target kernel --forbid-asm --deny-unsafe
    if ($LASTEXITCODE -ne 0) { throw 'invariant_check.ghl compile failed.' }
}
finally {
    if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
}

Write-Host '[ghl-invariants] PASS' -ForegroundColor Green
