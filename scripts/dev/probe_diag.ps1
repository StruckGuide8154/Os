$c = [Net.Sockets.TcpClient]::new()
$c.Connect('127.0.0.1', 5555)
$s = $c.GetStream()
$buf = New-Object byte[] 16384

# drain initial boot output
$end = (Get-Date).AddSeconds(8)
$pre = ''
while ((Get-Date) -lt $end) {
    if ($s.DataAvailable) {
        $n = $s.Read($buf, 0, $buf.Length)
        $pre += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } else { Start-Sleep -Milliseconds 100 }
}
Write-Host "---PREDRAIN $($pre.Length) bytes"

# send '='
$eq = [byte[]]@(0x3D)
$s.Write($eq, 0, 1)
$s.Flush()

# collect response
$end = (Get-Date).AddSeconds(6)
$resp = ''
while ((Get-Date) -lt $end) {
    if ($s.DataAvailable) {
        $n = $s.Read($buf, 0, $buf.Length)
        $resp += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } else { Start-Sleep -Milliseconds 100 }
}
Write-Host "---AFTER ="
Write-Host $resp
$c.Close()
