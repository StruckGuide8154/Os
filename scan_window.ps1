# Scan the "before_drag" screenshot to find window titlebar
$bytes = [IO.File]::ReadAllBytes("C:\Users\user\Documents\new\build\before_drag.ppm")
$headerEnd = 0
$newlines = 0
for ($i = 0; $i -lt 50; $i++) {
    if ($bytes[$i] -eq 10) { $newlines++ }
    if ($newlines -eq 3) { $headerEnd = $i + 1; break }
}
Write-Host "Header ends at byte $headerEnd"

# Titlebar color is 0x0055AA (focused) = R=0, G=85, B=170
# Or unfocused 0x555555 = R=85, G=85, B=85
# Scan row by row looking for titlebar blue pixels
for ($y = 0; $y -lt 768; $y += 10) {
    for ($x = 100; $x -lt 800; $x += 50) {
        $offset = $headerEnd + ($y * 1024 + $x) * 3
        $r = $bytes[$offset]
        $g = $bytes[$offset + 1]
        $b = $bytes[$offset + 2]
        # Check for titlebar blue (0x0055AA)
        if ($r -eq 0 -and $g -eq 85 -and $b -eq 170) {
            Write-Host "TITLEBAR BLUE at ($x, $y)"
        }
        # Check for window border (0x333333)
        if ($r -eq 51 -and $g -eq 51 -and $b -eq 51 -and $y -lt 700) {
            Write-Host "WIN BORDER at ($x, $y)"
        }
    }
}

# Also check what's near the menu area
Write-Host ""
Write-Host "--- Menu area scan ---"
foreach ($y in @(620, 630, 640, 650, 660, 670, 680, 690, 700, 710)) {
    $offset = $headerEnd + ($y * 1024 + 80) * 3
    $r = $bytes[$offset]
    $g = $bytes[$offset + 1]
    $b = $bytes[$offset + 2]
    Write-Host "  (80, $y): R=$r G=$g B=$b"
}
