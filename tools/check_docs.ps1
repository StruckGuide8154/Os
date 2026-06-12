$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Docs = Join-Path $Root 'docs'
$Index = Join-Path $Docs 'reference-index.md'
$ProposalDocs = @('app-loader-format.md', 'grithl.md')

function Assert-Text {
    param([string]$Path, [string]$Pattern, [string]$Message)
    $text = Get-Content -Path $Path -Raw
    if ($text -notmatch $Pattern) { throw $Message }
}

$indexText = Get-Content -Path $Index -Raw
$refs = [regex]::Matches($indexText, '`([^`]+\.md)`') | ForEach-Object {
    $_.Groups[1].Value
} | Sort-Object -Unique

foreach ($ref in $refs) {
    if ($ref -like 'build/*') {
        $path = Join-Path $Root $ref
    } else {
        $path = Join-Path $Docs $ref
    }
    if (-not (Test-Path $path)) { throw "Missing docs reference: $ref" }
}

foreach ($doc in $ProposalDocs) {
    Assert-Text (Join-Path $Docs $doc) '(?im)\b(proposed|roadmap|future)\b' "$doc must be clearly marked as proposal/roadmap/future."
}

Assert-Text (Join-Path $Docs 'invariant-registry.md') '(?im)\bnormative\b' 'Invariant registry must be marked normative.'
Assert-Text (Join-Path $Docs 'verification.md') '(?im)\bnormative\b' 'Verification doc must be marked normative.'
Assert-Text $Index 'source-map\.md' 'Reference index must link generated source map.'
Assert-Text $Index 'complexity-dashboard\.md' 'Reference index must link complexity dashboard.'

Write-Host '[docs] PASS'
