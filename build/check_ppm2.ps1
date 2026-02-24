$b = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\uefi_screen2.ppm')
$header = [System.Text.Encoding]::ASCII.GetString($b, 0, 60)
Write-Host "Header: $header"

$nl = 0; $dataStart = 0
for ($i = 0; $i -lt 200; $i++) {
    if ($b[$i] -eq 10) { $nl++; if ($nl -eq 3) { $dataStart = $i + 1; break } }
}
Write-Host "Data starts at byte: $dataStart"
$mid = $dataStart + (1024 * 384 + 512) * 3
Write-Host "Center pixel RGB: $($b[$mid]) $($b[$mid+1]) $($b[$mid+2])"
Write-Host "Top-left pixel RGB: $($b[$dataStart]) $($b[$dataStart+1]) $($b[$dataStart+2])"

# Sample a grid of pixels
for ($y = 0; $y -lt 768; $y += 192) {
    for ($x = 0; $x -lt 1024; $x += 256) {
        $off = $dataStart + ($y * 1024 + $x) * 3
        Write-Host "Pixel ($x,$y): $($b[$off]) $($b[$off+1]) $($b[$off+2])"
    }
}
