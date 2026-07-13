$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Ownership = Join-Path $Root 'docs\ownership-registry.md'
$required = @(
    'src/kernel/kernel_build.asm',
    'src/kernel/proc/usermode.asm',
    'src/include/l3_runtime.inc',
    'src/kernel/proc/syscall.asm',
    'src/kernel/proc/syscall_validation.inc',
    'src/kernel/proc/process.asm',
    'src/include/constants.inc',
    'src/boot/paging.asm',
    'src/include/window_layout.inc',
    'src/kernel/gui/window.asm',
    'src/kernel/grithlk/fat16_core.ghl',
    'scripts/test/test_verify_all.ps1'
)

$text = Get-Content -Path $Ownership -Raw
foreach ($item in $required) {
    $pattern = [regex]::Escape($item)
    if ($text -notmatch $pattern) { throw "Ownership registry missing $item" }
    if (-not (Test-Path (Join-Path $Root $item))) { throw "Owned path missing $item" }
}

Write-Host '[ownership] PASS'
