$b = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\uefi_screen.ppm')
$header = [System.Text.Encoding]::ASCII.GetString($b, 0, 60)
Write-Host "Header: $header"

# Find data start (after 3 newlines in PPM P6 format)
$nl = 0
$dataStart = 0
for ($i = 0; $i -lt 200; $i++) {
    if ($b[$i] -eq 10) {
        $nl++
        if ($nl -eq 3) { $dataStart = $i + 1; break }
    }
}
Write-Host "Data starts at byte: $dataStart"

# Check center pixel (row 384, col 512)
$mid = $dataStart + (1024 * 384 + 512) * 3
Write-Host "Center pixel RGB: $($b[$mid]) $($b[$mid+1]) $($b[$mid+2])"

# Check top-left
Write-Host "Top-left pixel RGB: $($b[$dataStart]) $($b[$dataStart+1]) $($b[$dataStart+2])"

# Check 100 pixels across center row
$allWhite = $true
for ($x = 0; $x -lt 100; $x++) {
    $off = $dataStart + (1024 * 384 + $x * 10) * 3
    if ($b[$off] -ne 255 -or $b[$off+1] -ne 255 -or $b[$off+2] -ne 255) {
        $allWhite = $false
        Write-Host "Non-white pixel at x=$($x*10): $($b[$off]) $($b[$off+1]) $($b[$off+2])"
        break
    }
}
if ($allWhite) { Write-Host "Center row: ALL WHITE - kernel entry confirmed!" }
