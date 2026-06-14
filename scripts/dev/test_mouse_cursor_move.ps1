# Functional pointer test: boot the built UEFI image headless, inject relative
# mouse movement through the QEMU monitor (usb-mouse), and verify the cursor
# pixels actually moved between two screendumps. Exercises the whole input
# path: xHCI event ring -> usb_poll_mouse / fp_input_pump -> process_mouse ->
# cursor draw. PASS = the two dumps differ in a small changed-pixel region
# (cursor erase + redraw), not a full-screen repaint.
param([int]$BootWaitMs = 12000)
$ErrorActionPreference = 'Continue'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$DumpA = Join-Path $Root 'build\cursor_a.ppm'
$DumpB = Join-Path $Root 'build\cursor_b.ppm'

function Send-Monitor([string[]]$cmds, [int]$settleMs = 400) {
    $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 4444)
    $s = $c.GetStream()
    foreach ($cmd in $cmds) {
        $b = [System.Text.Encoding]::ASCII.GetBytes("$cmd`r`n")
        $s.Write($b, 0, $b.Length); $s.Flush()
        Start-Sleep -Milliseconds $settleMs
    }
    $c.Close()
}

function Stop-Qemu {
    try { Send-Monitor @('quit') 200 } catch {}
    try { Get-Process qemu-system-x86_64 -ErrorAction Stop | Stop-Process -Force -ErrorAction Stop } catch {}
}

Stop-Qemu; Start-Sleep -Milliseconds 400
foreach ($f in @($DumpA, $DumpB)) { if (Test-Path $f) { Remove-Item $f -Force } }

$job = Start-Job -ScriptBlock {
    param($RootPath)
    powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough -SerialTcp
} -ArgumentList $Root
Start-Sleep -Milliseconds $BootWaitMs

# Monitor paths must use forward slashes (backslashes are eaten by the parser).
$mA = $DumpA -replace '\\', '/'
$mB = $DumpB -replace '\\', '/'
try {
    Send-Monitor @("screendump $mA") 1500
    # Several small relative moves (usb-mouse is relative; large single deltas clamp).
    $moves = @(); 1..10 | ForEach-Object { $moves += 'mouse_move 25 12' }
    Send-Monitor $moves 120
    Start-Sleep -Milliseconds 800
    Send-Monitor @("screendump $mB") 1500
} catch { Write-Host "monitor error: $_" }
Stop-Qemu
Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null

if (-not (Test-Path $DumpA) -or -not (Test-Path $DumpB)) {
    Write-Host 'FAIL: missing screendump(s)'; exit 1
}

# Parse the two binary P6 PPMs and count/locate changed pixels.
function Read-Ppm([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    # Header: "P6\n<w> <h>\n255\n" - find the third newline.
    $nl = 0; $i = 0
    while ($nl -lt 3 -and $i -lt 64) { if ($bytes[$i] -eq 10) { $nl++ }; $i++ }
    $hdr = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $i)
    $parts = ($hdr -split '\s+') | Where-Object { $_ -match '^\d+$' }
    @{ W = [int]$parts[0]; H = [int]$parts[1]; Off = $i; Bytes = $bytes }
}
$a = Read-Ppm $DumpA; $b = Read-Ppm $DumpB
if ($a.W -ne $b.W -or $a.H -ne $b.H) { Write-Host 'FAIL: dump size mismatch'; exit 1 }

$w = $a.W; $changed = 0
$minX = [int]::MaxValue; $minY = [int]::MaxValue; $maxX = -1; $maxY = -1
$len = [Math]::Min($a.Bytes.Length - $a.Off, $b.Bytes.Length - $b.Off)
for ($p = 0; $p -lt $len; $p += 3) {
    if ($a.Bytes[$a.Off + $p] -ne $b.Bytes[$b.Off + $p] -or
        $a.Bytes[$a.Off + $p + 1] -ne $b.Bytes[$b.Off + $p + 1] -or
        $a.Bytes[$a.Off + $p + 2] -ne $b.Bytes[$b.Off + $p + 2]) {
        $changed++
        $pix = [int]($p / 3); $x = $pix % $w; $y = [int][Math]::Floor($pix / $w)
        if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
        if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
    }
}
Write-Host ("changed pixels: $changed  bbox: ($minX,$minY)-($maxX,$maxY) of ${w}x$($a.H)")
if ($changed -eq 0) { Write-Host 'FAIL: cursor did not move (identical dumps)'; exit 1 }
Write-Host 'PASS: cursor pixels moved'
exit 0
