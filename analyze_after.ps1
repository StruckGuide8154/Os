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

Write-Host "=== After keyboard interaction ==="
Write-Host "Desktop (512,100):" (Get-Pixel 512 100)
Write-Host "Taskbar (512,750):" (Get-Pixel 512 750)

# Check various spots for a window
Write-Host ""
Write-Host "=== Checking for window ==="
# Default terminal window pos might be at various places depending on wm_create
# Let's scan broadly
$foundWindow = $false
for ($y = 50; $y -le 500; $y += 25) {
    for ($x = 50; $x -le 800; $x += 50) {
        $offset = $pos + ($y * 1024 + $x) * 3
        $r = $bytes[$offset]; $g = $bytes[$offset+1]; $b = $bytes[$offset+2]
        # Not desktop color (51,85,119) and not taskbar (26,26,46)
        if (-not ($r -eq 51 -and $g -eq 85 -and $b -eq 119) -and -not ($r -eq 0 -and $g -eq 0 -and $b -eq 0)) {
            Write-Host "  Non-desktop pixel at ($x,$y): R=$r G=$g B=$b"
            $foundWindow = $true
        }
    }
}
if (-not $foundWindow) {
    Write-Host "  No window pixels found (all desktop color)"
}

# Check cursor position (should be at ~40, ~130 after moves)
Write-Host ""
Write-Host "=== Cursor area ==="
Write-Host "(40,130):" (Get-Pixel 40 130)
Write-Host "(38,128):" (Get-Pixel 38 128)
Write-Host "(42,132):" (Get-Pixel 42 132)
