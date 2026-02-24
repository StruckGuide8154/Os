$b = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\screen.ppm')
$h = 16

function px($x, $y) {
    $o = $h + ($y * 1024 + $x) * 3
    if ($o + 2 -ge $b.Length) { return "OOB" }
    $r = $b[$o]; $g = $b[$o+1]; $bl = $b[$o+2]
    return ("{0:X2}{1:X2}{2:X2}" -f $r, $g, $bl)
}

Write-Host "=== Key points ==="
Write-Host "Desktop bg (800,300): #$(px 800 300)"
Write-Host "Center     (512,384): #$(px 512 384)"
Write-Host "Taskbar    (500,740): #$(px 500 740)"
Write-Host "Start btn  (30, 740): #$(px 30 740)"
Write-Host "Icon1-PC   (40,  40): #$(px 40 40)"
Write-Host "Icon2-Term (40, 120): #$(px 40 120)"
Write-Host "Icon3-Note (40, 200): #$(px 40 200)"
Write-Host ""

# Check for any window in center area
Write-Host "=== Center scan for stray windows ==="
for ($y = 100; $y -le 600; $y += 50) {
    for ($x = 200; $x -le 800; $x += 100) {
        $c = px $x $y
        if ($c -ne "335577") {
            Write-Host "  NON-BG at ($x,$y): #$c"
        }
    }
}
Write-Host "(end of scan)"
