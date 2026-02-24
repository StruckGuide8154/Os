# Send specific test keys: 'a', then arrow right, then kp_multiply
try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 500
    while($s.DataAvailable) { $r.ReadLine() | Out-Null }

    # Wait a bit for the system to settle
    Start-Sleep -Seconds 2

    # Send 'a' key
    $w.WriteLine('sendkey a')
    Start-Sleep -Milliseconds 500

    # Send arrow right
    $w.WriteLine('sendkey right')
    Start-Sleep -Milliseconds 500

    # Send kp_multiply
    $w.WriteLine('sendkey kp_multiply')
    Start-Sleep -Milliseconds 500

    # Screendump
    $w.WriteLine('screendump build/screen_keys.ppm')
    Start-Sleep -Milliseconds 500

    $c.Close()
    Write-Host "Done - sent test keys"
} catch {
    Write-Host "Error: $($_.Exception.Message)"
}
