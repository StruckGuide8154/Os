$qemu = "C:\Program Files\qemu\qemu-system-x86_64.exe"
Remove-Item -Force "C:\Users\user\Documents\new\build\serial.log" -ErrorAction SilentlyContinue

$args = @(
    "-bios", "build/OVMF.fd",
    "-drive", "file=fat:rw:build\esp,format=raw",
    "-m", "8G",
    "-cpu", "EPYC-v4",
    "-smp", "4",
    "-vga", "virtio",
    "-serial", "file:build/serial.log",
    "-monitor", "telnet:127.0.0.1:4444,server,nowait",
    "-no-reboot"
)

$proc = Start-Process $qemu -ArgumentList $args -PassThru -WorkingDirectory "C:\Users\user\Documents\new"
Write-Host "Waiting 120s for QEMU EPYC..."
Start-Sleep -Seconds 120

try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $s = $c.GetStream()
    $w = New-Object System.IO.StreamWriter($s)
    Start-Sleep -Milliseconds 500
    $w.WriteLine('screendump build/screen.ppm')
    $w.Flush()
    Start-Sleep -Milliseconds 1000
    $w.WriteLine('quit')
    $w.Flush()
    Start-Sleep -Milliseconds 500
    $c.Close()
} catch {
    Write-Host "Monitor error: $($_.Exception.Message)"
}

Start-Sleep -Seconds 2
if (!$proc.HasExited) { $proc.Kill() }

Write-Host "`n=== SERIAL LOG ==="
if (Test-Path "C:\Users\user\Documents\new\build\serial.log") {
    Get-Content "C:\Users\user\Documents\new\build\serial.log"
} else {
    Write-Host "No serial log!"
}
