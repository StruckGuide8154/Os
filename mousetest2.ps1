$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$buf = New-Object byte[] 4096

Start-Sleep -Milliseconds 500
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true

# Send several mouse moves
for ($i = 0; $i -lt 5; $i++) {
    $w.WriteLine('mouse_move 10 0')
    Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 1000

while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

# Check IRQ counter and also info irq
$w.WriteLine('xp /4xb 0x510')
Start-Sleep -Milliseconds 1000
$all = ""
while ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 4096)
    $all += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}
Write-Host "IRQ12 counter at 0x510:"
foreach ($line in ($all -split "`n")) {
    if ($line -match '0000000000000510') { Write-Host $line.Trim() }
}

# Also check info irq
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
Write-Host "IRQ stats:"
foreach ($line in ($printable -split "`n")) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -gt 2 -and $trimmed -notmatch '^\(qemu\)' -and $trimmed -notmatch '^x') {
        Write-Host $trimmed
    }
}

$c.Close()
