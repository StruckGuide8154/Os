# Analyze PPM screendump
param([string]$File = "build\screen_test.ppm", [string]$Mode = "overview")

$bytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $File))
$pos = 0; $newlines = 0
while ($newlines -lt 3 -and $pos -lt 100) {
    if ($bytes[$pos] -eq 10) { $newlines++ }
    $pos++
}

function Get-Pixel($x, $y) {
    $offset = $script:pos + ($y * 1024 + $x) * 3
    return @($bytes[$offset], $bytes[$offset+1], $bytes[$offset+2])
}

function Pixel-Str($x, $y) {
    $p = Get-Pixel $x $y
    return "R=$($p[0]) G=$($p[1]) B=$($p[2])"
}

switch ($Mode) {
    "overview" {
        Write-Host "Desktop (512,100):" (Pixel-Str 512 100)
        Write-Host "Taskbar (512,750):" (Pixel-Str 512 750)
        Write-Host "Start (30,740):" (Pixel-Str 30 740)
        Write-Host "Icon1 (40,50):" (Pixel-Str 40 50)
        Write-Host "Icon2 (40,130):" (Pixel-Str 40 130)
        Write-Host "Center (512,384):" (Pixel-Str 512 384)
    }
    "findwindow" {
        Write-Host "Scanning for non-desktop pixels..."
        $found = @{}
        for ($y = 30; $y -le 700; $y += 10) {
            for ($x = 80; $x -le 900; $x += 20) {
                $p = Get-Pixel $x $y
                $r = $p[0]; $g = $p[1]; $b = $p[2]
                if ($r -eq 51 -and $g -eq 85 -and $b -eq 119) { continue }  # desktop
                if ($r -eq 26 -and $g -eq 26 -and $b -eq 46) { continue }  # taskbar
                $key = "R=$r G=$g B=$b"
                if (-not $found.ContainsKey($key)) {
                    $found[$key] = "($x,$y)"
                    Write-Host "  ($x,$y): $key"
                }
            }
        }
        if ($found.Count -eq 0) { Write-Host "  No window found" }
    }
    "region" {
        # Scan a specific region - pass x1,y1,x2,y2 as extra args
        $x1 = [int]$args[0]; $y1 = [int]$args[1]
        $x2 = [int]$args[2]; $y2 = [int]$args[3]
        for ($y = $y1; $y -le $y2; $y += 2) {
            $line = "y=$($y.ToString('D3')): "
            for ($x = $x1; $x -le $x2; $x += 2) {
                $p = Get-Pixel $x $y
                $r = $p[0]; $g = $p[1]; $b = $p[2]
                if ($r -eq 51 -and $g -eq 85 -and $b -eq 119) { $line += "." }  # desktop
                elseif ($r -eq 26 -and $g -eq 26 -and $b -eq 46) { $line += "=" }  # dark
                elseif ($r -eq 0 -and $g -eq 0 -and $b -eq 0) { $line += "#" }  # black
                elseif ($r -gt 200 -and $g -gt 200 -and $b -gt 200) { $line += "W" }  # white
                elseif ($r -eq 0 -and $g -eq 255 -and $b -eq 0) { $line += "C" }  # cursor green
                elseif ($r -gt 100 -and $g -lt 50 -and $b -lt 50) { $line += "R" }  # red
                elseif ($r -lt 50 -and $g -gt 100 -and $b -lt 50) { $line += "G" }  # green
                elseif ($r -lt 80 -and $g -lt 80 -and $b -gt 150) { $line += "B" }  # blue
                else { $line += "?" }
            }
            Write-Host $line
        }
    }
}
