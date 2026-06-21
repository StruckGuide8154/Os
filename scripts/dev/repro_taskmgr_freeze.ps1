# Repro harness for the Task-Manager-open whole-OS freeze.
# Boots the built UEFI image headless, opens the Start menu, clicks the
# "Task Manager" row, then checks (a) the serial log for a TXBF line and
# (b) whether the cursor still moves afterwards (OS alive).
param([int]$BootWaitMs = 16000)
$ErrorActionPreference = 'Continue'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Serial = Join-Path $Root 'build\serial_full.log'

function Send-Monitor([string[]]$cmds, [int]$settleMs = 300) {
    $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 4444)
    $s = $c.GetStream()
    foreach ($cmd in $cmds) {
        $b = [System.Text.Encoding]::ASCII.GetBytes("$cmd`r`n")
        $s.Write($b, 0, $b.Length); $s.Flush()
        Start-Sleep -Milliseconds $settleMs
    }
    $c.Close()
}
function Move-To([int]$tx, [int]$ty) {
    # Relative usb-mouse with ~1.5x guest pointer accel: divide the requested
    # ABSOLUTE target by the accel factor so the cursor lands on (tx,ty).
    $accel = 1.5
    $rx = [int]($tx / $accel); $ry = [int]($ty / $accel)
    $cmds = @(); 1..16 | ForEach-Object { $cmds += 'mouse_move -200 -200' }
    Send-Monitor $cmds 30
    $x = 0; $y = 0; $steps = @()
    while ($x -lt $rx -or $y -lt $ry) {
        $dx = [Math]::Min(20, $rx - $x); $dy = [Math]::Min(20, $ry - $y)
        if ($dx -lt 0) { $dx = 0 }; if ($dy -lt 0) { $dy = 0 }
        $steps += "mouse_move $dx $dy"; $x += $dx; $y += $dy
    }
    Send-Monitor $steps 30
}
function Click() { Send-Monitor @('mouse_button 1') 120; Send-Monitor @('mouse_button 0') 200 }

Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
if (Test-Path $Serial) { Remove-Item $Serial -Force -ErrorAction SilentlyContinue }

$job = Start-Job -ScriptBlock {
    param($RootPath)
    powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough
} -ArgumentList $Root
Start-Sleep -Milliseconds $BootWaitMs

# Screen is 1024x768. Taskbar bottom (y 732..768), Start button x 4..74.
# Start menu (9 rows, 28px each, pad 8) anchors above the taskbar at x=4.
$dumpPre  = (Join-Path $Root 'build\tm_pre.ppm')  -replace '\\','/'
$dumpMenu = (Join-Path $Root 'build\tm_menu.ppm') -replace '\\','/'
$dumpPost = (Join-Path $Root 'build\tm_post.ppm') -replace '\\','/'
$dumpLive = (Join-Path $Root 'build\tm_live.ppm') -replace '\\','/'

Send-Monitor @("screendump $dumpPre") 800
# Screen is 1920x1200. Taskbar bottom 36px -> top at 1164. Start btn x 4..74.
# 1) Open Start menu (start button center ~ (39,1182)).
Move-To 39 1182
Click
Send-Monitor @("screendump $dumpMenu") 800
# 2) Click the Task Manager row. Start menu (height 268) anchors above the
#    taskbar at menu_y0 = 1164 - 268 = 896. Rows: 896 + 8 + i*28 (+14 center).
#    Row index 5 (Explorer,Term,Notepad,Settings,Paint,TaskMgr) -> y = 1058.
Move-To 104 1058
Click
Start-Sleep -Milliseconds 1500
Send-Monitor @("screendump $dumpPost") 800
# 3) Liveness: jiggle the mouse and screendump again.
Send-Monitor @('mouse_move 40 -40','mouse_move -40 40','mouse_move 30 30') 120
Start-Sleep -Milliseconds 600
Send-Monitor @("screendump $dumpLive") 800

Start-Sleep -Milliseconds 300
$txbf = $null
if (Test-Path $Serial) {
    $txbf = Select-String -Path $Serial -Pattern 'TXBF|ZRSP|DMF|KREC' -SimpleMatch -ErrorAction SilentlyContinue
}
Write-Host "==== serial markers ===="
if ($txbf) { $txbf | ForEach-Object { Write-Host $_.Line } } else { Write-Host '(none)' }
Write-Host "==== tail of serial ===="
if (Test-Path $Serial) { Get-Content $Serial -Tail 25 }

Send-Monitor @('quit') 200
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
