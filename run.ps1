$ErrorActionPreference = 'Stop'
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$FW   = 'C:\Program Files\qemu\share\edk2-x86_64-code.fd'
$ESP  = (Join-Path $PSScriptRoot 'build\esp')
$DATA = (Join-Path $PSScriptRoot 'build\data.img')

Write-Host 'Booting NexusOS in QEMU...' -ForegroundColor Cyan
& $QEMU `
    -drive "if=pflash,format=raw,readonly=on,file=$FW" `
    -drive "file=fat:rw:$ESP,if=ide,index=0" `
    -drive "file=$DATA,format=raw,if=ide,index=1" `
    -m 512M `
    -net none `
    -vga std `
    -serial file:build/serial.log `
    -monitor tcp:127.0.0.1:4444,server,nowait `
    -name NexusOS
