$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$buf = New-Object byte[] 4096

Start-Sleep -Milliseconds 500
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true

# Check counter before
$w.WriteLine('xp /4xb 0x510')
Start-Sleep -Milliseconds 1000
$all = ""
while ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 4096)
    $all += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}
Write-Host "BEFORE mouse_move:"
foreach ($line in ($all -split "`n")) {
    if ($line -match '0000000000000510') { Write-Host $line.Trim() }
}

# Send mouse movements
$w.WriteLine('mouse_move 50 0')
Start-Sleep -Milliseconds 200
$w.WriteLine('mouse_move 50 0')
Start-Sleep -Milliseconds 200
$w.WriteLine('mouse_move 50 0')
Start-Sleep -Milliseconds 500

# Flush
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

# Check counter after
$w.WriteLine('xp /4xb 0x510')
Start-Sleep -Milliseconds 1000
$all = ""
while ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 4096)
    $all += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}
Write-Host "AFTER mouse_move:"
foreach ($line in ($all -split "`n")) {
    if ($line -match '0000000000000510') { Write-Host $line.Trim() }
}

$c.Close()
