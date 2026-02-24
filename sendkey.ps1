param([string]$cmd)
$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 300
$w.WriteLine($cmd)
$w.Flush()
Start-Sleep -Milliseconds 300
$c.Close()
