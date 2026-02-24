try {
    $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', 4444)
    $s = $c.GetStream()
    $buf = New-Object byte[] 4096

    # Read welcome
    Start-Sleep -Milliseconds 500
    if ($s.DataAvailable) { $null = $s.Read($buf, 0, 4096) }

    # Send info mice
    $cmd = [System.Text.Encoding]::ASCII.GetBytes("info mice`r`n")
    $s.Write($cmd, 0, $cmd.Length)
    $s.Flush()
    Start-Sleep -Milliseconds 1000
    if ($s.DataAvailable) {
        $n = $s.Read($buf, 0, 4096)
        $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        $resp = $resp -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x08', ''
        Write-Host "=== MICE ===`n$resp"
    }

    # Switch to mouse index 2 (PS/2 Mouse)
    $cmd = [System.Text.Encoding]::ASCII.GetBytes("mouse_set 2`r`n")
    $s.Write($cmd, 0, $cmd.Length)
    $s.Flush()
    Start-Sleep -Milliseconds 300

    # Verify
    $cmd = [System.Text.Encoding]::ASCII.GetBytes("info mice`r`n")
    $s.Write($cmd, 0, $cmd.Length)
    $s.Flush()
    Start-Sleep -Milliseconds 500
    if ($s.DataAvailable) {
        $n = $s.Read($buf, 0, 4096)
        $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        $resp = $resp -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x08', ''
        Write-Host "=== AFTER SET ===`n$resp"
    }

    # Send mouse moves
    for ($i = 0; $i -lt 30; $i++) {
        $cmd = [System.Text.Encoding]::ASCII.GetBytes("mouse_move 500 -300`r`n")
        $s.Write($cmd, 0, $cmd.Length)
        $s.Flush()
        Start-Sleep -Milliseconds 30
    }

    $c.Close()
    Write-Host "Done"
} catch {
    Write-Host "Error: $($_.Exception.Message)"
}
