# Send commands to QEMU monitor
# Usage: qcmd.ps1 "command1" "command2" ...
param([Parameter(ValueFromRemainingArguments)]$commands)

try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $s = $c.GetStream()
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 300
    # Drain prompt
    while($s.DataAvailable) { $s.ReadByte() | Out-Null }

    foreach ($cmd in $commands) {
        $w.WriteLine($cmd)
        Start-Sleep -Milliseconds 100
    }

    Start-Sleep -Milliseconds 500
    $c.Close()
} catch {
    Write-Host "Error: $($_.Exception.Message)"
}
