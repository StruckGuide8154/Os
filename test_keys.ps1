# Try mouse_set to move cursor to absolute position, then click
try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 500
    while($s.DataAvailable) { $r.ReadLine() | Out-Null }

    # Try mouse_set (absolute positioning)
    $w.WriteLine('mouse_set 40 120 1')
    Start-Sleep -Milliseconds 300

    # Read any output
    Start-Sleep -Milliseconds 200
    while($s.DataAvailable) {
        $line = $r.ReadLine()
        Write-Host "QEMU: $line"
    }

    # Try mouse_button
    $w.WriteLine('mouse_button 1')
    Start-Sleep -Milliseconds 300
    $w.WriteLine('mouse_button 0')
    Start-Sleep -Milliseconds 500

    while($s.DataAvailable) {
        $line = $r.ReadLine()
        Write-Host "QEMU: $line"
    }

    # Screendump
    $w.WriteLine('screendump build/screen3.ppm')
    Start-Sleep -Milliseconds 500

    $c.Close()
    Write-Host "Done"
} catch {
    Write-Host "Error: $($_.Exception.Message)"
}
