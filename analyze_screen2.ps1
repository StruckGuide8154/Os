$bytes = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\screen2.ppm')
$header = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 50)
Write-Host "Header:" $header.Substring(0, 30)

$pos = 0
$newlines = 0
while ($newlines -lt 3 -and $pos -lt 100) {
    if ($bytes[$pos] -eq 10) { $newlines++ }
    $pos++
}
Write-Host "Pixel data starts at byte: $pos"

function Get-Pixel($x, $y) {
    $offset = $pos + ($y * 1024 + $x) * 3
    $r = $bytes[$offset]; $g = $bytes[$offset+1]; $b = $bytes[$offset+2]
    return "R=$r G=$g B=$b"
}

# Check desktop area
Write-Host "Desktop (512,100):" (Get-Pixel 512 100)

# Check if a window appeared (Terminal window starts at x=120, y=80 default)
# Check typical window positions
Write-Host ""
Write-Host "=== Window check ==="
# Window titlebar area (if created at default position ~120,80)
Write-Host "Titlebar (200,85):" (Get-Pixel 200 85)
Write-Host "Titlebar (300,85):" (Get-Pixel 300 85)
Write-Host "Client  (200,110):" (Get-Pixel 200 110)
Write-Host "Client  (300,200):" (Get-Pixel 300 200)
Write-Host "Client  (400,300):" (Get-Pixel 400 300)

# Check if there's a terminal prompt visible (dark bg in window client area)
# Terminal bg should be 0x1A1A2E (R=26 G=26 B=46)
Write-Host ""
Write-Host "=== Terminal BG check ==="
for ($y = 100; $y -le 400; $y += 50) {
    for ($x = 150; $x -le 600; $x += 100) {
        $pixel = Get-Pixel $x $y
        Write-Host "  ($x,$y): $pixel"
    }
}

# Taskbar
Write-Host ""
Write-Host "Taskbar (512,750):" (Get-Pixel 512 750)
Write-Host "Start (30,740):" (Get-Pixel 30 740)
