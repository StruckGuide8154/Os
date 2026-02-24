$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$buf = New-Object byte[] 4096

Start-Sleep -Milliseconds 500
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true

# Read 8042 status register (port 0x64)
$w.WriteLine('i /b 0x64')
Start-Sleep -Milliseconds 500

# Send command 0x20 to read controller config byte
$w.WriteLine('o /b 0x64 0x20')
Start-Sleep -Milliseconds 500

# Read data port (config byte)
$w.WriteLine('i /b 0x60')
Start-Sleep -Milliseconds 500

# Also check info mice
$w.WriteLine('info mice')
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
    if ($trimmed.Length -gt 2 -and $trimmed -notmatch '^\(qemu\)$') {
        Write-Host $trimmed
    }
}

$c.Close()
