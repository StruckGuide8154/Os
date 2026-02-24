param([string[]]$keys)
$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 300
foreach ($k in $keys) {
    $w.WriteLine("sendkey $k")
    $w.Flush()
    Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 200
$c.Close()
