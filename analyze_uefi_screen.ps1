$ppm = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\uefi_screen_test.ppm')
# Find pixel data start (after "P6\n1024 768\n255\n")
$headerEnd = 0
$newlines = 0
for ($i = 0; $i -lt 100; $i++) {
    if ($ppm[$i] -eq 10) { $newlines++ }
    if ($newlines -eq 3) { $headerEnd = $i + 1; break }
}
Write-Host "Header ends at byte $headerEnd"
Write-Host "Total bytes: $($ppm.Length)"
Write-Host "Pixel data: $($ppm.Length - $headerEnd) bytes"

# Sample pixels at key locations
$w = 1024; $h = 768
function GetPixel($x, $y) {
    $off = $headerEnd + ($y * $w + $x) * 3
    $r = $ppm[$off]; $g = $ppm[$off+1]; $b = $ppm[$off+2]
    return "($r,$g,$b)"
}

# Check corners and center
Write-Host "Top-left (0,0): $(GetPixel 0 0)"
Write-Host "Center (512,384): $(GetPixel 512 384)"
Write-Host "Bottom-left (0,767): $(GetPixel 0 767)"
Write-Host "Bottom-center (512,760): $(GetPixel 512 760)"
Write-Host "Taskbar area (512,745): $(GetPixel 512 745)"

# Check for desktop color (should be teal/blue)
Write-Host "`nSampling rows:"
foreach ($y in @(10, 100, 300, 500, 700, 740, 750, 760)) {
    Write-Host "  Row $y, x=100: $(GetPixel 100 $y)  x=500: $(GetPixel 500 $y)"
}
