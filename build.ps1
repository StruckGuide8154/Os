$ErrorActionPreference = 'Stop'

$NASM = 'C:\Tools\nasm-2.16.03\nasm.exe'
$SRC  = (Join-Path $PSScriptRoot 'src\boot.asm')
$OUT  = (Join-Path $PSScriptRoot 'build')
$ESP  = (Join-Path $OUT 'esp\EFI\BOOT')
$EFI  = (Join-Path $ESP 'BOOTX64.EFI')

Write-Host ''
Write-Host '  NexusOS Build System' -ForegroundColor Cyan
Write-Host '  ====================' -ForegroundColor Cyan
Write-Host ''

New-Item -Path $ESP -ItemType Directory -Force | Out-Null

Write-Host '[1/1] Assembling boot.asm ...' -ForegroundColor Yellow
& $NASM -f bin -o $EFI $SRC
if ($LASTEXITCODE -ne 0) {
    Write-Host '  FAILED - NASM assembly error' -ForegroundColor Red
    exit 1
}
$sz = (Get-Item $EFI).Length
Write-Host "  OK - BOOTX64.EFI created, $sz bytes" -ForegroundColor Green
Write-Host ''
Write-Host '  BUILD SUCCESSFUL' -ForegroundColor Green
Write-Host ''
Write-Host '  Output: build\esp\EFI\BOOT\BOOTX64.EFI' -ForegroundColor White
Write-Host ''
Write-Host '  To test with QEMU + OVMF:' -ForegroundColor Yellow
Write-Host '    qemu-system-x86_64 -bios OVMF.fd -drive file=fat:rw:build\esp -m 256M' -ForegroundColor Gray
Write-Host ''
Write-Host '  To boot on real hardware:' -ForegroundColor Yellow
Write-Host '    1. Format USB as FAT32' -ForegroundColor Gray
Write-Host '    2. Copy build\esp\EFI\ folder to USB root' -ForegroundColor Gray
Write-Host '    3. Boot from USB in UEFI mode' -ForegroundColor Gray
Write-Host ''
