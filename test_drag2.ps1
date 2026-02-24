$t = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $t.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 500

# Wait for boot
Start-Sleep -Seconds 4

# Simple test - just move mouse and click
$w.WriteLine("mouse_move 400 400")
$w.Flush()
Start-Sleep -Milliseconds 500

$w.WriteLine("mouse_button 1")
$w.Flush()
Start-Sleep -Milliseconds 300

$w.WriteLine("mouse_button 0")
$w.Flush()
Start-Sleep -Milliseconds 500

$w.WriteLine("mouse_move 500 400")
$w.Flush()
Start-Sleep -Milliseconds 500

$t.Close()
Write-Host "Done"
