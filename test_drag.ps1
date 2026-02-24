$t = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
$s = $t.GetStream()
$w = New-Object System.IO.StreamWriter($s)
$r = New-Object System.IO.StreamReader($s)
Start-Sleep -Milliseconds 500

# Click on Start button (approx x=35, y=748)
$w.WriteLine("mouse_move 35 748")
$w.Flush()
Start-Sleep -Milliseconds 200
$w.WriteLine("mouse_button 1")
$w.Flush()
Start-Sleep -Milliseconds 200
$w.WriteLine("mouse_button 0")
$w.Flush()
Start-Sleep -Milliseconds 500

# Click on "Terminal" menu item (3rd item, approx x=80, y=660)
$w.WriteLine("mouse_move 80 660")
$w.Flush()
Start-Sleep -Milliseconds 200
$w.WriteLine("mouse_button 1")
$w.Flush()
Start-Sleep -Milliseconds 200
$w.WriteLine("mouse_button 0")
$w.Flush()
Start-Sleep -Milliseconds 500

# Take screenshot to see the window
$w.WriteLine("screendump C:/Users/user/Documents/new/build/before_drag.ppm")
$w.Flush()
Start-Sleep -Milliseconds 500

# Now click on the window's titlebar to start drag (window should be near center)
# Terminal window is typically at x=200, y=150, titlebar at ~y=160
$w.WriteLine("mouse_move 350 160")
$w.Flush()
Start-Sleep -Milliseconds 200
$w.WriteLine("mouse_button 1")
$w.Flush()
Start-Sleep -Milliseconds 200
$w.WriteLine("mouse_button 0")
$w.Flush()
Start-Sleep -Milliseconds 500

# Move mouse to new position (should show outline)
$w.WriteLine("mouse_move 500 300")
$w.Flush()
Start-Sleep -Milliseconds 500

# Take screenshot (should see outline)
$w.WriteLine("screendump C:/Users/user/Documents/new/build/during_drag.ppm")
$w.Flush()
Start-Sleep -Milliseconds 500

# Click to place
$w.WriteLine("mouse_button 1")
$w.Flush()
Start-Sleep -Milliseconds 200
$w.WriteLine("mouse_button 0")
$w.Flush()
Start-Sleep -Milliseconds 500

# Screenshot after placement
$w.WriteLine("screendump C:/Users/user/Documents/new/build/after_drag.ppm")
$w.Flush()
Start-Sleep -Milliseconds 500

$t.Close()
Write-Host "Test complete - check serial log and screenshots"
