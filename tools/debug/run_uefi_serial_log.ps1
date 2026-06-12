$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$ROOT = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$BUILD = Join-Path $ROOT 'build'
$LOG = Join-Path $BUILD 'serial.log'
if (Test-Path $LOG) { Remove-Item $LOG -Force }
Get-Process qemu-system-x86_64 -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 1
$qemuArgs = @(
    '-bios', "$BUILD\OVMF.fd",
    '-drive', "format=raw,file=fat:rw:$BUILD\esp",
    '-drive', "file=$BUILD\data.img,format=raw,media=disk",
    '-m', '512M',
    '-vga', 'std',
    '-display', 'none',
    '-device', 'qemu-xhci,id=xhci0',
    '-device', 'usb-mouse,bus=xhci0.0,port=1',
    '-device', 'usb-kbd,bus=xhci0.0,port=2',
    '-serial', "file:$LOG",
    '-monitor', 'telnet:127.0.0.1:4444,server,nowait',
    '-no-reboot',
    '-name', 'GritOS_UEFI'
)
Start-Process -FilePath $QEMU -ArgumentList $qemuArgs -WindowStyle Hidden | Out-Null
Write-Host "QEMU launched, serial -> $LOG"
