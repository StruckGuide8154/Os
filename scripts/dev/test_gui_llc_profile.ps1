$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Constants = Get-Content -Path (Join-Path $Root 'src\include\constants.inc') -Raw
$Fat16 = Get-Content -Path (Join-Path $Root 'src\kernel\fs\fat16.asm') -Raw
$Syscall = Get-Content -Path (Join-Path $Root 'src\kernel\proc\syscall.asm') -Raw

$required = @(
    'GUI_LLC_ARENA_START equ 0x400000',
    'GUI_LLC_ARENA_END   equ 0x1000000',
    'CACHE32_RAM_LIMIT   equ 0x2000000',
    'XHCI_DCBAA_ADDR     equ 0x1900000',
    'FAT16_SECTOR_BUF    equ 0x1A00000',
    'FAT16_ROOT_CACHE    equ 0x1A11000'
)

$missing = @()
foreach ($pattern in $required) {
    if (($Constants + $Fat16 + $Syscall) -notlike "*$pattern*") { $missing += $pattern }
}
if ($missing.Count -gt 0) {
    throw "Missing Cache32Max layout constants: $($missing -join ', ')"
}

Write-Host '[gui-llc] PASS' -ForegroundColor Green
