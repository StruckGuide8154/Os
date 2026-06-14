param(
    [switch]$IncludeUntracked,
    [switch]$FailOnSourceDirty
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Convert-GitPath {
    param([string]$Path)
    return ($Path -replace '/', '\')
}

function Test-GeneratedPath {
    param([string]$Path)

    $normalized = Convert-GitPath $Path
    return (
        $normalized -like 'build\*' -or
        $normalized -like 'dist\*' -or
        $normalized -like 'sandbox_shadow\*' -or
        $normalized -like 'src\include\qrng_seed.inc' -or
        $normalized -like 'tools\quantum\seed.bin' -or
        $normalized -like 'tools\quantum\seed.inc' -or
        $normalized -like 'tools\quantum\qrng_manifest.txt' -or
        $normalized -match '\.(bin|img|iso|efi|lst|map|log|tmp|bak|png|bmp|ppm)$'
    )
}

$statusArgs = @('status', '--porcelain=v1')
if (-not $IncludeUntracked) {
    $statusArgs += '--untracked-files=no'
}

$statusLines = git -C $Root @statusArgs
if ($LASTEXITCODE -ne 0) {
    throw "git status failed with exit code $LASTEXITCODE"
}

$generated = New-Object System.Collections.Generic.List[string]
$source = New-Object System.Collections.Generic.List[string]

foreach ($line in $statusLines) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) {
        continue
    }

    $state = $line.Substring(0, 2)
    $path = $line.Substring(3)
    if ($path -like '* -> *') {
        $path = ($path -split ' -> ', 2)[1]
    }
    $entry = '{0} {1}' -f $state, (Convert-GitPath $path)

    if (Test-GeneratedPath $path) {
        $generated.Add($entry)
    } else {
        $source.Add($entry)
    }
}

Write-Host 'Dirty generated files:'
if ($generated.Count -eq 0) {
    Write-Host '  (none)'
} else {
    foreach ($item in ($generated | Sort-Object)) {
        Write-Host "  $item"
    }
}

Write-Host ''
Write-Host 'Dirty source files:'
if ($source.Count -eq 0) {
    Write-Host '  (none)'
} else {
    foreach ($item in ($source | Sort-Object)) {
        Write-Host "  $item"
    }
}

if ($FailOnSourceDirty -and $source.Count -gt 0) {
    throw "Source dirty files found: $($source.Count)"
}
