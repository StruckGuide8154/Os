param([int]$x, [int]$y)
$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 300
# Move mouse to position (absolute mode)
$w.WriteLine("mouse_move $x $y")
$w.Flush()
Start-Sleep -Milliseconds 200
# Click (button 1 = left)
$w.WriteLine("mouse_button 1")
$w.Flush()
Start-Sleep -Milliseconds 200
# Release
$w.WriteLine("mouse_button 0")
$w.Flush()
Start-Sleep -Milliseconds 200
$c.Close()
