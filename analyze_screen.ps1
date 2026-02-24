$bytes = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\screen.ppm')
# Parse PPM header
$header = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 100)
Write-Host "Header:" $header.Substring(0, 50)

# Find pixel data start (after P6\n<width> <height>\n<maxval>\n)
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

# Sample key areas
Write-Host "Desktop (512,100):" (Get-Pixel 512 100)
Write-Host "Taskbar (512,750):" (Get-Pixel 512 750)
Write-Host "Center  (512,384):" (Get-Pixel 512 384)
Write-Host "(300,200):" (Get-Pixel 300 200)
Write-Host "Icon area (40,50):" (Get-Pixel 40 50)
Write-Host "Start btn (30,740):" (Get-Pixel 30 740)

# Check if there's a window around 250,120 (old notepad position)
Write-Host "Win area (260,130):" (Get-Pixel 260 130)
Write-Host "Win area (260,145):" (Get-Pixel 260 145)
Write-Host "Win area (400,200):" (Get-Pixel 400 200)
