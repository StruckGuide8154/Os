$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$buf = New-Object byte[] 4096

Start-Sleep -Milliseconds 500
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true

# Check QEMU version
$w.WriteLine('info version')
Start-Sleep -Milliseconds 1000

# Try writing a mouse byte via D4 command (write to aux device)
# First: send 0xD4 to port 0x64 (write next byte to mouse)
$w.WriteLine('o /b 0x64 0xd4')
Start-Sleep -Milliseconds 200
# Then write 0xEB (read data - mouse should respond with 3 bytes)
$w.WriteLine('o /b 0x60 0xeb')
Start-Sleep -Milliseconds 500

# Check if IRQ12 fired
$w.WriteLine('info irq')
Start-Sleep -Milliseconds 500

# Also check 0x510 counter
$w.WriteLine('xp /4xb 0x510')
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
    if ($trimmed.Length -gt 2 -and $trimmed -notmatch '^\(qemu\)$' -and $trimmed -notmatch '^[a-z] ') {
        Write-Host $trimmed
    }
}

$c.Close()
