Remove-Item "build\serial.log" -ErrorAction SilentlyContinue

$qemu = "C:\Program Files\qemu\qemu-system-x86_64.exe"
$args_list = @(
    "-bios", "build\OVMF.fd",
    "-drive", "format=raw,file=fat:rw:build\esp",
    "-drive", "format=raw,file=build\data.img,if=ide,index=1",
    "-m", "256M",
    "-vga", "std",
    "-serial", "file:build\serial.log",
    "-display", "sdl"
)

$proc = Start-Process -FilePath $qemu -ArgumentList $args_list -PassThru
Start-Sleep 10
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep 1

if (Test-Path "build\serial.log") {
    Get-Content "build\serial.log"
} else {
    Write-Host "No serial log generated"
}
