# Repro: open Notepad, click inside it (File menu -> dropdown), and verify the
# OS stays alive (cursor keeps moving) instead of freezing. Notepad window opens
# at (250,120) size 400x300 on a 1920x1200 screen; usb-mouse has ~1.5x accel.
param([int]$BootWaitMs = 16000)
$ErrorActionPreference = 'Continue'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Serial = Join-Path $Root 'build\serial_full.log'

function Send-Monitor([string[]]$cmds,[int]$ms=300){ $c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',4444);$s=$c.GetStream();foreach($cmd in $cmds){$b=[Text.Encoding]::ASCII.GetBytes("$cmd`r`n");$s.Write($b,0,$b.Length);$s.Flush();Start-Sleep -Milliseconds $ms};$c.Close() }
function Move-To([int]$tx,[int]$ty){ $a=1.5;$rx=[int]($tx/$a);$ry=[int]($ty/$a);$c=@();1..16|%{$c+='mouse_move -200 -200'};Send-Monitor $c 25;$x=0;$y=0;$st=@();while($x -lt $rx -or $y -lt $ry){$dx=[Math]::Min(20,$rx-$x);$dy=[Math]::Min(20,$ry-$y);if($dx -lt 0){$dx=0};if($dy -lt 0){$dy=0};$st+="mouse_move $dx $dy";$x+=$dx;$y+=$dy};Send-Monitor $st 25 }
function Click(){ Send-Monitor @('mouse_button 1') 120;Send-Monitor @('mouse_button 0') 250 }
function Live([string]$tag){ Send-Monitor @("screendump build/np_$tag`_a.ppm") 600; Send-Monitor @('mouse_move 50 -50','mouse_move -50 50','mouse_move 40 40') 120; Start-Sleep -Milliseconds 500; Send-Monitor @("screendump build/np_$tag`_b.ppm") 600 }

Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
Remove-Item $Serial -Force -ErrorAction SilentlyContinue
$job = Start-Job -ScriptBlock { powershell -ExecutionPolicy Bypass -File "C:\Users\user\Documents\new\scripts\run\run_uefi.ps1" -Headless -NoPassthrough }
Start-Sleep -Milliseconds $BootWaitMs

$mark=(Get-Content $Serial).Count
Move-To 39 1182; Click            # Start menu
Move-To 104 974; Click            # Notepad row -> launch
Start-Sleep -Milliseconds 1200
# Click the File menu (top-left of the notepad client area).
Move-To 272 156; Click
# Click into the dropdown (Save As is the 2nd item).
Move-To 286 196; Click
Start-Sleep -Milliseconds 1200
Live 'after'
Start-Sleep -Milliseconds 300
Write-Host "==== markers ===="
$m = Select-String -Path $Serial -Pattern 'TXBF|TXAB|ZRSP|DMF|R3CN|CANARY' -SimpleMatch -ErrorAction SilentlyContinue
if ($m) { $m | % { $_.Line } } else { Write-Host '(none)' }
Write-Host "==== tail since interaction ===="
Get-Content $Serial | Select-Object -Skip $mark | Select-Object -Last 18

Send-Monitor @('quit') 200
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force
Stop-Job $job -ErrorAction SilentlyContinue|Out-Null; Remove-Job $job -Force -ErrorAction SilentlyContinue|Out-Null
