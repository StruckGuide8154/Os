# SVG render-comparison harness.
#
# Compares how the Grit svg2 rasterizer draws glass-ribbons.svg against a
# reference renderer (Microsoft Edge), to surface where curves/lines are wrong
# or detail is missing -- independent of anti-aliasing.
#
#   1. Grit  - boots the OS in QEMU and issues the serial console command
#      0x01 'g'. The kernel forces the glass-ribbons SVG wallpaper, re-renders
#      it through svg2, and streams the wallpaper-cache image (a clean copy
#      with no icons/windows) over COM1, downsampled to 160x90.
#   2. Reference - Edge headless screenshots the same SVG at the Grit source
#      resolution, then it is downsampled with the identical nearest-neighbour
#      mapping so any letterboxing matches.
#
# Both are box-blurred to cancel anti-aliasing, then compared on:
#   * shape/coverage - which pixels each renderer painted as non-background.
#     This is the headline metric: wrong curves and missing detail show up
#     here without being drowned out by color/compositing differences.
#   * color - mean per-channel delta where both painted something.
#
# Outputs (build/):
#   svg_grit.ppm  - Grit render (160x90)
#   svg_edge.ppm   - Edge render    (160x90)
#   svg_diff.ppm   - shape-diff heatmap:
#                      green = both renderers painted here (agree)
#                      red   = Grit painted, Edge did not (spurious/wrong)
#                      blue  = Edge painted, Grit did not (missing detail)
#                      black = both background
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools/dev/svg_compare.ps1 [-SkipBuild]

param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Build = Join-Path $Root 'build'
$W = 160                                  # comparison raster width
$H = 90                                   # comparison raster height
$BgR = 0x05; $BgG = 0x05; $BgB = 0x08     # glass-ribbons background #050508

$SerialHost = '127.0.0.1'
$SerialPort = 5555

function Stop-Qemu {
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force
}

# --- 1. Build ---------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host '[svg-compare] building UEFI image...' -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_uefi.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'build_uefi.ps1 failed' }
}

# Stripped glass-ribbons SVG for the reference render: the feTurbulence noise
# is dropped so random noise cannot dominate a structural diff. (Grit keeps
# the noise rect, but its 4% alpha makes it negligible after blur.)
$StrippedSvg = Join-Path $Build 'glass-ribbons-stripped.svg'
& python -c @"
import re
s = open(r'$Root\src\resources\wallpapers\glass-ribbons.svg', encoding='utf-8').read()
s = re.sub(r'<filter id=\"noise\">.*?</filter>', '', s, flags=re.S)
s = re.sub(r'<rect[^>]*filter=\"url\(#noise\)\"[^>]*/>', '', s, flags=re.S)
s = re.sub(r'<!--.*?-->', '', s, flags=re.S)
s = re.sub(r'>\s+<', '><', s).strip()
open(r'$StrippedSvg', 'w', encoding='utf-8', newline='\n').write(s)
"@
if ($LASTEXITCODE -ne 0) { throw 'failed to write stripped SVG' }

# --- 2. Grit render via QEMU + serial ------------------------------------
Write-Host '[svg-compare] booting Grit in QEMU...' -ForegroundColor Cyan
Stop-Qemu
Start-Sleep -Seconds 1

$bootJob = Start-Job -ScriptBlock {
    param($RootPath)
    powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless
} -ArgumentList $Root

$serialText = ''
try {
    $client = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not $client -and [DateTime]::UtcNow -lt $deadline) {
        try {
            $c = [System.Net.Sockets.TcpClient]::new()
            $c.Connect($SerialHost, $SerialPort)
            $client = $c
        } catch {
            if ($c) { $c.Dispose() }
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $client) { throw "could not connect to serial $SerialHost`:$SerialPort" }

    $stream = $client.GetStream()
    $enc = [System.Text.Encoding]::ASCII
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 65536

    # Let the kernel reach the desktop before issuing the dump command.
    Write-Host '[svg-compare] waiting for boot, then requesting SVG dump...' -ForegroundColor Cyan
    Start-Sleep -Seconds 16

    # Serial control: byte 0x01 arms control mode, 'g' (0x67) triggers the dump.
    $stream.Write([byte[]]@(0x01, 0x67), 0, 2)
    $stream.Flush()

    $capDeadline = [DateTime]::UtcNow.AddSeconds(40)
    while ([DateTime]::UtcNow -lt $capDeadline) {
        while ($stream.DataAvailable) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { [void]$sb.Append($enc.GetString($buf, 0, $n)) }
        }
        if ($sb.ToString().Contains('[SVGEND]')) { break }
        Start-Sleep -Milliseconds 100
    }
    $serialText = $sb.ToString()
    $client.Close()
}
finally {
    Stop-Qemu
    Wait-Job $bootJob | Out-Null
    Remove-Job $bootJob -Force
}

Set-Content -Path (Join-Path $Build 'svg_compare_serial.log') -Value $serialText

$startIdx = $serialText.IndexOf('[SVGDUMP]')
$endIdx   = $serialText.IndexOf('[SVGEND]')
if ($startIdx -lt 0 -or $endIdx -lt 0 -or $endIdx -le $startIdx) {
    throw 'no [SVGDUMP]...[SVGEND] frame in serial output (see build/svg_compare_serial.log)'
}
$frame = $serialText.Substring($startIdx, $endIdx - $startIdx)

# Source resolution the kernel sampled from (DIM <w> <h>).
$srcW = 0; $srcH = 0
foreach ($line in $frame -split "`n") {
    if ($line.Trim() -match '^DIM\s+(\d+)\s+(\d+)') {
        $srcW = [int]$Matches[1]; $srcH = [int]$Matches[2]
    }
}
if ($srcW -le 0 -or $srcH -le 0) { throw 'no DIM line in dump frame' }

# Reassemble the pixel hex from the pure-hex lines (skips markers / DIM line).
$hex = New-Object System.Text.StringBuilder
foreach ($line in $frame -split "`n") {
    $t = $line.Trim()
    if ($t.Length -gt 0 -and $t -match '^[0-9A-Fa-f]+$') { [void]$hex.Append($t) }
}
$hexStr = $hex.ToString()
$expect = $W * $H * 6
if ($hexStr.Length -ne $expect) {
    throw "pixel hex length $($hexStr.Length), expected $expect"
}

$grit = New-Object 'int[]' ($W * $H * 3)
for ($i = 0; $i -lt $W * $H; $i++) {
    $o = $i * 6
    $grit[$i*3]   = [Convert]::ToInt32($hexStr.Substring($o, 2), 16)
    $grit[$i*3+1] = [Convert]::ToInt32($hexStr.Substring($o+2, 2), 16)
    $grit[$i*3+2] = [Convert]::ToInt32($hexStr.Substring($o+4, 2), 16)
}
Write-Host "[svg-compare] captured Grit render (source ${srcW}x${srcH} -> ${W}x${H})" -ForegroundColor Green

# --- 3. Reference render via Edge headless ----------------------------------
$edgePaths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
)
$edge = $edgePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found' }

$edgePng = Join-Path $Build 'svg_edge.png'
if (Test-Path $edgePng) { Remove-Item $edgePng -Force }
$svgUri = ([Uri](Resolve-Path $StrippedSvg).Path).AbsoluteUri
Write-Host "[svg-compare] rendering reference with Edge headless (${srcW}x${srcH})..." -ForegroundColor Cyan
$edgeArgs = @(
    '--headless=new', '--disable-gpu', '--hide-scrollbars',
    "--screenshot=$edgePng", "--window-size=$srcW,$srcH",
    '--force-device-scale-factor=1', $svgUri
)
# Start-Process so Edge's stderr chatter does not trip $ErrorActionPreference.
$edgeProc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -NoNewWindow -PassThru `
    -RedirectStandardError (Join-Path $Build 'svg_edge_stderr.log')
$edgeProc.WaitForExit(25000) | Out-Null
if (-not $edgeProc.HasExited) { $edgeProc.Kill() }
$waitPng = [DateTime]::UtcNow.AddSeconds(25)
while (-not (Test-Path $edgePng) -and [DateTime]::UtcNow -lt $waitPng) { Start-Sleep -Milliseconds 200 }
if (-not (Test-Path $edgePng)) { throw 'Edge produced no screenshot' }

Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap($edgePng)
# Downsample with the SAME nearest-neighbour mapping the kernel uses, so any
# letterboxing from preserveAspectRatio lands on the same pixels in both.
$edge_ = New-Object 'int[]' ($W * $H * 3)
for ($oy = 0; $oy -lt $H; $oy++) {
    $sy = [int]([Math]::Floor($oy * $bmp.Height / $H))
    if ($sy -ge $bmp.Height) { $sy = $bmp.Height - 1 }
    for ($ox = 0; $ox -lt $W; $ox++) {
        $sx = [int]([Math]::Floor($ox * $bmp.Width / $W))
        if ($sx -ge $bmp.Width) { $sx = $bmp.Width - 1 }
        $p = $bmp.GetPixel($sx, $sy)
        $i = ($oy * $W + $ox) * 3
        $a = $p.A / 255.0
        $edge_[$i]   = [int]($p.R * $a + $BgR * (1 - $a))
        $edge_[$i+1] = [int]($p.G * $a + $BgG * (1 - $a))
        $edge_[$i+2] = [int]($p.B * $a + $BgB * (1 - $a))
    }
}
$bmp.Dispose()
Write-Host "[svg-compare] captured Edge render ($W x $H)" -ForegroundColor Green

# --- 4. Compare -------------------------------------------------------------
function Write-Ppm {
    param([string]$Path, [int[]]$Px)
    $head = [System.Text.Encoding]::ASCII.GetBytes("P6`n$W $H`n255`n")
    $body = New-Object byte[] ($W * $H * 3)
    for ($i = 0; $i -lt $body.Length; $i++) { $body[$i] = [byte]([Math]::Max(0, [Math]::Min(255, $Px[$i]))) }
    $fs = [System.IO.File]::Create($Path)
    $fs.Write($head, 0, $head.Length)
    $fs.Write($body, 0, $body.Length)
    $fs.Close()
}

# Separable 3x3 box blur - cancels single-pixel anti-aliasing fringes so the
# diff reflects shape, not edge softness.
function Blur {
    param([int[]]$Px)
    $out = New-Object 'int[]' ($W * $H * 3)
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            for ($c = 0; $c -lt 3; $c++) {
                $sum = 0; $cnt = 0
                for ($dy = -1; $dy -le 1; $dy++) {
                    for ($dx = -1; $dx -le 1; $dx++) {
                        $nx = $x + $dx; $ny = $y + $dy
                        if ($nx -ge 0 -and $nx -lt $W -and $ny -ge 0 -and $ny -lt $H) {
                            $sum += $Px[($ny * $W + $nx) * 3 + $c]; $cnt++
                        }
                    }
                }
                $out[($y * $W + $x) * 3 + $c] = [int]($sum / $cnt)
            }
        }
    }
    return $out
}

$nB = Blur $grit
$eB = Blur $edge_

# A pixel is "ink" if it diverges from the background past a small tolerance.
$inkTol = 24
function Is-Ink {
    param([int[]]$Px, [int]$I)
    $d = [Math]::Abs($Px[$I] - $BgR) + [Math]::Abs($Px[$I+1] - $BgG) + [Math]::Abs($Px[$I+2] - $BgB)
    return ($d -gt $inkTol)
}

# Precompute ink masks once.
$nInk = New-Object 'bool[]' ($W * $H)
$eInk = New-Object 'bool[]' ($W * $H)
for ($i = 0; $i -lt $W * $H; $i++) {
    $nInk[$i] = Is-Ink $nB ($i * 3)
    $eInk[$i] = Is-Ink $eB ($i * 3)
}

# Edge-tolerant match: a shape boundary that lands one pixel apart between two
# correct renderers is anti-aliasing, not a structural error. So a mismatched
# ink pixel only counts as a real disagreement if the other renderer has NO
# ink anywhere in its EdgeTol-radius neighbourhood. A genuinely missing curve
# or detail still fails this test (its interior has no nearby ink), so this
# isolates "wrong/missing geometry" from "edge sits 1px over".
$EdgeTol = 1
function Ink-Near {
    param([bool[]]$Mask, [int]$X, [int]$Y)
    for ($dy = -$EdgeTol; $dy -le $EdgeTol; $dy++) {
        for ($dx = -$EdgeTol; $dx -le $EdgeTol; $dx++) {
            $nx = $X + $dx; $ny = $Y + $dy
            if ($nx -ge 0 -and $nx -lt $W -and $ny -ge 0 -and $ny -lt $H) {
                if ($Mask[$ny * $W + $nx]) { return $true }
            }
        }
    }
    return $false
}

$diff = New-Object 'int[]' ($W * $H * 3)
$bothInk = 0; $gritOnly = 0; $edgeOnly = 0; $edgeBand = 0
$colorSum = 0.0; $colorN = 0

for ($y = 0; $y -lt $H; $y++) {
    for ($x = 0; $x -lt $W; $x++) {
        $i = $y * $W + $x
        $o = $i * 3
        $ni = $nInk[$i]
        $ei = $eInk[$i]
        if ($ni -and $ei) {
            $bothInk++
            $diff[$o] = 0; $diff[$o+1] = 200; $diff[$o+2] = 0
            $colorSum += ([Math]::Abs($nB[$o]-$eB[$o]) + [Math]::Abs($nB[$o+1]-$eB[$o+1]) + [Math]::Abs($nB[$o+2]-$eB[$o+2])) / 3.0
            $colorN++
        } elseif ($ni) {
            if (Ink-Near $eInk $x $y) {
                $edgeBand++
                $diff[$o] = 90; $diff[$o+1] = 90; $diff[$o+2] = 0
            } else {
                $gritOnly++
                $diff[$o] = 220; $diff[$o+1] = 0; $diff[$o+2] = 0
            }
        } elseif ($ei) {
            if (Ink-Near $nInk $x $y) {
                $edgeBand++
                $diff[$o] = 90; $diff[$o+1] = 90; $diff[$o+2] = 0
            } else {
                $edgeOnly++
                $diff[$o] = 0; $diff[$o+1] = 0; $diff[$o+2] = 220
            }
        } else {
            $diff[$o] = 8; $diff[$o+1] = 8; $diff[$o+2] = 12
        }
    }
}

Write-Ppm (Join-Path $Build 'svg_grit.ppm') $grit
Write-Ppm (Join-Path $Build 'svg_edge.ppm')  $edge_
Write-Ppm (Join-Path $Build 'svg_diff.ppm')  $diff

# Also emit PNGs so the results open in any Windows image viewer.
& python -c @"
import os, struct, zlib
def ppm_to_png(src, dst):
    d = open(src, 'rb').read()
    i, tok = 0, []
    while len(tok) < 4:
        while d[i] in b' \t\n\r': i += 1
        s = i
        while d[i] not in b' \t\n\r': i += 1
        tok.append(d[s:i])
    i += 1
    w, h = int(tok[1]), int(tok[2])
    px = d[i:]
    raw = b''.join(b'\x00' + px[y*w*3:(y+1)*w*3] for y in range(h))
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    open(dst, 'wb').write(png)
for n in ('svg_grit', 'svg_edge', 'svg_diff'):
    ppm_to_png(os.path.join(r'$Build', n + '.ppm'), os.path.join(r'$Build', n + '.png'))
"@
if ($LASTEXITCODE -ne 0) { Write-Host '[svg-compare] PNG export skipped' -ForegroundColor DarkYellow }

# Shape agreement counts both-ink and edge-band (1px AA offset) as agreement;
# only neighbourhood-isolated mismatches are real geometry errors.
$totalInk = $bothInk + $edgeBand + $gritOnly + $edgeOnly
$agree      = $bothInk + $edgeBand
$shapeAgree = if ($totalInk -gt 0) { 100.0 * $agree / $totalInk } else { 100.0 }
$missing    = if ($totalInk -gt 0) { 100.0 * $edgeOnly / $totalInk } else { 0.0 }
$spurious   = if ($totalInk -gt 0) { 100.0 * $gritOnly / $totalInk } else { 0.0 }
$meanColor  = if ($colorN -gt 0) { $colorSum / $colorN } else { 0.0 }

Write-Host ''
Write-Host '======== SVG render comparison ========' -ForegroundColor Cyan
Write-Host ("  comparison raster : {0} x {1}  (Grit source {2} x {3})" -f $W, $H, $srcW, $srcH)
Write-Host ("  shape agreement   : {0:N2}%  (same geometry, ignoring 1px AA edges)" -f $shapeAgree)
Write-Host ("  missing detail    : {0:N2}%  (Edge painted geometry Grit lacks)" -f $missing) -ForegroundColor Yellow
Write-Host ("  spurious / wrong  : {0:N2}%  (Grit painted geometry Edge lacks)" -f $spurious) -ForegroundColor Yellow
Write-Host ("  mean color delta  : {0:N1} / 255  (where both painted)" -f $meanColor)
Write-Host ("  ink pixels        : agree={0}  edge-band={1}  grit-only={2}  edge-only={3}" -f $bothInk, $edgeBand, $gritOnly, $edgeOnly)
Write-Host '  outputs           : build/svg_{grit,edge,diff}.png  (+ .ppm)'
Write-Host '=======================================' -ForegroundColor Cyan
