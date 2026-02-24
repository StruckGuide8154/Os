$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$buf = New-Object byte[] 4096

Start-Sleep -Milliseconds 500
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true

# Try mouse_button press/release
$w.WriteLine('mouse_button 1')
Start-Sleep -Milliseconds 200
$w.WriteLine('mouse_button 0')
Start-Sleep -Milliseconds 200
$w.WriteLine('mouse_move 100 100')
Start-Sleep -Milliseconds 200
$w.WriteLine('mouse_move -100 -100')
Start-Sleep -Milliseconds 1000

while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w.WriteLine('xp /4xb 0x510')
Start-Sleep -Milliseconds 500
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
    if ($trimmed -match '0000000000000510|IRQ|^\d+:') { Write-Host $trimmed }
}

$c.Close()
