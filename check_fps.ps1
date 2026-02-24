$ppm = [System.IO.File]::ReadAllBytes('build\test_sse.ppm')
# Find header end (after 'P6\n1024 768\n255\n')
$headerEnd = 0
$nlCount = 0
for ($i = 0; $i -lt 100; $i++) {
    if ($ppm[$i] -eq 10) { $nlCount++ }
    if ($nlCount -eq 3) { $headerEnd = $i + 1; break }
}
Write-Host "Header ends at byte: $headerEnd"

$rowStride = 1024 * 3

# Scan FPS text area for yellow pixels to understand the digit
# FPS text is at y=10, x starts around 10 for "FPS:" and 50 for the number
# Font is 8x16, so digits at y=10..25, number at x=50+

# Create a bitmap of yellow pixels in the FPS number area
Write-Host "`nFPS digit area (x=48..96, y=8..24) - yellow pixel map:"
for ($y = 8; $y -lt 26; $y++) {
    $line = ""
    for ($x = 48; $x -lt 100; $x++) {
        $offset = $headerEnd + ($y * $rowStride) + ($x * 3)
        $r = $ppm[$offset]; $g = $ppm[$offset+1]; $b = $ppm[$offset+2]
        if ($r -gt 200 -and $g -gt 200 -and $b -lt 50) {
            $line += "#"
        } else {
            $line += "."
        }
    }
    Write-Host "y=$($y.ToString('D2')): $line"
}

# Also check the wider area for more digits
Write-Host "`nExtended area (x=48..140, y=10..24):"
for ($y = 10; $y -lt 26; $y++) {
    $line = ""
    for ($x = 48; $x -lt 140; $x++) {
        $offset = $headerEnd + ($y * $rowStride) + ($x * 3)
        $r = $ppm[$offset]; $g = $ppm[$offset+1]; $b = $ppm[$offset+2]
        if ($r -gt 200 -and $g -gt 200 -and $b -lt 50) {
            $line += "#"
        } else {
            $line += "."
        }
    }
    Write-Host "y=$($y.ToString('D2')): $line"
}
