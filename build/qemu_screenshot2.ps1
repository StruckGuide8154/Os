Start-Sleep -Seconds 12
$t = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4446)
$s = $t.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 500
$w.WriteLine('screendump C:/Users/user/Documents/new/build/uefi_screen2.ppm')
$w.Flush()
Start-Sleep -Milliseconds 1000
$w.WriteLine('quit')
$w.Flush()
Start-Sleep -Milliseconds 500
$t.Close()
