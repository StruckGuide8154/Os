$path = "C:\Users\user\Documents\new\build\test_fat16.ppm"
$bytes = [IO.File]::ReadAllBytes($path)
$headerEnd = 0
$newlines = 0
for ($i = 0; $i -lt 50; $i++) {
    if ($bytes[$i] -eq 10) { $newlines++ }
    if ($newlines -eq 3) { $headerEnd = $i + 1; break }
}
Write-Host "PPM header ends at byte $headerEnd"
Write-Host "File size: $($bytes.Length) bytes"

# Check desktop bg at (100, 100) - should be blue-gray 0x335577 = R=51 G=85 B=119
$offset = $headerEnd + (100 * 1024 + 100) * 3
$r = $bytes[$offset]; $g = $bytes[$offset+1]; $b = $bytes[$offset+2]
Write-Host "Desktop (100,100): R=$r G=$g B=$b (expect R=51 G=85 B=119)"

# Check taskbar at (100, 740) - should be dark 0x1A1A2E = R=26 G=26 B=46
$offset = $headerEnd + (740 * 1024 + 100) * 3
$r = $bytes[$offset]; $g = $bytes[$offset+1]; $b = $bytes[$offset+2]
Write-Host "Taskbar (100,740): R=$r G=$g B=$b (expect R=26 G=26 B=46)"

# Check center (512, 384)
$offset = $headerEnd + (384 * 1024 + 512) * 3
$r = $bytes[$offset]; $g = $bytes[$offset+1]; $b = $bytes[$offset+2]
Write-Host "Center (512,384): R=$r G=$g B=$b"
