$ErrorActionPreference = 'SilentlyContinue'
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$BUILD = Join-Path $PSScriptRoot 'build'
$SERIAL = Join-Path $BUILD 'serial_debug.log'

# Kill existing
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force

Start-Sleep -Seconds 1

Write-Host "Launching NexusOS UEFI with XHCI+HID..." -ForegroundColor Cyan

Start-Process -FilePath $QEMU -ArgumentList @(
    '-bios', "$BUILD\OVMF.fd",
    '-drive', "file=fat:rw:$BUILD\esp",
    '-drive', "file=$BUILD\data.img,format=raw,media=disk",
    '-m', '512M',
    '-vga', 'std',
    '-device', 'qemu-xhci,id=xhci0',
    '-device', 'usb-mouse,bus=xhci0.0',
    '-device', 'usb-mouse,bus=xhci0.0',
    '-serial', "file:$SERIAL",
    '-no-reboot',
    '-monitor', 'telnet:127.0.0.1:4444,server,nowait',
    '-name', 'NexusOS_UEFI'
)

Write-Host "VM Launched!" -ForegroundColor Green
