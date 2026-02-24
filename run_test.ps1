Remove-Item 'build\serial_test.log' -Force -ErrorAction SilentlyContinue
$qemu = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$qargs = @('-machine','q35','-m','256','-bios','build\OVMF.fd',
           '-drive','format=raw,file=fat:rw:build\esp',
           '-serial','file:build\serial_test.log',
           '-vga','std','-no-reboot')
$p = Start-Process $qemu -ArgumentList $qargs -PassThru
Start-Sleep 9
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Start-Sleep 1
Get-Content 'build\serial_test.log' -ErrorAction SilentlyContinue
