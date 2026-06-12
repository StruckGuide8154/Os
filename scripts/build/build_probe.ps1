$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$NASM = 'C:\Tools\nasm-2.16.03\nasm.exe'
$SRC = Join-Path $Root 'src\diag\uefi_mouse_probe.asm'
$OUTDIR = Join-Path $Root 'build\probe-esp\EFI\BOOT'

Write-Host ''
Write-Host '  GritOS Mouse Probe Build' -ForegroundColor Cyan
Write-Host '  ==========================' -ForegroundColor Cyan

New-Item -Path $OUTDIR -ItemType Directory -Force | Out-Null
$Out = Join-Path $OUTDIR 'BOOTX64.EFI'

& $NASM -f bin -o $Out $SRC
if ($LASTEXITCODE -ne 0) {
    Write-Host '  FAILED' -ForegroundColor Red
    exit 1
}

$sz = (Get-Item $Out).Length
Write-Host ("  OK  BOOTX64.EFI  ({0} bytes)" -f $sz) -ForegroundColor Green
Write-Host ''
Write-Host "  Output: $OUTDIR\BOOTX64.EFI" -ForegroundColor White
Write-Host ''
Write-Host '  Copy that file to a FAT32 USB stick at \EFI\BOOT\BOOTX64.EFI' -ForegroundColor Gray
Write-Host '  Boot from it. Screen should go black with a moving white square' -ForegroundColor Gray
Write-Host '  if any UEFI pointer protocol works on your hardware.' -ForegroundColor Gray
Write-Host ''
