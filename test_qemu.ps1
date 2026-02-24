$qemu = "C:\Program Files\qemu\qemu-system-x86_64.exe"
$proc = Start-Process $qemu -ArgumentList "-bios build/OVMF.fd -drive file=fat:rw:build\esp -m 512M -vga std -serial file:build/serial.log -monitor telnet:127.0.0.1:4444,server,nowait" -PassThru -WorkingDirectory "C:\Users\user\Documents\new"
Start-Sleep -Seconds 90
try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1',4444)
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
    Write-Host $_.Exception.Message
}
if (!$proc.HasExited) { Start-Sleep -Seconds 2; if (!$proc.HasExited) { $proc.Kill() } }
