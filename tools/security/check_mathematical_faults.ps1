# Runs the deterministic mathematical fault scanner.
#
# The Python checker compiles embedded user apps into a temp directory and then
# proves W^X/layout fault conditions from source/build geometry. It emits only
# concrete findings with trigger/evidence/fix fields.
param(
    [string]$RepoRoot,
    [ValidateSet('text', 'json', 'markdown')]
    [string]$Format = 'text',
    [string]$Output,
    [string]$Listing,
    [switch]$KeepTemp
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

if (-not $RepoRoot) {
    $RepoRoot = Get-RepoRoot
}

$Script = Join-Path $RepoRoot 'tools\security\check_mathematical_faults.py'
if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
    throw "Missing mathematical fault checker: $Script"
}

$argsList = @($Script, '--repo-root', $RepoRoot, '--format', $Format)
if ($Output) { $argsList += @('--output', $Output) }
if ($Listing) { $argsList += @('--listing', $Listing) }
if ($KeepTemp) { $argsList += '--keep-temp' }

& python @argsList
exit $LASTEXITCODE
