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
    return "R=$r G=$g B=$b"
}

# Check cursor colors
Write-Host "Cursor pixels:"
Write-Host "(36,129):" (Get-Pixel 36 129)
Write-Host "(36,130):" (Get-Pixel 36 130)
Write-Host "(37,130):" (Get-Pixel 37 130)
Write-Host "(37,131):" (Get-Pixel 37 131)
Write-Host "(38,131):" (Get-Pixel 38 131)
Write-Host "(36,132):" (Get-Pixel 36 132)
Write-Host "(37,132):" (Get-Pixel 37 132)
Write-Host "(36,133):" (Get-Pixel 36 133)

# Check mouse_x and mouse_y values by looking at actual cursor position
# Cursor draws at mouse_x, mouse_y
# The cursor hotspot is at top-left
# From the pattern, the cursor tip appears to be at x~36, y~129
# But we expected x=40, y=130 (8*5, 26*5)
Write-Host ""
Write-Host "Expected cursor at (40,130), appears at approximately (36,129)"
Write-Host "Possible: cursor starts at 0,0 and initial position varies"

# Actually, check - did the kp_multiply click work?
# mouse_x should be 40, mouse_y should be 130
# Let's check ICON2 bounds: ICON_X=24, ICON2_Y=108, size=48
# So icon2 box: x=[24,72], y=[108,156], click zone y=[108,176]
# (40,130) IS within terminal icon area!
# But maybe the click didn't fire? Let's check serial log
