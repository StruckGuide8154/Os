Start-Sleep -Seconds 4
$t = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $t.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 500
$w.WriteLine("screendump C:/Users/user/Documents/new/build/test_fat16.ppm")
$w.Flush()
Start-Sleep -Milliseconds 1000
$t.Close()
Write-Host "Screenshot taken"
