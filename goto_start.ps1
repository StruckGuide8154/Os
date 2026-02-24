# Move cursor to start button and click it, then click a menu item
$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $c.GetStream()
$w = New-Object System.IO.StreamWriter($s)
Start-Sleep -Milliseconds 300

# Move left 95 times (from 512 to ~37)
for ($i = 0; $i -lt 95; $i++) {
    $w.WriteLine("sendkey kp_4")
    $w.Flush()
}
Start-Sleep -Milliseconds 300

# Move down 72 times (from 384 to ~744)
for ($i = 0; $i -lt 72; $i++) {
    $w.WriteLine("sendkey kp_2")
    $w.Flush()
}
Start-Sleep -Milliseconds 300

# Click (numpad * = left click)
$w.WriteLine("sendkey kp_multiply")
$w.Flush()
Start-Sleep -Milliseconds 500

$c.Close()
Write-Host "Clicked start button"
