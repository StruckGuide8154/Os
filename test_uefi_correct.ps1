$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$BUILD = Join-Path $PSScriptRoot 'build'
$SERIAL = Join-Path $PSScriptRoot 'serial_verify.log'

# Kill existing
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host "Launching..."
$p = Start-Process -FilePath $QEMU -ArgumentList @(
    '-bios', "$BUILD\OVMF.fd",
    '-drive', "file=fat:rw:$BUILD\esp",
    '-drive', "file=$BUILD\data.img,format=raw,media=disk",
    '-m', '512M',
    '-vga', 'std',
    '-device', 'qemu-xhci',
    '-device', 'usb-mouse',
    '-serial', "file:$SERIAL",
    '-no-reboot',
    '-display', 'none'
) -PassThru

Start-Sleep -Seconds 5
Stop-Process -Id $p.Id -Force
Write-Host "Done."
if (Test-Path $SERIAL) {
    Get-Content $SERIAL -Raw | Write-Host
} else {
    Write-Host "Log file not found."
}
