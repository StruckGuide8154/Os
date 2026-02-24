$ppm = [System.IO.File]::ReadAllBytes('build/screen.ppm')
$headerEnd = 0
$nlCount = 0
for ($i = 0; $i -lt [Math]::Min(100, $ppm.Length); $i++) {
    if ($ppm[$i] -eq 10) { $nlCount++ }
    if ($nlCount -eq 3) { $headerEnd = $i + 1; break }
}
$w = 1024; $h = 768
function Get-Pixel($x, $y) {
    $off = $headerEnd + ($y * $w + $x) * 3
    $r = $ppm[$off]; $g = $ppm[$off+1]; $b = $ppm[$off+2]
    return "($r,$g,$b)"
}

# Check if start menu opened
Write-Host "Start menu area (30, 540): $(Get-Pixel 30 540)"
Write-Host "Start menu bg check (100, 580): $(Get-Pixel 100 580)"
# Menu items area
Write-Host "Menu item 1 area (120, 578): $(Get-Pixel 120 578)"
# Taskbar
Write-Host "Taskbar (100, 740): $(Get-Pixel 100 740)"
# Desktop
Write-Host "Desktop (800, 300): $(Get-Pixel 800 300)"
# Menu area colors
$menuBg = Get-Pixel 50 560
Write-Host "Menu bg at (50,560): $menuBg"
$menuBg2 = Get-Pixel 50 600
Write-Host "Menu bg at (50,600): $menuBg2"
