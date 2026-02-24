$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$Args = "-bios build\OVMF.fd -drive file=build\nexus_uefi.img,format=raw -m 512M -vga std -display none -serial file:serial.log"

$p = Start-Process -FilePath $QEMU -ArgumentList $Args -PassThru
Start-Sleep -Seconds 5
Stop-Process -Id $p.Id -Force
Write-Host "QEMU boot done."
Get-Content -Path "serial.log" -Raw | Write-Host
