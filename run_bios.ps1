$ErrorActionPreference = 'Stop'
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$IMG = (Join-Path $PSScriptRoot 'build\NexusOS.img')
$LOG = (Join-Path $PSScriptRoot 'serial.log')

Write-Host "Booting NexusOS (BIOS) in QEMU..." -ForegroundColor Cyan
& $QEMU `
    -drive "file=$IMG,format=raw,index=0,media=disk" `
    -m 512M `
    -vga std `
    -name NexusOS `
    -serial "file:$LOG" `
    -device nec-usb-xhci,id=xhci `
    -device usb-mouse,bus=xhci.0
