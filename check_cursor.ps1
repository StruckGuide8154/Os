$bytes = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\screen_after.ppm')
$pos = 0
$newlines = 0
while ($newlines -lt 3 -and $pos -lt 100) {
    if ($bytes[$pos] -eq 10) { $newlines++ }
    $pos++
}

function Get-Pixel($x, $y) {
    $offset = $pos + ($y * 1024 + $x) * 3
    $r = $bytes[$offset]; $g = $bytes[$offset+1]; $b = $bytes[$offset+2]
    return @($r, $g, $b)
}

# Find cursor - it should be white or light colored, scan area around expected position
Write-Host "=== Scanning 0-80 x 0-200 for non-desktop, non-icon colors ==="
$desktopR = 51; $desktopG = 85; $desktopB = 119
$iconYellow = @(204, 170, 68)
$iconDarkTab = @(170, 136, 34)
$iconDark = @(34, 34, 34)
$iconWhite = @(255, 255, 255)
$iconCC = @(204, 204, 204)

for ($y = 0; $y -le 200; $y += 2) {
    for ($x = 0; $x -le 80; $x += 2) {
        $p = Get-Pixel $x $y
        $r = $p[0]; $g = $p[1]; $b = $p[2]
        # Skip desktop color
        if ($r -eq $desktopR -and $g -eq $desktopG -and $b -eq $desktopB) { continue }
        # Skip icon colors we know
        if ($r -eq 204 -and $g -eq 170 -and $b -eq 68) { continue }  # yellow
        if ($r -eq 170 -and $g -eq 136 -and $b -eq 34) { continue }  # dark yellow tab
        if ($r -eq 34 -and $g -eq 34 -and $b -eq 34) { continue }    # dark terminal icon
        if ($r -eq 255 -and $g -eq 255 -and $b -eq 255) { continue } # white notepad
        if ($r -eq 204 -and $g -eq 204 -and $b -eq 204) { continue } # notepad lines
        if ($r -eq 0 -and $g -eq 255 -and $b -eq 0) { continue }     # green prompt
        Write-Host "  ($x,$y): R=$r G=$g B=$b (cursor?)"
    }
}

# Also check mouse_x/mouse_y by examining the actual cursor sprite
Write-Host ""
Write-Host "=== Row-by-row scan at x=38-42, y=126-136 ==="
for ($y = 126; $y -le 136; $y++) {
    $line = ""
    for ($x = 36; $x -le 46; $x++) {
        $p = Get-Pixel $x $y
        $r = $p[0]; $g = $p[1]; $b = $p[2]
        if ($r -eq $desktopR -and $g -eq $desktopG -and $b -eq $desktopB) {
            $line += "."
        } elseif ($r -eq 34 -and $g -eq 34 -and $b -eq 34) {
            $line += "#"  # Terminal icon dark
        } else {
            $line += "X"  # Something else (cursor?)
        }
    }
    Write-Host "  y=$y : $line"
}
