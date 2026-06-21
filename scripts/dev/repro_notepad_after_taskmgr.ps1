# Repro: open Task Manager, THEN open Notepad -> whole-OS freeze.
# Boots the built UEFI image headless, opens Start menu + Task Manager, waits,
# then opens Start menu + Notepad, and checks (a) serial markers and (b) whether
# the cursor still moves afterwards (OS alive).
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

# Screen 1920x1200. Taskbar bottom 36px -> top 1164. Start btn x 4..74.
# Start menu (height 268) anchors above taskbar at menu_y0 = 896. Rows:
#   896 + 8 + i*28 + 14 (center). Order: Explorer0,Term1,Notepad2,Settings3,Paint4,TaskMgr5
$yTask = 896 + 8 + 5*28 + 14   # 1058
$yNote = 896 + 8 + 2*28 + 14   # 974
$dumpA = (Join-Path $Root 'build\nat_after_task.ppm') -replace '\\','/'
$dumpB = (Join-Path $Root 'build\nat_after_note.ppm') -replace '\\','/'
$dumpL = (Join-Path $Root 'build\nat_live.ppm')       -replace '\\','/'

# 1) Open Start menu + Task Manager.
Move-To 39 1182; Click
Move-To 104 $yTask; Click
Start-Sleep -Milliseconds 1800
Send-Monitor @("screendump $dumpA") 800

# 2) Open Start menu AGAIN + Notepad.
Move-To 39 1182; Click
Move-To 104 $yNote; Click
Start-Sleep -Milliseconds 1800
Send-Monitor @("screendump $dumpB") 800

# 3) Liveness: jiggle the mouse and screendump again.
Send-Monitor @('mouse_move 40 -40','mouse_move -40 40','mouse_move 30 30') 120
Start-Sleep -Milliseconds 600
Send-Monitor @("screendump $dumpL") 800

Start-Sleep -Milliseconds 300
$mk = $null
if (Test-Path $Serial) {
    $mk = Select-String -Path $Serial -Pattern 'TXBF','ZRSP','DMF','TXAB','KREC' -SimpleMatch -ErrorAction SilentlyContinue
}
Write-Host "==== serial markers ===="
if ($mk) { $mk | ForEach-Object { Write-Host $_.Line } } else { Write-Host '(none)' }
Write-Host "==== tail of serial ===="
if (Test-Path $Serial) { Get-Content $Serial -Tail 30 }

Send-Monitor @('quit') 200
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
