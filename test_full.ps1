param([string]$Action = "screendump")

try {
    $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $s = $c.GetStream()
    $r = New-Object System.IO.StreamReader($s)
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 500
    while($s.DataAvailable) { $r.ReadLine() | Out-Null }

    switch ($Action) {
        "screendump" {
            $w.WriteLine('screendump build/screen_test.ppm')
            Start-Sleep -Milliseconds 500
        }
        "open_terminal" {
            # Move cursor to Terminal icon: x~40, y~130
            # From center (512, 384), we need to move left and up
            # Actually cursor starts at center after boot, move to terminal icon
            # Terminal icon at ICON_X=24, ICON2_Y=108, size=48
            # We need to navigate there with arrows (5px per step)
            # But first let's just use mouse_move which sends relative movement
            # Move mouse to known position first
            for ($i = 0; $i -lt 50; $i++) {
                $w.WriteLine('sendkey down')
                Start-Sleep -Milliseconds 30
            }
            Start-Sleep -Milliseconds 200
            for ($i = 0; $i -lt 50; $i++) {
                $w.WriteLine('sendkey left')
                Start-Sleep -Milliseconds 30
            }
            Start-Sleep -Milliseconds 200
            # Now we should be at bottom-left corner (0, 634)
            # Move to terminal icon: right 8 (40px), up 101 (505px -> y=634-505=129)
            for ($i = 0; $i -lt 8; $i++) {
                $w.WriteLine('sendkey right')
                Start-Sleep -Milliseconds 30
            }
            Start-Sleep -Milliseconds 100
            for ($i = 0; $i -lt 101; $i++) {
                $w.WriteLine('sendkey up')
                Start-Sleep -Milliseconds 30
            }
            Start-Sleep -Milliseconds 200
            # Click
            $w.WriteLine('sendkey kp_multiply')
            Start-Sleep -Milliseconds 1000
            $w.WriteLine('screendump build/screen_test.ppm')
            Start-Sleep -Milliseconds 500
        }
        "type" {
            # Type the text passed as second arg
            $text = $args[0]
            if (-not $text) { $text = "ver" }
            foreach ($ch in $text.ToCharArray()) {
                if ($ch -eq ' ') {
                    $w.WriteLine('sendkey spc')
                } else {
                    $w.WriteLine("sendkey $ch")
                }
                Start-Sleep -Milliseconds 80
            }
            Start-Sleep -Milliseconds 200
            $w.WriteLine('screendump build/screen_test.ppm')
            Start-Sleep -Milliseconds 500
        }
        "enter" {
            $w.WriteLine('sendkey ret')
            Start-Sleep -Milliseconds 500
            $w.WriteLine('screendump build/screen_test.ppm')
            Start-Sleep -Milliseconds 500
        }
        "numlock" {
            $w.WriteLine('sendkey num_lock')
            Start-Sleep -Milliseconds 200
        }
    }

    $c.Close()
    Write-Host "Done: $Action"
} catch {
    Write-Host "Error: $($_.Exception.Message)"
}
