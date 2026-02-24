$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()

Start-Sleep -Milliseconds 500
$buf = New-Object byte[] 4096
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

# Send mouse event via QEMU - move mouse
$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true
$w.WriteLine('mouse_move 10 10')
Start-Sleep -Milliseconds 500
$w.WriteLine('mouse_move 10 10')
Start-Sleep -Milliseconds 500
$w.WriteLine('mouse_move 10 10')
Start-Sleep -Milliseconds 1000

# Flush previous response
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

# Now check mouse_moved flag and mouse_x/y
# First let me check 0x500 area (init status) and then find mouse vars
# Let me just send sendkey to test keyboard too
$w.WriteLine('sendkey kp_multiply')
Start-Sleep -Milliseconds 500

# Read IRQ debug: check if mouse handler stored 'M' at 0x510
# Actually, let me dump a wider area to find mouse state
$w.WriteLine('xp /32xb 0x500')
Start-Sleep -Milliseconds 1500

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
# Find hex dump lines
foreach ($line in ($printable -split "`n")) {
    if ($line -match '00000000005') { Write-Host $line }
}

$c.Close()
