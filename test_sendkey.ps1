# Use sendkey to navigate the OS via keyboard
# When no window is focused: arrows move cursor, * = left click, - = right click
# Desktop icons: My PC at y=24-90, Terminal at y=108-174, Notepad at y=192-258
# Icons are at x=16-72 range
# Mouse starts at 0,0 presumably - need to move to Terminal icon area

param([string]$Action = "open_terminal")

try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 500
    while($s.DataAvailable) { $r.ReadLine() | Out-Null }

    if ($Action -eq "open_terminal") {
        # Move cursor to Terminal icon area (x~40, y~130)
        # Cursor moves 5px per arrow press
        # Move right 8 times = 40px, down 26 times = 130px
        for ($i = 0; $i -lt 8; $i++) {
            $w.WriteLine('sendkey right')
            Start-Sleep -Milliseconds 50
        }
        for ($i = 0; $i -lt 26; $i++) {
            $w.WriteLine('sendkey down')
            Start-Sleep -Milliseconds 50
        }
        Start-Sleep -Milliseconds 200

        # Click with * (kp_multiply)
        $w.WriteLine('sendkey kp_multiply')
        Start-Sleep -Milliseconds 1000
    }
    elseif ($Action -eq "type_ver") {
        # Type "ver" and press Enter
        $w.WriteLine('sendkey v')
        Start-Sleep -Milliseconds 100
        $w.WriteLine('sendkey e')
        Start-Sleep -Milliseconds 100
        $w.WriteLine('sendkey r')
        Start-Sleep -Milliseconds 100
        $w.WriteLine('sendkey ret')
        Start-Sleep -Milliseconds 500
    }
    elseif ($Action -eq "type_dir") {
        $w.WriteLine('sendkey d')
        Start-Sleep -Milliseconds 100
        $w.WriteLine('sendkey i')
        Start-Sleep -Milliseconds 100
        $w.WriteLine('sendkey r')
        Start-Sleep -Milliseconds 100
        $w.WriteLine('sendkey ret')
        Start-Sleep -Milliseconds 500
    }
    elseif ($Action -eq "screendump") {
        $w.WriteLine('screendump build/screen_test.ppm')
        Start-Sleep -Milliseconds 500
    }

    # Always take a screendump
    $w.WriteLine('screendump build/screen_after.ppm')
    Start-Sleep -Milliseconds 500

    $c.Close()
    Write-Host "Done: $Action"
} catch {
    Write-Host "Error: $($_.Exception.Message)"
}
