$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$buf = New-Object byte[] 4096

Start-Sleep -Milliseconds 500
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true

# Try mouse_set to ensure PS/2 is active
$w.WriteLine('mouse_set 2')
Start-Sleep -Milliseconds 500

# info mice again
$w.WriteLine('info mice')
Start-Sleep -Milliseconds 500

# Send mouse moves
for ($i = 0; $i -lt 10; $i++) {
    $w.WriteLine('mouse_move 10 0')
    Start-Sleep -Milliseconds 50
}
Start-Sleep -Milliseconds 1000

while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

# Check IRQ counter
$w.WriteLine('xp /4xb 0x510')
Start-Sleep -Milliseconds 1000
$all = ""
while ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 4096)
    $all += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}
Write-Host "IRQ12 counter:"
foreach ($line in ($all -split "`n")) {
    if ($line -match '0000000000000510') { Write-Host $line.Trim() }
}

# Info irq
$w.WriteLine('info irq')
Start-Sleep -Milliseconds 1000
$all = ""
while ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 4096)
    $all += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}
$printable = ""
foreach ($ch in $all.ToCharArray()) {
    $code = [int]$ch
    if ($code -ge 32 -and $code -le 126) { $printable += $ch }
    elseif ($code -eq 10) { $printable += "`n" }
}
foreach ($line in ($printable -split "`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\d+:' -or $trimmed -match 'IRQ') { Write-Host $trimmed }
}

$c.Close()
