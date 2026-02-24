$ppm = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\uefi_screen_test.ppm')

# Find start of pixel data (header: P6\n1024 768\n255\n)
$offset = 0
$newlines = 0
for ($i = 0; $i -lt 100; $i++) {
    if ($ppm[$i] -eq 10) { $newlines++ }
    if ($newlines -eq 3) { $offset = $i + 1; break }
}

$width = 1024
$height = 768
$greenCount = 0
$blackCount = 0

# Check debug area (y=40 to y=200, x=10 to x=300)
for ($y = 40; $y -lt 200; $y++) {
    for ($x = 10; $x -lt 300; $x++) {
        $idx = $offset + ($y * $width + $x) * 3
        $r = $ppm[$idx]
        $g = $ppm[$idx+1]
        $b = $ppm[$idx+2]
        
        # Check for pure Green (0, 255, 0)
        if ($r -eq 0 -and $g -eq 255 -and $b -eq 0) {
            $greenCount++
        }
        # Check for Black (0, 0, 0)
        if ($r -eq 0 -and $g -eq 0 -and $b -eq 0) {
            $blackCount++
        }
    }
}

Write-Host "Debug Area Analysis:"
Write-Host "Green pixels: $greenCount"
Write-Host "Black pixels: $blackCount"

if ($greenCount -gt 50 -and $blackCount -gt 1000) {
    Write-Host "DEBUG PRINTS CONFIRMED!" -ForegroundColor Green
} else {
    Write-Host "NO DEBUG PRINTS FOUND. Screen might be blank or different color." -ForegroundColor Red
}
