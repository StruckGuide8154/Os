$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 500
$w.WriteLine('screendump build/screen.ppm')
$w.Flush()
Start-Sleep -Milliseconds 500
$c.Close()
Write-Host 'Screenshot saved'
