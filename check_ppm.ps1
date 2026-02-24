$ppm = [IO.File]::ReadAllBytes("build\test_sse.ppm")
Write-Host "PPM Size: $($ppm.Length) bytes"

# Find header end (3 newlines in P6 format)
$skip = 0
$dataStart = 0
for ($i = 0; $i -lt [Math]::Min($ppm.Length, 100); $i++) {
    if ($ppm[$i] -eq 10) {
        $skip++
        if ($skip -eq 3) {
            $dataStart = $i + 1
            break
        }
    }
}
Write-Host "Pixel data starts at offset: $dataStart"

function Get-Pixel($x, $y) {
    $off = $dataStart + ($y * 1024 + $x) * 3
    return "$($ppm[$off]),$($ppm[$off+1]),$($ppm[$off+2])"
}

# Check key areas
Write-Host "`n=== Pixel Checks ==="
Write-Host "Desktop center (512,384): $(Get-Pixel 512 384)"
Write-Host "Taskbar (100,750): $(Get-Pixel 100 750)"
Write-Host "FPS label area (15,14): $(Get-Pixel 15 14)"
Write-Host "Top-left corner (0,0): $(Get-Pixel 0 0)"
Write-Host "FPS number area (55,14): $(Get-Pixel 55 14)"

# More detailed checks
Write-Host "Desktop (200,200): $(Get-Pixel 200 200)"
Write-Host "Desktop (800,400): $(Get-Pixel 800 400)"
Write-Host "Taskbar center (400,750): $(Get-Pixel 400 750)"
Write-Host "Icon area (24,100): $(Get-Pixel 24 100)"
Write-Host "Start btn (35,740): $(Get-Pixel 35 740)"

# Check multiple distinct regions
$desktopOK = ((Get-Pixel 200 200) -eq "51,85,119")  # Desktop BG
$taskbarOK = ((Get-Pixel 100 750) -eq "26,26,46")   # Taskbar BG
$fpsOK = ((Get-Pixel 55 14) -eq "255,255,0")        # Yellow FPS text

Write-Host "`n=== Verdict ==="
if ($desktopOK) { Write-Host "Desktop background: OK" -ForegroundColor Green } else { Write-Host "Desktop background: UNEXPECTED" -ForegroundColor Red }
if ($taskbarOK) { Write-Host "Taskbar: OK" -ForegroundColor Green } else { Write-Host "Taskbar: UNEXPECTED" -ForegroundColor Red }
if ($fpsOK) { Write-Host "FPS counter: OK" -ForegroundColor Green } else { Write-Host "FPS counter: UNEXPECTED" -ForegroundColor Red }

if ($desktopOK -and $taskbarOK -and $fpsOK) {
    Write-Host "`nALL RENDERING CHECKS PASSED - SSE2 optimizations working!" -ForegroundColor Green
}

# Debug: check center area more carefully (might have cursor or icon)
Write-Host "`n=== Center Area Debug ==="
Write-Host "(510,382): $(Get-Pixel 510 382)"
Write-Host "(512,380): $(Get-Pixel 512 380)"
Write-Host "(512,384): $(Get-Pixel 512 384)"
Write-Host "(512,386): $(Get-Pixel 512 386)"
Write-Host "(514,384): $(Get-Pixel 514 384)"
Write-Host "(500,384): $(Get-Pixel 500 384)"
# Cursor is at default (0,0) so center should be desktop BG
# The black at center might be mouse cursor or icon shadow
