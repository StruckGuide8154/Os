$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$w = New-Object System.IO.StreamWriter($s)
$r = New-Object System.IO.StreamReader($s)
Start-Sleep -Seconds 5
$w.WriteLine('screendump C:/Users/user/Documents/new/build/uefi_screen_test.ppm')
$w.Flush()
Start-Sleep -Milliseconds 1000
$w.Close()
$c.Close()
Write-Host 'Screenshot taken'
