$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$ROOT = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$BUILD = Join-Path $ROOT 'build'
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
$qemuArgs = @(
    '-bios', "$BUILD\OVMF.fd",
    '-drive', "format=raw,file=fat:rw:$BUILD\esp",
    '-drive', "file=$BUILD\data.img,format=raw,media=disk",
    '-m', '512M',
    '-vga', 'std',
    '-display', 'sdl',
    '-device', 'qemu-xhci,id=xhci0',
    '-device', 'usb-mouse,bus=xhci0.0,port=1',
    '-device', 'usb-kbd,bus=xhci0.0,port=2',
    '-serial', 'tcp:127.0.0.1:5555,server=on,wait=off',
    '-no-reboot',
    '-name', 'Grit_UEFI_SDL'
)
Start-Process -FilePath $QEMU -ArgumentList $qemuArgs
Write-Host "SDL window launching..." -ForegroundColor Green
