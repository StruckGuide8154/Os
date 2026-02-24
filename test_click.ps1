try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 500
    while($s.DataAvailable) { $r.ReadLine() | Out-Null }

    # Click on Terminal desktop icon (x=40, y=120)
    $w.WriteLine('mouse_move 40 120')
    Start-Sleep -Milliseconds 300
    $w.WriteLine('mouse_button 1')
    Start-Sleep -Milliseconds 200
    $w.WriteLine('mouse_button 0')
    Start-Sleep -Milliseconds 1000

    # Take screendump
    $w.WriteLine('screendump build/screen2.ppm')
    Start-Sleep -Milliseconds 500
    $c.Close()
    Write-Host "Done - clicked terminal icon"
} catch {
    Write-Host "Error: $($_.Exception.Message)"
}
