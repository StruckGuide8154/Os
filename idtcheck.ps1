$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$buf = New-Object byte[] 4096

Start-Sleep -Milliseconds 500
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$w = New-Object System.IO.StreamWriter($s)
$w.AutoFlush = $true

# Dump IDT entry 44 (mouse) at 0x2002C0 (16 bytes)
$w.WriteLine('xp /16xb 0x2002C0')
Start-Sleep -Milliseconds 1000

# Also dump IDT entry 33 (keyboard) at 0x200210 for comparison
$w.WriteLine('xp /16xb 0x200210')
Start-Sleep -Milliseconds 1000

# Also dump IDT entry 32 (timer) at 0x200200 for comparison
$w.WriteLine('xp /16xb 0x200200')
Start-Sleep -Milliseconds 1000

$all = ""
while ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 4096)
    $all += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}

foreach ($line in ($all -split "`n")) {
    if ($line -match '00000000002') { Write-Host $line.Trim() }
}

$c.Close()
