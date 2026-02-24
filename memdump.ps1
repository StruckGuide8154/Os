$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()

Start-Sleep -Milliseconds 500
$buf = New-Object byte[] 4096
while ($s.DataAvailable) { $s.Read($buf, 0, 4096) | Out-Null }

$cmd = [System.Text.Encoding]::ASCII.GetBytes("xp /16xb 0x500`r`n")
$s.Write($cmd, 0, $cmd.Length)
Start-Sleep -Milliseconds 2000

$all = ""
while ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 4096)
    $all += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}

# Just dump raw, replacing control chars with dots
$printable = ""
foreach ($ch in $all.ToCharArray()) {
    $code = [int]$ch
    if ($code -ge 32 -and $code -le 126) {
        $printable += $ch
    } elseif ($code -eq 10) {
        $printable += "`n"
    } else {
        $printable += '.'
    }
}
Write-Host $printable

$c.Close()
